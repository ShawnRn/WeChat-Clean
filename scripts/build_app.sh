#!/bin/bash
# 微信存储管理 - 一键打包脚本
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

echo "==> 正在编译 WeChatClean (Release)..."
swift build -c release

APP_NAME="微信存储管理.app"
APP_DIR="$DIR/$APP_NAME"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> 正在构建 $APP_NAME 结构..."
mkdir -p "$MACOS" "$RESOURCES/scripts"

cp "$DIR/.build/release/WeChatClean" "$MACOS/WeChatClean"
chmod +x "$MACOS/WeChatClean"

if [ -f "$DIR/scripts/extract_keys.py" ]; then
    cp "$DIR/scripts/extract_keys.py" "$RESOURCES/scripts/extract_keys.py"
    chmod +x "$RESOURCES/scripts/extract_keys.py"
fi

if [ -f "$DIR/Resources/Info.plist" ]; then
    cp "$DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
fi

echo "==> 清除属性并进行本地代码签名..."
xattr -cr "$APP_DIR" || true
codesign --force --deep --sign - "$APP_DIR" || true

echo "==> 构建成功！应用位于: $APP_DIR"
