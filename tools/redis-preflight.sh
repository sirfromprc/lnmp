#!/bin/sh
# redis.service 的启动前检查。
# Type=simple 下 systemd 在进程 exec 后即判定启动成功，端口被占用时 systemctl start
# 会先返回 0，几秒后才进入 failed。这里在启动前发现占用并直接失败，让返回码和提示
# 在同一时刻给出。只报告占用者，不结束任何进程。
# 用法：redis-preflight [redis.conf 路径]

conf=${1:-/usr/local/redis/etc/redis.conf}
[ -r "${conf}" ] || exit 0

port=$(awk '$1 == "port" { print $2; exit }' "${conf}")
case "${port}" in
    ''|*[!0-9]*) exit 0 ;;
esac

command -v ss >/dev/null 2>&1 || exit 0
listener=$(ss -lntp 2>/dev/null | awk -v pat=":${port}\$" 'NR > 1 && $4 ~ pat')
[ -n "${listener}" ] || exit 0

echo "端口 ${port} 已被其他进程监听，Redis 未启动：" >&2
echo "${listener}" >&2
echo "请自行确认并处理该进程（LNMP 不会结束它），再启动 redis.service。" >&2
exit 1
