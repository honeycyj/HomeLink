#!/usr/bin/env bash
set -euo pipefail

REVEAL_PACKAGE=false
case "${1:-}" in
  '') ;;
  --reveal) REVEAL_PACKAGE=true ;;
  --help|-h)
    echo 'Usage: ./script/package.sh [--reveal]'
    echo 'Build an Apple Silicon test package. --reveal shows the result in Finder.'
    exit 0 ;;
  *) echo 'Usage: ./script/package.sh [--reveal]' >&2; exit 2 ;;
esac
if (( $# > 1 )); then
  echo 'Too many arguments.' >&2
  exit 2
fi

TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$TASK_ROOT/.build"
DERIVED_DATA="$BUILD_DIR/DistributionDerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Release/HomeLink.app"
OUTPUT_DIR="$TASK_ROOT/Distribution"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
source "$TASK_ROOT/script/signing_settings.sh"

# Build separately from the running development app; packaging never stops it.
if ! xcodebuild -project "$TASK_ROOT/HomeLink.xcodeproj" -scheme HomeLink \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    "CODE_SIGN_ENTITLEMENTS=$TASK_ROOT/Configuration/Distribution.entitlements" \
    "${SIGNING_SETTINGS[@]}" build > "$BUILD_DIR/distribution-build.log" 2>&1; then
  tail -n 60 "$BUILD_DIR/distribution-build.log" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_BUNDLE/Contents/MacOS/HomeLink")"
if [[ "$ARCHITECTURES" != "arm64" ]]; then
  echo "Expected Apple Silicon only (arm64), found: $ARCHITECTURES" >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_BUNDLE/Contents/Info.plist")"
PACKAGE_NAME="HomeLink-$VERSION-test-arm64"
STAGING="$(mktemp -d "$BUILD_DIR/package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

# Only ship the compiled app. Never include Application Support or Keychain data.
/usr/bin/ditto "$APP_BUNDLE" "$STAGING/HomeLink.app"
/bin/ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/安装说明.txt" <<EOF
HomeLink $VERSION 测试版

系统要求：macOS $MINIMUM_OS 或更新版本。
仅支持 Apple Silicon（M 系列芯片，arm64），不支持 Intel Mac。

安装：将 HomeLink.app 拖入 Applications（应用程序），然后打开。
HomeLink 只在菜单栏显示链条图标，没有 Dock 图标。

此包仅供测试，使用本地测试签名，尚未完成 Apple Developer ID 分发签名或苹果公证。
不需要购买苹果开发者会员即可使用这个测试包。

首次打开如果提示无法验证开发者或无法检查恶意软件：
1. 确认安装包来自你信任的来源，并先尝试打开一次 HomeLink。
2. 打开“系统设置 → 隐私与安全性”，找到 HomeLink 对应的提示并点“仍要打开”。
3. 在随后的系统提示中自行确认“打开”。系统会记住这次允许。
系统管理策略可能禁止此操作；公司受管理的 Mac 请联系管理员。
若提示应用已损坏或将损坏电脑，请停止并重新获取、核对安装包。
无需导入开发证书，也不需要关闭系统整体安全保护。
苹果官方操作说明：https://support.apple.com/zh-cn/102445

这个安装包不含原电脑的设备记录、SSH 私钥、已信任主机或连接日志。
新电脑首次使用需添加设备，并在远程 Mac 授权它生成的公钥。
不同客户端分别授权各自公钥，不要覆盖原有 authorized_keys。
远程 Mac 仍需开启远程登录和屏幕共享；公网连接还需可达的网络和端口配置。

更新：先退出旧版 HomeLink，再替换应用。相同签名和应用标识用于保持本机数据兼容。
EOF

/usr/bin/hdiutil create -volname 'HomeLink' -srcfolder "$STAGING" \
    -format UDZO -ov "$OUTPUT_DIR/$PACKAGE_NAME.dmg" > "$BUILD_DIR/dmg-build.log"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGING/HomeLink.app" \
    "$OUTPUT_DIR/$PACKAGE_NAME.zip"
/bin/cp "$STAGING/安装说明.txt" "$OUTPUT_DIR/安装说明.txt"
(cd "$OUTPUT_DIR" && /usr/bin/shasum -a 256 "$PACKAGE_NAME.dmg" "$PACKAGE_NAME.zip" > SHA256SUMS.txt)
/usr/bin/hdiutil verify "$OUTPUT_DIR/$PACKAGE_NAME.dmg"
echo "Packaged: $OUTPUT_DIR/$PACKAGE_NAME.dmg"
if [[ "$REVEAL_PACKAGE" == true ]]; then
  /usr/bin/open -R "$OUTPUT_DIR/$PACKAGE_NAME.dmg"
fi
