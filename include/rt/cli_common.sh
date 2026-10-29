# shellcheck shell=bash
# 管理命令公共层：lnmp、lnmpa、lamp 共用的函数定义。
# 部署时由 include/rt/cli_assemble.sh 并入各栈入口，本文件不含顶层语句。
Text_Display_Width()
{
    local text="$1" bytes ascii_bytes wide_chars
    bytes=$(printf '%s' "${text}" | LC_ALL=C wc -c)
    ascii_bytes=$(printf '%s' "${text}" | LC_ALL=C tr -cd '\000-\177' | wc -c)
    wide_chars=$(( (bytes - ascii_bytes) / 3 ))
    printf '%d' $((ascii_bytes + wide_chars * 2))
}

Print_Banner()
{
    local width=72 border text text_width padding left right
    for text in "$@"; do
        text_width=$(Text_Display_Width "${text}")
        [ "${text_width}" -gt "${width}" ] && width=${text_width}
    done
    border=$(printf '%*s' "${width}" '' | tr ' ' '-')
    printf '+%s+\n' "${border}"
    for text in "$@"; do
        text_width=$(Text_Display_Width "${text}")
        padding=$((width - text_width))
        left=$((padding / 2))
        right=$((padding - left))
        printf '|%*s%s%*s|\n' "${left}" '' "${text}" "${right}" ''
    done
    printf '+%s+\n' "${border}"
}

# systemd 的启动限流按窗口内的启动次数计数，成功启动同样累计，命中后连正确
# 配置也拒绝启动。计数在 unit 仍是 active、Result 仍是 success 时就已累加，
# 按 Result 判断会漏掉第一次被拒，因此人工 start 与 restart 前无条件重置。
# reset-failed 只清 failed 状态与计数，不影响运行中的进程；Restart= 触发的
# 自动重启循环不经过这里，仍受限流约束。
Reset_Start_Limit()
{
    local service="$1" failed=0

    systemctl is-failed --quiet "${service}.service" 2>/dev/null && failed=1
    systemctl reset-failed "${service}.service" >/dev/null 2>&1
    [ "${failed}" -eq 1 ] && \
        echo "${service}: 已清除上次的 failed 状态与 systemd 启动限流计数。"
    return 0
}

Svc()
{
    local service="$1" action="$2"

    [ -z "${service}" ] && return 0

    case "${action}" in
    start|stop|restart|reload|status)
        if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 \
           && Svc_Unit_Exists "${service}"; then
            case "${action}" in
            start|restart) Reset_Start_Limit "${service}" ;;
            esac
            systemctl --no-pager "${action}" "${service}.service"
            return $?
        fi
        ;;
    esac

    if [ -x "/etc/init.d/${service}" ]; then
        "/etc/init.d/${service}" "${action}"
        return $?
    fi
    echo "${service}: 既没有 systemd unit 也没有 /etc/init.d 脚本，跳过。"
    return 1
}

Svc_If_Installed()
{
    local label="$1" service="$2" action="$3" rc
    if [ -z "${service}" ]; then
        echo "${label}: 未检测到已安装服务，跳过 ${action}。"
        return 0
    fi
    Svc "${service}" "${action}"
    rc=$?
    [ ${rc} -eq 0 ] || [ "${action}" = status ] || Echo_Red "${label} ${action} 失败（退出码 ${rc}）"
    return ${rc}
}

# systemctl 成功时通常不输出内容，因此管理命令补充明确的成功或失败结果。
# status 已包含完整状态，不再重复提示。
Svc_Feedback()
{
    local service="$1" action="$2" rc

    # 强制终止由 init 脚本直接发信号，进程会脱离 systemd 管理，须走 lnmp kill。
    case "${action}" in
    '')
        echo "用法：lnmp ${service} {start|stop|restart|reload|status}"
        return 1
        ;;
    kill|force-quit)
        if [ -d /run/systemd/system ] && Svc_Unit_Exists "${service}"; then
            Echo_Red "${service} 由 systemd 管理，不支持单独 ${action}；请用 lnmp stop，失败时再用 lnmp kill。"
            return 1
        fi
        ;;
    esac

    Svc "${service}" "${action}"
    rc=$?

    case "${action}" in
    status)
        ;;
    *)
        if [ ${rc} -eq 0 ]; then
            Echo_Green "${service} ${action} 成功"
        else
            Echo_Red "${service} ${action} 失败（退出码 ${rc}）"
            case "${service}" in
            mysql|mariadb) Diagnose_DB_Start_Failure "${action}" ;;
            nginx|httpd)   Diagnose_Web_Start_Failure "${service}" ;;
            esac
        fi
        ;;
    esac

    return ${rc}
}

Check_Svc_State()
{
    local service state stray='' down=''

    [ -d /run/systemd/system ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0

    for service in "$@"; do
        [ -z "${service}" ] && continue
        Svc_Unit_Exists "${service}" || continue
        state=$(systemctl is-active "${service}.service" 2>/dev/null)
        [ "${state}" = "active" ] && continue
        # unit 设了 Restart= 后，重启期间状态为 activating，此时尚未出结果，
        # 判定为异常会产生误报。
        case "${state}" in
            activating|deactivating|reloading) continue ;;
        esac
        # 进程在跑但 unit 不是 active，才是 systemd 之外启动导致的状态不一致；
        # 进程不在，说明启动确实失败，此时提示 kill 只会重复同一个失败。
        if Svc_Process_Running "${service}"; then
            stray="${stray} ${service}"
        else
            down="${down} ${service}"
        fi
    done

    [ -z "${stray}" ] && [ -z "${down}" ] && return 0

    if [ -n "${stray}" ]; then
        echo "警告：以下服务在运行，但不受 systemd 管理：${stray}"
        echo "      它们被 systemd 之外的方式启动过，systemctl 无法停止或重载。"
        echo "      执行 lnmp kill 后再 lnmp start，可让两边重新对齐。"
    fi
    if [ -n "${down}" ]; then
        echo "警告：以下服务未能启动：${down}"
        echo "      查看失败原因："
        for service in ${down}; do
            echo "        systemctl status ${service}.service"
            echo "        journalctl -xeu ${service}.service"
        done
    fi
    return 1
}

# Apache 主配置是否经 mod_proxy_fcgi 交给 PHP-FPM（新装形态）；否则按 mod_php 的指令书写站点配置。
Apache_PHP_Is_FPM()
{
    grep -Eq '^[[:space:]]*Include[[:space:]]+conf/extra/lnmp-php\.conf' /usr/local/apache/conf/httpd.conf 2>/dev/null
}

# Site_Apache_Open_Basedir <站点目录> [off]：输出站点级 open_basedir 指令，off 时输出为注释行。
Site_Apache_Open_Basedir()
{
    local line

    if Apache_PHP_Is_FPM; then
        line="ProxyFCGISetEnvIf \"true\" PHP_ADMIN_VALUE \"open_basedir=${1}:/tmp/:/var/tmp/:/proc/\""
    else
        line="php_admin_value open_basedir \"${1}:/tmp/:/var/tmp/:/proc/\""
    fi
    [ "${2:-}" = off ] && line="#${line}"
    printf '%s\n' "${line}"
}

# 站点关闭 PHP 的标记行。mod_php 形态由 php_admin_flag 关闭引擎，PHP-FPM 形态只靠 RedirectMatch。
Site_Apache_Engine_Off()
{
    Apache_PHP_Is_FPM || printf '%s\n' 'php_admin_flag engine off'
}

# Apache 栈（PHP-FPM 形态）的附加 PHP 实例：程序与 init 脚本齐备才算可用。
# 输出已装版本，每行一个。
Apache_MPHP_Versions()
{
    local script ver

    for script in /etc/init.d/php-fpm[578].[0-9]; do
        [ -f "${script}" ] || continue
        ver="${script##*/php-fpm}"
        [ -s "/usr/local/php${ver}/sbin/php-fpm" ] && printf '%s\n' "${ver}"
    done
    return 0
}

# Apache_MPHP_Action <动作>：对全部附加实例执行服务动作，模板 unit 已安装时走 systemd。
# 逐个执行，任一实例失败返回 1。
Apache_MPHP_Action()
{
    local action="$1" ver rc failed=0

    for ver in $(Apache_MPHP_Versions); do
        if Svc_Unit_Exists "php-fpm@"; then
            Svc "php-fpm@${ver}" "${action}"
        else
            "/etc/init.d/php-fpm${ver}" "${action}"
        fi
        rc=$?
        [ ${rc} -eq 0 ] && continue
        failed=1
        [ "${action}" = status ] || Echo_Red "PHP ${ver} ${action} 失败（退出码 ${rc}）"
    done
    return ${failed}
}

# Apache_MPHP_Choose：为站点选择 PHP 版本，结果写入 apache_php_ver（空表示使用主 PHP）。
# 只有主 PHP 时不询问；非 PHP-FPM 形态（mod_php）不支持附加实例。
Apache_MPHP_Choose()
{
    local ver idx choice cands='' total cur_ver=''

    apache_php_ver=''
    Apache_PHP_Is_FPM || return 0
    if [ -s /usr/local/php/bin/php-config ]; then
        cur_ver="$(/usr/local/php/bin/php-config --version)"
        cands='main'
    fi
    for ver in $(Apache_MPHP_Versions); do
        cands="${cands:+${cands} }${ver}"
    done
    case "${cands}" in
    ''|main) return 0 ;;
    esac

    echo "检测到多个 PHP 版本，请选择要使用的版本。"
    idx=0
    for ver in ${cands}; do
        idx=$((idx + 1))
        if [ "${ver}" = main ]; then
            Echo_Green "${idx}: 默认主 PHP ${cur_ver}"
        else
            Echo_Green "${idx}: PHP ${ver} [已安装]"
        fi
    done
    total=${idx}
    while :; do
        Echo_Yellow "请选择 [1-${total}]（默认 1）："
        Read_Input choice "PHP 版本选择"
        [ -z "${choice}" ] && choice=1
        case "${choice}" in
        *[!0-9]*|'')
            Echo_Red "请输入 1 到 ${total} 之间的编号。"
            continue
            ;;
        esac
        if [ "${choice}" -lt 1 ] || [ "${choice}" -gt "${total}" ]; then
            Echo_Red "只能选择上面列出的编号 1 到 ${total}。"
            continue
        fi
        ver=$(printf '%s\n' ${cands} | sed -n "${choice}p")
        if [ "${ver}" = main ]; then
            echo "当前选择：PHP ${cur_ver}"
        else
            echo "当前选择：PHP $(/usr/local/php${ver}/bin/php-config --version)"
            apache_php_ver="${ver}"
        fi
        return 0
    done
}

# Site_Apache_PHP_Version_Block <版本>：站点使用附加 PHP 时的处理器覆盖，版本为空时无输出。
Site_Apache_PHP_Version_Block()
{
    [ -n "${1:-}" ] || return 0
    printf '%s\n' "# 本站点使用 PHP ${1}。" '<FilesMatch "\.php$">' \
        "    SetHandler \"proxy:unix:/run/php-fpm/php-cgi${1}.sock|fcgi://localhost\"" '</FilesMatch>'
}

# Kill_Process <进程名> [等待秒数]
# 先 TERM 并等待进程真正退出，超时才 KILL。不等待会让随后的 start 撞上
# 尚未释放的端口或 pid 文件。目标进程本就不存在时静默返回 0。
Kill_Process()
{
    local name="$1" wait_sec="${2:-10}" i

    if ! command -v pgrep >/dev/null 2>&1 || ! command -v pkill >/dev/null 2>&1; then
        # 缺少 procps 时退回 killall，此路径无法确认进程是否已退出。
        if command -v killall >/dev/null 2>&1; then
            killall "${name}" 2>/dev/null
            return 0
        fi
        Echo_Red "缺少 pkill 和 killall，无法终止 ${name}，请安装 procps。"
        return 1
    fi

    pgrep -x "${name}" >/dev/null 2>&1 || return 0
    pkill -x "${name}" 2>/dev/null
    i=0
    while [ ${i} -lt ${wait_sec} ]; do
        pgrep -x "${name}" >/dev/null 2>&1 || return 0
        sleep 1
        i=$((i + 1))
    done

    Echo_Yellow "${name} 未响应 TERM，改用 KILL 强制终止。"
    echo
    pkill -9 -x "${name}" 2>/dev/null
    sleep 1
    pgrep -x "${name}" >/dev/null 2>&1 || return 0
    Echo_Red "${name} 进程未能终止，请手工检查。"
    return 1
}

# 先按 unit 停止再清残留：unit 设了 Restart=on-failure 时，直接发信号会被
# systemd 判为异常退出并重新拉起；systemctl stop 属主动停止，不触发重启。
Kill_By_Unit()
{
    local svc
    for svc in "$@"; do
        [ -z "${svc}" ] && continue
        Svc_Unit_Exists "${svc}" || continue
        Svc "${svc}" stop >/dev/null 2>&1
    done
}

# 应用名同时用于 unit 实例名、专属账号名和文件名，字符集必须收紧。
# 账号名为 lnmp-app-<名字>，Linux 用户名上限 32 字符，故名字最长 23。
Check_App_Name()
{
    local n="$1"

    if [ -z "${n}" ]; then
        Echo_Red "应用名不能为空。"
        return 1
    fi
    if [ ${#n} -gt 23 ]; then
        Echo_Red "应用名过长（超过 23 字符）：${n}"
        return 1
    fi
    if ! printf '%s' "${n}" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
        Echo_Red "应用名不合法：'${n}'"
        Echo_Red "只接受小写字母、数字和中划线，且必须以字母或数字开头结尾。"
        return 1
    fi
    return 0
}

App_Env_File()  { echo "${App_Conf_Dir}/$1.env"; }

App_User_Name() { echo "lnmp-app-$1"; }

App_Unit_Name() { echo "lnmp-app@$1.service"; }

# PM2 托管应用的状态目录；env 文件含 PM2_HOME 即为 PM2 托管。
App_Pm2_Home() { echo "${App_State_Dir:-/var/lib/lnmp/apps}/$1/pm2"; }

App_Is_Pm2() { grep -q '^PM2_HOME=' "$(App_Env_File "$1")" 2>/dev/null; }

# App_Pm2_Run <应用名> <pm2 参数...>：以应用账号和该应用的 PM2_HOME 执行同目录的 pm2。
App_Pm2_Run()
{
    local name="$1" bin_dir user

    shift
    App_Load "${name}"
    bin_dir=${App_Exec%% *}
    bin_dir=${bin_dir%/*}
    user=$(App_User_Name "${name}")
    if ! command -v runuser >/dev/null 2>&1; then
        Echo_Red "系统没有 runuser，无法以应用账号执行 pm2。"
        return 1
    fi
    if [ ! -x "${bin_dir}/pm2" ]; then
        Echo_Red "找不到 ${bin_dir}/pm2，请执行 ./addons.sh install pm2。"
        return 1
    fi
    runuser -u "${user}" -- env \
        "PATH=${bin_dir}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "PM2_HOME=$(App_Pm2_Home "${name}")" "${bin_dir}/pm2" "$@"
}

App_Exists()
{
    [ -s "$(App_Env_File "$1")" ]
}

# 读取应用元数据到 App_Dir / App_Exec / App_Port。
App_Load()
{
    local name="$1" env_file
    env_file=$(App_Env_File "${name}")

    App_Dir=$(awk -F= '$1 == "APP_DIR" { sub(/^APP_DIR=/, ""); print; exit }' "${env_file}")
    App_Exec=$(awk -F= '$1 == "APP_EXEC" { sub(/^APP_EXEC=/, ""); print; exit }' "${env_file}")
    App_Port=$(awk -F= '$1 == "APP_PORT" { sub(/^APP_PORT=/, ""); print; exit }' "${env_file}")
    return 0
}

# 端口被别的进程占用时拒绝，避免应用起来后与现有服务抢端口。
Check_App_Port()
{
    local port="$1"

    [ -z "${port}" ] && return 0
    if ! printf '%s' "${port}" | grep -Eq '^[0-9]+$' \
       || [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
        Echo_Red "端口不合法：${port}"
        return 1
    fi
    if command -v ss >/dev/null 2>&1 \
       && ss -lntH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' \
          | grep -qx "${port}"; then
        Echo_Red "端口 ${port} 已被占用。"
        return 1
    fi
    return 0
}

# 模板 unit 由安装流程写入；命令行单独使用时按需补装。
Ensure_App_Unit_Tpl()
{
    if [ ! -s "${App_Unit_Tpl}" ]; then
        Echo_Red "缺少应用托管单元 ${App_Unit_Tpl}。"
        Echo_Yellow "请重新执行安装包中的收尾步骤，或手工放置 init.d/lnmp-app@.service。"
        return 1
    fi
    if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
        Echo_Red "当前系统未运行 systemd，无法托管应用进程。"
        return 1
    fi
    return 0
}

# App_Dir_Key <目录>：比较用的规范路径，去掉重复与结尾斜杠及 . 组件。
App_Dir_Key()
{
    realpath -m -- "$1" 2>/dev/null || printf '%s\n' "$1" | sed -e 's#/\+#/#g' -e 's#/$##'
}

# 目录与其它托管应用的目录相同或互为父子时拒绝：chown -R 会夺走对方的属主。
App_Dir_In_Use()
{
    local dir env_file other other_dir

    [ -d "${App_Conf_Dir}" ] || return 1
    dir=$(App_Dir_Key "$1")
    for env_file in "${App_Conf_Dir}"/*.env; do
        [ -s "${env_file}" ] || continue
        other=$(basename "${env_file}" .env)
        other_dir=$(awk -F= '$1 == "APP_DIR" { sub(/^APP_DIR=/, ""); print; exit }' "${env_file}")
        [ -n "${other_dir}" ] || continue
        other_dir=$(App_Dir_Key "${other_dir}")
        if [ "${other_dir}" = "${dir}" ]; then
            Echo_Red "目录 ${dir} 已被应用 ${other} 使用。"
        elif [[ "${dir}/" == "${other_dir}/"* ]]; then
            Echo_Red "目录 ${dir} 位于应用 ${other} 的目录 ${other_dir} 之内。"
        elif [[ "${other_dir}/" == "${dir}/"* ]]; then
            Echo_Red "目录 ${dir} 包含应用 ${other} 的目录 ${other_dir}。"
        else
            continue
        fi
        Echo_Red "（递归改属主会夺走该应用的目录属主。）"
        return 0
    done
    return 1
}

Add_App()
{
    local name dir exec_cmd port user env_file bin nodejs_prefix="${LNMP_NODEJS_PREFIX:-/usr/local/nodejs}"
    local -a parts
    local pm2_mode=n pm2_home

    Ensure_App_Unit_Tpl || return 1

    while :; do
        Echo_Yellow "请输入应用名（小写字母、数字、中划线）: "
        Read_Input name "应用名"
        Check_App_Name "${name}" || continue
        if App_Exists "${name}"; then
            Echo_Red "应用 ${name} 已存在，请先用 lnmp app del 删除或换一个名字。"
            continue
        fi
        break
    done

    while :; do
        Echo_Yellow "请输入应用目录（绝对路径）: "
        Read_Input dir "应用目录"
        # 复用站点目录的边界校验：随后要对该目录执行 chown -R，
        # 必须挡住 /etc、/usr 这类系统目录、允许根本身和符号链接越界。
        if ! Check_Vhost_Dir "${dir}"; then
            Echo_Red "该目录不能作为应用目录，请另选。"
            continue
        fi
        dir="${vhostdir}"
        if [ ! -d "${dir}" ]; then
            Echo_Red "目录不存在：${dir}"
            continue
        fi
        App_Dir_In_Use "${dir}" && continue
        break
    done

    while :; do
        Echo_Yellow "请输入启动命令（含绝对路径，如 /usr/bin/node server.js）: "
        Echo_Yellow "只支持以空格分隔的简单参数，参数本身不能含空格。"
        Read_Input exec_cmd "启动命令"
        if [ -z "${exec_cmd}" ]; then
            Echo_Red "启动命令不能为空。"
            continue
        fi
        # 换行会破坏 EnvironmentFile 的一行一项格式。
        case "${exec_cmd}" in
        *$'\n'*) Echo_Red "启动命令不能包含换行。"; continue ;;
        esac
        # APP_EXEC 在 unit 里以未加引号的形式展开，shell 只做分词和通配，
        # 不会把展开结果里的引号、反斜杠、重定向和命令连接重新当成语法，
        # 这些写法会静默改变参数边界。因此按白名单收字符，不合法就当场说清限制。
        if printf '%s' "${exec_cmd}" | LC_ALL=C grep -q '[^A-Za-z0-9 _./:=@,+-]'; then
            Echo_Red "启动命令只能用字母、数字、空格和 _ . / : = @ , + - 这些字符。"
            Echo_Red "引号、反斜杠、通配、变量展开、重定向和命令连接符都不会生效，"
            Echo_Red "带空格的参数也无法保留边界。"
            Echo_Red "需要这些写法时，请写成应用自己的启动脚本，这里填该脚本的绝对路径。"
            continue
        fi
        bin=${exec_cmd%% *}
        case "${bin}" in
        /*) ;;
        *)  Echo_Red "启动命令的可执行文件必须写绝对路径：${bin}"; continue ;;
        esac
        if [ ! -x "${bin}" ]; then
            Echo_Red "不是可执行文件：${bin}"
            continue
        fi
        # pm2-runtime 托管：参数必须是 start <ecosystem 文件>，文件须存在。
        pm2_mode=n
        if [ "${bin##*/}" = "pm2-runtime" ]; then
            read -r -a parts <<<"${exec_cmd}"
            if [ "${#parts[@]}" -ne 3 ] || [ "${parts[1]}" != "start" ]; then
                Echo_Red "PM2 托管的启动命令格式为：<pm2-runtime 绝对路径> start <ecosystem 文件>"
                continue
            fi
            case "${parts[2]}" in
            /*) [ -f "${parts[2]}" ] ;;
            *)  [ -f "${dir}/${parts[2]}" ] ;;
            esac || { Echo_Red "ecosystem 文件不存在：${parts[2]}"; continue; }
            pm2_mode=y
        fi
        break
    done

    while :; do
        Echo_Yellow "请输入监听端口（留空跳过检查）: "
        Read_Input port "监听端口"
        Check_App_Port "${port}" || continue
        break
    done

    user=$(App_User_Name "${name}")
    if ! id -u "${user}" >/dev/null 2>&1; then
        # 专属账号，不复用 www：复用会让应用获得全部站点目录的读写权限。
        if ! useradd -r -M -s /sbin/nologin "${user}" 2>/dev/null \
           && ! useradd -r -M -s /usr/sbin/nologin "${user}" 2>/dev/null; then
            Echo_Red "创建运行账号 ${user} 失败。"
            return 1
        fi
        echo "已创建运行账号 ${user}。"
    fi

    if ! mkdir -p "${App_Conf_Dir}"; then
        Echo_Red "创建 ${App_Conf_Dir} 失败。"
        return 1
    fi
    chmod 750 "${App_Conf_Dir}"

    env_file=$(App_Env_File "${name}")
    if ! cat >"${env_file}"<<EOF
APP_DIR=${dir}
APP_EXEC=${exec_cmd}
APP_PORT=${port}
EOF
    then
        Echo_Red "写入 ${env_file} 失败。"
        return 1
    fi
    # 使用 /usr/local/nodejs/<主版本>/bin 下的解释器时，把该目录置于 PATH 首位，
    # 应用内 npm run、#!/usr/bin/env node 与子进程调用 node 才会找到同一版本。
    if [[ "${bin}" == "${nodejs_prefix}"/* && "${bin#"${nodejs_prefix}"/}" =~ ^[0-9]+/bin/[A-Za-z0-9._-]+$ ]]; then
        printf 'PATH=%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' \
            "${bin%/*}" >>"${env_file}"
    fi
    # Node.js 应用通常读取 PORT。
    [ -z "${port}" ] || printf 'PORT=%s\n' "${port}" >>"${env_file}"
    if [ "${pm2_mode}" = "y" ]; then
        # 应用账号没有家目录，PM2 状态目录单独指定并仅限该账号访问。
        pm2_home=$(App_Pm2_Home "${name}")
        if ! mkdir -p "${pm2_home}" || ! chown -R "${user}:${user}" "${pm2_home%/pm2}" \
           || ! chmod 700 "${pm2_home}"; then
            Echo_Red "创建 PM2 状态目录 ${pm2_home} 失败。"
            rm -f "${env_file}"
            return 1
        fi
        printf 'PM2_HOME=%s\n' "${pm2_home}" >>"${env_file}"
    fi
    chmod 640 "${env_file}"

    # 应用需要读取自己的目录，交给专属账号。
    # 递归改属主前再次复核边界：dir 到这里为止经过了多次赋值与交互输入。
    if ! Check_Vhost_Dir "${dir}" || [ ! -d "${dir}" ]; then
        Echo_Red "应用目录 ${dir} 未通过写入前复核，已取消托管。"
        rm -f "${env_file}"
        return 1
    fi
    if ! chown -R "${user}:${user}" "${dir}"; then
        Echo_Yellow "变更 ${dir} 属主失败，请确认应用账号对该目录有读取权限。"
    fi

    Svc_Reload_Units
    if ! systemctl enable --now "$(App_Unit_Name "${name}")"; then
        Echo_Red "启动应用 ${name} 失败，配置已保留。"
        Echo_Yellow "可执行 lnmp app logs ${name} 查看原因。"
        return 1
    fi

    echo "========================================================"
    echo "应用 ${name} 已托管并设为开机启动。"
    echo "目录：${dir}"
    echo "命令：${exec_cmd}"
    [ -n "${port}" ] && echo "端口：${port}"
    echo "运行账号：${user}"
    [ "${pm2_mode}" = "y" ] && echo "PM2 状态目录：${pm2_home}（平滑重载：lnmp app reload ${name}）"
    echo "查看日志：lnmp app logs ${name}"
    [ -n "${port}" ] && echo "反向代理请执行 lnmp vhost add 建站后按 127.0.0.1:${port} 配置。"
    echo "========================================================"
    return 0
}

List_App()
{
    local env_file name state

    if [ ! -d "${App_Conf_Dir}" ] || [ -z "$(ls -A "${App_Conf_Dir}" 2>/dev/null)" ]; then
        echo "当前没有托管的应用。"
        return 0
    fi
    printf '%-24s %-10s %-8s %s\n' "应用名" "状态" "端口" "目录"
    for env_file in "${App_Conf_Dir}"/*.env; do
        [ -s "${env_file}" ] || continue
        name=$(basename "${env_file}" .env)
        App_Load "${name}"
        state=$(systemctl is-active "$(App_Unit_Name "${name}")" 2>/dev/null)
        printf '%-24s %-10s %-8s %s\n' "${name}" "${state:-unknown}" "${App_Port:-—}" "${App_Dir}"
    done
    return 0
}

Del_App()
{
    local name="$1" user env_file answer

    if [ -z "${name}" ]; then
        List_App
        while :; do
            Echo_Yellow "请输入要删除的应用名: "
            Read_Input name "应用名"
            Check_App_Name "${name}" || continue
            break
        done
    else
        Check_App_Name "${name}" || return 1
    fi

    if ! App_Exists "${name}"; then
        Echo_Red "应用 ${name} 不存在。"
        return 1
    fi

    App_Load "${name}"
    user=$(App_User_Name "${name}")
    env_file=$(App_Env_File "${name}")

    systemctl disable --now "$(App_Unit_Name "${name}")" >/dev/null 2>&1
    systemctl reset-failed "$(App_Unit_Name "${name}")" >/dev/null 2>&1
    rm -f "${env_file}"
    # 状态目录由 lnmp app add 创建，应用名已通过 Check_App_Name，路径固定。
    rm -rf -- "${App_State_Dir:-/var/lib/lnmp/apps}/${name}"

    # 账号可能仍拥有应用目录，交由用户决定是否删除。
    if id -u "${user}" >/dev/null 2>&1; then
        Echo_Yellow "是否删除运行账号 ${user}？(y/N) "
        if read -r answer && { [ "${answer}" = "y" ] || [ "${answer}" = "Y" ]; }; then
            userdel "${user}" >/dev/null 2>&1 \
                && echo "已删除账号 ${user}。" \
                || Echo_Yellow "删除账号 ${user} 失败，请手工处理。"
        else
            echo "保留账号 ${user}。"
        fi
    fi

    Svc_Reload_Units
    echo "========================================================"
    echo "应用 ${name} 已取消托管。"
    echo "为安全起见，应用目录 ${App_Dir} 不会被自动删除。"
    echo "站点的反向代理配置需要另行用 lnmp vhost del 处理。"
    echo "========================================================"
    return 0
}

# start/stop/restart/status 统一走 systemd，与其余服务的语义保持一致。
App_Ctl()
{
    local action="$1" name="$2" rc

    if [ -z "${name}" ]; then
        Echo_Red "请指定应用名：lnmp app ${action} <应用名>"
        return 1
    fi
    Check_App_Name "${name}" || return 1
    if ! App_Exists "${name}"; then
        Echo_Red "应用 ${name} 不存在。"
        return 1
    fi
    systemctl --no-pager "${action}" "$(App_Unit_Name "${name}")"
    rc=$?
    if [ "${action}" = "status" ] && App_Is_Pm2 "${name}" \
       && systemctl is-active --quiet "$(App_Unit_Name "${name}")"; then
        echo "---- PM2 进程 ----"
        App_Pm2_Run "${name}" list
    fi
    return "${rc}"
}

# 平滑重载：仅 PM2 托管的应用支持，经 pm2 reload 逐个替换工作进程。
App_Reload()
{
    local name="$1"

    if [ -z "${name}" ]; then
        Echo_Red "请指定应用名：lnmp app reload <应用名>"
        return 1
    fi
    Check_App_Name "${name}" || return 1
    if ! App_Exists "${name}"; then
        Echo_Red "应用 ${name} 不存在。"
        return 1
    fi
    if ! App_Is_Pm2 "${name}"; then
        Echo_Red "应用 ${name} 不是 PM2 托管，不支持 reload，请使用 lnmp app restart ${name}。"
        return 1
    fi
    if ! systemctl is-active --quiet "$(App_Unit_Name "${name}")"; then
        Echo_Red "应用 ${name} 未在运行，请先执行 lnmp app start ${name}。"
        return 1
    fi
    App_Pm2_Run "${name}" reload all
}

Logs_App()
{
    local name="$1"

    if [ -z "${name}" ]; then
        Echo_Red "请指定应用名：lnmp app logs <应用名>"
        return 1
    fi
    Check_App_Name "${name}" || return 1
    if ! App_Exists "${name}"; then
        Echo_Red "应用 ${name} 不存在。"
        return 1
    fi
    if ! command -v journalctl >/dev/null 2>&1; then
        Echo_Red "系统没有 journalctl，无法查看应用日志。"
        return 1
    fi
    journalctl -u "$(App_Unit_Name "${name}")" -n 100 --no-pager
}

Function_App()
{
    case "$1" in
        [aA][dD][dD])
            Add_App
            ;;
        [lL][iI][sS][tT])
            List_App
            ;;
        [dD][eE][lL])
            Del_App "$2"
            ;;
        [sS][tT][aA][rR][tT]|[sS][tT][oO][pP]|[rR][eE][sS][tT][aA][rR][tT]|[sS][tT][aA][tT][uU][sS])
            App_Ctl "$(echo "$1" | tr '[:upper:]' '[:lower:]')" "$2"
            ;;
        [rR][eE][lL][oO][aA][dD])
            App_Reload "$2"
            ;;
        [lL][oO][gG][sS])
            Logs_App "$2"
            ;;
        *)
            echo "用法：lnmp app {add|list|del|start|stop|restart|reload|status|logs}"
            echo "      lnmp app {del|start|stop|restart|reload|status|logs} <应用名>"
            exit 1
            ;;
    esac
}

Function_Perm()
{
    # 权限基线核对由三种运行模式共用，避免基线出现分歧。
    local bin="/bin/lnmp-perm"
    if [ ! -x "${bin}" ]; then
        Echo_Red "找不到 ${bin}，安装不完整。"
        Echo_Red "可从源码目录补装："
        Echo_Red "  cp tools/lnmp-perm.sh /bin/lnmp-perm && chmod +x /bin/lnmp-perm"
        return 1
    fi
    "${bin}" "$@"
}

Function_Health()
{
    # 健康检查由三种运行模式共用，避免探测阈值出现分歧。
    local bin="/bin/lnmp-health"
    if [ ! -x "${bin}" ]; then
        Echo_Red "找不到 ${bin}，安装不完整。"
        Echo_Red "可从源码目录补装："
        Echo_Red "  cp tools/lnmp-health.sh /bin/lnmp-health && chmod +x /bin/lnmp-health"
        return 1
    fi
    "${bin}" "$@"
}

Function_Fw()
{
    # 防火墙对齐由三种运行模式共用，避免规则表出现分歧。
    local bin="/bin/lnmp-fw"
    if [ ! -x "${bin}" ]; then
        Echo_Red "找不到 ${bin}，安装不完整。"
        Echo_Red "可从源码目录补装："
        Echo_Red "  cp tools/lnmp-fw.sh /bin/lnmp-fw && chmod +x /bin/lnmp-fw"
        return 1
    fi
    "${bin}" "$@"
}

Function_Backup()
{
    # 三种运行模式共用 /bin/lnmp-backup，避免备份行为不一致。
    local bin="/bin/lnmp-backup"
    if [ ! -x "${bin}" ]; then
        Echo_Red "找不到 ${bin}，安装不完整。"
        Echo_Red "可从源码目录补装："
        Echo_Red "  ./bumpversion.sh"
        return 1
    fi
    "${bin}" "$@"
}

# 后端主机名：去掉 scheme、端口和路径。
Proxy_Backend_Host()
{
    printf '%s' "$1" | sed -E 's#^https?://##; s#[:/].*$##'
}

# IPv4 字面量返回 0，域名返回 1。两者的 proxy_pass 写法不同。
Proxy_Backend_Is_IP()
{
    printf '%s' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

# 列出 vhost 目录下的配置名。目录为空时 glob 不展开，用 -e 跳过字面量。
List_VHost_Dir()
{
    local f name
    for f in "$1"/*.conf; do
        [ -e "${f}" ] || continue
        name=$(basename "${f}" .conf)
        if Vhost_Is_Stopped "${f}" || Vhost_Is_Stopped "$1/shared/${name}.conf"; then
            echo "${name} [已停用]"
        else
            echo "${name}"
        fi
    done
}

# Vhost_Accept <Host> <网站目录> <php|static|proxy> [期望 PHP 版本]：建站后经本机 80 端口请求站点。
# Web 入口服务未运行时只说明未验收，不判失败。0 通过或未验收；1 未通过。
Vhost_Accept()
{
    local host=$1 root=$2 kind=$3 want=${4:-} web='nginx' rc i dir='' prefix='' made='n'

    [ -x /usr/local/nginx/sbin/nginx ] || web='httpd'
    if ! Svc_Running "${web}"; then
        echo "Web 服务未运行，站点配置已生成，未做请求验收。"
        return 0
    fi
    # 反代站点只看状态码，无法区分请求是否落到其它站点；先经本地提供的
    # /.well-known/ 以静态文件确认新配置已生效，再请求上游。
    if [ "${kind}" = proxy ]; then
        dir="${root}/.well-known"
        [ -d "${dir}" ] || { mkdir -- "${dir}" 2>/dev/null && made='y'; }
        prefix='/.well-known'
        kind='static'
    else
        dir="${root}"
    fi
    # graceful 重载后旧工作进程可能仍在处理连接，未到达本站点时重试。
    for i in 1 2 3 4 5; do
        Web_Probe "${kind}" "${host}" 80 "${dir}" "${want}" "${prefix}"
        rc=$?
        [ "${rc}" -eq 5 ] || break
        sleep 1
    done
    [ "${made}" = 'y' ] && rmdir -- "${dir}" 2>/dev/null
    if [ -n "${prefix}" ] && { [ "${rc}" -eq 0 ] || [ "${rc}" -eq 7 ]; }; then
        kind='get'
        Web_Probe get "${host}" 80 "${root}"
        rc=$?
    fi
    case "${rc}" in
    0) Echo_Green "$(Web_Probe_Report "${rc}" "${kind}" "${host}" "${want}")" ;;
    7|8) Web_Probe_Report "${rc}" "${kind}" "${host}" "${want}" ;;
    *) Echo_Red "$(Web_Probe_Report "${rc}" "${kind}" "${host}" "${want}")"; return 1 ;;
    esac
    return 0
}

# 站点类型说明，供选择后的确认输出。
Site_Type_Note()
{
    case "$1" in
    php) echo "站点类型：PHP 站点。" ;;
    static) echo "站点类型：静态站点，不执行任何 .php。" ;;
    proxy) echo "站点类型：反向代理，请求转发到后端服务。" ;;
    esac
}

# Site_Type_Menu：选择站点类型，写入 site_type（php|static|proxy）与 enable_site_php。
# 非交互不读标准输入：读 VHOST_TYPE，兼容 VHOST_PHP、VHOST_PROXY；取值非法或相互矛盾时返回 1。
# 依赖各栈的 Site_PHP_Available。
Site_Type_Menu()
{
    local type="${VHOST_TYPE:-}" php='' explicit='n' has_php='y' choice

    site_type=''
    enable_site_php='n'
    Site_PHP_Available || has_php='n'

    if [ ! -t 0 ]; then
        type="${type,,}"
        case "${VHOST_PHP:-}" in
        '') ;;
        [yY]|[yY][eE][sS]) php='y' ;;
        [nN]|[nN][oO]) php='n' ;;
        *) Echo_Red "VHOST_PHP 只接受 y 或 n，已放弃建站。"; return 1 ;;
        esac
        case "${type}" in
        '')
            if [ -n "${VHOST_PROXY:-}" ]; then
                if [ "${php}" = 'y' ]; then
                    Echo_Red "VHOST_PHP=y 与 VHOST_PROXY 冲突：反向代理站点不执行本地 PHP，已放弃建站。"
                    return 1
                fi
                type='proxy'
            elif [ "${php}" = 'n' ]; then
                type='static'
            else
                type='php'
                [ "${php}" = 'y' ] && explicit='y'
            fi
            ;;
        php)
            explicit='y'
            if [ "${php}" = 'n' ] || [ -n "${VHOST_PROXY:-}" ]; then
                Echo_Red "VHOST_TYPE=php 与 VHOST_PHP=n 或 VHOST_PROXY 冲突，已放弃建站。"
                return 1
            fi
            ;;
        static)
            if [ "${php}" = 'y' ] || [ -n "${VHOST_PROXY:-}" ]; then
                Echo_Red "VHOST_TYPE=static 与 VHOST_PHP=y 或 VHOST_PROXY 冲突，已放弃建站。"
                return 1
            fi
            ;;
        proxy)
            if [ "${php}" = 'y' ]; then
                Echo_Red "VHOST_TYPE=proxy 与 VHOST_PHP=y 冲突，已放弃建站。"
                return 1
            fi
            if [ -z "${VHOST_PROXY:-}" ]; then
                Echo_Red "VHOST_TYPE=proxy 需要用 VHOST_PROXY 指定后端地址，已放弃建站。"
                return 1
            fi
            ;;
        *)
            Echo_Red "VHOST_TYPE 只接受 php、static 或 proxy，已放弃建站。"
            return 1
            ;;
        esac
        if [ "${type}" = 'php' ] && [ "${has_php}" = 'n' ]; then
            if [ "${explicit}" = 'y' ]; then
                Echo_Red "未检测到已安装的 PHP，不能建立 PHP 站点，已放弃建站。"
                return 1
            fi
            echo "未检测到已安装的 PHP，按静态站点建立，所有 .php 请求返回 404。"
            echo "如需 PHP 站点，请先完成 PHP 安装再建站。"
            type='static'
        fi
        site_type="${type}"
        echo "非交互执行，$(Site_Type_Note "${site_type}")"
    else
        echo "请选择站点类型："
        if [ "${has_php}" = 'y' ]; then
            echo "  1) PHP 站点"
        else
            echo "  1) PHP 站点（未检测到已安装的 PHP，不可选；如需 PHP 站点，请先完成 PHP 安装再建站）"
        fi
        echo "  2) 静态站点（不执行 .php）"
        echo "  3) 反向代理（请求转发到后端服务）"
        while :;do
            if [ "${has_php}" = 'y' ]; then
                Echo_Yellow "请选择 [1-3]（默认 1）: "
            else
                Echo_Yellow "请选择 [2-3]（默认 2）: "
            fi
            Read_Input choice "站点类型"
            [ -n "${choice}" ] || choice=$([ "${has_php}" = 'y' ] && echo 1 || echo 2)
            case "${choice}" in
            1)
                if [ "${has_php}" = 'n' ]; then
                    Echo_Red "未检测到已安装的 PHP，请选择 2 或 3。"
                    continue
                fi
                site_type='php'
                ;;
            2) site_type='static' ;;
            3) site_type='proxy' ;;
            *) Echo_Red "请输入列出的编号。"; continue ;;
            esac
            break
        done
        Site_Type_Note "${site_type}"
    fi
    [ "${site_type}" = 'php' ] && enable_site_php='y'
    return 0
}

# Site_Preset_Menu：PHP 站点的程序预设，写入 site_preset（none|wordpress|laravel）。
# 预设只改变后续提问的默认值。非交互读 VHOST_PRESET，非 PHP 站点设置该变量时返回 1。
Site_Preset_Menu()
{
    local preset="${VHOST_PRESET:-}" choice

    site_preset='none'
    preset="${preset,,}"
    if [ ! -t 0 ]; then
        case "${preset}" in
        ''|none) return 0 ;;
        wordpress|laravel) ;;
        *) Echo_Red "VHOST_PRESET 只接受 wordpress 或 laravel，已放弃建站。"; return 1 ;;
        esac
        if [ "${site_type}" != 'php' ]; then
            Echo_Red "VHOST_PRESET 仅适用于 PHP 站点，已放弃建站。"
            return 1
        fi
        site_preset="${preset}"
        echo "非交互执行，按 VHOST_PRESET=${site_preset} 使用程序预设。"
        return 0
    fi
    [ "${site_type}" = 'php' ] || return 0

    echo "请选择程序预设（只设置后续提问的默认值，仍可逐项修改）："
    echo "  1) 不使用预设"
    echo "  2) WordPress"
    echo "  3) Laravel（网站根目录为项目下的 public/）"
    while :;do
        Echo_Yellow "请选择 [1-3]（默认 1）: "
        Read_Input choice "程序预设"
        case "${choice}" in
        ''|1) site_preset='none' ;;
        2) site_preset='wordpress' ;;
        3) site_preset='laravel' ;;
        *) Echo_Red "请输入 1 到 3 之间的编号。"; continue ;;
        esac
        break
    done
    case "${site_preset}" in
    wordpress) echo "已选择 WordPress 预设。" ;;
    laravel) echo "已选择 Laravel 预设，下面输入的网站目录为项目目录。" ;;
    *) echo "不使用程序预设。" ;;
    esac
    return 0
}

# Site_Project_Dir：在 vhostdir 通过 Check_Vhost_Dir 后调用，写入 site_basedir。
# Laravel 预设把输入的目录作为项目目录，网站根目录改为其下的 public/，open_basedir 放宽到项目目录。
# public 为链接或非目录时返回 1，vhostdir 不变。
Site_Project_Dir()
{
    site_basedir="${vhostdir}"
    [ "${site_preset:-none}" = 'laravel' ] || return 0
    if [ -L "${vhostdir}/public" ] || { [ -e "${vhostdir}/public" ] && [ ! -d "${vhostdir}/public" ]; }; then
        Echo_Red "${vhostdir}/public 是符号链接或不是目录，不能作为网站根目录。"
        return 1
    fi
    vhostdir="${site_basedir}/public"
    echo "项目目录：${site_basedir}，网站根目录：${vhostdir}，open_basedir 放宽到项目目录。"
    echo "请把 Laravel 项目放在 ${site_basedir}，入口为 public/index.php；已有文件不会被移动。"
    return 0
}

# 单站点启停：停用时在站点入口配置的每个 server_name（Nginx）或 ServerName（Apache）后
# 插入带标记的 503 片段，只放行 ACME HTTP-01 验证路径；启用时删除标记片段。
# 标记即启停状态，站点其余配置、证书、网站文件与共享服务不变。

Vhost_Is_Stopped()
{
    [ -f "$1" ] && grep -q "# LNMP-VHOST-STOP-BEGIN" "$1"
}

# Vhost_Stop_Render <nginx|apache> <配置> <输出>：0 已插入；2 无锚点；3 server_name 跨行。
Vhost_Stop_Render()
{
    awk -v kind="$1" -v mark=LNMP-VHOST-STOP '
        { print }
        kind == "nginx" && /^[[:space:]]*server_name[[:space:]]/ {
            if ($0 !~ /;/) bad = 1
            match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
            print ind "# " mark "-BEGIN"
            print ind "if ($uri !~ \"^/\\.well-known/acme-challenge/\") {"
            print ind "    return 503;"
            print ind "}"
            print ind "# " mark "-END"
            n++
        }
        kind == "apache" && /^[[:space:]]*ServerName[[:space:]]/ {
            match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
            print ind "# " mark "-BEGIN"
            print ind "RewriteEngine On"
            print ind "RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/"
            print ind "RewriteRule ^ - [R=503,L]"
            print ind "# " mark "-END"
            n++
        }
        END { if (bad) exit 3; exit (n ? 0 : 2) }' "$2" > "$3"
}

# Vhost_Start_Render <配置> <输出>：删除全部标记片段；0 成功；3 标记不成对。
Vhost_Start_Render()
{
    awk -v b="# LNMP-VHOST-STOP-BEGIN" -v e="# LNMP-VHOST-STOP-END" '
        { t = $0; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t) }
        t == b { if (skip) bad = 1; skip = 1; next }
        t == e { if (!skip) bad = 1; skip = 0; next }
        !skip { print }
        END { exit ((bad || skip) ? 3 : 0) }' "$1" > "$2"
}

# Vhost_Conf_Apply <nginx|apache>：配置测试后重载运行中的服务。
# 0 已生效或服务未运行；1 配置测试失败；2 重载失败。
Vhost_Conf_Apply()
{
    local bin

    if [ "$1" = nginx ]; then
        bin=/usr/local/nginx/sbin/nginx
        "${bin}" -t || return 1
        if ! pgrep -f "${bin}" >/dev/null 2>&1; then
            echo "Nginx 未在运行，配置已写入，启动后生效。"
            return 0
        fi
        "${bin}" -s reload || return 2
    else
        bin=/usr/local/apache/bin/httpd
        "${bin}" -t || return 1
        if ! pgrep -f "${bin}" >/dev/null 2>&1; then
            echo "Apache 未在运行，配置已写入，启动后生效。"
            return 0
        fi
        Svc httpd reload || return 2
    fi
    return 0
}

# Vhost_Toggle <start|stop> <域名>：入口配置由各栈的 Vhost_Entry_Conf 给出（类型<TAB>路径）。
# 配置测试或重载失败时恢复原配置并返回 1；重复执行返回 0。
Vhost_Toggle()
{
    local action="$1" domain="$2" kind conf backup tmp rc

    if [ -z "${domain}" ]; then
        echo "用法：lnmp vhost ${action} <域名>"
        return 1
    fi
    Lower_Domain_Input domain
    Check_Domain_Name "${domain}" || return 1
    if [ "${domain}" = default ]; then
        Echo_Red "默认站点 default 不支持单独启停。"
        return 1
    fi
    IFS=$'\t' read -r kind conf < <(Vhost_Entry_Conf "${domain}")
    if [ -z "${conf}" ] || [ ! -s "${conf}" ]; then
        Echo_Red "站点 ${domain} 不存在，请使用 lnmp vhost list 中列出的站点名。"
        return 1
    fi
    if [ "${action}" = stop ] && Vhost_Is_Stopped "${conf}"; then
        echo "站点 ${domain} 已处于停用状态。"
        return 0
    fi
    if [ "${action}" = start ] && ! Vhost_Is_Stopped "${conf}"; then
        echo "站点 ${domain} 已处于启用状态。"
        return 0
    fi

    LNMP_Tmp_Init || return 1
    backup=$(LNMP_Mktemp vhost-toggle) || return 1
    if ! \cp -p "${conf}" "${backup}"; then
        rm -f "${backup}"
        Echo_Red "备份 ${conf} 失败，未做改动。"
        return 1
    fi
    # 临时文件与配置同目录，不以 .conf 结尾，不会被 vhost/*.conf 引入。
    if ! tmp=$(mktemp "${conf}.XXXXXXXX"); then
        rm -f "${backup}"
        return 1
    fi
    if [ "${action}" = stop ]; then
        Vhost_Stop_Render "${kind}" "${conf}" "${tmp}"
    else
        Vhost_Start_Render "${conf}" "${tmp}"
    fi
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        rm -f "${tmp}" "${backup}"
        case "${rc}" in
        2) Echo_Red "${conf} 中没有 server_name 或 ServerName，无法停用。" ;;
        3) Echo_Red "${conf} 的格式无法自动处理（server_name 跨行或停用标记不成对），未做改动。" ;;
        *) Echo_Red "生成 ${conf} 失败，未做改动。" ;;
        esac
        return 1
    fi
    chmod --reference="${conf}" "${tmp}" 2>/dev/null
    if ! mv -f "${tmp}" "${conf}"; then
        rm -f "${tmp}" "${backup}"
        Echo_Red "写入 ${conf} 失败，未做改动。"
        return 1
    fi

    Vhost_Conf_Apply "${kind}"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        \cp -p "${backup}" "${conf}"
        rm -f "${backup}"
        Vhost_Conf_Apply "${kind}" >/dev/null 2>&1
        if [ "${rc}" -eq 1 ]; then
            Echo_Red "配置测试未通过，已恢复 ${conf}，站点状态未变。"
        else
            Echo_Red "服务重载失败，已恢复 ${conf}，站点状态未变。"
        fi
        return 1
    fi
    rm -f "${backup}"
    if [ "${action}" = stop ]; then
        Echo_Green "站点 ${domain} 已停用：访问返回 503，ACME 验证路径保留，网站文件、证书与数据库未改动。"
    else
        Echo_Green "站点 ${domain} 已启用。"
    fi
    return 0
}

# 删站后提示证书残留，不自动删除：同一份证书可能仍被其它站点引用，
# 删错会让在线站点失去 HTTPS。只列出剩余站点都不再引用且仍在磁盘上的目录。
Report_Vhost_Cert_Residue()
{
    local conf_backup="$1" p dir base main workdir dirs='' nl=$'\n'

    [ -s "${conf_backup}" ] || return 0
    while IFS= read -r p; do
        [ -n "${p}" ] || continue
        # 只报告本包管理的证书目录，用户自备路径不提示。
        case "${p}" in
        "${Acme_Cert_Home}"/*) ;;
        *) continue ;;
        esac
        dir="${p%/*}"
        # 证书直接放在证书主目录下时，目录本身不是站点专属目录，不能作为残留报告。
        [ "${dir}" != "${Acme_Cert_Home}" ] || continue
        [ -d "${dir}" ] || continue
        case "${nl}${dirs}${nl}" in
        *"${nl}${dir}${nl}"*) continue ;;
        esac
        Cert_Dir_In_Use "${dir}" && continue
        dirs="${dirs:+${dirs}${nl}}${dir}"
    done <<EOF
$(Vhost_Cert_Paths "${conf_backup}")
EOF
    [ -n "${dirs}" ] || return 0

    echo
    Echo_Yellow "以下证书文件已不被任何站点引用，未自动删除："
    echo
    while IFS= read -r dir; do
        [ -n "${dir}" ] || continue
        echo "  ${dir}/"
        base="${dir##*/}"
        # 泛域名的证书目录名把 *. 换成了 _wildcard.，acme.sh 台账里仍是 *. 开头。
        main="${base/#_wildcard./*.}"
        workdir="${Acme_Cert_Home}/${main}_ecc"
        [ -d "${workdir}" ] || continue
        echo "  ${workdir}/"
        Echo_Yellow "  acme.sh 仍会为 ${main} 续期，停止续期："
        echo
        echo "    . /usr/local/acme.sh/acme.sh.env"
        printf "    /usr/local/acme.sh/acme.sh --remove -d '%s' --ecc\n" "${main}"
    done <<EOF
${dirs}
EOF
    Echo_Yellow "确认不再使用后手工删除上面列出的目录。"
    echo
    return 0
}

First_Executable()
{
    local candidate

    for candidate in "$@"; do
        if [ -x "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

Check_DB()
{
    local found kind dir client config

    if found=$(Db_Detect); then
        IFS=$'\t' read -r kind dir client config <<< "${found}"
        MySQL_Bin="${client}"
        MySQL_Ver=$("${config}" --version)
    else
        MySQL_Bin="None"
    fi
}

# 按 / 拆解并消除 . 与 ..，只做文本规范化，不访问文件系统。
Normalize_Fs_Path()
{
    local path="$1" part out=""
    local IFS=/

    for part in ${path}; do
        case "${part}" in
        ''|.) ;;
        ..)   out="${out%/*}" ;;
        *)    out="${out}/${part}" ;;
        esac
    done
    printf '%s' "${out:-/}"
}

# mysqld 把相对 log_error 解释为相对 datadir。不解析会按当前工作目录判断权限
# 并读错日志位置。解析结果越出 datadir 时提示并返回 1，由调用方跳过日志检查。
# 提示写 stderr，避免被命令替换吞掉。
Resolve_DB_Log_Error()
{
    local logerror="$1" datadir="$2" base resolved

    [ -n "${logerror}" ] || return 0
    case "${logerror}" in
    /*) Normalize_Fs_Path "${logerror}"; return 0 ;;
    esac
    if [ -z "${datadir}" ]; then
        Echo_Yellow "log_error=${logerror} 为相对路径且未配置 datadir，无法定位错误日志。" >&2
        echo >&2
        return 1
    fi
    base=$(Normalize_Fs_Path "${datadir}")
    resolved=$(Normalize_Fs_Path "${base}/${logerror}")
    case "${resolved}" in
    "${base}"/*) printf '%s' "${resolved}"; return 0 ;;
    esac
    Echo_Yellow "log_error=${logerror} 解析为 ${resolved}，越出数据目录 ${base}，不做检查。" >&2
    echo >&2
    return 1
}

# 数据库启动失败时给出可操作的原因。datadir 或错误日志对运行账号不可写时，
# 服务端在打开错误日志前就退出，日志文件里不留任何记录，systemd 只显示
# init 脚本的 ERROR!，需要在这里补出真实原因。
# 数据库 init 脚本可能被发行版包（如 apt 的 mariadb-server / mysql-server）覆盖：
# 覆盖后脚本指向系统路径，start 会返回 0 但服务起不来，容易被误判为数据丢失。
# 本函数只判断脚本归属，不改动任何文件。
Check_DB_Init_Script_Integrity()
{
    local initd="/etc/init.d/${DB_Name}" prefix

    [ -f "${initd}" ] || return 0
    case "${DB_Name}" in
    mysql)   prefix="/usr/local/mysql" ;;
    mariadb) prefix="/usr/local/mariadb" ;;
    *) return 0 ;;
    esac
    grep -q "${prefix}" "${initd}" && return 0

    Echo_Red "${initd} 已不再指向 ${prefix}，很可能被系统包（apt/yum 的 mariadb-server、mysql-server）覆盖。"
    Echo_Red "数据目录不受影响，数据仍在；只是启动脚本被换掉，start 可能返回 0 却起不来。"
    Echo_Yellow "恢复方式："
    echo
    echo "  cp ${prefix}/support-files/mysql.server ${initd}"
    echo "  chmod 755 ${initd}"
    echo "  systemctl daemon-reload && systemctl start ${DB_Name}"
    Echo_Yellow "同时建议卸载系统包，避免 mysql.service 被别名到 mariadb.service："
    echo
    echo "  apt-get purge 'mariadb-server*' 'mysql-server*'"
    return 1
}

# nginx 与 httpd 的启动或重载失败多半出在配置上，直接给出配置测试结果，
# 免得只看到退出码还要再手工跑一遍。
Diagnose_Web_Start_Failure()
{
    local service="$1" tester='' result

    result=$(systemctl show -p Result --value "${service}.service" 2>/dev/null)
    if [ "${result}" = "start-limit-hit" ]; then
        echo "短时间内启动次数过多，systemd 已限流并拒绝本次启动。"
        echo "排除启动失败原因后执行：systemctl reset-failed ${service}.service"
        return 0
    fi

    case "${service}" in
    nginx)
        [ -x /usr/local/nginx/sbin/nginx ] && tester='/usr/local/nginx/sbin/nginx -t'
        ;;
    httpd)
        [ -x /usr/local/apache/bin/apachectl ] && tester='/usr/local/apache/bin/apachectl -t'
        ;;
    esac
    [ -n "${tester}" ] || return 0

    echo "配置测试结果："
    ${tester} 2>&1 | sed 's/^/  /'
    echo "配置无误仍启动失败时，查看：journalctl -xeu ${service}.service"
    return 0
}

Diagnose_DB_Start_Failure()
{
    local action="${1:-start}" conf="${2:-/etc/my.cnf}"
    local db_user db_group datadir logerror target probe unwritable=0

    case "${action}" in
    start|restart) ;;
    *) return 0 ;;
    esac
    # 脚本归属异常时先给出结论，避免把"被换掉的启动脚本"误判成数据问题。
    Check_DB_Init_Script_Integrity || return 1
    [ -s "${conf}" ] || return 1

    db_user=$(Db_Conf_Value user "${conf}")
    datadir=$(Db_Conf_Value datadir "${conf}")
    logerror=$(Db_Conf_Value log_error "${conf}")
    if [ -n "${logerror}" ]; then
        logerror=$(Resolve_DB_Log_Error "${logerror}" "${datadir}") || logerror=""
    fi

    if [ -n "${db_user}" ] && id "${db_user}" >/dev/null 2>&1 &&
       command -v runuser >/dev/null 2>&1; then
        db_group=$(id -gn "${db_user}" 2>/dev/null) || db_group="${db_user}"
        for target in "${datadir}" "${logerror}"; do
            [ -n "${target}" ] || continue
            probe="${target}"
            # 首次启动时错误日志尚未生成，改判其父目录：父目录不可写同样会让
            # 服务端在打开日志前退出，日志文件里不会留下任何记录。
            if [ ! -e "${probe}" ]; then
                probe="${probe%/*}"
                [ -n "${probe}" ] && [ -d "${probe}" ] || continue
            fi
            runuser -u "${db_user}" -- test -w "${probe}" 2>/dev/null && continue
            Echo_Red "${probe} 对数据库运行账号 ${db_user} 不可写。"
            unwritable=1
        done
        if [ ${unwritable} -eq 1 ]; then
            # Echo_Yellow 不输出换行，提示后需要补一个换行再列修复命令。
            Echo_Yellow "数据库进程无法写入数据目录或错误日志，修复属主后重新启动："
            echo
            [ -n "${datadir}" ] && echo "  chown -R ${db_user}:${db_group} ${datadir}"
            case "${logerror}" in
            ''|"${datadir}"/*) ;;
            *) echo "  chown ${db_user}:${db_group} ${logerror}" ;;
            esac
            return 1
        fi
    fi

    if [ -n "${logerror}" ] && [ -s "${logerror}" ]; then
        Echo_Yellow "数据库错误日志末尾（${logerror}）："
        echo
        tail -n 15 "${logerror}"
    fi
    return 1
}

Make_TempMycnf()
{
    local pw sock
    # MySQL option file 会解析反斜杠转义，写入前需转义反斜杠以保持密码原值。
    # 单引号仅用于包围字段值，密码内部的单引号无需另行处理。
    pw="${1//\\/\\\\}"
    sock=$(Db_Socket)
    # 管理员已有的 ~/.my.cnf 会在凭据清理时恢复。
    if [ -s ~/.my.cnf ] && [ ! -e ~/.my.cnf.lnmp-bak ]; then
        cp -p ~/.my.cnf ~/.my.cnf.lnmp-bak
    fi
    umask 077
    cat >~/.my.cnf<<EOF
[client]
user=root
password='${pw}'
socket=${sock}
EOF
    chmod 600 ~/.my.cnf
    # 标记临时凭据，确保退出时清理。
    LNMP_Mycnf_Owned=1
    LNMP_Set_Trap
}

# 强制通过 TCP 校验口令：root@localhost 使用 unix_socket 认证时，
# socket 连接对任意口令都会成功，结果不能反映口令是否正确。
# 返回值：0 口令正确；1 口令错误；2 无法通过 TCP 连接。
Check_DB_Password_TCP()
{
    local port err rc

    Check_DB
    [ "${MySQL_Bin}" = "None" ] && return 2
    port=$(Db_Port)
    err=$(${MySQL_Bin} --defaults-file="${HOME}/.my.cnf" \
        --protocol=TCP --host=127.0.0.1 --port="${port}" \
        --connect-timeout=5 -e 'SELECT 1' 2>&1 >/dev/null)
    rc=$?
    [ ${rc} -eq 0 ] && return 0
    case "${err}" in
    *"ERROR 1045"*|*"Access denied"*) return 1 ;;
    esac
    return 2
}

# EXIT trap 同时清理临时目录和数据库凭据，覆盖异常退出路径。
LNMP_Cleanup()
{
    Restore_Cert_Dir
    if [ -n "${LNMP_Tmp_Dir}" ]; then
        rm -rf "${LNMP_Tmp_Dir}"
        LNMP_Tmp_Dir=""
    fi
    TempMycnf_Clean
}

# INT/TERM 需要显式退出，确保中断倒计时后进入 EXIT 清理。
# trap 只能在主 shell 注册，防止子 shell 提前清理主流程仍在使用的文件。
LNMP_Set_Trap()
{
    trap 'LNMP_Cleanup' EXIT
    trap 'echo; exit 130' INT TERM HUP
}

# 临时目录必须在当前 shell 初始化，使主流程和 EXIT trap 使用同一路径。
LNMP_Tmp_Init()
{
    [ -n "${LNMP_Tmp_Dir}" ] && return 0
    LNMP_Tmp_Dir=$(mktemp -d /tmp/.lnmp-adm.XXXXXXXX) || return 1
    chmod 700 "${LNMP_Tmp_Dir}"
    LNMP_Set_Trap
    return 0
}

# 调用前需要完成 LNMP_Tmp_Init。
LNMP_Mktemp()
{
    [ -n "${LNMP_Tmp_Dir}" ] || return 1
    mktemp "${LNMP_Tmp_Dir}/$1.XXXXXXXX"
}

# MySQL 字符串先转义反斜杠，再转义单引号，避免重复处理新增的转义符。
Sql_Quote()
{
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\'/\\\'}"
    printf '%s' "${v}"
}

# 数据库名和用户名使用字符白名单，防止标识符构造为非法 SQL。
Check_DB_Identifier()
{
    case "$1" in
    ''|*[!A-Za-z0-9_]*)
        Echo_Red "名称 '$1' 不合法：只允许字母、数字和下划线，且不能为空。"
        return 1
        ;;
    esac
    if [ ${#1} -gt 32 ]; then
        Echo_Red "名称过长（超过 32 字符）。"
        return 1
    fi
    return 0
}

# 检测 EOF，防止非交互输入耗尽后校验循环空转。
Read_Input()
{
    local __var="$1" __what="$2"
    [ -n "${__what}" ] || printf -v __what '输入'
    # 变量名由调用方给出，此处是有意的间接读取。
    # shellcheck disable=SC2229
    if ! read -r "${__var}"; then
        echo
        Echo_Red "读取${__what}时遇到 EOF —— 标准输入已经没有内容了。"
        Echo_Red "若你用管道或重定向提供输入，请核对输入项的数量与顺序："
        Echo_Red "少喂一项就会走到这里。交互执行本命令则不会有此问题。"
        exit 1
    fi
}

# 读取不回显的密码，并检测 EOF。
Read_Secret()
{
    local __var="$1" __what="$2"
    [ -n "${__what}" ] || printf -v __what '密码'
    # shellcheck disable=SC2229
    if ! read -r -s "${__var}"; then
        echo
        Echo_Red "读取${__what}时遇到 EOF —— 标准输入已经没有内容了。"
        exit 1
    fi
}

# 严格读取 y/n：接受 y/yes/n/no（不分大小写），空输入取默认值，
# 其它输入在原问题处重问，EOF 由 Read_Input 终止，不按默认值继续。
Read_YN()
{
    local __var="$1" __prompt="$2" __def="$3" __what="$4" __in
    [ -n "${__what}" ] || printf -v __what '选择'
    while :;do
        Echo_Yellow "${__prompt}"
        Read_Input __in "${__what}"
        case "${__in}" in
        "")                 __in="${__def}" ;;
        [yY]|[yY][eE][sS])  __in="y" ;;
        [nN]|[nN][oO])      __in="n" ;;
        *)
            Echo_Red "只接受 y 或 n（也可写 yes/no），直接回车使用默认值 ${__def}。"
            continue
            ;;
        esac
        printf -v "${__var}" '%s' "${__in}"
        return 0
    done
}

# 执行前的最后确认：真实终端按任意键；非交互从标准输入读一行，
# 输入耗尽（EOF）或终端操作失败时返回非 0，调用方须放弃本次变更。
Press_Any_Key_Or_Line()
{
    local __old __discard
    echo ""
    echo "$1"
    if [ ! -t 0 ]; then
        if ! read -r __discard; then
            echo
            Echo_Red "读取确认时遇到 EOF —— 标准输入已经没有内容了，已取消。"
            return 1
        fi
        return 0
    fi
    __old=$(stty -g) || { Echo_Red "读取终端状态失败，已取消。"; return 1; }
    if ! stty -icanon -echo min 1 time 0; then
        Echo_Red "设置终端状态失败，已取消。"
        return 1
    fi
    if ! dd bs=1 count=1 >/dev/null 2>&1; then
        stty "${__old}"
        Echo_Red "读取确认按键失败，已取消。"
        return 1
    fi
    stty "${__old}"
    echo
    return 0
}

# DNS 不区分大小写，域名统一转小写后再比对、写配置和申请证书。
Lower_Domain_Input()
{
    local var="$1" value="${!1}"

    printf -v "${var}" '%s' "${value,,}"
}

# 泛域名不能作为站点名，站点必须是具体域名。
Reject_Wildcard_Site()
{
    local d

    set -f
    for d in $1; do
        case "${d}" in
        \*.*)
            set +f
            Echo_Red "不能用泛域名建立网站：${d}"
            Echo_Yellow "请先用具体子域名建站，再执行 lnmp dnsssl <服务商> 输入 ${d} 申请泛域名证书。"
            echo
            return 1
            ;;
        esac
    done
    set +f
    return 0
}

# DNS 名称可带前导泛域名标记，但不能包含路径分隔符、空白或配置元字符。
# default 指内置兜底站点，由调用方决定是否接受。
Check_Domain_Name()
{
    local d="$1"
    if [ -z "${d}" ]; then
        Echo_Red "域名不能为空。"
        return 1
    fi

    if [ "${d}" = "default" ]; then
        return 0
    fi
    if [ ${#d} -gt 253 ]; then
        Echo_Red "域名过长（超过 253 字符）：${d}"
        return 1
    fi
    # 泛域名前缀不参与 DNS 标签格式校验。
    case "${d}" in
    \*.*) d="${d#\*.}" ;;
    esac
    if ! printf '%s' "${d}" \
        | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; then
        Echo_Red "域名不合法：'$1'"
        Echo_Red "只接受形如 example.com / www.example.com / *.example.com 的名字，"
        Echo_Red "不接受路径分隔符、空白以及 ; { } \$ 等配置元字符。"
        return 1
    fi
    return 0
}

# default 是安装时生成的兜底站点，删除后未匹配的请求失去落点。
Reject_Default_Site_Del()
{
    [ "$1" = "default" ] || return 0
    Echo_Red "default 是内置兜底站点，不能删除。"
    return 1
}

# 附加域名按空格分隔，任一名称无效时拒绝整组输入。
Check_More_Domains()
{
    local d
    for d in $1; do
        Check_Domain_Name "${d}" || return 1
        if [ "${d}" = "default" ]; then
            Echo_Red "default 是内置兜底站点名，不能作为附加域名。"
            return 1
        fi
    done
    return 0
}

# 附加域名与主域名或彼此重复会写出重复的 server_name/ServerAlias，
# reload 时 Web 服务会报 conflicting server name。
Check_More_Domains_Unique()
{
    local main="$1" d seen=''

    # 附加域名可能含泛域名，拆词前关闭通配符展开。
    set -f
    for d in $2; do
        if [ "${d}" = "${main}" ]; then
            set +f
            Echo_Red "附加域名 ${d} 与主域名重复，请重新输入。"
            return 1
        fi
        case " ${seen} " in
            *" ${d} "*)
                set +f
                Echo_Red "附加域名 ${d} 重复出现，请重新输入。"
                return 1
                ;;
        esac
        seen="${seen:+${seen} }${d}"
    done
    set +f
    return 0
}

# rewrite 与日志名会成为文件名或配置片段，只允许单个安全文件名。
Check_Config_Name()
{
    local value="$1" what="$2"
    [ -n "${what}" ] || printf -v what '配置名称'
    if [ -z "${value}" ] || [ "${value}" = '.' ] || [ "${value}" = '..' ] \
       || [[ ! "${value}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        Echo_Red "${what}不合法：'${value}'"
        Echo_Red "只允许字母、数字、点、下划线和连字符，不允许路径或配置元字符。"
        return 1
    fi
    return 0
}

# 邮箱域名按标签校验：每个标签必须以字母或数字开头和结尾，连续点、首尾点
# 以及以连字符开头或结尾的标签都会被拒绝。
Check_EMail_Format()
{
    local value="$1"
    [[ "${value}" =~ ^[A-Za-z0-9_%+-]+(\.[A-Za-z0-9_%+-]+)*@([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

Check_Server_Admin_Email()
{
    local value="$1"
    if ! Check_EMail_Format "${value}"; then
        Echo_Red "管理员邮箱格式无效：'${value}'"
        return 1
    fi
    return 0
}

# Web 配置中的证书路径不加 shell 转义，必须是已存在且无配置元字符的绝对路径。
Check_Config_File_Path()
{
    local value="$1" what="$2"
    [ -n "${what}" ] || printf -v what '配置文件'
    if [[ ! "${value}" =~ ^/[A-Za-z0-9._/+@,:=-]+$ ]] \
       || [[ "/${value#/}/" == *'/../'* ]] \
       || [[ "/${value#/}/" == *'/./'* ]] \
       || [[ "${value}" == *'//'* ]]; then
        Echo_Red "${what}必须是无空白和配置元字符的绝对路径：'${value}'"
        return 1
    fi
    if [ ! -s "${value}" ]; then
        Echo_Red "${what}不存在或为空：'${value}'"
        return 1
    fi
    return 0
}

# 站点目录必须是无元字符的绝对路径，并位于允许的网站根目录内。
# 该限制防止递归 chmod 或 chown 影响系统目录及其它用户数据。
Check_Vhost_Dir()
{
    local d="$1" norm root ok='n'
    local matched_root='' rest probe comp resolved rroot

    if [ -z "${d}" ]; then
        Echo_Red "目录不能为空。"
        return 1
    fi
    case "${d}" in
    /*) : ;;
    *)
        Echo_Red "目录必须是绝对路径：'${d}'"
        return 1
        ;;
    esac
    if printf '%s' "${d}" | grep -Eq '[[:space:]`$;&|<>*?"'"'"'\\]'; then
        Echo_Red "目录名含空白或 shell 元字符，拒绝：'${d}'"
        return 1
    fi

    # 规范化路径，不要求目标已经存在。
    norm=$(printf '%s' "${d}" | sed -e 's#/\+#/#g' -e 's#/\./#/#g' -e 's#/$##')
    # 归一化会把 / 抹成空串，单独判掉，否则报错里显示的是空目录名。
    if [ -z "${norm}" ]; then
        Echo_Red "不能使用根目录 '${d}'，请指定它下面的子目录。"
        return 1
    fi
    case "${norm}" in
    *..*)
        Echo_Red "目录不能包含 .. ：'${d}'"
        return 1
        ;;
    esac

    for root in /home /var/www /srv /data /www; do
        case "${norm}/" in
        "${root}"/*) ok='y'; matched_root="${root}"; break ;;
        esac
    done
    if [ "${ok}" != 'y' ]; then
        Echo_Red "目录 '${d}' 不在允许的根目录之下。"
        Echo_Red "允许：/home /var/www /srv /data /www"
        Echo_Red "（限制它是因为随后要对该目录执行 chmod -R / chown -R，"
        Echo_Red "  打到 / 或 /usr 上是不可逆的。）"
        return 1
    fi

    # 网站必须位于允许根的子目录，避免递归授权整个根目录。
    if [ "${norm}" = "${matched_root}" ]; then
        Echo_Red "不能直接用 '${norm}'，请在它下面建子目录。"
        Echo_Red "（随后的 chown -R 会作用于整个目录树。）"
        return 1
    fi

    # 逐级拒绝子路径中的符号链接，防止递归授权越过允许目录边界。
    # 允许根本身可由管理员配置为符号链接。
    rest="${norm#${matched_root}/}"
    probe="${matched_root}"
    while [ -n "${rest}" ]; do
        comp="${rest%%/*}"
        if [ "${comp}" = "${rest}" ]; then rest=''; else rest="${rest#*/}"; fi
        probe="${probe}/${comp}"
        if [ -L "${probe}" ]; then
            Echo_Red "路径组件 '${probe}' 是符号链接，拒绝使用该目录。"
            Echo_Red "（递归改权限会跟着链接跑到目录树之外去。）"
            return 1
        fi
    done

    # realpath 解析后的路径仍需位于解析后的允许根目录内。
    # realpath -m 支持尚未创建的目标路径。
    if command -v realpath >/dev/null 2>&1; then
        resolved=$(realpath -m "${norm}" 2>/dev/null) || resolved="${norm}"
        ok='n'
        for root in /home /var/www /srv /data /www; do
            rroot=$(realpath -m "${root}" 2>/dev/null) || rroot="${root}"
            case "${resolved}/" in
            "${rroot}"/*) ok='y'; break ;;
            esac
        done
        if [ "${ok}" != 'y' ]; then
            Echo_Red "'${norm}' 解析后指向 '${resolved}'，不在允许的根目录之下，拒绝。"
            return 1
        fi
    fi

    vhostdir="${norm}"
    return 0
}

Do_Query()
{
    local sql_file rc
    # 临时目录创建失败属于环境错误，不能作为密码校验失败重试。
    LNMP_Tmp_Init || exit 1
    sql_file=$(LNMP_Mktemp query) || exit 1
    chmod 600 "${sql_file}"
    printf '%s\n' "$1" > "${sql_file}"
    Check_DB
    ${MySQL_Bin} --defaults-file="${HOME}/.my.cnf" < "${sql_file}"
    rc=$?
    rm -f "${sql_file}"
    return ${rc}
}

# 仅清理临时生成的凭据，避免删除管理员已有的 ~/.my.cnf。
# 清理函数可重复调用，不会重复恢复备份。
TempMycnf_Clean()
{
    [ "${LNMP_Mycnf_Owned}" -eq 1 ] || return 0
    LNMP_Mycnf_Owned=0
    rm -f ~/.my.cnf
    # 恢复安装前备份的客户端配置。
    if [ -e ~/.my.cnf.lnmp-bak ]; then
        mv -f ~/.my.cnf.lnmp-bak ~/.my.cnf
    fi
}

Enter_Database_Name()
{
    while :;do
        Echo_Yellow "请输入数据库名（只允许字母、数字和下划线）: "
        Read_Input database_name "数据库名"
        Check_DB_Identifier "${database_name}" || continue
        if [ "${database_name}" == "" ]; then
            Echo_Red "数据库名不能为空。"
        else
            break
        fi
    done
}

# 建库前确认数据库与两个 host 用户都不存在。
# 查询失败与"存在"必须区分：返回 2 表示无法判断，不能当作可以继续创建。
Database_Object_Exists()
{
    local out
    out=$(${MySQL_Bin} --defaults-file="${HOME}/.my.cnf" -N -B -e "$1" 2>/dev/null) || return 2
    [ -n "${out}" ]
}

# database add 只用于新建；命中已有对象时返回非 0，不改动任何认证信息。
Check_Database_Absent()
{
    local name="$1" host rc conflict=""

    Check_DB_Identifier "${name}" || return 1

    Database_Object_Exists "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${name}';"
    rc=$?
    if [ ${rc} -eq 2 ]; then
        Echo_Red "无法查询数据库 ${name} 是否已存在，已中止。"
        return 1
    fi
    [ ${rc} -eq 0 ] && conflict="数据库 ${name}"

    for host in localhost 127.0.0.1; do
        Database_Object_Exists "SELECT 1 FROM mysql.user WHERE User='${name}' AND Host='${host}';"
        rc=$?
        if [ ${rc} -eq 2 ]; then
            Echo_Red "无法查询数据库用户 ${name}@${host} 是否已存在，已中止。"
            return 1
        fi
        [ ${rc} -eq 0 ] && conflict="${conflict}${conflict:+，}用户 ${name}@${host}"
    done

    if [ -n "${conflict}" ]; then
        Echo_Red "已存在：${conflict}"
        Echo_Red "database add 只负责新建，继续会改掉现有账号的密码，让在用站点连不上数据库。"
        Echo_Red "改密码请执行 lnmp database edit；确认不再需要旧库可执行 lnmp database del 后重建；"
        Echo_Red "或换一个数据库名。"
        return 1
    fi
    return 0
}

Add_Database_Menu()
{
    Enter_Database_Name
    # 先确认是新建而不是覆盖，避免收集完密码才在写库阶段破坏既有账号。
    Check_Database_Absent "${database_name}" || return 1
    echo "将创建数据库及同名数据库用户：${database_name}"
    Echo_Yellow "请输入数据库用户 ${database_name} 的密码（输入不回显）: "
    Read_Secret mysql_password "数据库用户密码"
    echo
    if [ -z "${mysql_password}" ]; then
        Echo_Red "密码不能为空。"
        return 1
    fi
    return 0
}

Add_Database()
{
    local sql_file mysql_password_q rc
    Check_DB_Identifier "${database_name}" || return 1
    mysql_password_q=$(Sql_Quote "${mysql_password}")
    LNMP_Tmp_Init || return 1
    sql_file=$(LNMP_Mktemp add_db) || return 1
    chmod 600 "${sql_file}"

    # 建库语句兼容当前 MySQL 和 MariaDB，并支持失败后重复执行。
    cat >"${sql_file}"<<EOF
CREATE USER IF NOT EXISTS '${database_name}'@'localhost' IDENTIFIED BY '${mysql_password_q}';
CREATE USER IF NOT EXISTS '${database_name}'@'127.0.0.1' IDENTIFIED BY '${mysql_password_q}';
GRANT USAGE ON *.* TO '${database_name}'@'localhost';
GRANT USAGE ON *.* TO '${database_name}'@'127.0.0.1';
CREATE DATABASE IF NOT EXISTS \`${database_name}\`;
GRANT ALL PRIVILEGES ON \`${database_name}\`.* TO '${database_name}'@'localhost';
GRANT ALL PRIVILEGES ON \`${database_name}\`.* TO '${database_name}'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF

    ${MySQL_Bin} --defaults-file="${HOME}/.my.cnf" < "${sql_file}"
    rc=$?
    rm -f "${sql_file}"
    if [ ${rc} -ne 0 ]; then
        Echo_Red "数据库创建失败。"
        return ${rc}
    fi
    echo "数据库创建成功。"
    return 0
}

List_Database()
{
    local rc
    ${MySQL_Bin} --defaults-file="${HOME}/.my.cnf" -e "SHOW DATABASES;"
    rc=$?
    if [ ${rc} -ne 0 ]; then
        Echo_Red "数据库列表读取失败。"
        return ${rc}
    fi
    echo "数据库列表读取成功。"
    return 0
}

Edit_Database()
{
    local pass_q
    while :;do
        Echo_Yellow "请输入数据库用户名（只允许字母、数字和下划线）: "
        Read_Input database_username "数据库用户名"
        Check_DB_Identifier "${database_username}" || continue
        break
    done
    while :;do
        Echo_Yellow "请输入新密码（输入不回显）: "
        Read_Secret database_username_passwd "新密码"
        echo
        if [ "${database_username_passwd}" == "" ]; then
            Echo_Red "数据库密码不能为空。"
        else
            break
        fi
    done
    pass_q=$(Sql_Quote "${database_username_passwd}")

    # 三条语句一次执行，确保任一主机授权失败都会返回错误。
    if ! Do_Query "ALTER USER '${database_username}'@'localhost' IDENTIFIED BY '${pass_q}';
ALTER USER '${database_username}'@'127.0.0.1' IDENTIFIED BY '${pass_q}';
FLUSH PRIVILEGES;"; then
        Echo_Red "数据库用户密码修改失败。"
        return 1
    fi
    echo "数据库用户密码修改成功。"
    return 0
}

Check_Dump_Bin()
{
    if [ "${MySQL_Bin}" == "None" ]; then
        Echo_Red "未检测到已安装的 MySQL/MariaDB。"
        return 1
    fi
    MySQL_Dump_Bin=$(First_Executable \
        "$(dirname "${MySQL_Bin}")/mariadb-dump" \
        "$(dirname "${MySQL_Bin}")/mysqldump")
    if [ -z "${MySQL_Dump_Bin}" ]; then
        Echo_Red "找不到可执行的数据库导出程序。"
        return 1
    fi
    return 0
}

# 通过 information_schema 精确匹配库名，避免下划线被 LIKE 解释为通配符。
Database_Exists()
{
    local name_q out
    name_q=$(Sql_Quote "$1")
    out=$(${MySQL_Bin} --defaults-file="${HOME}/.my.cnf" -N -B -e \
        "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${name_q}';") || return 1
    [ -n "${out}" ]
}

# 备份文件的父目录必须存在，目标只能是普通文件路径。
Check_Backup_Path()
{
    local f="$1" dir
    if [ -z "${f}" ]; then
        Echo_Red "备份文件路径不能为空。"
        return 1
    fi
    case "${f}" in
        */)
            Echo_Red "备份文件路径不能以 / 结尾：${f}"
            return 1
            ;;
    esac
    dir=$(dirname -- "${f}")
    if [ ! -d "${dir}" ]; then
        Echo_Red "目录不存在：${dir}"
        return 1
    fi
    if [ -e "${f}" ] && [ ! -f "${f}" ]; then
        Echo_Red "目标已存在且不是普通文件：${f}"
        return 1
    fi
    return 0
}

Export_Database()
{
    local database_name="$1" out_file="$2" tmp_file dump_rc gzip_rc pipe_st

    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "用法：lnmp database export <数据库名> <文件.sql.gz>"
        return 1
    fi
    Check_DB_Identifier "${database_name}" || return 1
    Check_Backup_Path "${out_file}" || return 1
    if [ -e "${out_file}" ]; then
        Echo_Red "文件已存在，不覆盖：${out_file}"
        Echo_Red "请换一个文件名，或自行删除旧文件后重试。"
        return 1
    fi
    Check_Dump_Bin || return 1
    if ! Database_Exists "${database_name}"; then
        Echo_Red "数据库不存在：${database_name}"
        return 1
    fi

    # 先写入同目录临时文件再原子改名，失败时不会留下不完整的备份文件。
    tmp_file=$(mktemp "${out_file}.lnmp-part.XXXXXXXX") || {
        Echo_Red "无法在目标目录创建临时文件：${out_file}"
        return 1
    }
    echo "正在导出数据库 ${database_name} ..."
    ${MySQL_Dump_Bin} --defaults-file="${HOME}/.my.cnf" \
        --max-allowed-packet=1G --single-transaction --quick --routines --triggers --events \
        --default-character-set=utf8mb4 \
        "${database_name}" | gzip -c > "${tmp_file}"
    # 一次性保存 PIPESTATUS，确保导出和压缩任一失败都能被识别。
    pipe_st=("${PIPESTATUS[@]}")
    dump_rc=${pipe_st[0]}
    gzip_rc=${pipe_st[1]}
    if [ "${dump_rc}" -ne 0 ] || [ "${gzip_rc}" -ne 0 ]; then
        rm -f "${tmp_file}"
        Echo_Red "数据库 ${database_name} 导出失败（mysqldump=${dump_rc}，gzip=${gzip_rc}）。"
        return 1
    fi
    if ! mv -f "${tmp_file}" "${out_file}"; then
        rm -f "${tmp_file}"
        Echo_Red "写入备份文件失败：${out_file}"
        return 1
    fi
    chmod 600 "${out_file}"
    # 导出的备份应当只涉及本库；含跨库引用时提前告知，避免恢复时才发现要额外确认。
    if [ -x /bin/lnmp-sqlguard ] && ! /bin/lnmp-sqlguard check "${database_name}" "${out_file}" >/dev/null 2>&1; then
        Echo_Yellow "提示：该库的导出内容含跨库引用（如视图或触发器指向其它库）。"
        Echo_Yellow "导入这份文件时需要显式确认，详见 lnmp-sqlguard report ${database_name} ${out_file}"
    fi
    echo "数据库 ${database_name} 导出成功。"
    echo "备份文件：${out_file}"
    return 0
}

# 导入用 root 客户端执行文件里的全部 SQL，跨库或管理级语句会越过目标库边界。
# 因此导入前必须先做边界检查；检查器缺失时拒绝导入，不做静默降级。
Check_Import_Sql_Boundary()
{
    local target="$1" file="$2" bin="/bin/lnmp-sqlguard"

    if [ ! -x "${bin}" ]; then
        Echo_Red "找不到 ${bin}，无法确认备份文件只影响数据库 ${target}，已拒绝导入。"
        Echo_Red "可从源码目录补装："
        Echo_Red "  cp tools/lnmp-sqlguard.sh /bin/lnmp-sqlguard && chmod +x /bin/lnmp-sqlguard"
        return 1
    fi

    "${bin}" check "${target}" "${file}" && return 0

    Echo_Red "该文件包含越出数据库 ${target} 的语句，导入会改动目标库以外的数据，已拒绝。"
    Echo_Red "确认这些语句确实需要执行时（例如用 --databases 导出的整库备份），显式声明后重试："
    Echo_Red "  LNMP_Import_Allow_Cross_Db=yes lnmp database import ${target} <文件>"
    return 1
}

Import_Database()
{
    local database_name="$1" in_file="$2" rc gz_rc mysql_rc pipe_st

    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "用法：lnmp database import <数据库名> <文件.sql.gz>"
        return 1
    fi
    Check_DB_Identifier "${database_name}" || return 1
    if [ ! -f "${in_file}" ]; then
        Echo_Red "备份文件不存在或不是普通文件：${in_file}"
        return 1
    fi
    if [ ! -r "${in_file}" ] || [ ! -s "${in_file}" ]; then
        Echo_Red "备份文件不可读或为空：${in_file}"
        return 1
    fi
    # 导入不自动建库，避免生成没有对应用户和授权的数据库。
    if ! Database_Exists "${database_name}"; then
        Echo_Red "数据库不存在：${database_name}"
        Echo_Red "请先执行 lnmp database add 建库建用户，再导入。"
        return 1
    fi

    if [ "${LNMP_Import_Allow_Cross_Db:-}" = "yes" ]; then
        Echo_Yellow "已显式允许跨库语句（LNMP_Import_Allow_Cross_Db=yes），跳过边界检查。"
    else
        Check_Import_Sql_Boundary "${database_name}" "${in_file}" || return 1
    fi

    Echo_Yellow "导入会覆盖数据库 ${database_name} 中的同名表，且无法撤销。"

    echo
    echo "10 秒后继续，按 Ctrl+C 可取消..."
    Sleep_Sec 10

    echo "正在导入数据库 ${database_name} ..."
    # 按文件内容识别压缩格式，未压缩的 SQL 文件也可直接导入。
    if gzip -t "${in_file}" 2>/dev/null; then
        gzip -dc "${in_file}" | ${MySQL_Bin} --defaults-file="${HOME}/.my.cnf" \
            --max-allowed-packet=1G --default-character-set=utf8mb4 "${database_name}"
        pipe_st=("${PIPESTATUS[@]}")
        gz_rc=${pipe_st[0]}
        mysql_rc=${pipe_st[1]}
        rc=0
        [ "${gz_rc}" -ne 0 ] && rc=1
        [ "${mysql_rc}" -ne 0 ] && rc=1
    else
        ${MySQL_Bin} --defaults-file="${HOME}/.my.cnf" \
            --max-allowed-packet=1G --default-character-set=utf8mb4 "${database_name}" < "${in_file}"
        rc=$?
    fi
    if [ "${rc}" -ne 0 ]; then
        Echo_Red "数据库 ${database_name} 导入失败。"
        return 1
    fi
    echo "数据库 ${database_name} 导入成功。"
    return 0
}

Enter_Ftp_Name()
{
    while :;do
        Echo_Yellow "请输入 FTP 账号名（只允许字母、数字和下划线）: "
        Read_Input ftp_account_name "FTP 账号名"
        # 账号名用于临时路径和 pure-pw 参数，因此必须限制字符集。
        if ! Check_DB_Identifier "${ftp_account_name}"; then
            continue
        else
            break
        fi
    done
}

Add_Ftp_Menu()
{
    Enter_Ftp_Name
    while :;do
        Echo_Yellow "请输入 FTP 账号 ${ftp_account_name} 的密码（输入不回显）: "
        Read_Secret ftp_account_password "FTP 密码"
        echo
        if [ "${ftp_account_password}" == "" ]; then
            Echo_Red "FTP 密码不能为空。"
        else
            break
        fi
    done
    if [ "${vhostdir}" == "" ]; then
        while :;do
            Echo_Yellow "请输入 FTP 账号 ${ftp_account_name} 的目录: "
            Read_Input vhostdir "FTP 目录"
            # FTP 根目录会被递归授权，必须限制在允许的网站目录内。
            # 校验通过后使用规范化的路径。
            Check_Vhost_Dir "${vhostdir}" && break
            Echo_Red "该目录不能作为 FTP 账号目录，请另选。"
            vhostdir=''
        done
    fi
    return 0
}

Check_Pureftpd()
{
    if [ ! -f /usr/local/pureftpd/sbin/pure-ftpd ]; then
        Echo_Red "未检测到已安装的 Pure-FTPd。"
        exit 1
    fi
}

Add_Ftp()
{
    local rc ftp_pass_file www_uid www_gid
    # 创建账号前再次校验目录，覆盖直接调用和建站调用两种入口。
    Check_Vhost_Dir "${vhostdir}" || return 1
    # pure-pw 需要有效的 www 用户和用户组 ID。
    www_uid=$(id -u www 2>/dev/null) || { Echo_Red "系统里没有 www 用户，无法创建 FTP 账号。"; return 1; }
    www_gid=$(id -g www 2>/dev/null) || { Echo_Red "系统里没有 www 用户组，无法创建 FTP 账号。"; return 1; }
    if [ ! -d "${vhostdir}" ]; then
        mkdir -p "${vhostdir}" || { Echo_Red "创建目录失败：${vhostdir}"; return 1; }
        chown www:www -R "${vhostdir}"
    fi

    LNMP_Tmp_Init || return 1
    ftp_pass_file=$(LNMP_Mktemp ftppass) || return 1
    chmod 600 "${ftp_pass_file}"
    cat >"${ftp_pass_file}"<<EOF
${ftp_account_password}
${ftp_account_password}
EOF
    /usr/local/pureftpd/bin/pure-pw useradd "${ftp_account_name}" -f /usr/local/pureftpd/etc/pureftpd.passwd -u "${www_uid}" -g "${www_gid}" -d "${vhostdir}" -m < "${ftp_pass_file}"
    rc=$?
    rm -f "${ftp_pass_file}"
    if [ ${rc} -ne 0 ]; then
        Echo_Red "FTP 账号 ${ftp_account_name} 创建失败（pure-pw 返回 ${rc}）。"
        Echo_Red "常见原因：同名账号已存在，或密码库 /usr/local/pureftpd/etc/pureftpd.passwd 不可写。"
        Echo_Red "先用 lnmp ftp list 确认账号是否已经存在。"
        return ${rc}
    fi
    echo "FTP 账号 ${ftp_account_name} 创建成功。"
    return 0
}

List_Ftp()
{
    local rc
    /usr/local/pureftpd/bin/pure-pw list -f /usr/local/pureftpd/etc/pureftpd.passwd
    rc=$?
    if [ ${rc} -ne 0 ]; then
        Echo_Red "FTP 账号列表读取失败（pure-pw 返回 ${rc}）。"
        return ${rc}
    fi
    echo "FTP 账号列表读取成功。"
    return 0
}

Edit_Ftp()
{
    local pass_rc=0 dir_rc=0 ftp_pass_file www_uid www_gid
    # 账号列表仅供操作前参考，读取失败不阻止后续编辑。
    List_Ftp
    Enter_Ftp_Name
    Echo_Yellow "请输入 FTP 账号 ${ftp_account_name} 的新密码（输入不回显，留空则不修改）: "
    read -r -s ftp_account_password
    echo
    if [ "${ftp_account_password}" != "" ]; then
        LNMP_Tmp_Init || return 1
        ftp_pass_file=$(LNMP_Mktemp ftppass) || return 1
        chmod 600 "${ftp_pass_file}"
        cat >"${ftp_pass_file}"<<EOF
${ftp_account_password}
${ftp_account_password}
EOF
        /usr/local/pureftpd/bin/pure-pw passwd "${ftp_account_name}" -f /usr/local/pureftpd/etc/pureftpd.passwd -m < "${ftp_pass_file}"
        pass_rc=$?
        rm -f "${ftp_pass_file}"
        if [ ${pass_rc} -ne 0 ]; then
            Echo_Red "FTP 账号 ${ftp_account_name} 的密码修改失败（pure-pw 返回 ${pass_rc}，账号可能不存在）。"
        else
            echo "FTP 账号 ${ftp_account_name} 的密码修改成功。"
        fi
    else
        echo "FTP 密码保持不变。"
    fi
    Echo_Yellow "请输入 FTP 账号 ${ftp_account_name} 的新目录（留空则不修改）: "
    Read_Input vhostdir "FTP 目录"
    if [ "${vhostdir}" != "" ]; then
        # 仅在填写新目录时执行与创建账号相同的目录校验。
        if ! Check_Vhost_Dir "${vhostdir}"; then
            Echo_Red "FTP 目录未修改。"
            return 1
        fi
        www_uid=$(id -u www 2>/dev/null) || { Echo_Red "系统里没有 www 用户。"; return 1; }
        www_gid=$(id -g www 2>/dev/null) || { Echo_Red "系统里没有 www 用户组。"; return 1; }
        if [ ! -d "${vhostdir}" ]; then
            mkdir -p "${vhostdir}" || { Echo_Red "创建目录失败：${vhostdir}"; return 1; }
            chown www:www -R "${vhostdir}"
        fi
        /usr/local/pureftpd/bin/pure-pw usermod "${ftp_account_name}" -f /usr/local/pureftpd/etc/pureftpd.passwd -u "${www_uid}" -g "${www_gid}" -d "${vhostdir}" -m
        dir_rc=$?
        if [ ${dir_rc} -ne 0 ]; then
            Echo_Red "FTP 账号 ${ftp_account_name} 的目录修改失败（pure-pw 返回 ${dir_rc}，账号可能不存在）。"
        else
            echo "FTP 账号 ${ftp_account_name} 的目录修改成功。"
        fi
    else
        echo "FTP 目录保持不变。"
    fi
    # 密码或目录任一修改失败时，整体返回非零状态。
    if [ ${pass_rc} -ne 0 ] || [ ${dir_rc} -ne 0 ]; then
        return 1
    fi
    return 0
}

Show_Ftp()
{
    local rc
    List_Ftp
    Enter_Ftp_Name
    echo "FTP 账号 ${ftp_account_name} 的详细信息："
    /usr/local/pureftpd/bin/pure-pw show "${ftp_account_name}"
    rc=$?
    if [ ${rc} -ne 0 ]; then
        Echo_Red "无法读取 FTP 账号 ${ftp_account_name}（pure-pw 返回 ${rc}，账号可能不存在）。"
        return ${rc}
    fi
    echo "完成。"
    return 0
}

# HTTP 验证不能签发泛域名，用户当场输入泛域名时拒绝整组输入。
Reject_Wildcards_For_HTTP()
{
    local d

    set -f
    for d in $1; do
        case "${d}" in
        \*.*)
            set +f
            Echo_Red "HTTP 验证不能签发泛域名证书：${d}"
            Echo_Yellow "泛域名只接受 DNS 验证，请改用 lnmp dnsssl {ali|cf|dp|he|gd|aws}。"
            echo
            return 1
            ;;
        esac
    done
    set +f
    return 0
}

# lnmp ssl add 从现有虚拟主机读取站点参数，仅询问证书相关选项。
Add_SSL_Only_Info_Menu()
{
    local input

    domain=""
    while :;do
        Echo_Yellow "HTTP 验证，请输入域名（示例：www.example.com）: "
        Read_Input input "域名"
        Lower_Domain_Input input
        Check_Domain_Name "${input}" || continue
        # HTTP-01 不能签发泛域名，ACME 规定泛域名只接受 DNS-01。
        Reject_Wildcards_For_HTTP "${input}" || continue
        if [ "${input}" = "default" ]; then
            domain="default"
            break
        fi
        # HTTP 验证要求该域名由现有网站直接服务，因此只认站点名和 server_name，
        # 不做 dnsssl 那样的根域回退。
        if Find_Site_For_SSL "${input}"; then
            domain="${Site_Match_Name}"
            break
        fi
        Echo_Red "未找到网站 ${input} 的虚拟主机配置。"
        if [ -n "${Site_Match_Hints}" ]; then
            Echo_Yellow "同一根域下现有网站：${Site_Match_Hints}"
            echo
            Echo_Yellow "HTTP 验证要求该域名由现有网站直接服务，请输入准确的域名。"
            echo
            continue
        fi
        Echo_Yellow "请先执行 lnmp vhost add 创建网站，再执行 lnmp ssl add 添加证书。"
        echo
        Echo_Yellow "只要证书不需要网站，请用 lnmp onlyssl {ali|cf|dp|he|gd|aws}。"
        echo
        return 1
    done
    echo "您的域名：${domain}"
    [ "${domain}" != "${input}" ] && echo "已匹配到网站：${domain}（输入的 ${input} 由该网站服务）"

    Load_Vhost_Params
}

Check_Acme_EMail()
{
    if [ ! -s /usr/local/acme.sh/account.conf ] || ! grep -Eq "^ACCOUNT_EMAIL=" /usr/local/acme.sh/account.conf; then
        while :;do
            Echo_Yellow "请输入证书账户邮箱（可留空）: "
            Read_Input email_address "邮箱地址"
            if [ -z "${email_address}" ]; then
                echo "未填写账户邮箱，acme.sh 按无邮箱账户注册。"
                break
            fi
            if Check_EMail_Format "${email_address}"; then
                echo "邮箱地址 ${email_address} 格式有效。"
                break
            else
                echo "邮箱地址 ${email_address} 格式无效，请重新输入。"
            fi
        done
    fi
}

# ZeroSSL 必须用邮箱换取 EAB 凭据，与 Let's Encrypt 的可选邮箱不同，单独确认一次。
# 结果写入 ACCOUNT_EMAIL，acme.sh 取值时该变量优先于 account.conf。
Check_ZeroSSL_EMail()
{
    local saved val

    saved=$(sed -n "s/^CA_EMAIL='\(.*\)'$/\1/p" "${Acme_ZeroSSL_CA_Conf}" 2>/dev/null | tail -n 1)
    while :;do
        if [ -n "${saved}" ]; then
            Echo_Yellow "请输入 ZeroSSL 账户邮箱 [已保存 ${saved}，回车沿用]: "
        else
            Echo_Yellow "请输入 ZeroSSL 账户邮箱: "
        fi
        Read_Input val "ZeroSSL 账户邮箱"
        [ -z "${val}" ] && val="${saved}"
        if [ -z "${val}" ]; then
            Echo_Red "ZeroSSL 需要邮箱换取 EAB 凭据，不能为空。"
            continue
        fi
        if Check_EMail_Format "${val}"; then
            export ACCOUNT_EMAIL="${val}"
            email_address="${val}"
            return 0
        fi
        Echo_Red "邮箱地址 ${val} 格式无效，请重新输入。"
    done
}

# newNonce 端点故障时 acme.sh 会重试 20 轮（约 5 分钟）才失败，且只提示
# Could not get nonce，先探测一次给出可判断的结果。curl 缺失时跳过检查。
Check_ZeroSSL_Endpoint()
{
    local code

    command -v curl >/dev/null 2>&1 || return 0
    echo "正在检查 ZeroSSL 服务可用性..."
    code=$(curl -s -o /dev/null -I -w '%{http_code}' --max-time 5 "${Acme_ZeroSSL_Nonce_URL}" 2>/dev/null)
    case "${code}" in
    200|204)
        return 0
        ;;
    000|"")
        Echo_Red "ZeroSSL 的 ${Acme_ZeroSSL_Nonce_URL} 5 秒内无响应。"
        ;;
    *)
        Echo_Red "ZeroSSL 的 ${Acme_ZeroSSL_Nonce_URL} 返回 HTTP ${code}。"
        ;;
    esac
    Echo_Yellow "继续签发会在 acme.sh 重试约 5 分钟后失败。"
    echo
    return 1
}

Return_301_Menu()
{
    Read_YN using_301 "是否将 HTTP 301 跳转到 HTTPS [y/N]（默认 n）: " n "301 跳转开关"
    if [ "${using_301}" == "n" ]; then
        echo "不设置 301 跳转。"
    else
        echo "将 http://${domain} 跳转到 https://${domain}。"
    fi
}

Add_DNS_SSL_Select_Menu()
{
    echo "1: 使用 Let's Encrypt 签发 SSL 证书（DNS 验证）"
    echo "2: 使用 ZeroSSL 签发 SSL 证书（DNS 验证）"
    while :;do
        Echo_Yellow "请选择 [1-2]："
        Read_Input dns_ssl_choice "证书来源选项"
        if [[ "${dns_ssl_choice}" =~ ^(1|2)$ ]]; then
            if [ "${dns_ssl_choice}" = "2" ] && ! Check_ZeroSSL_Endpoint; then
                Read_YN use_le "是否改用 Let's Encrypt 签发 [Y/n]（默认 y）: " y "改用 Let's Encrypt"
                [ "${use_le}" = "y" ] && dns_ssl_choice=1
            fi
            if [ "${dns_ssl_choice}" = "2" ]; then
                Check_ZeroSSL_EMail
            else
                Check_Acme_EMail
            fi
            break
        else
            Echo_Red "请输入 1 或 2。"
        fi
    done
}

# 解析 acme.sh dnsapi 插件头部的 dns_<provider>_info 元数据，取出所需变量。
# 输出每行：组号<TAB>变量名<TAB>required|optional<TAB>说明
# 组 1 来自 Options:，组 2 来自 OptionsAlt:（同一服务商的另一套凭据）。
Parse_DNS_API_Options()
{
    local plugin="$1"

    [ -s "${plugin}" ] || return 1
    awk '
        BEGIN { q=sprintf("%c", 39); inblock=0; group=0 }
        !inblock && /^dns_[A-Za-z0-9_]+_info=/ { inblock=1; next }
        inblock && substr($0, 1, 1) == q { exit }
        inblock && /^Options:/ { group=1; next }
        inblock && /^OptionsAlt:/ { group=2; next }
        inblock && group > 0 && /^[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]|$)/ {
            name=$1
            desc=""
            for (i=2; i<=NF; i++) desc = (desc == "" ? $i : desc " " $i)
            req="required"
            if (desc ~ /Optional\.?$/) {
                req="optional"
                sub(/[ \t]*Optional\.?$/, "", desc)
            }
            if (desc == "") desc=name
            printf "%d\t%s\t%s\t%s\n", group, name, req, desc
            next
        }
        inblock { group=0 }
    ' "${plugin}"
}

# 读取 acme.sh account.conf 中已保存的凭据，用于提示可直接沿用。
# 新式插件存 SAVED_<KEY>，旧式插件（如 dns_nsone）直接存 <KEY>，两种都要认。
Acme_Saved_Conf_Value()
{
    local key="$1" conf="${Acme_Account_Conf}" val

    [ -s "${conf}" ] || return 0
    val=$(sed -n "s/^SAVED_${key}='\(.*\)'\$/\1/p" "${conf}" | tail -n 1)
    [ -n "${val}" ] || val=$(sed -n "s/^${key}='\(.*\)'\$/\1/p" "${conf}" | tail -n 1)
    printf '%s' "${val}"
}

# acme.sh 每次运行都会 source account.conf，旧式插件保存的裸 <KEY> 行会覆盖
# 本次 export 的新凭据。换凭据时先删掉该行，同一服务商的第二个账号才生效。
Acme_Clear_Conf_Key()
{
    local key="$1" conf="${Acme_Account_Conf}" tmp

    [ -s "${conf}" ] || return 0
    grep -q "^${key}=" "${conf}" || return 0
    tmp=$(mktemp "${conf}.XXXXXX") || return 1
    if ! sed "/^${key}=/d" "${conf}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    chmod --reference="${conf}" "${tmp}" 2>/dev/null || chmod 600 "${tmp}"
    mv -f "${tmp}" "${conf}" || { rm -f "${tmp}"; return 1; }
}

# 凭据文件按证书主域名命名，泛域名的 * 转成 _wildcard. 避免路径被展开。
Acme_DNS_Cred_File()
{
    local main="$1"

    [ -n "${main}" ] || return 1
    printf '%s/%s.conf' "${Acme_DNS_Cred_Dir}" "${main/#\*./_wildcard.}"
}

# 写入某个域名的凭据文件，参数为主域名加若干 NAME=VALUE。
# 值用单引号包裹，内部单引号按 shell 规则转义；不输出凭据内容。
Acme_DNS_Cred_Write()
{
    local main="$1" file tmp item name val
    shift

    [ "$#" -gt 0 ] || return 0
    file=$(Acme_DNS_Cred_File "${main}") || return 1
    mkdir -p "${Acme_DNS_Cred_Dir}" || return 1
    chmod 700 "${Acme_DNS_Cred_Dir}" || return 1
    tmp=$(mktemp "${Acme_DNS_Cred_Dir}/cred.XXXXXX") || return 1
    chmod 600 "${tmp}"
    {
        printf '# lnmp 按域名保存的 DNS API 凭据，由 lnmp dnsssl 维护。\n'
        for item in "$@";do
            name="${item%%=*}"
            val="${item#*=}"
            [ -n "${name}" ] || continue
            printf "%s='%s'\n" "${name}" "${val//\'/\'\\\'\'}"
        done
    } > "${tmp}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "${file}" || { rm -f "${tmp}"; return 1; }
}

# account.conf 末尾的加载块正文，必须是 POSIX sh：该文件由 acme.sh 用 sh 执行。
# 块内赋值一律缩进，acme.sh 的 _setopt 会 sed 改写顶格的 KEY= 行。
Acme_DNS_Cred_Block_Text()
{
    cat <<EOF
# LNMP-DNSCRED-BEGIN 由 lnmp 维护，勿手工编辑
if [ -n "\${Le_Domain-}" ]; then
  case "\$Le_Domain" in
    '*.'*) _lnmp_dc="_wildcard.\${Le_Domain#\\*.}" ;;
    *) _lnmp_dc="\$Le_Domain" ;;
  esac
  if [ -f "${Acme_DNS_Cred_Dir}/\$_lnmp_dc.conf" ]; then
    . "${Acme_DNS_Cred_Dir}/\$_lnmp_dc.conf"
  fi
  unset _lnmp_dc
fi
# LNMP-DNSCRED-END
EOF
}

# 预置本次服务商的全部凭据变量行，再把加载块重建到 account.conf 末尾。
# acme.sh 每次运行都 source account.conf，renew 在 source 前就设好 Le_Domain，
# issue 不设，因此块只在续期时生效，交互签发仍用当场输入的凭据。
# 预置的作用：_setopt 只对不存在的 key 追加到文件尾，key 提前存在就只会原地替换，
# 不会排到加载块后面把按域名加载的值覆盖掉。
Acme_DNS_Cred_Block_Sync()
{
    local provider="${1:-}" conf="${Acme_Account_Conf}" tmp opts g name req desc
    local -a preset=()

    [ -s "${conf}" ] || return 0
    if [ -n "${provider}" ]; then
        opts=$(Parse_DNS_API_Options "${Acme_DNSAPI_Dir}/dns_${provider}.sh")
        while IFS=$'\t' read -r g name req desc;do
            [ -n "${name}" ] || continue
            grep -q "^${name}=" "${conf}" || preset+=("${name}")
        done <<EOF
${opts}
EOF
    fi

    tmp=$(mktemp "${conf}.XXXXXX") || return 1
    {
        sed '/^# LNMP-DNSCRED-BEGIN/,/^# LNMP-DNSCRED-END$/d' "${conf}"
        for name in "${preset[@]}";do
            printf "%s=''\n" "${name}"
        done
        Acme_DNS_Cred_Block_Text
    } > "${tmp}" || { rm -f "${tmp}"; return 1; }
    chmod --reference="${conf}" "${tmp}" 2>/dev/null || chmod 600 "${tmp}"
    mv -f "${tmp}" "${conf}" || { rm -f "${tmp}"; return 1; }
}

# 换凭据前，把 account.conf 里此刻的凭据固化给已用同一服务商签发、
# 但还没有凭据文件的证书，否则它们续期时会拿到新账号的凭据。
Acme_DNS_Cred_Snapshot()
{
    local provider="${1:-}" opts g name req desc val has_val='n'
    local main rest file conf webroot
    local -a values=()

    [ -n "${provider}" ] || return 0
    [ -s /usr/local/acme.sh/acme.sh ] || return 0
    opts=$(Parse_DNS_API_Options "${Acme_DNSAPI_Dir}/dns_${provider}.sh")
    [ -n "${opts}" ] || return 0

    while IFS=$'\t' read -r g name req desc;do
        [ -n "${name}" ] || continue
        val=$(Acme_Saved_Conf_Value "${name}")
        case "${val}" in __ACME_BASE64__START_*) val='' ;; esac
        [ -n "${val}" ] && has_val='y'
        values+=("${name}=${val}")
    done <<EOF
${opts}
EOF
    # 一个值都没有说明此前没用过该服务商，写空文件反而会挡住全局凭据。
    [ "${has_val}" = 'y' ] || return 0

    while IFS='|' read -r main rest;do
        [ -n "${main}" ] && [ "${main}" != "Main_Domain" ] || continue
        file=$(Acme_DNS_Cred_File "${main}") || continue
        [ -e "${file}" ] && continue
        conf="${Acme_Cert_Home}/${main}_ecc/${main}.conf"
        [ -s "${conf}" ] || continue
        webroot=$(sed -n "s/^Le_Webroot='\(.*\)'\$/\1/p" "${conf}" | tail -n 1)
        [ "${webroot}" = "dns_${provider}" ] || continue
        if Acme_DNS_Cred_Write "${main}" "${values[@]}";then
            echo "已为已有证书 ${main} 固化当前 ${provider} 凭据，其续期不受本次更换影响。"
        else
            Echo_Yellow "为 ${main} 固化 ${provider} 凭据失败，该证书续期可能受本次更换影响。"
            echo
        fi
    done <<EOF
$(/usr/local/acme.sh/acme.sh ${acme_sh_sudo} --list --listraw 2>/dev/null)
EOF
    return 0
}

# 签发成功后保存本次凭据，并把加载块重新挪到 account.conf 末尾：
# 插件首次保存某个 key 时 acme.sh 会把它追加到文件尾，排到加载块后面。
Acme_DNS_Cred_Save()
{
    local main="$1" provider="${2:-}"

    [ -n "${main}" ] || return 0
    [ "${#Acme_DNS_Cred_Values[@]}" -gt 0 ] || return 0
    if ! Acme_DNS_Cred_Write "${main}" "${Acme_DNS_Cred_Values[@]}";then
        Echo_Yellow "保存 ${main} 的 DNS API 凭据失败，到期前需重新执行本命令续期。"
        echo
        return 1
    fi
    Acme_DNS_Cred_Block_Sync "${provider}"
    return 0
}

# 交互获取 DNS 服务商 API 凭据并导出，避免用户手工 export。
# 变量名和说明来自插件元数据，新增服务商无需改本脚本。
Prompt_DNS_API_Credentials()
{
    local provider="${1:-}" plugin opts group g name req desc hint saved val

    Acme_DNS_Cred_Values=()
    [ -z "${provider}" ] && return 0
    plugin="${Acme_DNSAPI_Dir}/dns_${provider}.sh"
    opts=$(Parse_DNS_API_Options "${plugin}")
    if [ -z "${opts}" ]; then
        Echo_Yellow "无法从 ${plugin} 读取所需的 API 变量名。"
        echo
        Echo_Yellow "请按 acme.sh 文档自行 export 对应变量后重新执行。"
        echo
        return 0
    fi

    group=1
    if printf '%s\n' "${opts}" | grep -q "^2$(printf '\t')"; then
        echo "DNS 服务商 ${provider} 支持两套凭据："
        echo "1: $(printf '%s\n' "${opts}" | awk -F'\t' '$1 == 1 { printf "%s ", $2 }')"
        echo "2: $(printf '%s\n' "${opts}" | awk -F'\t' '$1 == 2 { printf "%s ", $2 }')"
        while :;do
            Echo_Yellow "请选择 [1-2]："
            Read_Input group "凭据组"
            [[ "${group}" =~ ^[12]$ ]] && break
            Echo_Red "请输入 1 或 2。"
        done
    fi

    echo "请输入 ${provider} 的 API 凭据，acme.sh 会保存供续期复用。"
    while IFS=$'\t' read -r g name req desc <&3; do
        if [ "${g}" != "${group}" ];then
            # 未选中那组必须显式置空，否则续期时会读到别的域名留下的同名凭据，
            # 插件按变量是否为空挑分支，会走错到另一套凭据上。
            Acme_DNS_Cred_Values+=("${name}=")
            continue
        fi
        hint="可留空"
        # acme.sh 元数据把 CF_Account_ID 标为必填，实际只用于缩小 zone 查询范围，可留空。
        if [ "${provider}" = "cf" ] && [ "${name}" = "CF_Account_ID" ]; then
            req="optional"
            hint="CF_Token 有区域权限可留空"
        fi
        saved=$(Acme_Saved_Conf_Value "${name}")
        # base64 保存的值直接 source 拿到的是编码串，不能当作可沿用值。
        case "${saved}" in __ACME_BASE64__START_*) saved='' ;; esac
        while :;do
            if [ -n "${saved}" ]; then
                Echo_Yellow "${name}（${desc}）[已保存，回车沿用]: "
            elif [ "${req}" = "optional" ]; then
                Echo_Yellow "${name}（${desc}，${hint}）: "
            else
                Echo_Yellow "${name}（${desc}）: "
            fi
            Read_Input val "${name}"
            if [ -n "${val}" ]; then
                export "${name}=${val}"
                Acme_Clear_Conf_Key "${name}"
                Acme_DNS_Cred_Values+=("${name}=${val}")
                if [ -n "${saved}" ] && [ "${val}" != "${saved}" ]; then
                    Echo_Yellow "${name} 已更换，本次凭据按域名单独保存，不影响其它域名续期。"
                    echo
                fi
                break
            fi
            # 留空且已有保存值时不导出，由 acme.sh 读取自身保存的凭据。
            [ -n "${saved}" ] && { Acme_DNS_Cred_Values+=("${name}=${saved}"); break; }
            [ "${req}" = "optional" ] && { Acme_DNS_Cred_Values+=("${name}="); break; }
            Echo_Red "${name} 不能为空。"
        done
    done 3<<EOF
${opts}
EOF
    return 0
}

Get_Domain_Base()
{
    local d="${1#\*.}" n l2

    n=$(printf '%s' "${d}" | awk -F. '{ print NF }')
    if [ "${n}" -le 2 ]; then
        printf '%s' "${d}"
        return 0
    fi
    l2=$(printf '%s' "${d}" | awk -F. '{ print $(NF-1)"."$NF }')
    case " ${Public_Suffix_L2} " in
    *" ${l2} "*)
        if [ "${n}" -le 3 ]; then
            printf '%s' "${d}"
        else
            printf '%s' "$(printf '%s' "${d}" | awk -F. '{ print $(NF-2)"."$(NF-1)"."$NF }')"
        fi
        return 0
        ;;
    esac
    printf '%s' "${l2}"
}

# 生成证书域名列表：去重，并去掉已被泛域名覆盖的同级子域名。
# CA 拒绝同一请求内出现与泛域名重复的子域名，主域名被覆盖时改用该泛域名打头。
Filter_Cert_Domains()
{
    printf '%s %s\n' "$1" "$2" | awk '
        {
            n=0
            for (i=1; i<=NF; i++) if (!seen[$i]++) list[++n]=$i
            for (i=1; i<=n; i++) if (substr(list[i], 1, 2) == "*.") wild[substr(list[i], 3)]=1
            main=list[1]
            mainwild=""
            if (substr(main, 1, 2) != "*.") {
                p=index(main, ".")
                if (p > 0 && (substr(main, p+1) in wild)) mainwild="*." substr(main, p+1)
            }
            # 输出第一个域名决定 acme.sh 证书目录，替换后仍是有效的证书主域名。
            if (mainwild != "") out=mainwild
            for (i=1; i<=n; i++) {
                d=list[i]
                if (mainwild != "" && (d == main || d == mainwild)) continue
                if (i > 1 && substr(d, 1, 2) != "*.") {
                    p=index(d, ".")
                    if (p > 0 && (substr(d, p+1) in wild)) continue
                }
                out = (out == "" ? d : out " " d)
            }
            print out
        }
    '
}

# 泛域名只覆盖恰好一级的子域名：a.test.com 收，test.com 与 b.a.test.com 不收。
# 判定不依赖公共后缀清单，*.test.com.uk 与 *.test.gov.uk 同样成立。
Domain_Covered_By_Wildcard()
{
    local name="$1" base="${2#\*.}"

    case "$2" in
    \*.*) ;;
    *) return 1 ;;
    esac
    # 站点名自身是泛域名时不参与覆盖判定。
    case "${name}" in
    \*.*|'') return 1 ;;
    esac
    [ "${name}" != "${base}" ] || return 1
    [ "${name#*.}" = "${base}" ]
}

# CA 不签发公共后缀上的泛域名，签发前先拦下来，避免走完交互才报错。
Check_Wildcard_Base()
{
    local base="${1#\*.}" n

    n=$(printf '%s' "${base}" | awk -F. '{ print NF }')
    if [ "${n}" -lt 2 ]; then
        Echo_Red "${1} 缺少注册域名部分，CA 不签发这样的证书。"
        echo
        return 1
    fi
    case " ${Public_Suffix_L2} " in
    *" ${base} "*)
        Echo_Red "${base} 是公共后缀，CA 不签发 ${1} 这样的证书。"
        Echo_Yellow "请使用自己注册的域名，例如 *.example.${base}。"
        echo
        return 1
        ;;
    esac
    return 0
}

Find_Sites_Covered_By_Wildcard()
{
    local wildcard="$1" f name d hit

    Wildcard_Site_List=""
    [ -d "${Vhost_Conf_Dir}" ] || return 1

    for f in "${Vhost_Conf_Dir}"/*.conf; do
        [ -s "${f}" ] || continue
        name=$(basename "${f}" .conf)
        [ "${name}" = "default" ] && continue
        hit=""
        if Domain_Covered_By_Wildcard "${name}" "${wildcard}"; then
            hit="${name}"
        else
            # 站点可能以别的名字命名，真正被泛域名覆盖的是它声明的其它域名，
            # 只看文件名会把这类站点漏掉。存量配置里可能有泛域名，拆分期间
            # 关闭路径展开。
            set -f
            for d in $(Vhost_Domains "${f}"); do
                Domain_Covered_By_Wildcard "${d}" "${wildcard}" || continue
                hit="${name}"
                echo "网站 ${name} 的域名 ${d} 被 ${wildcard} 覆盖。"
                break
            done
            set +f
        fi
        [ -n "${hit}" ] || continue
        Wildcard_Site_List="${Wildcard_Site_List:+${Wildcard_Site_List} }${hit}"
    done

    [ -n "${Wildcard_Site_List}" ]
}

# 查找已签发且未过期、包含指定泛域名的证书，命中时写入 Wildcard_Cert_* 系列变量。
# 台账取自 acme.sh --list，泛域名可能只出现在 SAN 中，两列都要比对。
Find_Wildcard_Cert()
{
    local wildcard="$1" main san created dir cert

    Wildcard_Cert_Main=""
    Wildcard_Cert_Dir=""
    Wildcard_Cert_Created=""
    Wildcard_Cert_Expire=""
    [ -s /usr/local/acme.sh/acme.sh ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1

    while IFS='|' read -r main _ san _ _ created _; do
        [ -n "${main}" ] && [ "${main}" != "Main_Domain" ] || continue
        case " ${main} $(printf '%s' "${san}" | tr ',' ' ') " in
        *" ${wildcard} "*) ;;
        *) continue ;;
        esac
        dir="${Acme_Cert_Home}/${main/#\*./_wildcard.}"
        cert="${dir}/fullchain.cer"
        [ -s "${cert}" ] || continue
        openssl x509 -noout -checkend 0 -in "${cert}" >/dev/null 2>&1 || continue
        Wildcard_Cert_Main="${main}"
        Wildcard_Cert_Dir="${dir}"
        Wildcard_Cert_Created="${created}"
        Wildcard_Cert_Expire=$(openssl x509 -noout -enddate -in "${cert}" 2>/dev/null | sed 's/^notAfter=//')
        return 0
    done <<EOF
$(/usr/local/acme.sh/acme.sh ${acme_sh_sudo} --list --listraw 2>/dev/null)
EOF
    return 1
}

# 把已就位的证书写进多个站点配置。单个站点失败只跳过该站，不回滚其它站点。
Install_Cert_To_Sites()
{
    local sites="$1" site saved_domain="${domain}" conf ok=0 skip=0

    for site in ${sites}; do
        conf="${Vhost_Conf_Dir}/${site}.conf"
        if [ ! -s "${conf}" ]; then
            Echo_Red "网站 ${site} 的配置不存在，跳过。"
            skip=$((skip + 1))
            continue
        fi
        if Vhost_Has_HTTPS "${conf}"; then
            echo "网站 ${site} 已有 HTTPS 配置，跳过。"
            skip=$((skip + 1))
            continue
        fi
        domain="${site}"
        if ! Load_Vhost_Params; then
            skip=$((skip + 1))
            continue
        fi
        if Create_SSL_Config; then
            ok=$((ok + 1))
            Echo_Green "网站 ${site} 的 HTTPS 配置已写入。"
        else
            Echo_Red "网站 ${site} 的 HTTPS 配置写入失败，已跳过。"
            skip=$((skip + 1))
        fi
    done
    domain="${saved_domain}"

    echo "已配置 ${ok} 个网站，跳过 ${skip} 个。"
    [ "${ok}" -gt 0 ]
}

# onlyssl 不写站点配置，跨根域是合法用法，只提示服务商需同时管理这些解析。
Warn_Multi_Root_Domains()
{
    local base list="$2" d outside=""

    base=$(Get_Domain_Base "$1")
    set -f
    for d in ${list}; do
        [ "$(Get_Domain_Base "${d}")" = "${base}" ] && continue
        outside="${outside:+${outside} }${d}"
    done
    set +f

    [ -z "${outside}" ] && return 0
    Echo_Yellow "注意：${outside} 与主域名不同根域，DNS 服务商须同时管理它们的解析。"
    echo
}

# 附加域名超出本站根域时确认；DNS 验证要求服务商能管理这些域名的解析。
Confirm_Extra_Domains()
{
    local base="$1" known="$2" list="$3" d k outside="" ans

    # 泛域名带 *，比对期间关闭路径展开。
    set -f
    for d in ${list}; do
        for k in ${known}; do
            [ "${k}" = "${d}" ] && continue 2
        done
        [ "$(Get_Domain_Base "${d}")" = "${base}" ] && continue
        outside="${outside:+${outside} }${d}"
    done
    set +f

    [ -z "${outside}" ] && return 0
    Echo_Red "这些域名不属于网站 ${domain} 的根域 ${base}：${outside}"
    Echo_Yellow "DNS 验证需要服务商能管理它们的解析，否则本次签发会失败；"
    echo
    Echo_Yellow "它们还会被写入该网站的 HTTPS 配置。"
    echo
    Echo_Yellow "确认一并申请? (y/N，默认 n) "
    read ans
    [ "${ans}" = "y" ] && return 0
    return 1
}

# 按是否已有 HTTPS 分组展示被泛域名覆盖的站点。
Report_Wildcard_Sites()
{
    local site conf pending="" configured=""

    for site in ${Wildcard_Site_List}; do
        conf="${Vhost_Conf_Dir}/${site}.conf"
        if Vhost_Has_HTTPS "${conf}"; then
            configured="${configured:+${configured} }${site}"
        else
            pending="${pending:+${pending} }${site}"
        fi
    done
    [ -n "${pending}" ] && echo "本次写入 HTTPS 配置的网站：${pending}"
    [ -n "${configured}" ] && echo "已有 HTTPS 配置、本次跳过的网站：${configured}"
    [ -n "${pending}" ] || Echo_Yellow "被覆盖的网站都已配置 HTTPS，本次只签发证书。"
    [ -n "${pending}" ] || echo
    return 0
}

# 泛域名不覆盖去掉星号后的域名本身，存在同名站点时单独确认是否一并签入。
Confirm_Wildcard_Base_Domain()
{
    local base="${1#\*.}" ans

    [ -s "${Vhost_Conf_Dir}/${base}.conf" ] || return 0
    Read_YN ans "检测到网站 ${base}，泛域名不覆盖它本身，是否一并签入本证书 [y/N]（默认 n）: " n "上级域名签入开关"
    if [ "${ans}" = "y" ]; then
        moredomain="${moredomain:+${moredomain} }${base}"
        # 该站点可能已因别名被泛域名覆盖而在列表里，重复会让它被处理两次。
        case " ${Wildcard_Site_List} " in
        *" ${base} "*) ;;
        *) Wildcard_Site_List="${Wildcard_Site_List:+${Wildcard_Site_List} }${base}" ;;
        esac
        echo "${base} 已加入证书域名。"
    else
        echo "${base} 不参与本次证书。"
    fi
    return 0
}

# 已存在覆盖该泛域名的证书时的处理方式，结果写入 Wildcard_Choice。
Wildcard_Cert_Exists_Menu()
{
    local wildcard="$1"

    echo "已存在证书 ${Wildcard_Cert_Main}（签发于 ${Wildcard_Cert_Created}，${Wildcard_Cert_Expire} 到期）。"
    echo "1: 把该证书写入尚未配置 HTTPS 的网站，不重新签发"
    echo "2: 换一个具体子域名单独申请证书"
    echo "3: 重新签发 ${wildcard}，覆盖现有证书"
    while :;do
        Echo_Yellow "请选择 [1-3]："
        Read_Input Wildcard_Choice "处理方式"
        case "${Wildcard_Choice}" in
        1|2|3) return 0 ;;
        *) Echo_Red "请输入 1、2 或 3。" ;;
        esac
    done
}

# 更多域名里的泛域名已有可用证书时拒绝重复申请，并指出复用入口。
Check_Extra_Wildcards()
{
    local d

    set -f
    for d in $1; do
        case "${d}" in
        \*.*) ;;
        *) continue ;;
        esac
        if ! Check_Wildcard_Base "${d}"; then
            set +f
            return 1
        fi
        if Find_Wildcard_Cert "${d}"; then
            set +f
            Echo_Red "已存在证书 ${Wildcard_Cert_Main}（签发于 ${Wildcard_Cert_Created}，${Wildcard_Cert_Expire} 到期），不需要重复申请。"
            Echo_Yellow "要把它写入现有网站，请执行 lnmp dnsssl <服务商> 并输入 ${d}，选择第 1 项。"
            echo
            return 1
        fi
    done
    set +f
    return 0
}

# 更多域名里的泛域名覆盖了本站域名时，CA 不接受两者共存，转入泛域名流程。
# 返回 0 已转入，1 无覆盖，2 需要重新输入。
Switch_To_Wildcard_Menu()
{
    local extra="$1" d wildcard="" rest="" choice

    set -f
    for d in ${extra}; do
        case "${d}" in
        \*.*)
            if [ -z "${wildcard}" ] && Domain_Covered_By_Wildcard "${domain}" "${d}"; then
                wildcard="${d}"
                continue
            fi
            ;;
        esac
        rest="${rest:+${rest} }${d}"
    done
    set +f
    [ -n "${wildcard}" ] || return 1

    Echo_Yellow "${wildcard} 已覆盖网站域名 ${domain}，CA 不接受两者同时出现在一张证书里。"
    echo
    if ! Find_Sites_Covered_By_Wildcard "${wildcard}"; then
        Echo_Red "没有找到 ${wildcard} 覆盖的网站，请改填其它域名。"
        echo
        Wildcard_Site_List=""
        return 2
    fi
    echo "泛域名 ${wildcard} 覆盖的网站：${Wildcard_Site_List}"
    Report_Wildcard_Sites
    echo "1: 按 ${wildcard} 签发证书，并写入上面列出的网站"
    echo "2: 重新输入更多域名"
    while :;do
        Echo_Yellow "请选择 [1-2]："
        Read_Input choice "处理方式"
        case "${choice}" in
        1) break ;;
        2) Wildcard_Site_List=""; return 2 ;;
        *) Echo_Red "请输入 1 或 2。" ;;
        esac
    done

    Wildcard_Mode="y"
    [ -n "${rest}" ] && moredomain="${moredomain:+${moredomain} }${rest}"
    domain="${wildcard}"
    Confirm_Wildcard_Base_Domain "${wildcard}"
    echo "证书域名：$(Filter_Cert_Domains "${domain}" "${moredomain}")"
    return 0
}

# dnsssl 只给已存在的站点签发证书，域名必须命中现有虚拟主机。
Add_DNS_SSL_Site_Info_Menu()
{
    local input extradomain site_base

    domain=""
    Wildcard_Mode="n"
    Wildcard_Site_List=""
    while :;do
        Echo_Yellow "DNS 验证，请输入域名（示例：www.example.com）: "
        Read_Input input "域名"
        Lower_Domain_Input input
        Check_Domain_Name "${input}" || continue
        if [ "${input}" = "default" ]; then
            Echo_Red "default 是 IP 站点，DNS 验证无法为 IP 地址签发证书。"
            Echo_Yellow "请执行 lnmp ssl add 并输入 default，走 IP 证书流程。"
            echo
            return 1
        fi
        # 泛域名不定位单个站点，按覆盖关系处理全部被覆盖的站点。
        case "${input}" in
        \*.*)
            Check_Wildcard_Base "${input}" || continue
            if ! Find_Sites_Covered_By_Wildcard "${input}"; then
                Echo_Red "没有找到 ${input} 覆盖的网站。"
                Echo_Yellow "泛域名只覆盖恰好一级的子域名，请先执行 lnmp vhost add 建立网站。"
                echo
                Echo_Yellow "只要证书不写入网站配置，请用 lnmp onlyssl {ali|cf|dp|he|gd|aws}。"
                echo
                return 1
            fi
            Wildcard_Mode="y"
            domain="${input}"
            moredomain=""
            echo "泛域名 ${input} 覆盖的网站：${Wildcard_Site_List}"
            Report_Wildcard_Sites
            if Find_Wildcard_Cert "${input}"; then
                Wildcard_Cert_Exists_Menu "${input}"
                case "${Wildcard_Choice}" in
                1)
                    Use_Existing_Cert "${Wildcard_Cert_Dir}" || return 1
                    Return_301_Menu
                    Install_Cert_To_Sites "${Wildcard_Site_List}" || return 1
                    return 2
                    ;;
                2)
                    Wildcard_Mode="n"
                    domain=""
                    continue
                    ;;
                esac
            fi
            Confirm_Wildcard_Base_Domain "${input}"
            break
            ;;
        esac
        if Find_Site_For_SSL "${input}"; then
            domain="${Site_Match_Name}"
            break
        fi
        # 输入的是子域名或根域名时，按根域命中现有站点即可继续。
        if [ "$(printf '%s\n' ${Site_Match_Hints} | wc -l)" = "1" ] && [ -n "${Site_Match_Hints}" ]; then
            domain="${Site_Match_Hints}"
            echo "${input} 与现有网站 ${domain} 同属根域 $(Get_Domain_Base "${input}")，按该网站申请证书。"
            break
        fi
        Echo_Red "未找到网站 ${input} 的虚拟主机配置。"
        if [ -n "${Site_Match_Hints}" ]; then
            Echo_Yellow "同一根域下有多个网站：${Site_Match_Hints}"
            echo
            Echo_Yellow "请输入其中一个准确的域名。"
            echo
            continue
        fi
        Echo_Yellow "请先执行 lnmp vhost add 建立网站，再用本功能申请证书。"
        echo
        Echo_Yellow "只要证书不需要网站，请用 lnmp onlyssl {ali|cf|dp|he|gd|aws}。"
        echo
        return 1
    done
    if [ "${Wildcard_Mode}" = "y" ]; then
        echo "证书域名：$(Filter_Cert_Domains "${domain}" "${moredomain}")"
        return 0
    fi
    echo "您的域名：${domain}"

    Load_Vhost_Params || return 1
    [ -n "${moredomain}" ] && echo "站点现有域名：${moredomain}"

    site_base=$(Get_Domain_Base "${domain}")
    while :;do
        Echo_Yellow "请输入更多域名（支持泛域名，示例：*.example.com sub.example.com，留空跳过）: "
        Read_Input extradomain "更多域名"
        Lower_Domain_Input extradomain
        [ -z "${extradomain}" ] && break
        Check_More_Domains "${extradomain}" || continue
        Check_Extra_Wildcards "${extradomain}" || continue
        Switch_To_Wildcard_Menu "${extradomain}"
        case "$?" in
        0) return 0 ;;
        2) continue ;;
        esac
        Confirm_Extra_Domains "${site_base}" "${domain} ${moredomain}" "${extradomain}" && break
    done
    if [ -n "${extradomain}" ]; then
        moredomain=$(printf '%s %s\n' "${moredomain}" "${extradomain}" | awk -v p="${domain}" '
            { for (i=1; i<=NF; i++) if ($i != p && !seen[$i]++) out = (out == "" ? $i : out " " $i) }
            END { print out }
        ')
        echo "附加域名：${moredomain}"
    fi
    return 0
}

Add_DNS_SSL_Only_Info_Menu()
{
    Add_DNS_SSL_Select_Menu

    domain=""
    while :;do
        Echo_Yellow "DNS 验证，请输入域名（示例：www.example.com）: "
        Read_Input domain "域名"
        Lower_Domain_Input domain
        Check_Domain_Name "${domain}" || continue
        if [ "${domain}" = "default" ]; then
            Echo_Red "default 是 IP 站点，DNS 验证无法为 IP 地址签发证书。"
            Echo_Yellow "请执行 lnmp ssl add 并输入 default，走 IP 证书流程。"
            echo
            return 1
        fi
        # 泛域名先拦公共后缀，再核对是否已有可用证书，避免重复签发。
        case "${domain}" in
        \*.*)
            Check_Wildcard_Base "${domain}" || continue
            if Find_Wildcard_Cert "${domain}"; then
                echo "已存在证书 ${Wildcard_Cert_Main}（签发于 ${Wildcard_Cert_Created}，${Wildcard_Cert_Expire} 到期）。"
                echo "证书目录：${Wildcard_Cert_Dir}"
                Read_YN reissue_cert "是否重新签发并覆盖现有证书 [y/N]（默认 n）: " n "重新签发开关"
                if [ "${reissue_cert}" != "y" ]; then
                    echo "保留现有证书，本次不签发。"
                    return 2
                fi
            fi
            ;;
        esac
        echo "您的域名：${domain}"
        break
    done

    while :;do
        Echo_Yellow "请输入更多域名（支持泛域名，示例：*.example.com sub.example.com，留空跳过）: "
        Read_Input moredomain "更多域名"
        Lower_Domain_Input moredomain
        [ -z "${moredomain}" ] && break
        Check_More_Domains "${moredomain}" || continue
        Check_More_Domains_Unique "${domain}" "${moredomain}" || continue
        Check_Extra_Wildcards "${moredomain}" && break
    done
    if [ "${moredomain}" != "" ]; then
        echo "附加域名：${moredomain}"
        Warn_Multi_Root_Domains "${domain}" "${moredomain}"
    fi
}

# acme.sh 的工作目录只由环境变量决定，与脚本自身路径无关。调用前必须加载
# 安装时写下的 acme.sh.env，否则会按默认值在 ${HOME}/.acme.sh 另建一套账户目录。
Load_Acme_Env()
{
    if [ ! -s /usr/local/acme.sh/acme.sh.env ]; then
        Echo_Red "缺少 /usr/local/acme.sh/acme.sh.env，无法确定 acme.sh 工作目录。"
        return 1
    fi
    . "/usr/local/acme.sh/acme.sh.env"
    export LE_WORKING_DIR="/usr/local/acme.sh"
    export LE_CONFIG_HOME="/usr/local/acme.sh"
    return 0
}

# 返回前核对没有多出第二套 home，只删除本次运行新产生的目录；
# 机器上原有的目录可能是用户自建实例，不做任何改动。
Clean_Acme_Stray_Home()
{
    local pre="$1" home="${HOME:-/root}/.acme.sh"

    [ "${pre}" = 'n' ] || return 0
    [ -d "${home}" ] || return 0
    Echo_Yellow "本次运行新建了 ${home}，与固定的 /usr/local/acme.sh 重复，正在删除。"
    rm -rf "${home}"
    if [ -d "${home}" ]; then
        Echo_Red "删除 ${home} 失败，其中可能留有账户私钥，请手工处理。"
        return 1
    fi
    return 0
}

# 私有、保留、空值或非 IPv4 地址返回 0。
Is_Private_IP()
{
    case "$1" in
        10.*|127.*|169.254.*|192.168.*)          return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*)   return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
        ''|*[!0-9.]*)                            return 0 ;;
    esac
    return 1
}

# IP 是否绑定在本机某个接口上。ip 命令不可用时返回 0，不阻断流程。
Ip_On_Local_Interface()
{
    local addr="$1"
    [ -n "${addr}" ] || return 1
    command -v ip >/dev/null 2>&1 || return 0
    ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 |
        grep -qxF "${addr}"
}

# KILL 或断电时 Restore_Cert_Dir 来不及执行，活动证书目录会停留在缺失状态。
# 申请前扫描同级遗留备份：产生它的进程已退出且活动路径缺失时恢复，其余只提示。
Recover_Cert_Backups()
{
    local dir="$1" parent bak base pid

    parent="${dir%/*}"
    [ -n "${parent}" ] && [ -d "${parent}" ] || return 0
    for bak in "${parent}"/*.lnmp-bak.*; do
        [ -d "${bak}" ] || continue
        pid="${bak##*.lnmp-bak.}"
        case "${pid}" in
        ''|*[!0-9]*) continue ;;
        esac
        [ "${pid}" = "$$" ] && continue
        # 备份进程仍在运行时不介入，避免破坏正在进行的申请。
        kill -0 "${pid}" 2>/dev/null && continue
        [ -n "$(ls -A "${bak}" 2>/dev/null)" ] || continue
        base="${bak%.lnmp-bak.*}"
        if [ -e "${base}" ]; then
            Echo_Yellow "存在遗留证书备份 ${bak}，活动证书已在位，确认后可自行删除。"
            echo
            continue
        fi
        if mv "${bak}" "${base}"; then
            Echo_Yellow "上次申请被中断，已恢复原有证书：${base}"
            echo
        else
            Echo_Red "恢复遗留证书备份失败：${bak}"
        fi
    done
    return 0
}

# 证书目录在签发前改名保留，任一环节失败即回滚。直接删除会在签发或安装
# 失败时留下不可用的证书路径，而旧证书可能仍被站点配置引用。
# 记录本次签发前 acme.sh 工作目录的状态，供失败时判断能否清理。
Note_Acme_Workdir()
{
    Acme_Workdir="$1/$2_ecc"
    Acme_Workdir_Was_Absent='n'
    [ -e "${Acme_Workdir}" ] || Acme_Workdir_Was_Absent='y'
}

# 签发失败时清理本次新建的 acme.sh 工作目录，避免遗留私钥与 csr。
# 目录在本次签发前就存在，或其中已有证书时保持不动。
Cleanup_Failed_Acme_Workdir()
{
    [ "${Acme_Workdir_Was_Absent:-n}" = 'y' ] || return 0
    [ -n "${Acme_Workdir:-}" ] && [ -d "${Acme_Workdir}" ] || return 0
    case "${Acme_Workdir}" in
        */conf/ssl/?*_ecc) ;;
        *) return 0 ;;
    esac
    [ -s "${Acme_Workdir}/fullchain.cer" ] && return 0
    rm -rf "${Acme_Workdir}" && echo "已清理签发失败遗留的 ${Acme_Workdir}"
}

Backup_Cert_Dir()
{
    local dir="$1"

    Cert_Backup_Src=""
    Cert_Backup_Dir=""
    [ -n "${dir}" ] || return 0
    Recover_Cert_Backups "${dir}"
    [ -d "${dir}" ] || return 0

    Cert_Backup_Dir="${dir}.lnmp-bak.$$"
    rm -rf "${Cert_Backup_Dir}"
    if ! mv "${dir}" "${Cert_Backup_Dir}"; then
        Cert_Backup_Dir=""
        Echo_Red "备份现有证书目录失败：${dir}"
        return 1
    fi
    Cert_Backup_Src="${dir}"
    # 中断信号必须走 EXIT 清理，否则活动证书路径会停在缺失状态。
    LNMP_Set_Trap
    echo "已备份现有证书，签发失败时会自动恢复。"
    return 0
}

# 失败回滚：丢弃本次写入的内容，把备份改回原路径。
Restore_Cert_Dir()
{
    [ -n "${Cert_Backup_Dir}" ] && [ -d "${Cert_Backup_Dir}" ] || return 0
    rm -rf "${Cert_Backup_Src}"
    if mv "${Cert_Backup_Dir}" "${Cert_Backup_Src}"; then
        Echo_Yellow "已恢复原有证书：${Cert_Backup_Src}"
        echo
    else
        Echo_Red "恢复原有证书失败，备份保留在：${Cert_Backup_Dir}"
    fi
    Cert_Backup_Src=""
    Cert_Backup_Dir=""
    return 0
}

# 成功后清理备份。
Discard_Cert_Backup()
{
    [ -n "${Cert_Backup_Dir}" ] && rm -rf "${Cert_Backup_Dir}"
    Cert_Backup_Src=""
    Cert_Backup_Dir=""
    return 0
}

# 证书的 SAN 是否覆盖该域名，支持一级泛域名。
Cert_Covers_Domain()
{
    local d="$1" n

    for n in $2; do
        [ "${n}" = "${d}" ] && return 0
        case "${n}" in
        \*.*)
            [ "${d}" != "${d#*.}" ] && [ "${d#*.}" = "${n#\*.}" ] && return 0
            ;;
        esac
    done
    return 1
}

# 自有证书写入前的预检：可解析、未过期、私钥与证书配对、SAN 覆盖站点域名。
# nginx -t 只看语法，过期或域名不符的证书照样通过，浏览器才报错。
Verify_Own_Cert()
{
    local cert="$1" key="$2" main="$3" extra="$4"
    local cert_pub key_pub names d missing='' ans

    if ! command -v openssl >/dev/null 2>&1; then
        Echo_Yellow "系统没有 openssl，跳过证书预检。"
        echo
        return 0
    fi
    if ! openssl x509 -noout -in "${cert}" >/dev/null 2>&1; then
        Echo_Red "${cert} 不是可解析的 PEM 证书。"
        return 1
    fi
    if ! openssl x509 -noout -checkend 0 -in "${cert}" >/dev/null 2>&1; then
        Echo_Red "证书已过期：$(openssl x509 -noout -enddate -in "${cert}" 2>/dev/null | sed 's/^notAfter=//')"
        return 1
    fi
    cert_pub=$(openssl x509 -noout -pubkey -in "${cert}" 2>/dev/null)
    key_pub=$(openssl pkey -pubout -in "${key}" 2>/dev/null)
    if [ -z "${cert_pub}" ] || [ -z "${key_pub}" ] || [ "${cert_pub}" != "${key_pub}" ]; then
        Echo_Red "私钥 ${key} 与证书 ${cert} 不是同一对密钥。"
        return 1
    fi
    # default 站点用 IP 证书，没有域名可比对。
    [ "${main}" = "default" ] && return 0

    names=$(openssl x509 -noout -ext subjectAltName -in "${cert}" 2>/dev/null \
        | tr ',' '\n' | sed -n 's/^[[:space:]]*DNS://p')
    if [ -z "${names}" ]; then
        names=$(openssl x509 -noout -subject -in "${cert}" 2>/dev/null \
            | sed -n 's/.*CN[[:space:]]*=[[:space:]]*//p' | sed 's/[,/].*$//')
    fi
    # 证书里的泛域名带 *，比对期间关闭路径展开。
    set -f
    for d in ${main} ${extra}; do
        Cert_Covers_Domain "${d}" "${names}" && continue
        missing="${missing:+${missing} }${d}"
    done
    set +f
    [ -z "${missing}" ] || {
        Echo_Red "证书未覆盖这些域名：${missing}"
        Echo_Yellow "证书覆盖的名称：$(printf '%s' "${names}" | tr '\n' ' ')"
        echo
        Echo_Yellow "用它启用 HTTPS 后，上述域名的访问会被浏览器判为证书名称不匹配。"
        echo
        Read_YN ans "仍要使用该证书? (y/N，默认 n) " n "证书覆盖确认"
        [ "${ans}" = "y" ] || return 1
    }
    return 0
}

Color_Text()
{
  echo -e " \e[0;$2m$1\e[0m"
}

Echo_Red()
{
  echo "$(Color_Text "$1" "31")"
}

Echo_Green()
{
  echo "$(Color_Text "$1" "32")"
}

Echo_Yellow()
{
  echo -n "$(Color_Text "$1" "33")"
}

Echo_Blue()
{
  echo "$(Color_Text "$1" "34")"
}

Sleep_Sec()
{
    seconds=$1
    while [ "${seconds}" -ge "0" ];do
      echo -ne "\r     \r"
      echo -n ${seconds}
      seconds=$(($seconds - 1))
      sleep 1
    done
    echo -ne "\r"
}

Del_Database()
{
    local del_sql_file rc
    List_Database || return 1
    Enter_Database_Name
    if [[ "${database_name}" == "information_schema" || "${database_name}" == "mysql" || "${database_name}" == "performance_schema" ]]; then
        Echo_Red "MySQL 系统数据库不能删除。"
        return 1
    fi
    Check_DB_Identifier "${database_name}" || return 1
    # 删除倒计时前确认数据库存在，避免将名称错误误报为删除失败。
    if ! Database_Exists "${database_name}"; then
        Echo_Red "数据库不存在：${database_name}"
        return 1
    fi
    echo "将删除数据库及同名数据库用户：${database_name}"
    echo "10 秒后继续，按 Ctrl+C 可取消..."
    Sleep_Sec 10
    LNMP_Tmp_Init || return 1
    del_sql_file=$(LNMP_Mktemp del_db) || return 1
    chmod 600 "${del_sql_file}"
    cat >"${del_sql_file}"<<EOF
DROP USER IF EXISTS '${database_name}'@'127.0.0.1';
DROP USER IF EXISTS '${database_name}'@'localhost';
DROP DATABASE \`${database_name}\`;
FLUSH PRIVILEGES;
EOF
    ${MySQL_Bin} --defaults-file="${HOME}/.my.cnf" < "${del_sql_file}"
    rc=$?
    rm -f "${del_sql_file}"
    if [ ${rc} -ne 0 ]; then
        Echo_Red "数据库 ${database_name} 删除失败。"
        return ${rc}
    fi
    echo "数据库 ${database_name} 删除成功。"
    return 0
}

Function_Database()
{
    case "$1" in
        [aA][dD][dD])
            Add_Database_Menu && Add_Database
            ;;
        [lL][iI][sS][tT])
            List_Database
            ;;
        [dD][eE][lL])
            Del_Database
            ;;
        [eE][dD][iI][tT])
            Edit_Database
            ;;
        [eE][xX][pP][oO][rR][tT])
            Export_Database "$2" "$3"
            ;;
        [iI][mM][pP][oO][rR][tT])
            Import_Database "$2" "$3"
            ;;
        [eE][xX][iI][tT])
            return 1
            ;;
        *)
            echo "用法：lnmp database {add|list|edit|del}"
            echo "用法：lnmp database export <数据库名> <文件.sql.gz>"
            echo "用法：lnmp database import <数据库名> <文件.sql.gz>"
            return 1
            ;;
    esac
}

Function_Ftp()
{
    case "$1" in
        [aA][dD][dD])
            Add_Ftp_Menu && Add_Ftp
            ;;
        [lL][iI][sS][tT])
            List_Ftp
            ;;
        [dD][eE][lL])
            Del_Ftp
            ;;
        [eE][dD][iI][tT])
            Edit_Ftp
            ;;
        [eE][xX][iI][tT])
            return 1
            ;;
        [sS][hH][oO][wW])
            Show_Ftp
            ;;
        *)
            echo "用法：lnmp ftp {add|list|edit|del|show}"
            return 1
            ;;
    esac
}

Function_Vhost()
{
    case "$1" in
        [aA][dD][dD])
            Add_VHost
            ;;
        [lL][iI][sS][tT])
            List_VHost
            ;;
        [dD][eE][lL])
            Del_VHost "$2"
            ;;
        [sS][tT][aA][rR][tT])
            Vhost_Toggle start "$2" || exit 1
            ;;
        [sS][tT][oO][pP])
            Vhost_Toggle stop "$2" || exit 1
            ;;
        [eE][xX][iI][tT])
            exit 1
            ;;
        *)
            echo "用法：lnmp vhost {add|list|del|start|stop}"
            echo "      lnmp vhost del [域名]"
            echo "      lnmp vhost {start|stop} <域名>"
            exit 1
            ;;
    esac
}

# 数据库 root 密码最多校验 3 次，避免输入错误或 EOF 导致无休止重试。
Verify_DB_Password()
{
    local attempt=0 max_attempt=3
    Check_DB
    while [ ${attempt} -lt ${max_attempt} ]; do
        attempt=$((attempt + 1))
        Echo_Yellow "请输入当前数据库 root 密码（输入不回显）: "
        Read_Secret DB_Root_Password "数据库 root 密码"
        echo
        Make_TempMycnf "${DB_Root_Password}"
        Check_DB_Password_TCP
        case $? in
        0)
            echo "数据库 root 密码验证通过。"
            return 0
            ;;
        2)
            # TCP 不可用时退回 socket 连接，该结果不能证明口令正确。
            if Do_Query ""; then
                Echo_Yellow "数据库未监听 127.0.0.1，已改用 socket 连接校验；socket 认证下该结果不代表口令正确。"
                echo
                return 0
            fi
            ;;
        esac
        Echo_Red "数据库 root 密码校验失败（第 ${attempt}/${max_attempt} 次）。"
    done
    Echo_Red "连续 ${max_attempt} 次校验失败，已放弃。"
    return 1
}

# 探测服务器对外使用的 IPv4 地址。
Detect_Server_IP()
{
    local ip=''
    # 优先读取默认路由使用的源地址。
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    # 私有地址环境通过外部服务获取公网出口地址。
    if [ -z "${ip}" ] || Is_Private_IP "${ip}"; then
        local pub
        pub=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null)
        [ -n "${pub}" ] && ip="${pub}"
    fi
    printf '%s' "${ip}"
}

# Acme_Sources：acme.sh 固定版本的下载清单，校验定位列为固定 SHA256 所在变量。
Acme_Sources()
{
    printf 'acme.sh\t/usr/local/acme.sh\t%s\tacme.sh-%s.tar.gz\thttps://github.com/acmesh-official/acme.sh/archive/refs/tags/%s.tar.gz\tsha256\tAcme_Sh_SHA256\n' \
        "${Acme_Sh_Ver}" "${Acme_Sh_Ver}" "${Acme_Sh_Ver}"
}

Install_Check_Acme.sh()
{
    local tmpdir tarball srcdir actual url
    local acme_home_pre='n'
    local -a email_opt=()

    [ -d "${HOME:-/root}/.acme.sh" ] && acme_home_pre='y'

    if [ -s /usr/local/acme.sh/acme.sh ]; then
        echo "/usr/local/acme.sh/acme.sh [已存在]"
        Load_Acme_Env || return 1
        if [ -n "${email_address}" ] \
            && ! grep -Eq "^ACCOUNT_EMAIL=" /usr/local/acme.sh/account.conf 2>/dev/null; then
            /usr/local/acme.sh/acme.sh --register-account -m "${email_address}" || return 1
        fi
        Clean_Acme_Stray_Home "${acme_home_pre}"
        return 0
    fi

    if ! command -v sha256sum >/dev/null 2>&1; then
        Echo_Red "缺少 sha256sum，无法校验 acme.sh 安装包，拒绝安装。"
        return 1
    fi

    tmpdir=$(mktemp -d /tmp/acme.sh.XXXXXXXX) || return 1
    chmod 700 "${tmpdir}"
    tarball="${tmpdir}/acme.sh-${Acme_Sh_Ver}.tar.gz"
    srcdir="${tmpdir}/acme.sh-${Acme_Sh_Ver}"

    url=$(Acme_Sources | cut -f5)
    echo "正在从 github.com/acmesh-official 下载 acme.sh ${Acme_Sh_Ver} ..."
    if ! wget --prefer-family=IPv4 --max-redirect=5 -O "${tarball}" "${url}"; then
        Echo_Red "acme.sh 下载失败，未做任何修改。"
        rm -rf "${tmpdir}"
        return 1
    fi

    # 安装包通过固定 SHA256 校验后才能解压和执行。
    actual=$(sha256sum "${tarball}" | awk '{print $1}')
    if [ "${actual}" != "${Acme_Sh_SHA256}" ]; then
        Echo_Red "acme.sh 安装包 SHA256 不匹配，拒绝执行。"
        Echo_Red "  期望值：${Acme_Sh_SHA256}"
        Echo_Red "  实际值：${actual}"
        rm -rf "${tmpdir}"
        return 1
    fi

    if ! tar zxf "${tarball}" -C "${tmpdir}"; then
        Echo_Red "acme.sh 解压失败。"
        rm -rf "${tmpdir}"
        return 1
    fi
    # 归档目录必须与固定版本一致。
    if [ ! -s "${srcdir}/acme.sh" ]; then
        Echo_Red "acme.sh 归档结构异常：未找到 ${srcdir}/acme.sh"
        rm -rf "${tmpdir}"
        return 1
    fi

    [ -n "${email_address}" ] && email_opt=( -m "${email_address}" )
    ( cd "${srcdir}" && ./acme.sh --install ${acme_sh_sudo} --log \
        --home /usr/local/acme.sh --certhome "${Acme_Cert_Home}" "${email_opt[@]}" )
    if [ $? -ne 0 ] || [ ! -s /usr/local/acme.sh/acme.sh ]; then
        Echo_Red "acme.sh 安装失败。"
        rm -rf "${tmpdir}"
        return 1
    fi
    rm -rf "${tmpdir}"

    sed -i 's/cat "\$CERT_PATH"$/#cat "\$CERT_PATH"/g' /usr/local/acme.sh/acme.sh
    # 关闭 acme.sh 自动升级，避免未经固定版本校验的代码覆盖证书管理组件。
    # 安全更新通过 upgrade.sh 手动确认，完成后应重新核对来源和完整性。
    Load_Acme_Env || return 1
    /usr/local/acme.sh/acme.sh --upgrade --auto-upgrade 0 >/dev/null 2>&1
    cat >/usr/local/acme.sh/upgrade.sh<<EOF
#!/bin/bash
#
# 手动升级 acme.sh；禁止加入 crontab。
#
# 此操作直接从 GitHub 更新，不使用安装包的固定版本和 SHA256。
# 仅在需要上游安全更新时执行，完成后须确认组件来源和完整性。

echo "警告：即将从 GitHub 升级 acme.sh，此过程不做完整性校验。"
printf "确认继续请输入 yes: "
read -r _ans
[ "\$_ans" = "yes" ] || { echo "已取消。"; exit 1; }

. "/usr/local/acme.sh/acme.sh.env"
/usr/local/acme.sh/acme.sh --upgrade
/usr/local/acme.sh/acme.sh --upgrade --auto-upgrade 0 >/dev/null 2>&1
sed -i 's/cat "\\\$CERT_PATH"\$/#cat "\\\$CERT_PATH"/g' /usr/local/acme.sh/acme.sh
EOF

    chmod +x /usr/local/acme.sh/upgrade.sh
    #if crontab -l|grep -q "/usr/local/acme.sh/upgrade.sh"; then
    #    echo "acme.sh upgrade crontab rule is exist."
    #else
    #    echo "Add acme.sh upgrade crontab rule..."
    #    (crontab -l ; echo '0 3 */7 * * /usr/local/acme.sh/upgrade.sh') | crontab -
    #fi
    if command -v yum >/dev/null 2>&1; then
        yum -y update nss
        yum -y install ca-certificates
        service crond restart
        chkconfig crond on
    elif command -v apt-get >/dev/null 2>&1; then
        /etc/init.d/cron restart
        update-rc.d cron defaults
    fi

    Clean_Acme_Stray_Home "${acme_home_pre}"
    return 0
}

Del_Ftp()
{
    local rc
    List_Ftp
    Enter_Ftp_Name
    echo "将删除 FTP 账号 ${ftp_account_name}。"
    echo "10 秒后继续，按 Ctrl+C 可取消..."
    Sleep_Sec 10
    /usr/local/pureftpd/bin/pure-pw userdel "${ftp_account_name}" -f /usr/local/pureftpd/etc/pureftpd.passwd -m
    rc=$?
    if [ ${rc} -ne 0 ]; then
        Echo_Red "FTP 账号 ${ftp_account_name} 删除失败（pure-pw 返回 ${rc}，账号可能不存在）。"
        return ${rc}
    fi
    echo "FTP 账号 ${ftp_account_name} 删除成功。"
    return 0
}
