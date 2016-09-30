create or replace function _field_defs()
returns setof @extschema@.audit_field
language sql immutable as $f$
	select * from unnest(array[
		('id', 'default', 'bigserial'),
		('ts', 'now()', 'timestamptz'),
		('clock', 'clock_timestamp()', 'timestamptz'),
		('user', 'session_user', 'name'),
		('user_id', $$current_setting('@extschema@.user_id')$$, 'text'),
		('action', 'tg_op', 'text'),
		('schema', 'tg_table_schema', 'name'),
		('table', 'tg_table_name', 'name')
	]::@extschema@.audit_field[]);
$f$;
