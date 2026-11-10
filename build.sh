#!/bin/zsh
# Builds BarDeck.app into ./build and signs it.
# Usage: ./build.sh            (release build)
#        ./build.sh --install  (also copies to /Applications and launches it)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/BarDeck.app
LOG=$(swift build -c release 2>&1) || { print -r -- "$LOG"; echo "Build failed"; exit 1; }
print -r -- "$LOG" | grep -vE '^\[[0-9]+ ?/ ?[0-9]+\]' || true
BIN=$(swift build -c release --show-bin-path)/BarDeck

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BarDeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Sign with a stable identity so macOS remembers the Accessibility and Automation permissions
# across rebuilds. Falls back to ad-hoc signing (people building from source without a certificate).
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x BarDeck 2>/dev/null || true
    rm -rf /Applications/BarDeck.app
    cp -R "$APP" /Applications/
    open /Applications/BarDeck.app
    echo "Installed to /Applications and launched"
fi
