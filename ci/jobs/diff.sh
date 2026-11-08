#!/bin/sh
# Build cragutils and run the differential corpus (PLAN.md P9) against
# the GNU backend.
#
# Parameterised entirely by the environment:
#   BUILD_DIR      build tree (default: build-ci-diff)
#   BINDIR        use an existing flat tool directory instead of building
#   DIFF_BACKENDS backends for tests/diff/run-diff.sh
#                  (default: cragutils,gnu — see below)
#   DIFF_ARGS     extra arguments for tests/diff/run-diff.sh
#
# DRIFT gating: DRIFT is the only gate-failing verdict and is defined by
# the cragutils-vs-FreeBSD comparison.  Until the FreeBSD VM oracle
# (tests/diff/oracle/run-on-freebsd.sh) lands, this job runs with
# DIFF_BACKENDS=cragutils,gnu so no DRIFT can be produced and the job
# gates on the runner itself plus the junit report existing.  When the
# oracle lands, switch the default to cragutils,gnu,freebsd (or run with
# the oracle present — the runner picks it up) and the same script
# starts gating on DRIFT without further changes.
set -eu

cd "$(dirname "$0")/../.."

BUILD_DIR=${BUILD_DIR:-build-ci-diff}
DIFF_BACKENDS=${DIFF_BACKENDS:-cragutils,gnu}
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
