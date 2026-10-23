#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${STRAND_VERSION:-0.1.0}"
BUILD="${STRAND_BUILD:-1}"
APP="$(pwd)/dist/Strand.app"
swift build -c release --arch arm64
BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)"
FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$APP/Contents/Resources" ]; then
    rm -rf "$APP/Contents/Resources"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
ditto Sources/Strand/Resources "$APP/Contents/Resources"
cp "$BIN_PATH/Strand" "$APP/Contents/MacOS/Strand"
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
fi
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Strand</string>
<key>CFBundleIdentifier</key><string>com.opyuii.strand</string>
<key>CFBundleName</key><string>Strand</string>
<key>CFBundleDisplayName</key><string>Strand</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUEnableInstallerLauncherService</key><true/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
</dict></plist>
PLIST
PUBLIC_KEY="$(python3 -c 'import json; print(json.load(open("updates/config.json"))["public_key"])')"
FEED_URL="$(python3 -c 'import json; print(json.load(open("updates/config.json"))["feed_url"])')"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$APP/Contents/Info.plist"
# Preserve Sparkle's upstream signatures, including its nested helpers.
# A stable identity keeps macOS privacy permissions across updates; an ad-hoc signature changes with every build.
SIGNING_KEYCHAIN="$(bash scripts/signing-identity.sh)"
codesign --force --keychain "$SIGNING_KEYCHAIN" --sign "Strand Local Signing" "$APP"
if ! codesign -d --requirements - "$APP" 2>&1 | grep -q "certificate leaf"; then
    echo "Strand was not signed with the stable identity." >&2
    exit 1
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD)"

SIZE=$(python3 - "$APP" <<'PYSIZE'
from pathlib import Path
import sys
print(sum(p.stat().st_size for p in Path(sys.argv[1]).rglob('*') if p.is_file() and not p.is_symlink()))
PYSIZE
)
[ "$SIZE" -lt 41943040 ] || { echo "App exceeds 40 MB"; exit 1; }
