#!/bin/sh
#
# provision.sh - download, checksum-verify and prepare the FreeBSD VM
#                image that backs the differential-testing oracle
#                (PLAN.md P9: "real FreeBSD behavior is the reference").
#
# What it does (idempotent, safe to re-run):
#   1. downloads the official FreeBSD amd64 VM image + CHECKSUM.SHA256
#      from download.freebsd.org (TLS),
#   2. verifies the image's SHA256 against the published checksum file
#      AND against the pin below,
#   3. decompresses the pristine base qcow2 into $ORACLE_HOME/base
#      (kept read-only; never booted directly),
#   4. generates the ed25519 ssh keypair used for guest login,
#   5. builds the NoCloud seed ISO (user-data authorizes the ssh key for
#      the default 'freebsd' user; nuageinit in the guest applies it),
#   6. creates the qcow2 overlay that vm.sh boots (cheap reset = throw
#      the overlay away and make a new one).
#
# Exact release and checksum (recorded at first provisioning, 2026-11-07,
# from https://download.freebsd.org/releases/VM-IMAGES/15.1-RELEASE/amd64/Latest/CHECKSUM.SHA256):
#
#   image:    FreeBSD-15.1-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz
#   sha256:   e4ca4db889f8559c9b9dfcacc70405c038476f4b6d41649b152d3809a2ed9e1f
#
# (cragutils imports FreeBSD 15.1-RELEASE sources per upstream.conf, so
# the oracle runs the matching release.)
#
# Usage: provision.sh [--force]
#   --force  re-verify/rebuild everything even if cached.

set -eu

. "$(dirname "$0")/common.sh"

# Pin captured from CHECKSUM.SHA256 over TLS at first provisioning
# (2026-11-07).  Once non-empty, provisioning aborts if upstream's
# checksum file ever disagrees with this pin (image replaced upstream =
# re-pin deliberately).  Empty = first provisioning run, trust the
# checksum file over TLS and report the value to pin here.
EXPECTED_SHA256="e4ca4db889f8559c9b9dfcacc70405c038476f4b6d41649b152d3809a2ed9e1f"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

log() { printf 'provision: %s\n' "$*"; }
die() { printf 'provision: ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "$ORACLE_CACHE" "$ORACLE_BASE_DIR" "$ORACLE_RUN_DIR"

log "release=${ORACLE_RELEASE} arch=${ORACLE_ARCH} image=${ORACLE_IMAGE_XZ}"

# --- 1. fetch the published checksum file ------------------------------
log "fetching ${ORACLE_CHECKSUM_URL}"
curl -fsSL --retry 3 -o "$ORACLE_CACHE/CHECKSUM.SHA256.tmp" "$ORACLE_CHECKSUM_URL" \
    || die "cannot fetch CHECKSUM.SHA256"
mv "$ORACLE_CACHE/CHECKSUM.SHA256.tmp" "$ORACLE_CACHE/CHECKSUM.SHA256"

# FreeBSD checksum files use the format:  SHA256 (file) = hex
PUBLISHED=$(sed -n "s/^SHA256 (\(${ORACLE_IMAGE_XZ}\)) = \([0-9a-fA-F]*\)$/\2/p" \
    "$ORACLE_CACHE/CHECKSUM.SHA256")
[ -n "$PUBLISHED" ] || die "no entry for ${ORACLE_IMAGE_XZ} in CHECKSUM.SHA256"
log "published sha256: $PUBLISHED"

if [ -n "$EXPECTED_SHA256" ]; then
    [ "$PUBLISHED" = "$EXPECTED_SHA256" ] \
        || die "pin mismatch: published=$PUBLISHED pinned=$EXPECTED_SHA256 (upstream image changed?)"
    log "pin verified: $EXPECTED_SHA256"
else
    log "NOTE: EXPECTED_SHA256 is not pinned yet; pin this value in provision.sh:"
    log "      $PUBLISHED"
fi

MARKER="$ORACLE_BASE_DIR/.verified-sha256"
if [ "$FORCE" -eq 0 ] && [ -f "$MARKER" ] && [ -f "$ORACLE_BASE_QCOW2" ] \
    && [ "$(cat "$MARKER")" = "$PUBLISHED" ]; then
    log "base image already provisioned and verified; use --force to redo"
else
    # --- 2. download the image (resumable) ----------------------------
    if [ -f "$ORACLE_CACHE/$ORACLE_IMAGE_XZ" ] && [ "$FORCE" -eq 0 ]; then
        log "using cached download $ORACLE_CACHE/$ORACLE_IMAGE_XZ"
    else
        log "downloading ${ORACLE_IMAGE_URL} (~634 MiB)"
        curl -fL --retry 3 --retry-delay 2 -C - \
            -o "$ORACLE_CACHE/$ORACLE_IMAGE_XZ.tmp" "$ORACLE_IMAGE_URL" \
            || die "download failed"
        mv "$ORACLE_CACHE/$ORACLE_IMAGE_XZ.tmp" "$ORACLE_CACHE/$ORACLE_IMAGE_XZ"
    fi

    # --- 3. verify the download --------------------------------------
    log "verifying sha256 of ${ORACLE_IMAGE_XZ}"
    ACTUAL=$(sha256sum "$ORACLE_CACHE/$ORACLE_IMAGE_XZ" | awk '{print $1}')
    [ "$ACTUAL" = "$PUBLISHED" ] \
        || die "sha256 mismatch: got=$ACTUAL expected=$PUBLISHED"
    log "sha256 OK"

    # --- 4. decompress to the pristine base image --------------------
    log "decompressing to ${ORACLE_BASE_QCOW2}"
    xz -dc "$ORACLE_CACHE/$ORACLE_IMAGE_XZ" > "$ORACLE_BASE_QCOW2.tmp"
    mv "$ORACLE_BASE_QCOW2.tmp" "$ORACLE_BASE_QCOW2"
    chmod 444 "$ORACLE_BASE_QCOW2"      # pristine: never boot this directly
    printf '%s\n' "$PUBLISHED" > "$MARKER"
    log "base image ready ($(qemu-img info "$ORACLE_BASE_QCOW2" | sed -n 's/^virtual size: //p'))"
fi

# --- 5. ssh keypair for guest login -----------------------------------
if [ ! -f "$ORACLE_SSH_KEY" ]; then
    log "generating ed25519 keypair ${ORACLE_SSH_KEY}"
    ssh-keygen -q -t ed25519 -N '' -C 'cragutils-diff-oracle' -f "$ORACLE_SSH_KEY"
fi
[ -f "$ORACLE_SSH_KEY.pub" ] || die "missing ${ORACLE_SSH_KEY}.pub"
log "ssh pubkey: $(cat "$ORACLE_SSH_KEY.pub")"

# --- 6. NoCloud seed ISO ----------------------------------------------
# The BASIC-CLOUDINIT image runs nuageinit (FreeBSD's native cloud-init,
# libexec/nuageinit) at boot.  It reads user-data from a CD-ROM labelled
# 'cidata'.  With no 'users:' key, nuageinit creates/locates its default
# user ('freebsd', /home/freebsd, wheel) and installs the top-level
# 'ssh_authorized_keys' into that user's authorized_keys.
PUBKEY=$(cat "$ORACLE_SSH_KEY.pub")
SEED_DIR="$ORACLE_CACHE/seed"
rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR"
cat > "$SEED_DIR/user-data" <<EOF
#cloud-config
# cragutils differential-test oracle seed (tests/diff/oracle/provision.sh)
hostname: fbsd-oracle
ssh_authorized_keys:
  - ${PUBKEY}
EOF
cat > "$SEED_DIR/meta-data" <<EOF
instance-id: crag-diff-oracle-0001
local-hostname: fbsd-oracle
EOF
log "building ${ORACLE_SEED_ISO}"
rm -f "$ORACLE_SEED_ISO"
genisoimage -quiet -output "$ORACLE_SEED_ISO" -volid cidata -joliet -rock \
    "$SEED_DIR/user-data" "$SEED_DIR/meta-data" \
    || die "genisoimage failed (install genisoimage or mkisofs)"

# --- 7. qcow2 overlay (what actually boots; reset = new overlay) ------
if [ ! -f "$ORACLE_OVERLAY_QCOW2" ] || [ "$FORCE" -eq 1 ]; then
    log "creating overlay ${ORACLE_OVERLAY_QCOW2}"
    rm -f "$ORACLE_OVERLAY_QCOW2"
    qemu-img create -q -f qcow2 -F qcow2 -b "$ORACLE_BASE_QCOW2" \
        "$ORACLE_OVERLAY_QCOW2"
fi

log "done"
log "  release:  FreeBSD ${ORACLE_RELEASE} (${ORACLE_ARCH})"
log "  image:    ${ORACLE_IMAGE_XZ}"
log "  sha256:   ${PUBLISHED}"
log "  base:     ${ORACLE_BASE_QCOW2} (pristine, read-only)"
log "  overlay:  ${ORACLE_OVERLAY_QCOW2}"
log "  seed:     ${ORACLE_SEED_ISO}"
log "  ssh key:  ${ORACLE_SSH_KEY}"
log "next: ./vm.sh start && ./run-on-freebsd.sh 'uname -a'"
