#!/bin/sh
# Regression tests ported from FreeBSD's own test suites for the most
# patched tools (PLAN.md P0 extension: "port a subset of FreeBSD's ATF
# tests").
#
# Sources, converted to this harness's assertions:
#   - usr.bin/sed/tests/regress.sh (+ regress.*.out): inputs and expected
#     outputs byte-identical to FreeBSD's checked-in *.out files.
#   - usr.bin/sed/tests/sed2_test.sh (atf-sh cases): same cases; scripts
#     and inputs are rebuilt through printf files so the backslashes
#     survive exactly one level of shell quoting (see 13-regress-parsers).
#   - usr.bin/awk/tests (bugs-fixed / onetrueawk lineage): the b.c regex
#     defect classes from SECURITY-FINDINGS.md plus interpreter cases.
#
# sed and awk carry real fixes (sed: cspace NULL memmove, per-s regex_t
# leak, compile.c triage; awk: six b.c bug classes + nested-bound DoS),
# so upstream behavioural coverage doubles as regression cover: a future
# FreeBSD import that reverts a fix usually breaks these too.

. "$CU_LIB/lib.sh"

group "sed: FreeBSD usr.bin/sed/tests/regress.sh (ported)"

if require "sed (ATF port)" sed; then
    printf 'input\ndata\nfor validation\nof sed(1)\n' > regress.in

    assert_out "sed G appends the (empty) hold space" "$(printf 'input\n\ndata\n\nfor validation\n\nof sed(1)\n')" \
        sh -c "$(tool sed) G < regress.in"
    assert_out "sed P prints the first line twice" "$(printf 'input\ninput\ndata\ndata\nfor validation\nfor validation\nof sed(1)\nof sed(1)\n')" \
        sh -c "$(tool sed) P < regress.in"
    assert_out "sed \$!g;P;D (psl)" "$(printf '\n\n\nof sed(1)\n')" \
        sh -c "$(tool sed) '\$!g;P;D' < regress.in"
    assert_out "sed y/// (y)" "fOO" \
        sh -c "printf 'foo' | $(tool sed) y/o/O/"
    assert_out "sed s/,*/,/g (sg)" ",f,o,o," \
        sh -c "echo foo | $(tool sed) 's/,*/,/g'"
    assert_out "sed s/,*/,/3 (s3)" "fo,o" \
        sh -c "echo foo | $(tool sed) 's/,*/,/3'"
    assert_out "sed s/,*/,/4 (s4)" "foo," \
        sh -c "echo foo | $(tool sed) 's/,*/,/4'"
    assert_out "sed s/,*/,/5 (s5)" "foo" \
        sh -c "echo foo | $(tool sed) 's/,*/,/5'"
    assert_out "sed 1!!s/foo/bar/ (not)" "foo" \
        sh -c "echo foo | $(tool sed) '1!!s/foo/bar/'"

    # The c command: scripts are written to files so the backslash-newline
    # text survives exactly one level of shell quoting.
    printf 'c\\\nfoo\n' > c0.sed
    assert_out "sed c with empty address (c0)" "$(printf 'foo\nfoo\nfoo\nfoo\n')" \
        sh -c "$(tool sed) -f c0.sed < regress.in"
    printf '4,$c\\\nfoo\n' > c1.sed
    assert_out "sed 4,\$c (c1)" "$(printf 'input\ndata\nfor validation\nfoo\n')" \
        sh -c "$(tool sed) -f c1.sed < regress.in"
    printf '3,9c\\\nfoo\n' > c2.sed
    assert_out "sed 3,9c past EOF (c2)" "$(printf 'input\ndata\nfoo\n')" \
        sh -c "$(tool sed) -f c2.sed < regress.in"
    printf '3,/no such string/c\\\nfoo\n' > c3.sed
    assert_out "sed 3,/no match/c (c3)" "$(printf 'input\ndata\nfoo\n')" \
        sh -c "$(tool sed) -f c3.sed < regress.in"

    printf '2,3b\n1,2d\n' > b2a.sed
    assert_out "sed branch over a delete (b2a)" "$(printf 'data\nfor validation\nof sed(1)\n')" \
        sh -c "$(tool sed) -f b2a.sed < regress.in"

    assert_out "sed /SED/Id case-insensitive delete" "$(printf 'input\ndata\nfor validation\n')" \
        "$(tool sed)" /SED/Id regress.in
    assert_out "sed s/SED/Foo/I" "$(printf 'input\ndata\nfor validation\nof Foo(1)\n')" \
        "$(tool sed)" s/SED/Foo/I regress.in
    assert_out "sed s/SED/Foo/ is case-sensitive" "$(printf 'input\ndata\nfor validation\nof sed(1)\n')" \
        "$(tool sed)" s/SED/Foo/ regress.in
    assert_out "sed s/SED/Foo/i legacy icase flag" "$(printf 'input\ndata\nfor validation\nof Foo(1)\n')" \
        "$(tool sed)" s/SED/Foo/i regress.in
fi

group "sed: FreeBSD sed2_test.sh — escapes (ported ATF cases)"

if require "sed (ATF port 2)" sed; then
    # Input per upstream: lines "a", "t\<literal \t>", "<TAB>b",
    # "<TAB><TAB>c<CR>".  Scripts are files so the exact backslash text
    # reaches sed.
    printf 'a\nt\\t\n\tb\n\t\tc\r\n' > es.a

    assert_out "delete lines containing a tab" "$(printf 'a\nt\\t\n')" \
        sh -c "$(tool sed) '/\t/d' < es.a"
    printf 's/\\t/    /g\n' > es1.sed
    assert_out "s/\\t/    /g expands tabs" "$(printf 'a\nt\\t\n    b\n        c\r\n')" \
        sh -c "$(tool sed) -f es1.sed < es.a"
    printf 's/\\t/\\t\\t/g\n' > es2.sed
    assert_out "s/\\t/\\t\\t/g doubles tabs" "$(printf 'a\nt\\t\n\t\tb\n\t\t\t\tc\r\n')" \
        sh -c "$(tool sed) -f es2.sed < es.a"
    printf 's/\\\\t//g\n' > es3.sed
    assert_out "s/\\\\t//g removes a literal backslash-t" "$(printf 'a\nt\n\tb\n\t\tc\r\n')" \
        sh -c "$(tool sed) -f es3.sed < es.a"
    printf 's/[ \\r\\t]//g\n' > es4.sed
    assert_out "s/[ \\r\\t]//g strips space, CR, tab" "abcx" \
        sh -c "printf 'a\tb c\rx\n' | $(tool sed) -f es4.sed"

    # hex_subst: \xHH conversions in the replacement.
    printf 's/\\x27/"/g\n' > hx1.sed
    assert_out "hex escape in replacement" 'test="foo"' \
        sh -c "printf \"test='foo'\" | $(tool sed) -f hx1.sed"
    printf 's/\\x2727/"/g\n' > hx2.sed
    assert_out "hex escape takes trailing digits literally" "test=\"foo'" \
        sh -c "printf \"test='27foo'\" | $(tool sed) -f hx2.sed"
    printf 's/\\xd/x/\n' > hx3.sed
    assert_out "single-digit hex escape" "xn" \
        sh -c "printf '\rn' | $(tool sed) -f hx3.sed"
    printf 's/\\xx//\n' > hx4.sed
    # FreeBSD's libc regex rejects \xx (the upstream ATF case expects
    # exit 1); glibc/musl treat \x as a literal x.  The engine-dependent
    # verdict is not portable — only the requirement not to crash is.
    assert_no_crash "escape of an ordinary character is not fatal" \
        sh -c "printf 'xx' | $(tool sed) -f hx4.sed >/dev/null 2>&1"

    # bracket_y: '[' is an ordinary character for the y command.
    assert_out "y/[/x/ with no '[' in input" "echo" \
        sh -c "echo echo | $(tool sed) 'y/[/x/'"
    assert_out "y/[]/xy/ leaves other chars alone" "echo" \
        sh -c "echo echo | $(tool sed) 'y/[]/xy/'"
    # POSIX y/// maps by position: [->x, a->y, ]->z.  (FreeBSD's checked-in
    # inline value reflects its atf harness's input mangling; the mapping
    # semantics are what matter here.)
    assert_out "y/[a]/xyz/ maps by position" "zxy" \
        sh -c "echo '][a' | $(tool sed) 'y/[a]/xyz/'"
    assert_out "y/[]/ct/" "bracket" \
        sh -c "echo 'bra[ke]' | $(tool sed) 'y/[]/ct/'"
    assert_out "y[\\[][ct[ with alternate delimiters" "bracket" \
        sh -c "echo 'bra[ke]' | $(tool sed) 'y[\[][ct['"
fi

group "sed: FreeBSD sed2_test.sh — commands and -f handling (ported)"

if require "sed (ATF port 3)" sed; then
    printf 'a\nb\nc\nd\ne\nf\n' > cd.a
    printf '/a/,/b/c\\\nx\n' > ccmd.sed
    assert_out "c command starts a new cycle" "$(printf 'x\nc\nd\ne\nf\n')" \
        sh -c "$(tool sed) -f ccmd.sed < cd.a"
    printf '/a/,/b/c\\\nx\n$!N\n' > ccmd2.sed
    assert_out "c command cycle with \$!N" "$(printf 'x\nc\nd\ne\nf\n')" \
        sh -c "$(tool sed) -f ccmd2.sed < cd.a"

    printf 'hello\n\nworld\n' > dd.a
    assert_out "P;D on an empty pattern space" "$(printf 'hello\n\nworld\n')" \
        sh -c "$(tool sed) -e 's/^//;P;D' < dd.a"
    assert_out "\$!N;P;D on an empty pattern space" "$(printf 'hello\n\nworld\n')" \
        sh -c "$(tool sed) -e 's/^//;\$!N;P;D' < dd.a"

    # commands_on_stdin: -f - reads a script from stdin, chained with
    # other -f files in order.
    printf 'a\n' > in.a
    printf 's/a/b/\n' > a_to_b.sed
    printf 's/b/c/\n' > b_to_c.sed
    printf 's/c/d/\n' > last.sed
    assert_out "-f - reads commands from stdin" "d" \
        sh -c "$(tool sed) -f a_to_b.sed -f - -f last.sed < b_to_c.sed in.a"
    printf 'i\\\nx\n' > insert_x.sed
    assert_out "no input files, no output" "" \
        sh -c "$(tool sed) -f - < insert_x.sed"

    # inplace_command_q: -i with a backup suffix and the q command.
    printf '1\n2\n3\n' > q.a
    assert_ok "sed -i.bak with q" "$(tool sed)" -i.bak '2q' q.a
    assert_out "in-place result stops at q" "$(printf '1\n2\n')" "$(tool cat)" q.a
    assert_out "backup file keeps the original" "$(printf '1\n2\n3\n')" "$(tool cat)" q.a.bak
fi

group "awk: FreeBSD usr.bin/awk/tests — ported bug-fix cases (b.c)"

if require "awk (ATF port)" awk; then
    # Repro patterns for the six b.c bug classes (SECURITY-FINDINGS.md).
    # Each must either match or fail cleanly — never die on a signal.
    assert_no_crash "regex: trailing lone backslash is a clean error" \
        sh -c "echo x | $(tool awk) '/a\\\\/ {print}' >/dev/null 2>&1"
    assert_no_crash "regex: class ending in [. is a clean error" \
        sh -c "echo x | $(tool awk) '/[[./ {print}' >/dev/null 2>&1"
    assert_no_crash "regex: class ending in [= is a clean error" \
        sh -c "echo x | $(tool awk) '/[[=/ {print}' >/dev/null 2>&1"
    assert_no_crash "regex: bare {2,3} repetition has no atom" \
        sh -c "echo x | $(tool awk) '/{2,3}/ {print}' >/dev/null 2>&1"
    assert_no_crash "regex: chained repetitions after an atom" \
        sh -c "echo x | $(tool awk) '/x{1}{1,3}/ {print}' >/dev/null 2>&1"
    # Repetition bounds cap at 255 (POSIX RE_DUP_MAX): beyond is FATAL,
    # not an integer overflow into a huge allocation.
    assert_bounded "regex: repetition bound above 255 rejected" 262144 \
        sh -c "echo x | $(tool awk) '/x{99999}/ {print}' >/dev/null 2>&1"
    # Character-class buffer growth at the 100 * 2^k terminator boundary.
    cls=$(awk 'BEGIN{s="[";for(i=0;i<105;i++)s=s sprintf("%c",65+(i%26));s=s "]";print s}')
    assert_no_crash "regex: character class over 100 elements" \
        sh -c "echo ABC | $(tool awk) -v re='$cls' '\$0 ~ re {print}' >/dev/null 2>&1"

    # Interpreter-level behaviour, upstream regression cases.
    assert_out "awk split with a regex FS" "3" \
        sh -c "echo 'a1b2c' | $(tool awk) -F'[0-9]' '{print NF}'"
    assert_out "awk gsub with &" "f[o][o]" \
        sh -c "echo foo | $(tool awk) '{gsub(/o/,\"[&]\");print}'"
    assert_out "awk printf %x" "ff" \
        sh -c "$(tool awk) 'BEGIN{printf \"%x\",255}'"
    assert_out "awk numeric for loop" "$(printf '0\n1\n2\n')" \
        sh -c "$(tool awk) 'BEGIN{for(i=0;i<3;i++)print i}'"
    assert_out "awk user function recursion" "120" \
        sh -c "$(tool awk) 'function f(n){return n<=1?1:n*f(n-1)} BEGIN{print f(5)}'"
    assert_out "awk getline from a pipe" "ok" \
        sh -c "$(tool awk) 'BEGIN{\"echo ok\"|getline x;print x}'"
    assert_out "awk CONVFMT" "1.5|2" \
        sh -c "$(tool awk) 'BEGIN{CONVFMT=\"%.1f\"; x=1.5; y=2; print x \"|\" y}'"
    assert_out "awk sub with &" "fXoXo" \
        sh -c "echo foo | $(tool awk) '{sub(/o/,\"X&X\");print}'"
    assert_out "awk match and RSTART/RLENGTH" "1 3" \
        sh -c "echo abc | $(tool awk) '{match(\$0,/abc/);print RSTART, RLENGTH}'"
    assert_out "awk arrays and delete" "1" \
        sh -c "$(tool awk) 'BEGIN{a[\"k\"]=1; delete a[\"j\"]; print a[\"k\"]}'"
fi

cu_finish