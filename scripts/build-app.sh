#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

swift build -c release

BUILD_DIR=$(swift build -c release --show-bin-path)
APP="$ROOT/dist/QuickMarkview.app"
RESOURCE_DIR="$BUILD_DIR/QuickMarkview_QuickMarkview.bundle"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/QuickMarkview" "$APP/Contents/MacOS/QuickMarkview"
cp -R "$RESOURCE_DIR" "$APP/Contents/Resources/"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"

echo "Built $APP"
