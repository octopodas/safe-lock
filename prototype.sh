#!/bin/bash
# prototype.sh — throwaway check that LUKS2 + TPM2 + PIN works on this machine.
# Uses a 32 MB dummy image in /run and a dummy PIN; no real secrets involved.
# Run: sudo ./prototype.sh
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0"; exit 1; }

command -v cryptsetup >/dev/null || apt-get install -y cryptsetup-bin || exit 1

work=$(mktemp -d /run/safe-proto.XXXXXX)
img=$work/test.img
key=$work/tmpkey
name=safe-proto
cleanup() {
    umount "$work/mnt" 2>/dev/null
    systemd-cryptsetup detach "$name" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

step() { echo; echo "== $*"; }
fail() { echo "PROTOTYPE FAILED: $*"; exit 1; }

fallocate -l 32M "$img"
head -c 64 /dev/urandom > "$key"

step "luksFormat dummy image"
cryptsetup luksFormat --type luks2 --batch-mode --key-file "$key" "$img" || fail "luksFormat"

step "enroll TPM2 + PIN (dummy PIN), no PCR binding, drop the temp passphrase"
NEWPIN=2468 systemd-cryptenroll --unlock-key-file="$key" --tpm2-device=auto \
    --tpm2-with-pin=yes --tpm2-pcrs= --wipe-slot=password "$img" || fail "TPM2 enrollment"
cryptsetup luksDump "$img" | sed -n '/^Keyslots:/,/^Digests:/p' | grep -E '^\s+[0-9]+: |^\s+Keyslot:'

step "unlock with correct PIN"
PIN=2468 systemd-cryptsetup attach "$name" "$img" - tpm2-device=auto,headless=true || fail "attach with correct PIN"
mkfs.ext4 -q -L proto "/dev/mapper/$name" || fail "mkfs"
mkdir -p "$work/mnt"
mount -o nosuid,nodev,noexec "/dev/mapper/$name" "$work/mnt" || fail "mount"
echo "hello from the vault" > "$work/mnt/probe.txt"
umount "$work/mnt"
systemd-cryptsetup detach "$name" || fail "detach"

step "unlock with WRONG PIN (must fail; uses up one TPM guess)"
if PIN=0000 systemd-cryptsetup attach "$name" "$img" - tpm2-device=auto,headless=true; then
    fail "wrong PIN was accepted"
fi
echo "wrong PIN rejected (exit $?)"

step "unlock again with correct PIN and read the file back"
PIN=2468 systemd-cryptsetup attach "$name" "$img" - tpm2-device=auto,headless=true || fail "re-attach"
mount -o ro "/dev/mapper/$name" "$work/mnt" || fail "re-mount"
cat "$work/mnt/probe.txt" || fail "read back"

echo
echo "PROTOTYPE OK"
