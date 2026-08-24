#!/bin/sh
# redis.service 的启动前检查：端口占用与配置可用性。
# Type=simple 下 systemd 在进程 exec 后即判定启动成功，端口被占用或配置有错时
# systemctl start 会先返回 0，几秒后才进入 failed。这里在启动前同步检出并直接
# 失败，让返回码和提示在同一时刻给出。只报告占用者，不结束任何进程。
# 用法：redis-preflight [redis.conf 路径]

conf=${1:-/usr/local/redis/etc/redis.conf}
[ -r "${conf}" ] || exit 0

# 端口占用检查。取不到端口号或缺少 ss 时跳过，不阻断启动。
port=$(awk '$1 == "port" { print $2; exit }' "${conf}")
case "${port}" in
    ''|*[!0-9]*) port='' ;;
esac
if [ -n "${port}" ] && command -v ss >/dev/null 2>&1; then
    listener=$(ss -lntp 2>/dev/null | awk -v pat=":${port}\$" 'NR > 1 && $4 ~ pat')
    if [ -n "${listener}" ]; then
        echo "端口 ${port} 已被其他进程监听，Redis 未启动：" >&2
        echo "${listener}" >&2
        echo "请自行确认并处理该进程（LNMP 不会结束它），再启动 redis.service。" >&2
        exit 1
    fi
fi

# 配置错误同样在 systemd 判定启动成功之后才暴露：Type=simple 下 systemd 只等
# exec 成功，Redis 解析配置失败要到进程退出时才体现。这里先用同一份配置试跑一次，
# 只监听临时目录下的 unix socket、不加载也不写入真实数据，把解析和初始化错误
# 同步转成非零返回码。缺少 redis-server 或 mktemp 时跳过，不阻断启动。
# 测试注入点，默认取实际安装路径。
redis_server=${LNMP_REDIS_SERVER:-/usr/local/redis/bin/redis-server}
[ -x "${redis_server}" ] || exit 0
command -v mktemp >/dev/null 2>&1 || exit 0

checkdir=$(mktemp -d /tmp/redis-preflight.XXXXXXXX) || exit 0
chmod 700 "${checkdir}"
check_pid=''
cleanup()
{
    if [ -n "${check_pid}" ]; then
        kill "${check_pid}" 2>/dev/null
        wait "${check_pid}" 2>/dev/null
    fi
    rm -rf "${checkdir}"
    return 0
}
trap 'cleanup' EXIT INT TERM

sock="${checkdir}/check.sock"
"${redis_server}" "${conf}" --daemonize no --port 0 --unixsocket "${sock}" \
    --dir "${checkdir}" --dbfilename check.rdb --appendonly no --save '' \
    --logfile '' --pidfile "${checkdir}/check.pid" >"${checkdir}/out" 2>&1 &
check_pid=$!

# 支持小数的 sleep 用 0.1 秒轮询，不支持时退回 1 秒，两种情况都最多等 10 秒。
unit=0.1
max=100
if ! sleep "${unit}" 2>/dev/null; then
    unit=1
    max=10
fi
# 退出但未回收的子进程仍在 /proc 中，kill -0 对僵尸同样返回成功，
# 因此按 /proc/<pid>/stat 的状态位判断，comm 字段可能含空格，从右括号后截取。
alive()
{
    stat=$(cat "/proc/${check_pid}/stat" 2>/dev/null) || return 1
    state=${stat##*) }
    state=${state%% *}
    [ "${state}" != 'Z' ]
}

i=0
# unixsocket 文件出现即表示 Redis 已完成配置解析和初始化。
while [ "${i}" -lt "${max}" ]; do
    [ -e "${sock}" ] && break
    alive || break
    sleep "${unit}"
    i=$((i + 1))
done

# 仍在初始化的进程不阻断启动；只有 Redis 自行退出才说明配置或初始化有错。
if [ -e "${sock}" ] || alive; then
    exit 0
fi

echo "Redis 配置校验未通过，未启动服务：${conf}" >&2
sed -n '1,20p' "${checkdir}/out" >&2
exit 1
