#!/bin/sh
#
# smoke.sh - smoke proof that the FreeBSD oracle works and is genuinely
#            FreeBSD (PLAN.md P9).  Runs a battery of real BSD tools in
#            the guest via run-on-freebsd.sh, decodes the framed results,
#            and demonstrates at least one case where the GNU host's
#            output for the same argv differs.
#
# Usage: ./smoke.sh          (VM must already be running: ./vm.sh start)
#        ./smoke.sh | tee evidence/smoke-run1.txt
#
# Exit status: 0 if every battery case behaved as expected.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/common.sh"

RUNNER="$HERE/run-on-freebsd.sh"
FAILURES=0

frame_show() {
    # frame_show <frame-file> <label> : decode a crag-diff-run frame
    f=$1; label=$2
    hb=$(sed -n '1,/^$/p' "$f" | wc -c); hb=$((hb))
    rc=$(sed -n 's/^exit_status: \([0-9][0-9]*\)$/\1/p' "$f" | head -n 1)
    so=$(sed -n 's/^stdout_bytes: \([0-9][0-9]*\)$/\1/p' "$f" | head -n 1)
    se=$(sed -n 's/^stderr_bytes: \([0-9][0-9]*\)$/\1/p' "$f" | head -n 1)
    printf '=== %s ===\n' "$label"
    printf 'exit_status: %s  stdout_bytes: %s  stderr_bytes: %s\n' "$rc" "$so" "$se"
    printf -- '--- guest stdout ---\n'
    tail -c +$((hb + 1)) "$f" | head -c "$so"
    printf -- '--- guest stderr ---\n'
    tail -c +$((hb + 1)) "$f" | tail -c +$((so + 1)) | head -c "$se"
    printf -- '--- end ---\n\n'
}

run_case() {
    # run_case <label> <command> <want-exit> [check-mode]
    #   check-mode: 'expect' (default; want-exit must match) or 'any'
    label=$1; cmd=$2; want=$3; mode=${4:-expect}
    f=$(mktemp "${TMPDIR:-/tmp}/smoke-frame.XXXXXX")
    if ! "$RUNNER" "$cmd" > "$f"; then
        printf '=== %s ===\nRUN-ON-FREEBSD FAILED (no frame)\n\n' "$label"
        FAILURES=$((FAILURES + 1))
        rm -f "$f"
        return 0
    fi
    frame_show "$f" "$label"
    rc=$(sed -n 's/^exit_status: \([0-9][0-9]*\)$/\1/p' "$f" | head -n 1)
    if [ "$mode" = "expect" ] && [ "$rc" != "$want" ]; then
        printf '*** FAIL: %s: exit_status=%s, wanted %s\n\n' "$label" "$rc" "$want"
        FAILURES=$((FAILURES + 1))
    fi
    rm -f "$f"
}

host_case() {
    # host_case <label> <command> : same argv against host GNU tools
    printf '=== HOST GNU: %s ===\n' "$1"
    printf -- '--- host stdout ---\n'
    sh -c "$2" 2>/dev/null || true
    printf -- '--- host stderr ---\n'
    sh -c "$2" 2>&1 >/dev/null || true
    printf -- '--- end ---\n\n'
}

printf '## FreeBSD oracle smoke battery\n'
printf '## host: %s\n' "$(uname -srm)"
printf '## run: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

printf -- '--- identity: prove the oracle is really FreeBSD ---\n\n'
run_case 'uname -srm' 'uname -srm' 0
run_case 'uname -a' 'uname -a' 0

printf -- '--- required battery: date, sed, awk, sort, stat -f, jot, printf, cut, find, uname ---\n\n'
run_case 'date' 'date' 0 any
run_case "sed" "printf 'hello world\n' | sed 's/world/crag/'" 0
run_case 'awk' "printf '3\n1\n2\n' | awk '{ s += \$1 } END { print s }'" 0
run_case 'sort' "printf 'beta\nalpha\ngamma\n' | sort" 0
run_case 'stat -f (BSD format)' "stat -f '%N size=%z mode=%Sp' /etc/passwd" 0
run_case 'jot 5' 'jot 5' 0
run_case 'printf' "/usr/bin/printf '%d-%s-%05.2f\n' 7 mid 3.14159" 0
run_case 'cut' "printf 'a:b:c\n' | cut -d: -f2" 0
run_case 'find' "find /etc -maxdepth 1 -type f -name 'ttys' -print" 0

printf -- '--- frame protocol: stderr, nonzero exit, stdin, binary safety ---\n\n'
run_case 'mixed streams + exit 3' 'echo out; echo err >&2; exit 3' 3
printf '=== stdin passthrough (host stdin "a b c" -> guest wc -w) ===\n'
f=$(mktemp "${TMPDIR:-/tmp}/smoke-frame.XXXXXX")
printf 'a b c\n' | "$RUNNER" 'wc -w' > "$f"
frame_show "$f" 'stdin passthrough'
rm -f "$f"
printf '=== binary-safe payloads (guest stdout "a\\0b") ===\n'
f=$(mktemp "${TMPDIR:-/tmp}/smoke-frame.XXXXXX")
"$RUNNER" "printf 'a\\000b'" > "$f"
frame_show "$f" 'binary stdout'
printf 'payload hexdump: '
hb=$(sed -n '1,/^$/p' "$f" | wc -c); hb=$((hb))
so=$(sed -n 's/^stdout_bytes: \([0-9][0-9]*\)$/\1/p' "$f" | head -n 1)
tail -c +$((hb + 1)) "$f" | head -c "$so" | od -An -tx1
printf '\n'
rm -f "$f"

printf -- '--- GNU divergence: same argv on the host must DIFFER (oracle is the reference) ---\n\n'
run_case 'guest: stat -f (BSD)' "stat -f '%N size=%z mode=%Sp' /etc/passwd" 0
host_case 'stat -f (GNU)' "stat -f '%N size=%z mode=%Sp' /etc/passwd"
run_case 'guest: date -r (BSD epoch seconds)' 'date -u -r 1000000000' 0
host_case 'date -r (GNU = reference file)' 'date -u -r 1000000000'
run_case 'guest: jot 5 (BSD only)' 'jot 5' 0
host_case 'jot 5 (absent on GNU)' 'jot 5'

printf -- '--- per-command overhead (run-on-freebsd.sh round trip, 20 x `:`) ---\n\n'
T0=$(date +%s.%N)
i=0
while [ "$i" -lt 20 ]; do
    "$RUNNER" ':' >/dev/null
    i=$((i + 1))
done
T1=$(date +%s.%N)
awk -v s="$T0" -v e="$T1" -v n=20 \
    'BEGIN { printf "overhead: total %.2fs for %d commands, mean %.0f ms/command\n", e - s, n, (e - s) * 1000 / n }'
T0=$(date +%s.%N)
i=0
while [ "$i" -lt 20 ]; do
    oracle_ssh true 2>/dev/null
    i=$((i + 1))
done
T1=$(date +%s.%N)
awk -v s="$T0" -v e="$T1" -v n=20 \
    'BEGIN { printf "baseline (raw ssh true): total %.2fs, mean %.0f ms/command\n\n", e - s, (e - s) * 1000 / n }'

if [ "$FAILURES" -eq 0 ]; then
    printf '## SMOKE RESULT: PASS (all expectations met)\n'
else
    printf '## SMOKE RESULT: FAIL (%s unexpected results)\n' "$FAILURES"
    exit 1
fi
