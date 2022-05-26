define schema = 'AUD_UTIL'


pro
pro IMPORTANT: 
pro This script is for upgrading from Version 1 to Version 2 of the Audit Utility.
pro For a clean installation from scratch run audit_util_setup.sql instead
pro
pro Press Enter to continue with upgrade, otherwise Ctrl-C to abort
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
pro Have you set the SCHEMA variable in this script AND 
pro THE THREE CHILD SCRIPTS (audit_util_settings/audit_util_ps/audit_util_pb)?
pro If you have not then things are not going to go well
pro
pro If yes, press Enter to continue, otherwise Ctrl-C to abort
pause

set echo on
@@audit_util_settings.sql
set echo off

pro
pro  Examinging existing installed package to obtain defaults for the
pro  various global variables (that now become entries in AUDIT_UTIL_SETTINGS)
pro


set echo on
set serverout on
declare
  g_inserts_audited             varchar2(1) := 'N';
  g_always_log_header           varchar2(1) := 'N';
  g_capture_new_updates         varchar2(1) := 'N';
  g_trigger_in_audit_schema     varchar2(1) := 'Y';
  g_partitioning                varchar2(1) := 'Y';
  g_bulk_bind                   varchar2(1) := 'Y';
  g_use_context                 varchar2(1) := 'Y';
  g_audit_lobs_on_update_always varchar2(1) := 'N';
  
  c_default varchar2(20) := '**DEFAULT**';

begin
  for i in (
    select lower(text) txt
    from dba_source
    where name = 'AUDIT_UTIL'
    and  owner = upper('&&schema')
    and text not like '--%'
    and type = 'PACKAGE BODY'
    and ltrim(text) like 'g\_%' escape '\'
    and ( lower(text) like '%true%' or lower(text)  like '%false%' )
  )
  loop
     if instr(i.txt,'g_inserts_audited') > 0 then
       g_inserts_audited := 
         case 
           when i.txt like '%true%' then 'Y' 
           when i.txt like '%false%' then 'N' 
         end;
     elsif instr(i.txt,'g_always_log_header') > 0 then
       g_always_log_header := 
         case 
           when i.txt like '%true%' then 'Y' 
           when i.txt like '%false%' then 'N' 
         end;
     elsif instr(i.txt,'g_capture_new_updates') > 0 then
       g_capture_new_updates := 
         case 
           when i.txt like '%true%' then 'Y' 
           when i.txt like '%false%' then 'N' 
         end;
     elsif instr(i.txt,'g_trigger_in_audit_schema') > 0 then
       g_trigger_in_audit_schema := 
         case 
           when i.txt like '%true%' then 'Y' 
           when i.txt like '%false%' then 'N' 
         end;
     elsif instr(i.txt,'g_partitioning') > 0 then
       g_partitioning := 
         case 
           when i.txt like '%true%' then 'Y' 
           when i.txt like '%false%' then 'N' 
         end;
     elsif instr(i.txt,'g_bulk_bind') > 0 then
       g_bulk_bind := 
         case 
           when i.txt like '%true%' then 'Y' 
           when i.txt like '%false%' then 'N' 
         end;
     elsif instr(i.txt,'g_use_context') > 0 then
       g_use_context := 
         case 
           when i.txt like '%true%' then 'Y' 
           when i.txt like '%false%' then 'N' 
         end;
     elsif instr(i.txt,'g_audit_lobs_on_update_always') > 0 then
       g_audit_lobs_on_update_always := 
         case 
           when i.txt like '%true%' then 'Y' 
           when i.txt like '%false%' then 'N' 
         end;
     end if;
   end loop;

  dbms_output.put_line('Using V1 settings as below:');
  dbms_output.put_line('g_inserts_audited             = '||g_inserts_audited);
  dbms_output.put_line('g_always_log_header           = '||g_always_log_header);
  dbms_output.put_line('g_capture_new_updates         = '||g_capture_new_updates);
  dbms_output.put_line('g_trigger_in_audit_schema     = '||g_trigger_in_audit_schema);
  dbms_output.put_line('g_partitioning                = '||g_partitioning);
  dbms_output.put_line('g_bulk_bind                   = '||g_bulk_bind);
  dbms_output.put_line('g_use_context                 = '||g_use_context);
  dbms_output.put_line('g_audit_lobs_on_update_always = '||g_audit_lobs_on_update_always);

  delete &&schema..audit_util_settings
  where table_name = c_default;
  
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
    ,audit_lobs_on_update_always)
  values 
  (  c_default
    ,null
    ,null
    ,g_inserts_audited
    ,g_always_log_header
    ,g_capture_new_updates
    ,g_trigger_in_audit_schema
    ,g_partitioning
    ,g_bulk_bind
    ,g_use_context
    ,g_audit_lobs_on_update_always
  );
  dbms_output.put_line('Loaded default settings');

  insert into &&schema..audit_util_settings
  select 
     t.table_name
    ,u.update_cols
    ,u.when_clause
    ,g_inserts_audited
    ,g_always_log_header
    ,g_capture_new_updates
    ,g_trigger_in_audit_schema
    ,g_partitioning
    ,g_bulk_bind
    ,g_use_context
    ,g_audit_lobs_on_update_always    
  from dba_tables t,
       &&schema..audit_util_settings u
  where t.owner = upper('&&schema')
  and   t.table_name = u.table_name(+)
  and   t.table_name not in (
           'AUDIT_UTIL_UPDATE_TRIG'
          ,'SCHEMA_LIST'
          ,'MAINT_LOG'
          ,'AUDIT_UTIL_SETTINGS'
          ,'AUDIT_HEADER');
  dbms_output.put_line('Loaded '||sql%rowcount||' existing table settings');
end;
/
set echo off


pro 
pro Migration of settings attempted, but not yet committed.
pro Here is what we ended up with.
pro
set echo on
select *
from   &&schema..audit_util_settings
order by 1;
set echo off

pro
pro If that's OK, then press Enter to commit, or Ctrl-C to abort now
pro
pause
commit;


pro
pro Upgrading the database packages
pro

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


