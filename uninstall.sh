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


Backup_DB_Data()
{
    local src="$1"
    local dst="/root/databases_backup_$(date +"%Y%m%d%H%M%S")"

    if [ ! -d "${src}" ]; then
        echo "数据目录 ${src} 不存在，跳过备份。"
        return 0
    fi

    # 空数据目录无需备份，也不应阻止卸载未完成的安装。
    if [ -z "$(ls -A "${src}" 2>/dev/null)" ]; then
        echo "数据目录 ${src} 为空，无需备份。"
        return 0
    fi

    echo "正在将 ${DB_Name} 数据目录备份到 ${dst}"
    if ! mv "${src}" "${dst}"; then
        Echo_Red "致命错误：数据目录备份失败：${src} -> ${dst}"
        Echo_Red "为避免连同数据一起删除，卸载在此中止。**没有删除任何文件。**"
        Echo_Red "请先手工把数据目录搬到安全位置，再重新执行卸载。"
        exit 1
    fi

    # 删除程序前必须确认备份目录存在且包含数据。
    if [ ! -d "${dst}" ] || [ -z "$(ls -A "${dst}" 2>/dev/null)" ]; then
        Echo_Red "致命错误：备份目录 ${dst} 不存在或为空，无法确认数据已安全转移。"
        Echo_Red "卸载中止，**没有删除任何文件。**"
        exit 1
    fi

    # 备份目录必须位于卸载删除范围之外。
    case "${dst}" in
    /usr/local/*)
        Echo_Red "致命错误：备份路径 ${dst} 仍在 /usr/local 下，会被后续删除。卸载中止。"
        exit 1
        ;;
    esac

    Echo_Green "数据目录已备份到 ${dst}"
    return 0
}

# 停止数据库并备份数据，任一步失败均中止卸载。
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

# 处理 /etc/lnmp 下的备份配置与凭据。
#
# lnmp backup init 会生成 backup.conf（站点清单、异地上传设置）与
# backup-mysql.cnf（以 0600 保存数据库 root 口令）。卸载删掉了数据库实例和
# /bin/lnmp-backup，口令文件留下只剩风险，且重装后会被误当成新实例的凭据，
# 因此删除该凭据；其余配置移到 /root 并显示目标路径。
#
# 配置转移失败时保留原目录并提示使用者手工处理。
Remove_Lnmp_Conf_Dir()
{
    local dir='/etc/lnmp'
    local dst="/root/lnmp_conf_backup_$(date +"%Y%m%d%H%M%S")"

    [ -d "${dir}" ] || return 0

    if [ -f "${dir}/backup-mysql.cnf" ]; then
        rm -f "${dir}/backup-mysql.cnf"
        echo "已删除含数据库口令的 ${dir}/backup-mysql.cnf。"
    fi

    if [ -n "$(ls -A "${dir}" 2>/dev/null)" ]; then
        if mkdir -p "${dst}" &&
            find "${dir}" -mindepth 1 -maxdepth 1 -exec mv -f {} "${dst}/" \; &&
            [ -z "$(ls -A "${dir}" 2>/dev/null)" ]; then
            Echo_Green "${dir} 下的其余配置已移到 ${dst}"
        else
            Echo_Red "无法转移 ${dir} 下的配置，已原样保留：${dir}"
            Echo_Red "该目录可能仍有含敏感信息的文件，请自行检查并处理。"
            return 0
        fi
    fi

    rmdir "${dir}" 2>/dev/null
    return 0
}

Remove_DB_Files()
{
    [ "${DB_Name}" = "None" ] && return 0
    Remove_DB_Command_Links
    rm -rf /usr/local/${DB_Name}
    rm -f /etc/my.cnf
    rm -f /etc/init.d/${DB_Name}
    Remove_Libaio_Compat_Link
}

# 仅清理本包为数据库通用二进制包建立的 libaio.so.1 兼容链接：必须是符号链接，
# 且指向 libaio.so.1t64*。发行版自带的实体库或指向别处的链接一律不动。
Remove_Libaio_Compat_Link()
{
    local link target

    for link in $(ldconfig -p 2>/dev/null | awk '$1 == "libaio.so.1t64" {print $NF}' \
                  | xargs -r -n1 dirname | sort -u | sed 's:$:/libaio.so.1:'); do
        [ -L "${link}" ] || continue
        target=$(readlink "${link}")
        case "${target##*/}" in
        libaio.so.1t64*)
            rm -f "${link}"
            ldconfig
            ;;
        esac
    done
}

# 只删除仍指向本包数据库目录的软链接，以及带 LNMP 标记的 MariaDB 包装器。
# 非本包安装的同名系统客户端不在清理范围内。
Remove_DB_Command_Links()
{
    local command path target first second

    for command in mysql mysqldump mysqladmin mysqlcheck mysql_upgrade mysqld_safe \
                   mariadb mariadb-dump mariadb-admin mariadb-check mariadb-upgrade mariadbd-safe \
                   myisamchk; do
        path="/usr/bin/${command}"
        if [ -L "${path}" ]; then
            target=$(readlink "${path}" 2>/dev/null)
            case "${target}" in
                /usr/local/mysql/*|/usr/local/mariadb/*) rm -f "${path}" ;;
            esac
        elif [ -f "${path}" ]; then
            first=$(sed -n '1p' "${path}")
            second=$(sed -n '2p' "${path}")
            if [ "${first}" = '#!/bin/sh' ] \
                && [ "${second}" = '# LNMP MariaDB compatibility wrapper' ]; then
                rm -f "${path}"
            fi
        fi
    done
}


MPHP_Supported_Vers='8.0 8.1 8.2 8.3 8.4 8.5'

Remove_Multiple_PHP()
{
    local v mphp
    for v in ${MPHP_Supported_Vers}; do
        mphp="/usr/local/php${v}"
        [ -d "${mphp}" ] || continue
        echo "正在删除多版本 PHP ${v} ..."
        if [ -s /etc/init.d/php-fpm${v} ]; then
            /etc/init.d/php-fpm${v} stop
            Remove_StartUp php-fpm${v}
            rm -f /etc/init.d/php-fpm${v}
        fi
        rm -f /usr/local/nginx/conf/enable-php${v}.conf
        rm -rf "${mphp}"
    done
}

# 清理 lnmp backup init 写入的定时任务，不动已有备份数据。
Remove_Backup_Schedule()
{
    local timer='/etc/systemd/system/lnmp-backup.timer'
    local service='/etc/systemd/system/lnmp-backup.service'
    local cron='/etc/cron.d/lnmp-backup'

    if [ -e "${timer}" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now lnmp-backup.timer >/dev/null 2>&1
    fi
    if [ -e "${timer}" ] || [ -e "${service}" ]; then
        rm -f "${timer}" "${service}"
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    fi
    rm -f "${cron}"
    return 0
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

    rm -f /etc/init.d/nginx
    rm -f /etc/init.d/php-fpm
    rm -f /bin/lnmp
    rm -f /bin/lnmp-backup
    rm -f /bin/lnmp-tgnotice
    rm -f /bin/lnmp-phpmyadmin
    rm -f /etc/profile.d/lnmp-tgnotice.sh
    Remove_Lnmp_Conf_Dir
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

    rm -f /etc/init.d/nginx
    rm -f /etc/init.d/httpd
    rm -f /bin/lnmp
    rm -f /bin/lnmp-backup
    rm -f /bin/lnmp-tgnotice
    rm -f /bin/lnmp-phpmyadmin
    rm -f /etc/profile.d/lnmp-tgnotice.sh
    Remove_Lnmp_Conf_Dir
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

    rm -f /etc/my.cnf
    rm -f /etc/init.d/httpd
    rm -f /bin/lnmp
    rm -f /bin/lnmp-backup
    rm -f /bin/lnmp-tgnotice
    rm -f /bin/lnmp-phpmyadmin
    rm -f /etc/profile.d/lnmp-tgnotice.sh
    Remove_Lnmp_Conf_Dir
    echo "LAMP 卸载完成。"
}

    Check_Stack
    echo "当前安装栈：${Get_Stack}"

    action="${Stack}"
    if [ -z "${action}" ]; then
        echo "1: 卸载 LNMP"
        echo "2: 卸载 LNMPA"
        echo "3: 卸载 LAMP"
        read -p "请选择 [1-3]：" action
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
/etc/profile.d/lnmp-tgnotice.sh
/usr/local/phpmyadmin 与 /var/lib/phpmyadmin
/usr/local/acme.sh 及其中的证书
已安装的多版本 PHP（/usr/local/php8.x）
lnmp-backup 的 systemd timer/service 与 /etc/cron.d/lnmp-backup
/etc/lnmp（数据库口令文件删除，其余配置移到 /root）
EOF
        Sleep_Sec 3
        Press_Start
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
/etc/profile.d/lnmp-tgnotice.sh
/usr/local/phpmyadmin 与 /var/lib/phpmyadmin
/usr/local/acme.sh 及其中的证书
已安装的多版本 PHP（/usr/local/php8.x）
lnmp-backup 的 systemd timer/service 与 /etc/cron.d/lnmp-backup
/etc/lnmp（数据库口令文件删除，其余配置移到 /root）
EOF
        Sleep_Sec 3
        Press_Start
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
/etc/profile.d/lnmp-tgnotice.sh
/usr/local/phpmyadmin 与 /var/lib/phpmyadmin
/usr/local/acme.sh 及其中的证书
已安装的多版本 PHP（/usr/local/php8.x）
lnmp-backup 的 systemd timer/service 与 /etc/cron.d/lnmp-backup
/etc/lnmp（数据库口令文件删除，其余配置移到 /root）
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
