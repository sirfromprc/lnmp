#!/usr/bin/env bash
#
# 完整安装入口（lnmp/lnmpa/lamp）的安装残留检测与清理。
# 中断的安装不会留下可用的 /bin/lnmp，本文件不依赖该命令，也不调用 uninstall.sh。
# 删除动作复用 include/cleanup.sh 的共享实现。

# Detect_Install_Residue 的结果，每行一条。
Install_Residue_Items=''

# 检测路径的前缀，默认空即检测真实系统路径。定向测试用它把检测范围
# 指到临时目录，只影响检测，清理函数一律使用绝对路径。
Residue_Root="${Residue_Root:-}"

# 本包安装的顶层目录，检测和清理共用同一份清单。
Residue_Dirs='/usr/local/mysql /usr/local/mariadb /usr/local/nginx /usr/local/openresty
/usr/local/php /usr/local/apache /usr/local/zend /usr/local/phpmyadmin'

# 本包安装的管理命令，/bin 与 /usr/bin 未合并的系统上两处都要清理。
Residue_Commands='lnmp lnmp-backup lnmp-tgnotice lnmp-phpmyadmin lnmp-perm
lnmp-health lnmp-sqlguard lnmp-cutlogs'

Residue_Init_Scripts='mysql mariadb nginx httpd php-fpm'

Residue_Add()
{
    Install_Residue_Items="${Install_Residue_Items}${1}
"
}

# 输出本包目录下正在运行的进程，每行 "<pid> <可执行文件>"。
# 只认可执行文件位于 /usr/local 下的进程，发行版自带的同名服务不在范围内。
Residue_Running_Procs()
{
    local name pid exe

    for name in mysqld mariadbd nginx php-fpm httpd; do
        for pid in $(pgrep -x "${name}" 2>/dev/null); do
            exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null)
            case "${exe}" in
            /usr/local/*) printf '%s %s\n' "${pid}" "${exe}" ;;
            esac
        done
    done
}

# 检测安装残留。有残留返回 0 并填充 Install_Residue_Items，环境干净返回 1。
Detect_Install_Residue()
{
    local path ver pid exe started

    Install_Residue_Items=''

    for path in ${Residue_Dirs}; do
        [ -e "${Residue_Root}${path}" ] && Residue_Add "目录：${path}"
    done
    for ver in ${MPHP_Supported_Vers}; do
        [ -d "${Residue_Root}/usr/local/php${ver}" ] && Residue_Add "目录：/usr/local/php${ver}"
    done

    [ -e "${Residue_Root}/etc/my.cnf" ] && Residue_Add "配置：/etc/my.cnf"
    [ -d "${Residue_Root}/etc/lnmp" ] && Residue_Add "配置：/etc/lnmp"

    for path in ${Residue_Init_Scripts}; do
        [ -e "${Residue_Root}/etc/init.d/${path}" ] &&
            Residue_Add "启动脚本：/etc/init.d/${path}"
        [ -e "${Residue_Root}/etc/systemd/system/${path}.service" ] &&
            Residue_Add "服务单元：/etc/systemd/system/${path}.service"
    done

    for path in ${Residue_Commands}; do
        [ -e "${Residue_Root}/bin/${path}" ] && Residue_Add "管理命令：/bin/${path}"
        # /bin 与 /usr/bin 未合并的系统上两处是不同文件，需要分别列出。
        if [ -e "${Residue_Root}/usr/bin/${path}" ] &&
           ! [ "${Residue_Root}/bin/${path}" -ef "${Residue_Root}/usr/bin/${path}" ]; then
            Residue_Add "管理命令：/usr/bin/${path}"
        fi
    done

    if started=$(Install_Progress_Get started); then
        Residue_Add "未完成的安装：${started} 开始，进度标记 ${Install_Progress_File}"
    fi

    # php-fpm 的 worker 可能有几十个，按可执行文件聚合，避免清单刷屏。
    while read -r count exe; do
        [ -n "${exe}" ] || continue
        Residue_Add "运行中的进程：${exe}（${count} 个）"
    done <<< "$(Residue_Running_Procs | awk '{print $2}' | LC_ALL=C sort | uniq -c)"

    [ -S "${Residue_Root}/run/mysqld/mysqld.sock" ] &&
        Residue_Add "数据库套接字：/run/mysqld/mysqld.sock"

    [ -n "${Install_Residue_Items}" ] || return 1
    return 0
}

# 打印上一次 Detect_Install_Residue 的结果。
Print_Install_Residue()
{
    local line

    printf '%s' "${Install_Residue_Items}" | while IFS= read -r line; do
        [ -n "${line}" ] && echo "  - ${line}"
    done
}

# 已装好的环境重装的确认。这里的组件是在用的，不是中断留下的半成品，
# 因此要求输入完整的 yes，不接受单个 y。
Confirm_Reinstall_Installed()
{
    local ans

    case "${LNMP_Purge_Residue:-}" in
    yes)
        echo "LNMP_Purge_Residue=yes，直接清理现有环境并重新安装。"
        return 0
        ;;
    no)
        Echo_Yellow "LNMP_Purge_Residue=no，保留现有环境，安装已中止。"
        return 1
        ;;
    esac

    if [ ! -t 0 ]; then
        Echo_Red "标准输入不是终端，无法确认重装，安装已中止。"
        Echo_Red "自动化请设置 LNMP_Purge_Residue=yes 后重试。"
        return 1
    fi

    echo ""
    Echo_Yellow "重新安装会停止上述服务并删除上述目录、配置和命令。"
    Echo_Yellow "数据库数据目录不会被删除，会先移动到 /root/databases_backup_<时间戳>；"
    Echo_Yellow "网站目录、证书和 /root 下的备份不在清理范围内。"
    if ! read -r -p "确认重新安装请输入 yes ，其它输入一律取消：" ans; then
        echo
        Echo_Red "读取确认时遇到 EOF，安装已中止。"
        return 1
    fi
    if [ "${ans}" != "yes" ]; then
        Echo_Yellow "输入与 yes 不一致，保留现有环境，安装已中止。"
        return 1
    fi
    return 0
}

# 中断安装留下的残留的清理确认。非交互环境只接受显式 LNMP_Purge_Residue=yes。
Confirm_Purge_Residue()
{
    local ans

    case "${LNMP_Purge_Residue:-}" in
    yes)
        echo "LNMP_Purge_Residue=yes，直接清理上述残留。"
        return 0
        ;;
    no)
        Echo_Yellow "LNMP_Purge_Residue=no，不清理残留，安装已中止。"
        return 1
        ;;
    esac

    if [ ! -t 0 ]; then
        Echo_Red "标准输入不是终端，无法确认清理，安装已中止。"
        Echo_Red "自动化请设置 LNMP_Purge_Residue=yes 后重试。"
        return 1
    fi

    echo ""
    Echo_Yellow "清理会停止上述服务并删除上述目录、配置和命令。"
    Echo_Yellow "数据库数据目录不会被删除，会先移动到 /root/databases_backup_<时间戳>。"
    if ! read -r -p "是否清理这些残留并重新安装？[y/N]：" ans; then
        echo
        Echo_Red "读取确认时遇到 EOF，安装已中止。"
        return 1
    fi
    case "${ans}" in
    y|Y|yes|YES) return 0 ;;
    esac
    Echo_Yellow "未确认清理，安装已中止。"
    return 1
}

# 停止本包部署的服务。init 脚本、systemd 单元和进程三条路径都要走，
# 中断的安装可能只留下其中一种。
Stop_Residue_Services()
{
    local svc ver pid exe waited left

    for svc in nginx php-fpm httpd mysql mariadb pureftpd redis memcached; do
        if Systemd_Is_Running; then
            systemctl stop "${svc}.service" >/dev/null 2>&1
            systemctl disable "${svc}.service" >/dev/null 2>&1
            systemctl reset-failed "${svc}.service" >/dev/null 2>&1
        fi
        [ -x "/etc/init.d/${svc}" ] && "/etc/init.d/${svc}" stop >/dev/null 2>&1
    done

    for ver in ${MPHP_Supported_Vers}; do
        if Systemd_Is_Running; then
            systemctl stop "php-fpm@${ver}.service" >/dev/null 2>&1
            systemctl disable "php-fpm@${ver}.service" >/dev/null 2>&1
        fi
        [ -x "/etc/init.d/php-fpm${ver}" ] && "/etc/init.d/php-fpm${ver}" stop >/dev/null 2>&1
    done

    # 先按 exe 路径确认是本包进程再终止，最多等待 10 秒后强杀。
    left=$(Residue_Running_Procs)
    if [ -n "${left}" ]; then
        echo "正在终止 $(printf '%s\n' "${left}" | wc -l) 个残留进程..."
        while read -r pid exe; do
            [ -n "${pid}" ] || continue
            kill -TERM "${pid}" >/dev/null 2>&1
        done <<< "${left}"
    fi

    waited=0
    while [ ${waited} -lt 10 ] && [ -n "$(Residue_Running_Procs)" ]; do
        sleep 1
        waited=$((waited + 1))
    done

    left=$(Residue_Running_Procs)
    if [ -n "${left}" ]; then
        Echo_Yellow "$(printf '%s\n' "${left}" | wc -l) 个残留进程未响应 TERM，强制终止。"
        while read -r pid exe; do
            [ -n "${pid}" ] || continue
            kill -KILL "${pid}" >/dev/null 2>&1
        done <<< "${left}"
    fi

    return 0
}

# 清理数据库残留。数据目录先移出删除范围，移动失败则整个清理中止。
Purge_Residue_DB()
{
    local dir path

    for dir in "${MySQL_Data_Dir}" "${MariaDB_Data_Dir}"; do
        Backup_DB_Data "${dir}" || return 1
    done

    rm -rf /usr/local/mysql /usr/local/mariadb
    rm -f /etc/my.cnf /etc/init.d/mysql /etc/init.d/mariadb
    Remove_DB_Command_Links
    Remove_DB_Dev_Links
    Remove_Libaio_Compat_Link

    # 异常退出留下的套接字和 pid 文件会让下次安装误判有实例在运行。
    for path in /run/mysqld/mysqld.sock /run/mysqld/mysqld.pid; do
        [ -e "${path}" ] || continue
        if fuser "${path}" >/dev/null 2>&1; then
            Echo_Red "${path} 仍被进程占用，无法清理，安装已中止。"
            return 1
        fi
        rm -f "${path}"
    done
    rmdir /run/mysqld 2>/dev/null

    # 密码初始化使用的私有临时目录，异常退出时会残留。
    find /run -maxdepth 1 -name 'lnmp-db-init.*' -type d -exec rm -rf {} + 2>/dev/null
    return 0
}

# 清理 Web 服务端残留。OpenResty 由软件包安装，需先走包管理器卸载。
Purge_Residue_Web()
{
    if [ -d /usr/local/openresty ]; then
        Uninstall_OpenResty
    fi
    rm -rf /usr/local/nginx /usr/local/php /usr/local/apache /usr/local/zend
    rm -rf /usr/local/phpmyadmin /var/lib/phpmyadmin
    find /usr/local -maxdepth 1 -name 'phpmyadmin.bak.*' -exec rm -rf {} + 2>/dev/null
    rm -f /etc/init.d/nginx /etc/init.d/php-fpm /etc/init.d/httpd
    return 0
}

# 清理管理命令与其单元文件。
Purge_Residue_Commands()
{
    local name unit svc changed='n'

    for name in ${Residue_Commands}; do
        rm -f "/bin/${name}"
        [ -e "/usr/bin/${name}" ] && rm -f "/usr/bin/${name}"
    done
    rm -f /etc/profile.d/lnmp-tgnotice.sh

    # 只删 ExecStart 指向本包组件的单元，发行版同名服务不动。
    for svc in ${Residue_Init_Scripts}; do
        unit="/etc/systemd/system/${svc}.service"
        [ -f "${unit}" ] || continue
        grep -qE "^ExecStart=[^[:space:]]*(/usr/local/|/etc/init\.d/${svc}([[:space:]]|$))" \
            "${unit}" || continue
        rm -f "${unit}"
        changed='y'
    done
    [ "${changed}" = 'y' ] && Systemd_Is_Running && systemctl daemon-reload >/dev/null 2>&1
    return 0
}

# 彻底清理安装残留。任一步骤失败均返回非零，由调用方中止安装。
Purge_Install_Residue()
{
    echo ""
    Echo_Yellow "开始清理安装残留..."
    Stop_Residue_Services
    Purge_Residue_DB || return 1
    Purge_Residue_Web
    Remove_Multiple_PHP
    Remove_Backup_Schedule
    Remove_Health_Schedule
    Remove_Cutlogs_Schedule
    Remove_App_Hosting
    Remove_Perm_Hooks
    Remove_Lnmp_Conf_Dir
    Purge_Residue_Commands
    Firewall_Purge
    rm -f "${Install_Progress_File}"

    # 清理后必须复检，仍有残留说明有目录或进程没能删掉。
    if Detect_Install_Residue; then
        Echo_Red "清理后仍存在以下残留，安装已中止："
        Print_Install_Residue
        Echo_Red "请手工删除上述目录或终止上述进程后重新执行安装。"
        return 1
    fi
    Echo_Green "安装残留已清理完毕。"
    return 0
}

# 完整安装入口的前置检查。进度标记只在安装成功收尾时删除，据此区分
# 「已经装好、正在用的环境」和「上次没装完留下的半成品」，两者确认方式不同。
Check_Install_Residue()
{
    local started

    Detect_Install_Residue || return 0

    if started=$(Install_Progress_Get started); then
        Echo_Yellow "检测到 ${started} 开始的安装没有完成，环境里留下了以下内容："
        Print_Install_Residue
        Confirm_Purge_Residue || return 1
    else
        Echo_Yellow "你已成功安装过 ${Stack}，如需重新安装，请先备份相关数据。"
        Echo_Yellow "本机现有以下组件："
        Print_Install_Residue
        Confirm_Reinstall_Installed || return 1
    fi

    Purge_Install_Residue || return 1
    return 0
}
