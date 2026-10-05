#!/bin/bash
# 构建 AirPodMicBlocker.app（Apple Silicon + Intel 通用二进制）
#
# 用法：
#   ./build.sh              构建并安装到 ~/Applications
#   ./build.sh --no-install 只在 build/ 里产出，不动 ~/Applications
#   ./build.sh --release    额外打一个 zip（放 dist/），用于分发
set -euo pipefail

cd "$(dirname "$0")"

NAME="AirPodMicBlocker"
BUILD="build"
DIST="dist"
APP="$HOME/Applications/$NAME.app"
DEPLOY_TARGET="13.0"

INSTALL=1
RELEASE=0
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --release)    RELEASE=1 ;;
    -h|--help)    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$arg（--help 看用法）"; exit 2 ;;
  esac
done

rm -rf "$BUILD"
mkdir -p "$BUILD"

FRAMEWORKS="-framework AppKit -framework CoreAudio -framework AudioToolbox -framework ServiceManagement -framework Security"

echo "▸ 编译 (arm64) …"
# shellcheck disable=SC2086
swiftc -O -swift-version 5 \
  -target "arm64-apple-macosx$DEPLOY_TARGET" \
  -o "$BUILD/$NAME.arm64" \
  Sources/*.swift $FRAMEWORKS

echo "▸ 编译 (x86_64) …"
# shellcheck disable=SC2086
swiftc -O -swift-version 5 \
  -target "x86_64-apple-macosx$DEPLOY_TARGET" \
  -o "$BUILD/$NAME.x86_64" \
  Sources/*.swift $FRAMEWORKS

echo "▸ 合并通用二进制 …"
lipo -create "$BUILD/$NAME.arm64" "$BUILD/$NAME.x86_64" -output "$BUILD/$NAME"

# 生成应用图标
echo "▸ 生成应用图标 …"
swiftc -O Tools/MakeIcon.swift -o "$BUILD/makeicon" -framework AppKit 2>/dev/null
"$BUILD/makeicon" "$BUILD/$NAME.iconset" >/dev/null
iconutil -c icns "$BUILD/$NAME.iconset" -o "$BUILD/$NAME.icns"

if [ "$INSTALL" -eq 1 ]; then
  echo "▸ 打包 .app → $APP"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BUILD/$NAME" "$APP/Contents/MacOS/$NAME"
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  cp "$BUILD/$NAME.icns" "$APP/Contents/Resources/$NAME.icns"
  printf 'APPL????' > "$APP/Contents/PkgInfo"

  # 临时签名：没有开发者证书时也要能跑（SMAppService 开机自启要求签名）
  echo "▸ 临时签名 …"
  codesign --force --sign - "$APP" >/dev/null 2>&1 \
    || echo "  （跳过签名，不影响使用；开机自启可能不可用）"

  # 让 Finder 立刻用上新图标
  touch "$APP" 2>/dev/null || true

  # 命令行软链
  mkdir -p "$HOME/bin"
  ln -sf "$APP/Contents/MacOS/$NAME" "$HOME/bin/$NAME"
fi

if [ "$RELEASE" -eq 1 ]; then
  echo "▸ 打 zip → $DIST"
  rm -rf "$DIST"
  mkdir -p "$DIST"
  cp -R "$APP" "$DIST/"
  cp README.md "$DIST/" 2>/dev/null || true
  ( cd "$DIST" && zip -qry "$NAME-$NAME-macos.zip" . )
  echo "   $DIST/$NAME-$NAME-macos.zip"
fi

echo ""
if [ "$INSTALL" -eq 1 ]; then
  echo "✅ 构建完成：$APP"
  echo "   启动菜单栏 App：open \"$APP\""
  echo "   命令行用法：    \"$APP/Contents/MacOS/$NAME\" --status"
else
  echo "✅ 构建完成：$BUILD/$NAME"
fi