#!/bin/sh
# Builds TuringScreen.app (menu bar app) into macos/build/: release binary, the 3.5" themes and only the fonts they
# use, Info.plist with LSUIElement (no Dock icon), ad-hoc signature.
# Usage: bundle.sh [--install]   --install also copies it to ~/Applications (quitting a running copy first) and starts it,
#                                 through its LaunchAgent if Open at login is on
set -e
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
APP="build/TuringScreen.app"

./build.sh -c release --product TuringScreen
BIN="$(./build.sh -c release --show-bin-path)/TuringScreen"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/res/themes" "$APP/Contents/Resources/res/fonts"
cp "$BIN" "$APP/Contents/MacOS/TuringScreen"
cp "$REPO/res/themes/default.yaml" "$APP/Contents/Resources/res/themes/"

# Themes for the 3.5" display (DISPLAY_SIZE 3.5" or unset), and the fonts they reference
FONTS="roboto-mono/RobotoMono-Regular.ttf
roboto/Roboto-Black.ttf"
for yaml in "$REPO"/res/themes/*/theme.yaml; do
    dir="$(dirname "$yaml")"
    size="$(grep -m1 'DISPLAY_SIZE' "$yaml" | sed 's/.*DISPLAY_SIZE: *//; s/[" ]//g' || true)"
    [ -z "$size" ] || [ "$size" = "3.5" ] || continue
    cp -R "$dir" "$APP/Contents/Resources/res/themes/"
    FONTS="$FONTS
$(grep -E '^\s*(AXIS_)?FONT:' "$yaml" | sed 's/.*FONT: *//; s/ *#.*//; s/["'\'']//g')"
done
echo "$FONTS" | sort -u | while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$REPO/res/fonts/$f" ] || continue
    mkdir -p "$APP/Contents/Resources/res/fonts/$(dirname "$f")"
    cp "$REPO/res/fonts/$f" "$APP/Contents/Resources/res/fonts/$f"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>TuringScreen</string>
    <key>CFBundleIdentifier</key><string>local.turingscreen</string>
    <key>CFBundleName</key><string>Turing Screen</string>
    <key>CFBundleDisplayName</key><string>Turing Screen</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "$APP: $(du -sh "$APP" | cut -f1), $(ls "$APP/Contents/Resources/res/themes" | grep -vc yaml) themes, $(find "$APP/Contents/Resources/res/fonts" -type f | wc -l | tr -d ' ') fonts"

if [ "$1" = "--install" ]; then
    DEST="$HOME/Applications/TuringScreen.app"
    osascript -e 'quit app id "local.turingscreen"' 2>/dev/null && sleep 2 || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "installed to $DEST"

    # The app owns the LaunchAgent plist (Settings > Open at login). If it's on, reload the agent so launchd runs
    # this build now and relaunches it after a crash; otherwise just open the app.
    AGENT="$HOME/Library/LaunchAgents/local.turingscreen.plist"
    if [ -f "$AGENT" ]; then
        launchctl bootout "gui/$(id -u)/local.turingscreen" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$AGENT"
        echo "started by launch agent $AGENT"
    else
        open "$DEST"
    fi
fi
