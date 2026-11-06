#!/bin/bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$TASK_DIR"
BUILD_DIR="$ROOT_DIR/build/pock"
SOURCES=("$TASK_DIR/Sources/ClawdScene.m" "$TASK_DIR/Sources/ClawdLive.m" "$TASK_DIR/Sources/ClawdView.m" "$TASK_DIR/Sources/ClawdWidget.m")
mkdir -p "$BUILD_DIR"

# build_variant NAME BUNDLE_ID LABEL PRINCIPAL_CLASS [extra clang flags...]
build_variant() {
    local name="$1" identifier="$2" label="$3" principal="$4"
    shift 4
    local bundle="$ROOT_DIR/dist/$name.pock"
    rm -rf "$bundle"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    for ARCH in arm64 x86_64; do
        xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter \
            -arch "$ARCH" -mmacosx-version-min=11.0 -O2 -bundle \
            -framework AppKit -framework QuartzCore -framework Security "$@" \
            "${SOURCES[@]}" -o "$BUILD_DIR/$name-$ARCH"
    done
    xcrun lipo -create "$BUILD_DIR/$name-arm64" "$BUILD_DIR/$name-x86_64" -output "$bundle/Contents/MacOS/$name"
    local plist="$bundle/Contents/Info.plist"
    cp "$TASK_DIR/Resources/Info.plist" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $name" \
        -c "Set :CFBundleIdentifier $identifier" \
        -c "Set :CFBundleName $label" \
        -c "Set :CFBundleDisplayName $label" \
        -c "Set :NSPrincipalClass $principal" "$plist"
    cp "$TASK_DIR/THIRD_PARTY_NOTICES.md" "$ROOT_DIR/LICENSE" "$ROOT_DIR/NOTICE" "$bundle/Contents/Resources/"
    if [[ "$name" == "ClawdLive" ]]; then
        cp "$TASK_DIR/Tools/clawd-statusline.sh" "$TASK_DIR/Tools/setup-live.sh" "$bundle/Contents/Resources/"
    fi
    codesign --force --sign - "$bundle"
    plutil -lint "$plist"
    rm -f "$ROOT_DIR/dist/$name.pock.zip"
    ditto -c -k --sequesterRsrc --keepParent "$bundle" "$ROOT_DIR/dist/$name.pock.zip"
}

# 1. Clawd: wanders, codes, sips coffee and naps on his own. Tap: tantrum.
build_variant Clawd com.jurekzsl.pock.Clawd Clawd ClawdWidget
# 2. Clawd Live: acts out what local Claude Code is doing. Tap: usage limits.
# Its classes are renamed so both widgets can be loaded by Pock together.
build_variant ClawdLive com.jurekzsl.pock.ClawdLive "Clawd Live" ClawdLiveWidget \
    -DCLAWD_LIVE=1 -DClawdView=ClawdLiveView -DClawdWidget=ClawdLiveWidget \
    -DCWClaudeMonitor=CWLiveClaudeMonitor

# The tools load the bundles' actual renderers in every mode. --check loads
# PockKit first, just as the host does. No widget classes are compiled twice.
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter \
    -mmacosx-version-min=11.0 -O2 -framework AppKit -framework QuartzCore \
    -Wl,-rpath,"${POCK_APP:-/Applications/Pock.app}/Contents/Frameworks" \
    -I "$TASK_DIR/Sources" "$TASK_DIR/Tools/main.m" \
    -o "$BUILD_DIR/ClawdTools"
printf 'Built %s\nBuilt %s\nPreview: %s --preview [--live]\n' \
    "$ROOT_DIR/dist/Clawd.pock" "$ROOT_DIR/dist/ClawdLive.pock" "$BUILD_DIR/ClawdTools"
