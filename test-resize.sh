#!/bin/bash
# test-resize.sh — tries resize.sh on a throwaway 256 MB vault (dummy PIN,
# random dummy files) before it touches the real one: shrink, a refused
# too-small shrink, and grow, checking the files survive each step.
# Run: sudo ./test-resize.sh
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0"; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)

work=$(mktemp -d /run/safe-resize-test.XXXXXX)
img=$work/test.img
name=safe-lock-resize-test
dev=/dev/mapper/$name
cleanup() {
    umount "$work/mnt" 2>/dev/null
    systemd-cryptsetup detach "$name" 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

step() { echo; echo "== $*"; }
fail() { echo "TEST FAILED: $*"; exit 1; }
size_is() { [[ $(stat -c %s "$img") -eq $(numfmt --from=iec "$1") ]]; }
check_files() {
    PIN=2468 systemd-cryptsetup attach "$name" "$img" - tpm2-device=auto,headless=true || fail "attach"
    mount -o ro "$dev" "$work/mnt" || fail "mount"
    (cd "$work/mnt" && sha256sum -c --quiet "$work/sums") || fail "files changed"
    df -h --output=size,used,avail "$work/mnt" | tail -1
    umount "$work/mnt"
    systemd-cryptsetup detach "$name"
}
resize() { DRY_RUN_IMAGE=$img DRY_RUN_PIN=2468 "$here/resize.sh" "$1"; }

step "make a 256M dummy vault like install.sh does, with 20 MB of dummy files"
fallocate -l 256M "$img"
(umask 077; head -c 64 /dev/urandom > "$work/key")
cryptsetup luksFormat --type luks2 --batch-mode --key-file "$work/key" "$img" >/dev/null || fail "luksFormat"
NEWPIN=2468 systemd-cryptenroll --unlock-key-file="$work/key" --tpm2-device=auto \
    --tpm2-with-pin=yes --tpm2-pcrs= --wipe-slot=password "$img" >/dev/null 2>&1 || fail "enroll"
PIN=2468 systemd-cryptsetup attach "$name" "$img" - tpm2-device=auto,headless=true || fail "attach"
mkfs.ext4 -q -L Safe -m 0 "$dev" || fail "mkfs"
mkdir -p "$work/mnt" && mount "$dev" "$work/mnt" || fail "mount"
head -c 20M /dev/urandom > "$work/mnt/big.bin"
echo "dummy key" > "$work/mnt/keys.txt"
(cd "$work/mnt" && sha256sum big.bin keys.txt > "$work/sums")
umount "$work/mnt"
systemd-cryptsetup detach "$name"

step "shrink 256M -> fit"
resize fit || fail "shrink"
fitted=$(stat -c %s "$img")
(( fitted < 128 * 1024 * 1024 )) || fail "fit didn't shrink below 128M ($fitted bytes)"
check_files

step "shrink to 32M (too small for 20 MB of files: must refuse and change nothing)"
if resize 32M; then fail "too-small shrink was accepted"; fi
[[ $(stat -c %s "$img") -eq $fitted ]] || fail "file changed after a refused shrink"
[[ ! -e $img.before-resize ]] || fail "safety copy left behind"
check_files

step "grow to 160M"
resize 160M || fail "grow"
size_is 160M || fail "file is not 160M"
check_files

step "fit again after growing (shrink with the files in place)"
resize fit || fail "second shrink"
[[ $(stat -c %s "$img") -le $fitted ]] || fail "second fit is bigger than the first"
check_files

echo
echo "RESIZE TEST OK"
