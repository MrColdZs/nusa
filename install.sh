#!/bin/sh
# Pasang Nusa di Mac: curl -fsSL https://raw.githubusercontent.com/MrColdZs/nusa/main/install.sh | sh
# Diunduh lewat curl jadi macOS nggak ngeblok ("Apple could not verify") kayak file dari browser.
set -e
REPO="MrColdZs/nusa"
DEST="${NUSA_DEST:-/Applications}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ "$(uname)" = "Darwin" ] || { echo "Script ini buat macOS. Windows/Linux: unduh dari https://github.com/$REPO/releases"; exit 1; }
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || { echo "Nusa butuh macOS 14 (Sonoma) atau lebih baru. Mac ini: $(sw_vers -productVersion)"; exit 1; }

echo "Mengunduh Nusa..."
curl -fsSL "https://github.com/$REPO/releases/latest/download/Nusa-macOS.zip" -o "$TMP/Nusa.zip"
ditto -x -k "$TMP/Nusa.zip" "$TMP"

if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
osascript -e 'tell application "Nusa" to quit' >/dev/null 2>&1 || true
rm -rf "$DEST/Nusa.app"
mv "$TMP/Nusa.app" "$DEST/Nusa.app"
xattr -dr com.apple.quarantine "$DEST/Nusa.app" 2>/dev/null || true

echo "Nusa terpasang di $DEST/Nusa.app"
[ -n "$NUSA_NO_OPEN" ] || open "$DEST/Nusa.app"
