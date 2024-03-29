define schema = aud_util
define tspace = users

pro
pro IMPORTANT: 
pro This script is for installing Version 2 of the Audit Utility from scratch.
pro If you already have the existing audit utility (version 1), then do NOT
pro run this script. Please run the upgrade.sql script instead.
pro
pro Press Enter to continue with fresh install, otherwise Ctrl-C to abort
pause


pro
pro Doing some preliminary checks
pro
whenever sqlerror exit
set feedback off
begin
  if user != 'SYS' and SYS_CONTEXT('SYS_SESSION_ROLES', 'PDB_DBA') = 'FALSE' then
     raise_application_error(-20000,'You must be SYSDBA or a PDB_DBA to run this script');
  end if;
  
  if sys_context('USERENV','CON_ID') = '1' then
     raise_application_error(-20000,'Auditing is not intended for the root of a container database');
  end if;
end;
/
set feedback on
whenever sqlerror continue

pro
pro IMPORTANT #1: 
pro Have you set the SCHEMA and TSPACE variables in this script AND 
pro THE THREE CHILD SCRIPTS (audit_util_settings/audit_util_ps/audit_util_pb)?
pro If you have not then things are not going to go well
pro
pro If yes, press Enter to continue, otherwise Ctrl-C to abort
pause

pro
pro IMPORTANT #2: 
pro This script might need to be edited if you do NOT have a partitioning license
pro Look for sections marked "-- PARTITIONING" and edit accordingly
pro
pro If yes, press Enter to continue, otherwise Ctrl-C to abort
pause


pro
pro Important: We are about to DROP the &&schema schema if it exists
pro
pro Press Enter to continue, or Ctrl-C to abort
pro
pause


set verify off
pro Proceeding with SCHEMA = &&schema, TSPACE = &&tspace
set echo on
drop user &&schema cascade;
create user &&schema no authentication default tablespace &&tspace;

alter user &&schema quota unlimited on &&tspace;

grant select on dba_tables to &&schema;
grant select on dba_constraints to &&schema;
grant select on dba_tab_columns to &&schema;
grant select on dba_part_tables to &&schema;
grant select on dba_tab_partitions to &&schema;
grant select on dba_tab_cols to &&schema;
grant select on dba_objects to &&schema;

grant 
  select any table,
  create table,
  create any trigger,
  create procedure
to &&schema;

@@audit_util_settings.sql

-- PARTITIONING
--
-- If you do not have a partitioning license, comment out these lines
-- and set the "partitioning" value to N in the insert above.
--

insert into &&schema..audit_util_settings(
     table_name
    ,update_cols
    ,when_clause
    ,inserts_audited
    ,always_log_header
    ,capture_new_updates
    ,trigger_in_audit_schema
    ,partitioning
    ,bulk_bind
    ,use_context
    ,audit_lobs_on_update_always
)
values (
  '**DEFAULT**',
  null,
  null,
  'N', 
  'N', 
  'N', 
  'Y',
  'Y',   -- partitioning
  'Y',
  'Y',
  'N'
  );
commit;


create table &&schema..schema_list ( schema_name varchar2(128));

comment on table &&schema..schema_list is 'List of schemas that auditing will be allowed for'
/

create sequence &&schema..maint_seq cache 1000;

create table &&schema..maint_log ( 
  maint_seq number default on null &&schema..maint_seq.nextval, 
  tstamp timestamp, 
  msg varchar2(4000)
  ) pctfree 2;

comment on table &&schema..maint_log is 'Debugging/logging information for all audit utility operations'
/

create sequence &&schema..seq_al_id cache 5000;

create table &&schema..AUDIT_HEADER
(
  AUD$TSTAMP           TIMESTAMP(6) NOT NULL 
 ,AUD$ID               NUMBER(18)   NOT NULL 
 ,TABLE_NAME           VARCHAR2(128) NOT NULL 
 ,DML                  VARCHAR2(1)  NOT NULL
 ,DESCR                VARCHAR2(100)
 ,ACTION               VARCHAR2(64)
 ,CLIENT_ID            VARCHAR2(64)
 ,HOST                 VARCHAR2(64)
 ,MODULE               VARCHAR2(64)
 ,OS_USER              VARCHAR2(128) 
) 
--
-- PARTITIONING
--
-- If you do not have a partitioning license, comment out these lines
-- and set the "partitioning" value to N in the insert above.
--
partition by range ( aud$tstamp  ) 
interval (numtoyminterval(1,'MONTH'))
( partition SYS_P000 values less than ( to_timestamp('20200101','yyyymmdd') )
) 
pctfree 1 tablespace &&tspace;

comment on table &&schema..AUDIT_HEADER is 'Consolidated list of all audit entries to all tables';

comment on column &&schema..AUDIT_HEADER.AUD$TSTAMP is 'When action occurred';
comment on column &&schema..AUDIT_HEADER.AUD$ID     is 'Increasing sequence ID';
comment on column &&schema..AUDIT_HEADER.TABLE_NAME is 'Table where the action occurred';
comment on column &&schema..AUDIT_HEADER.DML        is 'The DML, I=insert, U=update, D=delete';
comment on column &&schema..AUDIT_HEADER.DESCR      is 'Long form version of the DML plus logical delete handling if so nominated';
comment on column &&schema..AUDIT_HEADER.ACTION     is 'Whatever was contained in SYS_CONTEXT-USERENV-ACTION';
comment on column &&schema..AUDIT_HEADER.CLIENT_ID  is 'Whatever was contained in SYS_CONTEXT-USERENV-CLIENT_ID';
comment on column &&schema..AUDIT_HEADER.HOST       is 'Whatever was contained in SYS_CONTEXT-USERENV-HOST';
comment on column &&schema..AUDIT_HEADER.MODULE     is 'Whatever was contained in SYS_CONTEXT-USERENV-MODULE';
comment on column &&schema..AUDIT_HEADER.OS_USER    is 'Whatever was contained in SYS_CONTEXT-USERENV-OS_USER';


alter table &&schema..AUDIT_HEADER add constraint AUDIT_HEADER_PK
  primary key ( AUD$TSTAMP, AUD$ID) using index local
/  


--

@@audit_pkg.sql

--
-- Ability to selectively disable a trigger within a session if you have data maintenance needs
-- avoids the need to take an outage just because you want to not have the trigger fire.
--
-- Clearly, you might want to look at either not using this (if you want to force audit ALL the time)
-- or perhaps adding some sort of authentication etc to ensure people don't go around selectively
-- turning off the audit.
--

--
-- You can do this with a package or with a context, and you control this with the 'use_context' 
-- default setting.  If you're not using contexts, then you can ignore any error you get trying to
-- create this context
--
create context TRIGGER_CTL using &&schema..TRIGGER_CTL;

create or replace
package &&schema..trigger_ctl is
  procedure maintenance_on(p_trigger varchar2);
  procedure maintenance_off(p_trigger varchar2);
  function  enabled(p_trigger varchar2) return boolean;
end;
/

create or replace
package body &&schema..trigger_ctl is

  type trig_list is table of int
   index by varchar2(128);

  t trig_list;

  procedure maintenance_on(p_trigger varchar2) is
  begin
    --
    -- Seriously - if you have 200k tables, its time to take a long hard look at yourself :-)
    --
    if t.count > 200000 then
       raise_application_error(-20000,'This looks like an attempt to destroy your PGA');
    end if;
    t(upper(p_trigger)) := 1;
    
    --
    -- Comment this out if you don't want to use a context at all
    --
    dbms_session.set_context('TRIGGER_CTL',upper(p_trigger),'Y');
  end;
  
  procedure maintenance_off(p_trigger varchar2) is
  begin
    if t.exists(p_trigger) then
       t.delete(p_trigger);
        --
        -- Comment this out if you don't want to use a context at all
        --
       dbms_session.set_context('TRIGGER_CTL',upper(p_trigger),'');
    end if;
  end;
  
  function  enabled(p_trigger varchar2) return boolean is
  begin
    return not t.exists(p_trigger);
  end;

end;
/
  
--
-- Now we create the main package
--
set echo off
@@audit_util_ps.sql
@@audit_util_pb.sql

set lines 120
col object_name format a40

pro
pro Listing obects and their status in &&schema schema
pro
pro Anything not VALID indicates an installation failure
pro

select object_name, object_type, status
from dba_objects
where owner = upper('&&schema.');
