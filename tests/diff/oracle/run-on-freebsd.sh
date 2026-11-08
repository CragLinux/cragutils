#!/bin/sh
#
# run-on-freebsd.sh - run one shell command inside the FreeBSD oracle VM
#                     and emit its result faithfully and machine-readably
#                     (PLAN.md P9: the FreeBSD guest is the reference).
#
# Usage: run-on-freebsd.sh '<shell command>'   (exactly one argument)
#        echo stdin | run-on-freebsd.sh 'cat > /tmp/x'
#
# The guest command runs:
#   - as user '${ORACLE_SSH_USER}' (freebsd) over ssh,
#   - with working directory /home/freebsd (ORACLE_GUEST_CWD),
#   - with LC_ALL=C LANG=C (so sorting, collation and message output are
#     deterministic C-locale behavior - the harness depends on this),
#   - under /bin/sh -c,
#   - with this script's stdin forwarded verbatim to the command.
#
# OUTPUT FORMAT ("crag-diff-run" frame, version 1) on stdout:
#
#   crag-diff-run: 1
#   cwd: /home/freebsd
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
#   3  ssh/transport failure or invalid/truncated frame (no frame on
#      stdout; details on stderr)
#
# Do not run commands that leave background children holding stdout
# open (e.g. `sleep 100 &`) - the ssh channel, and thus the frame, will
# not complete until they exit or close their fds.

set -eu

. "$(dirname "$0")/common.sh"

if [ "$#" -ne 1 ]; then
    printf 'usage: %s '\''<shell command>'\''\n' "$0" >&2
    exit 2
fi
CMD="$1"

fail() {
    printf 'run-on-freebsd: %s\n' "$*" >&2
    exit 3
}

oracle_running || fail "oracle VM is not running (start it with ./vm.sh start)"

# --- guest-side wrapper ------------------------------------------------
# Runs the command with the documented locale/cwd, captures stdout and
# stderr separately, then prints the framed result.  Deliberately free
# of single quotes so it can be transported inside one.
WRAPPER=$(cat <<'EOF'
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
WRAPPER=$(printf '%s\n' "$WRAPPER" | sed "s|__CWD__|$ORACLE_GUEST_CWD|g")

# single-quote an arbitrary string for POSIX sh (stdin -> stdout)
shquote() {
    printf "'"
    sed "s/'/'\\\\''/g"
    printf "'"
}

WRAPPER_Q=$(printf '%s' "$WRAPPER" | shquote)
CMD_Q=$(printf '%s' "$CMD" | shquote)
REMOTE="sh -c ${WRAPPER_Q} crag-diff-run ${CMD_Q}"

FRAME=$(mktemp "${TMPDIR:-/tmp}/crag-frame.XXXXXX")
DIAG=$(mktemp "${TMPDIR:-/tmp}/crag-diag.XXXXXX")
trap 'rm -f "$FRAME" "$DIAG"' EXIT HUP INT TERM

if ssh $ORACLE_SSH_OPTS "${ORACLE_SSH_USER}@127.0.0.1" "$REMOTE" \
        >"$FRAME" 2>"$DIAG"; then
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

# --- emit the validated frame verbatim ---------------------------------
cat "$FRAME"
exit 0
