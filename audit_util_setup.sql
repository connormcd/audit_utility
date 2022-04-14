define schema = aud_util
define tspace = users

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
pro IMPORTANT: 
pro Have you set the SCHEMA and TSPACE variables in this script AND 
pro the two child scripts (audit_util_ps/audit_util_pb)? If you have not
pro then things are not going to go well
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

create table &&schema..audit_util_update_trig (
  table_name             varchar2(128)  not null,
  update_cols            varchar2(4000),
  when_clause            varchar2(4000),
  constraint audit_util_update_cols_chk01  check (table_name = upper(table_name)),
  constraint audit_util_update_cols_chk02  check (update_cols=upper(update_cols)),
  constraint audit_util_update_cols_chk03  check (regexp_like(update_cols,'^(\w{1,90},){0,20}\w{1,90}$')),
  constraint audit_util_update_cols_chk04  check ( upper(when_clause) like 'WHEN%'),
  constraint audit_util_update_cols_pk primary key (table_name)
  )
  pctfree 2
/


comment on table &&schema..audit_util_update_trig is 'Allows custom triggering for individual audit tables';
comment on column &&schema..audit_util_update_trig.table_name  is 'Audit TABLE_NAME in data dictionary';
comment on column &&schema..audit_util_update_trig.update_cols  is 'col1,col2,col3,...';

grant select on &&schema..audit_util_update_trig to select_catalog_role
/


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

create sequence &&schema..seq_al_id cache 1000;

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
-- If you do not have a partitioning license, comment out these lines
-- and set the "g_partitioning" variable to false in the package body
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
-- Common routine to capture the audit header information for every audit action. Called from all auditing triggers.
--

create or replace
package &&schema..audit_pkg is

  procedure bulk_init;
  procedure bulk_process;
  
  procedure log_header_bulk(
    p_table_name      varchar2,
    p_dml             varchar2,
    p_descr           varchar2,
    p_timestamp   out timestamp,
    p_al_id       out number);

  procedure log_header(
    p_table_name      varchar2,
    p_dml             varchar2,
    p_descr           varchar2,
    p_timestamp   out timestamp,
    p_al_id       out number);
end;
/


create or replace
package body &&schema..audit_pkg is

  type t_audit_rows is table of audit_header%rowtype
    index by pls_integer;
  
  l_headers t_audit_rows;

  g_bulk_bind_limit constant int := 500;

  procedure bulk_init is
  begin
    l_headers.delete;
  end;
  
  procedure bulk_process is
  begin
    forall i in 1 .. l_headers.count
      insert into audit_header values l_headers(i);
    bulk_init;
  end;
  
  procedure log_header_bulk(
        p_table_name      varchar2,
        p_dml             varchar2,
        p_descr           varchar2,
        p_timestamp   out timestamp,
        p_al_id       out number) is
    l_idx pls_integer := l_headers.count+1;  
  begin
    if l_idx > g_bulk_bind_limit then
      bulk_process;
      l_idx := 1;
    end if;
  
    l_headers(l_idx).aud$tstamp := systimestamp;
    l_headers(l_idx).aud$id     := seq_al_id.nextval;
    l_headers(l_idx).table_name := p_table_name;
    l_headers(l_idx).dml        := p_dml;
    l_headers(l_idx).descr      := p_descr;
    l_headers(l_idx).action     := sys_context('userenv','action');
    l_headers(l_idx).client_id  := sys_context('userenv','client_identifier');
    l_headers(l_idx).host       := sys_context('userenv','host');
    l_headers(l_idx).module     := sys_context('userenv','module');
    l_headers(l_idx).os_user    := sys_context('userenv','os_user') ;
    
    p_timestamp := l_headers(l_idx).aud$tstamp;
    p_al_id     := l_headers(l_idx).aud$id ;

  end;

  procedure log_header(
    p_table_name      varchar2,
    p_dml             varchar2,
    p_descr           varchar2,
    p_timestamp   out timestamp,
    p_al_id       out number) is
  begin
    insert into audit_header 
      ( aud$tstamp   
       ,aud$id       
       ,table_name  
       ,dml
       ,descr
       ,action      
       ,client_id   
       ,host        
       ,module      
       ,os_user )    
    values (
      systimestamp
     ,seq_al_id.nextval
     ,p_table_name
     ,p_dml
     ,p_descr
     ,sys_context('userenv','action')
     ,sys_context('userenv','client_identifier')
     ,sys_context('userenv','host')
     ,sys_context('userenv','module')
     ,sys_context('userenv','os_user')
    )
    returning AUD$TSTAMP, AUD$ID
    into p_timestamp, p_al_id;
  end;

    
end;
/
  

--
-- Ability to selectively disable a trigger within a session if you have data maintenance needs
-- avoids the need to take an outage just because you want to not have the trigger fire.
--
-- Clearly, you might want to look at either not using this (if you want to force audit ALL the time)
-- or perhaps adding some sort of authentication etc to ensure people don't go around selectively
-- turning off the audit.
--

--
-- You can do this with a package or with a context, and you control this with the g_use_context 
-- variable in the package body
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
    
    dbms_session.set_context('TRIGGER_CTL',upper(p_trigger),'Y');
  end;
  
  procedure maintenance_off(p_trigger varchar2) is
  begin
    if t.exists(p_trigger) then
       t.delete(p_trigger);
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
