#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-v$(node -p 'require(process.argv[1]).version' "$ROOT_DIR/mcp/package.json")}"
BUILD_DIR="${BUILD_DIR:-/tmp/lookin-mcp-release-build}"
STAGE_DIR="$ROOT_DIR/dist/lookin-mcp-$VERSION"
ZIP_BASENAME="lookin-mcp-macos-arm64-$VERSION"
ZIP_PATH="$ROOT_DIR/dist/$ZIP_BASENAME.zip"
BRIDGE_BIN="$BUILD_DIR/Build/Products/Release/lookinextension"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/bin" "$ROOT_DIR/dist"

xcodebuild \
  -project "$ROOT_DIR/lookinextension/lookinextension.xcodeproj" \
  -scheme lookinextension \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -x "$BRIDGE_BIN" ]]; then
  echo "Expected release bridge binary at $BRIDGE_BIN" >&2
  exit 1
fi

cp "$BRIDGE_BIN" "$STAGE_DIR/bin/lookinextension"
cp -R "$ROOT_DIR/mcp" "$STAGE_DIR/mcp"
cp "$ROOT_DIR/README.md" "$STAGE_DIR/README.md"

chmod +x "$STAGE_DIR/bin/lookinextension" "$STAGE_DIR/mcp/server.js"

rm -f "$ZIP_PATH"
(
  cd "$ROOT_DIR/dist"
  zip -qry "$ZIP_BASENAME.zip" "lookin-mcp-$VERSION"
)

echo "Release package created:"
echo "  $ZIP_PATH"
