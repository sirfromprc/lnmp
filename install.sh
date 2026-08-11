#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this script, please use root to install lnmp"
    exit 1
fi

cur_dir=$(pwd)
Stack=$1
if [ "${Stack}" = "" ]; then
    Stack="lnmp"
else
    Stack=$1
fi

LNMP_Ver='2.3'
. lnmp.conf
. include/main.sh
. include/verify.sh
. include/firewall.sh
. include/profile.sh
. include/dbcommon.sh
. include/init.sh
. include/mysql.sh
. include/mariadb.sh
. include/php.sh
. include/nginx.sh
# 通知函数：让安装/升级流程里可以直接写 tgnotice "..."
. tools/lnmp-tgnotice.sh
. include/openresty_modules.sh
. include/openresty.sh
. include/apache.sh
. include/end.sh
. include/only.sh
. include/multiplephp.sh
. include/imageMagick.sh
. include/php_default_ext.sh

Get_Dist_Name

if [ "${DISTRO}" = "unknow" ]; then
    Echo_Red "Unable to get Linux distribution name, or do NOT support the current distribution."
    exit 1
fi

if [[ "${Stack}" = "lnmp" || "${Stack}" = "lnmpa" || "${Stack}" = "lamp" ]]; then
    if [ -f /bin/lnmp ]; then
        Echo_Red "You have installed LNMP!"
        echo -e "If you want to reinstall LNMP, please BACKUP your data.\nand run uninstall script: ./uninstall.sh before you install."
        exit 1
    fi
fi

Check_LNMPConf

clear
echo "+------------------------------------------------------------------------+"
echo "|          LNMP V${LNMP_Ver} for ${DISTRO} Linux Server, Written by Licess          |"
echo "+------------------------------------------------------------------------+"
echo "|        A tool to auto-compile & install LNMP/LNMPA/LAMP on Linux       |"
echo "+------------------------------------------------------------------------+"
echo "|          Upstream-official sources only, checksums enforced             |"
echo "+------------------------------------------------------------------------+"

Init_Install()
{
    Press_Install
    Print_APP_Ver
    Get_Dist_Version
    Print_Sys_Info
    Check_Hosts
    Check_CMPT
    if [ "${CheckMirror}" != "n" ]; then
        Modify_Source
    fi
    # 放在 Modify_Source 之后：本包自己改写过的源（RHEL 系）也一并被检查到，
    # 检查的是即将真正用于装依赖的最终状态。只警告，不阻断。
    Check_Host_Repo_Trust
    Add_Swap
    Set_Timezone
    if [ "$PM" = "yum" ]; then
        CentOS_InstallNTP
        CentOS_RemoveAMP
        CentOS_Dependent
    elif [ "$PM" = "apt" ]; then
        Deb_InstallNTP
        Xen_Hwcap_Setting
        Deb_RemoveAMP
        Deb_Dependent
    fi
    Disable_Selinux
    Check_Download
    Install_Libiconv
    Install_Freetype
    Install_Pcre
    if [ "${SelectMalloc}" = "2" ]; then
        Install_Jemalloc
    elif [ "${SelectMalloc}" = "3" ]; then
        Install_TCMalloc
    fi
    if [ "$PM" = "yum" ]; then
        CentOS_Lib_Opt
    elif [ "$PM" = "apt" ]; then
        Deb_Lib_Opt
    fi
    if [ "${DB_Kind}" != "none" ]; then
        Dispatch "${DB_Install}"
    fi
    TempMycnf_Clean
    Clean_DB_Src_Dir
    Check_PHP_Option
}

Install_PHP()
{
    Dispatch "${PHP_Install}"
    Clean_PHP_Src_Dir
    Install_PHP_Default_Ext
}


Install_WebServer()
{
    if [ "${WebServer}" = "openresty" ]; then
        Install_OpenResty
    else
        Install_Nginx
    fi
}

LNMP_Stack()
{
    Init_Install
    Install_PHP
    LNMP_PHP_Opt
    Install_WebServer
    Creat_PHP_Tools
    Add_Iptables_Rules
    Add_LNMP_Startup
    Check_LNMP_Install
}

LNMPA_Stack()
{
    Apache_Selection
    Init_Install
    Dispatch "${Apache_Install}"
    Install_PHP
    Install_WebServer
    Creat_PHP_Tools
    Add_Iptables_Rules
    Add_LNMPA_Startup
    Check_LNMPA_Install
}

LAMP_Stack()
{
    Apache_Selection
    Init_Install
    Dispatch "${Apache_Install}"
    Install_PHP
    Creat_PHP_Tools
    Add_Iptables_Rules
    Add_LAMP_Startup
    Check_LAMP_Install
}


Install_Rc=0

case "${Stack}" in
    lnmp)
        Dispaly_Selection
        LNMP_Stack 2>&1 | tee /root/lnmp-install.log
        Install_Rc=${PIPESTATUS[0]}
        ;;
    lnmpa)
        Dispaly_Selection
        LNMPA_Stack 2>&1 | tee /root/lnmp-install.log
        Install_Rc=${PIPESTATUS[0]}
        ;;
    lamp)
        Dispaly_Selection
        LAMP_Stack 2>&1 | tee /root/lnmp-install.log
        Install_Rc=${PIPESTATUS[0]}
        ;;
    nginx)
        Install_Only_Nginx 2>&1 | tee /root/nginx-install.log
        Install_Rc=${PIPESTATUS[0]}
        ;;
    db)
        Install_Only_Database
        Install_Rc=$?
        ;;
    mphp)
        Install_Multiplephp
        Install_Rc=$?
        ;;
    *)

        Echo_Red "Usage: $0 {lnmp|lnmpa|lamp}"
        Echo_Red "Usage: $0 {nginx|db|mphp}"
        Install_Rc=1
        ;;
esac

exit ${Install_Rc}
