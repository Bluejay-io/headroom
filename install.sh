#!/usr/bin/env bash
# Installs Headroom into /Applications and starts it.
# curl -fsSL https://raw.githubusercontent.com/bluejay-io/headroom/main/install.sh | bash
set -euo pipefail

REPO="bluejay-io/headroom"
URL="https://github.com/$REPO/releases/latest/download/Headroom.zip"
DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  echo "Note: /Applications isn't writable, installing to ~/Applications instead." >&2
  echo "Menu bar managers on macOS 27 can't keep apps visible from there." >&2
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Headroom only runs on macOS." >&2
  exit 1
fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$major" -lt 14 ]; then
  echo "Headroom needs macOS 14 (Sonoma) or newer." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Headroom..."
curl -fsSL "$URL" -o "$tmp/Headroom.zip"
ditto -x -k "$tmp/Headroom.zip" "$tmp"

if pgrep -x Headroom >/dev/null; then
  osascript -e 'quit app "Headroom"' >/dev/null 2>&1 || true
  sleep 1
  pkill -x Headroom 2>/dev/null || true
fi

[ "$DEST" = "/Applications" ] && rm -rf "$HOME/Applications/Headroom.app"
mkdir -p "$DEST"
rm -rf "$DEST/Headroom.app"
mv "$tmp/Headroom.app" "$DEST/Headroom.app"
xattr -dr com.apple.quarantine "$DEST/Headroom.app" 2>/dev/null || true

open "$DEST/Headroom.app"
echo "Headroom is installed in $DEST and running in your menu bar."
echo "If macOS asks about Keychain access for Claude Code, choose Always Allow."
