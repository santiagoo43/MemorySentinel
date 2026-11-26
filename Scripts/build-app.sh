#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ -n "${SENTINEL_PREBUILT_BINARY:-}" ]]; then
  [[ -x "$SENTINEL_PREBUILT_BINARY" ]] || { print -u2 "Missing prebuilt executable"; exit 1; }
  SENTINEL_BINARY="$SENTINEL_PREBUILT_BINARY"
else
  swift build -c release --product MemorySentinel
  SENTINEL_BINARY=".build/release/MemorySentinel"
fi
case "$(lipo -archs "$SENTINEL_BINARY")" in
  arm64) SENTINEL_ARCH=arm64 ;;
  x86_64) SENTINEL_ARCH=x86_64 ;;
  "arm64 x86_64"|"x86_64 arm64") SENTINEL_ARCH=universal ;;
  *) print -u2 "Unsupported executable architecture"; exit 1 ;;
esac
SENTINEL_ARCHIVE_PATH="${SENTINEL_ARCHIVE_PATH:-$PWD/build/MemorySentinel-macOS-$SENTINEL_ARCH.zip}"
SENTINEL_OUTPUT_DIR="${SENTINEL_OUTPUT_DIR:-$PWD/build}"
APP="$SENTINEL_OUTPUT_DIR/MemorySentinel.app"
if [[ -e "$APP" ]]; then
  SENTINEL_EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$SENTINEL_EXISTING_ID" != "local.memorysentinel.app" ]]; then
    print -u2 "Refusing to replace a different application at $APP"
    exit 1
  fi
  if [[ -n "$(/usr/sbin/lsof -t "$APP/Contents/MacOS/MemorySentinel" 2>/dev/null)" ]]; then
    print -u2 "Quit the application at $APP before replacing it"
    exit 1
  fi
fi
mkdir -p build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SENTINEL_BINARY" "$APP/Contents/MacOS/MemorySentinel"
# Keep local compiler paths out of the distributed executable.
xcrun strip -S "$APP/Contents/MacOS/MemorySentinel"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MemorySentinel</string>
<key>CFBundleIdentifier</key><string>local.memorysentinel.app</string>
<key>CFBundleName</key><string>MemorySentinel</string>
<key>CFBundleDisplayName</key><string>MemorySentinel</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.0</string>
<key>CFBundleVersion</key><string>11</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><false/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>NSHumanReadableCopyright</key><string>MemorySentinel · Local memory diagnostics</string>
</dict></plist>
PLIST
swift Scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
mkdir -p "${SENTINEL_ARCHIVE_PATH:h}"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SENTINEL_ARCHIVE_PATH"
print "Built $APP"
print "Archive $SENTINEL_ARCHIVE_PATH"
