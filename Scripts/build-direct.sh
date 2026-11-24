#!/bin/zsh
# Compile the same sources directly, without SwiftPM or external dependencies.
set -euo pipefail
cd "${0:A:h:h}"
SENTINEL_DIRECT_BUILD_DIR="${SENTINEL_DIRECT_BUILD_DIR:-$HOME/Library/Caches/MemorySentinel/DirectBuild}"
SENTINEL_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$SENTINEL_DIRECT_BUILD_DIR/CSystem" "$SENTINEL_DIRECT_BUILD_DIR/Modules"
cp Sources/CSystem/include/CSystem.h "$SENTINEL_DIRECT_BUILD_DIR/CSystem/CSystem.h"
cat > "$SENTINEL_DIRECT_BUILD_DIR/CSystem/module.modulemap" <<'MODULE'
module CSystem {
  header "CSystem.h"
  export *
}
MODULE
xcrun clang -O2 -target arm64-apple-macosx14.0 -isysroot "$SENTINEL_SDK_PATH" \
  -I Sources/CSystem/include -c Sources/CSystem/CSystem.c -o "$SENTINEL_DIRECT_BUILD_DIR/CSystem.o"
xcrun swiftc -O -whole-module-optimization -parse-as-library -swift-version 6 -D SWIFT_PACKAGE \
  -target arm64-apple-macosx14.0 -sdk "$SENTINEL_SDK_PATH" \
  -I "$SENTINEL_DIRECT_BUILD_DIR/CSystem" -module-name SentinelCore \
  -emit-library -static -emit-module -emit-module-path "$SENTINEL_DIRECT_BUILD_DIR/Modules/SentinelCore.swiftmodule" \
  Sources/SentinelCore/*.swift -o "$SENTINEL_DIRECT_BUILD_DIR/libSentinelCore.a"
xcrun swiftc -O -whole-module-optimization -parse-as-library -swift-version 6 -D SWIFT_PACKAGE \
  -target arm64-apple-macosx14.0 -sdk "$SENTINEL_SDK_PATH" \
  -I "$SENTINEL_DIRECT_BUILD_DIR/CSystem" -I "$SENTINEL_DIRECT_BUILD_DIR/Modules" \
  -module-name MemorySentinel Sources/MemorySentinel/*.swift \
  "$SENTINEL_DIRECT_BUILD_DIR/libSentinelCore.a" "$SENTINEL_DIRECT_BUILD_DIR/CSystem.o" \
  -lproc -lsqlite3 -o "$SENTINEL_DIRECT_BUILD_DIR/MemorySentinel"
if [[ "${1:-}" == "--tests" ]]; then
  xcrun swiftc -O -parse-as-library -swift-version 6 -D SWIFT_PACKAGE \
    -target arm64-apple-macosx14.0 -sdk "$SENTINEL_SDK_PATH" \
    -I "$SENTINEL_DIRECT_BUILD_DIR/CSystem" -I "$SENTINEL_DIRECT_BUILD_DIR/Modules" \
    -module-name SentinelCoreTests Tests/SentinelCoreTests/*.swift \
    "$SENTINEL_DIRECT_BUILD_DIR/libSentinelCore.a" "$SENTINEL_DIRECT_BUILD_DIR/CSystem.o" \
    -lproc -lsqlite3 -o "$SENTINEL_DIRECT_BUILD_DIR/SentinelCoreTests"
fi
print "Built $SENTINEL_DIRECT_BUILD_DIR/MemorySentinel"
