#!/bin/bash
# install.sh — root half of the Safe setup.
#   sudo ./install.sh [--backup-dir DIR | --no-backup] [SIZE]
#
#   SIZE defaults to 256M. Re-running upgrades the helper and config and
#   leaves an existing vault untouched. --backup-dir sets where the locked
#   vault is copied after every lock (must be on another disk); without the
#   flag a re-run keeps the previous setting.
#
# Creates /var/lib/safe-lock/vault.img (LUKS2) with two ways in:
#   1. this PC's TPM2 chip + your PIN (no PCR binding, so firmware/Windows
#      updates don't lock you out)
#   2. a recovery key you write down — the only way in if the TPM is gone.
set -uo pipefail

if [[ $EUID -ne 0 || -z ${SUDO_USER:-} || $SUDO_USER == root ]]; then
    echo "Run as your normal user through sudo: sudo $0"
    exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)

backup_dir=__keep__
while [[ ${1:-} == --* ]]; do
    case $1 in
        --backup-dir) backup_dir=${2:?--backup-dir needs a folder}; shift 2 ;;
        --no-backup)  backup_dir=; shift ;;
        *)            echo "unknown option: $1"; exit 1 ;;
    esac
done
if [[ $backup_dir == __keep__ ]]; then
    # shellcheck source=/dev/null
    backup_dir=$( [[ -r /etc/safe-lock.conf ]] && source /etc/safe-lock.conf; echo "${SAFE_BACKUP_DIR:-}" )
fi

size=${1:-256M}
user=$SUDO_USER
uid=$(id -u "$user")
gid=$(id -g "$user")

IMAGE=/var/lib/safe-lock/vault.img
MAPPER=safe-lock
MOUNT=/run/safe-lock/vault
LOG=/run/safe-lock-install.log

: > "$LOG"; chmod 644 "$LOG"
log()  { echo "$*"; echo "$(date +%T) $*" >> "$LOG"; }
fail() { log "FAILED: $*"; exit 1; }
clear_screen() { printf '\033[3J\033[H\033[2J'; }

log "== installing dependencies"
command -v cryptsetup >/dev/null || apt-get install -y cryptsetup-bin >/dev/null || fail "apt-get install cryptsetup-bin"

log "== installing helper, polkit policy and config"
install -D -m 0755 -o root -g root "$here/root/safe-helper" /usr/local/libexec/safe-lock/safe-helper || fail "install helper"
install -m 0644 -o root -g root "$here/root/org.safelock.policy" /usr/share/polkit-1/actions/org.safelock.policy || fail "install policy"
sed "s/__USER__/$user/" "$here/root/50-safe-lock.rules" > /etc/polkit-1/rules.d/50-safe-lock.rules || fail "install polkit rule"
chmod 0644 /etc/polkit-1/rules.d/50-safe-lock.rules
cat > /etc/safe-lock.conf <<EOF
# Safe configuration — read by safe-helper (root) and safe (user).
SAFE_USER=$user
SAFE_UID=$uid
SAFE_IMAGE=$IMAGE
SAFE_MAPPER=$MAPPER
SAFE_MOUNT=$MOUNT
SAFE_BACKUP_DIR=$(printf '%q' "$backup_dir")
EOF
chmod 0644 /etc/safe-lock.conf
log "backups after every lock: ${backup_dir:-off}"

if [[ -e $IMAGE ]]; then
    log "== vault already exists at $IMAGE, leaving it untouched"
    log "DONE"
    exit 0
fi

log "== creating the $size vault"
install -d -m 0700 -o root -g root /var/lib/safe-lock
fallocate -l "$size" "$IMAGE" || fail "fallocate"
chmod 0600 "$IMAGE"

key=$(mktemp /run/safe-key.XXXXXX)
pin='' pin2='' rk='' typed=''
cleanup() {
    [[ -f $key ]] && shred -u "$key"
    umount "$MOUNT" 2>/dev/null
    [[ -e /dev/mapper/$MAPPER ]] && systemd-cryptsetup detach "$MAPPER"
    pin='' pin2='' rk='' typed=''
}
trap cleanup EXIT
abort_vault() { rm -f "$IMAGE"; fail "$*"; }

head -c 64 /dev/urandom > "$key"
cryptsetup luksFormat --type luks2 --batch-mode --key-file "$key" "$IMAGE" >/dev/null || abort_vault "luksFormat"

# ---- recovery key -----------------------------------------------------------
log "== creating the recovery key (shown on screen only, never logged)"
rk=$(systemd-cryptenroll --unlock-key-file="$key" --recovery-key "$IMAGE" 2>/dev/null \
        | grep -oE '([cbdefghijklnrtuv]{8}-){7}[cbdefghijklnrtuv]{8}' | head -1)
[[ -n $rk ]] || abort_vault "recovery key enrollment"

while :; do
    clear_screen
    cat <<EOF

  ┌─────────────────────────── RECOVERY KEY ───────────────────────────┐

      $rk

  └─────────────────────────────────────────────────────────────────────┘

  Write this on paper and keep it somewhere safe, away from this PC.
  It opens the Safe on ANY Linux machine, so guard it like the secrets
  themselves. Without it, a dead motherboard or reset TPM = data gone.
  Don't photograph it or save it in a file on this computer.

EOF
    read -r -p "  Type it back to confirm you wrote it down (or press Enter to see it again): " typed
    typed=$(tr -d ' \t' <<<"$typed" | tr '[:upper:]' '[:lower:]')
    [[ $typed == "$rk" ]] && break
    [[ -n $typed ]] && { echo "  Doesn't match. Showing it again..."; sleep 2; }
done
rk='' typed=''
clear_screen
log "recovery key confirmed and cleared from the screen"

# ---- PIN --------------------------------------------------------------------
echo
echo "Now choose the PIN you'll type to open the Safe."
echo "The TPM chip itself blocks guessing, so 6 digits is plenty."
while :; do
    read -r -s -p "PIN: " pin; echo
    read -r -s -p "PIN again: " pin2; echo
    if [[ $pin != "$pin2" ]]; then echo "They don't match, try again."; continue; fi
    if (( ${#pin} < 4 )); then echo "Use at least 4 characters."; continue; fi
    break
done
pin2=

log "== sealing the key in the TPM (PIN required, no PCR binding)"
NEWPIN="$pin" systemd-cryptenroll --unlock-key-file="$key" --tpm2-device=auto \
    --tpm2-with-pin=yes --tpm2-pcrs= --wipe-slot=password "$IMAGE" >/dev/null \
    || abort_vault "TPM2 enrollment"
shred -u "$key"

log "== first unlock with the PIN and creating the filesystem"
PIN="$pin" systemd-cryptsetup attach "$MAPPER" "$IMAGE" - tpm2-device=auto,headless=true \
    || abort_vault "unlock with the new PIN"
pin=
mkfs.ext4 -q -L Safe -m 0 -E root_owner="$uid:$gid" "/dev/mapper/$MAPPER" || abort_vault "mkfs"
install -d -m 0755 /run/safe-lock "$MOUNT"
mount -o nosuid,nodev,noexec "/dev/mapper/$MAPPER" "$MOUNT" || abort_vault "mount"
rmdir "$MOUNT/lost+found" 2>/dev/null
printf '[Dolphin]\nPreviewsShown=false\nVersion=4\n' > "$MOUNT/.directory"
chown "$uid:$gid" "$MOUNT/.directory"
umount "$MOUNT"
systemd-cryptsetup detach "$MAPPER"

log "== key slots now on the vault:"
cryptsetup luksDump "$IMAGE" | sed -n '/^Tokens:/,/^Digests:/p' | grep -E '^\s+[0-9]+: ' | tee -a "$LOG"
log "DONE — now run ./install-user.sh (no sudo)"
