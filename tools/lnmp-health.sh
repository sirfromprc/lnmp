#!/usr/bin/env bash
#
# LNMP 服务健康检查工具，通过 `lnmp health <子命令>` 使用。
# 安装路径为 /bin/lnmp-health，lnmp、lnmpa 和 lamp 管理命令共用该工具。
#
#   lnmp health check          执行一轮探测，由 lnmp-health.timer 调用
#   lnmp health status         显示各服务探测结果、失败计数与熔断状态
#   lnmp health reset [服务]   清除失败计数与熔断标记，不带参数清除全部
#   lnmp health init           安装定时探测任务
#   lnmp health uninit         移除定时探测任务
#
# ---------------------------------------------------------------------------
# 职责边界
#
# unit 的 Restart=on-failure 处理进程退出，本工具处理进程存活但不响应请求。
# 两者不重叠：本工具只调用 systemctl restart，不直接启动进程，重启次数上限
# 仍由 unit 的 StartLimitIntervalSec 与 StartLimitBurst 约束。
#
# 探测前先确认服务应处于运行状态：unit 为 inactive（人工停止）、failed
# （systemd 已放弃并由 OnFailure 告警）或 activating/deactivating（正在切换）
# 时不探测，避免与人工操作和 systemd 自身的重启抢动作。其中 unit 仍是开机
# 自启却没在运行的，连续多轮后告警一次，但不自动重启。
#
# 数据库不执行重启，只发送告警。mysqld_safe 已负责 mysqld 的崩溃拉起，
# 且数据损坏场景下反复重启会加剧损坏。
#
# 本工具依赖 systemd，没有 systemd 的环境下不工作也不安装定时任务，原因见
# Systemd_Available 的说明。
# ---------------------------------------------------------------------------

set -u

Conf_Dir="/etc/lnmp"
Conf_File="${Conf_Dir}/health.conf"
State_File="${Conf_Dir}/health-state"
Log_File="/var/log/lnmp/health.log"
Systemd_Service="/etc/systemd/system/lnmp-health.service"
Systemd_Timer="/etc/systemd/system/lnmp-health.timer"
# 本工具不安装 cron，该路径仅用于 uninit 时清理手工写入的任务。
Cron_File="/etc/cron.d/lnmp-health"

# 连续失败达到该次数才动作，滤掉重载和瞬时抖动造成的单次失败。
Fail_Threshold=3
# 熔断窗口内本工具最多重启同一服务的次数，超出后只告警不再重启。
Restart_Window_Sec=1800
Restart_Max=2
# 单次探测超时，取值需小于 timer 间隔。
Probe_Timeout=5
# 主配置内置的 Nginx 状态端点端口。使用者改动该 server 的 listen 后由
# Nginx_Status_Port 自动改探实际端口，这里只作为首选值。
Nginx_Status_Port_Default=1008
# Nginx_Status_Probe 的输出。命令替换会开子 shell，函数内的赋值传不回来，
# 因此端口与响应码都用全局变量回传，调用方只看返回码。
Nginx_Status_Port_Found=''
Nginx_Status_Code=''
# 同一服务的告警间隔，防止持续故障刷屏。
Notify_Quiet_Sec=3600
# 全部服务正常时的日志摘要间隔，用于确认检查任务确实在跑。
Summary_Interval_Sec=86400

# 状态文件仅 root 可读。
umask 077

# 测试注入点：默认取实际系统路径。
Nginx_Dir="${LNMP_HEALTH_NGINX_DIR:-/usr/local/nginx}"
Apache_Dir="${LNMP_HEALTH_APACHE_DIR:-/usr/local/apache}"
Php_Dir="${LNMP_HEALTH_PHP_DIR:-/usr/local/php}"
Redis_Dir="${LNMP_HEALTH_REDIS_DIR:-/usr/local/redis}"
My_Cnf="${LNMP_HEALTH_MYCNF:-/etc/my.cnf}"

# ---------------------------------------------------------------------------
# 输出与日志
# ---------------------------------------------------------------------------
Color()   { if [ -t 1 ]; then printf '\033[%sm%s\033[0m\n' "$1" "$2"; else printf '%s\n' "$2"; fi; }
Say()     { printf '%s\n' "$*"; }
Warn()    { Color "0;33" "$*"; }
Err()     { Color "0;31" "$*" >&2; }
Ok()      { Color "0;32" "$*"; }

Log()
{
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
    [ -d "${Log_File%/*}" ] || mkdir -p "${Log_File%/*}" 2>/dev/null
    printf '%s\n' "${line}" >> "${Log_File}" 2>/dev/null
}

Notify()
{
    [ -r /bin/lnmp-tgnotice ] || return 0
    # shellcheck disable=SC1091
    . /bin/lnmp-tgnotice
    command -v tgnotice >/dev/null 2>&1 || return 0
    tgnotice "$1" text >/dev/null 2>&1 || true
}

# Notify_Throttled <服务名> <正文>
# 同一服务在静默期内只发一条，避免持续故障反复推送。
Notify_Throttled()
{
    local svc="$1" body="$2" now last
    now=$(date +%s)
    last=$(Read_State "Notify_${svc}")
    case "${last}" in
        ''|*[!0-9]*) ;;
        *) [ $((now - last)) -lt "${Notify_Quiet_Sec}" ] && return 0 ;;
    esac
    Write_State "Notify_${svc}" "${now}"
    Notify "${body}"
}

# ---------------------------------------------------------------------------
# 状态读写
# ---------------------------------------------------------------------------
Read_State()
{
    local key="$1"
    [ -s "${State_File}" ] || return 0
    awk -F= -v k="${key}" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "${State_File}"
}

Write_State()
{
    local key="$1" value="$2" tmp
    [ -d "${Conf_Dir}" ] || mkdir -p "${Conf_Dir}" 2>/dev/null
    tmp=$(mktemp "${State_File}.XXXXXX" 2>/dev/null) || return 0
    if [ -s "${State_File}" ]; then
        awk -F= -v k="${key}" '$1 != k' "${State_File}" > "${tmp}" 2>/dev/null
    fi
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
    chmod 600 "${tmp}" && mv -f "${tmp}" "${State_File}" || rm -f "${tmp}"
}

Clear_State()
{
    local key="$1" tmp
    [ -s "${State_File}" ] || return 0
    tmp=$(mktemp "${State_File}.XXXXXX" 2>/dev/null) || return 0
    awk -F= -v k="${key}" '$1 != k' "${State_File}" > "${tmp}" 2>/dev/null
    chmod 600 "${tmp}" && mv -f "${tmp}" "${State_File}" || rm -f "${tmp}"
}

# ---------------------------------------------------------------------------
# 服务发现
# ---------------------------------------------------------------------------
Unit_Exists()
{
    local unit="$1"
    [ -s "/etc/systemd/system/${unit}.service" ] || \
    [ -s "/lib/systemd/system/${unit}.service" ] || \
    [ -s "/usr/lib/systemd/system/${unit}.service" ]
}

# 输出本机需要探测的服务列表。多版本 PHP 按已安装的 unit 实例展开。
Managed_Services()
{
    local unit svc
    for svc in nginx httpd php-fpm mysql mariadb redis memcached; do
        Unit_Exists "${svc}" && printf '%s\n' "${svc}"
    done
    for unit in /etc/systemd/system/multi-user.target.wants/php-fpm@*.service; do
        [ -e "${unit}" ] || continue
        svc="${unit##*/}"
        printf '%s\n' "${svc%.service}"
    done
    for unit in /etc/systemd/system/multi-user.target.wants/lnmp-app@*.service; do
        [ -e "${unit}" ] || continue
        svc="${unit##*/}"
        printf '%s\n' "${svc%.service}"
    done
}

# 探测目标的服务类别。多版本 PHP 与主 php-fpm 共用探针。
Svc_Kind()
{
    case "$1" in
    php-fpm@*) printf 'mphp' ;;
    lnmp-app@*) printf 'app' ;;
    mysql|mariadb) printf 'db' ;;
    *) printf '%s' "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# 前置判定
# ---------------------------------------------------------------------------
# 健康检查依赖 systemd：区分「人工停止」和「崩溃」要看 unit 的 enabled 与 active
# 状态，重启也交给 systemd 执行以复用 unit 的启动次数上限。SysV 没有对应语义，
# status 非 0 既可能是崩溃也可能是人工停止，照样重启会把 lnmp stop 之后的服务
# 重新拉起来。因此无 systemd 时本工具不工作，也不安装定时任务。
Systemd_Available()
{
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    return 0
}

# 服务当前应处于运行状态时返回 0。人工停止、systemd 已放弃或正在切换状态
# 时返回非 0，本轮不探测也不动作。
Should_Probe()
{
    local svc="$1" active enabled

    Systemd_Available || return 1

    enabled=$(systemctl is-enabled "${svc}.service" 2>/dev/null)
    case "${enabled}" in
        enabled|enabled-runtime|static|indirect) ;;
        *) return 1 ;;
    esac

    active=$(systemctl is-active "${svc}.service" 2>/dev/null)
    [ "${active}" = "active" ] || return 1
    return 0
}

# unit 仍是开机自启却没在运行：可能是崩溃后 systemd 已放弃，也可能是停止后
# 无人处理。连续多轮仍未运行才告警，避开维护期间的短暂停止；不自动重启，
# 以免与人工操作抢服务。
Report_Not_Running()
{
    local svc="$1" enabled active downs

    enabled=$(systemctl is-enabled "${svc}.service" 2>/dev/null)
    case "${enabled}" in
        enabled|enabled-runtime|static|indirect) ;;
        *) Clear_State "Down_${svc}"; return 0 ;;
    esac

    active=$(systemctl is-active "${svc}.service" 2>/dev/null)
    case "${active}" in
        active) Clear_State "Down_${svc}"; return 0 ;;
        activating|deactivating|reloading) return 0 ;;
    esac

    downs=$(Read_State "Down_${svc}")
    case "${downs}" in
        ''|*[!0-9]*) downs=0 ;;
    esac
    downs=$((downs + 1))
    Write_State "Down_${svc}" "${downs}"
    Log WARN "${svc} 未在运行（unit 状态 ${active:-未知}，第 ${downs} 轮）。"

    # failed 表示 systemd 已放弃重启，不必再等确认轮次。
    if [ "${active}" != "failed" ] && [ "${downs}" -lt "${Fail_Threshold}" ]; then
        return 0
    fi
    Notify_Throttled "${svc}" "LNMP 健康检查：${svc} 未在运行（unit ${active:-未知}），本工具不会自动重启，请人工确认。"
    return 0
}

# 正常运行时日志没有任何输出，无法确认检查是否在跑，因此按间隔写一条摘要。
Log_Periodic_Summary()
{
    local ok_count="$1" fail_count="$2" down_count="$3" summary now last
    now=$(date +%s)
    last=$(Read_State "Summary_Ts")
    case "${last}" in
        ''|*[!0-9]*) last=0 ;;
    esac
    [ $((now - last)) -ge "${Summary_Interval_Sec}" ] || return 0
    Write_State "Summary_Ts" "${now}"
    printf -v summary '正常 %s，探测失败 %s，未运行 %s' \
        "${ok_count}" "${fail_count}" "${down_count}"
    Log INFO "周期摘要：${summary}"
}

# ---------------------------------------------------------------------------
# 探针
#
# 全部为协议层探测，不依赖 LNMP 之外的新增软件包。
# ---------------------------------------------------------------------------
# Run_With_Timeout <秒> <命令> [参数...]
# 输出命令的 stdout 与 stderr，超时返回 124，其余返回命令自身的退出码。
#
# 优先用 timeout 命令；它不存在时退回后台执行加轮询。不能只依赖 timeout：
# 客户端工具的 --connect-timeout 一类选项只覆盖建立连接阶段，服务端接受连接后
# 不响应时探针会一直挂住，拖垮整轮探测。
Run_With_Timeout()
{
    local sec="$1"; shift
    local out pid rc waited=0 had_monitor=''

    if command -v timeout >/dev/null 2>&1; then
        timeout "${sec}" "$@" 2>&1
        return $?
    fi

    out=$(mktemp "${TMPDIR:-/tmp}/.lnmp-health.XXXXXX") || return 1

    # 开 job control 让目标命令成为独立进程组的组长，超时时才能连同它派生的
    # 子进程一起清理，否则只杀顶层 PID 会留下孤儿进程反复累积。
    case "$-" in *m*) had_monitor=y ;; esac
    set -m
    "$@" </dev/null >"${out}" 2>&1 &
    pid=$!
    [ -n "${had_monitor}" ] || set +m

    while [ "${waited}" -lt "${sec}" ]; do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 1
        waited=$((waited + 1))
    done

    if kill -0 "${pid}" 2>/dev/null; then
        Kill_Process_Group "${pid}"
        wait "${pid}" 2>/dev/null
        cat "${out}"
        rm -f "${out}"
        return 124
    fi

    wait "${pid}"
    rc=$?
    cat "${out}"
    rm -f "${out}"
    return ${rc}
}

# Kill_Process_Group <PID>
# 先 TERM 后 KILL。仅在确认该 PID 就是自己进程组的组长时才按进程组发信号：
# 取不到组号或它不是组长时，负号会打到调用方所在的进程组，把健康检查自己杀掉。
Kill_Process_Group()
{
    local pid="$1" pgid=""

    if command -v ps >/dev/null 2>&1; then
        pgid=$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d '[:space:]')
    fi

    if [ "${pgid}" = "${pid}" ]; then
        kill -TERM -"${pid}" 2>/dev/null
        sleep 1
        kill -KILL -"${pid}" 2>/dev/null
    else
        kill -TERM "${pid}" 2>/dev/null
        sleep 1
        kill -KILL "${pid}" 2>/dev/null
    fi
    return 0
}

# 取服务对外提供站点的 TCP 端口，取不到时输出空串。
#
# 按进程名而非 MainPID 匹配：master 与 worker 共享监听套接字，ss 列出的持有者
# 未必是主进程。优先取绑在通配地址上的端口，同时监听多个时优先 80。
#
# 只绑回环的端口仅对 Apache 采纳：LNMPA 中 Apache 正是只监听 127.0.0.1:88，由
# Nginx 反代，不取该端口就会退到 80 去探 Nginx，探不出 Apache 的状态。Nginx 的
# 回环监听则是 1008 状态端口一类的内部入口，用它探测得不出站点是否可用。
Unit_Listen_Port()
{
    local svc="$1" name loopback=0

    command -v ss >/dev/null 2>&1 || return 0
    case "${svc}" in
        nginx) name=nginx ;;
        httpd) name=httpd; loopback=1 ;;
        *)     return 0 ;;
    esac
    ss -lntpH 2>/dev/null | awk -v n="${name}" -v lo="${loopback}" '
        $0 !~ "\"" n "\"" { next }
        {
            port = $4
            sub(/^.*:/, "", port)
            addr = substr($4, 1, length($4) - length(port) - 1)
            if (addr != "0.0.0.0" && addr != "*" && addr != "[::]") {
                if (lo == 1 && loopback_port == "" &&
                    (addr == "127.0.0.1" || addr == "[::1]")) loopback_port = port
                next
            }
            # awk 的 exit 仍会执行 END，因此结果统一在 END 输出
            if (port == "80") { found = port; exit }
            if (fallback == "") fallback = port
        }
        END {
            if (found != "") print found
            else if (fallback != "") print fallback
            else if (loopback_port != "") print loopback_port
        }
    '
}

# Http_Status <端口> <路径>
# 输出响应状态码，连接失败或超时返回 1。
#
# 用 bash 的 /dev/tcp 而不是 curl：curl 不存在时整个 Web 探针会直接跳过，
# nginx 实际未被探测却记为正常；read -t 是内建超时，服务端接受连接后不响应
# 时能可靠中断，不依赖 timeout 命令。
Http_Status()
{
    local port="$1" path="$2" line code

    # 重定向失败时 bash 在 exec 阶段就写 stderr，同一命令上的 2>/dev/null 抑制不掉，
    # 必须包成复合命令，否则每轮探测都往 journal 里灌两行 Connection refused。
    { exec 9<>"/dev/tcp/127.0.0.1/${port}"; } 2>/dev/null || return 1
    printf 'GET %s HTTP/1.0\r\nHost: localhost\r\nUser-Agent: lnmp-health\r\nConnection: close\r\n\r\n' \
        "${path}" >&9 2>/dev/null
    line=""
    read -r -t "${Probe_Timeout}" line <&9 2>/dev/null
    exec 9<&- 2>/dev/null

    line="${line//$'\r'/}"
    code="${line#* }"
    code="${code%% *}"
    case "${code}" in
        [1-5][0-9][0-9]) printf '%s' "${code}"; return 0 ;;
    esac
    return 1
}

# 列出 Nginx 绑在回环地址上的监听端口，供状态端点改过端口时定位。
Nginx_Loopback_Ports()
{
    command -v ss >/dev/null 2>&1 || return 0
    ss -lntpH 2>/dev/null | awk '
        $0 !~ "\"nginx\"" { next }
        {
            port = $4
            sub(/^.*:/, "", port)
            addr = substr($4, 1, length($4) - length(port) - 1)
            if (addr == "127.0.0.1" || addr == "[::1]") print port
        }
    ' | sort -u
}

# 定位 Nginx 状态端点并探测，结果写入 Nginx_Status_Port_Found 与 Nginx_Status_Code。
#
# 先探默认端口，命中就不调 ss——默认配置下探测次数与调用开销和写死端口时相同。
# 只有使用者改过该 server 的 listen 才会去回环监听里逐个试，避免退到站点端口：
# 站点端口的探测请求会写进站点访问日志，且探的是业务根路径而非状态端点。
Nginx_Status_Probe()
{
    local port code

    Nginx_Status_Port_Found=''
    Nginx_Status_Code=''

    code=$(Http_Status "${Nginx_Status_Port_Default}" /nginx_status)
    if [ -n "${code}" ]; then
        Nginx_Status_Port_Found="${Nginx_Status_Port_Default}"
        Nginx_Status_Code="${code}"
        return 0
    fi

    for port in $(Nginx_Loopback_Ports); do
        [ "${port}" = "${Nginx_Status_Port_Default}" ] && continue
        code=$(Http_Status "${port}" /nginx_status) || continue
        Nginx_Status_Port_Found="${port}"
        Nginx_Status_Code="${code}"
        return 0
    done
    return 1
}

# Web 探针。连接失败、超时或 5xx 判为异常；2xx/3xx/4xx 均表示服务在响应。
#
# Nginx 优先探状态端点：该 server 已关闭访问日志，每分钟一次的探测不写站点日志。
# 端点定位不到（server 被删除等）时才回退站点端口。
Probe_Http()
{
    local svc="$1" port code fell_back='n'

    if [ "${svc}" = "nginx" ]; then
        if Nginx_Status_Probe; then
            case "${Nginx_Status_Code}" in
                5??) printf -v Probe_Detail '127.0.0.1:%s/nginx_status 返回 %s' \
                         "${Nginx_Status_Port_Found}" "${Nginx_Status_Code}"
                     return 1 ;;
            esac
            return 0
        fi
        fell_back='y'
    fi

    port=$(Unit_Listen_Port "${svc}")
    case "${port}" in
        ''|*[!0-9]*) port=80 ;;
    esac

    code=$(Http_Status "${port}" /)
    if [ -z "${code}" ]; then
        # 两个端点都不通更能说明 worker 卡死或进程已停，只报站点端口会被当成端口配置问题。
        if [ "${fell_back}" = 'y' ]; then
            printf -v Probe_Detail 'Nginx 状态端点未定位到（默认 %s）且 127.0.0.1:%s 连接失败或超时' \
                "${Nginx_Status_Port_Default}" "${port}"
        else
            printf -v Probe_Detail '连接 127.0.0.1:%s 失败或超时' "${port}"
        fi
        return 1
    fi
    case "${code}" in
        5??) printf -v Probe_Detail '127.0.0.1:%s 返回 %s' "${port}" "${code}"; return 1 ;;
    esac
    return 0
}

# PHP-FPM 探针。协议层无法直接发起 FastCGI 请求，改为核对 socket 存在、
# master 进程存活且已派生 worker；worker 全部卡死的场景由 Web 探针的
# 502/504 间接反映。
Probe_Fpm()
{
    local svc="$1" ver='' sock pid workers

    case "${svc}" in
        php-fpm@*) ver="${svc#php-fpm@}" ;;
    esac
    if [ -n "${ver}" ]; then
        sock="/run/php-fpm/php-cgi${ver}.sock"
    else
        sock="/run/php-fpm/php-cgi.sock"
    fi

    if [ ! -S "${sock}" ]; then
        printf -v Probe_Detail '监听套接字 %s 不存在' "${sock}"
        return 1
    fi

    pid=$(systemctl show "${svc}.service" -p MainPID --value 2>/dev/null)
    case "${pid}" in
        ''|0|*[!0-9]*) printf -v Probe_Detail 'master 进程不存在'; return 1 ;;
    esac
    [ -d "/proc/${pid}" ] || {
        printf -v Probe_Detail 'master 进程 %s 已消失' "${pid}"
        return 1
    }

    workers=$(pgrep -P "${pid}" 2>/dev/null | wc -l)
    if [ "${workers}" -eq 0 ]; then
        printf -v Probe_Detail 'master 存活但 worker 数为 0'
        return 1
    fi
    return 0
}

# 从 redis.conf 读取监听端口，缺失或非数字时回退到 Redis 默认的 6379。
Redis_Conf_Port()
{
    local port

    port=$(awk '$1 == "port" { print $2; exit }' "${Redis_Dir}/etc/redis.conf" 2>/dev/null)
    case "${port}" in
        ''|*[!0-9]*) port=6379 ;;
    esac
    printf '%s' "${port}"
}

# Redis 探针。用 bash 的 /dev/tcp 直接发 inline 命令，不调 redis-cli。
#
# 不用 redis-cli 的原因是超时无法保证：其 -t 只控制建立连接的超时，服务器接受
# 连接后不响应时不会中断（实测卡住 20 秒仍未返回），而这正是本工具要发现的场景；
# 外挂 timeout 命令又要求该命令存在。read -t 是 bash 内建，不依赖任何外部命令。
#
# 服务器回 +PONG 表示正常；配了 requirepass 回 -NOAUTH，正在载入数据集回
# -LOADING，都说明进程在响应请求，判为存活。
Probe_Redis()
{
    local port line

    port=$(Redis_Conf_Port)
    # port 0 表示只监听 unixsocket，没有 TCP 端口可探测，不判为故障。
    [ "${port}" = "0" ] && return 0

    { exec 9<>"/dev/tcp/127.0.0.1/${port}"; } 2>/dev/null || {
        printf -v Probe_Detail '连接 127.0.0.1:%s 失败' "${port}"
        return 1
    }
    printf 'PING\r\n' >&9 2>/dev/null
    line=""
    read -r -t "${Probe_Timeout}" line <&9 2>/dev/null
    exec 9<&- 2>/dev/null

    # RESP 的状态回复以 + 开头，错误回复以 - 开头，两者都代表服务器在响应。
    case "${line}" in
        +*|-*) return 0 ;;
    esac
    if [ -z "${line}" ]; then
        printf -v Probe_Detail '127.0.0.1:%s 未响应 PING（%s 秒超时）' \
            "${port}" "${Probe_Timeout}"
    else
        printf -v Probe_Detail '127.0.0.1:%s PING 返回异常内容：%s' "${port}" "${line}"
    fi
    return 1
}

# Memcached 探针。用 bash 的 /dev/tcp 发送 version，不引入 nc 依赖。
Probe_Memcached()
{
    local ip port line

    ip=$(awk -F= '$1 == "IP" { gsub(/"/, "", $2); print $2; exit }' /etc/init.d/memcached 2>/dev/null)
    port=$(awk -F= '$1 == "PORT" { gsub(/"/, "", $2); print $2; exit }' /etc/init.d/memcached 2>/dev/null)
    [ -n "${ip}" ] || ip=127.0.0.1
    case "${port}" in
        ''|*[!0-9]*) port=11211 ;;
    esac

    { exec 9<>"/dev/tcp/${ip}/${port}"; } 2>/dev/null || {
        printf -v Probe_Detail '连接 %s:%s 失败' "${ip}" "${port}"
        return 1
    }
    printf 'version\r\n' >&9 2>/dev/null
    read -r -t "${Probe_Timeout}" line <&9 2>/dev/null
    exec 9<&- 2>/dev/null
    case "${line}" in
        VERSION*) return 0 ;;
    esac
    printf -v Probe_Detail '%s:%s 未返回 VERSION' "${ip}" "${port}"
    return 1
}

# 取数据库 socket 路径，优先读 my.cnf，缺省用安装时写入的正式路径。
Db_Socket_Path()
{
    local sock
    sock=$(awk -F= '
        /^[[:space:]]*\[/ { in_srv = ($0 ~ /\[(mysqld|server)\]/) }
        in_srv && $1 ~ /^[[:space:]]*socket[[:space:]]*$/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit
        }
    ' "${My_Cnf}" 2>/dev/null)
    [ -n "${sock}" ] || sock=/run/mysqld/mysqld.sock
    printf '%s' "${sock}"
}

# 数据库探针。mysqladmin ping 在认证失败时同样返回 mysqld is alive，
# 说明服务在响应，因此不需要口令。
Probe_Db()
{
    local svc="$1" admin sock out rc

    sock=$(Db_Socket_Path)
    case "${svc}" in
    mariadb)
        for admin in /usr/local/mariadb/bin/mariadb-admin /usr/local/mariadb/bin/mysqladmin; do
            [ -x "${admin}" ] && break
        done
        ;;
    *)
        admin=/usr/local/mysql/bin/mysqladmin
        ;;
    esac

    if [ ! -x "${admin}" ]; then
        # 没有客户端工具时退回套接字存在性判断，避免误判为故障。
        [ -S "${sock}" ] && return 0
        printf -v Probe_Detail '套接字 %s 不存在，且找不到 mysqladmin' "${sock}"
        return 1
    fi

    # init 脚本被发行版包覆盖后 start 会返回 0 却起不来，这里给出确切原因，
    # 避免把启动脚本被替换误判成数据问题。数据目录不受影响。
    if [ -f "/etc/init.d/${svc}" ] &&
       ! grep -q "/usr/local/${svc}" "/etc/init.d/${svc}"; then
        printf -v Probe_Detail \
            '/etc/init.d/%s 已不指向 /usr/local/%s，疑似被系统包覆盖；数据目录未受影响' \
            "${svc}" "${svc}"
        [ -S "${sock}" ] || return 1
    fi

    # --connect-timeout 只覆盖建立连接阶段，mysqld 接受连接后不响应时不会中断，
    # 因此整条命令再包一层墙钟超时。
    out=$(Run_With_Timeout "${Probe_Timeout}" \
            "${admin}" --no-defaults --protocol=socket --socket="${sock}" \
            --connect-timeout="${Probe_Timeout}" -u root ping)
    rc=$?
    case "${out}" in
        *"is alive"*|*"Access denied"*) return 0 ;;
    esac
    if [ "${rc}" -eq 124 ]; then
        printf -v Probe_Detail 'mysqladmin ping 超时（%s 秒），进程可能已无响应' \
            "${Probe_Timeout}"
    else
        if [ -n "${out}" ]; then
            printf -v Probe_Detail 'mysqladmin ping 失败：%s' "${out}"
        else
            printf -v Probe_Detail 'mysqladmin ping 失败：无响应'
        fi
    fi
    return 1
}

# Probe <服务名>
# 探测成功返回 0，失败返回 1 并在 Probe_Detail 中给出原因。
# 探针本身不可用（缺少客户端工具等）时返回 0，不制造假故障。
Probe()
{
    local svc="$1"

    Probe_Detail=""
    case "$(Svc_Kind "${svc}")" in
    nginx|httpd) Probe_Http "${svc}" ;;
    php-fpm|mphp) Probe_Fpm "${svc}" ;;
    redis)       Probe_Redis ;;
    memcached)   Probe_Memcached ;;
    db)          Probe_Db "${svc}" ;;
    *)           return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# 熔断与动作
# ---------------------------------------------------------------------------
# 保留熔断窗口内的重启时间戳，返回窗口内的重启次数。
Recent_Restart_Count()
{
    local svc="$1" now ts kept='' count=0
    now=$(date +%s)
    for ts in $(Read_State "Rst_${svc}"); do
        case "${ts}" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ $((now - ts)) -lt "${Restart_Window_Sec}" ]; then
            kept="${kept} ${ts}"
            count=$((count + 1))
        fi
    done
    Write_State "Rst_${svc}" "${kept# }"
    printf '%s' "${count}"
}

Record_Restart()
{
    local svc="$1" now list
    now=$(date +%s)
    list=$(Read_State "Rst_${svc}")
    Write_State "Rst_${svc}" "${list:+${list} }${now}"
}

# 达到失败阈值后的处理。数据库只告警，其余服务在熔断窗口内重启一次。
Handle_Failure()
{
    local svc="$1" detail="$2" count rc

    if [ "$(Svc_Kind "${svc}")" = "db" ]; then
        Log WARN "${svc} 连续探测失败：${detail}"
        Notify_Throttled "${svc}" "LNMP 健康检查：${svc} 连续 ${Fail_Threshold} 次无响应
${detail}
数据库不执行自动重启，请人工确认后处理。"
        return 0
    fi

    count=$(Recent_Restart_Count "${svc}")
    if [ "${count}" -ge "${Restart_Max}" ]; then
        Write_State "Paused_${svc}" "$(date +%s)"
        Log ERROR "${svc} 熔断：${Restart_Window_Sec} 秒内已重启 ${count} 次，停止重启。"
        Notify_Throttled "${svc}" "LNMP 健康检查：${svc} 已熔断
${Restart_Window_Sec} 秒内已由健康检查重启 ${count} 次仍未恢复，停止继续重启。
最近一次探测：${detail}
排查：systemctl status ${svc}.service；恢复后执行 lnmp health reset ${svc}。"
        return 1
    fi

    Log WARN "${svc} 连续探测失败，执行重启：${detail}"
    systemctl restart "${svc}.service" >/dev/null 2>&1
    rc=$?
    Record_Restart "${svc}"
    Write_State "Fail_${svc}" 0
    if [ ${rc} -eq 0 ]; then
        Notify_Throttled "${svc}" "LNMP 健康检查：${svc} 无响应，已重启
${detail}"
    else
        Notify_Throttled "${svc}" "LNMP 健康检查：${svc} 无响应，重启失败（退出码 ${rc}）
${detail}"
    fi
    return ${rc}
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------
# 探测结果记入日志与状态文件，始终返回 0：
# 探测到故障不应让 timer 触发的 oneshot unit 进入 failed 状态。
Cmd_Check()
{
    local svc fails paused active rc tty='' ok_count=0 fail_count=0 down_count=0

    if ! Systemd_Available; then
        Log WARN "本机没有运行中的 systemd，健康检查不执行。"
        Err "本机没有运行中的 systemd，健康检查依赖 systemd 才能工作，未执行探测。"
        return 1
    fi

    # 终端下逐服务反馈结果，无需再执行 status；timer 调用时保持静默，
    # 否则每分钟往 journal 写一份完整探测结果。
    [ -t 1 ] && tty='y'

    for svc in $(Managed_Services); do
        if ! Should_Probe "${svc}"; then
            Report_Not_Running "${svc}"
            active=$(systemctl is-active "${svc}.service" 2>/dev/null)
            if [ -n "$(Read_State "Down_${svc}")" ]; then
                down_count=$((down_count + 1))
                [ -n "${tty}" ] && Warn "${svc}：unit 状态 ${active:-未知}，未运行，不自动重启"
            else
                [ -n "${tty}" ] && Say "${svc}：unit 状态 ${active:-未知}，本轮不探测"
            fi
            continue
        fi

        if Probe "${svc}"; then
            paused=$(Read_State "Paused_${svc}")
            if [ -n "${paused}" ]; then
                Clear_State "Paused_${svc}"
                Log INFO "${svc} 探测恢复正常，解除熔断。"
                Notify "LNMP 健康检查：${svc} 已恢复正常，解除熔断。"
            fi
            Clear_State "Down_${svc}"
            Write_State "Fail_${svc}" 0
            ok_count=$((ok_count + 1))
            if [ -n "${tty}" ]; then
                if [ -n "${paused}" ]; then
                    Ok "${svc}：探测正常，已解除熔断"
                else
                    Ok "${svc}：探测正常"
                fi
            fi
            continue
        fi
        fail_count=$((fail_count + 1))

        fails=$(Read_State "Fail_${svc}")
        case "${fails}" in
            ''|*[!0-9]*) fails=0 ;;
        esac
        fails=$((fails + 1))
        Write_State "Fail_${svc}" "${fails}"
        Log WARN "${svc} 探测失败（第 ${fails} 次）：${Probe_Detail}"

        if [ "${fails}" -lt "${Fail_Threshold}" ]; then
            [ -n "${tty}" ] && Warn "${svc}：探测失败（第 ${fails} 次）：${Probe_Detail}"
            continue
        fi

        Handle_Failure "${svc}" "${Probe_Detail}"
        rc=$?
        [ -n "${tty}" ] || continue
        if [ "$(Svc_Kind "${svc}")" = "db" ]; then
            Warn "${svc}：连续失败 ${fails} 次，已告警；数据库不执行自动重启"
        elif [ ${rc} -eq 0 ]; then
            Warn "${svc}：连续失败 ${fails} 次，已重启，详见 ${Log_File}"
        else
            Err "${svc}：连续失败 ${fails} 次，未重启（已熔断或重启失败），详见 ${Log_File}"
        fi
    done

    Log_Periodic_Summary "${ok_count}" "${fail_count}" "${down_count}"
    if [ -n "${tty}" ]; then
        Say ""
        Say "检查完成：正常 ${ok_count}，探测失败 ${fail_count}，未运行 ${down_count}"
    fi
    return 0
}

Cmd_Status()
{
    local svc fails paused active detail downs

    if ! Systemd_Available; then
        Err "本机没有运行中的 systemd，健康检查不可用。"
        return 1
    fi

    for svc in $(Managed_Services); do
        active=$(systemctl is-active "${svc}.service" 2>/dev/null)
        fails=$(Read_State "Fail_${svc}")
        paused=$(Read_State "Paused_${svc}")
        [ -n "${fails}" ] || fails=0

        if ! Should_Probe "${svc}"; then
            downs=$(Read_State "Down_${svc}")
            if [ -n "${downs}" ]; then
                Warn "${svc}：unit 状态 ${active:-未知}，已连续 ${downs} 轮未运行，不自动重启"
            else
                Say "${svc}：unit 状态 ${active:-未知}，本轮不探测"
            fi
            continue
        fi

        if Probe "${svc}"; then
            printf -v detail '探测正常'
        else
            printf -v detail '探测失败：%s' "${Probe_Detail}"
        fi
        if [ -n "${paused}" ]; then
            Warn "${svc}：${detail}，连续失败 ${fails} 次，已熔断"
        elif [ "${fails}" -gt 0 ]; then
            Warn "${svc}：${detail}，连续失败 ${fails} 次"
        else
            Ok "${svc}：${detail}"
        fi
    done

    [ -s "${State_File}" ] || return 0
    Say ""
    Say "状态文件 ${State_File}："
    sed 's/^/  /' "${State_File}"
}

Cmd_Reset()
{
    local want="${1:-}" svc

    for svc in $(Managed_Services); do
        [ -z "${want}" ] || [ "${want}" = "${svc}" ] || continue
        Clear_State "Fail_${svc}"
        Clear_State "Paused_${svc}"
        Clear_State "Rst_${svc}"
        Clear_State "Notify_${svc}"
        Clear_State "Down_${svc}"
        Ok "已清除 ${svc} 的失败计数与熔断标记。"
    done
    return 0
}

Write_Systemd_Unit()
{
    cat > "${Systemd_Service}" <<'EOF' || { Err "写入 ${Systemd_Service} 失败。"; return 1; }
[Unit]
Description=LNMP service health check
# 本单元不设 OnFailure，避免探测自身失败触发权限诊断。

[Service]
Type=oneshot
ExecStart=/bin/lnmp-health check
Nice=10
EOF
    cat > "${Systemd_Timer}" <<'EOF' || { Err "写入 ${Systemd_Timer} 失败。"; return 1; }
[Unit]
Description=LNMP service health check timer

[Timer]
OnBootSec=3min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
    chmod 644 "${Systemd_Service}" "${Systemd_Timer}" \
        || { Err "设置 unit 文件权限失败。"; return 1; }
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now lnmp-health.timer >/dev/null 2>&1 \
        || { Err "启用 lnmp-health.timer 失败，请手工检查。"; return 1; }
    Ok "已启用 lnmp-health.timer：每分钟探测一次。"
    return 0
}

# 生成默认配置文件，供用户就地修改阈值。文件已存在时不覆盖，
# 生成失败不影响定时任务安装，仅回落到内置默认值。
Write_Default_Conf()
{
    local tmp rc

    [ -e "${Conf_File}" ] && return 0

    tmp=$(mktemp "${Conf_File}.XXXXXX" 2>/dev/null) || {
        Warn "生成 ${Conf_File} 失败，继续使用内置默认阈值。"
        return 0
    }
    cat > "${tmp}" <<EOF
# lnmp health 阈值配置。改完立即生效，不需要重启 lnmp-health.timer。
# 每项都必须是正整数，填写非法值时该项回退到内置默认值并告警。

# 连续探测失败达到该次数才重启或告警
Fail_Threshold=${Fail_Threshold}
# 熔断窗口秒数，以及窗口内最多重启同一服务的次数
Restart_Window_Sec=${Restart_Window_Sec}
Restart_Max=${Restart_Max}
# 单次探测超时秒数，须小于 30 秒
Probe_Timeout=${Probe_Timeout}
# 同一服务的告警间隔秒数
Notify_Quiet_Sec=${Notify_Quiet_Sec}
# 全部正常时写入日志摘要的间隔秒数
Summary_Interval_Sec=${Summary_Interval_Sec}
EOF
    rc=$?
    if [ ${rc} -ne 0 ] || ! chmod 600 "${tmp}" || ! mv -f "${tmp}" "${Conf_File}"; then
        rm -f "${tmp}"
        Warn "生成 ${Conf_File} 失败，继续使用内置默认阈值。"
        return 0
    fi
    Ok "已生成默认配置 ${Conf_File}，可直接修改其中的阈值。"
    return 0
}

Cmd_Init()
{
    [ "$(id -u)" = "0" ] || { Err "init 需要 root 权限。"; return 1; }

    # 不提供 cron 回退：cron 只解决「定时触发」，而本工具的前置判定和重启动作
    # 都依赖 systemd，装上定时任务也不会探测任何服务。
    if ! Systemd_Available; then
        Err "本机没有运行中的 systemd，健康检查不可用，未安装定时任务。"
        Err "unit 的 Restart= 在该环境同样不生效，服务异常需要自行监控。"
        return 1
    fi

    mkdir -p "${Conf_Dir}" && chmod 700 "${Conf_Dir}" || { Err "无法创建 ${Conf_Dir}"; return 1; }
    Write_Default_Conf
    Write_Systemd_Unit || return 1
    Say "探测服务：$(Managed_Services | tr '\n' ' ')"
    return 0
}

Cmd_Uninit()
{
    [ "$(id -u)" = "0" ] || { Err "uninit 需要 root 权限。"; return 1; }

    if [ -f "${Systemd_Timer}" ]; then
        systemctl disable --now lnmp-health.timer >/dev/null 2>&1
        rm -f "${Systemd_Timer}" "${Systemd_Service}"
        systemctl daemon-reload >/dev/null 2>&1
        Ok "已移除 lnmp-health.timer。"
    fi
    if [ -f "${Cron_File}" ]; then
        rm -f "${Cron_File}"
        Ok "已移除 ${Cron_File}。"
    fi
    return 0
}

Usage()
{
    Say "用法：lnmp health <check|status|reset [服务]|init|uninit>"
}

# Sanitize_Conf <"名=默认值" 列表>
# 配置文件交给用户修改，写成空值、负数或非数字会让后续算术展开和数值比较出错，
# 因此逐项校验，非法项回退到内置默认值并指出是哪一项。
Sanitize_Conf()
{
    local pair name def cur timeout_def=''

    for pair in $1; do
        name="${pair%%=*}"
        def="${pair#*=}"
        [ "${name}" = "Probe_Timeout" ] && timeout_def="${def}"
        cur="${!name}"
        case "${cur}" in
            ''|0|*[!0-9]*)
                Warn "${Conf_File} 中 ${name} 的值无效，回退为 ${def}。"
                printf -v "${name}" '%s' "${def}"
                ;;
        esac
    done

    # Web 探针最多探两次（状态端点与回退的站点端口），两次之和须留在 timer 间隔内，
    # 否则上一轮探测会压到下一轮。
    if [ -n "${timeout_def}" ] && [ "${Probe_Timeout}" -ge 30 ]; then
        Warn "${Conf_File} 中 Probe_Timeout 不得达到 30 秒，回退为 ${timeout_def}。"
        Probe_Timeout="${timeout_def}"
    fi
    return 0
}

Main()
{
    local cmd="${1:-help}" defaults
    shift 2>/dev/null || true

    # 读配置前快照内置默认值，供非法项回退。
    defaults="Fail_Threshold=${Fail_Threshold} Restart_Window_Sec=${Restart_Window_Sec}"
    defaults="${defaults} Restart_Max=${Restart_Max} Probe_Timeout=${Probe_Timeout}"
    defaults="${defaults} Notify_Quiet_Sec=${Notify_Quiet_Sec}"
    defaults="${defaults} Summary_Interval_Sec=${Summary_Interval_Sec}"

    # 配置文件可覆盖阈值，缺失时用内置默认值。
    if [ -r "${Conf_File}" ]; then
        # shellcheck disable=SC1090
        . "${Conf_File}" || Warn "读取 ${Conf_File} 失败，使用默认阈值。"
        Sanitize_Conf "${defaults}"
    fi

    case "${cmd}" in
        check)    Cmd_Check "$@" ;;
        status)   Cmd_Status "$@" ;;
        reset)    Cmd_Reset "$@" ;;
        init)     Cmd_Init "$@" ;;
        uninit)   Cmd_Uninit "$@" ;;
        help|-h|--help) Usage ;;
        *)        Usage; return 1 ;;
    esac
}

Probe_Detail=""

# 被 source 时只提供函数，供定向测试调用。
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    Main "$@"
fi
