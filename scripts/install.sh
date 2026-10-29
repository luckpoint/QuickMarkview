#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILT="$ROOT/dist/QuickMarkview.app"
DEST="${1:-/Applications}/QuickMarkview.app"
BIN_DIR="${QMV_BIN_DIR:-$HOME/.local/bin}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

"$ROOT/scripts/build-app.sh"

"$LSREGISTER" -u "$BUILT" 2>/dev/null || true
rm -rf "$DEST"
mv "$BUILT" "$DEST"
"$LSREGISTER" -f "$DEST"
mkdir -p "$BIN_DIR"
ln -sf "$DEST/Contents/Resources/bin/qmv" "$BIN_DIR/qmv"

echo "Installed $DEST and $BIN_DIR/qmv"
