#!/bin/bash
# resize.sh — make the vault smaller or bigger, keeping its PIN and recovery
# key (they live in the header, which a resize doesn't touch).
#   sudo ./resize.sh fit         smallest size that leaves 16 MB free
#   sudo ./resize.sh SIZE        e.g. 96M, 512M, 1G
# The Safe must be locked.
#
# It unlocks with your PIN, refuses sizes too small for what's inside
# before changing anything, resizes, then reopens the result to check it.
# A copy of the old vault is kept until that check passes.
#
# Set DRY_RUN_IMAGE=/path/to/test.img and DRY_RUN_PIN=... to try it on a
# throwaway vault instead of the real one.
set -uo pipefail

HEADROOM=$(( 16 * 1024 * 1024 ))   # free space `fit` leaves for new files
MiB4=$(( 4 * 1024 * 1024 ))

die() { echo "resize: $*" >&2; exit 1; }
iec() { numfmt --to=iec -- "$1"; }

[[ $EUID -eq 0 ]] || die "run with sudo: sudo $0 fit|SIZE"
[[ $# -eq 1 ]] || die "usage: sudo $0 fit|SIZE   (e.g. fit, 96M, 1G)"
# shellcheck source=/dev/null
source /etc/safe-lock.conf
IMAGE=${DRY_RUN_IMAGE:-$SAFE_IMAGE}
MAPPER=$SAFE_MAPPER
[[ -n ${DRY_RUN_IMAGE:-} ]] && MAPPER=safe-lock-resize-test
dev=/dev/mapper/$MAPPER
safety="$IMAGE.before-resize"

if [[ ${1,,} == fit ]]; then
    new=fit
else
    new=$(numfmt --from=iec "${1^^}" 2>/dev/null) || die "can't read size '$1'"
    new=$(( new / MiB4 * MiB4 ))
fi
[[ -e $dev ]] && die "the Safe is unlocked; lock it first (safe lock)"
cur=$(stat -c %s "$IMAGE") || die "no vault at $IMAGE"
offset=$(cryptsetup luksDump "$IMAGE" | awk '/^Data segments:/ {f=1} f && /offset:/ {print $2; exit}')
[[ $offset =~ ^[0-9]+$ ]] || die "couldn't read the vault header"

attach() {
    PIN="$pin" systemd-cryptsetup attach "$MAPPER" "$IMAGE" - tpm2-device=auto,headless=true \
        || die "unlock failed (wrong PIN?)"
}
detach() { [[ -e $dev ]] && systemd-cryptsetup detach "$MAPPER"; }
fsck_ok() { e2fsck -f -y "$dev" >/dev/null 2>&1; (( $? < 4 )); }
fs_stats() {   # sets bcount bfree bsize
    read -r bcount bfree bsize < <(dumpe2fs -h "$dev" 2>/dev/null | awk -F: '
        /^Block count/ {c=$2} /^Free blocks/ {f=$2} /^Block size/ {s=$2}
        END {print c+0, f+0, s+0}')
}
cleanup() { detach 2>/dev/null; pin=''; }
trap cleanup EXIT

if [[ -n ${DRY_RUN_PIN:-} ]]; then
    pin=$DRY_RUN_PIN
else
    read -r -s -p "Safe PIN: " pin; echo
fi

# Look inside first: checks the PIN and finds the smallest workable size.
attach
fsck_ok || die "filesystem check failed; nothing was changed"
fs_stats
min=$(( $(resize2fs -P "$dev" 2>/dev/null | awk -F: '{print $2+0}') * bsize ))
detach
floor=$(( (offset + min + HEADROOM + MiB4 - 1) / MiB4 * MiB4 ))
echo "In use: $(iec $(( (bcount - bfree) * bsize ))) (files plus filesystem bookkeeping)."
echo "Smallest workable size: $(iec "$floor") (keeps about $(iec "$HEADROOM") free for new files)."

[[ $new == fit ]] && new=$floor
(( new == cur )) && { echo "Already $(iec "$cur"); nothing to do."; exit 0; }
(( new < cur && new < floor )) && die "$(iec "$new") is too small; nothing was changed. Try: sudo $0 fit"

echo "Resizing $(iec "$cur") -> $(iec "$new"). Keeping a copy of the old vault until it checks out..."
cp --sparse=always "$IMAGE" "$safety" || die "couldn't make the safety copy"
chmod 0600 "$safety"
restore() {
    echo "Putting the old vault back." >&2
    detach 2>/dev/null
    mv -f "$safety" "$IMAGE"
    die "$*"
}

if (( new < cur )); then
    attach
    fsck_ok || restore "filesystem check failed"
    resize2fs "$dev" "$(( (new - offset) / 1024 ))K" >/dev/null 2>&1 || restore "resize2fs failed"
    detach
    truncate -s "$new" "$IMAGE" || restore "truncate failed"
else
    truncate -s "$new" "$IMAGE" || restore "truncate failed"
    attach
    fsck_ok || restore "filesystem check failed"
    resize2fs "$dev" >/dev/null 2>&1 || restore "resize2fs failed"
    detach
fi

echo "Checking the resized vault..."
attach
e2fsck -f -n "$dev" >/dev/null 2>&1 || restore "check of the resized filesystem failed"
fs_stats
detach
rm -f "$safety"

echo "Done: the vault is now $(iec "$(stat -c %s "$IMAGE")") with $(iec $(( bfree * bsize ))) free."
echo "PIN and recovery key unchanged. Backups pick up the new size from the next lock."
