#!/bin/sh
# 把 SwiftPM 产物打成一个可双击的 .app。
#
#   ./Scripts/make-app.sh            # release
#   ./Scripts/make-app.sh debug      # debug
#
# 产物：build/红果短剧.app
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"

config=${1:-release}
swift build -c "$config"
bin=$(swift build -c "$config" --show-bin-path)

name="红果短剧"
app="$here/build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/HongguoPlayer" "$app/Contents/MacOS/HongguoPlayer"

# 有 sidecar 就一起打包：App 会优先用子进程访问真 SDK。
if [ -x "$here/build/openhongguo-sidecar" ]; then
	cp "$here/build/openhongguo-sidecar" "$app/Contents/Resources/openhongguo-sidecar"
	echo "  + Resources/openhongguo-sidecar"
else
	echo "  ! 没有 sidecar，App 会跑离线演示数据（先跑 Scripts/build-sidecar.sh）"
fi

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>HongguoPlayer</string>
	<key>CFBundleIdentifier</key>
	<string>dev.hongguo.player</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>红果短剧</string>
	<key>CFBundleDisplayName</key>
	<string>红果短剧</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.entertainment</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSHumanReadableCopyright</key>
	<string>非官方客户端，仅供学习研究</string>
</dict>
</plist>
PLIST

# ad-hoc 签名：本地跑得动，也免得 Gatekeeper 抱怨未签名二进制。
codesign --force --sign - "$app" >/dev/null 2>&1 || echo "（ad-hoc 签名失败，不影响本机运行）"

echo "built $app"
echo "运行： open \"$app\""
