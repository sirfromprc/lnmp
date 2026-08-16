#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
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
# version.sh 提供菜单所需的组件版本常量，必须在选择函数执行前载入。
. include/version.sh
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
# 提供安装和升级流程使用的 Telegram 通知函数。
. tools/lnmp-tgnotice.sh
. include/openresty_modules.sh
. include/openresty.sh
. include/apache.sh
. include/end.sh
. include/only.sh
. include/multiplephp.sh
. include/imageMagick.sh
. include/php_default_ext.sh

Validate_Service_Ports || exit 1
Get_Dist_Name

if [ "${DISTRO}" = "unknow" ]; then
    Echo_Red "无法识别 Linux 发行版，或当前发行版不受支持。"
    exit 1
fi

if [[ "${Stack}" = "lnmp" || "${Stack}" = "lnmpa" || "${Stack}" = "lamp" ]]; then
    if [ -f /bin/lnmp ]; then
        Echo_Red "检测到 LNMP 已安装。"
        echo -e "如需重新安装，请先备份数据，\n然后执行 ./uninstall.sh 卸载现有环境。"
        exit 1
    fi
fi

Check_LNMPConf

clear
Print_Banner \
    "LNMP V${LNMP_Ver} 安装程序" \
    "在 ${DISTRO} Linux 上安装 LNMP、LNMPA 或 LAMP" \
    "仅使用上游官方源码，并强制校验完整性"

Init_Install()
{
    Press_Install
    Get_Dist_Version
    Print_Sys_Info
    Check_Hosts
    Check_CMPT
    if [ "${CheckMirror}" != "n" ]; then
        Modify_Source
    fi
    # 检查 Modify_Source 处理后的最终软件源状态；异常仅告警，不阻断安装。
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
        # 数据库安装失败时立即中止，避免继续配置依赖数据库的组件。
        Dispatch "${DB_Install}" || return 1
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
    Init_Install || return 1
    Install_PHP
    LNMP_PHP_Opt
    Install_WebServer || return 1
    Creat_PHP_Tools || return 1
    Add_Iptables_Rules
    Add_LNMP_Startup || return 1
    Check_LNMP_Install
}

LNMPA_Stack()
{
    Apache_Selection || return 1
    Init_Install || return 1
    Dispatch "${Apache_Install}"
    Install_PHP
    Install_WebServer || return 1
    Creat_PHP_Tools || return 1
    Add_Iptables_Rules
    Add_LNMPA_Startup || return 1
    Check_LNMPA_Install
}

LAMP_Stack()
{
    Apache_Selection || return 1
    Init_Install || return 1
    Dispatch "${Apache_Install}"
    Install_PHP
    Creat_PHP_Tools || return 1
    Add_Iptables_Rules
    Add_LAMP_Startup || return 1
    Check_LAMP_Install
}


# 安装依赖或修改防火墙的入口需要安装前确认；不涉及端口和防火墙的
# phpMyAdmin 管理子命令及 mphp 不执行该确认。
case "${Stack}" in
    lnmp|lnmpa|lamp|nginx|db)
        Confirm_LNMPConf_Reviewed
        Check_SSH_Port_Policy || exit 1
        ;;
esac

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
    phpmyadmin)
        Install_Only_phpMyAdmin "${2:-}" 2>&1 | tee /root/phpmyadmin-install.log
        Install_Rc=${PIPESTATUS[0]}
        ;;
    *)

        Echo_Red "用法：$0 {lnmp|lnmpa|lamp}"
        Echo_Red "用法：$0 {nginx|db|mphp|phpmyadmin}"
        Echo_Red "用法：$0 phpmyadmin {enable|disable|status}"
        Install_Rc=1
        ;;
esac

# 成功后同步管理命令到 /usr/bin，并将执行权限设置为 755。
if [ "${Install_Rc}" -eq 0 ] && [ -s /bin/lnmp ]; then
    Sync_LNMP_Command_Alias || Install_Rc=1
fi

exit ${Install_Rc}
