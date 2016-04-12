create or replace package body idn is
    -- constants
    initial_n    constant number           := 128;
    initial_bias constant number           := 72;
    delimiter    constant varchar2(1 char) := unistr('\002D');
    damp         constant number           := 700;
    base         constant number           := 36;
    tmin         constant number           := 1;
    tmax         constant number           := 26;
    skew         constant number           := 38;
    maxint       constant number           := 2147483647; -- 0x7fffffff
    idn_prefix   constant varchar2(4 char) := 'xn--';
    backslash    constant varchar2(1 char) := unistr('\005C');

-- version
function VERSION (v varchar2 := '0.02') return varchar2 is begin return v; end;

    -- private
    function get_token (
        str nvarchar2,
        i   number,
        sep nvarchar2 := '.'
    ) return nvarchar2 deterministic is
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
               head := head + nvl(length(sep), 0);
            end if;
        end if;
        tail := instr(str, sep, head, 1);
        if tail = 0 then
            return substr(str, head);
        else
            return substr(str, head, tail - head);
        end if;
    end;

    -- http://www.sqlsnippets.com/en/topic-13438.html
    function unicode_point (
        c nvarchar2
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

    -- http://codezine.jp/article/detail/1592
    function unicode_string (
        n number
    ) return nvarchar2 deterministic is
        offset constant number := 65536; -- 0x10000
        x    number := n - offset;
        high number := trunc(x / 1024) + 55296; -- 0xD800
        low  number := mod(x, 1024) + 56320; -- 0xDC00
    begin
        if (n is null) then
            return null;
        end if;

        if (x < 0) then
            return unistr(backslash || lpad(to_char(n, 'FMXXXX'), 4, '0'));
        end if;

        -- surrogate pair
        return unistr( backslash
                    || lpad(to_char(high, 'FMXXXX'), 4, '0')
                    || backslash
                    || lpad(to_char(low, 'FMXXXX'), 4, '0'));
    end;

    -- decode_digit(cp) returns the numeric value of a basic code point (for
    -- use in representing integers) in the range 0 to base-1, or base if cp is
    -- does not represent a value.
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

    -- Bias adaptation function
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
            delta := trunc(delta / 2);
        end if;

        delta := delta + trunc(delta / numpoints);

        loop
            exit when (delta <= (((base - tmin) * tmax) / 2));

            delta := trunc(delta / (base - tmin));

            k := k + base;
        end loop;

        return trunc(k + (base - tmin + 1) * delta / (delta + skew));
    end;

    -- encode_basic(bcp,flag) forces a basic code point to lowercase if flag is
    -- zero, uppercase if flag is nonzero, and returns the resulting code
    -- point.  The code point is unchanged if it is caseless.  The behavior is
    -- undefined if bcp is not a basic code point.
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

    function decode_punycode (
        input nvarchar2,
        preserve_case boolean := false
    ) return nvarchar2 deterministic is
        illegal_input exception;
        pragma exception_init(illegal_input, -6502);
        range_error exception;
        pragma exception_init(range_error, -6503);
        type string_array is varray(255) of nvarchar2(5); -- length('\HHHH')
        output_arr string_array := string_array();
        output     nvarchar2(256) := '';
        case_flags varchar2(256);
        input_len  number := nvl(length(input), 0);
        n          number := initial_n;
        o          number := 0;
        i          number := 0;
        ic         number := 0;
        bias       number := initial_bias;
        basic      number := instr(input, delimiter, -1, 1) - 1;
        j          number;
        oldi       number;
        w          number;
        k          number;
        digit      number;
        t          number;
    begin
        -- Handle the basic code points: Let basic be the number of input code
        -- points before the last delimiter, or 0 if there is none, then
        -- copy the first basic code points to the output.
        if (basic < 0) then
            basic := 0;
        end if;

        -- Main decoding loop: Start just after the last delimiter if any
        -- basic code points were copied; start at the beginning otherwise.
        for j in 1 .. basic loop
            if (unicode_point(substr(input, j, 1)) >= 128) then -- 128 == 0x80
                raise illegal_input;
            end if;
            output_arr.extend;
            output_arr(j) := substr(input, j, 1);
            o := o + 1;
        end loop;

        if (basic > 0) then
            ic := basic + 1;
        end if;

        -- ic is the index of the next character to be consumed,
        while (ic < input_len) loop
            oldi := i;
            w := 1;
            k := base;

            -- Decode a generalized variable-length integer into delta,
            -- which gets added to i. The overflow checking is easier
            -- if we increase i as we go, then subtract off its starting
            -- value at the end to obtain delta.
            loop
                if (ic >= input_len) then
                    raise range_error;
                end if;

                ic := ic + 1;
                digit := decode_digit(ascii(substr(input, ic, 1)));

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

                w := w * (base - t);

                k := k + base;
            end loop;

            o := o + 1;
            bias := adapt(i - oldi, o, oldi = 0);

            -- i was supposed to wrap around from out to 0,
            -- incrementing n each time, so we'll fix that now:
            if (trunc(i / o) > maxint - n) then
                raise range_error;
            end if;

            n := n + trunc(i / o);
            i := mod(i, o);

            -- Insert n at position i of the output:
            -- Case of last character determines uppercase flag:
            -- TODO: preserve_case
            -- if (preserve_case) then
                -- case_flags.splice(i, 0, input.charCodeAt(ic -1) -65 < 26);
            -- end if;

            -- splice(output_arr, i, 0, n)
            output_arr.extend;
            for j in 1 .. (output_arr.count - i) loop
                exit when (output_arr.count -j < 1);
                output_arr(output_arr.count - j + 1)
                    := output_arr(output_arr.count - j);
            end loop;
            output_arr(i + 1) := unicode_string(n);

            i := i + 1;
        end loop;

        -- TODO: preserve_case
        -- if (preserve_case) then
            -- for (i = 0, len = output.length; i < len; i++) {
            --     if (case_flags[i]) {
            --         output[i] = (String.fromCharCode(output[i]).toUpperCase()).charCodeAt(0);
            --     }
            -- }
        -- end if;

        for j in 1 .. output_arr.count loop
            output := output || output_arr(j);
        end loop;

        return output;
    exception
        when illegal_input then return null;
        when range_error   then return null;
    end;

    function encode_punycode (
        input         nvarchar2,
        preserve_case boolean := false
    ) return varchar2 deterministic is
        range_error exception;
        pragma exception_init(range_error, -6503);
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
        -- case_flags   varchar2(1);
        input_length number           := nvl(length(input), 0);
        output       varchar2(256)    := '';
        c            nvarchar2(1 char);
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
                    -- Represent delta as a generalized variable-length integer
                    loop
                        t := case when k <= bias        then tmin
                                  when k >= bias + tmax then tmax
                             else k - bias end;

                        exit when (q < t);

                        output
                            := output
                            || chr(encode_digit(t + mod(q-t, base-t), false));

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
        domain nvarchar2
    ) return varchar2 is
        invalid_domain exception;
        pragma exception_init(invalid_domain, -6503);
        dot_count number
            := nvl(length(domain), 0) - nvl(length(replace(domain, '.')), 0);
        part nvarchar2(256) := '';
        ret  nvarchar2(256) := '';
        i    number;
    begin
        for i in 0 .. dot_count loop
            part := get_token(domain, i + 1);

            if (part != asciistr(part)) then
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

    -- public
    function ascii_to_domain (
        domain varchar2
    ) return nvarchar2 is
        invalid_domain exception;
        pragma exception_init(invalid_domain, -6503);
        dot_count number
            := nvl(length(domain), 0) - nvl(length(replace(domain, '.')), 0);
        idn_prefix_len number := nvl(length(idn_prefix), 0);
        part nvarchar2(256) := '';
        ret  nvarchar2(256) := '';
        i    number;
    begin
        for i in 0 .. dot_count loop
            part := get_token(domain, i + 1);

            if (substr(part, 1, idn_prefix_len) = idn_prefix) then
                part := decode_punycode(substr(part, idn_prefix_len + 1));
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
end;
/
