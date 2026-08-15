#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi

cur_dir=$(pwd)
action=$1
shopt -s extglob
Upgrade_Date=$(date +"%Y%m%d%H%M%S")

. lnmp.conf
. include/version.sh
. include/main.sh
. include/verify.sh
. include/firewall.sh
. include/profile.sh
. include/dbcommon.sh
. include/init.sh
. include/php.sh
. include/nginx.sh
# 提供安装和升级流程使用的 Telegram 通知函数。
. tools/lnmp-tgnotice.sh
. include/openresty_modules.sh
. include/openresty.sh
. include/mysql.sh
. include/mariadb.sh
. include/upgrade_nginx.sh
. include/upgrade_openresty.sh
. include/upgrade_php.sh
. include/upgrade_mysql.sh
. include/upgrade_mariadb.sh
. include/upgrade_mysql2mariadb.sh
. include/upgrade_phpmyadmin.sh
. include/upgrade_mphp.sh

Validate_Service_Ports || exit 1
Get_Dist_Name
Get_Dist_Version
MemTotal=$(awk '/MemTotal/ {printf( "%d\n", $2 / 1024 )}' /proc/meminfo)

Display_Upgrade_Menu()
{
    echo "1: 升级 Nginx"
    echo "2: 升级 MySQL"
    echo "3: 升级 MariaDB"
    echo "4: 升级 LNMP 的 PHP"
    echo "5: 升级 LNMPA 或 LAMP 的 PHP"
    echo "6: 将 MySQL 迁移到 MariaDB"
    echo "7: 升级 phpMyAdmin"
    echo "8: 升级多版本 PHP"
    echo "9: 升级 OpenResty"
    echo "输入 exit：退出当前脚本"
    echo "###################################################"
    read -p "请选择 [1-9]，或输入 exit 退出：" action
}

clear
Print_Banner \
    "LNMP V2.3 升级工具" \
    "升级 Nginx、MySQL/MariaDB 和 PHP" \
    "仅使用上游官方源码，并强制校验完整性"

Upgrade_Rc=0

if [ "${action}" == "" ]; then
    Display_Upgrade_Menu
fi

    case "${action}" in
    1|[nN][gG][iI][nN][xX])
        Upgrade_Nginx 2>&1 | tee /root/upgrade_nginx${Upgrade_Date}.log
        Upgrade_Rc=${PIPESTATUS[0]}
        ;;
    2|[mM][yY][sS][qQ][lL])
        Upgrade_MySQL 2>&1 | tee /root/upgrade_mysq${Upgrade_Date}.log
        Upgrade_Rc=${PIPESTATUS[0]}
        ;;
    3|[mM][aA][rR][iI][aA][dD][bB])
        Upgrade_MariaDB 2>&1 | tee /root/upgrade_mariadb${Upgrade_Date}.log
        Upgrade_Rc=${PIPESTATUS[0]}
        ;;
    4|[pP][hP][pP])
        Stack="lnmp"
        Upgrade_PHP 2>&1 | tee /root/upgrade_lnmp_php${Upgrade_Date}.log
        Upgrade_Rc=${PIPESTATUS[0]}
        ;;
    5|[pP][hP][pP][aA])
        Upgrade_PHP 2>&1 | tee /root/upgrade_a_php${Upgrade_Date}.log
        Upgrade_Rc=${PIPESTATUS[0]}
        ;;
    6|[mM]2[mY])
        Upgrade_MySQL2MariaDB 2>&1 | tee /root/upgrade_mysql2mariadb${Upgrade_Date}.log
        Upgrade_Rc=${PIPESTATUS[0]}
        ;;
    7|[pP][hH][pP][mM][yY][aA][dD][mM][iI][nN])
        Upgrade_phpMyAdmin 2>&1 | tee /root/upgrade_phpmyadmin${Upgrade_Date}.log
        Upgrade_Rc=${PIPESTATUS[0]}
        ;;
    8|[mM][pP][hH][pP])
        Upgrade_Multiplephp 2>&1 | tee /root/upgrade_mphp${Upgrade_Date}.log
        Upgrade_Rc=${PIPESTATUS[0]}
        ;;
    9|[oO][pP][eE][nN][rR][eE][sS][tT][yY])
        Upgrade_OpenResty 2>&1 | tee /root/upgrade_openresty${Upgrade_Date}.log
        Upgrade_Rc=${PIPESTATUS[0]}
        ;;
    [eE][xX][iI][tT])
        exit 1
        ;;
    *)
        echo "用法：./upgrade.sh {nginx|openresty|mysql|mariadb|m2m|php|phpa|phpmyadmin|mphp}"
        exit 1
    ;;
    esac

exit ${Upgrade_Rc}
