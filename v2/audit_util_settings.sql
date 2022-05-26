define schema = 'AUD_UTIL'

drop table &&schema..audit_util_settings purge;

create table &&schema..audit_util_settings (
  table_name                  varchar2(128)  not null,
  update_cols                 varchar2(4000),
  when_clause                 varchar2(4000),
  inserts_audited             varchar2(1),
  always_log_header           varchar2(1),
  capture_new_updates         varchar2(1),
  trigger_in_audit_schema     varchar2(1),
  partitioning                varchar2(1),
  bulk_bind                   varchar2(1),
  use_context                 varchar2(1),
  audit_lobs_on_update_always varchar2(1),
  constraint audit_util_settings_chk01  check (table_name = upper(table_name)),
  constraint audit_util_settings_chk02  check (update_cols=upper(update_cols)),
  constraint audit_util_settings_chk03  check (regexp_like(update_cols,'^(\w{1,90},){0,20}\w{1,90}$')),
  constraint audit_util_settings_chk04  check ( upper(when_clause) like 'WHEN%'),
  constraint audit_util_settings_chk05  check ( table_name not like '**%' or table_name = '**DEFAULT**' ),
  --
  constraint audit_util_settings_chk06  check ( inserts_audited in ('Y','N') ),
  constraint audit_util_settings_chk07  check ( always_log_header in ('Y','N') ),
  constraint audit_util_settings_chk08  check ( capture_new_updates in ('Y','N') ),
  constraint audit_util_settings_chk09  check ( trigger_in_audit_schema in ('Y','N') ),
  constraint audit_util_settings_chk10  check ( partitioning in ('Y','N') ),
  constraint audit_util_settings_chk11  check ( bulk_bind in ('Y','N') ),
  constraint audit_util_settings_chk12  check ( use_context in ('Y','N') ),
  constraint audit_util_settings_chk13  check ( audit_lobs_on_update_always in ('Y','N') ),
  --
  constraint audit_util_settings_pk primary key (table_name)
  )
  pctfree 2
/



comment on table  &&schema..audit_util_settings is 'Allows custom settings for individual audit tables, table name of **DEFAULT** is for global defaults';
comment on column &&schema..audit_util_settings.table_name  is 'Audit TABLE_NAME in data dictionary';
comment on column &&schema..audit_util_settings.update_cols  is 'col1,col2,col3,...';
comment on column &&schema..audit_util_settings.when_clause  is 'optional trigger conditional firing clause';

comment on column &&schema..audit_util_settings.inserts_audited             is 'whether we audit just updates/deletes or inserts as well';
comment on column &&schema..audit_util_settings.always_log_header           is 'even if inserts are off, do we keep the header';
comment on column &&schema..audit_util_settings.capture_new_updates         is 'whether we want to capture OLD images for updates as well as NEW';
comment on column &&schema..audit_util_settings.trigger_in_audit_schema     is 'where we should create the trigger (Y=audit schema, N=table owning schema)';
comment on column &&schema..audit_util_settings.partitioning                is 'should we use partitioning';
comment on column &&schema..audit_util_settings.bulk_bind                   is 'should we use bulk binding (aka, are you expecting batch DML regularly)';
comment on column &&schema..audit_util_settings.use_context                 is 'should we use a context/WHEN clause or a plsql call for trigger maintenance';
comment on column &&schema..audit_util_settings.audit_lobs_on_update_always is 'should we log CLOB/BLOB if unchanged in an update';


grant select on &&schema..audit_util_settings to select_catalog_role
/

  