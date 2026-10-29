#!/bin/sh
# 把演示数据源换成真的 openhongguo SDK。
#
#   ./Scripts/enable-sdk.sh [openhongguo 仓库路径]
#
# 默认路径 ../openhongguo；不存在就浅克隆到 .vendor/openhongguo。
#
# 做的事：
#   1. 检查 Go（gomobile 需要它）
#   2. 在 openhongguo 里跑 bindings/mobile/build.sh ios
#      → 生成 OpenhongguoCore.xcframework（含 macOS slice，仓库里不提交）
#   3. 在 Package.swift 里挂上本地 package 依赖
#   4. swift build 验证
#
# 撤销：把 Package.swift 里两处取消注释的行改回转注释，或 git checkout Package.swift
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"

sdk=${1:-}
if [ -z "$sdk" ]; then
	if [ -d "$here/../openhongguo/bindings" ]; then
		sdk="$here/../openhongguo"
	else
		sdk="$here/.vendor/openhongguo"
	fi
fi

if [ ! -d "$sdk/bindings/mobile" ]; then
	echo "→ 克隆 openhongguo 到 $sdk"
	mkdir -p "$(dirname "$sdk")"
	git clone --depth 1 https://github.com/beilunyang/openhongguo.git "$sdk"
fi

if ! command -v go >/dev/null 2>&1; then
	cat <<'EOF'
需要 Go 才能编译 SDK core。装一个（任选其一）：

  # 官方 pkg 安装包
  open https://go.dev/dl/

  # 或者解压 tarball 到 ~/sdk/go 后把 ~/sdk/go/bin 加进 PATH
  curl -LO https://go.dev/dl/go1.26.0.darwin-arm64.tar.gz
  mkdir -p ~/sdk && tar -C ~/sdk -xzf go1.26.0.darwin-arm64.tar.gz
  export PATH="$HOME/sdk/go/bin:$PATH"

装好后重跑：./Scripts/enable-sdk.sh
EOF
	exit 1
fi

if ! command -v gomobile >/dev/null 2>&1; then
	echo "→ 安装 gomobile"
	go install golang.org/x/mobile/cmd/gomobile@latest
	go install golang.org/x/mobile/cmd/gobind@latest
	export PATH="$(go env GOPATH)/bin:$PATH"
fi

if [ ! -d "$sdk/bindings/mobile/ios/OpenhongguoCore.xcframework" ]; then
	echo "→ 编译 Go core（gomobile bind -target ios,iossimulator,macos）"
	# 只需要 macOS 工程用得到的那部分；build.sh ios 会一并产出 iOS slice。
	(cd "$sdk" && ./bindings/mobile/build.sh ios)
fi

# 挂依赖：把 Package.swift 里预留的注释换成真代码（幂等）。
python3 - "$here/Package.swift" "$sdk" <<'PY'
import sys
path, sdk = sys.argv[1], sys.argv[2]
src = open(path).read()
dep = f'        .package(path: "{sdk}/bindings/mobile/ios"),'
prod = '                .product(name: "Openhongguo", package: "ios"),'
if dep not in src:
    src = src.replace(
        '        // .package(path: "../openhongguo/bindings/mobile/ios"),', dep, 1
    )
if prod not in src:
    src = src.replace(
        '                // .product(name: "Openhongguo", package: "ios"),', prod, 1
    )
open(path, 'w').write(src)
PY

echo "→ 编译 App"
swift build

cat <<EOF

完成。现在 App 用的是真 SDK：
  - 匿名设备档案：~/Library/Application Support/HongguoPlayer/anonymous.json
  - 校验：swift run selftest && swift run HongguoPlayer
EOF
