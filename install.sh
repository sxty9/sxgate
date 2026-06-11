#!/usr/bin/env bash
# Installs sxgate into /usr/local/bin and prepares /etc/sxgate/.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

SRC="$(cd "$(dirname "$0")" && pwd)"

install -m 0755 "$SRC/bin/sxgate" /usr/local/bin/sxgate
install -d -m 0755 /etc/sxgate /etc/sxgate/backups
[ -f /etc/sxgate/services ] || install -m 0644 /dev/null /etc/sxgate/services

echo "sxgate installed to /usr/local/bin/sxgate"
echo "state dir:           /etc/sxgate/"
echo
echo "next: sudo sxgate init --zone <yourdomain>"
