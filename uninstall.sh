#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this script, please use root to install lnmp"
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

shopt -s extglob

Check_DB
Get_Dist_Name

clear
echo "+------------------------------------------------------------------------+"
echo "|          LNMP V${LNMP_Ver} for ${DISTRO} Linux Server, Written by Licess          |"
echo "+------------------------------------------------------------------------+"
echo "|        A tool to auto-compile & install Nginx+MySQL+PHP on Linux       |"
echo "+------------------------------------------------------------------------+"
echo "|          Upstream-official sources only, checksums enforced             |"
echo "+------------------------------------------------------------------------+"

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


Backup_DB_Data()
{
    local src="$1"
    local dst="/root/databases_backup_$(date +"%Y%m%d%H%M%S")"

    if [ ! -d "${src}" ]; then
        echo "数据目录 ${src} 不存在，跳过备份。"
        return 0
    fi

    echo "Backup ${DB_Name} databases directory to ${dst}"
    if ! mv "${src}" "${dst}"; then
        Echo_Red "FATAL: 数据目录备份失败：${src} -> ${dst}"
        Echo_Red "为避免连同数据一起删除，卸载在此中止。**没有删除任何文件。**"
        Echo_Red "请先手工把数据目录搬到安全位置，再重新执行卸载。"
        exit 1
    fi

    # 搬完必须确认目标真的在、且不是空的。这一步防的是 mv 返回 0 但结果不对
    # （例如目标是已存在的目录，源被搬成了它的子目录）。
    if [ ! -d "${dst}" ] || [ -z "$(ls -A "${dst}" 2>/dev/null)" ]; then
        Echo_Red "FATAL: 备份目录 ${dst} 不存在或为空，无法确认数据已安全转移。"
        Echo_Red "卸载中止，**没有删除任何文件。**"
        exit 1
    fi

    # 备份必须落在待删目录之外，否则等于没备份
    case "${dst}" in
    /usr/local/*)
        Echo_Red "FATAL: 备份路径 ${dst} 仍在 /usr/local 下，会被后续删除。卸载中止。"
        exit 1
        ;;
    esac

    Echo_Green "数据目录已备份到 ${dst}"
    return 0
}

# 停服务 + 备份数据，任一环节失败就不往下走
Stop_And_Backup_DB()
{
    [ "${DB_Name}" = "None" ] && return 0
    Remove_StartUp ${DB_Name}
    if [ "${DB_Name}" = "mysql" ]; then
        Backup_DB_Data "${MySQL_Data_Dir}"
    elif [ "${DB_Name}" = "mariadb" ]; then
        Backup_DB_Data "${MariaDB_Data_Dir}"
    fi
}

Remove_DB_Files()
{
    [ "${DB_Name}" = "None" ] && return 0
    rm -rf /usr/local/${DB_Name}
    rm -f /etc/my.cnf
    rm -f /etc/init.d/${DB_Name}
}


MPHP_Supported_Vers='8.0 8.1 8.2 8.3 8.4 8.5'

Remove_Multiple_PHP()
{
    local v mphp
    for v in ${MPHP_Supported_Vers}; do
        mphp="/usr/local/php${v}"
        [ -d "${mphp}" ] || continue
        echo "Removing multiple PHP ${v} ..."
        if [ -s /etc/init.d/php-fpm${v} ]; then
            /etc/init.d/php-fpm${v} stop
            Remove_StartUp php-fpm${v}
            rm -f /etc/init.d/php-fpm${v}
        fi
        rm -f /usr/local/nginx/conf/enable-php${v}.conf
        rm -rf "${mphp}"
    done
}

Remove_Acme()
{
    [ -s /usr/local/acme.sh/acme.sh ] || return 0
    /usr/local/acme.sh/acme.sh --uninstall
    rm -rf /usr/local/acme.sh
    if crontab -l 2>/dev/null | grep -q "/usr/local/acme.sh/upgrade.sh"; then
        crontab -l 2>/dev/null | grep -v "/usr/local/acme.sh/upgrade.sh" | crontab -
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
    # init 脚本也可能一并缺失，兜底把进程停掉
    for svc in nginx php-fpm mysqld httpd; do
        pkill -x "${svc}" 2>/dev/null
    done
    return 0
}

Uninstall_LNMP()
{
    echo "Stoping LNMP..."
    Stop_Stack_Services

    Remove_StartUp nginx
    Remove_StartUp php-fpm
    # 备份必须在任何 rm 之前，且失败即中止（Backup_DB_Data 内部 exit 1）
    Stop_And_Backup_DB

    chattr -i ${Default_Website_Dir}/.user.ini 2>/dev/null
    echo "Deleting LNMP files..."
    # 装的是 OpenResty 时，/usr/local/nginx 只是指向它的软链。
    # 必须先由 Uninstall_OpenResty 处理（卸包、删源、删软链），
    # 否则下面的 rm -rf 会顺着软链把 OpenResty 的目录内容删掉，
    # 同时避免包管理器保留不完整的 OpenResty 安装状态。
    if [ -d /usr/local/openresty ]; then
        Uninstall_OpenResty
    fi
    rm -rf /usr/local/nginx
    rm -rf /usr/local/php
    rm -rf /usr/local/zend
    # phpMyAdmin 及其模板缓存都在网站根目录之外，需要单独清理
    rm -rf /usr/local/phpmyadmin /usr/local/phpmyadmin.bak.*
    rm -rf /var/lib/phpmyadmin

    Remove_DB_Files
    Remove_Multiple_PHP
    Remove_Acme

    rm -f /etc/init.d/nginx
    rm -f /etc/init.d/php-fpm
    rm -f /bin/lnmp
    echo "LNMP Uninstall completed."
}

Uninstall_LNMPA()
{
    echo "Stoping LNMPA..."
    Stop_Stack_Services

    Remove_StartUp nginx
    Remove_StartUp httpd
    Stop_And_Backup_DB

    chattr -i ${Default_Website_Dir}/.user.ini 2>/dev/null
    echo "Deleting LNMPA files..."
    rm -rf /usr/local/nginx
    rm -rf /usr/local/php
    rm -rf /usr/local/apache
    rm -rf /usr/local/zend
    # phpMyAdmin 及其模板缓存都在网站根目录之外，需要单独清理
    rm -rf /usr/local/phpmyadmin /usr/local/phpmyadmin.bak.*
    rm -rf /var/lib/phpmyadmin

    Remove_DB_Files
    Remove_Multiple_PHP
    Remove_Acme

    rm -f /etc/init.d/nginx
    rm -f /etc/init.d/httpd
    rm -f /bin/lnmp
    echo "LNMPA Uninstall completed."
}

Uninstall_LAMP()
{
    echo "Stoping LAMP..."
    Stop_Stack_Services

    Remove_StartUp httpd
    Stop_And_Backup_DB

    chattr -i ${Default_Website_Dir}/.user.ini 2>/dev/null
    echo "Deleting LAMP files..."
    rm -rf /usr/local/apache
    rm -rf /usr/local/php
    rm -rf /usr/local/zend
    # phpMyAdmin 及其模板缓存都在网站根目录之外，需要单独清理
    rm -rf /usr/local/phpmyadmin /usr/local/phpmyadmin.bak.*
    rm -rf /var/lib/phpmyadmin

    Remove_DB_Files
    Remove_Multiple_PHP
    Remove_Acme

    rm -f /etc/my.cnf
    rm -f /etc/init.d/httpd
    rm -f /bin/lnmp
    echo "LAMP Uninstall completed."
}

    Check_Stack
    echo "Current Stack: ${Get_Stack}"

    action="${Stack}"
    if [ -z "${action}" ]; then
        echo "Enter 1 to uninstall LNMP"
        echo "Enter 2 to uninstall LNMPA"
        echo "Enter 3 to uninstall LAMP"
        read -p "(Please input 1, 2 or 3): " action
    else
        echo "Stack from command line: ${action}"
    fi

    case "$action" in
    1|[lL][nN][mM][pP])
        echo "You will uninstall LNMP"
        Echo_Red "Please backup your configure files and mysql data!!!!!!"
        Echo_Red "The following directory or files will be remove!"
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
EOF
        Sleep_Sec 3
        Press_Start
        Uninstall_LNMP
    ;;
    2|[lL][nN][mM][pP][aA])
        echo "You will uninstall LNMPA"
        Echo_Red "Please backup your configure files and mysql data!!!!!!"
        Echo_Red "The following directory or files will be remove!"
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
EOF
        Sleep_Sec 3
        Press_Start
        Uninstall_LNMPA
    ;;
    3|[lL][aA][mM][pP])
        echo "You will uninstall LAMP"
        Echo_Red "Please backup your configure files and mysql data!!!!!!"
        Echo_Red "The following directory or files will be remove!"
        cat << EOF
/usr/local/apache
${MySQL_Dir}
/etc/init.d/httpd
/etc/init.d/${DB_Name}
/usr/local/php
/usr/local/zend
/etc/my.cnf
/bin/lnmp
EOF
        Sleep_Sec 3
        Press_Start
        Uninstall_LAMP
    ;;
    *)

        Echo_Red "无效选择：'${action}'。可用值：1 (lnmp) / 2 (lnmpa) / 3 (lamp)。"
        exit 1
    ;;
    esac

exit 0
