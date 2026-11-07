#!/bin/sh
# ci/jobs/coverage.sh — clang source-based coverage over the functional
# suite (llvm-cov), reporting per-tool line coverage of the code carrying
# security fixes.
#
# Gating policy: this job is GATING for process (the build must succeed,
# the suite must pass, llvm-cov must produce a report) and NON-GATING for
# the percentages — there is deliberately no coverage threshold, because
# the per-tool numbers are a triage aid ("which patched code paths do the
# regression tests still not reach?"), not a quality gate.  A drop in a
# percentage never fails CI; a failing test does.
#
# Parameterised by the environment like build-test.sh:
#   CC, CXX        compiler (default: clang/clang++; needs source-based
#                  coverage support, i.e. clang)
#   BUILD_DIR      build tree (default: build-ci-cov)
#   PROF_DIR       profile output directory (default: $BUILD_DIR/profiles)
#   TEST_FILTERS   test files to run (default: the full suite)
#   REPORT_ONLY=1  skip build + suite; merge + report an existing
#                  PROF_DIR (used for before/after comparisons)
#
# Requires: clang with -fprofile-instr-generate/-fcoverage-mapping,
# llvm-profdata and llvm-cov (same major version as the compiler), meson,
# ninja.  posix sh only.
set -eu

cd "$(dirname "$0")/../.."

CC=${CC:-clang}
CXX=${CXX:-clang++}
BUILD_DIR=${BUILD_DIR:-build-ci-cov}
PROF_DIR=${PROF_DIR:-$BUILD_DIR/profiles}
TEST_FILTERS=${TEST_FILTERS:-}
REPORT_ONLY=${REPORT_ONLY:-0}

COVFLAGS="-fprofile-instr-generate -fcoverage-mapping"

if ! command -v llvm-cov >/dev/null 2>&1 || ! command -v llvm-profdata >/dev/null 2>&1; then
    printf 'coverage.sh: llvm-cov and llvm-profdata are required\n' >&2
    exit 2
fi

if [ "$REPORT_ONLY" != "1" ]; then
    printf '=== configure (%s, coverage instrumentation)\n' "$CC"
    rm -rf "$BUILD_DIR"
    # shellcheck disable=SC2086
    CC="$CC" CXX="$CXX" \
        CFLAGS="$COVFLAGS" CXXFLAGS="$COVFLAGS" LDFLAGS="-fprofile-instr-generate" \
        meson setup "$BUILD_DIR" -Dbuildtype=debugoptimized

    printf '=== build\n'
    ninja -C "$BUILD_DIR"

    printf '=== functional suite (profile collection)\n'
    rm -rf "$PROF_DIR"
    mkdir -p "$PROF_DIR"
    # Each tool process dumps its own .profraw (the %m module hash keeps
    # the ~150 binaries from clobbering each other's profiles).
    # shellcheck disable=SC2086
    LLVM_PROFILE_FILE="$PWD/$PROF_DIR/%p-%m.profraw" \
        sh tests/run-tests.sh --build "$BUILD_DIR" $TEST_FILTERS
fi

nprof=$(find "$PROF_DIR" -name '*.profraw' 2>/dev/null | wc -l | tr -d ' ')
if [ "$nprof" -eq 0 ]; then
    printf 'coverage.sh: no profiles found in %s\n' "$PROF_DIR" >&2
    exit 2
fi

printf '=== merge %s profiles\n' "$nprof"
llvm-profdata merge -sparse "$PROF_DIR"/*.profraw -o "$PROF_DIR/merged.profdata"

# ---------------------------------------------------------------------
# Per-tool report over the security-relevant sources.
#
# Each row maps a tool label to its binary and the source subtrees the
# SECURITY-FINDINGS.md fixes live in.  libcompat files (unvis/vis/setmode)
# are statically linked into several tools; the merged profile sums the
# executions of every binary containing them, which is what we want here
# ("how much of this patched file has the suite exercised"), but it does
# mean those rows are suite-wide, not single-tool.
# ---------------------------------------------------------------------

report_row() {
    # report_row <label> <binary-name> <src-pattern>...
    _label=$1; _bin=$2; shift 2
    _exe=$(find "$BUILD_DIR" -type f -name "$_bin" -perm -u+x ! -path '*.p/*' 2>/dev/null | head -1)
    if [ -z "$_exe" ]; then
        printf '%-8s  (binary %s not built)\n' "$_label" "$_bin"
        return 0
    fi
    _data="$PROF_DIR/merged.profdata"
    _rows=$(llvm-cov report "$_exe" -instr-profile="$_data" 2>/dev/null)
    if [ -z "$_rows" ]; then
        printf '%-8s  (no coverage data)\n' "$_label"
        return 0
    fi
    _pat=
    for _p in "$@"; do
        _pat="$_pat|$_p"
    done
    _pat=${_pat#|}
    # Columns: 1 Filename ... 8 Lines 9 Missed 10 Cover% ... (see llvm-cov report)
    _agg=$(printf '%s\n' "$_rows" | awk -v pat="$_pat" '
        $1 ~ pat && $8 ~ /^[0-9]+$/ && $8 + 0 > 0 { l += $8; m += $9 }
        END { if (l > 0) printf "%d %d %.1f", l, m, 100 * (l - m) / l }')
    if [ -z "$_agg" ]; then
        printf '%-8s  (sources not in this binary)\n' "$_label"
        return 0
    fi
    _tl=$(set -- $_agg; printf '%s' "$1")
    _tm=$(set -- $_agg; printf '%s' "$2")
    _tp=$(set -- $_agg; printf '%s' "$3")
    printf '%-8s  %5s/%-5s lines  %6s%%  files:\n' "$_label" "$((_tl - _tm))" "$_tl" "$_tp"
    printf '%s\n' "$_rows" | awk -v pat="$_pat" -v ind="           " '
        $1 ~ pat && $8 ~ /^[0-9]+$/ && $8 + 0 > 0 {
            printf "%s%-42s %5d/%-5d  %6s\n", ind, $1, $8 - $9, $8, $10
        }'
}

printf '\n=== coverage of security-relevant sources (line coverage)\n'
printf '    (suite-wide profile; libcompat rows aggregate all tools linking them)\n\n'
report_row patch   patch  '^src.freebsd/patch/'
report_row nvi     vi     '^src.freebsd/nvi/'
report_row telnet  telnet '^src.freebsd/telnet/'
report_row fetch   fetch  '^src.freebsd/fetch/|^src.freebsd/libfetch/'
report_row awk     awk    '^src.freebsd/awk/'
report_row sed     sed    '^src.freebsd/sed/'
report_row sh      sh     '^src.freebsd/sh/'
report_row unvis   unvis  'compat/unvis[.]c'
report_row vis     vis    'compat/vis[.]c'
report_row setmode chmod  'compat/setmode[.]c'
report_row getdate find   'getdate[.]|^src.freebsd/findutils/'

printf '\n=== overall (all instrumented sources linked into the tools above)\n'
for _t in patch vi telnet fetch awk sed sh unvis vis chmod find; do
    _exe=$(find "$BUILD_DIR" -type f -name "$_t" -perm -u+x ! -path '*.p/*' 2>/dev/null | head -1)
    [ -n "$_exe" ] || continue
    printf '%-8s  ' "$_t"
    llvm-cov report "$_exe" -instr-profile="$PROF_DIR/merged.profdata" -summary-only 2>/dev/null | \
        awk '/^TOTAL/ { printf "%s/%s lines  %s\n", $8 - $9, $8, $10 }'
done
