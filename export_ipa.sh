#!/bin/bash
# 本地 macOS 打包脚本（未签名 IPA，供越狱/AppSync/Sideloadly 安装）
set -euo pipefail
SCHEME="MagnetPlayer"
CONFIGURATION="Release"
BUILD_DIR="build"
OUTPUT="${OUTPUT:-MagnetPlayer.ipa}"

cd "$(dirname "$0")"
rm -rf "$BUILD_DIR" "$OUTPUT"

echo "==> 生成 Xcode 工程 (xcodegen)"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "请先安装: brew install xcodegen"
  exit 1
fi
xcodegen generate

echo "==> 编译 Release（不签名）"
xcodebuild build \
  -project MagnetPlayer.xcodeproj \
  -scheme MagnetPlayer \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR/app" \
  -quiet

echo "==> ad-hoc 重签名"
APP="$BUILD_DIR/app/$SCHEME.app"
codesign --force --sign - "$APP" 2>/dev/null || echo "codesign skipped"

echo "==> 打包 Payload"
rm -rf "$BUILD_DIR/Payload"; mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
( cd "$BUILD_DIR" && zip -qry "$SCHEME.ipa" Payload )
mv "$BUILD_DIR/$SCHEME.ipa" "$OUTPUT"

echo "✅ 构建完成: $OUTPUT"
ls -lh "$OUTPUT"
