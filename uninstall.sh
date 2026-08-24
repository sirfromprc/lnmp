#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ "$(id -u)" != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi

cur_dir=$(pwd)
Stack=$1

LNMP_Ver='2.3'

. lnmp.conf
. include/main.sh
. include/verify.sh
. include/firewall.sh
. include/openresty.sh
. include/cleanup.sh

shopt -s extglob

Check_DB
Get_Dist_Name

clear 2>/dev/null || true
Print_Banner \
    "LNMP V${LNMP_Ver} 卸载工具" \
    "卸载 LNMP、LNMPA 或 LAMP 组件" \
    "执行前请确认重要配置和数据已经备份"

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


# ---------------------------------------------------------------------------
# 卸载过程中失败或有残留的步骤。删除动作不因单步失败而中断，但末尾必须据此
# 决定输出和返回码，不能无条件打印“卸载完成”。
Uninstall_Failures=()

Record_Uninstall_Failure()
{
    Echo_Red "$1"
    Uninstall_Failures+=("$1")
}

# Run_Uninstall_Step <描述> <命令> [参数...]
# 执行一步清理，失败时记录并继续，返回该步的结果供调用方判断。
Run_Uninstall_Step()
{
    local what="$1"
    shift
    if "$@"; then
        return 0
    fi
    Record_Uninstall_Failure "${what}失败"
    return 1
}

# Remove_Uninstall_Path <路径>...
# 删除后确认目标确实消失；空值和系统关键目录一律拒绝。
Remove_Uninstall_Path()
{
    local path
    for path in "$@"; do
        case "${path}" in
        ''|/|/bin|/etc|/root|/usr|/usr/local|/var|/var/lib)
            Record_Uninstall_Failure "拒绝删除受保护路径：${path:-空值}"
            continue
            ;;
        esac
        [ -e "${path}" ] || [ -L "${path}" ] || continue
        rm -rf -- "${path}"
        if [ -e "${path}" ] || [ -L "${path}" ]; then
            Record_Uninstall_Failure "删除失败，仍然存在：${path}"
        fi
    done
    return 0
}

# Disable_Stack_Service <服务名>
# 取消自启后按服务状态复核，仍在运行或仍自启都记为失败。
Disable_Stack_Service()
{
    local svc="$1"

    Remove_StartUp "${svc}"
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        Record_Uninstall_Failure "${svc}.service 仍在运行"
        return 1
    fi
    if systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
        Record_Uninstall_Failure "${svc}.service 仍是开机自启"
        return 1
    fi
    return 0
}

# 三个栈共有的卸载目标，供删除后复核；按栈独有的路径由调用方追加。
Common_Uninstall_Targets()
{
    local -a targets=(
        /usr/local/php
        /usr/local/zend
        /usr/local/phpmyadmin
        /var/lib/phpmyadmin
        /usr/local/acme.sh
        /bin/lnmp
        /bin/lnmp-backup
        /bin/lnmp-tgnotice
        /bin/lnmp-phpmyadmin
        /bin/lnmp-perm
        /bin/lnmp-health
        /bin/lnmp-sqlguard
        /bin/lnmp-fw
        /bin/lnmp-cutlogs
        /etc/profile.d/lnmp-tgnotice.sh
        /etc/systemd/system/php-fpm@.service
        /etc/systemd/system/lnmp-app@.service
        /etc/systemd/system/lnmp-perm-diagnose@.service
        /etc/systemd/system/lnmp-backup.timer
        /etc/systemd/system/lnmp-backup.service
        /etc/systemd/system/lnmp-health.timer
        /etc/systemd/system/lnmp-health.service
        /etc/systemd/system/lnmp-cutlogs.timer
        /etc/systemd/system/lnmp-cutlogs.service
        /etc/systemd/system/lnmp-perm.timer
        /etc/systemd/system/lnmp-perm.service
        /etc/cron.d/lnmp-backup
        /etc/cron.d/lnmp-perm
        /etc/cron.d/lnmp-health
        /etc/lnmp/backup-mysql.cnf
        "${FW_UNIT_FILE}"
        "${FW_INCLUDE_FILE}"
    )
    if [ -n "${DB_Name}" ] && [ "${DB_Name}" != "None" ]; then
        targets+=(
            "/usr/local/${DB_Name}"
            "/etc/init.d/${DB_Name}"
            "/etc/systemd/system/${DB_Name}.service"
            /etc/my.cnf
        )
    fi
    printf '%s\n' "${targets[@]}"
}

# 删除动作结束后统一复核目标是否真的消失，只看命令返回码会漏掉被忽略的失败。
Check_Uninstall_Residue()
{
    local path
    for path in "$@"; do
        [ -e "${path}" ] || [ -L "${path}" ] || continue
        Record_Uninstall_Failure "残留：${path}"
    done
    if command -v nft >/dev/null 2>&1 && nft list table ${FW_TABLE} >/dev/null 2>&1; then
        Record_Uninstall_Failure "残留防火墙表：${FW_TABLE}"
    fi
    if crontab -l 2>/dev/null | grep -qF '/usr/local/acme.sh'; then
        Record_Uninstall_Failure "残留 acme.sh 定时任务（root 的 crontab）"
    fi
    return 0
}

# 卸载结束时给出结论：有失败或残留就逐条列出并返回非零。
Report_Uninstall_Result()
{
    local stack="$1" item

    if [ ${#Uninstall_Failures[@]} -eq 0 ]; then
        echo "${stack} 卸载完成。"
        return 0
    fi
    Echo_Red "${stack} 卸载未完成，以下步骤失败或有残留："
    for item in "${Uninstall_Failures[@]}"; do
        Echo_Red "  - ${item}"
    done
    Echo_Red "请按上述条目处理后重新执行卸载。addons 组件与网站数据为设计保留项，不在此列。"
    return 1
}

# 停止数据库并备份数据，任一步失败均中止卸载。
Stop_And_Backup_DB()
{
    [ "${DB_Name}" = "None" ] && return 0
    Remove_StartUp ${DB_Name}
    if [ "${DB_Name}" = "mysql" ]; then
        Backup_DB_Data "${MySQL_Data_Dir}" || exit 1
    elif [ "${DB_Name}" = "mariadb" ]; then
        Backup_DB_Data "${MariaDB_Data_Dir}" || exit 1
    fi
}


# ---------------------------------------------------------------------------
# addons 安装的 Redis 与 Memcached 不在各栈 kill/stop 的覆盖范围内，
# 卸载时需显式停止并取消开机自启，否则进程与自启项会留到下一次安装。
Stop_Addons_Services()
{
    # 测试注入点，默认取实际系统路径；停服会真的执行，定向测试必须指到临时目录。
    local initd="${LNMP_UNINST_INITD_DIR:-/etc/init.d}"
    local unit_dir="${LNMP_UNINST_SYSTEMD_DIR:-/etc/systemd/system}"
    local svc
    for svc in redis memcached; do
        [ -x "${initd}/${svc}" ] || [ -s "${unit_dir}/${svc}.service" ] || continue
        echo "正在停止 addons 组件 ${svc}..."
        [ -x "${initd}/${svc}" ] && "${initd}/${svc}" stop 2>/dev/null
        Remove_StartUp "${svc}"
    done
    return 0
}

# 卸载栈不删除 addons 的程序目录，需明确告知清理方式，
# 避免下次安装静默复用旧实例。
Notice_Addons_Residue()
{
    # 程序目录的注入点与 include/firewall.sh 的 Block_Addons_Ports 同名，
    # 一致性由 t/consistency.sh 的 V18 检查。
    local redis_dir="${LNMP_FW_REDIS_DIR:-/usr/local/redis}"
    local memcached_dir="${LNMP_FW_MEMCACHED_DIR:-/usr/local/memcached}"
    local left=''
    [ -d "${redis_dir}" ] && left="${left} redis"
    [ -d "${memcached_dir}" ] && left="${left} memcached"
    [ -n "${left}" ] || return 0
    Echo_Yellow "以下 addons 组件已停止并取消开机自启，程序目录仍保留：${left# }"
    Echo_Yellow "需要彻底删除请在源码目录执行：./addons.sh uninstall <组件名>"
    Echo_Yellow "保留期间防火墙规则已随本次卸载清空，重新安装栈后请执行 lnmp-fw sync 或重装该组件。"
    return 0
}

# 停服结果以进程是否残留为准：停服命令的返回码会被后一条覆盖，也无法反映
# 进程实际状态。仍有进程在跑时必须返回非零，调用方据此放弃删除阶段。
Stop_Stack_Services()
{
    local svc left=''

    if command -v lnmp >/dev/null 2>&1; then
        lnmp kill
        lnmp stop
        Stop_Addons_Services
    else
        Echo_Yellow "/bin/lnmp 不存在（通常是上次安装未完成），改用 init 脚本逐个停止。"
        for svc in nginx php-fpm mysql mariadb httpd pureftpd; do
            [ -x "/etc/init.d/${svc}" ] && "/etc/init.d/${svc}" stop 2>/dev/null
        done
        # init 脚本缺失时按进程名停止服务。
        for svc in nginx php-fpm mysqld httpd; do
            pkill -x "${svc}" 2>/dev/null
        done
        Stop_Addons_Services
    fi

    command -v pgrep >/dev/null 2>&1 || return 0
    for svc in nginx httpd php-fpm php-cgi mysqld mariadbd; do
        pgrep -x "${svc}" >/dev/null 2>&1 && left="${left} ${svc}"
    done
    if [ -n "${left}" ]; then
        Record_Uninstall_Failure "以下进程仍在运行：${left# }"
        return 1
    fi
    return 0
}

Uninstall_LNMP()
{
    echo "正在停止 LNMP..."
    if ! Stop_Stack_Services; then
        Echo_Red "服务未全部停止，已中止卸载，未删除任何文件。"
        Echo_Red "请手工停止上述进程后重新执行卸载。"
        return 1
    fi

    Disable_Stack_Service nginx
    Disable_Stack_Service php-fpm
    # 数据备份在删除操作前完成，失败时中止卸载。
    Stop_And_Backup_DB

    chattr -i ${Default_Website_Dir}/.user.ini 2>/dev/null
    echo "正在删除 LNMP 文件..."
    # OpenResty 使用 /usr/local/nginx 软链接，需先卸载软件包并移除链接。
    if [ -d /usr/local/openresty ]; then
        Uninstall_OpenResty
    fi
    Remove_Uninstall_Path /usr/local/nginx
    Remove_Uninstall_Path /usr/local/php
    Remove_Uninstall_Path /usr/local/zend
    # phpMyAdmin 及模板缓存位于网站根目录之外。
    Remove_Uninstall_Path /usr/local/phpmyadmin /usr/local/phpmyadmin.bak.*
    Remove_Uninstall_Path /var/lib/phpmyadmin

    Run_Uninstall_Step "删除数据库程序与配置" Remove_DB_Files
    Run_Uninstall_Step "删除多版本 PHP" Remove_Multiple_PHP
    Run_Uninstall_Step "卸载 acme.sh" Remove_Acme
    Run_Uninstall_Step "清理备份定时任务" Remove_Backup_Schedule
    Run_Uninstall_Step "清理巡检定时任务" Remove_Health_Schedule
    Run_Uninstall_Step "清理日志切割定时任务" Remove_Cutlogs_Schedule
    Run_Uninstall_Step "取消应用托管" Remove_App_Hosting
    Run_Uninstall_Step "清理权限校验钩子" Remove_Perm_Hooks

    Remove_Uninstall_Path /etc/init.d/nginx
    Remove_Uninstall_Path /etc/init.d/php-fpm
    Remove_Uninstall_Path /bin/lnmp
    Remove_Uninstall_Path /bin/lnmp-backup
    Remove_Uninstall_Path /bin/lnmp-tgnotice
    Remove_Uninstall_Path /bin/lnmp-phpmyadmin
    Remove_Uninstall_Path /bin/lnmp-perm
    Remove_Uninstall_Path /bin/lnmp-health
    Remove_Uninstall_Path /bin/lnmp-sqlguard
    Remove_Uninstall_Path /bin/lnmp-fw
    Remove_Uninstall_Path /bin/lnmp-cutlogs
    Remove_Uninstall_Path /etc/profile.d/lnmp-tgnotice.sh
    Run_Uninstall_Step "清理 /etc/lnmp" Remove_Lnmp_Conf_Dir
    Run_Uninstall_Step "清理防火墙规则" Firewall_Purge
    Notice_Addons_Residue

    local -a residue=()
    mapfile -t residue < <(Common_Uninstall_Targets)
    residue+=(
        /usr/local/nginx
        /etc/init.d/nginx
        /etc/init.d/php-fpm
        /etc/systemd/system/nginx.service
        /etc/systemd/system/php-fpm.service
    )
    Check_Uninstall_Residue "${residue[@]}"
    Report_Uninstall_Result LNMP
}

Uninstall_LNMPA()
{
    echo "正在停止 LNMPA..."
    if ! Stop_Stack_Services; then
        Echo_Red "服务未全部停止，已中止卸载，未删除任何文件。"
        Echo_Red "请手工停止上述进程后重新执行卸载。"
        return 1
    fi

    Disable_Stack_Service nginx
    Disable_Stack_Service httpd
    Stop_And_Backup_DB

    chattr -i ${Default_Website_Dir}/.user.ini 2>/dev/null
    echo "正在删除 LNMPA 文件..."
    Remove_Uninstall_Path /usr/local/nginx
    Remove_Uninstall_Path /usr/local/php
    Remove_Uninstall_Path /usr/local/apache
    Remove_Uninstall_Path /usr/local/zend
    # phpMyAdmin 及模板缓存位于网站根目录之外。
    Remove_Uninstall_Path /usr/local/phpmyadmin /usr/local/phpmyadmin.bak.*
    Remove_Uninstall_Path /var/lib/phpmyadmin

    Run_Uninstall_Step "删除数据库程序与配置" Remove_DB_Files
    Run_Uninstall_Step "删除多版本 PHP" Remove_Multiple_PHP
    Run_Uninstall_Step "卸载 acme.sh" Remove_Acme
    Run_Uninstall_Step "清理备份定时任务" Remove_Backup_Schedule
    Run_Uninstall_Step "清理巡检定时任务" Remove_Health_Schedule
    Run_Uninstall_Step "清理日志切割定时任务" Remove_Cutlogs_Schedule
    Run_Uninstall_Step "取消应用托管" Remove_App_Hosting
    Run_Uninstall_Step "清理权限校验钩子" Remove_Perm_Hooks

    Remove_Uninstall_Path /etc/init.d/nginx
    Remove_Uninstall_Path /etc/init.d/httpd
    Remove_Uninstall_Path /bin/lnmp
    Remove_Uninstall_Path /bin/lnmp-backup
    Remove_Uninstall_Path /bin/lnmp-tgnotice
    Remove_Uninstall_Path /bin/lnmp-phpmyadmin
    Remove_Uninstall_Path /bin/lnmp-perm
    Remove_Uninstall_Path /bin/lnmp-health
    Remove_Uninstall_Path /bin/lnmp-sqlguard
    Remove_Uninstall_Path /bin/lnmp-fw
    Remove_Uninstall_Path /bin/lnmp-cutlogs
    Remove_Uninstall_Path /etc/profile.d/lnmp-tgnotice.sh
    Run_Uninstall_Step "清理 /etc/lnmp" Remove_Lnmp_Conf_Dir
    Run_Uninstall_Step "清理防火墙规则" Firewall_Purge
    Notice_Addons_Residue

    local -a residue=()
    mapfile -t residue < <(Common_Uninstall_Targets)
    residue+=(
        /usr/local/nginx
        /usr/local/apache
        /etc/init.d/nginx
        /etc/init.d/httpd
        /etc/systemd/system/nginx.service
        /etc/systemd/system/httpd.service
        /etc/systemd/system/php-fpm.service
    )
    Check_Uninstall_Residue "${residue[@]}"
    Report_Uninstall_Result LNMPA
}

Uninstall_LAMP()
{
    echo "正在停止 LAMP..."
    if ! Stop_Stack_Services; then
        Echo_Red "服务未全部停止，已中止卸载，未删除任何文件。"
        Echo_Red "请手工停止上述进程后重新执行卸载。"
        return 1
    fi

    Disable_Stack_Service httpd
    Stop_And_Backup_DB

    chattr -i ${Default_Website_Dir}/.user.ini 2>/dev/null
    echo "正在删除 LAMP 文件..."
    Remove_Uninstall_Path /usr/local/apache
    Remove_Uninstall_Path /usr/local/php
    Remove_Uninstall_Path /usr/local/zend
    # phpMyAdmin 及模板缓存位于网站根目录之外。
    Remove_Uninstall_Path /usr/local/phpmyadmin /usr/local/phpmyadmin.bak.*
    Remove_Uninstall_Path /var/lib/phpmyadmin

    Run_Uninstall_Step "删除数据库程序与配置" Remove_DB_Files
    Run_Uninstall_Step "删除多版本 PHP" Remove_Multiple_PHP
    Run_Uninstall_Step "卸载 acme.sh" Remove_Acme
    Run_Uninstall_Step "清理备份定时任务" Remove_Backup_Schedule
    Run_Uninstall_Step "清理巡检定时任务" Remove_Health_Schedule
    Run_Uninstall_Step "清理日志切割定时任务" Remove_Cutlogs_Schedule
    Run_Uninstall_Step "取消应用托管" Remove_App_Hosting
    Run_Uninstall_Step "清理权限校验钩子" Remove_Perm_Hooks

    Remove_Uninstall_Path /etc/my.cnf
    Remove_Uninstall_Path /etc/init.d/httpd
    Remove_Uninstall_Path /bin/lnmp
    Remove_Uninstall_Path /bin/lnmp-backup
    Remove_Uninstall_Path /bin/lnmp-tgnotice
    Remove_Uninstall_Path /bin/lnmp-phpmyadmin
    Remove_Uninstall_Path /bin/lnmp-perm
    Remove_Uninstall_Path /bin/lnmp-health
    Remove_Uninstall_Path /bin/lnmp-sqlguard
    Remove_Uninstall_Path /bin/lnmp-fw
    Remove_Uninstall_Path /bin/lnmp-cutlogs
    Remove_Uninstall_Path /etc/profile.d/lnmp-tgnotice.sh
    Run_Uninstall_Step "清理 /etc/lnmp" Remove_Lnmp_Conf_Dir
    Run_Uninstall_Step "清理防火墙规则" Firewall_Purge
    Notice_Addons_Residue

    local -a residue=()
    mapfile -t residue < <(Common_Uninstall_Targets)
    residue+=(
        /usr/local/apache
        /etc/init.d/httpd
        /etc/systemd/system/httpd.service
    )
    Check_Uninstall_Residue "${residue[@]}"
    Report_Uninstall_Result LAMP
}

# 卸载会停服务、搬数据库并删除程序与配置，确认必须来自真实终端且输入完整栈名。
# LNMP_Auto 不能跳过该确认；自动化须显式提供 LNMP_Uninstall_Confirm=uninstall-<栈>。
Confirm_Uninstall()
{
    local stack="$1" expect ans
    expect="uninstall-${stack}"

    if [ -n "${LNMP_Uninstall_Confirm:-}" ]; then
        if [ "${LNMP_Uninstall_Confirm:-}" = "${expect}" ]; then
            echo "已通过 LNMP_Uninstall_Confirm=${expect} 确认卸载 ${stack}。"
            return 0
        fi
        Echo_Red "LNMP_Uninstall_Confirm 与本次卸载不匹配，已取消。"
        Echo_Red "卸载 ${stack} 需要：LNMP_Uninstall_Confirm=${expect}"
        return 1
    fi

    if [ ! -t 0 ]; then
        Echo_Red "标准输入不是终端，无法确认卸载，已取消。"
        Echo_Red "请在交互终端执行，或设置 LNMP_Uninstall_Confirm=${expect}"
        return 1
    fi

    echo ""
    if ! read -r -p "确认卸载 ${stack} 请输入 ${expect}，其它输入一律取消：" ans; then
        echo
        Echo_Red "读取确认时遇到 EOF，已取消卸载。"
        return 1
    fi
    if [ "${ans}" != "${expect}" ]; then
        Echo_Yellow "输入与 ${expect} 不一致，已取消卸载。"
        return 1
    fi
    return 0
}

    Check_Stack
    echo "当前安装栈：${Get_Stack}"

    action="${Stack}"
    if [ -z "${action}" ]; then
        echo "1: 卸载 LNMP"
        echo "2: 卸载 LNMPA"
        echo "3: 卸载 LAMP"
        if ! read -r -p "请选择 [1-3]：" action; then
            echo
            Echo_Red "读取选择时遇到 EOF，已取消卸载。"
            exit 1
        fi
    else
        echo "命令行指定安装栈：${action}"
    fi

    case "$action" in
    1|[lL][nN][mM][pP])
        echo "即将卸载 LNMP。"
        Echo_Red "请先备份配置文件和 MySQL/MariaDB 数据。"
        Echo_Red "以下目录或文件将被删除："
        cat << EOF
/usr/local/nginx
${MySQL_Dir}
/usr/local/php
/etc/init.d/nginx
/etc/init.d/${DB_Name}
/etc/init.d/php-fpm
/usr/local/zend
/etc/my.cnf
/bin/lnmp
/bin/lnmp-backup
/bin/lnmp-tgnotice
/bin/lnmp-phpmyadmin
/bin/lnmp-perm
/bin/lnmp-health
/bin/lnmp-sqlguard
/bin/lnmp-fw
/etc/profile.d/lnmp-tgnotice.sh
/usr/local/phpmyadmin 与 /var/lib/phpmyadmin
/usr/local/acme.sh 及其中的证书
已安装的多版本 PHP（/usr/local/php8.x）
lnmp-backup 的 systemd timer/service 与 /etc/cron.d/lnmp-backup
各服务 unit 中的权限校验钩子、lnmp-perm-diagnose@.service
lnmp-perm 的 systemd timer/service 与 /etc/cron.d/lnmp-perm
lnmp-health 的 systemd timer/service 与 /etc/lnmp/health-state
php-fpm@.service 模板单元
lnmp app 托管的应用 unit、/etc/lnmp/apps 与其专属账号（应用目录保留）
/etc/lnmp（数据库口令文件删除，fw.conf、source-dir 等其余配置移到 /root）
inet lnmp 防火墙表、/etc/nftables.d/lnmp.nft 与 lnmp-nftables.service
EOF
        Sleep_Sec 3
        Confirm_Uninstall lnmp || exit 1
        Uninstall_LNMP || exit 1
    ;;
    2|[lL][nN][mM][pP][aA])
        echo "即将卸载 LNMPA。"
        Echo_Red "请先备份配置文件和 MySQL/MariaDB 数据。"
        Echo_Red "以下目录或文件将被删除："
        cat << EOF
/usr/local/nginx
${MySQL_Dir}
/usr/local/php
/usr/local/apache
/etc/init.d/nginx
/etc/init.d/${DB_Name}
/etc/init.d/httpd
/usr/local/zend
/etc/my.cnf
/bin/lnmp
/bin/lnmp-backup
/bin/lnmp-tgnotice
/bin/lnmp-phpmyadmin
/bin/lnmp-perm
/bin/lnmp-health
/bin/lnmp-sqlguard
/bin/lnmp-fw
/etc/profile.d/lnmp-tgnotice.sh
/usr/local/phpmyadmin 与 /var/lib/phpmyadmin
/usr/local/acme.sh 及其中的证书
已安装的多版本 PHP（/usr/local/php8.x）
lnmp-backup 的 systemd timer/service 与 /etc/cron.d/lnmp-backup
各服务 unit 中的权限校验钩子、lnmp-perm-diagnose@.service
lnmp-perm 的 systemd timer/service 与 /etc/cron.d/lnmp-perm
lnmp-health 的 systemd timer/service 与 /etc/lnmp/health-state
php-fpm@.service 模板单元
lnmp app 托管的应用 unit、/etc/lnmp/apps 与其专属账号（应用目录保留）
/etc/lnmp（数据库口令文件删除，fw.conf、source-dir 等其余配置移到 /root）
inet lnmp 防火墙表、/etc/nftables.d/lnmp.nft 与 lnmp-nftables.service
EOF
        Sleep_Sec 3
        Confirm_Uninstall lnmpa || exit 1
        Uninstall_LNMPA || exit 1
    ;;
    3|[lL][aA][mM][pP])
        echo "即将卸载 LAMP。"
        Echo_Red "请先备份配置文件和 MySQL/MariaDB 数据。"
        Echo_Red "以下目录或文件将被删除："
        cat << EOF
/usr/local/apache
${MySQL_Dir}
/etc/init.d/httpd
/etc/init.d/${DB_Name}
/usr/local/php
/usr/local/zend
/etc/my.cnf
/bin/lnmp
/bin/lnmp-backup
/bin/lnmp-tgnotice
/bin/lnmp-phpmyadmin
/bin/lnmp-perm
/bin/lnmp-health
/bin/lnmp-sqlguard
/bin/lnmp-fw
/etc/profile.d/lnmp-tgnotice.sh
/usr/local/phpmyadmin 与 /var/lib/phpmyadmin
/usr/local/acme.sh 及其中的证书
已安装的多版本 PHP（/usr/local/php8.x）
lnmp-backup 的 systemd timer/service 与 /etc/cron.d/lnmp-backup
各服务 unit 中的权限校验钩子、lnmp-perm-diagnose@.service
lnmp-perm 的 systemd timer/service 与 /etc/cron.d/lnmp-perm
lnmp-health 的 systemd timer/service 与 /etc/lnmp/health-state
php-fpm@.service 模板单元
lnmp app 托管的应用 unit、/etc/lnmp/apps 与其专属账号（应用目录保留）
/etc/lnmp（数据库口令文件删除，fw.conf、source-dir 等其余配置移到 /root）
inet lnmp 防火墙表、/etc/nftables.d/lnmp.nft 与 lnmp-nftables.service
EOF
        Sleep_Sec 3
        Confirm_Uninstall lamp || exit 1
        Uninstall_LAMP || exit 1
    ;;
    *)

        Echo_Red "无效选择：'${action}'。可用值：1 (lnmp) / 2 (lnmpa) / 3 (lamp)。"
        exit 1
    ;;
    esac

exit 0
