# IDN - Internationalized Domain Name(IDN) helper package for Oracle

## DESCRIPTION:
This package provides functions to deal with IDN.

## CAUTION:
Keep in mind that this package does NOT provide any StringPrep/NamePrep
functionalities.  Domains from `domain_to_ascii` and `ascii_to_domain` may
refused by registries due to their registration rules.

This package is just an eye-candy to deal with IDNs.
Do not use this package for IDN validation.
YOU'VE BEEN WARNED.

## VERSION:
0.03

## USAGE:

- ascii_to_domain(domain)
    ASCII to IDN

    ```
    SQL> select idn.ascii_to_domain('xn--q9jyb4c.foo.com') from dual;

    IDN.ASCII_TO_DOMAIN('XN--Q9JYB4C.FOO.COM')
    ------------------------------------------
    みんな.foo.com
    ```

- domain_to_ascii(domain)
    IDN to ASCII

    ```
    SQL> select idn.domain_to_ascii('みんな.foo.com') from dual;

    IDN.DOMAIN_TO_ASCII('みんな.FOO.COM')
    -------------------------------------
    xn--q9jyb4c.foo.com
    ```

## PORT FROM:
http://stackoverflow.com/questions/183485/can-anyone-recommend-a-good-free-javascript-for-punycode-to-unicode-conversion

## LICENSE
This software is released under the MIT License, see LICENSE

## AUTHOR:
"Shin Kojima" &lt;shin@kojima.org&rt;
