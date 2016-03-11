/**
 * idn - Internationalized Domain Name(IDN) helper package for Oracle
 *
 * DESCRIPTION:
 *   This package provides functions to deal with IDN.
 *
 * VERSION:
 *   0.01
 *
 * USAGE:
 *   - ascii_to_domain(domain)
 *     ASCII to IDN
 *
 *   - domain_to_ascii(domain)
 *     IDN to ASCII
 *
 * AUTHOR:
 *   "Shin Kojima" <kojima@interlink.ad.jp>
 */
create or replace package idn is
    function ascii_to_domain (domain varchar2)
        return varchar2 deterministic;
    function domain_to_ascii (domain varchar2)
        return varchar2 deterministic;
end;
/
