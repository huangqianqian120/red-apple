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
# 用一份临时 go.mod 构建，构建完把仓库里的 go.mod 还原成可移植的相对路径，
# 免得本机绝对路径被提交上去（换机器 / 别人 clone 会直接构建失败）。
tmpmod=$(mktemp -d)
cp "$here/sidecar/go.mod" "$tmpmod/go.mod"
[ -f "$here/sidecar/go.sum" ] && cp "$here/sidecar/go.sum" "$tmpmod/go.sum"

(cd "$here/sidecar" \
	&& go mod edit -modfile="$tmpmod/go.mod" -replace "github.com/beilunyang/openhongguo=$sdk" \
	&& go mod tidy -modfile="$tmpmod/go.mod" \
	&& go build -modfile="$tmpmod/go.mod" -trimpath -ldflags="-s -w" -o "$here/build/openhongguo-sidecar" .) \
	|| { rm -rf "$tmpmod"; exit 1; }

# 顺带把 go.sum 同步回来（有变化才动），go.mod 本身保持相对路径不变。
[ -f "$tmpmod/go.sum" ] && cp "$tmpmod/go.sum" "$here/sidecar/go.sum"
rm -rf "$tmpmod"

mkdir -p "$here/build"
echo "built $here/build/openhongguo-sidecar  ($(du -h "$here/build/openhongguo-sidecar" | cut -f1))"
