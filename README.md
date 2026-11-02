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
| Right-click → **Lock now** | closes the Safe's Dolphin window(s) and locks |
| Do nothing | locks itself 15 min after the last open, when the screen locks, or on sleep |

From a terminal: `safe`, `safe add FILE…`, `safe lock`, `safe status`.
Set `SAFE_AUTOLOCK=30min` in the environment to change the auto-lock delay.

Wrong PINs are counted by the TPM chip itself; after enough misses it locks
out for a while. That's the point. A short PIN is safe because nobody can
guess it offline.

## How it's put together

| Piece | Where | Role |
|---|---|---|
| vault | `/var/lib/safe-lock/vault.img` (root-only) | LUKS2 + ext4, 256 MB |
| key slots | inside the vault header | slot 0 recovery key, slot 1 TPM2 + PIN (no PCRs) |
| [root/safe-helper](root/safe-helper) | `/usr/local/libexec/safe-lock/safe-helper` | root side: attach/mount, unmount/detach |
| [root/org.safelock.policy](root/org.safelock.policy), [root/50-safe-lock.rules](root/50-safe-lock.rules) | polkit | lets you (only) run the helper without an admin password |
| `/etc/safe-lock.conf` | | paths + owner, written by the installer |
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
sudo ./install.sh        # root parts + creates the vault (once); re-run to update the helper
```

```bash
./install-user.sh        # icon, safe command, watcher (no sudo)
```

`prototype.sh` is the throwaway TPM test used before the first install.

## Recovery (keep this section reachable without the Safe)

**Open with the recovery key on this PC** (TPM broken, PIN forgotten, lockout):

```bash
sudo systemd-cryptsetup attach safe-lock /var/lib/safe-lock/vault.img
```

It tries the TPM first, then asks for a passphrase; type the recovery key.
Then:

```bash
sudo mkdir -p /run/safe-lock/vault && sudo mount -o nosuid,nodev,noexec /dev/mapper/safe-lock /run/safe-lock/vault
```

**Open a copy on another Linux machine:**

```bash
sudo cryptsetup open vault.img safe && sudo mount /dev/mapper/safe /mnt
```

**Re-seal to the TPM** (new motherboard, cleared TPM, or to change the PIN).
It asks for the recovery key, then the new PIN:

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes --tpm2-pcrs= --wipe-slot=tpm2 /var/lib/safe-lock/vault.img
```

Never run `tpm2_clear` or clear the TPM in firmware without the recovery key
at hand. It also breaks BitLocker on the Windows side if that's enabled.

## Backups

The vault file is safe to back up anywhere while the Safe is locked; only the
recovery key can open it off this machine.

```bash
safe lock && sudo cp /var/lib/safe-lock/vault.img /path/to/backup/
```

## Making it bigger

```bash
safe lock && sudo truncate -s +256M /var/lib/safe-lock/vault.img
```

Then open the Safe and grow the filesystem:

```bash
sudo resize2fs /dev/mapper/safe-lock
```

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
