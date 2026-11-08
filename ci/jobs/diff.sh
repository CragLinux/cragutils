#!/bin/sh
# Build cragutils and run the differential corpus (PLAN.md P9) against
# the GNU host tools and the FreeBSD VM oracle.
#
# Parameterised entirely by the environment:
#   BUILD_DIR      build tree (default: build-ci-diff)
#   BINDIR        use an existing flat tool directory instead of building
#   DIFF_BACKENDS backends for tests/diff/run-diff.sh
#                  (default: cragutils,gnu,freebsd)
#   DIFF_ARGS     extra arguments for tests/diff/run-diff.sh
#
# DRIFT gating: DRIFT is the only gate-failing verdict and is defined by
# the cragutils-vs-FreeBSD comparison.  The FreeBSD VM oracle
# (tests/diff/oracle/run-on-freebsd.sh) has landed, so the default is
# cragutils,gnu,freebsd and the job gates on DRIFT: undeclared
# cragutils-vs-FreeBSD mismatches fail it, declared deltas (delta: hints
# referencing DIFFERENCES/ headings) and GNU divergences do not.  When
# the oracle is absent or its VM is not running the freebsd backend
# skips cleanly (never a DRIFT), so the job also works without a VM; run
# it with the oracle up to get real DRIFT gating.
set -eu

cd "$(dirname "$0")/../.."

BUILD_DIR=${BUILD_DIR:-build-ci-diff}
DIFF_BACKENDS=${DIFF_BACKENDS:-cragutils,gnu,freebsd}
DIFF_ARGS=${DIFF_ARGS:-}

if [ -n "${BINDIR:-}" ]; then
    printf '=== differential corpus (bindir %s)\n' "$BINDIR"
    # shellcheck disable=SC2086
    sh tests/diff/run-diff.sh --bindir "$BINDIR" --backends "$DIFF_BACKENDS" $DIFF_ARGS
else
    if [ ! -f "$BUILD_DIR/build.ninja" ]; then
        printf '=== configure (%s)\n' "${CC:-cc}"
        meson setup "$BUILD_DIR" -Dbuildtype=debugoptimized
    fi
    printf '=== build\n'
    ninja -C "$BUILD_DIR"

    printf '=== differential corpus\n'
    # shellcheck disable=SC2086
    sh tests/diff/run-diff.sh --build "$BUILD_DIR" --backends "$DIFF_BACKENDS" $DIFF_ARGS
fi

# The runner writes build/state/test-results/diff.{xml,txt} and exits
# non-zero only on DRIFT (or setup errors).
