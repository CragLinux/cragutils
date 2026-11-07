#!/bin/sh
# Static analysis gate: gcc -fanalyzer and clang scan-build over the whole
# tree, compared against the checked-in findings baseline.
#
# Both analyzers flag a large, long-triaged set of known issues (verdicts
# in SECURITY-FINDINGS.md), so raw counts gate nothing.  Every warning is
# normalized to a signature ("checker file") and compared against the
# sorted lists in ci/static-baseline/:
#   - a signature in the current run but not in the baseline is a NEW
#     finding and fails the job;
#   - a baseline signature that no longer fires is reported so the
#     baseline can be tightened.
#
# The signature set is toolchain-sensitive: gcc/clang major versions add
# and remove diagnostics.  After a deliberate toolchain bump, regenerate
# the baseline with STATIC_BASELINE_UPDATE=1 and triage the delta before
# committing it.
#
# Environment:
#   BUILD_DIR                scratch trees (default: build-ci-static)
#   STATIC_BASELINE=0        analyze and report, but do not gate
#   STATIC_BASELINE_UPDATE=1 rewrite ci/static-baseline/ from this run
set -eu

cd "$(dirname "$0")/../.."

BUILD_DIR=${BUILD_DIR:-build-ci-static}
GATE=${STATIC_BASELINE:-1}
UPDATE=${STATIC_BASELINE_UPDATE:-0}
basedir=ci/static-baseline

fail=0

# norm_path — strip build-directory and ../ noise so the same source file
# yields the same signature on any machine.
norm_path() {
    sed 's|^.*\(src\.[A-Za-z0-9]*/\)|\1|'
}

# signatures_from_gcc <build-log> <out>
signatures_from_gcc() {
    sed -n 's|^[^ ]*:[0-9][0-9]*:[0-9][0-9]*: warning: .*\[\(-W[A-Za-z0-9_+-]*\)\]$|\1|p' "$1" > "$BUILD_DIR/.flags"
    sed -n 's|^\([^ ][^:]*\):[0-9][0-9]*:[0-9][0-9]*: warning: .*\[-W[A-Za-z0-9_+-]*\]$|\1|p' "$1" \
        | norm_path > "$BUILD_DIR/.files"
    paste "$BUILD_DIR/.flags" "$BUILD_DIR/.files" | sort -u > "$2"
    rm -f "$BUILD_DIR/.flags" "$BUILD_DIR/.files"
}

# signatures_from_scanbuild <report-dir> <out>
signatures_from_scanbuild() {
    : > "$2.unsorted"
    for f in "$1"/report-*.html; do
        [ -f "$f" ] || continue
        type=$(sed -n 's/.*BUGTYPE \(.*\) -->.*/\1/p' "$f" | head -n 1)
        file=$(sed -n 's/.*BUGFILE \(.*\) -->.*/\1/p' "$f" | head -n 1)
        [ -n "$type" ] || continue
        printf '%s %s\n' "$type" "$file" >> "$2.unsorted"
    done
    sort -u "$2.unsorted" | norm_path > "$2"
    rm -f "$2.unsorted"
}

# compare <label> <current-sigs> <baseline-name>
compare() {
    _label=$1; _cur=$2; _base="$basedir/$3"

    if [ "$UPDATE" = "1" ]; then
        cp "$_cur" "$_base"
        printf '=== %s: baseline updated (%s signatures)\n' \
            "$_label" "$(wc -l < "$_base" | tr -d ' ')"
        return 0
    fi

    if [ ! -f "$_base" ]; then
        printf '=== %s: no baseline at %s (run with STATIC_BASELINE_UPDATE=1)\n' \
            "$_label" "$_base" >&2
        fail=1
        return 0
    fi

    _new=$(comm -13 "$_base" "$_cur")
    _gone=$(comm -23 "$_base" "$_cur")
    printf '=== %s: %s signatures (%s in baseline)\n' \
        "$_label" "$(wc -l < "$_cur" | tr -d ' ')" \
        "$(wc -l < "$_base" | tr -d ' ')"

    if [ -n "$_gone" ]; then
        printf '%s\n' "$_gone" | sed 's/^/  resolved: /'
    fi
    if [ -n "$_new" ]; then
        printf '%s\n' "$_new" | sed 's/^/  NEW FINDING: /'
        if [ "$GATE" = "1" ]; then
            fail=1
        else
            printf '  (STATIC_BASELINE=0: not gating)\n'
        fi
    fi
}

mkdir -p "$BUILD_DIR" "$basedir"

printf '=== configure (gcc -fanalyzer)\n'
rm -rf "$BUILD_DIR-gcc"
CC=gcc CFLAGS=-fanalyzer meson setup "$BUILD_DIR-gcc" \
    -Dbuildtype=debugoptimized >/dev/null

printf '=== build (gcc -fanalyzer)\n'
# Analyzer warnings go to stderr alongside ninja progress.
if ! ninja -C "$BUILD_DIR-gcc" > "$BUILD_DIR/gcc-build.log" 2>&1; then
    sed -n '$p' "$BUILD_DIR/gcc-build.log" >&2
    printf 'static.sh: gcc -fanalyzer build failed\n' >&2
    exit 1
fi
gcc_warns=$(grep -c 'warning:' "$BUILD_DIR/gcc-build.log" || true)
printf '    %s warnings\n' "$gcc_warns"

signatures_from_gcc "$BUILD_DIR/gcc-build.log" "$BUILD_DIR/gcc.sigs"

printf '=== scan-build\n'
rm -rf "$BUILD_DIR-scan" "$BUILD_DIR/scanbuild-out"
scan-build -o "$BUILD_DIR/scanbuild-out" meson setup "$BUILD_DIR-scan" \
    -Dbuildtype=debugoptimized >/dev/null 2>&1
if ! scan-build -o "$BUILD_DIR/scanbuild-out" ninja -C "$BUILD_DIR-scan" \
    > "$BUILD_DIR/scan-build.log" 2>&1; then
    sed -n '$p' "$BUILD_DIR/scan-build.log" >&2
    printf 'static.sh: scan-build build failed\n' >&2
    exit 1
fi
rep=$(find "$BUILD_DIR/scanbuild-out" -mindepth 1 -maxdepth 1 -type d | head -n 1)
if [ -z "$rep" ]; then
    printf 'static.sh: no scan-build report directory\n' >&2
    exit 1
fi
printf '    %s\n' "$(grep 'bugs found' "$BUILD_DIR/scan-build.log" || echo 'no bugs found')"

signatures_from_scanbuild "$rep" "$BUILD_DIR/scanbuild.sigs"

compare "gcc -fanalyzer" "$BUILD_DIR/gcc.sigs" gcc-analyzer.txt
compare "scan-build" "$BUILD_DIR/scanbuild.sigs" scanbuild.txt

printf '\n========================================\n'
if [ "$fail" = "1" ]; then
    printf 'static: NEW findings above the recorded baseline\n'
    printf 'triage them in SECURITY-FINDINGS.md; regenerate the baseline\n'
    printf 'only once every new signature carries a verdict\n'
    exit 1
fi
printf 'static: no new findings\n'
