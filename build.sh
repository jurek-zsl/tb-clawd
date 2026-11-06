#!/bin/bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$TASK_DIR"
BUILD_DIR="$ROOT_DIR/build/pock"
BUNDLE="$ROOT_DIR/dist/Clawd.pock"
mkdir -p "$BUILD_DIR" "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
for ARCH in arm64 x86_64; do
    xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter \
        -arch "$ARCH" -mmacosx-version-min=11.0 -O2 -bundle \
        -framework AppKit -framework QuartzCore \
        "$TASK_DIR/Sources/ClawdScene.m" "$TASK_DIR/Sources/ClawdView.m" "$TASK_DIR/Sources/ClawdWidget.m" \
        -o "$BUILD_DIR/Clawd-$ARCH"
done
xcrun lipo -create "$BUILD_DIR/Clawd-arm64" "$BUILD_DIR/Clawd-x86_64" -output "$BUNDLE/Contents/MacOS/Clawd"
cp "$TASK_DIR/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$TASK_DIR/THIRD_PARTY_NOTICES.md" "$ROOT_DIR/LICENSE" "$ROOT_DIR/NOTICE" "$BUNDLE/Contents/Resources/"
codesign --force --sign - "$BUNDLE"
plutil -lint "$BUNDLE/Contents/Info.plist"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ROOT_DIR/dist/Clawd.pock.zip"
# The tools load the bundle's actual renderer in every mode. --check loads
# PockKit first, just as the host does. No widget classes are compiled twice.
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter \
    -mmacosx-version-min=11.0 -O2 -framework AppKit -framework QuartzCore \
    -Wl,-rpath,"${POCK_APP:-/Applications/Pock.app}/Contents/Frameworks" \
    -I "$TASK_DIR/Sources" "$TASK_DIR/Tools/main.m" \
    -o "$BUILD_DIR/ClawdTools"
printf 'Built %s\nPreview: %s --preview\n' "$BUNDLE" "$BUILD_DIR/ClawdTools"
