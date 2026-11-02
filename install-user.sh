#!/bin/bash
# install-user.sh — user half of the Safe setup (no sudo). Run after
# `sudo ./install.sh`. Installs the `safe` command, the Desktop icon and the
# auto-lock watcher.
set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "Run without sudo."; exit 1; }
[[ -r /etc/safe-lock.conf ]] || { echo "Run 'sudo ./install.sh' first."; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
desktop=$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")

install -D -m 0755 "$here/bin/safe" "$HOME/.local/bin/safe"

sed "s|__HOME__|$HOME|g" "$here/desktop/Safe.desktop" > "$desktop/Safe.desktop"
chmod +x "$desktop/Safe.desktop"
# Mark as trusted so Plasma runs it without asking.
gio set "$desktop/Safe.desktop" metadata::trusted true 2>/dev/null || true

install -D -m 0644 "$here/systemd/safe-watch.service" "$HOME/.config/systemd/user/safe-watch.service"
systemctl --user daemon-reload
systemctl --user enable --now safe-watch.service

echo "Installed. The Safe icon is on your Desktop; 'safe status' says: $("$HOME/.local/bin/safe" status)"
