#!/bin/sh
#
# run-on-freebsd.sh - run one shell command or tool invocation inside the
#                     FreeBSD oracle VM and emit its result faithfully and
#                     machine-readably
#                     (PLAN.md P9: the FreeBSD guest is the reference).
#
# Two invocation modes (full contract: tests/diff/oracle/README.md):
#
#   Mode 1 - one shell command (exactly one argument):
#     run-on-freebsd.sh '<shell command>'
#     echo stdin | run-on-freebsd.sh 'cat > /tmp/x'
#
#   Mode 2 - tool invocation with fixtures (harness mode):
#     run-on-freebsd.sh [--stdin FILE] [--tar FILE] [--tar-out FILE]
#                       [--env VAR=VAL]... -- TOOL [ARG...]
#
# Mode 1 runs the command:
#   - as user '${ORACLE_SSH_USER}' (freebsd) over ssh,
#   - with working directory /home/freebsd (ORACLE_GUEST_CWD),
#   - with LC_ALL=C LANG=C (so sorting, collation and message output are
#     deterministic C-locale behavior - the harness depends on this),
#   - under /bin/sh -c,
#   - with this script's stdin forwarded verbatim to the command.
#
# Mode 2 runs TOOL [ARG...] (argv-faithful, exec'd, no re-parsing):
#   - with working directory $ORACLE_GUEST_RUNDIR (default
#     /tmp/crag-diff-w): a fresh directory (deleted + recreated on every
#     call) holding the tree from --tar, if given,
#   - with environment LC_ALL=C LANG=C TZ=UTC HOME=<rundir>
#     PATH=/sbin:/bin:/usr/sbin:/usr/bin plus the --env deltas,
#   - umask 022,
#   - with --stdin FILE (default /dev/null) forwarded as the tool's stdin,
#   - optionally fetching the post-run run-dir tree back into --tar-out
#     FILE (tar of the run dir) so callers can observe side effects.
#
# OUTPUT FORMAT ("crag-diff-run" frame, version 1) on stdout - identical
# in both modes:
#
#   crag-diff-run: 1
#   cwd: <guest cwd - ORACLE_GUEST_CWD in mode 1, the run dir in mode 2>
#   lc_all: C
#   exit_status: <guest exit status, decimal>
#   stdout_bytes: <decimal byte count>
#   stderr_bytes: <decimal byte count>
#   <empty line>
#   <exactly stdout_bytes bytes of guest stdout, byte-faithful>
#   <exactly stderr_bytes bytes of guest stderr, byte-faithful>
#
# The frame is produced by the guest-side wrapper, so its presence
# certifies the guest command ran to completion.  Parsing rule: read
# header lines up to the first empty line, then read exactly
# stdout_bytes + stderr_bytes payload bytes; anything else is an error
# (truncated transport).  Guest stdout and stderr are captured to
# separate temporary files first, so they never interleave.
#
# A trailing newline may be appended to the command string before it is
# executed (an artifact of shell quoting); a trailing newline is a no-op
# command separator in sh, so the guest's stdout/stderr/exit status are
# identical to executing the string as given.
#
# EXIT STATUS of this script (not the guest's - the guest's is in the
# frame):
#   0  a complete, valid frame was emitted
#   2  usage error
#   3  (mode 1) ssh/transport failure or invalid/truncated frame
#   77 (mode 2) oracle unavailable: VM not running, ssh/transport
#      failure, or invalid/truncated frame (also when the --tar-out
#      fetch fails).  Consumers treat 77 as "skip this backend".
#   No frame on stdout in the failure cases; details on stderr.
#
# Do not run commands that leave background children holding stdout
# open (e.g. `sleep 100 &`) - the ssh channel, and thus the frame, will
# not complete until they exit or close their fds.

set -eu

. "$(dirname "$0")/common.sh"

usage() {
    printf 'usage: %s '\''<shell command>'\''\n' "$0" >&2
    printf '       %s [--stdin FILE] [--tar FILE] [--tar-out FILE] [--env VAR=VAL]... -- TOOL [ARG...]\n' "$0" >&2
    exit 2
}

# --- argument parsing: mode 1 vs mode 2 -------------------------------
MODE=1
STDIN_FILE=/dev/null
TAR_IN=
TAR_OUT=
ENVS=''
RUN_TIMEOUT=10

case ${1:-} in
    --stdin|--tar|--tar-out|--timeout|--env|--) MODE=2 ;;
esac

if [ "$MODE" -eq 1 ]; then
    [ "$#" -eq 1 ] || usage
    CMD="$1"
    STDIN_FILE=
    FAIL_RC=3
else
    FAIL_RC=77
    while [ $# -gt 0 ]; do
        case $1 in
            --stdin)   [ $# -ge 2 ] || usage; STDIN_FILE=$2; shift 2 ;;
            --tar)     [ $# -ge 2 ] || usage; TAR_IN=$2; shift 2 ;;
            --tar-out) [ $# -ge 2 ] || usage; TAR_OUT=$2; shift 2 ;;
            --timeout) [ $# -ge 2 ] || usage; RUN_TIMEOUT=$2; shift 2 ;;
            --env)     [ $# -ge 2 ] || usage
                       ENVS="$ENVS$2
"; shift 2 ;;
            --)        shift; break ;;
            *)         usage ;;
        esac
    done
    [ $# -ge 1 ] || usage
    [ -r "$STDIN_FILE" ] || usage
    [ -z "$TAR_IN" ] || [ -f "$TAR_IN" ] || usage
    case $RUN_TIMEOUT in ''|*[!0-9]*|0) usage ;; esac
fi

fail() {
    printf 'run-on-freebsd: %s\n' "$*" >&2
    exit "$FAIL_RC"
}

oracle_running || {
    if [ "$MODE" -eq 1 ]; then
        fail "oracle VM is not running (start it with ./vm.sh start)"
    fi
    fail "oracle unavailable: VM not running (start it with ./vm.sh start)"
}

# single-quote an arbitrary string for POSIX sh (stdin -> stdout)
shquote() {
    printf "'"
    sed "s/'/'\\\\''/g"
    printf "'"
}

# --- guest-side wrapper ------------------------------------------------
# Runs the command with the documented locale/cwd, captures stdout and
# stderr separately, then prints the framed result.  $1 is the command
# string, optional $2 a setup snippet to run first (mode 2).  The body
# is deliberately free of single quotes so it can be transported inside
# one.
WRAPPER=$(cat <<'EOF'
if [ $# -ge 2 ] && [ -n "$2" ]; then sh -c "$2" || exit 125; fi
cd __CWD__ || exit 125
export LC_ALL=C LANG=C
o=$(mktemp /tmp/crag-run.o.XXXXXX) || exit 125
e=$(mktemp /tmp/crag-run.e.XXXXXX) || exit 125
trap "rm -f $o $e" EXIT HUP INT TERM
sh -c "$1" >"$o" 2>"$e"
r=$?
n=$(wc -c <"$o")
n=$((n))
m=$(wc -c <"$e")
m=$((m))
printf "crag-diff-run: 1\n"
printf "cwd: __CWD__\n"
printf "lc_all: C\n"
printf "exit_status: %d\n" "$r"
printf "stdout_bytes: %d\n" "$n"
printf "stderr_bytes: %d\n" "$m"
printf "\n"
cat "$o"
cat "$e"
EOF
)

GUEST_CWD=$ORACLE_GUEST_CWD
RUNDIR=${ORACLE_GUEST_RUNDIR:-/tmp/crag-diff-w}
SETUP=

if [ "$MODE" -eq 2 ]; then
    GUEST_CWD=$RUNDIR
    # Fresh run directory + optional fixture tree + deterministic umask.
    SETUP="rm -rf $(printf '%s' "$RUNDIR" | shquote); mkdir -p $(printf '%s' "$RUNDIR" | shquote) || exit 125"
    if [ -n "$TAR_IN" ]; then
        # shellcheck disable=SC2086
        ssh $ORACLE_SSH_OPTS "${ORACLE_SSH_USER}@127.0.0.1" \
            'umask 177; cat > /tmp/crag-tree.tar' < "$TAR_IN" \
            || fail "could not upload fixture tar to the guest"
        SETUP="$SETUP; tar -xf /tmp/crag-tree.tar -C $(printf '%s' "$RUNDIR" | shquote) || exit 125; rm -f /tmp/crag-tree.tar"
    fi
    SETUP="$SETUP; umask 022"
    # The tool command: deterministic env, then exec argv-faithfully,
    # bounded by timeout(1) (guest exit 124 on timeout; truncated output
    # is uncomparable, the harness skips those).
    CMD="export TZ=UTC HOME=$(printf '%s' "$RUNDIR" | shquote) PATH=/sbin:/bin:/usr/sbin:/usr/bin"
    if [ -n "$ENVS" ]; then
        old_ifs=$IFS
        IFS='
'
        for _e in $ENVS; do
            [ -n "$_e" ] || continue
            CMD="$CMD $(printf '%s' "$_e" | shquote)"
        done
        IFS=$old_ifs
    fi
    CMD="$CMD; exec timeout $(printf '%s' "$RUN_TIMEOUT" | shquote)"
    for _a in "$@"; do
        CMD="$CMD $(printf '%s' "$_a" | shquote)"
    done
fi

WRAPPER=$(printf '%s\n' "$WRAPPER" | sed "s|__CWD__|$GUEST_CWD|g")

WRAPPER_Q=$(printf '%s' "$WRAPPER" | shquote)
CMD_Q=$(printf '%s' "$CMD" | shquote)
SETUP_Q=$(printf '%s' "$SETUP" | shquote)
REMOTE="sh -c ${WRAPPER_Q} crag-diff-run ${CMD_Q} ${SETUP_Q}"

FRAME=$(mktemp "${TMPDIR:-/tmp}/crag-frame.XXXXXX")
DIAG=$(mktemp "${TMPDIR:-/tmp}/crag-diag.XXXXXX")
trap 'rm -f "$FRAME" "$DIAG"' EXIT HUP INT TERM

run_ssh() {
    # run_ssh <remote command> : stdout -> $FRAME, stderr -> $DIAG;
    # mode 1 inherits this script's stdin, mode 2 uses --stdin FILE.
    if [ -n "$STDIN_FILE" ]; then
        # shellcheck disable=SC2086
        ssh $ORACLE_SSH_OPTS "${ORACLE_SSH_USER}@127.0.0.1" "$1" \
            < "$STDIN_FILE" >"$FRAME" 2>"$DIAG"
    else
        # shellcheck disable=SC2086
        ssh $ORACLE_SSH_OPTS "${ORACLE_SSH_USER}@127.0.0.1" "$1" \
            >"$FRAME" 2>"$DIAG"
    fi
}

if run_ssh "$REMOTE"; then
    :
else
    SSH_RC=$?
    sed 's/^/run-on-freebsd: ssh: /' "$DIAG" >&2
    fail "ssh failed (rc=$SSH_RC) - no valid frame produced"
fi

# --- validate the frame ------------------------------------------------
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

FIRST=$(head -n 1 "$FRAME")
[ "$FIRST" = "crag-diff-run: 1" ] || fail "invalid frame: bad magic '$FIRST'"

HDR_BYTES=$(sed -n '1,/^$/p' "$FRAME" | wc -c)
HDR_BYTES=$((HDR_BYTES))
EXIT_STATUS=$(sed -n 's/^exit_status: \([0-9][0-9]*\)$/\1/p' "$FRAME" | head -n 1)
SO=$(sed -n 's/^stdout_bytes: \([0-9][0-9]*\)$/\1/p' "$FRAME" | head -n 1)
SE=$(sed -n 's/^stderr_bytes: \([0-9][0-9]*\)$/\1/p' "$FRAME" | head -n 1)
is_uint "${EXIT_STATUS:-}" && is_uint "${SO:-}" && is_uint "${SE:-}" \
    || fail "invalid frame: missing/invalid header fields"

PAY_BYTES=$(( $(tail -c +$((HDR_BYTES + 1)) "$FRAME" | wc -c) ))
WANT=$(( SO + SE ))
[ "$PAY_BYTES" -eq "$WANT" ] \
    || fail "truncated frame: payload $PAY_BYTES bytes, header promises $WANT"

# --- optional post-run tree fetch (mode 2) -----------------------------
if [ -n "$TAR_OUT" ]; then
    # shellcheck disable=SC2086
    ssh $ORACLE_SSH_OPTS "${ORACLE_SSH_USER}@127.0.0.1" \
        "tar -cf - -C $(printf '%s' "$RUNDIR" | shquote) ." \
        < /dev/null > "$TAR_OUT" 2>>"$DIAG" \
        || fail "could not fetch post-run tree from the guest"
fi

# --- emit the validated frame verbatim ---------------------------------
cat "$FRAME"
exit 0
