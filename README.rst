====================================
pgaudit - Audit trail for PostgreSQL
====================================

The extension allows the creation and maintenance of tables tracing the data
manipulation into other tables.


Installation
------------

To build it, just do this::

	make
	make installcheck
	sudo make install

If you encounter an error such as::

	"Makefile", line 8: Need an operator

You need to use GNU make, which may well be installed on your system as
``gmake``::

	gmake
	gmake install
	sudo gmake installcheck

If you encounter an error such as::

	make: pg_config: Command not found

Be sure that you have ``pg_config`` installed and in your path. If you used a
package management system such as RPM to install PostgreSQL, be sure that the
``-devel`` package is also installed. If necessary tell the build process where
to find it::

	export PG_CONFIG=/path/to/pg_config
	make && make installcheck && make install

If you encounter an error such as::

	ERROR:	must be owner of database regression

You need to run the test suite using a super user, such as the default
"postgres" super user::

	make installcheck PGUSER=postgres

Once pgaudit is installed, you can add it to a database. The extension can be
installed into any schema, including ``public`` but it is advisable to create
a separate schema to contain the audit tables::

	CREATE SCHEMA audit;
	CREATE EXTENSION pgaudit WITH SCHEMA audit;

See ``doc/pgaudit.rst`` for usage help.


Copyright and License
---------------------

Copyright (c) 2014 Daniele Varrazzo <piro@gambitresearch.com>.

