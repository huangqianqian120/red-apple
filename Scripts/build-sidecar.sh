#!/bin/sh
# 编译 Go sidecar，并把它塞进 .app 的 Resources。
#
#   ./Scripts/build-sidecar.sh [openhongguo 仓库路径]
#
# 需要 Go（不需要 Xcode、不需要 gomobile）。
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"

sdk=${1:-}
if [ -z "$sdk" ]; then
	if [ -d "$here/../openhongguo/bindings" ]; then
		sdk="$here/../openhongguo"
	elif [ -d "$here/.vendor/openhongguo/bindings" ]; then
		sdk="$here/.vendor/openhongguo"
	else
		sdk="$here/.vendor/openhongguo"
		echo "→ 克隆 openhongguo 到 $sdk"
		mkdir -p "$(dirname "$sdk")"
		git clone --depth 1 https://github.com/beilunyang/openhongguo.git "$sdk"
	fi
fi

if ! command -v go >/dev/null 2>&1; then
	if [ -x "$HOME/sdk/go/bin/go" ]; then
		PATH="$HOME/sdk/go/bin:$PATH"
		export PATH
	else
		echo "需要 Go：https://go.dev/dl/（或解压到 ~/sdk/go）" >&2
		exit 1
	fi
fi

# 国内网络走代理会快很多；已经设了 GOPROXY 就不覆盖。
: "${GOPROXY:=https://goproxy.cn,direct}"
export GOPROXY

echo "→ SDK: $sdk"
(cd "$here/sidecar" && go mod edit -replace "github.com/beilunyang/openhongguo=$sdk" && go mod tidy && go build -trimpath -ldflags="-s -w" -o "$here/build/openhongguo-sidecar" .)

mkdir -p "$here/build"
echo "built $here/build/openhongguo-sidecar  ($(du -h "$here/build/openhongguo-sidecar" | cut -f1))"
