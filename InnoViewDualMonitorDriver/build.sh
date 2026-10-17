#!/bin/sh
# Builds build/InnoViewDualMonitorDriver.app (no Xcode project needed, Command Line Tools are
# enough) and installs it to ~/Applications, where it registers itself as a
# login item.
#   ./build.sh       build and install
#   ./build.sh run   also restart the running copy
# CODESIGN_IDENTITY=<name of a code signing certificate> signs with it instead
# of ad hoc (see below).
set -eu
cd "$(dirname "$0")"

APP=build/InnoViewDualMonitorDriver.app
INSTALL_DIR="$HOME/Applications"
OBJ=build/obj
mkdir -p "$OBJ" "$APP/Contents/MacOS"

CFLAGS="-O2 -g -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=14.0 -Isrc"

# Objects of removed or renamed sources must not end up in the link.
rm -f "$OBJ"/*.o
for f in src/*.c; do
    clang -std=c11 $CFLAGS -c "$f" -o "$OBJ/$(basename "$f" .c).o"
done
for f in src/*.m; do
    clang -fobjc-arc $CFLAGS -c "$f" -o "$OBJ/$(basename "$f" .m).o"
done

clang -mmacosx-version-min=14.0 "$OBJ"/*.o -o "$APP/Contents/MacOS/InnoViewDualMonitorDriver" \
    -framework AppKit -framework IOKit -framework CoreFoundation -framework CoreGraphics \
    -framework CoreMedia -framework CoreVideo -framework ScreenCaptureKit -framework ServiceManagement \
    -framework Metal

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon, rendered from icon/AppIcon.svg only when the SVG or the renderer
# changes.
ICNS=build/AppIcon.icns
if [ ! -f "$ICNS" ] || [ icon/AppIcon.svg -nt "$ICNS" ] || [ icon/render_iconset.m -nt "$ICNS" ]; then
    clang -fobjc-arc -mmacosx-version-min=14.0 icon/render_iconset.m -o "$OBJ/render_iconset" \
        -framework AppKit
    rm -rf build/AppIcon.iconset
    "$OBJ/render_iconset" icon/AppIcon.svg build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o "$ICNS"
fi
mkdir -p "$APP/Contents/Resources"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# The "Screen Recording" permission belongs to the designated requirement, so
# it has to stay the same across rebuilds.
# - With CODESIGN_IDENTITY (for example a self-signed "Code Signing"
#   certificate from Keychain Access) the requirement names the identifier
#   and the certificate: only builds signed with it get the permission.
# - Without it: ad hoc, and the requirement names only the identifier (the
#   default ad hoc requirement is the cdhash, which changes with every build).
#   Any ad hoc signed program can claim that identifier and get the
#   permission without asking.
BUNDLE_ID=com.newparadigma.innoviewdualmonitordriver
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
    codesign --force --sign - --identifier "$BUNDLE_ID" -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
    echo "note: ad hoc signature, any program signed as $BUNDLE_ID shares its Screen Recording permission;"
    echo "      set CODESIGN_IDENTITY to sign with a certificate"
fi
# The icon cache goes by the date of the bundle directory itself, which
# rebuilding its contents doesn't change; without this the old icon stays.
touch "$APP"
echo "built $APP"

# Replace the installed copy by rename: a running instance keeps its old files.
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/InnoViewDualMonitorDriver.app.new"
ditto "$APP" "$INSTALL_DIR/InnoViewDualMonitorDriver.app.new"
rm -rf "$INSTALL_DIR/InnoViewDualMonitorDriver.app"
mv "$INSTALL_DIR/InnoViewDualMonitorDriver.app.new" "$INSTALL_DIR/InnoViewDualMonitorDriver.app"
echo "installed $INSTALL_DIR/InnoViewDualMonitorDriver.app"

if [ "${1:-}" = run ]; then
    # SIGTERM makes the running copy switch the screen off and release the device.
    if pkill -TERM -x InnoViewDualMonitorDriver; then
        while pgrep -x InnoViewDualMonitorDriver >/dev/null; do sleep 0.2; done
    fi
    open "$INSTALL_DIR/InnoViewDualMonitorDriver.app"
    echo "started"
fi
