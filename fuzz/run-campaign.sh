#!/bin/sh
# Bounded fuzz campaign driver: 14 targets x 300s, at most 2 in parallel
# (CPU courtesy). Per-target stdout/stderr in fuzz/logs/<t>.log.
cd "$(dirname "$0")/.." || exit 1
mkdir -p fuzz/logs fuzz/artifacts
: > fuzz/logs/status

run_one() {
    t=$1
    ASAN_OPTIONS=detect_leaks=0 fuzz/bin/fuzz_"$t" fuzz/corpus/"$t" \
        -max_total_time=300 -rss_limit_mb=4096 -timeout=25 \
        -print_final_stats=1 -artifact_prefix=fuzz/artifacts/ \
        > "fuzz/logs/$t.log" 2>&1
    rc=$?
    echo "exit $t $rc" >> fuzz/logs/status
    echo "--- done $t rc=$rc"
}

for pair in "unvis getdate" "setmode patch" "http telnet" "sh zopen" \
            "awkb grepdata" "sedcompile seddata" "awkdata patch_struct"; do
    for t in $pair; do
        run_one "$t" &
    done
    wait
done
echo "ALL TARGETS DONE"
cat fuzz/logs/status
