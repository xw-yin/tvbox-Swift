#!/bin/bash
set -e

# 设置工作目录为脚本所在目录
cd "$(dirname "$0")"

echo "清理构建目录与旧文件..."
rm -rf build
rm -f TVBox-macOS.dmg TVBox-macOS.zip

# 释放 runner 磁盘空间
echo "清理 Xcode 缓存与未使用的系统缓存释放空间..."
rm -rf ~/Library/Developer/Xcode/DerivedData/* 2>/dev/null || true
df -h .

echo "开始构建 macOS 版本..."
xcodebuild -project tvbox.xcodeproj -scheme tvbox-macOS -configuration Release SYMROOT="$(pwd)/build" clean build

APP_PATH="build/Release/TVBox.app"

if [ ! -d "$APP_PATH" ]; then
    echo "错误: 找不到构建好的 App: $APP_PATH"
    exit 1
fi

echo "构建完成后的磁盘空间:"
df -h .

echo "创建 DMG 安装临时目录..."
DMG_DIR="build/dmg_stage"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"

echo "复制 App 至临时目录..."
cp -R "$APP_PATH" "$DMG_DIR/"

echo "创建 Applications 快捷方式..."
ln -s /Applications "$DMG_DIR/Applications"

echo "创建 DMG 安装包..."
if hdiutil create -volname "TVBox" -srcfolder "$DMG_DIR" -ov -format UDZO "TVBox-macOS.dmg"; then
    echo "✅ DMG 打包成功！生成文件: TVBox-macOS.dmg"
else
    echo "⚠️ hdiutil 创建 DMG 失败 (空间受限)，降级为 zip 压缩包..."
    ditto -c -k --keepParent "$APP_PATH" "TVBox-macOS.zip"
    echo "✅ Zip 打包成功！生成文件: TVBox-macOS.zip"
fi
