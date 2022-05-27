Audit trigger/package generator for Oracle tables VERSION 2

Fundamental Changes
===================
In version 1, the various audit generation options were burnt into the code, so if you want to (say) capture inserts for auditing tables, then every table you audited was going to have that facility. The only really table-level options you had were for the triggers (the WHEN clause and the UPDATE columns). In this new version, those settings are persisted on a table by table basis in a new table AUDIT_UTIL_SETTINGS

    SQL> desc AUD_UTIL.AUDIT_UTIL_SETTINGS
     Name                          Null?    Type
     ----------------------------- -------- --------------------
     TABLE_NAME                    NOT NULL VARCHAR2(128)
     UPDATE_COLS                            VARCHAR2(4000)
     WHEN_CLAUSE                            VARCHAR2(4000)
     INSERTS_AUDITED                        VARCHAR2(1)
     ALWAYS_LOG_HEADER                      VARCHAR2(1)
     CAPTURE_NEW_UPDATES                    VARCHAR2(1)
     TRIGGER_IN_AUDIT_SCHEMA                VARCHAR2(1)
     PARTITIONING                           VARCHAR2(1)
     BULK_BIND                              VARCHAR2(1)
     USE_CONTEXT                            VARCHAR2(1)
     AUDIT_LOBS_ON_UPDATE_ALWAYS            VARCHAR2(1)

The default settings for the entire installation are stored in a special row in this table, with a table name of '\*\*DEFAULT\*\*'. This is created when you run the upgrade script.

Also new is a generic audit history query. In the generated package for each table, a new routine SHOW_HISTORY will be added, allowing you to get JSON representation of the audit information for a table for a given date range. For example, for typical SCOTT.EMP table, you'll get a routine like:

     function show_history(
        p_aud$tstamp_from  timestamp default localtimestamp - numtodsinterval(7,'DAY')
       ,p_aud$tstamp_to    timestamp default localtimestamp
       ,p_aud$id           number    default null
       ,p_aud$image        varchar2  default null
       ,p_empno            number    default null
       ,p_ename            varchar2  default null
       ,p_job              varchar2  default null
       ,p_mgr              number    default null
       ,p_hiredate         date      default null
       ,p_sal              number    default null
       ,p_comm             number    default null
       ,p_deptno           number    default null
     ) return clob;

The clob returned is a JSON array of all audit entries captured for that table, including the metadata from AUDIT_HEADER for any predicates passed. Timestamps are converted to UTC.

Installation/Upgrade
====================
As before, ensure that you edit each file to nominate the schema and tablespace you want to use. Needs to be run as SYSDBA or a PDB_DBA on autonomous. The script will check before proceeeding.

For a brand new installation, run:

    @audit_util_setup.sql

And for an upgrade from version 1 of the utility, run:

    @upgrade.sql
    
The upgrade will attempt to find the existing code base to identify what defaults you used, and load them into AUDIT_UTIL_SETTINGS, and will also look for any existing audit tables in your audit schema, and load them into the AUDIT_UTIL_SETTINGS table as well. If you modified the audit_code package code on a table-by-table basis in the past, then you would need to explicitly call GENERATE_AUDIT_SUPPORT for each table, with the settings you want to store the correct settings.

Functionality/Usage
===================
All the existing functionality and API calls remain the same, and thus any scripts you already had in place should continue to work unchanged. See the root level README for all the details on the APIs and example usage.  Only the GENERATE_AUDIT_SUPPORT has been extended. An existing call works as before:

    SQL> begin
      2     aud_util.audit_util.generate_audit_support('SCOTT','EMP',
      3        p_action=>'EXECUTE');
      4  end;

But the API can now also be called with the explicit options you want for this table, eg

    SQL> begin
      2   aud_util.audit_util.generate_audit_support('SCOTT','EMP',
      3     p_action=>'EXECUTE',
      4     p_update_cols                 =>'',
      5     p_when_clause                 =>'',
      6     p_inserts_audited             =>'',
      7     p_always_log_header           =>'',
      8     p_capture_new_updates         =>'',
      9     p_trigger_in_audit_schema     =>'',
     10     p_partitioning                =>'',
     11     p_bulk_bind                   =>'',
     12     p_use_context                 =>'',
     13     p_audit_lobs_on_update_always =>''
     14    );
     15  end;

The parameters P_UPDATE_COLS and P_WHEN_CLAUSE operate as before in they control the conditions under which the auditing trigger will fire. The other parameters can take a Y or N value to indicate whether you want to use (or not use) the facility that they control.  See the root README for each of these flags and the behaviour they control.

Passing null (or omitting the parameter) means preserve whatever setting previously existed for this table. If this is a first call to audit generation for this table, then a null will mean use the default system-wide settings for the installation.

Passing the string NULL for a parameter means clear the value for this table, and hence pick up the system wide default. Some examples:

    SQL> begin
      2     aud_util.audit_util.generate_audit_support('SCOTT','EMP',
      3        p_action=>'EXECUTE');
      4  end;
      
For a first time call, we will pick up the system-wide defaults and use them for SCOTT.EMP

    SQL> begin
      2   aud_util.audit_util.generate_audit_support('SCOTT','EMP',
      3     p_action=>'EXECUTE',
      4     p_inserts_audited             =>'Y',
      5     p_bulk_bind                   =>'N',
      6    );
      7  end;

will regenerate the audit package/trigger for SCOTT.EMP to additional audit INSERT commands and no longer use bulk binding.

    SQL> begin
      2     aud_util.audit_util.generate_audit_support('SCOTT','EMP',
      3        p_action=>'EXECUTE');
      4  end;

will now continue to audit INSERT commands and not use bulk binding because these preferences are saved.

    SQL> begin
      2   aud_util.audit_util.generate_audit_support('SCOTT','EMP',
      3     p_action=>'EXECUTE',
      4     p_inserts_audited             =>'NULL',
      5    );
      6  end;

will revert the auditing of INSERT commands to the system-wide default. This *might* still be to audit INSERT, but it is no longer bound to the table.


Additionally, there is one new API to set the system-wide defaults:

    SQL> begin
      2   aud_util.audit_util.set_defaults(
      3     p_update_cols                 =>'',
      4     p_when_clause                 =>'',
      5     p_inserts_audited             =>'N',
      6     p_always_log_header           =>'',
      7     p_capture_new_updates         =>'',
      8     p_trigger_in_audit_schema     =>'',
      9     p_partitioning                =>'',
     10     p_bulk_bind                   =>'',
     11     p_use_context                 =>'',
     12     p_audit_lobs_on_update_always =>''
     13    );
     14  end;

which has the same usage semantics, namely Y or N to set a value, the string NULL to clear UPDATE_COLS or WHEN_CLAUSE, and null to leave a setting unchanged. Changing the defaults does not alter the auditing for any existing tables but if you re-generate audit support AND those tables were using defaults, then they will pick up the new settings.

*Same schema support coming soon*

Your Usage Rights
=================
Whilst I've done plenty of testing, responsibilty for correctness on your own environment lies with you. There are boundary cases where you could break it. For example, throw in some 120 character table names combined column names and you might have problems. Similarly, the routines have no handling for mixed case dictionary names - you're on your own there. Having said that, I have no interest in licensing the code etc, so you are free to use, copy, modify etc with no implied ownership of my own, or any attribution required. If you get some value out of it, just pop a "Thanks" on Twitter to @connor_mc_d and that's cool.
