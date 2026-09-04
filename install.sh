#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ "$(id -u)" != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi

# 源码根目录按脚本自身位置确定：从其它目录以绝对路径启动时，
# pwd 指向调用者的当前目录，相对路径 source 会加载到那里的同名文件。
cur_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
if [ ! -s "${cur_dir}/lnmp.conf" ] || [ ! -d "${cur_dir}/include" ]; then
    echo "错误：${cur_dir} 不是 LNMP 源码目录，缺少 lnmp.conf 或 include/。"
    exit 1
fi
cd "${cur_dir}" || exit 1
Stack=$1
if [ "${Stack}" = "" ]; then
    Stack="lnmp"
else
    Stack=$1
fi

LNMP_Ver='2.3'
. "${cur_dir}/lnmp.conf"
# version.sh 提供菜单所需的组件版本常量，必须在选择函数执行前载入。
. "${cur_dir}/include/version.sh"
. "${cur_dir}/include/main.sh"
. "${cur_dir}/include/verify.sh"
. "${cur_dir}/include/firewall.sh"
. "${cur_dir}/include/profile.sh"
. "${cur_dir}/include/dbcommon.sh"
. "${cur_dir}/include/init.sh"
. "${cur_dir}/include/mysql.sh"
. "${cur_dir}/include/mariadb.sh"
. "${cur_dir}/include/php.sh"
. "${cur_dir}/include/nginx.sh"
# 提供安装和升级流程使用的 Telegram 通知函数。
. "${cur_dir}/tools/lnmp-tgnotice.sh"
. "${cur_dir}/include/openresty_modules.sh"
. "${cur_dir}/include/openresty.sh"
. "${cur_dir}/include/apache.sh"
. "${cur_dir}/include/end.sh"
. "${cur_dir}/include/only.sh"
. "${cur_dir}/include/multiplephp.sh"
. "${cur_dir}/include/imageMagick.sh"
. "${cur_dir}/include/php_default_ext.sh"
. "${cur_dir}/include/cleanup.sh"
. "${cur_dir}/include/residue.sh"
. "${cur_dir}/include/precheck.sh"

Validate_Service_Ports || exit 1
Get_Dist_Name

if [ "${DISTRO}" = "unknow" ]; then
    Echo_Red "无法识别 Linux 发行版，或当前发行版不受支持。"
    exit 1
fi

Check_LNMPConf

clear 2>/dev/null || true
Print_Banner \
    "LNMP V${LNMP_Ver} 安装程序" \
    "在 ${DISTRO} Linux 上安装 LNMP、LNMPA 或 LAMP" \
    "仅使用上游官方源码，并强制校验完整性"

# 编译耗时长，ssh 直连掉线会中断安装，因此在做任何选择之前先提示。
case "${Stack}" in
    lnmp|lnmpa|lamp) Warn_Detached_Session ;;
esac

# 已安装的组件和中断安装留下的残留都会让本次安装装到一半失败，
# 因此在安装开始前统一检测，确认后清理成干净环境再继续。
# LNMP_Resume_Broken_Install=yes 保留为不清理直接续装的显式入口。
if [[ "${Stack}" = "lnmp" || "${Stack}" = "lnmpa" || "${Stack}" = "lamp" ]]; then
    if [ "${LNMP_Resume_Broken_Install:-}" = "yes" ]; then
        Echo_Yellow "LNMP_Resume_Broken_Install=yes，跳过残留检测，继续在现有环境上重装。"
    else
        Check_Install_Residue || exit 1
    fi
fi

Init_Install()
{
    Press_Install
    # 确认开始安装后、系统被改动前的集中预检：磁盘、内存、端口和本次要下载的
    # 地址一次查完，无风险不输出，有风险由用户决定是否继续。
    # 返回码原样传出，供入口区分「预检就退出」和「安装中途失败」。
    Precheck_Install || return $?
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
    Init_Install || return $?
    Install_PHP
    LNMP_PHP_Opt
    Install_WebServer || return 1
    Creat_PHP_Tools || return 1
    Add_Firewall_Rules
    # 启动阶段失败仍要打印验收结果，返回码由两者合并。
    local startup_rc=0
    Add_LNMP_Startup || startup_rc=1
    Check_LNMP_Install || return 1
    return ${startup_rc}
}

LNMPA_Stack()
{
    Apache_Selection || return 1
    Save_Install_Answers
    Init_Install || return $?
    Dispatch "${Apache_Install}"
    Install_PHP
    Install_WebServer || return 1
    Creat_PHP_Tools || return 1
    Add_Firewall_Rules
    # 启动阶段失败仍要打印验收结果，返回码由两者合并。
    local startup_rc=0
    Add_LNMPA_Startup || startup_rc=1
    Check_LNMPA_Install || return 1
    return ${startup_rc}
}

LAMP_Stack()
{
    Apache_Selection || return 1
    Save_Install_Answers
    Init_Install || return $?
    Dispatch "${Apache_Install}"
    Install_PHP
    Creat_PHP_Tools || return 1
    Add_Firewall_Rules
    # 启动阶段失败仍要打印验收结果，返回码由两者合并。
    local startup_rc=0
    Add_LAMP_Startup || startup_rc=1
    Check_LAMP_Install || return 1
    return ${startup_rc}
}


# 整栈入口涉及 lnmp.conf 的全部选项，安装前统一确认一次；单组件入口的
# 配置项在各自的安装摘要里列出，这里只做 SSH 端口检查。
# 不涉及端口和防火墙的 phpMyAdmin 管理子命令及 mphp 不执行该确认。
case "${Stack}" in
    lnmp|lnmpa|lamp)
        Confirm_LNMPConf_Reviewed
        Check_SSH_Port_Policy || exit 1
        ;;
    nginx|db)
        Check_SSH_Port_Policy || exit 1
        ;;
esac

Install_Rc=0

case "${Stack}" in
    lnmp)
        Reuse_Install_Answers
        Dispaly_Selection
        Save_Install_Answers
        Install_Log_Begin /root/lnmp-install.log
        Install_Progress_Begin
        LNMP_Stack 2>&1 | tee -a /root/lnmp-install.log
        Install_Rc=${PIPESTATUS[0]}
        ;;
    lnmpa)
        Reuse_Install_Answers
        Dispaly_Selection
        Save_Install_Answers
        Install_Log_Begin /root/lnmp-install.log
        Install_Progress_Begin
        LNMPA_Stack 2>&1 | tee -a /root/lnmp-install.log
        Install_Rc=${PIPESTATUS[0]}
        ;;
    lamp)
        Reuse_Install_Answers
        Dispaly_Selection
        Save_Install_Answers
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

# 完整安装成功结束才清除进度标记和选择记录；失败时保留，供下次运行识别中断阶段。
if [ "${Install_Rc}" -eq 0 ]; then
    case "${Stack}" in
        lnmp|lnmpa|lamp) Install_Progress_Done ;;
    esac
elif [ "${Install_Rc}" -eq 2 ]; then
    # 预检就结束安装，系统尚未被改动：清掉本次进度标记，避免下次运行误报残留。
    # 菜单选择记录保留，重跑时仍可沿用。
    case "${Stack}" in
        lnmp|lnmpa|lamp) rm -f "${Install_Progress_File}" ;;
    esac
else
    # 失败后用户面对的是半成品环境，这里直接说明重跑会做什么，避免手工收拾。
    case "${Stack}" in
    lnmp|lnmpa|lamp)
        echo
        Echo_Yellow "本次安装未完成。直接重新执行即可："
        echo
        echo "  bash install.sh ${Stack}"
        echo
        Echo_Yellow "重跑会先列出本次留下的目录、服务和进程，确认后清理成干净环境，"
        Echo_Yellow "并沿用本次已经做过的菜单选择，不需要手工卸载或重选。"
        Echo_Yellow "数据库数据目录不会被删除，会先移动到 /root/databases_backup_<时间戳>。"
        Echo_Yellow "完整日志：/root/lnmp-install.log"
        ;;
    esac
fi

exit ${Install_Rc}
