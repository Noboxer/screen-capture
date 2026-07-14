#!/usr/bin/env bash
# install.sh — build and install ScreenCapture.app
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.thea.screencapture"
APP_DEST="/Applications/ScreenCapture.app"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

echo "=== ScreenCapture installer ==="
echo ""

# 1. Build release binary
echo "Building Swift binary..."
cd "$SCRIPT_DIR"
swift build -c release 2>&1 | tail -5
echo "  ✓ Build complete"

# 2. Assemble .app bundle
echo "Assembling ScreenCapture.app..."
rm -rf "$APP_DEST"
mkdir -p "$APP_DEST/Contents/MacOS"
mkdir -p "$APP_DEST/Contents/Resources"

cp "$SCRIPT_DIR/.build/release/ScreenCapture" "$APP_DEST/Contents/MacOS/ScreenCapture"
chmod +x "$APP_DEST/Contents/MacOS/ScreenCapture"
cp "$SCRIPT_DIR/Sources/ScreenCapture/Info.plist" "$APP_DEST/Contents/Info.plist"

# Generate AppIcon.icns from the same drawing code the menu-bar icon uses, so
# the Finder icon, Dock placeholder, and About-window icon all match.
echo "Generating AppIcon.icns..."
"$APP_DEST/Contents/MacOS/ScreenCapture" --generate-icns "$APP_DEST/Contents/Resources/AppIcon.icns"
if [ -f "$APP_DEST/Contents/Resources/AppIcon.icns" ]; then
    echo "  ✓ Icon written"
else
    echo "  ⚠ Icon generation failed (continuing without it)"
fi

# Ad-hoc codesign the bundle with a stable identifier matching the bundle ID.
# Without this, every rebuild produces an unsigned binary that macOS treats as
# a brand-new app, creating duplicate entries in Privacy & Security and prompting
# for Screen Recording / Accessibility on every install. Ad-hoc signing pins the
# identifier to the bundle ID so TCC has a stable handle.
codesign --force --deep --options runtime \
    --identifier com.thea.screencapture \
    --sign - "$APP_DEST"
echo "  ✓ Installed and ad-hoc signed: $APP_DEST"

# Nudge Finder/LaunchServices to pick up the new icon.
touch "$APP_DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_DEST" >/dev/null 2>&1 || true

# 3. LaunchAgent plist — launch the binary inside the bundle
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$PLIST_NAME</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_DEST/Contents/MacOS/ScreenCapture</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/screen-capture.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/screen-capture-error.log</string>
</dict>
</plist>
PLIST
echo "  ✓ LaunchAgent written: $PLIST_PATH"

# 4. Load the agent
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load  "$PLIST_PATH"
echo "  ✓ Daemon started"

echo ""
echo "=== Installation complete ==="
echo ""
echo "Hotkeys:"
echo "  Ctrl+Shift+S  →  Screenshot (area select) → annotate → clipboard"
echo "  Ctrl+Shift+F  →  Screenshot (fullscreen)  → annotate → clipboard"
echo "  Ctrl+Shift+R  →  Start / stop video recording"
echo "  Ctrl+Shift+Q  →  Quit"
echo ""
echo "Grant these permissions when prompted:"
echo "  • Screen Recording  (System Settings → Privacy & Security → Screen Recording)"
echo "  • Accessibility     (System Settings → Privacy & Security → Accessibility)"
echo ""
echo "Logs: ~/Library/Logs/screen-capture.log"
echo "To stop:    launchctl unload $PLIST_PATH"
echo "To restart: launchctl load   $PLIST_PATH"
