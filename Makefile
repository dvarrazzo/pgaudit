EXTENSION    = pgaudit
EXTVERSION   = $(shell grep default_version $(EXTENSION).control | sed -e "s/default_version[[:space:]]*=[[:space:]]*'\([^']*\)'/\1/")

DOCS         = $(wildcard doc/*.md)
REGRESS      = testaudit otherns
REGRESS_OPTS = --inputdir=test --load-language=plpgsql

PG_CONFIG    = pg_config

all: sql/$(EXTENSION)--$(EXTVERSION).sql

sql/$(EXTENSION)--$(EXTVERSION).sql: sql/$(EXTENSION).sql
	cp $< $@

DATA = $(wildcard sql/$(EXTENSION)--*--*.sql) sql/$(EXTENSION)--$(EXTVERSION).sql
EXTRA_CLEAN = sql/$(EXTENSION)--$(EXTVERSION).sql

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

installcheck: test/sql/otherns.sql test/expected/otherns.out

# check relocatability
test/sql/otherns.sql: test/sql/testaudit.sql 
	sed 's/testaudit/otherns/g' $< > $@

test/expected/otherns.out: test/expected/testaudit.out 
	sed 's/testaudit/otherns/g' $< > $@
