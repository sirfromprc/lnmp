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
# 只在完整安装收尾调用：bumpversion 同步管理命令时不应改动定时任务。
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
# 新建站点无需登记。只在有 Nginx 的栈调用：切割后要 reload 才会重开日志，
# Apache 的日志不由该脚本处理。
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

Add_LNMP_Startup()
{
    echo "正在设置开机启动并启动 LNMP..."
    Install_LNMP_Command lnmp || return 1
    Set_Tools_Permission || return 1
    StartUp nginx
    StartOrStop start nginx
    Startup_DB || return 1
    StartUp php-fpm
    StartOrStop start php-fpm
    if [ "${PHP_Branch}" = "5.2" ]; then
        sed -i 's#/usr/local/php/var/run/php-fpm.pid#/usr/local/php/logs/php-fpm.pid#' /bin/lnmp
        Sync_LNMP_Command_Alias || return 1
    fi
    Install_Health_Timer
    Install_Cutlogs_Timer
}

# 各安装栈共用数据库启动流程，并按已安装的服务类型启用对应服务。
Startup_DB()
{
    if [ "${DB_Kind}" = "none" ]; then
        return 0
    fi
    StartUp "${DB_Service}"
    StartOrStop start "${DB_Service}"
}

Add_LNMPA_Startup()
{
    echo "正在设置开机启动并启动 LNMPA..."
    Install_LNMP_Command lnmpa || return 1
    Set_Tools_Permission || return 1
    StartUp nginx
    StartOrStop start nginx
    Startup_DB || return 1
    StartUp httpd
    StartOrStop start httpd
    Install_Health_Timer
    Install_Cutlogs_Timer
}

Add_LAMP_Startup()
{
    echo "正在设置开机启动并启动 LAMP..."
    Install_LNMP_Command lamp || return 1
    Set_Tools_Permission || return 1
    StartUp httpd
    StartOrStop start httpd
    Startup_DB || return 1
    Install_Health_Timer
}

Check_Nginx_Files()
{
    isNginx=""
    echo "============================== 检查安装结果 =============================="
    echo "正在检查..."
    if [[ -s /usr/local/nginx/conf/nginx.conf && -s /usr/local/nginx/sbin/nginx ]]; then
        # 文件存在不代表可用，配置语法错误会导致 nginx 无法启动。
        if /usr/local/nginx/sbin/nginx -t >/dev/null 2>&1; then
            Echo_Green "Nginx：正常"
            isNginx="ok"
        else
            Echo_Red "错误：Nginx 配置检查未通过，执行 /usr/local/nginx/sbin/nginx -t 查看详情。"
        fi
    else
        Echo_Red "错误：Nginx 安装失败。"
    fi
}

Check_DB_Files()
{
    local db_client db_safe

    isDB=""
    if [ "${DB_Kind}" = "none" ]; then
        Echo_Green "未安装 MySQL/MariaDB。"
        isDB="ok"
    elif [ "${DB_Kind}" = "mariadb" ]; then
        db_client=$(First_Executable "${MySQL_Dir}/bin/mariadb" "${MySQL_Dir}/bin/mysql")
        db_safe=$(First_Executable "${MySQL_Dir}/bin/mariadbd-safe" "${MySQL_Dir}/bin/mysqld_safe")
        if [ -n "${db_client}" ] && [ -n "${db_safe}" ] && [ -s /etc/my.cnf ]; then
            MySQL_Bin="${db_client}"
            Echo_Green "MariaDB：正常"
            isDB="ok"
        else
            Echo_Red "错误：MariaDB 安装失败。"
        fi
    elif [[ -s ${MySQL_Dir}/bin/mysql && -s ${MySQL_Dir}/bin/mysqld_safe && -s /etc/my.cnf ]]; then
        MySQL_Bin="${MySQL_Dir}/bin/mysql"
        Echo_Green "MySQL：正常"
        isDB="ok"
    else
        if [ "${DB_Kind}" = "mariadb" ]; then
            Echo_Red "错误：MariaDB 安装失败。"
        else
            Echo_Red "错误：MySQL 安装失败。"
        fi
    fi
}

Check_PHP_Files()
{
    isPHP=""
    if [ "${Stack}" = "lnmp" ]; then
        if [[ -s /usr/local/php/sbin/php-fpm && -s /usr/local/php/etc/php.ini && -s /usr/local/php/bin/php ]]; then
            Echo_Green "PHP：正常"
            Echo_Green "PHP-FPM：正常"
            isPHP="ok"
        else
            Echo_Red "错误：PHP 安装失败。"
        fi
    else
        if [[ -s /usr/local/php/bin/php && -s /usr/local/php/etc/php.ini ]]; then
            Echo_Green "PHP：正常"
            isPHP="ok"
        else
            Echo_Red "错误：PHP 安装失败。"
        fi
    fi
}

Check_Apache_Files()
{
    isApache=""
    if [[ -s /usr/local/apache/bin/httpd && -s /usr/local/apache/modules/${PHP_Apache_Module} && -s /usr/local/apache/conf/httpd.conf ]]; then
        Echo_Green "Apache：正常"
        isApache="ok"
    else
        Echo_Red "错误：Apache 安装失败。"
    fi
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
