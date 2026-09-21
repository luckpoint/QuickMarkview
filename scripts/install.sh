#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILT="$ROOT/dist/QuickMarkview.app"
DEST="${1:-/Applications}/QuickMarkview.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

"$ROOT/scripts/build-app.sh"

"$LSREGISTER" -u "$BUILT" 2>/dev/null || true
rm -rf "$DEST"
mv "$BUILT" "$DEST"
"$LSREGISTER" -f "$DEST"

echo "Installed $DEST"
