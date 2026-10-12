# shellcheck shell=bash
# 服务运行部分：服务单元存在与运行判定、进程判定、单元写入与 systemd 重载。
# 安装器经 include/main.sh 加载；管理命令与 tools/lnmp-* 部署时由 include/rt/cli_assemble.sh 并入产物。
# 本文件只含函数定义，不含顶层语句，不引用组件变量。

# Svc_Systemd：systemd 正在运行且有 systemctl 时返回 0。
Svc_Systemd()
{
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

# Svc_Unit_Exists <服务名>：存在对应 unit 文件时返回 0。
# 模板实例（如 php-fpm@8.3）没有独立 unit 文件，改判其模板是否存在。
Svc_Unit_Exists()
{
    local service=$1 dir template

    for dir in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
        [ -s "${dir}/${service}.service" ] && return 0
    done
    case "${service}" in
    *@*)
        template="${service%@*}@"
        for dir in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
            [ -s "${dir}/${template}.service" ] && return 0
        done
        ;;
    esac
    return 1
}

# Svc_Use_Systemd <服务名>：该服务应经 systemd 管理时返回 0。
Svc_Use_Systemd()
{
    Svc_Systemd && Svc_Unit_Exists "$1"
}

# Svc_Exists <服务名>：有 unit 或 /etc/init.d 脚本时返回 0。
Svc_Exists()
{
    Svc_Unit_Exists "$1" || [ -x "/etc/init.d/$1" ]
}

# Svc_Running <服务名>：经 systemd 或 init 脚本 status 判定服务在运行。
Svc_Running()
{
    if Svc_Use_Systemd "$1"; then
        systemctl is-active --quiet "$1.service"
    else
        [ -x "/etc/init.d/$1" ] && "/etc/init.d/$1" status >/dev/null 2>&1
    fi
}

# Svc_Process_Names <服务名>：服务对应的进程名，服务名与进程名不一致时在这里映射。
Svc_Process_Names()
{
    case "$1" in
    mariadb) echo "mariadbd mysqld" ;;
    mysql)   echo "mysqld" ;;
    *)       echo "$1" ;;
    esac
}

# Svc_Process_Running <服务名>：服务有进程在运行时返回 0。缺少 pgrep 时按未运行处理。
Svc_Process_Running()
{
    local name

    command -v pgrep >/dev/null 2>&1 || return 1
    for name in $(Svc_Process_Names "$1"); do
        pgrep -x "${name}" >/dev/null 2>&1 && return 0
    done
    return 1
}

# Svc_Reload_Units：systemd 运行时重新加载 unit 文件；未运行 systemd 时返回 0。
Svc_Reload_Units()
{
    Svc_Systemd || return 0
    systemctl daemon-reload >/dev/null 2>&1
}

# Svc_Install_Unit <源 unit> <目标路径>：写入 unit 并重新加载。
# 发行版包常把 /etc/systemd/system/<名>.service 建成指向 /usr/lib/systemd/system/ 的符号链接，
# 直接 cp 会跟随链接改写发行版自带的 unit，因此先摘掉符号链接再写入。
Svc_Install_Unit()
{
    local src="$1" dst="$2"

    if [ ! -s "${src}" ]; then
        echo "找不到服务单元模板：${src}" >&2
        return 1
    fi
    if [ -L "${dst}" ]; then
        echo "${dst} 是指向 $(readlink -f "${dst}" 2>/dev/null) 的符号链接，先摘除再写入本项目的单元。"
        rm -f "${dst}" || return 1
    fi
    if ! \cp "${src}" "${dst}" || ! chmod 644 "${dst}"; then
        echo "写入服务单元失败：${dst}" >&2
        return 1
    fi
    Svc_Reload_Units
    return 0
}

# Svc_Install_Timer <service 路径> <timer 路径> <service 内容> <timer 内容>：
# 写入定时任务的两个 unit，重新加载并启用 timer。返回 1 写入失败，2 启用失败。
Svc_Install_Timer()
{
    local service=$1 timer=$2

    printf '%s\n' "$3" > "${service}" && printf '%s\n' "$4" > "${timer}" \
        && chmod 644 "${service}" "${timer}" || return 1
    Svc_Reload_Units
    systemctl enable --now "${timer##*/}" >/dev/null 2>&1 || return 2
    return 0
}

# Web_Probe <php|static|get> <Host> <端口> <网站目录> [期望 PHP 版本] [URL 前缀]：经本机 Web 入口请求站点。
# php、static 在网站目录写入随机名称的临时文件，内容为随机标识（php 另输出 PHP_VERSION），
# 请求结束、失败或中断时删除，请求路径为 URL 前缀加文件名；get 只请求 /。跳转到 HTTPS 时仍连本机，不依赖 DNS，不校验证书。
# 期望版本为分支（8.4）或完整版本。结果写入 Web_Probe_Status（HTTP 状态码）与 Web_Probe_Got（PHP 版本）。
# 返回：0 通过；2 连接失败；3 超时；4 HTTP 5xx；5 未执行 PHP 或未到达本站点；6 PHP 版本不符；
#       7 无法写入临时文件；8 缺少 curl。
Web_Probe()
{
    local kind=$1 host=$2 port=$3 root=$4 want=${5:-} prefix=${6:-} out rc token first

    Web_Probe_Status=''
    Web_Probe_Got=''
    command -v curl >/dev/null 2>&1 || return 8
    token=$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [ -n "${token}" ] || return 7
    out=$(
        f=''
        trap '[ -z "${f}" ] || rm -f -- "${f}"' EXIT
        trap 'exit 130' INT TERM HUP
        path=/
        if [ "${kind}" != get ]; then
            [ -d "${root}" ] || exit 107
            if [ "${kind}" = php ]; then
                f=$(mktemp --suffix=.php "${root}/lnmp-probe-XXXXXXXXXX") || exit 107
                printf '<?php echo "%s:", PHP_VERSION, "\\n";\n' "${token}" > "${f}" || exit 107
            else
                f=$(mktemp --suffix=.txt "${root}/lnmp-probe-XXXXXXXXXX") || exit 107
                printf '%s:static\n' "${token}" > "${f}" || exit 107
            fi
            chmod 644 "${f}" || exit 107
            path="${prefix}/${f##*/}"
        fi
        curl -s -k -L --max-redirs 3 --connect-timeout 5 --max-time 15 \
            --connect-to "::127.0.0.1:" -o - -w '\n%{http_code}' "http://${host}:${port}${path}"
    )
    rc=$?
    [ "${rc}" -eq 107 ] && return 7
    [ "${rc}" -eq 130 ] && return 130
    Web_Probe_Status=${out##*$'\n'}
    case "${rc}" in
    0) ;;
    28) return 3 ;;
    *) return 2 ;;
    esac
    case "${Web_Probe_Status}" in
    5[0-9][0-9]) return 4 ;;
    esac
    [ "${kind}" = get ] && return 0
    first=${out%%$'\n'*}
    case "${first}" in
    "${token}:"*) ;;
    *) return 5 ;;
    esac
    [ "${kind}" = php ] || return 0
    Web_Probe_Got=${first#"${token}:"}
    [ -z "${want}" ] && return 0
    case "${Web_Probe_Got}" in
    "${want}"|"${want}".*) return 0 ;;
    esac
    return 6
}

# Web_Probe_Report <返回码> <php|static|get> <Host> [期望 PHP 版本]：输出 Web_Probe 结论与处理方向。
Web_Probe_Report()
{
    local rc=$1 kind=$2 host=$3 want=${4:-}

    case "${rc}" in
    0)
        case "${kind}" in
        php) echo "请求验收通过：${host} 的 PHP 请求由 PHP ${Web_Probe_Got} 执行。" ;;
        static) echo "请求验收通过：${host} 的静态文件可经 Web 入口访问。" ;;
        *) echo "请求验收通过：${host} 的反向代理上游已响应（HTTP ${Web_Probe_Status}）。" ;;
        esac
        ;;
    2) echo "请求验收未通过：无法连接本机 Web 入口，请执行 lnmp status 检查 Web 服务。" ;;
    3) echo "请求验收未通过：请求 ${host} 超过 15 秒未完成，请检查 PHP-FPM 或反代上游是否阻塞。" ;;
    4)
        if [ "${kind}" = get ]; then
            case "${Web_Probe_Status}" in
            504) echo "请求验收未通过：反代上游响应超时（HTTP 504），请检查上游服务。" ;;
            502|503) echo "请求验收未通过：反代上游未启动或拒绝连接（HTTP ${Web_Probe_Status}），请先启动上游服务。" ;;
            *) echo "请求验收未通过：反代返回 HTTP ${Web_Probe_Status}，请检查上游服务日志。" ;;
            esac
        else
            echo "请求验收未通过：${host} 返回 HTTP ${Web_Probe_Status}，PHP-FPM 或 Apache 未能处理请求，请执行 lnmp status 检查。"
        fi
        ;;
    5)
        if [ "${kind}" = php ]; then
            echo "请求验收未通过：${host} 返回 HTTP ${Web_Probe_Status}，PHP 未执行或请求未到达本站点目录，请检查站点 PHP 配置与域名是否被其它站点占用。"
        else
            echo "请求验收未通过：${host} 返回 HTTP ${Web_Probe_Status}，请求未到达本站点目录，请检查域名是否被其它站点占用。"
        fi
        ;;
    6) echo "请求验收未通过：${host} 实际由 PHP ${Web_Probe_Got} 执行，期望 PHP ${want}，请检查站点选择的 PHP 版本。" ;;
    7) echo "无法在网站目录写入临时探测文件，跳过请求验收。" ;;
    8) echo "未找到 curl，跳过请求验收。" ;;
    130) echo "请求验收被中断，临时探测文件已删除。" ;;
    esac
}
