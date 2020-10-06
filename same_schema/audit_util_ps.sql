define schema = scott
define prefix = aud$

pro
pro Using schema &&schema, prefix &&prefix
pro

CREATE OR REPLACE PACKAGE &&schema..&&prefix.AUDIT_UTIL IS

-- ----------------------------------------------------------------------------
-- Routines for new audit table support
--
-- Destructive routines have
--    p_action can be 'OUTPUT' or 'EXECUTE' as parameters
--      OUTPUT = just output the commands/ddl that would be run without doing it
--      EXECUTE = do it for real

--
-- Standard grants for audit tables.  Typically does not need to be
-- called in isolation
--
PROCEDURE grant_audit_access(p_object_name varchar2
                            ,p_owner varchar2
                            ,p_action varchar2);

--
-- Create (or modify) the audit table for an IMS table.
-- The routine sends back two booleans indicating if any work
-- was needed to either create a new table, or alter it to add
-- any columns.  You can (at your discretion) use these values
-- to decide if you want to proceed to creating packages and triggers
--


PROCEDURE generate_audit_table(p_owner varchar2
                              ,p_table_name varchar2
                              ,p_created out boolean
                              ,p_altered out boolean
                              ,p_action varchar2);

--
-- As above, but ignoring the booleans
--
PROCEDURE generate_audit_table(p_owner varchar2
                              ,p_table_name varchar2
                              ,p_action varchar2);

--
-- Create (or modify) the audit package to do inserts into the audit table
--
PROCEDURE generate_audit_package(p_owner varchar2
                                ,p_table_name varchar2
                                ,p_action varchar2);

--
-- Create (or modify) the audit trigger thats calls the audit package
--
PROCEDURE generate_audit_trigger(p_owner varchar2
                                ,p_table_name varchar2
                                ,p_action varchar2
                                ,p_update_cols varchar2 default null
                                ,p_when_clause varchar2 default null
                                ,p_enable_trigger boolean default true);

--
-- Do the whole lot...(this is normal usage).  You just call
-- "generate_audit_support" and it works out what is needed.
-- The "p_force" controls whether to recreate packages and triggers
-- even if the audit table is present and has not changed
--
PROCEDURE generate_audit_support(p_owner varchar2
                                ,p_table_name varchar2
                                ,p_force boolean default false
                                ,p_action varchar2
                                ,p_update_cols varchar2 default null
                                ,p_when_clause varchar2 default null
                                ,p_enable_trigger boolean default true);


--
-- same for dropping support.  Its unlikely you will ever need to use these.
-- Typically its only if generation of audit support went belly up and hence
-- you had a partial mess to sort out.
--
-- "force" means
--   a) drop tables even if they have rows
--   b) don't return errors if objects do not exist
--
PROCEDURE drop_audit_table(p_owner varchar2
                          ,p_table_name varchar2
                          ,p_force boolean default false
                          ,p_action varchar2);

PROCEDURE drop_audit_package(p_owner varchar2
                            ,p_table_name varchar2
                            ,p_force boolean default false
                            ,p_action varchar2);

PROCEDURE drop_audit_trigger(p_owner varchar2
                            ,p_table_name varchar2
                            ,p_force boolean default false
                            ,p_action varchar2);

PROCEDURE drop_audit_support(p_owner varchar2
                            ,p_table_name varchar2
                            ,p_force boolean default false
                            ,p_action varchar2);

--
-- Can be run from time to time to rename interval partitions
-- to something that is a little more relevant
--

PROCEDURE partition_name_tidy_up(p_operation varchar2 default 'DEFAULT',
                                 p_action varchar2);


--
-- If you needed to rename a column in your base table, you can use
-- this to make the appropriate fix to your audit table
--

PROCEDURE rename_column(p_owner varchar2
                       ,p_table_name varchar2
                       ,p_old_columns varchar2
                       ,p_new_columns varchar2
                       ,p_action varchar2);

--
-- The kind of thing you would run after an application deployment.
-- It looks for new tables, new columns and generates appropriate audit
-- suport for these new/modified tables
--

PROCEDURE post_install(p_action varchar2);

END;
/
