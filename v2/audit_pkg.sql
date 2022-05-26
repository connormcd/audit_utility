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
    --l_headers(l_idx).host       := sys_context('userenv','host');
    l_headers(l_idx).host := coalesce(owa_util.get_cgi_env('X-Forwarded-For'), owa_util.get_cgi_env('REMOTE_ADDR'), sys_context('userenv','host'));
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
  