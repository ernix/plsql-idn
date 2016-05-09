create or replace package idn is
    function VERSION (v varchar2 := '0.03')
        return varchar2;
    function ascii_to_domain (domain nvarchar2)
        return nvarchar2 deterministic;
    function domain_to_ascii (domain nvarchar2)
        return nvarchar2 deterministic;
end;
/
