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
    # Nginx 的 HTTP/3 走 UDP 443。
    [ -x /usr/local/nginx/sbin/nginx ] && Firewall_Allow udp 443
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

# Deploy_LNMP_Command_Group <栈> <目标目录>
# 管理命令成组部署：全部产物先在目标目录内的暂存目录组装并通过 bash -n，
# 嵌入同一构建 ID，备份现有文件后逐个 rename 换入，再核对构建 ID。
# 任一环节失败，已换入的文件按备份恢复。
# 返回：0 成功；1 失败且目标已保持部署前状态；2 失败且恢复未完成，暂存目录保留。
Deploy_LNMP_Command_Group()
{
    local stack=$1 bindir=$2
    local -a names=(lnmp lnmp-backup lnmp-tgnotice lnmp-phpmyadmin lnmp-perm \
                    lnmp-health lnmp-sqlguard lnmp-fw lnmp-cutlogs)
    local -a srcs=("conf/${stack}" tools/lnmp-backup.sh tools/lnmp-tgnotice.sh \
                   tools/lnmp-phpmyadmin.sh tools/lnmp-perm.sh tools/lnmp-health.sh \
                   tools/lnmp-sqlguard.sh tools/lnmp-fw.sh tools/cut_nginx_logs.sh)
    local i name stage build_id swapped=0 failed='' restore_rc=0

    if [ -z "${bindir}" ] || [ ! -d "${bindir}" ]; then
        Echo_Red "安装管理命令失败：目标目录不存在：${bindir}"
        return 1
    fi
    for i in "${!names[@]}"; do
        if [ ! -s "${cur_dir}/${srcs[i]}" ]; then
            Echo_Red "安装管理命令失败：缺少 ${cur_dir}/${srcs[i]}"
            return 1
        fi
    done

    # 暂存目录与目标同一文件系统，换入为 rename。上次中断留下的暂存目录先清理。
    rm -rf "${bindir}"/.lnmp-deploy.* 2>/dev/null
    stage=$(mktemp -d "${bindir}/.lnmp-deploy.XXXXXXXX") || {
        Echo_Red "安装管理命令失败：无法在 ${bindir} 创建暂存目录。"
        return 1
    }
    mkdir "${stage}/new" "${stage}/old" || { rm -rf "${stage}"; return 1; }

    bash "${cur_dir}/include/rt/cli_assemble.sh" "${cur_dir}" "${stack}" > "${stage}/new/lnmp" || failed='组装'
    # 工具中的服务运行部分加载行替换为文件内容，部署产物不依赖源码目录。
    for i in "${!names[@]}"; do
        [ -n "${failed}" ] && break
        [ "${i}" -eq 0 ] && continue
        bash "${cur_dir}/include/rt/cli_assemble.sh" "${cur_dir}" "${srcs[i]}" > "${stage}/new/${names[i]}" \
            || failed="组装 ${names[i]}"
    done
    for name in "${names[@]}"; do
        [ -n "${failed}" ] && break
        if [ ! -s "${stage}/new/${name}" ] || ! bash -n "${stage}/new/${name}" 2>/dev/null; then
            failed="语法检查 ${name}"
        fi
    done

    if [ -z "${failed}" ]; then
        build_id=$(for name in "${names[@]}"; do cat "${stage}/new/${name}"; done \
            | { sha256sum 2>/dev/null || cksum; } | awk '{print substr($1, 1, 16)}')
        for name in "${names[@]}"; do
            printf '\n# LNMP-BUILD-ID: %s\n' "${build_id}" >> "${stage}/new/${name}" \
                && chmod 755 "${stage}/new/${name}" || failed="写入构建 ID ${name}"
        done
    fi

    for name in "${names[@]}"; do
        [ -n "${failed}" ] && break
        if [ -e "${bindir}/${name}" ] && ! \cp -p "${bindir}/${name}" "${stage}/old/${name}"; then
            failed="备份 ${name}"
        fi
    done

    for name in "${names[@]}"; do
        [ -n "${failed}" ] && break
        if ! mv -f -T "${stage}/new/${name}" "${bindir}/${name}"; then
            failed="换入 ${name}"
            break
        fi
        swapped=$((swapped + 1))
    done

    if [ -z "${failed}" ]; then
        declare -F Deploy_Test_Hook >/dev/null 2>&1 && Deploy_Test_Hook "${bindir}"
        for name in "${names[@]}"; do
            if [ ! -x "${bindir}/${name}" ] \
               || ! grep -qx "# LNMP-BUILD-ID: ${build_id}" "${bindir}/${name}"; then
                failed="核对构建 ID ${name}"
                break
            fi
        done
    fi

    if [ -z "${failed}" ]; then
        rm -rf "${stage}"
        return 0
    fi

    Echo_Red "安装管理命令失败（${failed}），正在恢复部署前的文件。"
    for ((i = 0; i < swapped; i++)); do
        name=${names[i]}
        if [ -f "${stage}/old/${name}" ]; then
            if ! \cp -p "${stage}/old/${name}" "${bindir}/.lnmp-restore.${name}" \
               || ! mv -f -T "${bindir}/.lnmp-restore.${name}" "${bindir}/${name}"; then
                Echo_Red "恢复 ${bindir}/${name} 失败，备份保留在 ${stage}/old。"
                restore_rc=1
            fi
        elif ! rm -f "${bindir}/${name}"; then
            Echo_Red "删除未部署前不存在的 ${bindir}/${name} 失败。"
            restore_rc=1
        fi
    done
    if [ "${restore_rc}" -ne 0 ]; then
        return 2
    fi
    rm -rf "${stage}"
    return 1
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
    local stack=$1

    case "${stack}" in lnmp|lnmpa|lamp) ;; *)
        Echo_Red "未知管理脚本类型：${stack}"
        return 1
        ;;
    esac

    Deploy_LNMP_Command_Group "${stack}" /bin || return $?

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
    if ! Svc_Install_Unit "${src}" "${dst}"; then
        Echo_Red "安装权限诊断单元失败：${dst}"
        return 1
    fi
    return 0
}

# lnmp app 托管 Node/Go 等应用进程时按实例启动该模板单元。
Install_App_Unit_Tpl()
{
    local src="${cur_dir}/init.d/lnmp-app@.service"
    local dst="/etc/systemd/system/lnmp-app@.service"

    [ -d /etc/systemd/system ] || return 0
    if ! Svc_Install_Unit "${src}" "${dst}"; then
        Echo_Red "安装应用托管单元失败：${dst}"
        return 1
    fi
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
    local service timer

    [ -d /etc/systemd/system ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    if [ ! -x /bin/lnmp-cutlogs ]; then
        Echo_Yellow "缺少 /bin/lnmp-cutlogs，跳过日志切割定时任务。"
        return 0
    fi

    service='[Unit]
Description=LNMP nginx log rotation

[Service]
Type=oneshot
ExecStart=/bin/lnmp-cutlogs'
    timer='[Unit]
Description=Daily LNMP nginx log rotation

[Timer]
OnCalendar=*-*-* 00:05:00
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target'
    if ! Svc_Install_Timer /etc/systemd/system/lnmp-cutlogs.service \
            /etc/systemd/system/lnmp-cutlogs.timer "${service}" "${timer}"; then
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
        Svc_Running "${service}" && return 0
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
    # 定时任务装不上不影响已装好的服务，不改变本函数的返回码。
    Install_Health_Timer
    Install_Cutlogs_Timer
    Install_Logrotate_Conf
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
    [ "$(PHP_Detect_Sapi lnmpa)" = fpm ] && { Start_And_Verify php-fpm || rc=1; }
    Start_And_Verify httpd || rc=1
    Install_Health_Timer
    Install_Cutlogs_Timer
    Install_Logrotate_Conf
    return ${rc}
}

Add_LAMP_Startup()
{
    local rc=0

    echo "正在设置开机启动并启动 LAMP..."
    Install_LNMP_Command lamp || return 1
    Set_Tools_Permission || return 1
    [ "$(PHP_Detect_Sapi lamp)" = fpm ] && { Start_And_Verify php-fpm || rc=1; }
    Start_And_Verify httpd || rc=1
    Startup_DB || rc=1
    Install_Health_Timer
    Install_Cutlogs_Timer
    Install_Logrotate_Conf
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
socket=$(Db_Socket)
EOF
    "${bin}" --defaults-file="${opt}" -e "SELECT 1;" >/dev/null 2>&1
    rc=$?
    rm -f "${opt}"
    return ${rc}
}

# _Probe_Install_Reload <栈>：配置测试后重载该栈的 Web 服务。
_Probe_Install_Reload()
{
    case "$1" in
    lnmp|lnmpa)
        /usr/local/nginx/sbin/nginx -t >/dev/null 2>&1 && StartOrStop reload nginx >/dev/null 2>&1 || return 1
        ;;
    esac
    case "$1" in
    lnmpa|lamp)
        /usr/local/apache/bin/httpd -t >/dev/null 2>&1 && StartOrStop reload httpd >/dev/null 2>&1 || return 1
        ;;
    esac
    return 0
}

# Probe_Install_PHP <栈>：安装收尾经本机 80 端口实际请求主 PHP。默认站点按设计不执行任意 PHP，
# 因此临时加入只响应随机 .invalid 域名的探测站点，PHP 处理沿用站点的 enable-php.conf、
# proxy-pass-php.conf 或 Apache 全局处理器；目录建在默认站点下的隐藏目录，满足兜底 open_basedir。
# 验收后删除探测配置与目录并重载。0 通过；1 未通过。
Probe_Install_PHP()
{
    local stack=$1 name host dir ngx='' apa='' port=80 want rc i

    name="lnmp_probe_$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
    host="${name//_/-}.invalid"
    want=$(/usr/local/php/bin/php-config --version 2>/dev/null)
    dir=$(mktemp -d "${Default_Website_Dir}/.lnmp-probe.XXXXXX") || return 1
    chmod 755 "${dir}"
    case "${stack}" in
    lnmp)  ngx="/usr/local/nginx/conf/vhost/${name}.conf" ;;
    lnmpa) ngx="/usr/local/nginx/conf/vhost/${name}.conf"; apa="/usr/local/apache/conf/vhost/${name}.conf"; port=88 ;;
    lamp)  apa="/usr/local/apache/conf/vhost/${name}.conf" ;;
    *) rm -rf -- "${dir}"; return 1 ;;
    esac
    if [ -n "${ngx}" ]; then
        printf 'server {\n    listen 80;\n    server_name %s;\n    root %s;\n    access_log off;\n    include %s;\n}\n' \
            "${host}" "${dir}" "$([ "${stack}" = lnmpa ] && echo proxy-pass-php.conf || echo enable-php.conf)" > "${ngx}" || rc=1
    fi
    if [ -n "${apa}" ]; then
        printf '<VirtualHost *:%s>\nServerName %s\nDocumentRoot "%s"\n<Directory "%s">\n    AllowOverride None\n    Require all granted\n</Directory>\n</VirtualHost>\n' \
            "${port}" "${host}" "${dir}" "${dir}" > "${apa}" || rc=1
    fi
    if [ -z "${rc}" ] && _Probe_Install_Reload "${stack}"; then
        # reload 后旧工作进程可能仍在处理连接，未到达探测站点时重试。
        for i in 1 2 3 4 5; do
            Web_Probe php "${host}" 80 "${dir}" "${want}"
            rc=$?
            [ "${rc}" -eq 5 ] || break
            sleep 1
        done
    else
        Echo_Red "错误：PHP 请求验收所需的临时探测站点无法写入或未通过配置测试。"
        rc=1
    fi
    rm -f -- ${ngx:+"${ngx}"} ${apa:+"${apa}"}
    rm -rf -- "${dir}"
    _Probe_Install_Reload "${stack}" || Echo_Red "删除临时探测站点后重载失败，请执行 lnmp reload。"
    case "${rc}" in
    0) Echo_Green "$(Web_Probe_Report 0 php "本机 Web 入口")"; return 0 ;;
    1) return 1 ;;
    7|8) Web_Probe_Report "${rc}" php "本机 Web 入口"; return 0 ;;
    esac
    Echo_Red "错误：$(Web_Probe_Report "${rc}" php "本机 Web 入口" "${want}")"
    return 1
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
    if ! Svc_Running nginx; then
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
    if ! Svc_Running "${DB_Service}"; then
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
    if [ "$(PHP_Detect_Sapi "${Stack}")" = fpm ]; then
        if [[ ! -s /usr/local/php/sbin/php-fpm || ! -s /usr/local/php/etc/php.ini || ! -s /usr/local/php/bin/php ]]; then
            Echo_Red "错误：PHP 安装失败。"
            return 1
        fi
        if ! Svc_Running php-fpm; then
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
    if [[ ! -s /usr/local/apache/bin/httpd || ! -s /usr/local/apache/conf/httpd.conf ]]; then
        Echo_Red "错误：Apache 安装失败。"
        return 1
    fi
    if [ "$(PHP_Detect_Sapi "${Stack}")" = fpm ]; then
        if [ ! -s /usr/local/apache/modules/mod_proxy_fcgi.so ] || [ ! -s /usr/local/apache/modules/mod_mpm_event.so ]; then
            Echo_Red "错误：Apache 缺少 mod_proxy_fcgi 或 mod_mpm_event，PHP 请求无法交给 PHP-FPM。"
            return 1
        fi
    elif [ ! -s "/usr/local/apache/modules/${PHP_Apache_Module}" ]; then
        Echo_Red "错误：Apache 安装失败（缺少 ${PHP_Apache_Module}）。"
        return 1
    fi
    if ! /usr/local/apache/bin/httpd -t >/dev/null 2>&1; then
        Echo_Red "错误：Apache 配置检查未通过，执行 /usr/local/apache/bin/httpd -t 查看详情。"
        return 1
    fi
    if ! Check_Apache_MPM_For_ModPHP; then
        return 1
    fi
    if ! Svc_Running httpd; then
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

# 默认 PHP 扩展失败不中止安装，结束时重复列出，避免编译期提示被后续输出淹没。
# 扩展属可选组件，不改变安装返回码。
Check_PHP_Ext_Result()
{
    [ -n "${PHP_Default_Ext_Failed}" ] || return 0

    echo
    Echo_Red "════════════════ 部分 PHP 扩展未安装 ════════════════"
    Echo_Red "未装成功：${PHP_Default_Ext_Failed# }"
    Echo_Yellow "其余组件不受影响，编译详情见 /root/lnmp-install.log。"
    Echo_Yellow "opcache、Redis、imageMagick 可用 ./addons.sh install 重试。"
    Echo_Red "══════════════════════════════════════════════════"
    return 0
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
    # 组件各自正常后，再经 Web 入口实际执行一次 PHP。
    if [[ "${isNginx}" = "ok" && "${isDB}" = "ok" && "${isPHP}" = "ok" ]] && ! Probe_Install_PHP lnmp; then
        isPHP=""
    fi
    if [[ "${isNginx}" = "ok" && "${isDB}" = "ok" && "${isPHP}" = "ok" ]]; then
        Print_Sucess_Info
        # 组件齐全后仍需分别检查防火墙和数据库初始化，两项均通过才返回成功。
        local rc=0
        Check_PHP_Ext_Result
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
    # 组件各自正常后，再经 Web 入口实际执行一次 PHP。
    if [[ "${isNginx}" = "ok" && "${isDB}" = "ok" && "${isPHP}" = "ok" && "${isApache}" = "ok" ]] && ! Probe_Install_PHP lnmpa; then
        isPHP=""
    fi
    if [[ "${isNginx}" = "ok" && "${isDB}" = "ok" && "${isPHP}" = "ok" && "${isApache}" = "ok" ]]; then
        Print_Sucess_Info
        local rc=0
        Check_PHP_Ext_Result
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
    # 组件各自正常后，再经 Web 入口实际执行一次 PHP。
    if [[ "${isApache}" = "ok" && "${isDB}" = "ok" && "${isPHP}" = "ok" ]] && ! Probe_Install_PHP lamp; then
        isPHP=""
    fi
    if [[ "${isApache}" = "ok" && "${isDB}" = "ok" && "${isPHP}" = "ok" ]]; then
        Print_Sucess_Info
        local rc=0
        Check_PHP_Ext_Result
        Check_Firewall_Result || rc=1
        Check_DB_Init_Result || rc=1
        return ${rc}
    fi
    Print_Failed_Info
    return 1
}
