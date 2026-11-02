# Safe

An encrypted vault on the Desktop that only this PC can open. The vault
file is LUKS2, and its key is sealed in this machine's TPM 2.0 chip behind a
PIN. A copy of the file (from a backup, cloud sync, malware or a leaked
transcript) is useless anywhere else, even to someone who knows the PIN.

## Daily use

| Do this | What happens |
|---|---|
| Double-click **Safe** on the Desktop | asks for the PIN, unlocks, opens `~/Safe` in its own Dolphin window |
| Drop files/folders on the **Safe** icon | moves them inside (copy verified first), wipes the originals |
| Right-click → **Lock now** | closes the Safe's Dolphin window(s), locks, then backs up the vault file |
| Do nothing | locks itself 15 min after the last open, when the screen locks, or on sleep |

From a terminal: `safe`, `safe add FILE…`, `safe lock`, `safe backup`, `safe status`.
Set `SAFE_AUTOLOCK=30min` in the environment to change the auto-lock delay.

Wrong PINs are counted by the TPM chip itself; after enough misses it locks
out for a while. That's the point. A short PIN is safe because nobody can
guess it offline.

## How it's put together

| Piece | Where | Role |
|---|---|---|
| vault | `/var/lib/safe-lock/vault.img` (root-only) | LUKS2 + ext4, 64 MB (change with `resize.sh`) |
| key slots | inside the vault header | slot 0 recovery key, slot 1 TPM2 + PIN (no PCRs) |
| [root/safe-helper](root/safe-helper) | `/usr/local/libexec/safe-lock/safe-helper` | root side: attach/mount, unmount/detach |
| [root/org.safelock.policy](root/org.safelock.policy), [root/50-safe-lock.rules](root/50-safe-lock.rules) | polkit | lets you (only) run the helper without an admin password |
| `/etc/safe-lock.conf` | | paths, owner, backup folder; written by the installer |
| backups | `/media/max/SSD-2TB/safe-lock-backup/` | last three locked copies of the vault file |
| [bin/safe](bin/safe) | `~/.local/bin/safe` | everything you click |
| [desktop/Safe.desktop](desktop/Safe.desktop) | `~/Desktop/Safe.desktop` | the icon |
| [systemd/safe-watch.service](systemd/safe-watch.service) | user service | locks on screen lock / sleep |

The vault is mounted at `/run/safe-lock/vault` with `nosuid,nodev,noexec`;
`~/Safe` is a symlink to it that exists only while it's unlocked.

The TPM enrollment is deliberately **not** bound to PCRs. On this dual-boot
machine, Windows Update pushes Secure Boot (dbx) updates that would change
PCR 7 and lock you out. The chip itself is the machine binding.

## Install / reinstall

```bash
sudo ./install.sh --backup-dir /media/max/SSD-2TB/safe-lock-backup   # root parts + creates the vault (once); re-run to update
```

```bash
./install-user.sh        # icon, safe command, watcher (no sudo)
```

`prototype.sh` (TPM + PIN) and `test-resize.sh` (resizing) are throwaway
tests on dummy vaults; neither touches the real one.

## If the TPM is lost (keep this section reachable without the Safe)

A copy lives in this public repo:
<https://github.com/octopodas/safe-lock#if-the-tpm-is-lost-keep-this-section-reachable-without-the-safe>

**You need two things:** the paper recovery key and a copy of the vault
file. The key alone opens nothing.

**When this applies:** the motherboard died or was replaced; the TPM was
cleared in firmware; the disk moved to another PC; the Safe says "Could not
unlock" with a TPM error rather than "Wrong PIN". The same steps work if you
forgot the PIN or the TPM is in lockout.

1. **Find the vault file**, newest first:
   - `/var/lib/safe-lock/vault.img` on the old system disk (still the
     newest, if that disk survived)
   - `/media/max/SSD-2TB/safe-lock-backup/vault.img` (copy from the last
     lock), then `vault.img.1` and `vault.img.2` (the two locks before that)

2. **Open it with the recovery key** (works on any Linux machine, no TPM
   involved; type the recovery key at the passphrase prompt):

   ```bash
   sudo cryptsetup open --disable-external-tokens /path/to/vault.img safe-lock
   ```

   ```bash
   sudo mkdir -p /run/safe-lock/vault && sudo mount -o nosuid,nodev,noexec /dev/mapper/safe-lock /run/safe-lock/vault
   ```

   Your files are in `/run/safe-lock/vault`. Close it afterwards with
   `safe lock` if the Safe is installed, otherwise:

   ```bash
   sudo umount /run/safe-lock/vault && sudo cryptsetup close safe-lock
   ```

3. **Get the Safe working again on the new or repaired PC.** Put the vault
   file back in place before installing, and the installer keeps it:

   ```bash
   sudo install -D -m 0600 /path/to/vault.img /var/lib/safe-lock/vault.img
   ```

   ```bash
   sudo ./install.sh --backup-dir /media/max/SSD-2TB/safe-lock-backup && ./install-user.sh
   ```

   Then seal it to this PC's TPM. It asks for the recovery key, then a new PIN:

   ```bash
   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes --tpm2-pcrs= --wipe-slot=tpm2 /var/lib/safe-lock/vault.img
   ```

   The same command changes the PIN on a working Safe.

Never run `tpm2_clear` or clear the TPM in firmware without the recovery key
at hand. It also breaks BitLocker on the Windows side if that's enabled.

## Backups

After every lock, the vault file (still encrypted) is copied to
`SAFE_BACKUP_DIR` from `/etc/safe-lock.conf`, which here is
`/media/max/SSD-2TB/safe-lock-backup`. The last three copies are kept:
`vault.img`, `vault.img.1` and `vault.img.2`. The copies are sparse, so the
vault's never-used space takes no room on the drive. A copy is useless
without the recovery key, so it doesn't matter that the NTFS drive can't
restrict who reads it.

- The backup is skipped, with a warning, if the folder is on the vault's own
  disk. That also catches the SSD not being mounted.
- `safe backup` runs one by hand (the Safe must be locked).
- To change the folder: `sudo ./install.sh --backup-dir DIR`, or
  `--no-backup` to turn it off.
- Every copy is on this PC. For fire or theft, also keep a copy of
  `vault.img` somewhere else (cloud, USB stick). That's safe for the same
  reason.

## Changing the size

The PIN and recovery key stay as they are, because they live in the header,
which a resize doesn't touch. Lock the Safe first; the script asks for your
PIN and refuses a size that's too small before changing anything.

```bash
sudo ./resize.sh fit       # smallest size that leaves 16 MB free for new files
```

```bash
sudo ./resize.sh 512M      # any size, bigger or smaller
```

It keeps a copy of the old vault until the resized one has been reopened and
checked. `test-resize.sh` runs the same steps on a throwaway vault.

## Limits (what this does not protect)

- While unlocked, any program running as you can read the files, so keep it
  locked when not in use.
- The system disk isn't encrypted and swap is a plain `/swap.img`, so pages
  of opened files can land on disk. Full-disk encryption fixes that.
- Klipper (clipboard history) saves copied text to
  `~/.local/share/klipper/history2.lst`. Turn off "Save clipboard contents
  on exit" in its settings if you copy keys out of the Safe.
- Wiping originals with `shred` is best-effort on an SSD. Rotate any secret
  that ever sat in plaintext.
- Linux side only; Windows can't open it.

## Uninstall

Copy everything out of the Safe first. Then:

```bash
systemctl --user disable --now safe-watch.service && rm ~/.config/systemd/user/safe-watch.service ~/.local/bin/safe ~/Desktop/Safe.desktop
```

```bash
sudo rm -r /var/lib/safe-lock /usr/local/libexec/safe-lock /etc/safe-lock.conf /etc/polkit-1/rules.d/50-safe-lock.rules /usr/share/polkit-1/actions/org.safelock.policy
```
