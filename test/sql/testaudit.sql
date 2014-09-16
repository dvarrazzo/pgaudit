SET client_min_messages = warning;

\set ECHO none
create schema testaudit;
create extension pgaudit with schema testaudit;
\set ECHO all

-- compact output
\t
\a

-- create an unprivileged test user
do language plpgsql $$
begin
	declare
		super bool;
	begin
		create user dumbuser nosuperuser;
	exception when duplicate_object then
		null;
	end;
end
$$;

create table test(id serial primary key, data text);
grant select, insert, update, delete on table test to dumbuser;
grant usage on sequence test_id_seq to dumbuser;

-- Default logging has tx and action fields
select testaudit.start('test');

set role dumbuser;
\t
select * from testaudit.info('test');
\t
insert into test (data) values ('aaa');
update test set data = 'bbb' where id = 1;
delete from test where id = 1;
reset role;

select count(*) from testaudit."public.test"
where now() - '5 seconds'::interval < audit_ts and audit_ts < now();
select audit_action, id, data from testaudit."public.test" order by audit_ts;

-- Can pause and resume auditing
select testaudit.pause('test');

set role dumbuser;
select * from testaudit.info('test');
insert into test (data) values ('ccc');
reset role;
select audit_action, id, data from testaudit."public.test"
order by audit_ts;

select testaudit.restart('test');
set role dumbuser;
select * from testaudit.info('test');
insert into test (data) values ('ddd');
reset role;
select audit_action, id, data from testaudit."public.test"
order by audit_ts;

-- Can't access by default
set role dumbuser;
select 1 from testaudit."public.test";
insert into testaudit."public.test" values (now(), 'INSERT', 100, 'hack');
delete from testaudit."public.test";
drop table testaudit."public.test";
reset role;

-- Calling start with the same arguments doesn't rename the audit table
select count(*) from testaudit."public.test";
select testaudit.start('test');
select count(*) from testaudit."public.test";
select count(*)
from pg_class c join pg_namespace n on n.oid = relnamespace
where nspname = 'testaudit' and relname ~ '^public.test_';

-- But changing the arguments will result in a rename and new table creation
select testaudit.start('test', '{clock,action}'::text[]);
select count(*) from testaudit."public.test";
select count(*)
from pg_class c join pg_namespace n on n.oid = relnamespace
where nspname = 'testaudit' and relname ~ '^public.test_';

-- Stop auditing
select pg_sleep(1);		-- conflict on rename
select testaudit.stop('test');
select * from testaudit.info('test');
insert into test (data) values ('eee');

-- The audit table has been renamed away
select count(*)
from pg_class c join pg_namespace n on n.oid = relnamespace
where nspname = 'testaudit' and relname ~ '^public.test_';

-- Rotate works as expected
create table rot(data int);
select testaudit.rotate('rot');
select testaudit.start('rot', '{id,action}'::text[]);
insert into rot values (10);
select * from testaudit."public.rot" order by data;
select pg_sleep(1);		-- conflict on rename
alter table rot add moredata int;
select testaudit.rotate('rot');
select count(*)
from pg_class c join pg_namespace n on n.oid = relnamespace
where nspname = 'testaudit' and relname ~ '^public.rot_';
insert into rot values (20, 30);
select * from testaudit."public.rot" order by data;

-- Recover from inconsistent
drop trigger "public.rot_audit_trg" on rot;
select testaudit.status('rot');
select pg_sleep(1);		-- conflict on rename
select testaudit.rotate('rot');
select count(*)
from pg_class c join pg_namespace n on n.oid = relnamespace
where nspname = 'testaudit' and relname ~ '^public.rot_';
select * from testaudit.info('rot');

-- Everything should work with problematic names
create schema "some-schema";
create table "some-schema"."some.table" ("some|field" integer);
select testaudit.start('"some-schema"."some.table"', '{id,action,table}');
select * from testaudit.info('"some-schema"."some.table"');
insert into "some-schema"."some.table" values (10);
insert into "some-schema"."some.table" values (11);
update "some-schema"."some.table" set "some|field" = 20 where "some|field" = 10;
select audit_id, audit_action, audit_table, "some|field"
from testaudit."""some-schema"".""some.table"""
order by audit_id;

-- Sequences get mangled names after stop/start: do we still grant them ok?
create table tseq(data int);
select testaudit.start('tseq', '{id}'::text[]);
insert into tseq values (10);
select testaudit.stop('tseq');
select testaudit.start('tseq', '{id}'::text[]);
insert into tseq values (11);
select * from testaudit."public.tseq" order by audit_id;

-- Can audit other fields, but not everything
create table test2 (data integer);
select testaudit.status('test2');
\set VERBOSITY terse
select testaudit.start('test2', '{foo}'::text[]);
\set VERBOSITY default
select testaudit.status('test2');
select testaudit.start('test2', '{id,ts,clock,user,action,schema,table}'::text[]);
select testaudit.status('test2');
begin;
insert into test2 values (10);
select
	audit_ts = now(),
	audit_clock > now(),
	audit_clock < clock_timestamp(),
	audit_user = current_user,
	audit_id, audit_action, audit_schema, audit_table
	from testaudit."public.test2";
commit;

-- Dropping the extension audit should continue no problem
-- (at least it shouldn't fail dml)
drop extension pgaudit;
insert into "some-schema"."some.table" values (30);
select count(*) from testaudit."""some-schema"".""some.table""";

-- Clear up for next tests
drop table test;
drop table rot;
drop table "some-schema"."some.table";
drop table tseq;
drop table test2;
drop schema "some-schema";
