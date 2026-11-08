# common.sh - shared configuration for the FreeBSD differential-testing
# oracle (PLAN.md P9).  Sourced by provision.sh, vm.sh, run-on-freebsd.sh
# and smoke.sh.  Every setting can be overridden from the environment.
#
# The oracle is a real FreeBSD RELEASE userland booted in QEMU; it is the
# reference implementation for tests/diff/.  Nothing here modifies the
# host system outside $ORACLE_HOME.

# --- what we provision -------------------------------------------------
# Must match upstream.conf's VER so the oracle tracks the FreeBSD release
# cragutils was imported from (see upstream.conf).
ORACLE_RELEASE="${ORACLE_RELEASE:-15.1-RELEASE}"
ORACLE_ARCH="${ORACLE_ARCH:-amd64}"
ORACLE_IMAGE_BASE="FreeBSD-${ORACLE_RELEASE}-${ORACLE_ARCH}-BASIC-CLOUDINIT-ufs"
ORACLE_IMAGE_XZ="${ORACLE_IMAGE_BASE}.qcow2.xz"

# Official FreeBSD VM image mirror + published checksum file.
ORACLE_MIRROR="${ORACLE_MIRROR:-https://download.freebsd.org/releases/VM-IMAGES}"
ORACLE_URL="${ORACLE_MIRROR}/${ORACLE_RELEASE}/${ORACLE_ARCH}/Latest"
ORACLE_CHECKSUM_URL="${ORACLE_URL}/CHECKSUM.SHA256"
ORACLE_IMAGE_URL="${ORACLE_URL}/${ORACLE_IMAGE_XZ}"

# The pinned SHA256 of ORACLE_IMAGE_XZ lives in provision.sh
# (EXPECTED_SHA256); provision.sh checks it against the checksum file.

# --- where artifacts live (heavy files stay out of the git tree) -------
ORACLE_HOME="${ORACLE_HOME:-$HOME/.cache/freebsd-oracle}"
ORACLE_CACHE="$ORACLE_HOME/cache"           # downloads (xz, CHECKSUM.SHA256)
ORACLE_BASE_DIR="$ORACLE_HOME/base"         # pristine decompressed base image
ORACLE_RUN_DIR="$ORACLE_HOME/run"           # per-VM mutable state
ORACLE_BASE_QCOW2="$ORACLE_BASE_DIR/${ORACLE_IMAGE_BASE}.qcow2"
ORACLE_OVERLAY_QCOW2="$ORACLE_RUN_DIR/overlay.qcow2"
ORACLE_SEED_ISO="$ORACLE_HOME/seed.iso"
ORACLE_SSH_KEY="$ORACLE_HOME/id_oracle"     # ed25519 keypair for guest login
ORACLE_KNOWN_HOSTS="$ORACLE_HOME/known_hosts"

# --- VM shape ----------------------------------------------------------
ORACLE_SSH_PORT="${ORACLE_SSH_PORT:-2224}"  # fixed hostfwd port on 127.0.0.1
ORACLE_SSH_USER="${ORACLE_SSH_USER:-freebsd}"
ORACLE_GUEST_CWD="${ORACLE_GUEST_CWD:-/home/freebsd}"
# run-on-freebsd.sh mode 2 (-- TOOL): the per-call fresh run directory
# on the guest (stable path so path normalization can target it).
ORACLE_GUEST_RUNDIR="${ORACLE_GUEST_RUNDIR:-/tmp/crag-diff-w}"
ORACLE_MEM="${ORACLE_MEM:-2048}"
ORACLE_SMP="${ORACLE_SMP:-2}"
ORACLE_ACCEL="${ORACLE_ACCEL:-tcg}"         # this host has no /dev/kvm
ORACLE_BOOT_TIMEOUT="${ORACLE_BOOT_TIMEOUT:-600}"
ORACLE_STOP_TIMEOUT="${ORACLE_STOP_TIMEOUT:-120}"

# ssh access to the guest.  Host keys are (re)generated inside the overlay
# on first boot, so after a reset vm.sh prunes the known_hosts entry and
# accept-new re-learns the fresh key.
ORACLE_SSH_OPTS="-i $ORACLE_SSH_KEY -p $ORACLE_SSH_PORT \
  -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=$ORACLE_KNOWN_HOSTS -o ConnectTimeout=5 \
  -o LogLevel=ERROR"

oracle_ssh() {
    # oracle_ssh <remote command...>
    # shellcheck disable=SC2086
    ssh $ORACLE_SSH_OPTS "${ORACLE_SSH_USER}@127.0.0.1" "$@"
}

oracle_now() {
    # fractional epoch seconds (GNU date on the host)
    date +%s.%N
}

oracle_elapsed() {
    # oracle_elapsed <start-fractional-epoch> -> "N.NN" seconds on stdout
    awk -v s="$1" -v e="$(oracle_now)" 'BEGIN { printf "%.2f", e - s }'
}

oracle_running() {
    [ -f "$ORACLE_RUN_DIR/qemu.pid" ] || return 1
    kill -0 "$(cat "$ORACLE_RUN_DIR/qemu.pid")" 2>/dev/null
}
