create or replace package body idn is
    -- private
    initial_n    number           := 128;
    initial_bias number           := 72;
    delimiter    varchar2(1 char) := unistr('\002D');
    damp         number           := 700;
    base         number           := 36;
    tmin         number           := 1;
    tmax         number           := 26;
    skew         number           := 38;
    maxint       number           := 2147483647; -- 0x7fffffff
    idn_prefix constant varchar2(4 char) := 'xn--';

    function get_token (
        str varchar2,
        i   number,
        sep varchar2 := '.'
    ) return varchar2 deterministic is
        head number;
        tail number;
    begin
        if i = 1 then
            head := 1;
        else
            head := instr(str, sep, 1, i - 1);
            if head = 0 then
                return null;
            else
               head := head + length(sep);
            end if;
        end if;
        tail := instr(str, sep, head, 1);
        if tail = 0 then
            return substr(str, head);
        else
            return substr(str, head, tail - head);
        end if;
    end;

    function splice (
        str varchar2,
        pos number,
        len number,
        rep varchar2 := ''
    ) return varchar2 deterministic is
    begin
        return substr(str, 1, pos - 1)
            || rep
            || substr(str, pos + len, length(str));
    end;

    -- http://www.sqlsnippets.com/en/topic-13438.html
    function unicode_point (
        c varchar2
    ) return number deterministic is
        fc constant varchar2(2 char) := substrc(c, 1, 1);
        rc constant raw(8) := utl_i18n.string_to_raw(fc, 'AL16UTF16');
        hex_val constant varchar(8) := rawtohex(rc);
        hex_lead  constant char(4) := substr(hex_val, 1, 4);
        hex_trail constant char(4) := substr(hex_val, 5, 4);
        dec_lead  constant number := to_number(hex_lead,  'XXXX');
        dec_trail constant number := to_number(hex_trail, 'XXXX');
        surrogate_offset constant number := -56613888;
    begin
        if (c is null) then
            return null;
        end if;

        if (hex_trail is null) then
            return dec_lead;
        end if;

        return dec_lead * 1024 + dec_trail + surrogate_offset;
    end;

    function decode_digit (
        cp number
    ) return number deterministic is
    begin
        if (cp - 48 < 10) then
            return cp - 22;
        elsif (cp - 65 < 26) then
            return cp - 65;
        elsif (cp - 97 < 26) then
            return cp - 97;
        else
            return base;
        end if;
    end;

    -- encode_digit(d,flag) returns the basic code point whose value (when used
    -- for representing integers) is d, which needs to be in the range 0 to
    -- base-1.  The lowercase form is used unless flag is nonzero, in which
    -- case the uppercase form is used. The behavior is undefined if flag is
    -- nonzero and digit d has no uppercase form. 
    function encode_digit (
        d    number,
        flag boolean
    ) return number deterministic is
        cpi  number;
    begin
        cpi := d
             + 22
             + 75 * (case when d < 26 then 1 else 0 end)
             - ((case when flag then 1 else 0 end) * 32)
             ;
        --  0..25 map to ASCII a..z or A..Z
        -- 26..35 map to ASCII 0..9
        return cpi;
    end;

    function adapt (
        input_delta number,
        numpoints number,
        firsttime boolean
    ) return number is
        k     number := 0;
        delta number := input_delta;
    begin
        if (firsttime) then
            delta := trunc(delta / damp);
        else
            delta := delta / 2;
        end if;

        delta := delta + trunc(delta / numpoints);

        loop
            exit when (delta <= (((base - tmin) * tmax) / 2));

            delta := trunc(delta / (base - tmin));

            k := k + base;
        end loop;

        return trunc(k + (base - tmin + 1) * delta / (delta + skew));
    end;

    function encode_basic (
        input_bcp number,
        flag      number
    ) return number is
        bcp number := input_bcp;
    begin
        bcp := (case when bcp - 97 < 26 then 1 else 0 end) * 32;

        return bcp
             + (case when flag = 0 and bcp - 65 < 26 then 1 else 0 end) * 32;
    end;

    -- public
    function decode_punycode (
        input varchar2
    ) return varchar2 deterministic is
        illegal_input exception;
        pragma exception_init(illegal_input, -6503);
        range_error exception;
        pragma exception_init(range_error, -6504);
        type string_array is varray(256) of char(4) not null;
        output     string_array := string_array(256);
        case_flags string_array := string_array(256);
        input_len  number := nvl(length(input), 0);
        n          number := initial_n;
        o          number;
        i          number := 0;
        bias       number := initial_bias;
        basic      number := instr(input, delimiter, -1, 1);
        j          number;
        ic         number := 0;
        oldi       number;
        w          number;
        k          number;
        digit      number;
        t          number;
        len        number;
        l          number;
        ret        varchar2(256) := '';
    begin
        if (basic < 0) then
            basic := 0;
        end if;

        for j in 1 .. (basic - 1) loop
            if (unicode_point(substr(input, j, 1)) >= 128) then -- 128 == 0x80
                raise illegal_input;
            end if;
            output(j) := substr(input, j, 1);
        end loop;

        if (basic > 0) then
            ic := basic + 1;
        end if;

        while (ic < input_len) loop
            oldi := i;
            w := 1;
            k := base;
            while (1 = 1) loop
                if (ic >= input_len) then
                    raise range_error;
                end if;

                digit := decode_digit(ascii(substr(input, ic + 1, ic + 2)));
                ic := ic + 1;

                if (digit >= base) then
                    raise range_error;
                end if;

                if (digit > trunc((maxint -i) / w)) then
                    raise range_error;
                end if;

                i := i + digit * w;

                t := case when k <= bias        then tmin
                          when k >= bias + tmax then tmax
                                                else k - bias
                     end;

                exit when (digit < t);

                if (w > trunc(maxint / (base - t))) then
                    raise range_error;
                end if;

                k := k + base;
            end loop;

            o := output.count + 1;
            bias := adapt(i - oldi, o, oldi = 0);

            if (trunc(i / o) > maxint - n) then
                raise range_error;
            end if;

            n := n + trunc(i / o);
            i := mod(i, o);

            output(i + 1) := n;
            i := i + 1;
        end loop;

        for l in 1 .. output.count loop
            ret := output(l);
        end loop;

        return ret;
    exception
        when illegal_input then return null;
        when range_error   then return null;
    end;

    function encode_punycode (
        input         varchar2,
        preserve_case boolean := false
    ) return varchar2 deterministic is
        range_error exception;
        pragma exception_init(range_error, -6504);
        n            number := initial_n;
        delta        number := 0;
        h            number;
        b            number;
        bias         number := initial_bias;
        j            number;
        m            number;
        q            number;
        k            number;
        t            number;
        ijv          number;
        case_flags   varchar2(1);
        input_length number        := nvl(length(input), 0);
        output       varchar2(256) := '';
        c            varchar2(1 char);
    begin
        -- TODO: preserve_case
        -- if (preserve_case) then
        --     case_flags := input;
        -- end if;

        for j in 1 .. input_length loop
            c := substr(input, j, 1);
            if (unicode_point(c) < 128) then
                output := output || c;
            end if;
        end loop;

        b := nvl(length(output), 0);
        h := b;

        -- h is the number of code points that have been handled, b is the
        -- number of basic code points 

        if (b > 0) then
            output := output || delimiter;
        end if;

        while (h < input_length) loop
            -- All non-basic code points < n have been handled already. Find
            -- the next larger one: 

            m := maxint;
            for j in 1 .. input_length loop
                ijv := unicode_point(substr(input, j, 1));
                if (ijv >= n and ijv < m) then
                    m := ijv;
                end if;
            end loop;

            -- Increase delta enough to advance the decoder's <n,i> state to
            -- <m,0>, but guard against overflow: 

            if (m - n > trunc((maxint - delta) / (h + 1))) then
                raise range_error;
            end if;

            delta := delta + (m - n) * (h + 1);
            n := m;

            for j in 1 .. input_length loop
                ijv := unicode_point(substr(input, j, 1));

                if (ijv < n) then
                    delta := delta + 1;
                    if (delta > maxint) then
                        raise range_error;
                    end if;
                end if;

                if (ijv = n) then
                    q := delta;
                    k := base;
                    loop
                        t := case when k <= bias        then tmin
                                  when k >= bias + tmax then tmax
                             else k - bias end;

                        exit when (q < t);

                        output := output || chr(encode_digit(t + mod(q - t, base - t), false));

                        q := trunc((q - t) / (base - t));
                        k := k + base;
                    end loop;

                    -- TODO: preserve_case
                    output := output || chr(encode_digit(q, false));

                    bias := adapt(delta, h + 1, h = b);
                    delta := 0;
                    h := h + 1;
                end if;
            end loop;

            delta := delta + 1;
            n := n + 1;
        end loop;

        return output;
    exception
        when range_error then return null;
    end;

    function domain_to_ascii (
        domain varchar2
    ) return varchar2 is
        invalid_domain exception;
        pragma exception_init(invalid_domain, -6503);
        dot_count number := nvl(length(domain), 0) - nvl(length(replace(domain, '.')), 0);
        i number;
        part varchar2(256) := '';
        ret  varchar2(256) := '';
    begin
        for i in 0 .. dot_count loop
            part := get_token(domain, i + 1);

            if (regexp_like(part, '[^A-Za-z0-9-]')) then
                part := idn_prefix || encode_punycode(part);
            end if;

            ret := ret || part;

            if (i != dot_count) then
                ret := ret || '.';
            end if;
        end loop;

        return ret;
    exception
        when invalid_domain then return null;
    end;

    function ascii_to_domain (
        domain varchar2
    ) return varchar2 is
        invalid_domain exception;
        pragma exception_init(invalid_domain, -6503);
    begin
        return 'TODO: ascii_to_domain';
    end;
end;
/
