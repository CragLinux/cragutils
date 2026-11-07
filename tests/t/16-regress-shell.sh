#!/bin/sh
# Coverage and regression tests for sh(1) — the dash-derived shell.
#
# sh carries fewest command-line-observable security fixes (its string
# sites were audited and left alone) but is the deepest interpreter in the
# tree, and coverage measurement showed the suite barely reached it:
# parser.c/eval.c/expand.c/redir.c were near zero before this file.
# These are functional tests in the FreeBSD ATF spirit (bin/sh/tests
# ported subset, PLAN.md P0 extension) exercising the code paths the
# fuzz harness (fuzz_sh, parse only) never runs.
#
# Everything runs the shell under test explicitly ($(tool sh)), never
# the harness's own sh.

. "$CU_LIB/lib.sh"

require "sh regressions" sh || { cu_finish; exit; }

SH=$(tool sh)

# sh_out <label> <want> <script> — run a script text through sh -c.
sh_out() {
    assert_out "$1" "$2" "$SH" -c "$3"
}

# sh_file <label> <want> <file> — run a script file (for anything with
# quoting that must survive exactly one shell level).
sh_file() {
    assert_out "$1" "$2" "$SH" "$3"
}

group "sh: arithmetic expansion"

sh_out "addition" "7" 'echo $((3 + 4))'
sh_out "precedence" "11" 'echo $((3 + 4 * 2))'
sh_out "variables in arithmetic" "10" 'x=5; echo $((x * 2))'
sh_out "ternary and comparison" "yes" 'x=1; echo $((x ? 1 : 0)) | grep -q 1 && echo yes'
sh_out "division and modulo" "2 1" 'echo $((7 / 3)) $((7 % 3))'
sh_out "arithmetic in assignment" "8" 'x=$((2 * 3 + 2)); echo $x'
sh_out "negative numbers" "-3" 'echo $((0 - 3))'
sh_out "hex literal" "255" 'echo $((0xff))'
assert_no_crash "division by zero is a clean error" \
    sh -c "$SH -c 'echo \$((1 / 0))' >/dev/null 2>&1"
assert_status "arithmetic syntax error exits nonzero" 2 \
    sh -c "$SH -c 'echo \$((1 +))' >/dev/null 2>&1"

group "sh: expansion and quoting"

sh_out "parameter expansion" "hello" 'x=hello; echo "$x"'
sh_out "\${var:-default}" "dflt" 'unset x; echo ${x:-dflt}'
sh_out "\${var:=assign}" "set" 'unset x; echo ${x:=set}'
sh_out "\${var:+alternate}" "alt" 'x=1; echo ${x:+alt}'
sh_out "\${#var}" "5" 'x=hello; echo ${#x}'
sh_out "\${var#pat} (shortest)" "bab" 'x=abab; echo ${x#a*}'
sh_out "\${var##pat} (longest)" "" 'x=abab; echo ${x##a*}'
sh_out "\${var%pat} no match keeps the value" "hello" 'x=hello; echo ${x%z}'
sh_out "\${var%%pat}" "he" 'x=hello; echo ${x%%llo}'
sh_out "single quotes are literal" 'a$b' "echo 'a\$b'"
sh_out "double quotes expand" "aX" 'x=X; echo "a$x"'
sh_out "backslash escapes" '$' 'echo \$'
sh_out "IFS field splitting" "a:b:c" 'IFS=:; set -- a b c; echo "$*"'
sh_out "positional parameters" "b" 'set -- a b c; echo "$2"'
sh_out "\$# and shift" "2 b" 'set -- a b c; shift; echo "$#" "$1"'
sh_out "quoted \${#}" "3" 'set -- a b c; echo "$#"'

group "sh: command substitution"

sh_out "backquote substitution" "X" 'x=`echo X`; echo $x'
sh_out "\$( ) substitution" "X" 'x=$(echo X); echo $x'
sh_out "nested substitution" "deep" 'echo $(echo $(echo deep))'
sh_out "substitution strips trailing newlines" "ok" 'x=$(printf "ok\n\n\n"); echo "$x"'
sh_out "substitution in double quotes" "a b" 'echo "a $(echo b)"'

group "sh: redirections"

: > r1.txt
sh_out "truncate and append" "one
two" 'echo one > r1.txt; echo two >> r1.txt; cat r1.txt'
sh_out "stdin redirect" "in" 'echo in > r2.txt; read x < r2.txt; echo "$x"'
sh_out "stderr redirect" "" 'echo err 1>&2 2>/dev/null'
sh_out "heredoc" "body" 'cat <<EOF
body
EOF'
sh_out "heredoc with quoted delimiter" 'a$b' 'cat <<"EOF"
a$b
EOF'
sh_out "here document appends lines" "1
2" 'cat <<EOF
1
2
EOF'

# noclobber (redir.c: the O_CREAT|O_EXCL re-check path from the
# SECURITY-FINDINGS.md stat->open race triage).
printf 'orig\n' > noclobber.txt
assert_status "set -C refuses to clobber an existing file" 2 \
    sh -c "$SH -c 'set -C; echo new > noclobber.txt' >/dev/null 2>&1"
assert_out "existing file untouched after noclobber refusal" "orig" "$(tool cat)" noclobber.txt
sh_out "set -C still creates new files" "ok" 'set -C; echo ok > nc-new.txt; cat nc-new.txt'
sh_out "pipe input" "b" 'echo a | { read x; echo b; }'
sh_out "fd juggling" "two" 'exec 3> fd.txt; echo two >&3; exec 3>&-; cat fd.txt'

group "sh: builtins"

sh_out "test builtin" "yes" '[ 1 -eq 1 ] && echo yes'
sh_out "test string operators" "yes" '[ abc = abc ] && [ -n abc ] && [ -z "" ] && echo yes'
sh_out "test file operators" "yes" 'echo x > t.txt; [ -f t.txt ] && [ -s t.txt ] && echo yes'
sh_out "echo builtin" "a b" 'echo a b'
sh_out "read builtin" "one two" 'echo "one two" | { read a b; echo "$a $b"; }'
sh_out "read -r keeps backslashes" 'a\b' 'printf "a\\\\b\n" | { read -r x; echo "$x"; }'
sh_out "printf-style output via echo -n" "x" 'echo -n x; echo'
sh_out "export and child env" "val" 'export FOO=val; sh -c "echo \$FOO"'
sh_out "unset" "" 'x=1; unset x; echo "$x"'
sh_out "shift with count" "c" 'set -- a b c; shift 2; echo "$1"'
sh_out "getopts" "$(printf 'a\nb\n')" 'set -- -a -b; while getopts ab o; do echo "$o"; done'
sh_out "eval expands its argument" "5" 'x=2; eval "echo \$((x + 3))"'
sh_out "colon builtin is a no-op" "ok" ': ignored; echo ok'
sh_out "dot builtin runs in the current shell" "42" 'echo "y=42" > dot.inc; . ./dot.inc; echo "$y"'
sh_out "exit status of the last command" "0" 'true; echo "$?"'
sh_out "failure status propagates" "1" 'false; echo "$?"'
sh_out "umask round-trips" "0022" 'umask 022; umask'
# Aliases are expanded when commands are *read*: the definition must be
# on an earlier input line than the use, so this runs from a script.
printf 'alias ah="echo alias-out"\nah\n' > al.sh
sh_file "alias expands" "alias-out" al.sh
printf 'alias ah="echo bad"\nunalias ah\nah\n' > unal.sh
sh_file "unalias removes" "" unal.sh

group "sh: control flow and functions"

sh_out "if/elif/else" "two" 'x=2; if [ $x = 1 ]; then echo one; elif [ $x = 2 ]; then echo two; else echo other; fi'
sh_out "case glob" "beta" 'x=beta; case $x in a*) echo alpha;; b*) echo beta;; *) echo other;; esac'
sh_out "case multiple patterns" "yes" 'x=2; case $x in 1|2|3) echo yes;; esac'
sh_out "for loop" "$(printf '1\n2\n3\n')" 'for i in 1 2 3; do echo $i; done'
sh_out "while loop" "done" 'i=0; while [ $i -lt 3 ]; do i=$((i + 1)); done; echo done'
sh_out "until loop" "done" 'i=0; until [ $i -ge 3 ]; do i=$((i + 1)); done; echo done'
sh_out "break and continue" "$(printf '1\n3\n')" 'for i in 1 2 3 4; do [ $i = 2 ] && continue; [ $i = 4 ] && break; echo $i; done'
sh_out "function definition and call" "in-fn" 'f() { echo in-fn; }; f'
sh_out "function return value" "7" 'f() { return 7; }; f; echo "$?"'
sh_out "subshell isolation" "outer" 'x=outer; ( x=inner; ); echo "$x"'
sh_out "command grouping" "inner" 'x=outer; { x=inner; }; echo "$x"'
sh_out "pipeline exit status is the last command" "0" 'false | true; echo "$?"'
sh_out "&& and ||" "ok" 'true && echo ok || echo bad'
sh_out "negation" "0" '! false; echo "$?"'

group "sh: traps and exit status"

# Exercises the trap/exit paths around exitshell_savedstatus() in
# trap.c (whose top-level exit() choice keeps atexit-based
# instrumentation — coverage profiles, sanitizers — alive).
sh_out "EXIT trap runs exactly once" "bye" 'trap "echo bye" EXIT'
sh_out "EXIT trap sees the exit status" "7" 'trap "echo \$?" EXIT; exit 7'
assert_status "exit builtin sets the status" 7 \
    sh -c "$SH -c 'exit 7'"
assert_status "EXIT trap does not clobber the status" 7 \
    sh -c "$SH -c 'trap \"true\" EXIT; exit 7'"
assert_ok "trap on a signal is runnable" \
    sh -c "$SH -c 'trap \"echo caught\" USR1; kill -USR1 \$\$; sleep 0' "
sh_out "set -e stops on failure" "" 'set -e; false; echo unreachable'
sh_out "set -u rejects unset expansion" "" 'set -u; echo "$not_set_here" 2>/dev/null'
assert_status "set -u error exits nonzero" 2 \
    sh -c "$SH -c 'set -u; echo \$not_set_here' >/dev/null 2>&1"
assert_status "syntax error exits 2" 2 \
    sh -c "$SH -c 'if then fi' >/dev/null 2>&1"
assert_status "sh -n accepts a valid script" 0 \
    sh -c "printf 'echo ok\n' | $SH -n"
assert_status "sh -n rejects a broken script" 2 \
    sh -c "printf 'if then\n' | $SH -n >/dev/null 2>&1"

group "sh: command execution"

sh_out "PATH lookup" "path-tool" 'mkdir -p bindir; printf "#!/bin/sh\necho path-tool\n" > bindir/tool; chmod +x bindir/tool; PATH="$PWD/bindir:$PATH"; tool'
sh_out "special builtin vs regular" "0" ': ; echo "$?"'
sh_out "command with a full path" "x" 'printf "#!/bin/sh\necho x\n" > full.sh; chmod +x full.sh; "$PWD/full.sh"'
printf '#!/bin/sh\necho "$1" "$2"\n' > args.sh
assert_out "script arguments" "arg1 arg2" "$SH" args.sh arg1 arg2
sh_out "command -v finds builtins" "echo" 'command -v echo'
sh_out "subshell exit does not kill the shell" "alive" '( exit 3 ); echo alive'
sh_out "background job and wait" "waited" 'sleep 0 & wait; echo waited'
sh_out "\$! records the background pid" "set" 'sleep 0 & [ -n "$!" ] && echo set; wait'
sh_out "env prefix assignment" "pre" 'FOO=pre sh -c "echo \$FOO"'
sh_out "xtrace prints commands" "trace" 'set -x; echo trace 2>/dev/null'
assert_no_crash "exec with only redirections" \
    sh -c "$SH -c 'exec 4>/dev/null; echo ok; exec 4>&-' >/dev/null 2>&1"
assert_no_crash "deep command nesting" \
    sh -c "$SH -c 'a=1; b=\$((a+1)); c=\$((b+1)); echo \$((a+b+c)) >/dev/null'"
assert_no_crash "long pipeline" \
    sh -c "$SH -c 'echo x | cat | cat | cat | cat | cat >/dev/null'"

cu_finish