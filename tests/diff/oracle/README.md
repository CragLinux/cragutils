# tests/diff/oracle — FreeBSD QEMU oracle for differential testing

The oracle is the reference side of PLAN.md's P9 ("Differential
testing: FreeBSD is the reference"): a **real FreeBSD RELEASE userland**
booted in QEMU, driven non-interactively over ssh, so the diff harness
can compare cragutils (and host GNU tools) against honest FreeBSD
behavior rather than a re-implementation.

This file is the single contract between the oracle and its consumers
(`tests/diff/run-diff.sh`, `smoke.sh`, humans): provisioning and VM
operations, the `run-on-freebsd.sh` invocation modes, and the canonical
`crag-diff-run` frame.  The harness side is deliberately tolerant: if
the oracle is absent it skips the `freebsd` backend, exit 77 skips, and
an unparsable frame skips the case with a warning — never a DRIFT.

## Quick start

```sh
./provision.sh          # download + checksum-verify image, build seed + overlay (~1x, minutes)
./vm.sh start           # boot the VM (daemon) and wait for ssh
./run-on-freebsd.sh 'uname -a'
./smoke.sh | tee evidence/smoke-run1.txt
./vm.sh reset           # discard ALL guest state, fresh first boot from pristine base
./vm.sh stop            # graceful ACPI shutdown
./vm.sh status          # machine-readable state
```

All state lives outside the git tree in `$ORACLE_HOME`
(default `~/.cache/freebsd-oracle`).  Every knob is an environment
variable; see `common.sh`.

## Provisioned artifact (exact release + checksum)

| | |
|---|---|
| Release | **FreeBSD 15.1-RELEASE** (amd64) — matches `upstream.conf`'s `VER=15.1-RELEASE` |
| Image | `FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz` |
| Source | `https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/amd64/Latest/` |
| SHA256 | `e4ca4db889f8559c9b9dfcacc70405c038476f4b6d41649b152d3809a2ed9e1f` |
| Verified | 2026-11-07 against the published `CHECKSUM.SHA256` from the same directory (TLS), and pinned in `provision.sh` (`EXPECTED_SHA256`) |

`provision.sh` re-fetches `CHECKSUM.SHA256` on every run and aborts if
the published hash ever disagrees with the pin (upstream replaced the
image ⇒ deliberate re-pin required).  The downloaded `.qcow2.xz` is
kept in `$ORACLE_HOME/cache/`; the decompressed base image
(`$ORACLE_HOME/base/…qcow2`, 6.03 GiB virtual) is made **read-only** and
is never booted directly.

SSH login is key-only via an ed25519 keypair generated at provisioning
(`$ORACLE_HOME/id_oracle`).  The key is delivered to the guest's
default `freebsd` user through a NoCloud seed ISO (`seed.iso`, volume
label `cidata`): `user-data` is a `#cloud-config` with top-level
`ssh_authorized_keys`, which the image's `nuageinit` (FreeBSD's native
cloud-init, `libexec/nuageinit`) installs into the default user's
`~/.ssh/authorized_keys` at boot.

## VM shape (`vm.sh`)

* QEMU `qemu-system-x86_64`, **TCG** (`accel=tcg`; this host has no
  `/dev/kvm`; override with `ORACLE_ACCEL=kvm` where available),
  2048 MiB RAM, 2 vCPUs.
* Disk: qcow2 overlay (`$ORACLE_HOME/run/overlay.qcow2`) backed by the
  pristine base — the only writable layer.  Seed ISO on the IDE cdrom.
* Network: qemu user-mode (slirp), virtio-net; **fixed ssh port
  `2224`** on `127.0.0.1` only (`hostfwd`).  The guest DHCPs
  (image default `ifconfig_DEFAULT="SYNCDHCP"`).
* Serial console → `$ORACLE_HOME/run/console.log` (per boot).
* HMP monitor on a unix socket is used for the ACPI power-button
  shutdown.  qemu runs as a daemon (`-daemonize`, pidfile).

Lifecycle semantics:

* `start` — idempotent; boots if needed and waits for ssh readiness
  (timeout `ORACLE_BOOT_TIMEOUT`, default 600 s).  The VM is
  **long-lived**: start once, run many commands via
  `run-on-freebsd.sh`, stop when done.  Do not boot per test case.
* `stop` — sends ACPI powerdown via the monitor and waits for qemu to
  exit (grace: `ORACLE_STOP_TIMEOUT`, default 120 s), then SIGTERM,
  then SIGKILL.  Guest state (overlay) is preserved.
* `reset` — stop (if running), delete the overlay, create a fresh one
  from the pristine base, boot.  **Reset semantics: all guest state is
  discarded; the next boot is exactly a fresh first boot of the
  official image.**  The base image is untouched (cheap: no
  re-download, no re-imaging; the overlay is a few MiB).
* `status` — `state:`/`pid:`/`ssh:`/`guest_uname:`/`last_boot_seconds:`
  etc. as key: value lines.

Host ssh keys change on a fresh overlay (sshd generates new host keys at
first boot), so `start`/`reset` prune the entry for
`[127.0.0.1]:2224` from `$ORACLE_HOME/known_hosts`; ssh re-learns it
(`StrictHostKeyChecking=accept-new`).  Everything ssh touches is
per-oracle (dedicated key + known_hosts), nothing global.

## Command execution (`run-on-freebsd.sh`) — two invocation modes

### Mode 1: one shell command (human/legacy mode)

```
./run-on-freebsd.sh '<shell command>'    # exactly one argument
echo 'a b c' | ./run-on-freebsd.sh 'wc -w'   # host stdin is forwarded
```

Execution contract (also echoed in every frame):

* runs as user `freebsd`, under `/bin/sh -c`,
* **working directory `/home/freebsd`** (`ORACLE_GUEST_CWD`),
* **locale `LC_ALL=C LANG=C`** — sorting, collation and message output
  are deterministic C-locale behavior; the harness relies on this,
* host stdin is forwarded verbatim to the guest command,
* guest stdout and stderr are captured to separate temp files first, so
  they can never interleave.

Exit status of `run-on-freebsd.sh` itself in this mode: `0` = valid
frame emitted, `2` = usage, `3` = ssh/transport failure or
truncated/invalid frame (no frame emitted; diagnostics on stderr).  The
guest's status lives only in the frame.

Caveats: a command string may have one trailing newline appended before
execution (shell-quoting artifact; trailing newlines are no-ops in
`sh -c`, so stdout/stderr/exit are unaffected).  Commands must not
leave background children holding stdout open (`sleep 100 &` would
delay the frame until the child exits).

### Mode 2: tool invocation with fixtures (harness mode)

    run-on-freebsd.sh [--stdin FILE] [--tar FILE] [--tar-out FILE]
                      [--timeout N] [--env VAR=VAL]... -- TOOL [ARG...]

Selected when the arguments are flag-shaped (`--stdin`, `--tar`,
`--tar-out`, `--timeout`, `--env`, `--`); a single non-flag argument is
mode 1.

* `--stdin FILE` — the tool's stdin is exactly this file (default
  `/dev/null`).
* `--tar FILE` — unpack this tar archive into a **fresh run directory**
  on the guest (`$ORACLE_GUEST_RUNDIR`, default `/tmp/crag-diff-w`,
  deleted and recreated per invocation) and run there; the tool's cwd
  is that run directory.  The harness sends the case's working tree,
  already mtime-pinned, as `tar -cf ... -C <workdir> .`.
* `--tar-out FILE` — after the tool runs, fetch the post-run run
  directory tree back as a tar (`tar -cf - -C <rundir> .`) into this
  host file.  The harness uses it for `post:` side-effect observations,
  so the observed tree is exactly what the tool left on the guest.  A
  fetch failure fails the whole invocation.
* `--timeout N` — bound the tool with the guest's `timeout(1)` (default
  10 seconds); on timeout the frame's `exit_status` is `124` and the
  stdout payload is truncated and run-to-run varying — consumers must
  not compare timed-out runs (the harness skips them).
* `--env VAR=VAL` — repeatable (values must not contain spaces); set
  these variables in addition to the base environment.
* `-- TOOL [ARG...]` — the tool name and arguments exactly as in the
  case table, transported argv-faithful (each argument is
  single-quoted for the guest shell and the tool is `exec`ed, so no
  re-parsing of arguments happens).

Execution contract in this mode:

* runs as user `freebsd`, under `/bin/sh -c`, `exec`ing the tool,
* **working directory `$ORACLE_GUEST_RUNDIR`** (stable path, fresh
  contents per call),
* **environment**: `LC_ALL=C LANG=C TZ=UTC HOME=<rundir>
  PATH=/sbin:/bin:/usr/sbin:/usr/bin`, plus the `--env` deltas,
* `umask 022`,
* `--stdin FILE` is forwarded verbatim to the tool; stdout/stderr are
  captured separately exactly as in mode 1.

Exit status of the runner itself in this mode: `0` = valid frame
produced (even if the tool failed — the tool's status is in the frame),
`2` = usage error, `77` = the oracle is unavailable (VM not running,
ssh/transport failure, or invalid/truncated frame; diagnostics on
stderr).  Consumers treat `77` as "skip this backend": in particular
`tests/diff/run-diff.sh` skips the case and can never turn it into a
DRIFT verdict.

## The canonical frame (`crag-diff-run`, version 1)

Both modes emit exactly one frame on stdout:

```
crag-diff-run: 1
cwd: /home/freebsd              <- mode 1: ORACLE_GUEST_CWD
lc_all: C                          mode 2: the guest run directory
exit_status: <decimal>          <- the GUEST's exit status
stdout_bytes: <decimal>
stderr_bytes: <decimal>
<empty line>
<exactly stdout_bytes of guest stdout, byte-faithful>
<exactly stderr_bytes of guest stderr, byte-faithful>
```

Parse rule: read header lines up to the first empty line, then read
exactly `stdout_bytes + stderr_bytes` payload bytes; anything else is a
transport error.  The frame is generated **guest-side**, so a complete
frame certifies the command ran to completion (a command exiting 255
can never be confused with an ssh failure).  Binary payloads are safe
(verified in smoke.sh: `printf 'a\000b'` arrives as 3 bytes).

`tests/diff/run-diff.sh`'s `oracle_unframe` parses exactly this frame
and additionally tolerates minor legacy spellings of the magic
(`CRAG-ORACLE 1`, `crag-oracle-v1`) and of the three counted fields
(`exit N`/`exit: N`/`status: N`, `stdout-bytes:`/`stdout-len:`/`stdout:`,
`stderr-bytes:`/`stderr-len:`/`stderr:`), but new producers must emit
the `crag-diff-run: 1` frame above.  **One format, one parser, one
producer — this frame is the contract.**

## Smoke proof (2026-11-08, evidence/)

Full transcripts: `evidence/smoke-run1.txt` (fresh boot) and
`evidence/smoke-run2.txt` (after `vm.sh reset`).  Both end
`## SMOKE RESULT: PASS`.  Required battery, from the guest
(`uname -srm` → `FreeBSD 15.1-RELEASE-p6 amd64`):

```
date    -> Sun Nov  8 02:02:54 UTC 2026
sed     -> printf 'hello world\n' | sed 's/world/crag/'  -> "hello crag"
awk     -> printf '3\n1\n2\n' | awk '{s+=$1} END{print s}' -> "6"
sort    -> printf 'beta\nalpha\ngamma\n' | sort -> alpha/beta/gamma
stat -f -> stat -f '%N size=%z mode=%Sp' /etc/passwd
          -> "/etc/passwd size=1703 mode=-rw-r--r--"   (BSD format language)
jot 5   -> 1 2 3 4 5
printf  -> /usr/bin/printf '%d-%s-%05.2f\n' 7 mid 3.14159 -> "7-mid-03.14"
cut     -> printf 'a:b:c\n' | cut -d: -f2 -> "b"
find    -> find /etc -maxdepth 1 -type f -name 'ttys' -print -> "/etc/ttys"
uname   -> FreeBSD fbsd-oracle 15.1-RELEASE-p6 releng/15.1-n283643-95719d8a895b GENERIC amd64
```

**GNU divergence proof** — identical argv on the Ubuntu host differs
(oracle output is the reference; these belong in `TRADEOFFS` as
GNU_DIVERGENCE documentation):

| argv | FreeBSD oracle | Ubuntu GNU |
|---|---|---|
| `stat -f '%N size=%z mode=%Sp' /etc/passwd` | `/etc/passwd size=1703 mode=-rw-r--r--` | `stat: cannot read file system information for '%N size=%z mode=%Sp'…` (GNU `-f` = file-system status) |
| `date -u -r 1000000000` | `Sun Sep  9 01:46:40 UTC 2001` | `date: 1000000000: No such file or directory` (GNU `-r` = reference file) |
| `jot 5` | `1 2 3 4 5` | `sh: 1: jot: not found` (no GNU equivalent) |

Frame protocol was exercised with: mixed stdout/stderr + `exit 3`
(kept separate in the frame), stdin passthrough (`wc -w` → `3`), and
NUL-safe binary payloads (3 bytes, hexdumped).

## Measured timings (this host: 24 cores, no /dev/kvm, pure TCG)

* **Cold boot (fresh image, first boot): 249.84 s to ssh.**  This
  includes the image's stock first-boot work: `firstboot-pkg-upgrade`
  fetches the FreeBSD-base catalogue and installs the 15.1→15.1p4/5/6
  security updates (111 packages) before sshd becomes responsive.
* **Reset: 14 s graceful ACPI stop + 309.35 s fresh first boot to
  ssh** (run 2; run 3 after the timing fix: 14 s stop + 286.51 s boot,
  `reset complete in 300.97s`).  The first-boot security work repeats
  because the overlay is recreated — the pristine image is, by design,
  never modified.
* **Warm boot (`stop` + `start`, same overlay): 43.19 s to ssh** — the
  practical cycle for a long-lived oracle; no first-boot work.
* **Per-command overhead: mean 879 ms / 851 ms per
  `run-on-freebsd.sh` call** across the two runs (20 × `:` = 17.59 s
  and 17.03 s totals), vs **594 ms / 562 ms for a bare `ssh true`**
  round trip — i.e. ~285 ms of framing/validation on top of the
  TCG-guest ssh round trip.  On a KVM host both numbers drop sharply.
  Mode 2 costs up to two extra round trips per call (tar upload, tar
  fetch).
* `vm.sh stop`: graceful ACPI powerdown observed at **14 s**; the
  escalation path (SIGTERM/SIGKILL) exists but has not been needed.

Reset semantics, restated: `reset` = stop + delete overlay + new
overlay from the read-only base + boot.  Every observable guest state
(hostname, users, host keys, package state, files in /tmp) returns to
the official first-boot state.  `provision.sh` needs re-running only if
`$ORACLE_HOME` is deleted or the pinned image changes.

## Notes for harness cases

* Mode 2 keeps the guest run directory path stable
  (`$ORACLE_GUEST_RUNDIR`), so `norm:workdir`-style path normalization
  can target it; the tree fetched with `--tar-out` is what the harness
  observes for `post:` hints.
* Nothing in the contract requires root on the VM; cases are written to
  be safe as any user.

## Known caveats

* First boot (and every `reset`) performs upstream's security-update
  fetch (`firstboot-pkg-upgrade`, from `/usr/local/etc/rc.d/`,
  enabled in the stock image's rc.conf).  It needs working network
  (slirp provides it) and dominates cold-boot time under TCG.  The
  reference userland is therefore 15.1-RELEASE + the current
  FreeBSD-base patches after first boot; `uname -r` reports
  `15.1-RELEASE-p6` as of provisioning date.  If a future harness run
  must match the pristine `15.1-RELEASE` src.txz byte-for-byte,
  disable that service in the seed's user-data (untested).
* TCG is slow.  For CI with KVM use `ORACLE_ACCEL=kvm`; the scripts
  are accelerator-agnostic.
* The seed's user-data sets only the ssh key + hostname.  Password
  auth exists in the stock image (`freebsd`/`freebsd`) but the runner
  always uses BatchMode key auth.
* `run-on-freebsd.sh` assumes the guest is FreeBSD (the frame wrapper
  is POSIX sh; byte counts use `wc -c`).  Do not point it at a Linux
  guest and expect BSD tool output — that would defeat the oracle.
