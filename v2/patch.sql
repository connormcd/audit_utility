define schema = 'AUD_UTIL'

set echo off
@@audit_util_ps.sql
@@audit_util_pb.sql


set echo on
alter table &&schema..audit_util_settings add   base_owner                  varchar2(128);
alter table &&schema..audit_util_settings add   base_table                  varchar2(128);

alter table &&schema..audit_util_settings add   constraint audit_util_settings_chk14  check (base_owner = upper(base_owner));
alter table &&schema..audit_util_settings add   constraint audit_util_settings_chk15  check (base_table = upper(base_table));

comment on column &&schema..audit_util_settings.base_owner  is 'Owner of the table on which audit was created';
comment on column &&schema..audit_util_settings.base_table  is 'Table on which audit was created';

create index &&schema..audit_util_settings_ix on &&schema..audit_util_settings ( base_owner,base_table);

set echo off
pro 
pro Back fitting OWNER/TABLE_NAME to AUDIT_UTIL_SETTINGS
pro

set serverout on
declare
  tname  varchar2(128);
  towner varchar2(128);
  cnt    int;
begin
  for i in ( select * from &&schema..audit_util_settings
             where  table_name != '**DEFAULT**' ) 
  loop
    select max(table_name), max(owner), count(*)
    into   tname, towner, cnt
    from   dba_tables
    where  owner in ( select schema_name from &&schema..schema_list )
    and    table_name = i.table_name;

    if cnt = 1 then
      update &&schema..audit_util_settings
      set    base_owner = towner,
             base_table = tname
      where  table_name = i.table_name;

      if sql%rowcount != 1 then
        raise_application_error(-20378,'Something went very wrong here');
      end if;
      dbms_output.put_line('Set base owner/tablename for '||i.table_name||' to '||towner||'.'||tname);
    else
      dbms_output.put_line('Multiple potential tables for audit table '||i.table_name||'. Please use AUDIT_UTIL.FIX_AUDIT_SETTINGS manually');
    end if;
  end loop;
end;
/

pro 
pro Correction of settings attempted, but not yet committed.
pro Here is what we ended up with.
pro
set echo on
select table_name, base_owner, base_table
from   &&schema..audit_util_settings
where  table_name != '**DEFAULT**' 
order by 1;
set echo off

pro
pro If that's OK, then press Enter to commit, or Ctrl-C to abort now
pro
pause
commit;


 


