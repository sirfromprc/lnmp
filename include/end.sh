#!/usr/bin/env bash

Add_Firewall_Rules()
{
    local port

    echo "正在配置防火墙..."

    if ! Firewall_Init; then
        Echo_Red "防火墙未配置成功，请自行确认 ${DB_Port} 等端口没有暴露在公网。"
        return 1
    fi

    # SSH 按系统实际监听放行，探测不到就不写规则。
    if Resolve_SSH_Ports; then
        for port in "${SSH_Ports[@]}"; do
            Firewall_Allow tcp "${port}"
        done
    fi
    Firewall_Allow tcp 80
    Firewall_Allow tcp 443
    Firewall_Allow_ICMP
    # 数据库端口拒绝外部新建连接，本机经回环接口访问不受影响。
    Firewall_Block tcp "${DB_Port}"
    # MySQL X Protocol 可通过 33060 执行数据库操作，且不受 my.cnf 中
    # bind-address 的约束，因此需要单独限制外部访问；MariaDB 不使用此端口。
    Firewall_Block tcp "${DB_X_Port}"
    Block_Addons_Ports

    Firewall_Save
}

# 同步两个常用命令路径并固定权限，兼容 merged-/usr 与传统目录布局。
Sync_LNMP_Command_Alias()
{
    local tmp

    if ! chmod 755 /bin/lnmp; then
        Echo_Red "/bin/lnmp 不可执行。"
        return 1
    fi
    if [ ! /bin/lnmp -ef /usr/bin/lnmp ] 2>/dev/null; then
        tmp=$(mktemp /usr/bin/.lnmp.XXXXXXXX) || return 1
        if ! \cp /bin/lnmp "${tmp}" || ! chmod 755 "${tmp}" || \
           ! mv -f "${tmp}" /usr/bin/lnmp; then
            rm -f "${tmp}"
            Echo_Red "同步 /usr/bin/lnmp 失败。"
            return 1
        fi
    fi
    if ! chmod 755 /usr/bin/lnmp || [ ! -x /usr/bin/lnmp ]; then
        Echo_Red "/usr/bin/lnmp 不可执行。"
        return 1
    fi
    return 0
}

Detect_Installed_LNMP_Command_Stack()
{
    local manager=${1:-/bin/lnmp}

    if [ ! -s "${manager}" ]; then
        return 1
    fi
    if grep -q '^lnmpa_start()' "${manager}"; then
        printf '%s\n' lnmpa
    elif grep -q '^lamp_start()' "${manager}"; then
        printf '%s\n' lamp
    else
        printf '%s\n' lnmp
    fi
}

Install_Current_LNMP_Command()
{
    local fallback=${1:-lnmp} installed_stack

    installed_stack=$(Detect_Installed_LNMP_Command_Stack /bin/lnmp 2>/dev/null) || \
        installed_stack=${fallback}
    Install_LNMP_Command "${installed_stack}"
}

# 管理命令依赖配套工具，需同步安装以保证各子命令可用。
Install_LNMP_Command()
{
    local stack=$1 source target

    case "${stack}" in lnmp|lnmpa|lamp) ;; *)
        Echo_Red "未知管理脚本类型：${stack}"
        return 1
        ;;
    esac

    for source in \
        "${cur_dir}/conf/${stack}:/bin/lnmp" \
        "${cur_dir}/tools/lnmp-backup.sh:/bin/lnmp-backup" \
        "${cur_dir}/tools/lnmp-tgnotice.sh:/bin/lnmp-tgnotice" \
        "${cur_dir}/tools/lnmp-phpmyadmin.sh:/bin/lnmp-phpmyadmin" \
        "${cur_dir}/tools/lnmp-perm.sh:/bin/lnmp-perm" \
        "${cur_dir}/tools/lnmp-health.sh:/bin/lnmp-health" \
        "${cur_dir}/tools/lnmp-sqlguard.sh:/bin/lnmp-sqlguard" \
        "${cur_dir}/tools/lnmp-fw.sh:/bin/lnmp-fw" \
        "${cur_dir}/tools/cut_nginx_logs.sh:/bin/lnmp-cutlogs"
    do
        target=${source#*:}
        source=${source%%:*}
        if [ ! -s "${source}" ] || ! \cp "${source}" "${target}" || \
           ! chmod 755 "${target}" || [ ! -x "${target}" ]; then
            Echo_Red "安装管理命令失败：${source} -> ${target}"
            return 1
        fi
    done

    # 保证从 /bin 或 /usr/bin 调用时使用同一份管理命令。
    Sync_LNMP_Command_Alias || return 1

    Install_Tgnotice_Profile || return 1
    Install_Perm_Diagnose_Unit || return 1
    Install_App_Unit_Tpl || return 1
    Record_Source_Dir
    return 0
}

# lnmp fw 需要回写 lnmp.conf 的端口变量，但运行期无从得知源码目录，
# 因此在这里记录一次。写失败不影响安装，lnmp fw 会退化为只对齐防火墙。
Record_Source_Dir()
{
    local dst='/etc/lnmp/source-dir' tmp

    mkdir -p /etc/lnmp 2>/dev/null || return 0
    tmp=$(mktemp "${dst}.XXXXXXXX") || return 0
    if ! printf '%s\n' "${cur_dir}" > "${tmp}" || ! chmod 600 "${tmp}" \
       || ! mv -f "${tmp}" "${dst}"; then
        rm -f "${tmp}"
        Echo_Yellow "记录源码目录到 ${dst} 失败，lnmp fw 将只对齐防火墙，不回写 lnmp.conf。"
    fi
    return 0
}

# 工具脚本需要可执行权限，以支持通过 ./tools/xxx.sh 直接调用。
# 只在初次安装时设置：源码目录的权限装完就已确定，后续同步管理命令不会改变它。
Set_Tools_Permission()
{
    if ! chmod 755 "${cur_dir}"/tools/*.sh 2>/dev/null; then
        Echo_Red "设置 tools/ 目录脚本权限失败，请手动执行: chmod 755 ${cur_dir}/tools/*.sh"
        return 1
    fi
    return 0
}

# 各服务 unit 的 OnFailure 指向该模板单元，安装期必须一并写入。
Install_Perm_Diagnose_Unit()
{
    local src="${cur_dir}/init.d/lnmp-perm-diagnose@.service"
    local dst="/etc/systemd/system/lnmp-perm-diagnose@.service"

    [ -d /etc/systemd/system ] || return 0
    [ -s "${src}" ] || { Echo_Red "缺少 ${src}"; return 1; }
    if ! \cp "${src}" "${dst}" || ! chmod 644 "${dst}"; then
        Echo_Red "安装权限诊断单元失败：${dst}"
        return 1
    fi
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    return 0
}

# lnmp app 托管 Node/Go 等应用进程时按实例启动该模板单元。
Install_App_Unit_Tpl()
{
    local src="${cur_dir}/init.d/lnmp-app@.service"
    local dst="/etc/systemd/system/lnmp-app@.service"

    [ -d /etc/systemd/system ] || return 0
    [ -s "${src}" ] || { Echo_Red "缺少 ${src}"; return 1; }
    if ! \cp "${src}" "${dst}" || ! chmod 644 "${dst}"; then
        Echo_Red "安装应用托管单元失败：${dst}"
        return 1
    fi
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    return 0
}

# 健康检查的定时探测任务。unit 的 Restart= 只处理进程退出，
# 进程存活但不响应请求的场景由该定时任务发现。
# 只在安装收尾调用：bumpversion 同步管理命令时不应改动定时任务。
# 探测目标由 lnmp-health 按已存在的 unit 决定，只装数据库的入口同样适用。
# 定时任务装不上不影响已装好的服务，失败只告警。
Install_Health_Timer()
{
    if [ ! -x /bin/lnmp-health ]; then
        Echo_Yellow "缺少 /bin/lnmp-health，跳过健康检查定时任务。"
        return 0
    fi
    if ! /bin/lnmp-health init >/dev/null 2>&1; then
        Echo_Yellow "安装健康检查定时任务失败，可稍后执行 lnmp health init 重试。"
    fi
    return 0
}

# Nginx 访问日志与错误日志的每日切割任务。切割的日志名由脚本自动发现，
# 新建站点无需登记。脚本同时解析 Nginx 与 Apache 配置，切割后按已安装的
# Web 服务 reload 或 graceful 重开日志，因此含任一 Web 服务的入口都调用。
Install_Cutlogs_Timer()
{
    [ -d /etc/systemd/system ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    if [ ! -x /bin/lnmp-cutlogs ]; then
        Echo_Yellow "缺少 /bin/lnmp-cutlogs，跳过日志切割定时任务。"
        return 0
    fi

    cat > /etc/systemd/system/lnmp-cutlogs.service <<'EOF' || return 0
[Unit]
Description=LNMP nginx log rotation

[Service]
Type=oneshot
ExecStart=/bin/lnmp-cutlogs
EOF
    cat > /etc/systemd/system/lnmp-cutlogs.timer <<'EOF' || return 0
[Unit]
Description=Daily LNMP nginx log rotation

[Timer]
OnCalendar=*-*-* 00:05:00
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
    chmod 644 /etc/systemd/system/lnmp-cutlogs.service \
              /etc/systemd/system/lnmp-cutlogs.timer
    systemctl daemon-reload >/dev/null 2>&1
    if ! systemctl enable --now lnmp-cutlogs.timer >/dev/null 2>&1; then
        Echo_Yellow "启用日志切割定时任务失败，可稍后执行 systemctl enable --now lnmp-cutlogs.timer 重试。"
    fi
    return 0
}

# 在 Bash 登录环境中加载 tgnotice；该函数依赖 Bash 数组与字符串操作。
Install_Tgnotice_Profile()
{
    mkdir -p /etc/profile.d 2>/dev/null || return 0
    cat > /etc/profile.d/lnmp-tgnotice.sh <<'PROFILE_EOF'
# LNMP 通知函数，仅在 Bash 环境中加载。
# 用法：tgnotice "文本"        默认 HTML
#       tgnotice "文本" md     MarkdownV2
if [ -n "${BASH_VERSION:-}" ] && [ -r /bin/lnmp-tgnotice ]; then
    . /bin/lnmp-tgnotice
fi
PROFILE_EOF
    chmod 644 /etc/profile.d/lnmp-tgnotice.sh
}

# 服务是否真的在运行。判定后端与管理命令一致：有 systemd unit 时以 unit
# 状态为准，否则回落到 init 脚本的 status。
Service_Running()
{
    local service="$1"

    if Use_Systemd_Unit "${service}"; then
        systemctl is-active --quiet "${service}.service"
    else
        [ -x "/etc/init.d/${service}" ] && "/etc/init.d/${service}" status >/dev/null 2>&1
    fi
}

# 设为开机启动并启动服务，再确认服务真的处于运行状态。
# 启动命令返回成功不代表进程还活着：端口被占、动态库缺失、运行期配置错误
# 都会让服务在启动后立刻退出。
Start_And_Verify()
{
    local service="$1" i=0

    if ! StartUp "${service}"; then
        Echo_Red "设置 ${service} 开机启动失败。"
        return 1
    fi
    if ! StartOrStop start "${service}"; then
        Echo_Red "启动 ${service} 失败。"
        return 1
    fi
    # unit 带 Restart= 时状态会短暂停在 activating，重试到 15 秒再判失败。
    while [ ${i} -lt 15 ]; do
        Service_Running "${service}" && return 0
        sleep 1
        i=$((i + 1))
    done
    Echo_Red "${service} 的启动命令返回成功，但服务没有处于运行状态。"
    Echo_Red "排查：systemctl status ${service}.service 或 journalctl -xeu ${service}.service"
    return 1
}

Add_LNMP_Startup()
{
    local rc=0

    echo "正在设置开机启动并启动 LNMP..."
    Install_LNMP_Command lnmp || return 1
    Set_Tools_Permission || return 1
    Start_And_Verify nginx || rc=1
    Startup_DB || rc=1
    Start_And_Verify php-fpm || rc=1
    if [ "${PHP_Branch}" = "5.2" ]; then
        sed -i 's#/usr/local/php/var/run/php-fpm.pid#/usr/local/php/logs/php-fpm.pid#' /bin/lnmp
        Sync_LNMP_Command_Alias || return 1
    fi
    # 定时任务装不上不影响已装好的服务，不改变本函数的返回码。
    Install_Health_Timer
    Install_Cutlogs_Timer
    return ${rc}
}

# 各安装栈共用数据库启动流程，并按已安装的服务类型启用对应服务。
Startup_DB()
{
    if [ "${DB_Kind}" = "none" ]; then
        return 0
    fi
    Start_And_Verify "${DB_Service}"
}

Add_LNMPA_Startup()
{
    local rc=0

    echo "正在设置开机启动并启动 LNMPA..."
    Install_LNMP_Command lnmpa || return 1
    Set_Tools_Permission || return 1
    Start_And_Verify nginx || rc=1
    Startup_DB || rc=1
    Start_And_Verify httpd || rc=1
    Install_Health_Timer
    Install_Cutlogs_Timer
    return ${rc}
}

Add_LAMP_Startup()
{
    local rc=0

    echo "正在设置开机启动并启动 LAMP..."
    Install_LNMP_Command lamp || return 1
    Set_Tools_Permission || return 1
    Start_And_Verify httpd || rc=1
    Startup_DB || rc=1
    Install_Health_Timer
    Install_Cutlogs_Timer
    return ${rc}
}

# 最小 HTTP 探测：不依赖 curl/wget，确认 Web 服务在监听并按 HTTP 协议应答。
Probe_Http_Local()
{
    local port="$1" line=''

    # 重定向自左向右生效，写在后面的 2>/dev/null 挡不住打开失败的报错，
    # 因此整体套一层 { } 再重定向。
    { exec 3<>"/dev/tcp/127.0.0.1/${port}"; } 2>/dev/null || return 1
    if ! printf 'HEAD / HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' >&3 2>/dev/null; then
        exec 3<&- 3>&-
        return 1
    fi
    read -r -t 5 line <&3
    exec 3<&- 3>&-
    case "${line}" in
    HTTP/*) return 0 ;;
    esac
    return 1
}

# PHP-FPM 监听 unix socket。socket 文件存在只说明进程建过它，进程退出后文件
# 仍会留下，因此还要确认内核里这个 socket 处于 LISTEN。
# bash 不能连接 unix socket（对 socket 文件执行重定向只会得到 ENXIO），
# 所以用 ss 查监听状态；没有 ss 时退回文件类型检查，不因缺工具判定安装失败。
Probe_Fpm_Socket()
{
    local sock="${1:-/run/php-fpm/php-cgi.sock}"

    [ -S "${sock}" ] || return 1
    command -v ss >/dev/null 2>&1 || return 0
    ss -lxH src "${sock}" 2>/dev/null | grep -q LISTEN
}

# 数据库最小探测：执行一次 SELECT 1。
# 安装流程在 Init_Install 结尾就清掉了 ~/.my.cnf，因此这里用本次安装的 root
# 口令临时生成一份私有 option file，探测后立即删除，口令不进命令行。
Probe_DB_Select1()
{
    local bin="$1" opt rc

    [ -x "${bin}" ] || return 1
    [ -n "${DB_Root_Password}" ] || return 1
    opt=$(mktemp) || return 1
    chmod 600 "${opt}"
    cat >"${opt}"<<EOF
[client]
user=root
password='$(SQL_Escape "${DB_Root_Password}")'
socket=$(Get_Actual_DB_Socket)
EOF
    "${bin}" --defaults-file="${opt}" -e "SELECT 1;" >/dev/null 2>&1
    rc=$?
    rm -f "${opt}"
    return ${rc}
}

Check_Nginx_Files()
{
    isNginx=""
    echo "============================== 检查安装结果 =============================="
    echo "正在检查..."
    if [[ ! -s /usr/local/nginx/conf/nginx.conf || ! -s /usr/local/nginx/sbin/nginx ]]; then
        Echo_Red "错误：Nginx 安装失败。"
        return 1
    fi
    # 文件存在不代表可用，配置语法错误会导致 nginx 无法启动。
    if ! /usr/local/nginx/sbin/nginx -t >/dev/null 2>&1; then
        Echo_Red "错误：Nginx 配置检查未通过，执行 /usr/local/nginx/sbin/nginx -t 查看详情。"
        return 1
    fi
    # 离线语法检查通过也可能因端口被占用等运行期问题起不来，因此确认服务在跑。
    if ! Service_Running nginx; then
        Echo_Red "错误：Nginx 未在运行，执行 systemctl status nginx.service 查看详情。"
        return 1
    fi
    if ! Probe_Http_Local 80; then
        Echo_Red "错误：Nginx 在运行，但 127.0.0.1:80 没有按 HTTP 协议应答。"
        return 1
    fi
    Echo_Green "Nginx：正常"
    isNginx="ok"
    return 0
}

Check_DB_Files()
{
    local db_client db_safe db_name='MySQL'

    isDB=""
    if [ "${DB_Kind}" = "none" ]; then
        Echo_Green "未安装 MySQL/MariaDB。"
        isDB="ok"
        return 0
    fi

    if [ "${DB_Kind}" = "mariadb" ]; then
        db_name='MariaDB'
        db_client=$(First_Executable "${MySQL_Dir}/bin/mariadb" "${MySQL_Dir}/bin/mysql")
        db_safe=$(First_Executable "${MySQL_Dir}/bin/mariadbd-safe" "${MySQL_Dir}/bin/mysqld_safe")
    else
        db_client=$(First_Executable "${MySQL_Dir}/bin/mysql")
        db_safe=$(First_Executable "${MySQL_Dir}/bin/mysqld_safe")
    fi

    if [ -z "${db_client}" ] || [ -z "${db_safe}" ] || [ ! -s /etc/my.cnf ]; then
        Echo_Red "错误：${db_name} 安装失败。"
        return 1
    fi
    MySQL_Bin="${db_client}"

    # 客户端和配置齐全不代表服务起得来，因此确认服务在跑并能执行一次查询。
    if ! Service_Running "${DB_Service}"; then
        Echo_Red "错误：${db_name} 未在运行，执行 systemctl status ${DB_Service}.service 查看详情。"
        return 1
    fi
    if ! Probe_DB_Select1 "${MySQL_Bin}"; then
        Echo_Red "错误：${db_name} 在运行，但用 root 执行 SELECT 1 失败。"
        Echo_Red "排查：${MySQL_Bin} -u root -p -e \"SELECT 1;\""
        return 1
    fi
    Echo_Green "${db_name}：正常"
    isDB="ok"
    return 0
}

Check_PHP_Files()
{
    isPHP=""
    if [ "${Stack}" = "lnmp" ]; then
        if [[ ! -s /usr/local/php/sbin/php-fpm || ! -s /usr/local/php/etc/php.ini || ! -s /usr/local/php/bin/php ]]; then
            Echo_Red "错误：PHP 安装失败。"
            return 1
        fi
        if ! Service_Running php-fpm; then
            Echo_Red "错误：PHP-FPM 未在运行，执行 systemctl status php-fpm.service 查看详情。"
            return 1
        fi
        if ! Probe_Fpm_Socket; then
            Echo_Red "错误：PHP-FPM 在运行，但 /run/php-fpm/php-cgi.sock 不可连接。"
            return 1
        fi
        Echo_Green "PHP：正常"
        Echo_Green "PHP-FPM：正常"
        isPHP="ok"
        return 0
    fi

    if [[ ! -s /usr/local/php/bin/php || ! -s /usr/local/php/etc/php.ini ]]; then
        Echo_Red "错误：PHP 安装失败。"
        return 1
    fi
    Echo_Green "PHP：正常"
    isPHP="ok"
    return 0
}

Check_Apache_Files()
{
    isApache=""
    if [[ ! -s /usr/local/apache/bin/httpd || ! -s /usr/local/apache/modules/${PHP_Apache_Module} || ! -s /usr/local/apache/conf/httpd.conf ]]; then
        Echo_Red "错误：Apache 安装失败。"
        return 1
    fi
    if ! /usr/local/apache/bin/httpd -t >/dev/null 2>&1; then
        Echo_Red "错误：Apache 配置检查未通过，执行 /usr/local/apache/bin/httpd -t 查看详情。"
        return 1
    fi
    if ! Check_Apache_MPM_For_ModPHP; then
        return 1
    fi
    if ! Service_Running httpd; then
        Echo_Red "错误：Apache 未在运行，执行 systemctl status httpd.service 查看详情。"
        return 1
    fi
    # LNMPA 里 Apache 在 Nginx 之后，监听 127.0.0.1:88。
    if [ "${Stack}" = "lamp" ] && ! Probe_Http_Local 80; then
        Echo_Red "错误：Apache 在运行，但 127.0.0.1:80 没有按 HTTP 协议应答。"
        return 1
    fi
    if [ "${Stack}" = "lnmpa" ] && ! Probe_Http_Local 88; then
        Echo_Red "错误：Apache 在运行，但 127.0.0.1:88 没有按 HTTP 协议应答。"
        Echo_Red "Nginx 会把 PHP 请求转到该端口，此时全站 PHP 不可用。"
        return 1
    fi
    Echo_Green "Apache：正常"
    isApache="ok"
    return 0
}

Clean_DB_Src_Dir()
{
    echo "正在清理数据库源码目录..."
    [ "${DB_Kind}" = "none" ] && return 0
    [ -n "${DB_Ver}" ] && rm -rf "${cur_dir}/src/${DB_Ver}"

    # Boost 清理范围由安装时解析的 Get_Boost_Ver 确定；非空检查可防止
    # 变量缺失时误删整个 src 目录。
    if [ "${DB_Needs_Boost}" = "y" ]; then
        [ -n "${Get_Boost_Ver}" ] && [ -d "${cur_dir}/src/boost_${Get_Boost_Ver}" ] && rm -rf "${cur_dir}/src/boost_${Get_Boost_Ver}"
    fi
    return 0
}

Clean_PHP_Src_Dir()
{
    echo "正在清理 PHP 源码目录..."
    [ -n "${Php_Ver}" ] && rm -rf "${cur_dir}/src/${Php_Ver}"
    return 0
}

Clean_Web_Src_Dir()
{
    echo "正在清理 Web 服务器源码目录..."
    if [ "${Stack}" = "lnmp" ]; then
        [ -n "${Nginx_Ver}" ] && rm -rf "${cur_dir}/src/${Nginx_Ver}"*
    elif [ "${Stack}" = "lnmpa" ]; then
        [ -n "${Nginx_Ver}" ] && rm -rf "${cur_dir}/src/${Nginx_Ver}"*
        [ -n "${Apache_Ver}" ] && rm -rf "${cur_dir}/src/${Apache_Ver}"
    elif [ "${Stack}" = "lamp" ]; then
        [ -n "${Apache_Ver}" ] && rm -rf "${cur_dir}/src/${Apache_Ver}"
    fi

    # 版本变量为空时路径退化为 ${cur_dir}/src，-d 判断反而成立，
    # 因此每项都先判非空。
    local item
    for item in "${Openssl_New_Ver}" "${Pcre_Ver}" "${LuaNginxModule}" \
        "${NgxDevelKit}" "${NgxFancyIndex_Ver}"; do
        [ -n "${item}" ] && [ -d "${cur_dir}/src/${item}" ] && rm -rf "${cur_dir}/src/${item}"
    done
    return 0
}


Print_DB_Password_Notice()
{
    local pass_file='/root/.lnmp_db_root_password'

    if [ "${DB_Root_Password_Random}" = "y" ]; then
        ( umask 077; printf '%s\n' "${DB_Root_Password}" > "${pass_file}" )
        chmod 600 "${pass_file}" 2>/dev/null
        Print_Banner \
            "数据库 root 密码为随机生成，已写入 ${pass_file}" \
            "查看：cat ${pass_file}（请尽快记录并删除该文件）"
    else
        Print_Banner "数据库 root 密码：即你安装时输入的那个，脚本不再回显。"
    fi
    Print_Banner "密码不再打印到屏幕与安装日志，见 changelog SEC-CRED-001。"
}

# 安装结果提示按当前栈显示名称，避免 LNMPA/LAMP 被提示为 LNMP。
Stack_Display_Name()
{
    case "${Stack}" in
    lnmpa) printf 'LNMPA' ;;
    lamp) printf 'LAMP' ;;
    *) printf 'LNMP' ;;
    esac
}

Print_Sucess_Info()
{
    Clean_Web_Src_Dir
    Print_Banner \
        "$(Stack_Display_Name) V${LNMP_Ver} 安装完成" \
        "运行 lnmp {start|stop|reload|restart|kill|status} 管理服务" \
        "仅使用上游官方源码，并强制校验完整性"
    # 安装摘要统一使用横幅格式，便于查看访问地址和常用管理入口。
    local summary_lines=() line='' server_ip
    # 刚装完的 default 站点只有 80 端口，两条地址统一用 http。
    server_ip=$(Get_Server_IP) || printf -v server_ip '<服务器IP>'
    if [ "${Enable_PhpMyAdmin}" = "y" ]; then
        summary_lines+=("phpMyAdmin：http://${server_ip}/$(cat ${PhpMyAdmin_Url_File} 2>/dev/null)/")
        printf -v line '上面这个路径是随机生成的，请自行记录；忘记可执行 lnmp status 查看。'
        summary_lines+=("${line}")
    fi
    [ "${Enable_PHPInfo_Page}" = "y" ] && summary_lines+=("phpinfo：http://${server_ip}/phpinfo.php")
    printf -v line '添加虚拟主机：lnmp vhost add'
    summary_lines+=("${line}")
    printf -v line '默认网站目录：%s' "${Default_Website_Dir}"
    summary_lines+=("${line}")
    Print_Banner "${summary_lines[@]}"
    if [ "${DB_Kind}" != "none" ]; then
        Print_DB_Password_Notice
    fi
    lnmp status
    if command -v ss >/dev/null 2>&1; then
        ss -ntl
    else
        netstat -ntl
    fi
    stop_time=$(date +%s)
    echo "$(Stack_Display_Name) 安装耗时 $(((stop_time-start_time)/60)) 分钟。"
    Echo_Green "$(Stack_Display_Name) V${LNMP_Ver} 安装完成。"

    # 完整性校验关闭时在安装结束处再次提示，便于确认组件来源可信度。

    if [ "${Enable_Download_Checksum}" != "y" ]; then
        echo
        Echo_Red "########################################################################"
        Echo_Red "!! 本次安装全程未做完整性校验（Enable_Download_Checksum='${Enable_Download_Checksum}'）。"
        Echo_Red "!! 所有下载的组件都没有与 src/checksums.sha256 核对过，"
        Echo_Red "!! 无法保证它们与上游一致。**这台机器不应作为生产环境使用。**"
        Echo_Red "!! 请改回 Enable_Download_Checksum='y' 后清空 src/ 重装。"
        Echo_Red "########################################################################"
    fi
}


Print_Failed_Info()
{
    if [ -s /bin/lnmp ]; then
        rm -f /bin/lnmp
    fi
    Echo_Red "$(Stack_Display_Name) 安装失败。"
    Echo_Red "请查看安装日志了解详情：/root/lnmp-install.log"
    Echo_Red "注意：该日志可能含数据库 root 密码等敏感信息，外发前请先清理。"
    return 1
}

# 防火墙初始化、规则写入或持久化失败时返回非零。组件可能仍可运行，
# 但数据库等端口的暴露状态需要人工确认后才能视为安装完成。
Check_Firewall_Result()
{
    [ "${FW_Failed}" != 'y' ] && return 0

    echo
    Echo_Red "════════════════ 防火墙未配置成功 ════════════════"
    Echo_Red "组件已经装好，但**防火墙规则没有成功写入**。"
    Echo_Red "这意味着 ${DB_Port}（数据库）等端口可能正暴露在公网上。"
    echo
    Echo_Yellow "请立即自行确认并处置："
    echo "  nft list table inet lnmp        # 看本包的规则表在不在"
    echo "  ss -lntp | grep -E ':${DB_Port}|:${Redis_Port}' # 看数据库/缓存监听在哪个地址"
    echo
    Echo_Yellow "数据库默认已配置 bind-address = 127.0.0.1（只监听回环），"
    Echo_Yellow "但若你改过 /etc/my.cnf，或使用了其他服务，请逐一核对。"
    Echo_Red "════════════════════════════════════════════════"
    return 1
}

# 数据库文件存在仅表示组件已安装，不能证明安全初始化已经完成。
# 任一初始化步骤失败时返回非零，并提示核对账号、测试库和远程授权。
Check_DB_Init_Result()
{
    [ "${DB_Init_Failed}" != 'y' ] && return 0

    echo
    Echo_Red "════════════════ 数据库初始化未全部成功 ════════════════"
    Echo_Red "以下初始化步骤失败：${DB_Init_Errors}"
    echo
    Echo_Yellow "这意味着匿名账号、test 库、远程 root 授权是否已清理无法确认。"
    Echo_Yellow "请先确认数据库客户端可用，再手工核对："
    echo "  ${MySQL_Bin} --version"
    echo "  ${MySQL_Bin} -u root -p -e \"SELECT User,Host FROM mysql.user;\""
    echo "  ${MySQL_Bin} -u root -p -e \"SHOW DATABASES;\"   # 不应有 test"
    Echo_Red "════════════════════════════════════════════════════════"
    return 1
}

Check_LNMP_Install()
{
    Check_Nginx_Files
    Check_DB_Files
    Check_PHP_Files
    if [[ "${isNginx}" = "ok" && "${isDB}" = "ok" && "${isPHP}" = "ok" ]]; then
        Print_Sucess_Info
        # 组件齐全后仍需分别检查防火墙和数据库初始化，两项均通过才返回成功。
        local rc=0
        Check_Firewall_Result || rc=1
        Check_DB_Init_Result || rc=1
        return ${rc}
    fi
    Print_Failed_Info
    return 1
}

Check_LNMPA_Install()
{
    Check_Nginx_Files
    Check_DB_Files
    Check_PHP_Files
    Check_Apache_Files
    if [[ "${isNginx}" = "ok" && "${isDB}" = "ok" && "${isPHP}" = "ok" && "${isApache}" = "ok" ]]; then
        Print_Sucess_Info
        local rc=0
        Check_Firewall_Result || rc=1
        Check_DB_Init_Result || rc=1
        return ${rc}
    fi
    Print_Failed_Info
    return 1
}

Check_LAMP_Install()
{
    Check_Apache_Files
    Check_DB_Files
    Check_PHP_Files
    if [[ "${isApache}" = "ok" && "${isDB}" = "ok" && "${isPHP}" = "ok" ]]; then
        Print_Sucess_Info
        local rc=0
        Check_Firewall_Result || rc=1
        Check_DB_Init_Result || rc=1
        return ${rc}
    fi
    Print_Failed_Info
    return 1
}
