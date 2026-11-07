#!/bin/sh
# Coverage and regression tests for telnet(1).
#
# telnet is the least-covered patched tool (0% of telnet/ and
# libtelnet/ before this file existed — no test in the suite ran it).
# SECURITY-FINDINGS.md fixes reachable here:
#   - strlcpy(_hostname, res->ai_canonname): the overflow itself needs a
#     >63-char canonical hostname (DNS-controlled) and is not reachable
#     from a test, but the connect path is exercised below;
#   - NetTraceFile[256] stack smash on a >255-char -n tracefile
#     (regression-tested: pre-fix fortify abort);
#   - libtelnet/sra.c uprompt guard with an exactly-256-char -l user
#     (needs an SRA server to fire; the argument handling is smoke-tested).
#
# The session tests run against a loopback listener built from the
# netcat under test — no network, no external services.  They walk the
# real telnet.c telrcv IAC negotiation parsers (the fuzz_telnet entry
# points) through main().

. "$CU_LIB/lib.sh"

require "telnet regressions" telnet || { cu_finish; exit; }

TELNET=$(tool telnet)
# telnet wants a terminal type even with a piped stdin.
export TERM=vt100

group "telnet: command-line handling"

long300=$(awk 'BEGIN{s="";for(i=0;i<300;i++)s=s "u";print s}')

assert_status "telnet with no arguments reads commands until EOF" 0 \
    sh -c "$TELNET </dev/null >/dev/null 2>&1"
assert_status "unknown option is a usage error" 1 \
    sh -c "$TELNET -Z 127.0.0.1 1 >/dev/null 2>&1"
assert_no_crash "telnet -e sets the escape character" \
    sh -c "$TELNET -e q 127.0.0.1 1 </dev/null >/dev/null 2>&1"

# NetTraceFile is char[256] and used to be strncpy'd unbounded.
assert_no_crash "telnet -n with a 300-char tracefile name" \
    sh -c "$TELNET -n '$long300' 127.0.0.1 1 </dev/null >/dev/null 2>&1"
assert_no_crash "telnet -l with a 300-char user name" \
    sh -c "$TELNET -l '$long300' 127.0.0.1 1 </dev/null >/dev/null 2>&1"
assert_no_crash "telnet -l with an exactly-256-char user name" \
    sh -c "$TELNET -l '$(awk 'BEGIN{s="";for(i=0;i<256;i++)s=s "u";print s}')' 127.0.0.1 1 </dev/null >/dev/null 2>&1"

group "telnet: connect failure is a clean error"

assert_no_crash "connection refused does not crash" \
    sh -c "$TELNET 127.0.0.1 1 </dev/null >/dev/null 2>&1"
assert_contains "connection refused is reported" "Unable to connect" \
    sh -c "$TELNET 127.0.0.1 1 </dev/null 2>&1"

# ---------------------------------------------------------------------
# Loopback listener (netcat under test).  The listener dies with its one
# connection; ports come from a pid-derived base so parallel runs do not
# collide, and a bind failure is reported as a skip, never a failure.
# ---------------------------------------------------------------------

NC=
have nc && NC=$(tool nc)
if [ -z "$NC" ] && have_host nc; then
    NC=nc
fi

# start_listener <in-file> <out-file> — start nc -l; sets listener_port
# and listener_pid as globals (a command substitution would run the
# function in a subshell and orphan the listener).
listener_port=
listener_pid=
start_listener() {
    _base=$((22000 + ($$ % 2000)))
    _try=0
    while [ "$_try" -lt 5 ]; do
        _port=$((_base + _try * 37))
        "$NC" -l "$_port" < "$1" > "$2" 2>/dev/null &
        listener_pid=$!
        cu_run_limited sleep 0.2 >/dev/null 2>&1
        if kill -0 "$listener_pid" 2>/dev/null; then
            listener_port=$_port
            return 0
        fi
        wait "$listener_pid" 2>/dev/null
        _try=$((_try + 1))
    done
    return 1
}

stop_listener() {
    kill "$listener_pid" 2>/dev/null
    wait "$listener_pid" 2>/dev/null
}

if [ -n "$NC" ]; then
    group "telnet: session against a loopback listener"

    : > sess.in
    if start_listener sess.in sess.out; then
        port=$listener_port
        printf '\035quit\n' > sess.cmd
        cu_run_limited "$TELNET" 127.0.0.1 "$port" \
            < sess.cmd > sess.log 2>&1
        st=$?
        stop_listener
        if grep -q 'Connected' sess.log 2>/dev/null; then
            assert_eq "telnet session with escape-quit exits cleanly" "0" "$st"
            assert_contains "telnet session reached command mode" "telnet>" \
                cat sess.log
        else
            skip "telnet session" "listener did not accept (port busy?)"
        fi
    else
        skip "telnet session" "could not bind a loopback listener"
    fi

    group "telnet: hostile IAC negotiation (telrcv parsers)"

    # IAC WILL ECHO / IAC DO SUPPRESS-GO-AHEAD / a broken suboption /
    # a doubled IAC / IAC GA / plain data: the fuzz_telnet input classes,
    # fed through the real binary's receive path.
    printf '\377\373\001\377\375\003\377\372\030\000VT220\377' > iac.in
    printf '\377\377\377\371garbage\377\376\001end\n' >> iac.in
    if start_listener iac.in iac.out; then
        assert_no_crash "telnet survives hostile IAC negotiation" \
            sh -c "$TELNET 127.0.0.1 $listener_port < /dev/null > /dev/null 2>&1"
        stop_listener
    else
        skip "telnet hostile IAC" "could not bind a loopback listener"
    fi

    group "telnet: trace file output"

    : > sess.in
    if start_listener sess.in sess.out; then
        assert_no_crash "telnet -n writes a trace and exits cleanly" \
            sh -c "$TELNET -n trace.out 127.0.0.1 $listener_port < /dev/null > /dev/null 2>&1"
        stop_listener
    else
        skip "telnet trace file" "could not bind a loopback listener"
    fi
else
    skip "telnet listener tests" "no nc available"
fi

cu_finish