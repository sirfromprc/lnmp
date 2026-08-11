#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this script"
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
# 通知函数：让安装/升级流程里可以直接写 tgnotice "..."
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
    echo "1: Upgrade Nginx"
    echo "2: Upgrade MySQL"
    echo "3: Upgrade MariaDB"
    echo "4: Upgrade PHP for LNMP"
    echo "5: Upgrade PHP for LNMPA or LAMP"
    echo "6: Upgrade MySQL to MariaDB"
    echo "7: Upgrade phpMyAdmin"
    echo "8: Upgrade Multiple PHP"
    echo "9: Upgrade OpenResty"
    echo "exit: Exit current script"
    echo "###################################################"
    read -p "Enter your choice (1-9 or exit): " action
}

clear
echo "+-----------------------------------------------------------------------+"
echo "|            Upgrade script for LNMP V2.3, Written by Licess            |"
echo "+-----------------------------------------------------------------------+"
echo "|     A tool to upgrade Nginx,MySQL/Mariadb,PHP for LNMP/LNMPA/LAMP     |"
echo "+-----------------------------------------------------------------------+"
echo "|          Upstream-official sources only, checksums enforced            |"
echo "+-----------------------------------------------------------------------+"

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
        echo "Usage: ./upgrade.sh {nginx|openresty|mysql|mariadb|m2m|php|phpa|phpmyadmin|mphp}"
        exit 1
    ;;
    esac

exit ${Upgrade_Rc}
