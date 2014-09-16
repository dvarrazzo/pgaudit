pgaudit - Audit trail for PostgreSQL
====================================

The extension allows the creation and maintenance of tables tracing the data
manipulation into other tables.


Installation
------------

This is a "PostgreSQL extension": it needs to be installed for a cluster
(files are copied into `/usr/share/postgres/X.Y/extensions` or somewhere else
in the system. After the installation phase the extension can be "created" and
used inside a database of that cluster.

To build and install the extension, just run:

	make
	sudo make install

Once pgaudit is installed, you can add it to a database. The extension can be
installed into any schema, including `public` but it is advisable to create
a separate schema to contain the audit tables:

	CREATE SCHEMA audit;
	CREATE EXTENSION pgaudit WITH SCHEMA audit;

See ``doc/pgaudit.md`` for usage help.


Copyright and License
---------------------

Copyright (c) 2014 Daniele Varrazzo <piro@gambitresearch.com>.

