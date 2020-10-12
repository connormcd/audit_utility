Audit trigger/package generator for Oracle tables


Installation
============
    @audit_util_setup.sql
    @audit_util_ps.sql
    @audit_utl_pb.sql

Ensure you edit each file to nominate the schema and tablespace you want to use. Needs to be run as DBA (naturally).

Functionality
================
The generator allows

- A dedicated audit table for each table to be audited 
- A consolidated view of all audit actions undertaken 
- Not having to write a lot of code to implement auditing - it should be generated for me 
- API level control over whether to capture inserts, and whether to capture both OLD/NEW updates or just OLD (because the current table values always contain the NEW) 
- The ability to selectively disable/enable the trigger for a session (for example, for data maintenance) without impacting other sessions 
- Handle things like new columns to the source table etc.

Under the Covers
=================
The common metadata for all captured changes goes into a table called AUDIT_HEADER. I won't describe what each column is here, because in perhaps what is the last example you'll see anywhere of someone using the database dictionary for what it is designed for, I have added COMMENT commands for all the tables and columns.  I always lament the sad state of affairs when people say "We don't have a place to document our database schema...".  Er, um, yes you do .. it's called (drum roll for impact.....) the database!

    SQL> desc AUD_UTIL.AUDIT_HEADER

     Name                          Null?    Type
     ----------------------------- -------- ------------------
     AUD$TSTAMP                    NOT NULL TIMESTAMP(6)
     AUD$ID                        NOT NULL NUMBER(18)
     TABLE_NAME                    NOT NULL VARCHAR2(30)
     DML                           NOT NULL VARCHAR2(1)
     DESCR                                  VARCHAR2(100)
     ACTION                                 VARCHAR2(32)
     CLIENT_ID                              VARCHAR2(64)
     HOST                                   VARCHAR2(64)
     MODULE                                 VARCHAR2(48)
     OS_USER                                VARCHAR2(32)


Every table for which you activate auditing for when then have its own table which is a logical child of the AUDIT_HEADER table. I say logical child because I am not explicitly nominating a foreign key here. Feel free to add it if you like, but by default, I don't do it because no-one should be doing DML against these tables except via the API that is automatically generated.

Each audit table is the table name suffixed with the schema (because multiple schemas with potentially the same table names will have their audit captured into a single auditing schema, which is AUD_UTIL by default, but you can change this simply by editing the 'schema' substitution variable at the top of each script.


    SQL> desc AUD_UTIL.EMP_SCOTT

     Name                          Null?    Type
     ----------------------------- -------- -----------------
     AUD$TSTAMP                    NOT NULL TIMESTAMP(6)
     AUD$ID                        NOT NULL NUMBER(18)
     AUD$IMAGE                     NOT NULL VARCHAR2(3)
     EMPNO                                  NUMBER(4)
     ENAME                                  VARCHAR2(10)
     JOB                                    VARCHAR2(9)
     MGR                                    NUMBER(4)
     HIREDATE                               DATE
     SAL                                    NUMBER(7,2)
     COMM                                   NUMBER(7,2)
     DEPTNO                                 NUMBER(2)

 
The child audit tables will contain the same columns as the source table name, but with three additional columns 

- AUD$TSTAMP, AUD$ID which are logical link back to the parent AUDIT_HEADER record 
- AUD$IMAGE which is "OLD" or "NEW" aligning to the triggering values

Sample Usage
============

Any API call that is "destructive", namely, could run DDL has an "action" parameter that is OUTPUT or EXECUTE.

Every API call to modify the auditing is captured in a MAINT_LOG table so you can blame the appropriate people have a history of the auditing API calls you have made. But first, we need to let the code know which schemas we will allow to be audited. Only the schemas nominated in the table SCHEMA_LIST can have auditing enabled, and by default it is empty, so you'll get an error on any attempt to use the API

    SQL> exec  aud_util.audit_util.generate_audit_table('SCOTT','EMP',p_action=>'OUTPUT');

    Call to generate audit table for SCOTT.EMP

    BEGIN aud_util.audit_util.generate_audit_table('SCOTT','EMP',p_action=>'OUTPUT'); END;

    *
    ERROR at line 1:
    ORA-20378: You can only manage audit facilities for schemas listed in SCHEMA_LIST
    ORA-06512: at "AUD_UTIL.AUDIT_UTIL", line 111
    ORA-06512: at "AUD_UTIL.AUDIT_UTIL", line 480
    ORA-06512: at "AUD_UTIL.AUDIT_UTIL", line 496
    ORA-06512: at line 1


    SQL> insert into aud_util.schema_list values ('SCOTT');

    1 row created.

    SQL> commit;

    Commit complete.



Now that this is done, we can dig into the API a little more

Creating an Audit Table
=======================

Note: This example does not actually do any work, because we have set p_action to OUTPUT. But we can see what work would have been performed by the call.

    SQL> exec  aud_util.audit_util.generate_audit_table('SCOTT','EMP',p_action=>'OUTPUT');

    Call to generate audit table for SCOTT.EMP

    create table AUD_UTIL.EMP_SCOTT (
     aud$tstamp     timestamp   not null,
     aud$id         number(18)  not null,
     aud$image      varchar2(3) not null )
     partition by range ( aud$tstamp  )
     interval (numtoyminterval(1,'MONTH'))
     ( partition EMP_p202009 values less than ( to_timestamp('20201001','yyyymmdd') )
     ) pctfree 1 tablespace users

    alter table AUD_UTIL.EMP_SCOTT
      add constraint EMP_SCOTT_PK primary key ( aud$tstamp, aud$id, aud$image)
      using index
        (create unique index AUD_UTIL.EMP_SCOTT_PK
         on AUD_UTIL.EMP_SCOTT ( aud$tstamp, aud$id, aud$image)
         local tablespace users)

    alter table AUD_UTIL.EMP_SCOTT add EMPNO NUMBER(4,0)
    alter table AUD_UTIL.EMP_SCOTT add ENAME VARCHAR2(10)
    alter table AUD_UTIL.EMP_SCOTT add JOB VARCHAR2(9)
    alter table AUD_UTIL.EMP_SCOTT add MGR NUMBER(4,0)
    alter table AUD_UTIL.EMP_SCOTT add HIREDATE DATE
    alter table AUD_UTIL.EMP_SCOTT add SAL NUMBER(7,2)
    alter table AUD_UTIL.EMP_SCOTT add COMM NUMBER(7,2)
    alter table AUD_UTIL.EMP_SCOTT add DEPTNO NUMBER(2,0)

    PL/SQL procedure successfully completed.

We create an audit table which is partitioned by month (see below for details about partitioning), with an appropriate locally partitioned primary key. No global indexes are used because the expectation here is that with partitioning you may ultimately want to purge at the partitioning level in future.

Creating an Audit Package
=========================

I'm "old school" and have always considered that any lengthy code that would go into a trigger should be placed into a package. So our insertion DML is wrapped up in a database package that ultimately our  audit trigger will call. 


    SQL> exec  aud_util.audit_util.generate_audit_package('SCOTT','EMP',p_action=>'OUTPUT');

    Call to generate audit package for SCOTT.EMP

    create or replace
    package AUD_UTIL.PKG_EMP_SCOTT is

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

      procedure audit_row(
         p_aud$tstamp                     timestamp
        ,p_aud$id                         number
        ,p_aud$image                      varchar2
        ,p_empno     number
        ,p_ename     varchar2
        ,p_job       varchar2
        ,p_mgr       number
        ,p_hiredate  date
        ,p_sal       number
        ,p_comm      number
        ,p_deptno    number
      );
    end;
    create or replace
    package body AUD_UTIL.PKG_EMP_SCOTT is

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

      procedure audit_row(
         p_aud$tstamp                    timestamp
        ,p_aud$id                        number
        ,p_aud$image                     varchar2
        ,p_empno     number
        ,p_ename     varchar2
        ,p_job       varchar2
        ,p_mgr       number
        ,p_hiredate  date
        ,p_sal       number
        ,p_comm      number
        ,p_deptno    number
      ) is
    begin

      insert into AUD_UTIL.EMP_SCOTT (
         aud$tstamp
        ,aud$id
        ,aud$image
        ,empno
        ,ename
        ,job
        ,mgr
        ,hiredate
        ,sal
        ,comm
        ,deptno
      ) values (
         p_aud$tstamp
        ,p_aud$id
        ,p_aud$image
        ,p_empno
        ,p_ename
        ,p_job
        ,p_mgr
        ,p_hiredate
        ,p_sal
        ,p_comm
        ,p_deptno
        );
    end;

    end;
    grant execute on AUD_UTIL.PKG_EMP_SCOTT to SCOTT


You can see that the package is created in our audit schema not in the table owing schema.  This is to improve security, and the use of a package is aimed to keep the code in the subsequent audit trigger nice and compact.

Creating an Audit Trigger
=========================

Finally we need a trigger to call our package to capture information.


    SQL> exec  aud_util.audit_util.generate_audit_trigger('SCOTT','EMP',p_action=>'OUTPUT');

    Call to generate audit trigger for SCOTT.EMP

    create or replace
    trigger AUD_UTIL.AUD$EMP
    after insert or update or delete on SCOTT.EMP
    for each row
    disable
    declare
     l_dml       varchar2(1) := case when updating then 'U' when inserting then 'I' else 'D' end;
     l_tstamp    timestamp;
     l_id        number;
     l_descr     varchar2(100);
    begin

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

     if aud_util.trigger_ctl.enabled('AUD$EMP') then
      l_descr :=
        case
          when updating
            then 'UPDATE'
          when inserting
            then 'INSERT'
          else
            'DELETE'
        end;

      aud_util.log_header('EMP',l_dml,l_descr,l_tstamp,l_id);

      if updating or
         deleting then
         aud_util.pkg_emp_scott.audit_row(
             p_aud$tstamp =>l_tstamp
            ,p_aud$id     =>l_id
            ,p_aud$image  =>'OLD'
            ,p_empno     =>:old.empno
            ,p_ename     =>:old.ename
            ,p_job       =>:old.job
            ,p_mgr       =>:old.mgr
            ,p_hiredate  =>:old.hiredate
            ,p_sal       =>:old.sal
            ,p_comm      =>:old.comm
            ,p_deptno    =>:old.deptno
            );
      end if;
      if inserting then
         aud_util.pkg_emp_scott.audit_row(
             p_aud$tstamp=>l_tstamp
            ,p_aud$id    =>l_id
            ,p_aud$image =>'NEW'
            ,p_empno     =>:new.empno
            ,p_ename     =>:new.ename
            ,p_job       =>:new.job
            ,p_mgr       =>:new.mgr
            ,p_hiredate  =>:new.hiredate
            ,p_sal       =>:new.sal
            ,p_comm      =>:new.comm
            ,p_deptno    =>:new.deptno
            );
      end if;
     end if;
    end;
    alter trigger AUD_UTIL.AUD$EMP enable

By default, even the trigger is created in the audit schema not the owning schema. Some people prefer this, some people hate it. You can choose your preference by adjusting the 'g_trigger_in_audit_schema' global variable in the package body. See below for other settings.

You can see that we are capturing inserts. I typically think this is overkill, because an inserted row is readily available in the table itself. It is only when someone updates or deletes the row that typically you want to capture an audit. The 'g_inserts_audited' (true|false) in the package body gives you control over this. 

Also, people have differing opinions on whether audit should capture both OLD and NEW values during an update, or just the OLD (because the new values are readily available in the table). Thus similarly, there is a setting 'g_capture_new_updates' (true|false) to give you control over this.

The trigger is always created in DISABLED mode to ensure that if it does not compile, then it will not cause any damage. It is enabled afterwards, but you can control this with the p_enable_trigger parameter which defaults to true.

Bringing it Altogether
======================

All of the above is really just to help with explaining what is going on under the covers. In normal operation, you only need a single call to generate all the audit infrastructure for a table.


    SQL> exec  aud_util.audit_util.generate_audit_support('SCOTT','EMP',p_action=>'EXECUTE');

Remember this call, because as you'll see below, it should be the only call you ever need.

Schema Evolution
================

Contrary to popular opinion, it is pretty easy to change the structure of a database table in a relational database. So what happens to our auditing when you add a column to the SCOTT.EMP table? By default, the auditing will continue on without any issue but will not capture that new column. But all you need to do is re-run the same audit API. It will work out what you have done and make the necessary adjustment.


    SQL> alter table scott.emp add new_col number(10,2);

    Table altered.

    SQL> exec  aud_util.audit_util.generate_audit_support('SCOTT','EMP',p_action=>'EXECUTE');

    Call to generate audit table for SCOTT.EMP

    alter table AUD_UTIL.EMP_SCOTT add NEW_COL NUMBER(10,2)

    Call to generate audit package for SCOTT.EMP
    create or replace
    package AUD_UTIL.PKG_EMP_SCOTT is

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

      procedure audit_row(
         p_aud$tstamp                     timestamp
        ,p_aud$id                         number
        ,p_aud$image                      varchar2
        ,p_empno     number
        ,p_ename     varchar2
        ,p_job       varchar2
        ,p_mgr       number
        ,p_hiredate  date
        ,p_sal       number
        ,p_comm      number
        ,p_deptno    number
        ,p_new_col   number
      );
    end;
    create or replace
    package body AUD_UTIL.PKG_EMP_SCOTT is

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

      procedure audit_row(
         p_aud$tstamp                    timestamp
        ,p_aud$id                        number
        ,p_aud$image                     varchar2
        ,p_empno     number
        ,p_ename     varchar2
        ,p_job       varchar2
        ,p_mgr       number
        ,p_hiredate  date
        ,p_sal       number
        ,p_comm      number
        ,p_deptno    number
        ,p_new_col   number
      ) is
    begin

      insert into AUD_UTIL.EMP_SCOTT (
         aud$tstamp
        ,aud$id
        ,aud$image
        ,empno
        ,ename
        ,job
        ,mgr
        ,hiredate
        ,sal
        ,comm
        ,deptno
        ,new_col
      ) values (
         p_aud$tstamp
        ,p_aud$id
        ,p_aud$image
        ,p_empno
        ,p_ename
        ,p_job
        ,p_mgr
        ,p_hiredate
        ,p_sal
        ,p_comm
        ,p_deptno
        ,p_new_col
        );
    end;

    end;
    grant execute on AUD_UTIL.PKG_EMP_SCOTT to SCOTT

    Call to generate audit trigger for SCOTT.EMP

    create or replace
    trigger AUD_UTIL.AUD$EMP
    after insert or update or delete on SCOTT.EMP
    for each row
    disable
    declare
     l_dml       varchar2(1) := case when updating then 'U' when inserting then 'I' else 'D' end;
     l_tstamp    timestamp;
     l_id        number;
     l_descr     varchar2(100);
    begin

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

     if aud_util.trigger_ctl.enabled('AUD$EMP') then
      l_descr :=
        case
          when updating
            then 'UPDATE'
          when inserting
            then 'INSERT'
          else
            'DELETE'
        end;

      aud_util.log_header('EMP',l_dml,l_descr,l_tstamp,l_id);

      if updating or
         deleting then
         aud_util.pkg_emp_scott.audit_row(
             p_aud$tstamp =>l_tstamp
            ,p_aud$id     =>l_id
            ,p_aud$image  =>'OLD'
            ,p_empno     =>:old.empno
            ,p_ename     =>:old.ename
            ,p_job       =>:old.job
            ,p_mgr       =>:old.mgr
            ,p_hiredate  =>:old.hiredate
            ,p_sal       =>:old.sal
            ,p_comm      =>:old.comm
            ,p_deptno    =>:old.deptno
            ,p_new_col   =>:old.new_col
            );
      end if;
      if inserting then
         aud_util.pkg_emp_scott.audit_row(
             p_aud$tstamp=>l_tstamp
            ,p_aud$id    =>l_id
            ,p_aud$image =>'NEW'
            ,p_empno     =>:new.empno
            ,p_ename     =>:new.ename
            ,p_job       =>:new.job
            ,p_mgr       =>:new.mgr
            ,p_hiredate  =>:new.hiredate
            ,p_sal       =>:new.sal
            ,p_comm      =>:new.comm
            ,p_deptno    =>:new.deptno
            ,p_new_col   =>:new.new_col
            );
      end if;
     end if;
    end;
    alter trigger AUD_UTIL.AUD$EMP enable

    PL/SQL procedure successfully completed.


If you drop a column, we don't change the audit table because presumably you still want a record of the changes that occurred whilst that column existed. Regenerating the audit with the same call again will adjust the package and trigger to no longer reference the dropped column and leave the table untouched.


    SQL> alter table scott.emp drop column new_col;

    Table altered.

    SQL> exec  aud_util.audit_util.generate_audit_support('SCOTT','EMP',p_action=>'EXECUTE');

    Call to generate audit table for SCOTT.EMP

    Call to generate audit package for SCOTT.EMP

    create or replace
    package AUD_UTIL.PKG_EMP_SCOTT is

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

      procedure audit_row(
         p_aud$tstamp                     timestamp
        ,p_aud$id                         number
        ,p_aud$image                      varchar2
        ,p_empno     number
        ,p_ename     varchar2
        ,p_job       varchar2
        ,p_mgr       number
        ,p_hiredate  date
        ,p_sal       number
        ,p_comm      number
        ,p_deptno    number
      );
    end;
    create or replace
    package body AUD_UTIL.PKG_EMP_SCOTT is

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

      procedure audit_row(
         p_aud$tstamp                    timestamp
        ,p_aud$id                        number
        ,p_aud$image                     varchar2
        ,p_empno     number
        ,p_ename     varchar2
        ,p_job       varchar2
        ,p_mgr       number
        ,p_hiredate  date
        ,p_sal       number
        ,p_comm      number
        ,p_deptno    number
      ) is
    begin

      insert into AUD_UTIL.EMP_SCOTT (
         aud$tstamp
        ,aud$id
        ,aud$image
        ,empno
        ,ename
        ,job
        ,mgr
        ,hiredate
        ,sal
        ,comm
        ,deptno
      ) values (
         p_aud$tstamp
        ,p_aud$id
        ,p_aud$image
        ,p_empno
        ,p_ename
        ,p_job
        ,p_mgr
        ,p_hiredate
        ,p_sal
        ,p_comm
        ,p_deptno
        );
    end;

    end;
    grant execute on AUD_UTIL.PKG_EMP_SCOTT to SCOTT

    Call to generate audit trigger for SCOTT.EMP

    create or replace
    trigger AUD_UTIL.AUD$EMP
    after insert or update or delete on SCOTT.EMP
    for each row
    disable
    declare
     l_dml       varchar2(1) := case when updating then 'U' when inserting then 'I' else 'D' end;
     l_tstamp    timestamp;
     l_id        number;
     l_descr     varchar2(100);
    begin

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

     if aud_util.trigger_ctl.enabled('AUD$EMP') then
      l_descr :=
        case
          when updating
            then 'UPDATE'
          when inserting
            then 'INSERT'
          else
            'DELETE'
        end;

      aud_util.log_header('EMP',l_dml,l_descr,l_tstamp,l_id);

      if updating or
         deleting then
         aud_util.pkg_emp_scott.audit_row(
             p_aud$tstamp =>l_tstamp
            ,p_aud$id     =>l_id
            ,p_aud$image  =>'OLD'
            ,p_empno     =>:old.empno
            ,p_ename     =>:old.ename
            ,p_job       =>:old.job
            ,p_mgr       =>:old.mgr
            ,p_hiredate  =>:old.hiredate
            ,p_sal       =>:old.sal
            ,p_comm      =>:old.comm
            ,p_deptno    =>:old.deptno
            );
      end if;
      if inserting then
         aud_util.pkg_emp_scott.audit_row(
             p_aud$tstamp=>l_tstamp
            ,p_aud$id    =>l_id
            ,p_aud$image =>'NEW'
            ,p_empno     =>:new.empno
            ,p_ename     =>:new.ename
            ,p_job       =>:new.job
            ,p_mgr       =>:new.mgr
            ,p_hiredate  =>:new.hiredate
            ,p_sal       =>:new.sal
            ,p_comm      =>:new.comm
            ,p_deptno    =>:new.deptno
            );
      end if;
     end if;
    end;
    alter trigger AUD_UTIL.AUD$EMP enable

    PL/SQL procedure successfully completed.


Column Rename
=============

Some things we obviously can't really know what your intent was, for example, if you rename a column, but there is an API provided to let you do that.


    PROCEDURE rename_column(p_owner varchar2
                           ,p_table_name varchar2
                           ,p_old_columns varchar2
                           ,p_new_columns varchar2
                           ,p_action varchar2) IS


You pass in a comman separated list of the old column names and the new column names, and the audit table columns will be renamed and the audit package and audit triggers regenerated.

Dropping Auditing for a table
==============================

If you want to remove the auditing facilities for a table, simply call DROP_AUDIT_SUPPORT for the table.


    SQL>  exec  aud_util.audit_util.drop_audit_support('SCOTT','EMP',p_action=>'EXECUTE');

    Call to drop audit trigger for SCOTT.EMP
    drop trigger AUD_UTIL.AUD$EMP

    Call to drop audit package for SCOTT.EMP
    drop package AUD_UTIL.PKG_EMP_SCOTT

    Call to drop audit table for SCOTT.EMP
    drop table AUD_UTIL.EMP_SCOTT

    PL/SQL procedure successfully completed.

Clearly, if you added auditing for a table, then dropping is not a thing that should be taken lightly. For this reason, we check to see if there are any rows in the audit table for this object. If there is any data, then by default, we will drop the trigger and the package, but the table will be preserved.


    SQL> exec  aud_util.audit_util.drop_audit_support('SCOTT','EMP',p_action=>'EXECUTE');

    Call to drop audit trigger for SCOTT.EMP
    drop trigger AUD_UTIL.AUD$EMP

    Call to drop audit package for SCOTT.EMP
    drop package AUD_UTIL.PKG_EMP_SCOTT

    Call to drop audit table for SCOTT.EMP
    BEGIN aud_util.audit_util.drop_audit_support('SCOTT','EMP',p_action=>'EXECUTE'); END;

    *
    ERROR at line 1:
    ORA-20378: Rows found in AUD_UTIL.EMP_SCOTT.  Use FORCE option if you really want to drop this
    ORA-06512: at "AUD_UTIL.AUDIT_UTIL", line 111
    ORA-06512: at "AUD_UTIL.AUDIT_UTIL", line 909
    ORA-06512: at "AUD_UTIL.AUDIT_UTIL", line 975
    ORA-06512: at line 1

As the error message suggests, if you really want to erase that audit history, then add the P_FORCE parameter.


``SQL> exec  aud_util.audit_util.drop_audit_support('SCOTT','EMP',p_action=>'EXECUTE',p_force=>true);``

Performance Optimisation
=======================

The examples above are simplified to make comprehension easier. As many of us know, one of the concerns about having auditing triggers is that they turn a batch operation (ie, a single DML that modifies lots of rows) into a row-by-row operation in terms of performance, because for every row touched, we are "jumping out" to the audit code to log the changed row.

In reality, the audit generator does not do this. We take advantage of bulk binding to ensure that we minimise the performance overhead of the audit triggers. This is controlled by the setting g_bulk_bind which defaults to true. 


    SQL> exec  aud_util.audit_util.generate_audit_package('SCOTT','EMP',p_action=>'EXECUTE');

    Call to generate audit package for SCOTT.EMP

    create or replace
    package AUD_UTIL.PKG_EMP_SCOTT is

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

      procedure bulk_init;
      procedure bulk_process;

      procedure audit_row(
         p_aud$tstamp                     timestamp
        ,p_aud$id                         number
        ,p_aud$image                      varchar2
        ,p_empno     number
        ,p_ename     varchar2
        ,p_job       varchar2
        ,p_mgr       number
        ,p_hiredate  date
        ,p_sal       number
        ,p_comm      number
        ,p_deptno    number
      );
    end;

    create or replace
    package body AUD_UTIL.PKG_EMP_SCOTT is

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

        type t_audit_rows is table of AUD_UTIL.EMP_SCOTT%rowtype
          index by pls_integer;

        l_audrows t_audit_rows;

      procedure bulk_init is
      begin
        l_audrows.delete;
      end;

      procedure bulk_process is
      begin
        if l_audrows.count = 1 then
          insert into AUD_UTIL.EMP_SCOTT values l_audrows(1);
        else
          forall i in 1 .. l_audrows.count
            insert into AUD_UTIL.EMP_SCOTT values l_audrows(i);
        end if;
      end;

      procedure audit_row(
         p_aud$tstamp                    timestamp
        ,p_aud$id                        number
        ,p_aud$image                     varchar2
        ,p_empno     number
        ,p_ename     varchar2
        ,p_job       varchar2
        ,p_mgr       number
        ,p_hiredate  date
        ,p_sal       number
        ,p_comm      number
        ,p_deptno    number
      ) is
        l_idx pls_integer := l_audrows.count+1;
      begin

        l_audrows(l_idx).aud$tstamp := p_aud$tstamp;
        l_audrows(l_idx).aud$id     := p_aud$id;
        l_audrows(l_idx).aud$image  := p_aud$image;
        l_audrows(l_idx).empno      := p_empno;
        l_audrows(l_idx).ename      := p_ename;
        l_audrows(l_idx).job        := p_job;
        l_audrows(l_idx).mgr        := p_mgr;
        l_audrows(l_idx).hiredate   := p_hiredate;
        l_audrows(l_idx).sal        := p_sal;
        l_audrows(l_idx).comm       := p_comm;
        l_audrows(l_idx).deptno     := p_deptno;
      end;

    end;
    You can see that the package just retains audit rows in an associative array, and the "bulk_process" routine which will be called by the trigger to process them all once the statement completes. Thus our trigger now becomes a compound one. 



    SQL> exec  aud_util.audit_util.generate_audit_trigger('SCOTT','EMP',p_action=>'EXECUTE');

    Call to generate audit trigger for SCOTT.EMP

    create or replace
    trigger AUD_UTIL.AUD$EMP
    for insert or update or delete on SCOTT.EMP
    disable
    compound trigger
     l_dml       varchar2(1) := case when updating then 'U' when inserting then 'I' else 'D' end;
     l_tstamp    timestamp;
     l_id        number;
     l_descr     varchar2(100);

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

    before statement is
    begin
     if aud_util.trigger_ctl.enabled('AUD$EMP') then
       aud_util.pkg_emp_scott.bulk_init;
     end if;
    end before statement;

    after each row is
    begin
     if aud_util.trigger_ctl.enabled('AUD$EMP') then
      l_descr :=
        case
          when updating
            then 'UPDATE'
          when inserting
            then 'INSERT'
          else
            'DELETE'
        end;

      aud_util.audit_pkg.log_header_bulk('EMP',l_dml,l_descr,l_tstamp,l_id);

      if updating('EMPNO')    or
         updating('DEPTNO')   or
         updating('HIREDATE') or
         deleting then
         aud_util.pkg_emp_scott.audit_row(
             p_aud$tstamp =>l_tstamp
            ,p_aud$id     =>l_id
            ,p_aud$image  =>'OLD'
            ,p_empno     =>:old.empno
            ,p_ename     =>:old.ename
            ,p_job       =>:old.job
            ,p_mgr       =>:old.mgr
            ,p_hiredate  =>:old.hiredate
            ,p_sal       =>:old.sal
            ,p_comm      =>:old.comm
            ,p_deptno    =>:old.deptno
            );
      end if;
      if updating('EMPNO')    or
         updating('DEPTNO')   or
         updating('HIREDATE') or
         inserting then
         aud_util.pkg_emp_scott.audit_row(
             p_aud$tstamp=>l_tstamp
            ,p_aud$id    =>l_id
            ,p_aud$image =>'NEW'
            ,p_empno     =>:new.empno
            ,p_ename     =>:new.ename
            ,p_job       =>:new.job
            ,p_mgr       =>:new.mgr
            ,p_hiredate  =>:new.hiredate
            ,p_sal       =>:new.sal
            ,p_comm      =>:new.comm
            ,p_deptno    =>:new.deptno
            );
      end if;
     end if;
    end after each row;

    after statement is
    begin
     if aud_util.trigger_ctl.enabled('AUD$EMP') then
       aud_util.pkg_emp_scott.bulk_process;
       aud_util.audit_pkg.bulk_process;
     end if;
    end after statement;
    end;
    alter trigger AUD_UTIL.AUD$EMP enable

Miscellaneous
=============

Interval Partitioning
---------------------

Also provided is a routine

``PROCEDURE partition_name_tidy_up(p_operation varchar2 default 'DEFAULT',p_action varchar2);``

which only is relevant if you are using partitioning for your audit tables. Interval partition is being used, and as such, automatically generated partition names will be observed. This routine looks through the audit schema and renames the partitions to have the form  <tablename>_P<yyyymm>

The "p_operation" parameter allows this routine to be activated as a scheduler job.  The values for this parameter are:

DEFAULT - do the partition renaming work 
DISABLE - disable the existing scheduler job 
ENABLE - enable the existing scheduler job 
UNSCHEDULE - drop the scheduler job 
SCHEDULE - create a new scheduler job for 9am each day, which simply calls the same routine with the DEFAULT operation 
CHECK - see if there is a job and create one if not there.

Selective Column Updates
------------------------
There may be some columns in your source table for which an update does constitute that change being audit worthy. For example, you might have a table of users, and you don't care when people upload a new profile photo. You can also nominate which columns are the ones "of interest" when generating audit support for the table

    SQL> exec  aud_util.audit_util.generate_audit_trigger('SCOTT','EMP',p_update_cols=>'EMPNO,DEPTNO,HIREDATE',p_action=>'OUTPUT');

    Call to generate audit trigger for SCOTT.EMP

    create or replace
    trigger AUD_UTIL.AUD$EMP
    after insert or update or delete on SCOTT.EMP
    for each row
    disable
    declare
     l_dml       varchar2(1) := case when updating then 'U' when inserting then 'I' else 'D' end;
     l_tstamp    timestamp;
     l_id        number;
     l_descr     varchar2(100);
    begin

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

     if aud_util.trigger_ctl.enabled('AUD$EMP') then
      l_descr :=
        case
          when updating
            then 'UPDATE'
          when inserting
            then 'INSERT'
          else
            'DELETE'
        end;

      aud_util.log_header_bulk('EMP',l_dml,l_descr,l_tstamp,l_id);

      if updating('EMPNO')    or
         updating('DEPTNO')   or
         updating('HIREDATE') or
         deleting then
         aud_util.pkg_emp_scott.audit_row(
             p_aud$tstamp =>l_tstamp
            ,p_aud$id     =>l_id
            ,p_aud$image  =>'OLD'
            ,p_empno     =>:old.empno
            ,p_ename     =>:old.ename
            ,p_job       =>:old.job
            ,p_mgr       =>:old.mgr
            ,p_hiredate  =>:old.hiredate
            ,p_sal       =>:old.sal
            ,p_comm      =>:old.comm
            ,p_deptno    =>:old.deptno
            );
      end if;
      if inserting then
         aud_util.pkg_emp_scott.audit_row(
             p_aud$tstamp=>l_tstamp
            ,p_aud$id    =>l_id
            ,p_aud$image =>'NEW'
            ,p_empno     =>:new.empno
            ,p_ename     =>:new.ename
            ,p_job       =>:new.job
            ,p_mgr       =>:new.mgr
            ,p_hiredate  =>:new.hiredate
            ,p_sal       =>:new.sal
            ,p_comm      =>:new.comm
            ,p_deptno    =>:new.deptno
            );
      end if;
     end if;
    end;
    alter trigger AUD_UTIL.AUD$EMP enable



When you create a trigger in this way, the nominated columns are stored in the AUDIT_UTIL_UPDATE_TRIG table. In this way, if you generate the trigger again, the same column specification is retained. If you need to reset the columns that are captured, you pass the string 'NULL' for the p_update_cols parameter (because a true null just means use the existing column specification.

Selective Row Audit
-------------------

Along similar lines, you can nominate a WHEN clause for the trigger when generating the audit.


    SQL> exec  aud_util.audit_util.generate_audit_trigger('SCOTT','EMP',p_when_clause=>'new.empno > 0',p_action=>'OUTPUT');
    Call to generate audit trigger for SCOTT.EMP
    create or replace
    trigger AUD_UTIL.AUD$EMP
    after insert or update or delete on SCOTT.EMP
    for each row
    disable
    when (new.empno > 0)
    declare
     l_dml       varchar2(1) := case when updating then 'U' when inserting then 'I' else 'D' end;
     l_tstamp    timestamp;
     l_id        number;
     l_descr     varchar2(100);
    begin

     /***************************************************************/
     /* ATTENTION                                                   */
     /*                                                             */
     /* This package is automatically generated by audit generator  */
     /* utility.  Do not edit this package by hand as your changes  */
     /* will be lost if the package are re-generated.               */
     /***************************************************************/

     if aud_util.trigger_ctl.enabled('AUD$EMP') then
      l_descr :=
        case
          when updating
            then 'UPDATE'
          when inserting
            then 'INSERT'
          else
            'DELETE'
        end;

      aud_util.log_header('EMP',l_dml,l_descr,l_tstamp,l_id);

      if updating('EMPNO')    or
         updating('DEPTNO')   or
         deleting then
         aud_util.pkg_emp_scott.audit_row(
             p_aud$tstamp =>l_tstamp
            ,p_aud$id     =>l_id
            ,p_aud$image  =>'OLD'
            ,p_empno     =>:old.empno
            ,p_ename     =>:old.ename
            ,p_job       =>:old.job
            ,p_mgr       =>:old.mgr
            ,p_hiredate  =>:old.hiredate
            ,p_sal       =>:old.sal
            ,p_comm      =>:old.comm
            ,p_deptno    =>:old.deptno
            );
      end if;
      if inserting then
         aud_util.pkg_emp_scott.audit_row(
             p_aud$tstamp=>l_tstamp
            ,p_aud$id    =>l_id
            ,p_aud$image =>'NEW'
            ,p_empno     =>:new.empno
            ,p_ename     =>:new.ename
            ,p_job       =>:new.job
            ,p_mgr       =>:new.mgr
            ,p_hiredate  =>:new.hiredate
            ,p_sal       =>:new.sal
            ,p_comm      =>:new.comm
            ,p_deptno    =>:new.deptno
            );
      end if;
     end if;
    end;
    alter trigger AUD_UTIL.AUD$EMP enable

    PL/SQL procedure successfully completed.
    
Like the update columns clause, the WHEN clause is stored in the AUDIT_UTIL_UPDATE_TRIG table. In this way, if you generate the trigger again, the same WHEN clause is retained. If you need to reset it, you pass the string 'NULL' for the p_when_clause parameter (because a true null just means use the existing specification . 

Post Installation
-----------------
Just done a large application deployment? If you are worried you might have missed something pertaining to auditing, you can call POST_INSTALL which will cycle though all tables for those schemas listed in the SCHEMA_LIST table and look for differences between the source table and its audit partner. In this one routine, as well as the standard OUTPUT and EXECUTE options for the p_action parameter, there is also an option of REPORT will be present a report of what differences were found. This can be very useful as a validation check.

Accidents Happen
----------------

Some times you need to turn off a trigger temporarily in a session. Disabling a trigger is a drastic way to achieve this because it breaks the application for any other session that is current using that table. So the audit routines respect that need, and you can control audit trigger facilities on a session by session basis using the TRIGGER_CTL package which will be loaded into the audit schema. Clearly, you might want to look at either not using this (if you want to force audit ALL the time) or perhaps adding some sort of authentication etc to ensure people don't go around selectively turning off the audit!

Same Schema Support
===================
By default, the audit utility was designed to be operated by a DBA to "impose" auditing on a target schema. However, in some environment you might not have the privs to that, and thus you want all of the auditing placed into an existing schema to which you have access. In the "same_schema" folder, there is a set of scripts to faciliate that. It replaces all refernces to "DBA_" views with "ALL_", and all objects created that are associated with audit are prefixed with AUD$ to separate them out from the existing objects in the schema.

Complete list of Settings
=========================
g_aud_prefix - common prefix for all audit table names. Defaults to null

g_capture_new_updates - whether to log :NEW records as well as :OLD records. Defaults to false.

g_inserts_audited - whether to log inserts as well as updates and deletes. Defaults to false.

g_always_log_header - whether to log a header record for inserts even if insert capture at table level is off. Default to false.

g_job_name - the scheduler job name for partition name tidy up. Defaults to AUDIT_PARTITION_NAME_TIDY_UP

g_log_level - The amount of logging we do. 1= dbms_output, 2=maint table, 3=both. Defaults to 3

g_logical_del_col - Some times an update is a delete from an application perspective, namely, we set a column called (say) DELETED to Y. If you have that, you can nominate that column here and we will log an update as a "logical delete" in the audit table metadata. Defaults to DELETED_IND

g_table_grantees - If you want to allow access to the audit tables, set the list of schemas/roles to be granted that privilege in this associative array. Defaults to none.

g_trigger_in_audit_schema - Whether the trigger should be created in the table owning schema or the audit schema. Defaults to true (the audit schema).

g_bulk_bind - Whether the audit processing uses bulk bind or row-by-row processing for audit capture. Partnered with g_bulk_bind_limit to control how often we flush the buffer to avoid PGA issues

g_use_context - should we use a context/WHEN clause or a plsql call for trigger maintenance. Defaults to true

Your Usage Rights
=================
Whilst I've done plenty of testing, responsibilty for correctness on your own environment lies with you. There are boundary cases where you could break it. For example, throw in some 120 character table names combined column names and you might have problems. Similarly, the routines have no handling for mixed case dictionary names - you're on your own there. Having said that, I have no interest in licensing the code etc, so you are free to use, copy, modify etc with no implied ownership of my own, or any attribution required. If you get some value out of it, just pop a "Thanks" on Twitter to @connor_mc_d and that's cool.
