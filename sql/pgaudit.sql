--
-- Audit trail for PostgreSQL
--

-- Create the user only if it doesn't exist.
do language plpgsql $$
begin
	declare
		super bool;
	begin
		create user audit nosuperuser;
	exception when duplicate_object then
		select usesuper into strict super
		from pg_user where usename = 'audit';
		if super then
			raise 'There is already an "audit" user but it is a superuser.'
			using hint = 'Please remove its superuser privilege.';
		end if;
	end;
end
$$;

-- The audit user must be able to create/manipulate tables here.
-- Other users may be interested to access some functions or tables
grant all on schema @extschema@ to audit;
grant usage on schema @extschema@ to public;


-- The following objects are created with the audit user owner.
set local role audit;


-- Synthetic info about the audit status of a table
-- Returned by the status() function.
create type audit_status as enum (
	'audited', 'paused', 'unaudited', 'inconsistent');


-- Detailed info about the audit status of a table
-- Returned by the info() function.
create type audit_info as (
	"table" regclass,
	fields text[],
	has_function boolean,
	has_trigger boolean,
	trigger_enabled boolean);


-- Create an audit table and install the audit trigger
create or replace function start(
	tgt regclass,
	audit_fields text[] default array['ts', 'action'])
returns @extschema@.audit_status
language plpgsql
as $$
declare
	info @extschema@.audit_info;
	status @extschema@.audit_status;
	stmt text;
begin
	begin -- this is a transaction in PL/pgSQL
		info := @extschema@.info(tgt);
		status := @extschema@._status(info);

		-- If the table is already audited and the fields are the same
		-- don't do anything.
		if status = 'audited' and audit_fields = info.fields then
			null;

		-- If the status is paused and we are asking for the same audit fields
		-- then just unpause it.
		elsif status = 'paused' and audit_fields = info.fields then
			return @extschema@.restart(tgt);

		-- Otherwise an existing audit table and start with a new one
		else
			foreach stmt
				in array @extschema@._start_stmts(tgt, audit_fields)
			loop
				execute stmt;
			end loop;
			perform @extschema@._grant_seqs(tgt);
		end if;

		return @extschema@.status(tgt);

	exception
		-- you can't have this clause empty
		when division_by_zero then raise 'wat?';
	end;
end
$$;

-- Remove audit trigger from a table and rename the audit table away
create or replace function stop(tgt regclass)
returns @extschema@.audit_status
language plpgsql
as $$
declare
	stmts text[];
	stmt text;
begin
	begin -- this is a transaction in PL/pgSQL
		stmts = @extschema@._stop_stmts(tgt);
		foreach stmt in array stmts loop
			execute stmt;
		end loop;
		return @extschema@.status(tgt);
	exception
		-- you can't have this clause empty
		when division_by_zero then raise 'wat?';
	end;
end
$$;

-- Rename the current log table away and start a new one keeping its definition
create or replace function rotate(tgt regclass)
returns @extschema@.audit_status
language plpgsql
as $$
declare
	info @extschema@.audit_info;
	status @extschema@.audit_status;
begin
	begin -- this is a transaction in PL/pgSQL
		info := @extschema@.info(tgt);
		status := @extschema@._status(info);

		if status = 'unaudited' then
			-- we don't know the columns so we cannot start
			return status;
		end if;

		perform @extschema@.stop(tgt);
		perform @extschema@.start(tgt, info.fields);

		return @extschema@.status(tgt);

	exception
		-- you can't have this clause empty
		when division_by_zero then raise 'wat?';
	end;
end
$$;

-- Temporarily suspend a table audit
create or replace function pause(tgt regclass)
returns @extschema@.audit_status
language plpgsql
as $$
begin
	begin -- this is a transaction in PL/pgSQL
		if @extschema@.status(tgt) = 'audited' then
			execute format('alter table %s disable trigger %I',
				@extschema@._full_table_name(tgt),
				@extschema@._trg_name(tgt));
		end if;
		return @extschema@.status(tgt);
	exception
		-- you can't have this clause empty
		when division_by_zero then raise 'wat?';
	end;
end
$$;

-- Restart a previously paused audit
create or replace function restart(tgt regclass)
returns @extschema@.audit_status
language plpgsql
as $$
begin
	begin -- this is a transaction in PL/pgSQL
		if @extschema@.status(tgt) = 'paused' then
			execute format('alter table %s enable trigger %I',
				@extschema@._full_table_name(tgt),
				@extschema@._trg_name(tgt));
		end if;
		return @extschema@.status(tgt);
	exception
		-- you can't have this clause empty
		when division_by_zero then raise 'wat?';
	end;
end
$$;


-- Return detailed informations about the status of the audit pieces
create or replace function info(tgt regclass)
returns @extschema@.audit_info
language plpgsql stable
as $$
declare
	rv @extschema@.audit_info;
begin
	select r.oid
	into rv.table
	from pg_class r
	join pg_namespace ns on ns.oid = relnamespace
	where nspname = '@extschema@'
	and relname = @extschema@._audit_table_name(tgt);

	select exists (
		select 1
		from pg_proc f
		join pg_namespace ns on ns.oid = pronamespace
		where nspname = '@extschema@'
		and proname = @extschema@._fn_name(tgt)
		and prorettype = 'trigger'::regtype)
	into rv.has_function;

	select tgenabled <> 'D'
	into rv.trigger_enabled
	from pg_trigger
	where tgrelid = tgt
	and tgname = @extschema@._trg_name(tgt);

	rv.has_trigger := rv.trigger_enabled is not null;

	select array_agg(name) into rv.fields from @extschema@._field_defs(tgt);

	return rv;
end
$$;


-- Internal function to get the status from an info structure
create or replace function _status(info @extschema@.audit_info)
returns @extschema@.audit_status
language sql immutable strict
as $$
select case
	when $1.table is not null and $1.has_function and $1.has_trigger
			and $1.trigger_enabled then
		'audited'::@extschema@.audit_status
	when $1.table is not null and $1.has_function and $1.has_trigger
			and not $1.trigger_enabled then
		'paused'
	when not ($1.table is not null or $1.has_function or $1.has_trigger) then
		'unaudited'
	else
		'inconsistent'
	end;
$$;

-- Return a string with the audit status of a table
create or replace function status(tgt regclass)
returns @extschema@.audit_status
language sql stable strict
as $$
	select @extschema@._status(@extschema@.info($1));
$$;


--
-- Definitions of the fields available for audit
--

create type audit_field as (
	name name,
	expression text,
	def text);

-- Return info about all the fields available
create or replace function _field_defs()
returns setof @extschema@.audit_field
language sql immutable as $$
	select * from unnest(array[
		('id', 'default', 'bigserial'),
		('ts', 'default', 'timestamptz default now()'),
		('clock', 'default', 'timestamptz default clock_timestamp()'),
		('user', 'session_user', 'name'),
		('action', 'tg_op', 'text'),
		('schema', 'tg_table_schema', 'name'),
		('table', 'tg_table_name', 'name')
	]::@extschema@.audit_field[]);
$$;

-- Return info about a selection of audit fields
create or replace function _field_defs(names name[])
returns setof @extschema@.audit_field
language plpgsql immutable
as $$
declare
	fname name;
	field @extschema@.audit_field;
begin
	foreach fname in array names loop
		select * into field from @extschema@._field_defs() where name = fname;
		if not found then
			raise 'unknown audit field: %', fname;
		end if;
		return next field;
	end loop;
end
$$;

-- Return info about the audit fields on a table
create or replace function _field_defs(tgt regclass)
returns setof @extschema@.audit_field
language plpgsql stable
as $$
declare
	colname name;
	fields name[] := array[]::name[];
begin
	for colname in
	select attname
	from pg_attribute a
	join pg_class r on r.oid = attrelid
	join pg_namespace n on n.oid = relnamespace
	where nspname = '@extschema@'
	and relname = @extschema@._full_table_name(tgt)
	and attnum > 0 and not attisdropped
	order by attnum loop
		if colname ~ '^audit_' then
			fields := fields || regexp_replace(colname, '^audit_', '')::name;
		else
			exit;
		end if;
	end loop;

	return query select * from @extschema@._field_defs(fields);
end
$$;


--
-- Sequence of statements to implement the various commands
--

create or replace function _start_stmts(
	tgt regclass,
	audit_fields text[] default array['ts', 'action'])
returns text[]
language plpgsql stable strict
as $f$
declare
	rv text[] := array[]::text[];
	info @extschema@.audit_info;
	def1 text[];
	def2 text[];
	seq name;
begin
	if array_length(audit_fields, 1) < 1
	or array_length(audit_fields, 1) is null -- meh, empty arrays
	then
		raise 'at least one audit field required';
	end if;

	info := @extschema@.info(tgt);

	if info.has_trigger then
		rv := rv || format('drop trigger %I on %s',
			@extschema@._trg_name(tgt),
			@extschema@._full_table_name(tgt));
	end if;

	-- If the table exists, rotate it away
	rv := rv || @extschema@._rename_stmts(tgt, info);

	-- Create an empty table with the audit fields followed by the table ones
	select array_agg(format('audit_%s %s', name, def))
	into strict def1
	from @extschema@._field_defs(audit_fields);

	select array_agg(t)
	into strict def2
	from (
		select format('%I %s', a.attname,
			pg_catalog.format_type(a.atttypid, a.atttypmod)) t
		from pg_attribute a
		where attrelid = tgt
		and attnum > 0 and not attisdropped
		order by attnum) x;

	rv := rv || format(
		'create table @extschema@.%I (%s)',
		@extschema@._audit_table_name(tgt),
		array_to_string(def1 || def2, ', '));

	rv := rv || format('grant insert on table @extschema@.%I to audit',
		@extschema@._audit_table_name(tgt));

	-- Create the trigger function
	select array_agg(expression)
	into strict def1
	from @extschema@._field_defs(audit_fields);

	rv := rv || format($f2$
		create or replace function @extschema@.%I() returns trigger
		security definer language plpgsql as $$
begin
	if tg_op <> 'DELETE' then
		insert into @extschema@.%I values (%s, new.*);
		return null;
	else
		insert into @extschema@.%I values (%s, old.*);
		return null;
	end if;
end
$$
		$f2$,
		@extschema@._fn_name(tgt),
		@extschema@._audit_table_name(tgt),
		array_to_string(def1, ', '),
		@extschema@._audit_table_name(tgt),
		array_to_string(def1, ', '));

	rv := rv || format('alter function @extschema@.%I() owner to audit',
		@extschema@._fn_name(tgt));

	-- Create the trigger
	rv := rv || format($$
		create trigger %I
			after insert or update or delete on %s
			for each row execute procedure @extschema@.%I()
		$$,
		@extschema@._trg_name(tgt),
		@extschema@._full_table_name(tgt),
		@extschema@._fn_name(tgt));

	return rv;
end
$f$;

create or replace function _rename_stmts(
	tgt regclass,
	info @extschema@.audit_info)
returns text[]
language plpgsql stable
as $$
declare
	rv text[] := array[]::text[];
	rotname name;
begin
	if info.table is not null then
		rotname := (@extschema@._audit_table_name(tgt)
			|| '_'
			|| to_char(clock_timestamp(), 'YYYYMMDD_HH24MISS'))::name;
		raise notice 'existing audit table for % will be renamed to %',
			@extschema@._audit_table_name(tgt),
			format('@extschema@.%I', rotname);
		rv := rv || format(
			'alter table @extschema@.%I rename to %I',
			@extschema@._audit_table_name(tgt), rotname);
	end if;
	return rv;
end
$$;

create or replace function _stop_stmts(tgt regclass)
returns text[]
language plpgsql stable strict
as $f$
declare
	rv text[] := array[]::text[];
	info @extschema@.audit_info;
begin
	info := @extschema@.info(tgt);

	if info.has_trigger then
		rv := rv || format('drop trigger %I on %s',
			@extschema@._trg_name(tgt),
			@extschema@._full_table_name(tgt));
	end if;

	if info.has_function then
		rv := rv || format('drop function @extschema@.%I()',
			@extschema@._fn_name(tgt));
	end if;

	rv := rv || @extschema@._rename_stmts(tgt, info);

	return rv;
end
$f$;

-- Grant usage to any audit table sequence to the audit user
-- this cannot be done in _start_stmts because we don't know the name
-- of the sequences until the table is created.
create or replace function _grant_seqs(tgt regclass)
returns void
language plpgsql
as $$
declare
	seq name;
begin
	-- If audit created any sequence, grant their usage
	for seq in
		select s.relname
		from pg_class s
		join pg_depend d on s.oid = d.objid
		join pg_class r on d.refobjid = r.oid
		join pg_namespace n on r.relnamespace = n.oid
		where n.nspname = '@extschema@'
		and r.relname = @extschema@._audit_table_name(tgt)
		and s.relkind = 'S'
	loop
		execute format(
			'grant usage on sequence @extschema@.%I to audit', seq);
	end loop;
end
$$;


--
-- Functions to mess up with names
--

-- Return the namespace-qualified name of a table, possibly adding it a suffix
create or replace function _mangle_name(
	tgt regclass, suffix text default '')
returns name
language sql stable
as $$
	select format('%I.%I', nspname, relname || $2)::name
	from pg_class r
	join pg_namespace n on relnamespace = n.oid
	where r.oid = $1;
$$;

-- Return the full name of the table being audited
-- The name is fully qualified to avoid search_path troubles,
-- so it shouldn't be added to queries using %I, otherwise extra
-- quotes would be added. Just use %s: the function adds the quotes itself
-- when required.
create or replace function _full_table_name(tgt regclass)
returns name
language sql stable
as $$
	select @extschema@._mangle_name($1);
$$;

-- Return the name of the audit table for a table
-- The function name can (and will) contain special chars and
-- doesn't contain the namespace name. So it can be used as it is
-- e.g. to query pg_class, but should be used with a placeholder
-- like '@extschema@.%I' in format().
create or replace function _audit_table_name(
	tgt regclass, suffix text default '')
returns name
language sql stable
as $$
	select @extschema@._mangle_name($1, $2);
$$;

-- Return the name of the audit trigger function for a table
create or replace function _fn_name(tgt regclass)
returns name
language sql stable
as $$
	select @extschema@._mangle_name($1, '_fn');
$$;

-- Return the name of the audit trigger for a table
create or replace function _trg_name(tgt regclass)
returns name
language sql stable
as $$
	select @extschema@._mangle_name($1, '_audit_trg');
$$;

-- Go back to the original role or running `create extension` in a transaction
-- would leave the wrong `current_user`.
reset role;
