#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
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
Stop_Stack_Services()
{
    if command -v lnmp >/dev/null 2>&1; then
        lnmp kill
        lnmp stop
        return 0
    fi

    Echo_Yellow "/bin/lnmp 不存在（通常是上次安装未完成），改用 init 脚本逐个停止。"
    local svc
    for svc in nginx php-fpm mysql mariadb httpd pureftpd redis; do
        [ -x "/etc/init.d/${svc}" ] && "/etc/init.d/${svc}" stop 2>/dev/null
    done
    # init 脚本缺失时按进程名停止服务。
    for svc in nginx php-fpm mysqld httpd; do
        pkill -x "${svc}" 2>/dev/null
    done
    return 0
}

Uninstall_LNMP()
{
    echo "正在停止 LNMP..."
    Stop_Stack_Services

    Remove_StartUp nginx
    Remove_StartUp php-fpm
    # 数据备份在删除操作前完成，失败时中止卸载。
    Stop_And_Backup_DB

    chattr -i ${Default_Website_Dir}/.user.ini 2>/dev/null
    echo "正在删除 LNMP 文件..."
    # OpenResty 使用 /usr/local/nginx 软链接，需先卸载软件包并移除链接。
    if [ -d /usr/local/openresty ]; then
        Uninstall_OpenResty
    fi
    rm -rf /usr/local/nginx
    rm -rf /usr/local/php
    rm -rf /usr/local/zend
    # phpMyAdmin 及模板缓存位于网站根目录之外。
    rm -rf /usr/local/phpmyadmin /usr/local/phpmyadmin.bak.*
    rm -rf /var/lib/phpmyadmin

    Remove_DB_Files
    Remove_Multiple_PHP
    Remove_Acme
    Remove_Backup_Schedule
    Remove_Health_Schedule
    Remove_Cutlogs_Schedule
    Remove_App_Hosting
    Remove_Perm_Hooks

    rm -f /etc/init.d/nginx
    rm -f /etc/init.d/php-fpm
    rm -f /bin/lnmp
    rm -f /bin/lnmp-backup
    rm -f /bin/lnmp-tgnotice
    rm -f /bin/lnmp-phpmyadmin
    rm -f /bin/lnmp-perm
    rm -f /bin/lnmp-health
    rm -f /bin/lnmp-sqlguard
    rm -f /bin/lnmp-cutlogs
    rm -f /etc/profile.d/lnmp-tgnotice.sh
    Remove_Lnmp_Conf_Dir
    Firewall_Purge
    echo "LNMP 卸载完成。"
}

Uninstall_LNMPA()
{
    echo "正在停止 LNMPA..."
    Stop_Stack_Services

    Remove_StartUp nginx
    Remove_StartUp httpd
    Stop_And_Backup_DB

    chattr -i ${Default_Website_Dir}/.user.ini 2>/dev/null
    echo "正在删除 LNMPA 文件..."
    rm -rf /usr/local/nginx
    rm -rf /usr/local/php
    rm -rf /usr/local/apache
    rm -rf /usr/local/zend
    # phpMyAdmin 及模板缓存位于网站根目录之外。
    rm -rf /usr/local/phpmyadmin /usr/local/phpmyadmin.bak.*
    rm -rf /var/lib/phpmyadmin

    Remove_DB_Files
    Remove_Multiple_PHP
    Remove_Acme
    Remove_Backup_Schedule
    Remove_Health_Schedule
    Remove_Cutlogs_Schedule
    Remove_App_Hosting
    Remove_Perm_Hooks

    rm -f /etc/init.d/nginx
    rm -f /etc/init.d/httpd
    rm -f /bin/lnmp
    rm -f /bin/lnmp-backup
    rm -f /bin/lnmp-tgnotice
    rm -f /bin/lnmp-phpmyadmin
    rm -f /bin/lnmp-perm
    rm -f /bin/lnmp-health
    rm -f /bin/lnmp-sqlguard
    rm -f /bin/lnmp-cutlogs
    rm -f /etc/profile.d/lnmp-tgnotice.sh
    Remove_Lnmp_Conf_Dir
    Firewall_Purge
    echo "LNMPA 卸载完成。"
}

Uninstall_LAMP()
{
    echo "正在停止 LAMP..."
    Stop_Stack_Services

    Remove_StartUp httpd
    Stop_And_Backup_DB

    chattr -i ${Default_Website_Dir}/.user.ini 2>/dev/null
    echo "正在删除 LAMP 文件..."
    rm -rf /usr/local/apache
    rm -rf /usr/local/php
    rm -rf /usr/local/zend
    # phpMyAdmin 及模板缓存位于网站根目录之外。
    rm -rf /usr/local/phpmyadmin /usr/local/phpmyadmin.bak.*
    rm -rf /var/lib/phpmyadmin

    Remove_DB_Files
    Remove_Multiple_PHP
    Remove_Acme
    Remove_Backup_Schedule
    Remove_Health_Schedule
    Remove_Cutlogs_Schedule
    Remove_App_Hosting
    Remove_Perm_Hooks

    rm -f /etc/my.cnf
    rm -f /etc/init.d/httpd
    rm -f /bin/lnmp
    rm -f /bin/lnmp-backup
    rm -f /bin/lnmp-tgnotice
    rm -f /bin/lnmp-phpmyadmin
    rm -f /bin/lnmp-perm
    rm -f /bin/lnmp-health
    rm -f /bin/lnmp-sqlguard
    rm -f /bin/lnmp-cutlogs
    rm -f /etc/profile.d/lnmp-tgnotice.sh
    Remove_Lnmp_Conf_Dir
    Firewall_Purge
    echo "LAMP 卸载完成。"
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
/etc/lnmp（数据库口令文件删除，其余配置移到 /root）
inet lnmp 防火墙表、/etc/nftables.d/lnmp.nft 与 lnmp-nftables.service
EOF
        Sleep_Sec 3
        Confirm_Uninstall lnmp || exit 1
        Uninstall_LNMP
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
/etc/lnmp（数据库口令文件删除，其余配置移到 /root）
inet lnmp 防火墙表、/etc/nftables.d/lnmp.nft 与 lnmp-nftables.service
EOF
        Sleep_Sec 3
        Confirm_Uninstall lnmpa || exit 1
        Uninstall_LNMPA
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
/etc/lnmp（数据库口令文件删除，其余配置移到 /root）
inet lnmp 防火墙表、/etc/nftables.d/lnmp.nft 与 lnmp-nftables.service
EOF
        Sleep_Sec 3
        Confirm_Uninstall lamp || exit 1
        Uninstall_LAMP
    ;;
    *)

        Echo_Red "无效选择：'${action}'。可用值：1 (lnmp) / 2 (lnmpa) / 3 (lamp)。"
        exit 1
    ;;
    esac

exit 0
