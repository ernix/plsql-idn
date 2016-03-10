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
    function splice (
        str varchar2,
        pos number,
        len number,
        rep varchar2 := ''
    ) return varchar2 deterministic;
    function unicode_point (c varchar2)
        return number deterministic;
    function decode_punycode (input varchar2)
        return varchar2 deterministic;
    function encode_punycode (input varchar2, preserve_case boolean := false)
        return varchar2 deterministic;
    function ascii_to_domain (domain varchar2)
        return varchar2 deterministic;
    function domain_to_ascii (domain varchar2)
        return varchar2 deterministic;
end;
/
