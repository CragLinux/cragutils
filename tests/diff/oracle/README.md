# FreeBSD VM oracle — interface contract

The differential runner (`tests/diff/run-diff.sh`) talks to a real
FreeBSD userland through `run-on-freebsd.sh` in this directory.  The
oracle itself (bootable image + ssh transport) is built separately; this
file is the contract between it and the harness.  The runner is the only
consumer and is deliberately tolerant: if the oracle is absent it skips
the `freebsd` backend, if it exits 77 it skips, and if the framed record
cannot be parsed the case is skipped with a warning — never a DRIFT.

## Invocation

    run-on-freebsd.sh [--stdin FILE] [--tar FILE] [--env VAR=VAL]... -- TOOL [ARG...]

* `--stdin FILE` — the tool's stdin is exactly this file (default
  `/dev/null`).
* `--tar FILE` — unpack this tar archive into a fresh run directory on
  the VM and run there (the harness sends the case's working tree,
  already mtime-pinned, as `tar -cf ... -C <workdir> .`; the tool's cwd
  is that run directory).
* `--env VAR=VAL` — repeatable; set these variables in addition to the
  base environment.  The oracle runs with a minimal deterministic
  environment (`LC_ALL=C TZ=UTC`).
* `-- TOOL [ARG...]` — the tool name and arguments exactly as in the
  case table.

Exit status of the runner itself: 0 when a framed record was produced
(even if the tool failed), 77 when the oracle is unavailable (VM not
booted, no KVM, ssh failure).  Diagnostics go to the runner's stderr.

## Framed record

One record on stdout.  Header lines are ASCII, terminated by LF; the
payload lengths are exact byte counts and the payloads are raw:

    CRAG-ORACLE 1
    exit <N>
    stdout-bytes <N>
    <exactly N bytes of the tool's stdout>
    stderr-bytes <N>
    <exactly N bytes of the tool's stderr>

`exit` is the tool's exit status as a decimal number (signal death may
be reported as 128+signal, matching POSIX sh convention).  A record is
still produced when the tool fails; "could not run" is exit 77 from the
runner instead.  The parser also accepts `exit:`, `status`, `stdout-len:`
and `stderr-len:` spellings of the three headers and a `crag-oracle-v1`
banner, to keep the adapter forgiving about minor format choices.

## Notes

* The harness normalizes run paths only for the local backends
  (`norm:workdir` replaces the local working dir); VM-side paths are
  whatever the oracle's run directory is, so cases that print absolute
  paths should not use them, or the oracle must keep its run directory
  path stable.
* Nothing in the contract requires root on the VM; cases are written to
  be safe as any user.
