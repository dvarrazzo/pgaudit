create or replace function _table_name(tgt regclass) returns name
language sql stable
as $$
	select relname from pg_class where oid = $1;
$$;

create or replace function create_index(tgt regclass, field name)
returns void
language plpgsql
as $$
begin
	perform @extschema@._create_table_index(
		(@extschema@.info(tgt))."table", field);
end
$$;

create or replace function _create_table_index(tbl regclass, field name)
returns void
language plpgsql
as $$
declare
	sql text;
	inh regclass;
begin
	sql := format('create index %I on %s (%I)',
		@extschema@._table_name(tbl) || '_' || field || '_idx',
		tbl, field);
	raise notice 'creating index with definition: %', sql;
	execute sql;

	for inh in select inhrelid from pg_inherits where inhparent = tbl loop
		perform @extschema@._create_table_index(inh, field);
	end loop;
end
$$;
