#!/usr/bin/env bash
# install.sh — build and install ScreenCapture.app
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.thea.screencapture"
APP_DEST="/Applications/ScreenCapture.app"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

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

# Codesign the bundle. A stable self-signed identity (created by
# scripts/setup-signing.sh) keeps macOS from dropping the app's Screen Recording +
# Accessibility grants on every rebuild/update — ad-hoc signing does NOT, because
# its code hash changes each build and TCC then treats the app as brand new.
# Falls back to ad-hoc if the identity hasn't been set up.
SIGN_IDENTITY="ScreenCapture Self-Signed"
# Note: not `-v` — a self-signed cert is untrusted (CSSMERR_TP_NOT_TRUSTED) so it
# never appears in the "valid" list, but codesign can still sign with it, and the
# resulting designated requirement is pinned to the cert (stable across rebuilds).
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    SIGN_WITH="$SIGN_IDENTITY"
    echo "Signing with stable identity: $SIGN_IDENTITY"
else
    SIGN_WITH="-"
    echo "Signing ad-hoc (permissions reset on each update)."
    echo "  → Run scripts/setup-signing.sh once to make grants persist across updates."
fi
codesign --force --deep --options runtime \
    --identifier com.thea.screencapture \
    --sign "$SIGN_WITH" "$APP_DEST"
echo "  ✓ Installed and signed: $APP_DEST"

# Nudge Finder/LaunchServices to pick up the new icon.
touch "$APP_DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_DEST" >/dev/null 2>&1 || true

# 3. Migrate away from the legacy KeepAlive LaunchAgent.
# Older installs registered autostart via a launchd agent with KeepAlive=true.
# Start-at-login is now handled in-app by SMAppService (toggle in Settings → About),
# so the agent is unloaded and removed. KeepAlive also meant "Quit" respawned the
# app — dropping it makes Quit actually quit.
if [ -f "$LEGACY_PLIST" ]; then
    echo "Removing legacy LaunchAgent..."
    launchctl unload "$LEGACY_PLIST" 2>/dev/null || true
    rm -f "$LEGACY_PLIST"
    echo "  ✓ Legacy autostart removed"
fi

# Stop any running instance so the freshly-installed one takes over cleanly.
pkill -x ScreenCapture 2>/dev/null || true
sleep 1

# 4. Launch. On first run the app registers itself as a login item because the
#    "Start at login" preference defaults on (change it in Settings → About).
open "$APP_DEST"
echo "  ✓ Launched"

echo ""
echo "=== Installation complete ==="
echo ""
echo "Default hotkeys (rebindable in Settings → Shortcuts):"
echo "  Ctrl+Shift+S  →  Screenshot (area select) → annotate → clipboard"
echo "  Ctrl+Shift+F  →  Screenshot (fullscreen)  → annotate → clipboard"
echo "  Ctrl+Shift+R  →  Start / stop video recording"
echo "  Ctrl+Shift+Q  →  Quit"
echo ""
echo "Grant these permissions when prompted:"
echo "  • Screen Recording  (System Settings → Privacy & Security → Screen Recording)"
echo "  • Accessibility     (System Settings → Privacy & Security → Accessibility)"
echo ""
echo "Start at login:  Settings → About → Startup  (on by default)"
echo "Check for updates: menu bar icon → Check for Updates…"
