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
        # 进度标记存在说明上次安装没走到成功收尾，据此区分已装好的环境与中断残留。
        if started_at=$(Install_Progress_Get started); then
            Echo_Yellow "检测到 ${started_at} 开始的安装没有完成，但 /bin/lnmp 已生成。"
            if [ "${LNMP_Resume_Broken_Install:-}" != "yes" ]; then
                Echo_Red "继续安装会覆盖已编译的组件，已中止。"
                Echo_Yellow "确认要在现有环境上重装时，显式声明后重试："
                echo
                echo "  LNMP_Resume_Broken_Install=yes bash install.sh ${Stack}"
                Echo_Yellow "想从干净环境开始时，先执行 ./uninstall.sh。"
                exit 1
            fi
            Echo_Yellow "LNMP_Resume_Broken_Install=yes，继续在现有环境上重装。"
        else
            Echo_Red "检测到 LNMP 已安装。"
            echo -e "如需重新安装，请先备份数据，\n然后执行 ./uninstall.sh 卸载现有环境。"
            exit 1
        fi
    fi
fi

Check_LNMPConf

clear 2>/dev/null || true
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
        # 必需依赖装不上就中止，避免后续编译在缺库时才失败。
        Deb_Dependent || return 1
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
        # 此后中断，数据目录已非空，重跑时据此区分残留与在用数据库。
        Install_Progress_Mark db
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
        Install_Log_Begin /root/lnmp-install.log
        Install_Progress_Begin
        LNMP_Stack 2>&1 | tee -a /root/lnmp-install.log
        Install_Rc=${PIPESTATUS[0]}
        ;;
    lnmpa)
        Dispaly_Selection
        Install_Log_Begin /root/lnmp-install.log
        Install_Progress_Begin
        LNMPA_Stack 2>&1 | tee -a /root/lnmp-install.log
        Install_Rc=${PIPESTATUS[0]}
        ;;
    lamp)
        Dispaly_Selection
        Install_Log_Begin /root/lnmp-install.log
        Install_Progress_Begin
        LAMP_Stack 2>&1 | tee -a /root/lnmp-install.log
        Install_Rc=${PIPESTATUS[0]}
        ;;
    nginx)
        Install_Log_Begin /root/nginx-install.log
        Install_Only_Nginx 2>&1 | tee -a /root/nginx-install.log
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
        Install_Log_Begin /root/phpmyadmin-install.log
        Install_Only_phpMyAdmin "${2:-}" 2>&1 | tee -a /root/phpmyadmin-install.log
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

# 完整安装成功结束才清除进度标记；失败时保留，供下次运行识别中断阶段。
if [ "${Install_Rc}" -eq 0 ]; then
    case "${Stack}" in
        lnmp|lnmpa|lamp) Install_Progress_Done ;;
    esac
fi

exit ${Install_Rc}
