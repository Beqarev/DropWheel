#!/bin/bash
# Compiles the app and wraps the binary into DropWheel.app.
# Usage:  ./build.sh           -> build/DropWheel.app
#         ./build.sh run       -> build, then (re)launch it from build/
#         ./build.sh install   -> build, copy to /Applications, launch it from there
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/DropWheel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DropWheel "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
# "-" = ad-hoc signature. Enough to run on your own Mac, not to distribute.
codesign --force --sign - "$APP"
echo "Built $APP"

case "${1:-}" in
    run)
        pkill -x DropWheel 2>/dev/null || true
        open "$APP"
        ;;
    install)
        pkill -x DropWheel 2>/dev/null || true
        rm -rf /Applications/DropWheel.app
        cp -R "$APP" /Applications/
        open /Applications/DropWheel.app
        echo "Installed to /Applications/DropWheel.app"
        ;;
esac
