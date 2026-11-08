#!/bin/sh
#
# vm.sh - lifecycle for the FreeBSD differential-testing oracle VM
#         (PLAN.md P9).  Boots the pristine base image through a qcow2
#         overlay under QEMU (TCG on this host - no /dev/kvm), with
#         user-mode (slirp) networking and a fixed hostfwd ssh port.
#
# The VM is a long-lived daemon: start it once, run commands with
# run-on-freebsd.sh, stop it when done.  Prefer that over per-case boots.
#
# Usage: vm.sh start|stop|reset|status
#
#   start   boot the VM (if not already running) and wait for ssh
#   stop    graceful ACPI power-button shutdown, SIGTERM/SIGKILL fallback
#   reset   stop, throw away the overlay (ALL guest state), boot fresh
#   status  report VM/ssh state machine-readably
#
# Reset semantics: the base qcow2 is never booted directly and is kept
# read-only; every boot writes into $ORACLE_OVERLAY_QCOW2.  `reset`
# deletes that overlay and creates a new empty one from the same base,
# so a reset VM is exactly a fresh first boot of the pristine image
# (including first-boot steps such as nuageinit and firstboot services).

set -eu

. "$(dirname "$0")/common.sh"

QEMU="${QEMU:-qemu-system-x86_64}"

log() { printf 'vm: %s\n' "$*"; }
die() { printf 'vm: ERROR: %s\n' "$*" >&2; exit 1; }

hmp() {
    # send one HMP monitor command to the running qemu
    python3 - "$ORACLE_RUN_DIR/monitor.sock" "$1" <<'PYEOF'
import socket, sys, time
path, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.settimeout(5)
s.connect(path)
try:
    s.recv(65536)          # banner/prompt
except Exception:
    pass
s.sendall((cmd + "\n").encode())
time.sleep(0.3)
try:
    s.recv(65536)
except Exception:
    pass
s.close()
PYEOF
}

require_provisioned() {
    [ -f "$ORACLE_BASE_QCOW2" ] || die "base image missing; run ./provision.sh first"
    [ -f "$ORACLE_SEED_ISO" ]  || die "seed ISO missing; run ./provision.sh first"
    [ -f "$ORACLE_SSH_KEY" ]   || die "ssh key missing; run ./provision.sh first"
}

wait_for_ssh() {
    # wait_for_ssh <start-fractional-epoch>
    local deadline waited
    deadline=$(( $(date +%s) + ORACLE_BOOT_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if oracle_ssh true 2>/dev/null; then
            waited=$(oracle_elapsed "$1")
            log "ssh ready after ${waited}s"
            printf 'BOOT_STARTED=%s\nBOOT_SECONDS=%s\nBOOT_DONE=%s\n' \
                "$1" "$waited" "$(oracle_now)" >> "$ORACLE_RUN_DIR/state.env"
            return 0
        fi
        # dead qemu is fatal, not a timeout
        oracle_running || die "qemu exited while waiting for ssh (see $ORACLE_RUN_DIR/console.log)"
        sleep 3
    done
    die "ssh not ready within ${ORACLE_BOOT_TIMEOUT}s (see $ORACLE_RUN_DIR/console.log)"
}

cmd_start() {
    require_provisioned
    if oracle_running; then
        log "already running (pid $(cat "$ORACLE_RUN_DIR/qemu.pid"))"
        oracle_ssh true 2>/dev/null && { log "ssh is up"; return 0; }
        log "qemu alive but ssh down; waiting"
        wait_for_ssh "$(sed -n 's/^BOOT_STARTED=//p' "$ORACLE_RUN_DIR/state.env" | tail -1)"
        return 0
    fi
    rm -f "$ORACLE_RUN_DIR/qemu.pid" "$ORACLE_RUN_DIR/monitor.sock"

    [ -f "$ORACLE_OVERLAY_QCOW2" ] || {
        log "creating overlay ${ORACLE_OVERLAY_QCOW2}"
        qemu-img create -q -f qcow2 -F qcow2 -b "$ORACLE_BASE_QCOW2" \
            "$ORACLE_OVERLAY_QCOW2"
    }

    # host keys live inside the overlay and may change after a reset
    ssh-keygen -R "[127.0.0.1]:${ORACLE_SSH_PORT}" -f "$ORACLE_KNOWN_HOSTS" \
        >/dev/null 2>&1 || true

    [ -f "$ORACLE_KNOWN_HOSTS" ] || : > "$ORACLE_KNOWN_HOSTS"

    : > "$ORACLE_RUN_DIR/state.env"
    T0=$(oracle_now)
    log "booting: ${QEMU} accel=${ORACLE_ACCEL} mem=${ORACLE_MEM}M smp=${ORACLE_SMP} ssh=127.0.0.1:${ORACLE_SSH_PORT}"
    "$QEMU" \
        -name crag-diff-oracle \
        -machine "pc,accel=${ORACLE_ACCEL}" \
        -m "$ORACLE_MEM" \
        -smp "$ORACLE_SMP" \
        -drive "file=${ORACLE_OVERLAY_QCOW2},if=virtio,format=qcow2" \
        -cdrom "$ORACLE_SEED_ISO" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ORACLE_SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -device virtio-rng-pci \
        -display none \
        -serial "file:${ORACLE_RUN_DIR}/console.log" \
        -monitor "unix:${ORACLE_RUN_DIR}/monitor.sock,server,nowait" \
        -pidfile "$ORACLE_RUN_DIR/qemu.pid" \
        -daemonize \
        || die "qemu failed to launch"
    printf 'QEMU_PID=%s\nSTARTED=%s\nSSH_PORT=%s\n' \
        "$(cat "$ORACLE_RUN_DIR/qemu.pid")" "$T0" "$ORACLE_SSH_PORT" \
        >> "$ORACLE_RUN_DIR/state.env"
    log "qemu pid $(cat "$ORACLE_RUN_DIR/qemu.pid"), console log: $ORACLE_RUN_DIR/console.log"
    wait_for_ssh "$T0"
}

cmd_stop() {
    if ! oracle_running; then
        log "not running"
        rm -f "$ORACLE_RUN_DIR/qemu.pid"
        return 0
    fi
    PID=$(cat "$ORACLE_RUN_DIR/qemu.pid")
    log "stopping pid $PID (ACPI powerdown, ${ORACLE_STOP_TIMEOUT}s grace)"
    hmp system_powerdown || true
    waited=0
    while [ "$waited" -lt "$ORACLE_STOP_TIMEOUT" ]; do
        kill -0 "$PID" 2>/dev/null || {
            log "guest powered off cleanly after ${waited}s"
            rm -f "$ORACLE_RUN_DIR/qemu.pid" "$ORACLE_RUN_DIR/monitor.sock"
            return 0
        }
        sleep 2
        waited=$(( waited + 2 ))
    done
    log "no clean shutdown in ${ORACLE_STOP_TIMEOUT}s; SIGTERM"
    kill -TERM "$PID" 2>/dev/null || true
    waited=0
    while [ "$waited" -lt 15 ]; do
        kill -0 "$PID" 2>/dev/null || {
            log "qemu exited after SIGTERM"
            rm -f "$ORACLE_RUN_DIR/qemu.pid" "$ORACLE_RUN_DIR/monitor.sock"
            return 0
        }
        sleep 1
        waited=$(( waited + 1 ))
    done
    log "SIGKILL"
    kill -KILL "$PID" 2>/dev/null || true
    rm -f "$ORACLE_RUN_DIR/qemu.pid" "$ORACLE_RUN_DIR/monitor.sock"
}

cmd_reset() {
    RESET_T0=$(oracle_now)
    log "reset: stopping VM and discarding all guest state"
    cmd_stop
    rm -f "$ORACLE_OVERLAY_QCOW2"
    log "reset: creating fresh overlay from pristine base"
    qemu-img create -q -f qcow2 -F qcow2 -b "$ORACLE_BASE_QCOW2" \
        "$ORACLE_OVERLAY_QCOW2"
    cmd_start
    log "reset complete in $(oracle_elapsed "$RESET_T0")s (fresh first boot)"
}

cmd_status() {
    if oracle_running; then
        PID=$(cat "$ORACLE_RUN_DIR/qemu.pid")
        printf 'state: running\n'
        printf 'pid: %s\n' "$PID"
    else
        printf 'state: stopped\n'
        printf 'pid: -\n'
    fi
    printf 'ssh_port: %s\n' "$ORACLE_SSH_PORT"
    printf 'ssh_user: %s\n' "$ORACLE_SSH_USER"
    printf 'accel: %s\n' "$ORACLE_ACCEL"
    printf 'base_image: %s\n' "$ORACLE_BASE_QCOW2"
    printf 'overlay: %s\n' "$ORACLE_OVERLAY_QCOW2"
    if [ -f "$ORACLE_OVERLAY_QCOW2" ]; then
        printf 'overlay_size: %s\n' "$(du -h "$ORACLE_OVERLAY_QCOW2" | awk '{print $1}')"
    else
        printf 'overlay_size: -\n'
    fi
    BOOT_SECONDS=$(sed -n 's/^BOOT_SECONDS=//p' "$ORACLE_RUN_DIR/state.env" 2>/dev/null | tail -1)
    printf 'last_boot_seconds: %s\n' "${BOOT_SECONDS:--}"
    if oracle_running && oracle_ssh true 2>/dev/null; then
        printf 'ssh: up\n'
        printf 'guest_uname: %s\n' "$(oracle_ssh 'uname -srm' 2>/dev/null)"
    elif oracle_running; then
        printf 'ssh: down\n'
    else
        printf 'ssh: -\n'
    fi
}

case "${1:-}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    reset)  cmd_reset ;;
    status) cmd_status ;;
    *)      printf 'usage: %s start|stop|reset|status\n' "$0" >&2; exit 2 ;;
esac
