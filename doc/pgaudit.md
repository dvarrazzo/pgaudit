pgaudit -- Audit trail for PostgreSQL
=====================================

The extension allows the creation of audit tables containing information about
all the data changes made to a table.


Installation
============

Usual story about installing an extension on PostgreSQL. Check `README.md`.


Usage
=====

Install the extension in a schema of your choice (typically `audit`: further
documentation will assume this name). Note that the extension will also create
an user called `audit`.

	create schema audit;
	create extension pgaudit with schema audit;


Audit fields
------------

The following fields can be added to each record in the audit trail:

- `id` (`bigint`): a numeric sequence of the operation
- `ts` (`timestamptz`): transaction timestamp of the operation.
  Rows updated in the same transaction will have the same value
- `clock` (`timestamptz`): wall clock timestamp of the operation.
  Increases even within the same transaction
- `action` (`text`): the operation performed (`INSERT`, `UPDATE`, `DELETE`)
- `schema` (`name`): the schema name of the audited table
- `table` (`name`): the name of the audited table
- `user` (`name`): the user performing the operation. (Note: the
  `session_user`, not the `current_user`)
- `user_id` (`text`): an app-defined user id, read from the `SCHEMA.user_id`
  setting parameter (where *SCHEMA* is the schema the extension is installed
  into).

The `user_id` setting should be set beforehand, e.g. with a statement such as
`SET [LOCAL] "audit.user_id" TO n`. At the time of updating an audited table
the setting **must** exist, either because `SET` was called or because
declared in a [customized option][1] in the `postgres.conf` file; failing to
do so, auditing will result in an "unrecognized configuration parameter"
error.

[1]: https://www.postgresql.org/docs/current/static/runtime-config-custom.html


function `audit.start(TABLE [, FIELDS])`
----------------------------------------

Start auditing a function. On success return the `audited` value.

Parameters:

- `TABLE` (`regclass`): name or oid of the table to audit.
- `FIELDS` (array of `text`): list of audit fields to include in the trail,
  chosen from the ones available in the [Audit fields](#audit-fields) section.
  Default: `ts`, `action`.

The command will create a new table in the `audit` schema called like the
original table *with its schema*. E.g. auditing the table `foo` in the
schema `bar` will create a new table called `audit."bar.foo"`. The audit
table name is always schema-qualified, even if the schema is in `public` or
in some other schema in the caller's search path.

The table will have a series of audit fields called `audit_NAME` where
the `NAME` s are the ones reqested in the `FIELDS` argument, followed by
the same fields of the audited tables (but without any constraint or check).

If at calling time an audit table with conflicting name is found, it will be
renamed appending a timestamp (as in `audit.stop()`). If `start()` is
called again on the same table with the same `FIELDS` will result in no
change; if `FIELDS` is changed the previous table is renamed and a new one
is created.


function `audit.stop(TABLE)`
----------------------------

Stop auditing on a table. On success return the `unaudited` value.

Parameters:

- `TABLE` (`regclass`): name or oid of the table where to stop audit on.

The function drops the audit trigger and support function and renames the
table appending a timestamp, e.g. the audit table `audit."public.foo"` is
renamed into something like `audit."public.foo_20140124_123734"`.  The new
name is published in a notice.


function `audit.rotate(TABLE)`
------------------------------

Rename the current audit table away and start auditing in a new table.

Parameters:

- `TABLE` (`regclass`): name or oid of the table to rotate audit for.

The previous audit table will be renamed as described in `stop()`.The new
table will have the same audit fields installed on `start()` but changes to
the table structure will be picked up.


function `audit.pause(TABLE)`
-----------------------------

Temporarily suspend a table audit. On success return the `paused` value.

Parameters:

- `TABLE` (`regclass`): name or oid of the table where to pause audit on.


function `audit.restart(TABLE)`
-------------------------------

Restart a temporarily suspended table audit. On success return the `audited`
value.

Parameters:

- `TABLE` (`regclass`): name or oid of the table where to restart audit on.


function `audit.status(TABLE)`
------------------------------

Return the audit status on a table.

Parameters:

- `TABLE` (`regclass`): name or oid of the table to get info about.

The returned value can be one of `audited`, `paused`, `unaudited`,
`inconsistent`. For an `inconsistent` table you may check the `info()`
function to see what objects are missing (a `stop()` should clear up the
mess).


function `audit.info(TABLE)`
----------------------------

Return a structure with detailed info about a table audit.

Parameters:

- `TABLE` (`regclass`): name or oid of the table to get info about.

Example result:

	=# select * from audit.info('foo');
		   table        |   fields    | has_function | has_trigger | trigger_enabled
	--------------------+-------------+--------------+-------------+-----------------
	 audit."public.foo" | {ts,action} | t            | t           | t


function `audit.create_index(TABLE, FIELD)`
-------------------------------------------

Create an index on FIELD of the audit table of TABLE

Parameters:

- `TABLE` (`regclass`): name or oid of the table on whose audit table create
  the index.
- `FIELD` (`name`): name of the field to create the index on.

The index will be named `SCHEMA.TABLE_FIELD_idx` and will be a simple btree
index on the entire table. It is not possible to create the index concurrently
(it's not possible inside a function). If there are inheriting tables create
indexes on them too.
