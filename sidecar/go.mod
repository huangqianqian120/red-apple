module hongguo-sidecar

go 1.22

require github.com/beilunyang/openhongguo v0.0.0

// SDK 顺序：Scripts/build-sidecar.sh 默认把它克隆到 ../openhongguo。
// 想放别处就传给脚本：./Scripts/build-sidecar.sh /path/to/openhongguo
// 脚本用临时 modfile 构建，不会把这个相对路径改成本机绝对路径。
replace github.com/beilunyang/openhongguo => ../openhongguo
