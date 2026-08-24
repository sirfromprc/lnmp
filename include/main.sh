#!/usr/bin/env bash

# 安装过程会创建 /usr/local 下的程序目录，服务账号需要遍历和读取。
# 调用者可能带着 umask 077 执行，这里固定为可预期值，密码等敏感文件
# 仍由各自的 ( umask 077; ... ) 子 shell 单独收紧。
umask 022

# 数据库、PHP 和 Apache 的菜单信息与编号映射统一定义在 profile.sh。

# phpMyAdmin 位于网站根目录之外，防止 Web 配置失效时源码和 config.inc.php
# 被作为静态文件下载；访问入口由 Web 服务器单独映射。
PhpMyAdmin_Dir='/usr/local/phpmyadmin'

# 保存随机访问路径，供安装完成提示和 lnmp status 查询。
PhpMyAdmin_Url_File="${PhpMyAdmin_Dir}/.access_url"

# 源码编译数据库的磁盘下限，与安装前集中预检（include/precheck.sh）共用。
DB_Source_Build_Min_Disk_MB=15360

# 源码编译 MySQL 需要较多内存、磁盘和时间。低于最低资源要求时停止并建议
# 使用官方通用二进制；低于推荐内存时要求交互确认，非交互执行仅提示风险。
Check_DB_Source_Build()
{
    local mem_mb disk_mb min_mem rec_mem=4096 ans jobs
    local min_disk="${DB_Source_Build_Min_Disk_MB}"

    [ "${DB_Kind}" = "none" ] && return 0
    [ "${Bin}" = "y" ] && return 0

    mem_mb=$(awk '/MemTotal/ {printf "%d", $2 / 1024; exit}' /proc/meminfo 2>/dev/null)
    case "${mem_mb}" in ''|*[!0-9]*) mem_mb=0 ;; esac
    disk_mb=$(df -Pm "${cur_dir}" 2>/dev/null | awk 'NR==2 {print $4}')
    case "${disk_mb}" in ''|*[!0-9]*) disk_mb=0 ;; esac

    min_mem="${DB_Min_Mem_MB:-0}"
    case "${min_mem}" in ''|*[!0-9]*) min_mem=0 ;; esac
    [ "${min_mem}" -lt 2048 ] && min_mem=2048

    if [ "${mem_mb}" -lt "${min_mem}" ]; then
        Echo_Red "内存 ${mem_mb}MB，低于源码编译 ${DB_Ver} 所需的 ${min_mem}MB。"
        Echo_Red "请改用官方通用二进制：Bin=y 重新执行，几分钟装完，功能一致。"
        return 1
    fi
    if [ "${disk_mb}" -lt "${min_disk}" ]; then
        Echo_Red "${cur_dir} 所在分区剩余 ${disk_mb}MB，低于源码编译所需的 ${min_disk}MB。"
        Echo_Red "实测编译目录会涨到 7GB 以上，装完还要再占用 /usr/local。"
        Echo_Red "请清理磁盘，或改用官方通用二进制：Bin=y。"
        return 1
    fi
    [ "${mem_mb}" -ge "${rec_mem}" ] && return 0

    jobs=$(Build_Jobs)
    Echo_Yellow "======================================================================"
    Echo_Yellow "注意：你选择了源码编译 ${DB_Ver}，当前内存 ${mem_mb}MB。"
    Echo_Yellow "  - 低于建议的 ${rec_mem}MB，编译只能开 ${jobs} 个并行任务，"
    Echo_Yellow "    这类机器上通常要跑数小时，链接阶段仍可能因内存不足失败。"
    Echo_Yellow "  - 官方通用二进制由上游构建，校验值同样强制核对，几分钟装完。"
    Echo_Yellow "  - 除非确实需要定制编译参数，否则建议改用 Bin=y。"
    Echo_Yellow "======================================================================"
    if [ ! -t 0 ] || [ "${LNMP_Auto}" = "y" ]; then
        Echo_Yellow "当前为非交互执行，按原选择继续源码编译。"
        return 0
    fi
    read -r -p "确认继续源码编译请输入 y，其它输入一律中止： " ans
    case "${ans}" in
        [yY]) return 0 ;;
        *) Echo_Red "已中止。改用官方通用二进制：Bin=y ./install.sh ..."; return 1 ;;
    esac
}

Database_Selection()
{
    # 选择需要安装的数据库版本。
    if [ -z "${DBSelect}" ]; then
        Print_DB_Menu
        read -p "请选择数据库版本（1-${DB_Count}，0 表示不安装，默认 ${DB_Default}）: " DBSelect
    fi

    # 编号通过 profile.sh 映射为版本、架构和默认策略。
    # 仅空输入使用默认值；非法编号必须终止安装。
    if [ -z "${DBSelect}" ]; then
        DBSelect="${DB_Default}"
        echo "未输入，默认安装 ${DB_Info[$((DB_Default-1))]}。"
    fi
    Set_DB_Profile "${DBSelect}" || Invalid_Selection DB "${DBSelect}"

    if [ "${DB_Kind}" = "none" ]; then
        echo "不安装 MySQL/MariaDB。"
    else
        Select_DB_Bin
    fi

    Check_DB_Source_Build || exit 1

    if [[ "${DBSelect}" != "0" ]]; then
        # 设置数据库 root 密码，输入过程不回显且不写入安装日志。
        DB_Root_Password_Random='n'
        if [ -z "${DB_Root_Password}" ]; then
            echo "==========================="
            Echo_Yellow "请设置 MySQL/MariaDB 的 root 密码（输入不回显）。"
            read -r -s -p "请输入密码（留空则随机生成）: " DB_Root_Password
            echo
            if [ "${DB_Root_Password}" = "" ]; then
                echo "未输入密码，将随机生成。"
                DB_Root_Password="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
                DB_Root_Password_Random='y'
            fi
        fi

        # 选择是否启用 InnoDB 存储引擎。
        echo "==========================="

        if [ -z ${InstallInnodb} ]; then
            InstallInnodb="y"
            Echo_Yellow "是否启用 InnoDB 存储引擎？"
            read -p "请输入 [Y/n]（默认 y，启用）: " InstallInnodb
        fi

        case "${InstallInnodb}" in
        [yY][eE][sS]|[yY])
            echo "将启用 InnoDB 存储引擎。"
            InstallInnodb="y"
            ;;
        [nN][oO]|[nN])
            echo "将禁用 InnoDB 存储引擎。"
            InstallInnodb="n"
            ;;
        "")
            echo "未输入，默认启用 InnoDB 存储引擎。"
            InstallInnodb="y"
            ;;
        *)
            echo "输入无效，按默认设置启用 InnoDB 存储引擎。"
            InstallInnodb="y"
        esac
    fi
}

PHP_Selection()
{
    # 选择需要安装的 PHP 版本。
    if [ -z "${PHPSelect}" ]; then
        echo "==========================="

        Print_PHP_Menu
        read -p "请选择 PHP 版本（1-${PHP_Count}，默认 ${PHP_Default}）: " PHPSelect
    fi

    # PHP 版本属性由 profile.sh 提供；空输入与非法输入分别处理。
    if [ -z "${PHPSelect}" ]; then
        PHPSelect="${PHP_Default}"
        echo "未输入，默认安装 ${PHP_Info[$((PHP_Default-1))]}。"
    fi
    Set_PHP_Profile "${PHPSelect}" || Invalid_Selection PHP "${PHPSelect}"
    echo "将安装 ${PHP_Info[$((PHPSelect-1))]}。"

    if [ "${PHP_Needs_DB}" = "y" ] && [ "${DBSelect}" = "0" ]; then
        echo "未选择 MySQL/MariaDB，不能安装 ${PHP_Info[$((PHPSelect-1))]}。"
        exit 1
    fi
}

MemoryAllocator_Selection()
{
    # 选择可选的内存分配器。
    if [ -z ${SelectMalloc} ]; then
        echo "==========================="

        SelectMalloc="1"
        Echo_Yellow "内存分配器有 3 个选项："
        echo "1: 不安装内存分配器（默认）"
        echo "2: 安装 Jemalloc"
        echo "3: 安装 TCMalloc"
        read -p "请选择 [1-3]（默认 1，不安装）: " SelectMalloc
    fi

    case "${SelectMalloc}" in
    1)
        echo "不安装内存分配器。"
        ;;
    2)
        echo "将安装 Jemalloc。"
        ;;
    3)
        echo "将安装 TCMalloc。"
        ;;
    "")
        echo "未输入，默认不安装内存分配器。"
        SelectMalloc="1"
        ;;
    *)
        echo "输入无效，按默认设置不安装内存分配器。"
        SelectMalloc="1"
    esac

    if [ "${SelectMalloc}" =  "1" ]; then
        MySQL51MAOpt=''
        MySQLMAOpt=''
        NginxMAOpt=''
    elif [ "${SelectMalloc}" =  "2" ]; then
        MySQL51MAOpt='--with-mysqld-ldflags=-ljemalloc'
        MySQLMAOpt='[mysqld_safe]
malloc-lib=/usr/lib/libjemalloc.so'
        NginxMAOpt="--with-ld-opt='-ljemalloc'"
    elif [ "${SelectMalloc}" =  "3" ]; then
        MySQL51MAOpt='--with-mysqld-ldflags=-ltcmalloc'
        MySQLMAOpt='[mysqld_safe]
malloc-lib=/usr/lib/libtcmalloc.so'
        NginxMAOpt='--with-google_perftools_module'
    fi
}

# 选择互斥的 Nginx 或 OpenResty。结果变量：
#   WebServer               nginx | openresty
#   OpenResty_Install_Mode  pkg | source（仅 WebServer=openresty 时有意义）
# 非交互参数：
#   WebSelect=1                          安装 Nginx（默认）
#   WebSelect=2 ORMode=1                 装 OpenResty，官方仓库预编译包
#   WebSelect=2 ORMode=2                 装 OpenResty，源码编译
# 仅 lnmp 和 lnmpa 需要此选项；lamp 不安装 nginx。
Web_Selection()
{
    WebServer='nginx'
    OpenResty_Install_Mode=''

    # LAMP 不安装 Nginx 或 OpenResty。
    if [ "${Stack}" = "lamp" ]; then
        return 0
    fi

    if [ -z "${WebSelect}" ]; then
        echo "==========================="
        Echo_Yellow "Web 服务器有 2 个选项："
        echo "1: 安装 Nginx ${Nginx_Ver#nginx-}（源码编译，默认）"
        echo "2: 安装 OpenResty（自带 LuaJIT 与 lua-resty-* 组件）"
        read -p "请选择 [1-2]（默认 1，Nginx）: " WebSelect
    fi

    case "${WebSelect}" in
    2|[oO][pP][eE][nN][rR][eE][sS][tT][yY])
        WebServer='openresty'
        # 回填编号，使中断重装沿用记录时不再重复询问。
        WebSelect='2'
        echo "将安装 OpenResty。"
        ;;
    *)
        WebServer='nginx'
        [ -z "${WebSelect}" ] && echo "未输入选项，使用默认项 Nginx。" \
                              || echo "已选择安装 Nginx。"
        WebSelect='1'
        # Nginx 与现有 OpenResty 不能同时占用相同服务入口。
        Check_WebServer_Conflict nginx || exit 1
        return 0
        ;;
    esac

    # OpenResty 可选择官方软件包或源码编译。
    if [ -z "${ORMode}" ]; then
        echo "==========================="
        Echo_Yellow "OpenResty 有两种安装方式："
        echo "1: 官方软件仓库的预编译包（**不编译**，快；需要上游提供当前发行版的包）"
        echo "2: 官方源码编译（慢，但不挑发行版；用 PGP 签名校验）"
        read -p "请选择 [1-2]（默认 1，官方软件包）: " ORMode
    fi

    case "${ORMode}" in
    2|[sS][oO][uU][rR][cC][eE])
        OpenResty_Install_Mode='source'
        ORMode='2'
        echo "将从源码编译安装 OpenResty ${OpenResty_Ver#openresty-}。"
        ;;
    *)
        OpenResty_Install_Mode='pkg'
        ORMode='1'
        echo "将从官方软件仓库安装 OpenResty。"
        ;;
    esac

    # 安装前检查 Web 服务器冲突，避免占用相同端口和服务名。
    Check_WebServer_Conflict openresty || exit 1
    return 0
}

Dispaly_Selection()
{
    Database_Selection
    PHP_Selection
    Web_Selection
    MemoryAllocator_Selection
}

Apache_Selection()
{
    echo "==========================="
    # 设置 Apache 服务器管理员邮箱。
    if [ -z "${ServerAdmin}" ]; then
        ServerAdmin=""
        read -r -p "请输入服务器管理员邮箱（默认 webmaster@example.com）: " ServerAdmin
    fi
    if [ "${ServerAdmin}" == "" ]; then
        echo "未输入，服务器管理员邮箱将设为 webmaster@example.com。"
        ServerAdmin="webmaster@example.com"
    else
        echo "==========================="
        echo "服务器管理员邮箱：${ServerAdmin}"
        echo "==========================="
    fi
    Check_Server_Admin_Email "${ServerAdmin}" || return 1
    echo "==========================="

    # Apache 仅支持 2.4；保留 ApacheSelect 以兼容命令行参数。
    [ -z "${ApacheSelect}" ] && ApacheSelect="${Apache_Default}"
    Set_Apache_Profile "${ApacheSelect}" || Invalid_Selection Apache "${ApacheSelect}"
    echo "将安装 ${Apache_Info[$((ApacheSelect-1))]}。"
}

# 完整安装的进度标记，用于区分「用户在用的数据库」和「上次没装完留下的残留」。
# 仅由 install.sh 的 lnmp/lnmpa/lamp 入口维护，安装成功后删除。
Install_Progress_File="${Install_Progress_File:-/root/.lnmp-install-progress}"

Install_Progress_Begin()
{
    if ! printf 'stack=%s\nstarted=%s\npid=%s\n' \
         "${Stack:-lnmp}" "$(date '+%F %T')" "$$" > "${Install_Progress_File}"; then
        Echo_Yellow "无法写入安装进度标记 ${Install_Progress_File}，中断后的重跑提示会不准确。"
        return 1
    fi
    chmod 600 "${Install_Progress_File}" 2>/dev/null
    return 0
}

# Install_Progress_Mark <阶段名>：记录已完成的阶段，取值由调用方约定。
Install_Progress_Mark()
{
    [ -s "${Install_Progress_File}" ] || return 0
    printf 'stage=%s\n' "$1" >> "${Install_Progress_File}" || return 1
    return 0
}

Install_Progress_Done()
{
    rm -f "${Install_Progress_File}" "${Install_Answers_File}"
}

# Install_Progress_Get <键>：输出最后一次写入的值；无标记或无该键时输出空并返回 1。
Install_Progress_Get()
{
    local value
    [ -s "${Install_Progress_File}" ] || return 1
    value=$(awk -F= -v k="$1" '$1 == k {v = $2} END {print v}' "${Install_Progress_File}")
    [ -n "${value}" ] || return 1
    printf '%s' "${value}"
}

# 完整安装的菜单选择记录。中断后重装可直接沿用，不必重走一遍选择。
# 只记录菜单选项，数据库 root 口令等敏感值一律不写入，安装成功后删除。
Install_Answers_File="${Install_Answers_File:-/root/.lnmp-install-answers}"

Install_Answers_Vars='DBSelect Bin InstallInnodb PHPSelect SelectMalloc
WebSelect ORMode ApacheSelect ServerAdmin'

Save_Install_Answers()
{
    local var val tmp

    tmp=$(mktemp "${Install_Answers_File}.XXXXXX") || {
        Echo_Yellow "无法写入安装选择记录，中断后重装需要重新选择。"
        return 1
    }
    chmod 600 "${tmp}"
    {
        echo "# LNMP 安装选择记录，中断后重装时可沿用；不含数据库口令。"
        printf 'Answers_Stack=%s\n' "${Stack:-lnmp}"
        printf 'Answers_Saved=%s\n' "$(date '+%F_%T')"
        for var in ${Install_Answers_Vars}; do
            val=${!var-}
            [ -n "${val}" ] || continue
            printf '%s=%s\n' "${var}" "${val}"
        done
    } > "${tmp}" || { rm -f "${tmp}"; return 1; }

    if ! mv -f "${tmp}" "${Install_Answers_File}"; then
        rm -f "${tmp}"
        Echo_Yellow "无法保存安装选择记录 ${Install_Answers_File}。"
        return 1
    fi
    return 0
}

# Read_Saved_Answer <键>：输出记录中该键的值，无该键时输出空。
Read_Saved_Answer()
{
    [ -s "${Install_Answers_File}" ] || return 1
    awk -F= -v k="$1" '$1 !~ /^#/ && $1 == k {print $2; exit}' "${Install_Answers_File}"
}

# Saved_Answer_Valid <键> <值>：键必须在白名单内，值只允许菜单编号、
# y/n 及邮箱用到的字符。记录文件被改坏时按无效丢弃，不会带进安装流程。
Saved_Answer_Valid()
{
    local key="$1" val="$2" var known='n'

    for var in ${Install_Answers_Vars}; do
        [ "${var}" = "${key}" ] && { known='y'; break; }
    done
    [ "${known}" = 'y' ] || return 1
    [ -n "${val}" ] || return 1
    case "${val}" in
        *[!A-Za-z0-9._@+-]*) return 1 ;;
    esac
    return 0
}

# 按菜单上的文字打印记录里的选择，供用户确认后再决定是否沿用。
# 中英文混排下按字节补空格对不齐，因此用「项：值」逐行输出。
Print_Saved_Answers()
{
    local db php web malloc apache admin innodb saved

    saved=$(Read_Saved_Answer Answers_Saved)
    db=$(Read_Saved_Answer DBSelect)
    php=$(Read_Saved_Answer PHPSelect)
    web=$(Read_Saved_Answer WebSelect)
    malloc=$(Read_Saved_Answer SelectMalloc)
    apache=$(Read_Saved_Answer ApacheSelect)
    admin=$(Read_Saved_Answer ServerAdmin)
    innodb=$(Read_Saved_Answer InstallInnodb)

    echo "==========================="
    echo "上次的安装选择（记录于 ${saved:-未知时间}）："
    echo "  安装栈：${Stack}"

    if [ "${db}" = "0" ]; then
        echo "  数据库：不安装"
    elif [ -n "${db}" ] && [ "${db}" -ge 1 ] 2>/dev/null && [ "${db}" -le "${DB_Count}" ]; then
        if [ "$(Read_Saved_Answer Bin)" = "y" ]; then
            echo "  数据库：${DB_Info[$((db-1))]}（官方通用二进制）"
        else
            echo "  数据库：${DB_Info[$((db-1))]}（源码编译）"
        fi
        echo "  启用 InnoDB：${innodb:-y}"
    fi

    if [ -n "${php}" ] && [ "${php}" -ge 1 ] 2>/dev/null && [ "${php}" -le "${PHP_Count}" ]; then
        echo "  PHP：${PHP_Info[$((php-1))]}"
    fi

    if [ "${Stack}" != "lamp" ]; then
        case "${web}" in
        2)
            if [ "$(Read_Saved_Answer ORMode)" = "2" ]; then
                echo "  Web 服务器：OpenResty（源码编译）"
            else
                echo "  Web 服务器：OpenResty（官方仓库预编译包）"
            fi
            ;;
        *) echo "  Web 服务器：Nginx" ;;
        esac
    fi

    if [ "${Stack}" != "lnmp" ]; then
        if [ -n "${apache}" ] && [ "${apache}" -ge 1 ] 2>/dev/null &&
           [ "${apache}" -le "${Apache_Count}" ]; then
            echo "  Apache：${Apache_Info[$((apache-1))]}"
        fi
        [ -n "${admin}" ] && echo "  管理员邮箱：${admin}"
    fi

    case "${malloc}" in
    2) echo "  内存分配器：Jemalloc" ;;
    3) echo "  内存分配器：TCMalloc" ;;
    *) echo "  内存分配器：不安装" ;;
    esac

    echo "  数据库 root 口令不记录，沿用时需要重新输入。"
    echo "==========================="
}

# 载入上次的安装选择。无记录或安装栈不同返回 1。
# 命令行和环境变量已给出的选择优先，记录只补空缺。
Load_Install_Answers()
{
    local key val

    [ -s "${Install_Answers_File}" ] || return 1
    [ "$(Read_Saved_Answer Answers_Stack)" = "${Stack}" ] || return 1

    while IFS='=' read -r key val; do
        Saved_Answer_Valid "${key}" "${val}" || continue
        [ -n "${!key}" ] && continue
        printf -v "${key}" '%s' "${val}"
    done < "${Install_Answers_File}"
    return 0
}

# 有上次记录时先列出具体选择，确认后才沿用；不确认则走正常菜单。
Reuse_Install_Answers()
{
    local ans

    [ -s "${Install_Answers_File}" ] || return 0
    # 安装栈不同的记录不参与本次安装，也不打扰用户。
    [ "$(Read_Saved_Answer Answers_Stack)" = "${Stack}" ] || return 0

    case "${LNMP_Reuse_Answers:-}" in
    no)
        return 0
        ;;
    yes)
        ;;
    *)
        if [ "${LNMP_Auto:-}" != "y" ]; then
            if [ ! -t 0 ]; then
                return 0
            fi
            echo ""
            Echo_Yellow "检测到上次未完成安装时的选择记录 ${Install_Answers_File}。"
            Print_Saved_Answers
            if ! read -r -p "沿用以上选择请输入 y ，输入其它任意键重新选择：" ans; then
                echo
                return 0
            fi
            case "${ans}" in
            y|Y|yes|YES) ;;
            *)
                Echo_Yellow "不沿用，按正常流程重新选择。"
                return 0
                ;;
            esac
        else
            Print_Saved_Answers
        fi
        ;;
    esac

    if Load_Install_Answers; then
        Echo_Green "已沿用上次的安装选择，只需重新输入数据库 root 口令。"
    else
        Echo_Yellow "选择记录不可用，按正常流程重新选择。"
    fi
    return 0
}

# Install_Log_Begin <日志文件>：写入本次运行的分隔行，供追加写入的日志区分批次。
# 超过 10MB 时先滚动为 .1，避免反复重装把日志撑大；只保留一份历史。
Install_Log_Begin()
{
    local log="$1" size

    size=$(stat -c %s "${log}" 2>/dev/null || echo 0)
    if [ "${size}" -gt $((10 * 1024 * 1024)) ] && ! mv -f "${log}" "${log}.1"; then
        Echo_Yellow "日志滚动失败，继续追加写入 ${log}。"
    fi
    if ! printf '\n===== %s  %s  pid=%s =====\n' \
         "$(date '+%F %T')" "${Stack:-lnmp}" "$$" >> "${log}"; then
        Echo_Yellow "无法写入 ${log}，本次安装日志可能不完整。"
        return 1
    fi
    return 0
}

# 在限定时间内等待包管理器锁释放。
# 不终止包管理器进程，也不删除活动锁文件，避免破坏 dpkg/rpm 数据库。
# Kill_PM 保留为兼容别名。
PM_Lock_Wait_Sec=300

# apt 1.9 起支持 DPkg::Lock::Timeout，锁被占用时自行等待而非立即失败；
# 更早版本忽略未知配置项，行为与不带该选项一致。所有 apt-get 调用统一经此包装。
APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-300}"

Apt_Get()
{
    apt-get -o DPkg::Lock::Timeout="${APT_LOCK_TIMEOUT}" "$@"
}

PM_Lock_Busy()
{
    # fuser 直接检查锁文件是否由进程持有。
    local f
    if [ "${PM}" = "yum" ]; then
        for f in /var/run/yum.pid /var/lib/rpm/.rpm.lock; do
            [ -e "${f}" ] || continue
            fuser "${f}" >/dev/null 2>&1 && return 0
        done
        # 旧版 yum 可能只保留 pid 文件，因此同时检查对应进程是否存活。
        if [ -s /var/run/yum.pid ]; then
            kill -0 "$(cat /var/run/yum.pid 2>/dev/null)" 2>/dev/null && return 0
        fi
    else
        for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do
            [ -e "${f}" ] || continue
            fuser "${f}" >/dev/null 2>&1 && return 0
        done
    fi
    return 1
}

Wait_PM()
{
    local waited=0

    if ! command -v fuser >/dev/null 2>&1; then
        Echo_Yellow "未找到 fuser（psmisc），跳过包管理器锁检测。"
        Echo_Yellow "若稍后装依赖时报 'Could not get lock'，请等自动更新结束后重试。"
        return 0
    fi

    PM_Lock_Busy || return 0

    Echo_Yellow "检测到包管理器正在被占用（通常是系统自动更新），等待其结束..."
    while PM_Lock_Busy; do
        if [ ${waited} -ge ${PM_Lock_Wait_Sec} ]; then
            Echo_Red "等待 ${PM_Lock_Wait_Sec} 秒后包管理器仍被占用，中止安装。"
            Echo_Red "请确认没有 unattended-upgrades / dnf-automatic 或其他管理员的操作在跑，"
            Echo_Red "结束后重新执行本脚本。"
            Echo_Red "（本脚本不会强杀包管理进程，也不会删除锁文件 ——"
            Echo_Red "  在 dpkg/rpm 写库中途被打断会留下半配置的包和损坏的数据库。）"
            exit 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    echo "包管理器已空闲，继续。"
}

# 保留现有调用使用的函数名。
Kill_PM()
{
    Wait_PM
}

# 编译耗时较长，ssh 直连时掉线会使安装中断在半途。提示放在选择开始前，
# 避免选完各项才发现要改用 screen/tmux 重跑一遍。
Warn_Detached_Session()
{
    [ -n "${STY:-}" ] && return 0
    [ -n "${TMUX:-}" ] && return 0
    [ -n "${SSH_CONNECTION:-}" ] || return 0

    Echo_Yellow "=========================================================================="
    Echo_Yellow "当前为 ssh 直连会话，编译期间掉线会中断安装。"
    Echo_Yellow "建议先按 Ctrl+C 退出，执行 screen -S lnmp（或 tmux new -s lnmp）后再运行本脚本，"
    Echo_Yellow "掉线后用 screen -r lnmp（或 tmux attach -t lnmp）接回。"
    Echo_Yellow "=========================================================================="
}

Press_Install()
{
    . include/version.sh
    Set_Profiles

    case "${Stack}" in
    lnmp|lnmpa|lamp)
        # 完整安装前展示版本、端口及目录等系统变更，供用户确认。
        Echo_Yellow "=========================================================================="
        Echo_Yellow "您即将安装/编译以下模块，请确认！" 
        Print_APP_Ver
        Confirm_Start_Install || exit 1
        ;;
    # 单组件入口只展示该组件的版本、生效配置和系统变更，确认语义与整栈一致。
    nginx)
        Print_Nginx_Only_Summary
        Confirm_Start_Install || exit 1
        ;;
    db)
        Print_DB_Only_Summary
        Confirm_Start_Install || exit 1
        ;;
    pureftpd)
        Print_Pureftpd_Only_Summary
        Confirm_Start_Install || exit 1
        ;;
    *)
        Press_Start || exit 1
        ;;
    esac

    Kill_PM
}

# lnmp、lnmpa 和 lamp 在安装依赖及编译前进行最终确认。
# 只有显式 LNMP_Auto=y 可跳过；无终端或 EOF 一律取消，不按默认选择继续。
Confirm_Start_Install()
{
    local ans

    if [ "${LNMP_Auto:-}" = "y" ]; then
        Echo_Yellow "LNMP_Auto=y，按以上信息直接开始安装。"
        return 0
    fi

    if [ ! -t 0 ]; then
        Echo_Red "标准输入不是终端，无法确认安装，已取消。"
        Echo_Red "请在交互终端执行，或设置 LNMP_Auto=y 并完整提供各项安装选择。"
        return 1
    fi

    echo ""
    if ! read -r -p "确认以上信息，开始安装请输入 y，其它输入一律取消： " ans; then
        echo
        Echo_Red "读取确认时遇到 EOF，已取消安装。"
        return 1
    fi
    case "${ans}" in
        [yY]) return 0 ;;
        *)
            Echo_Yellow "已取消安装。"
            return 1
            ;;
    esac
}

# 菜单编号在加载 version.sh 后转换为版本属性；profile.sh 提供随选项变化的值。
Set_Profiles()
{
    if [ -n "${DBSelect}" ]; then
        Set_DB_Profile "${DBSelect}" || Invalid_Selection DB "${DBSelect}"
    fi
    if [ -n "${PHPSelect}" ]; then
        Set_PHP_Profile "${PHPSelect}" || Invalid_Selection PHP "${PHPSelect}"
    fi
    if [ -n "${ApacheSelect}" ]; then
        Set_Apache_Profile "${ApacheSelect}" || Invalid_Selection Apache "${ApacheSelect}"
    fi
}

# 非法编号直接报错，避免意外安装默认版本。
Invalid_Selection()
{
    Echo_Red "致命错误：${1}Select 的值无效：'${2}'"
    case "$1" in
    DB)
        Echo_Red "有效值：0（跳过），1-${DB_Count}"
        ;;
    PHP)
        Echo_Red "有效值：1-${PHP_Count}"
        ;;
    Apache)
        Echo_Red "有效值：1-${Apache_Count}"
        ;;
    esac
    exit 1
}

# 按键确认必须来自真实终端；无终端只接受显式 LNMP_Auto=y，
# stty/dd 失败或 EOF 一律返回非 0，调用方须终止后续系统变更。
Press_Start()
{
    local oldconfig

    if [ "${LNMP_Auto:-}" = "y" ]; then
        echo "LNMP_Auto=y，跳过按键确认。"
        return 0
    fi

    if [ ! -t 0 ]; then
        Echo_Red "标准输入不是终端，无法读取确认按键，已取消。"
        Echo_Red "请在交互终端执行，或设置 LNMP_Auto=y 明确表示自动确认。"
        return 1
    fi

    echo ""
    Echo_Green "按任意键开始，或按 Ctrl+C 取消。"
    oldconfig=$(stty -g) || { Echo_Red "读取终端状态失败，已取消。"; return 1; }
    if ! stty -icanon -echo min 1 time 0; then
        Echo_Red "设置终端状态失败，已取消。"
        return 1
    fi
    if ! dd bs=1 count=1 >/dev/null 2>&1; then
        stty "${oldconfig}"
        Echo_Red "读取确认按键失败，已取消。"
        return 1
    fi
    stty "${oldconfig}"
    return 0
}

Install_LSB()
{
    echo "[+] 正在安装 lsb..."
    if [ "$PM" = "yum" ]; then
        yum -y install redhat-lsb
    elif [ "$PM" = "apt" ]; then
        Apt_Get update
        Apt_Get --no-install-recommends install -y lsb-release
    fi
}

Get_Dist_Version()
{
    if command -v lsb_release >/dev/null 2>&1; then
        DISTRO_Version=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        DISTRO_Version="$DISTRIB_RELEASE"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_Version="$VERSION_ID"
    fi
    if [[ "${DISTRO}" = "" || "${DISTRO_Version}" = "" ]]; then
        if command -v python2 >/dev/null 2>&1; then
            DISTRO_Version=$(python2 -c 'import platform; print platform.linux_distribution()[1]')
        elif command -v python3 >/dev/null 2>&1; then
            DISTRO_Version=$(python3 -c 'import platform; print(platform.linux_distribution()[1])')
        else
            Install_LSB
            DISTRO_Version=`lsb_release -rs`
        fi
    fi
    printf -v "${DISTRO}_Version" '%s' "${DISTRO_Version}"
}

Get_Dist_Name()
{
    if grep -Eqi "Alibaba" /etc/issue || grep -Eq "Alibaba Cloud Linux" /etc/*-release; then
        DISTRO='Alibaba'
        PM='yum'
    elif grep -Eqi "Aliyun" /etc/issue || grep -Eq "Aliyun Linux" /etc/*-release; then
        DISTRO='Aliyun'
        PM='yum'
    elif grep -Eqi "Amazon Linux" /etc/issue || grep -Eq "Amazon Linux" /etc/*-release; then
        DISTRO='Amazon'
        PM='yum'
    elif grep -Eqi "Fedora" /etc/issue || grep -Eq "Fedora" /etc/*-release; then
        DISTRO='Fedora'
        PM='yum'
    elif grep -Eqi "Oracle Linux" /etc/issue || grep -Eq "Oracle Linux" /etc/*-release; then
        DISTRO='Oracle'
        PM='yum'
    elif grep -Eqi "rockylinux" /etc/issue || grep -Eq "Rocky Linux" /etc/*-release; then
        DISTRO='Rocky'
        PM='yum'
    elif grep -Eqi "almalinux" /etc/issue || grep -Eq "AlmaLinux" /etc/*-release; then
        DISTRO='Alma'
        PM='yum'
    elif grep -Eqi "openEuler" /etc/issue || grep -Eq "openEuler" /etc/*-release; then
        DISTRO='openEuler'
        PM='yum'
    elif grep -Eqi "Anolis OS" /etc/issue || grep -Eq "Anolis OS" /etc/*-release; then
        DISTRO='Anolis'
        PM='yum'
    elif grep -Eqi "Kylin Linux Advanced Server" /etc/issue || grep -Eq "Kylin Linux Advanced Server" /etc/*-release; then
        DISTRO='Kylin'
        PM='yum'
    elif grep -Eqi "OpenCloudOS" /etc/issue || grep -Eq "OpenCloudOS" /etc/*-release; then
        DISTRO='OpenCloudOS'
        PM='yum'
    elif grep -Eqi "Huawei Cloud EulerOS" /etc/issue || grep -Eq "Huawei Cloud EulerOS" /etc/*-release; then
        DISTRO='HCE'
        PM='yum'
    elif grep -Eqi "CentOS" /etc/issue || grep -Eq "CentOS" /etc/*-release; then
        DISTRO='CentOS'
        PM='yum'
        if grep -Eq "CentOS Stream" /etc/*-release; then
            isCentosStream='y'
        fi
    elif grep -Eqi "Red Hat Enterprise Linux" /etc/issue || grep -Eq "Red Hat Enterprise Linux" /etc/*-release; then
        DISTRO='RHEL'
        PM='yum'
    elif grep -Eqi "Ubuntu" /etc/issue || grep -Eq "Ubuntu" /etc/*-release; then
        DISTRO='Ubuntu'
        PM='apt'
    elif grep -Eqi "Raspbian" /etc/issue || grep -Eq "Raspbian" /etc/*-release; then
        DISTRO='Raspbian'
        PM='apt'
    elif grep -Eqi "Deepin" /etc/issue || grep -Eq "Deepin" /etc/*-release; then
        DISTRO='Deepin'
        PM='apt'
    elif grep -Eqi "Mint" /etc/issue || grep -Eq "Mint" /etc/*-release; then
        DISTRO='Mint'
        PM='apt'
    elif grep -Eqi "Kali" /etc/issue || grep -Eq "Kali" /etc/*-release; then
        DISTRO='Kali'
        PM='apt'
    elif grep -Eqi "Debian" /etc/issue || grep -Eq "Debian" /etc/*-release; then
        DISTRO='Debian'
        PM='apt'
    elif grep -Eqi "UnionTech OS|UOS" /etc/issue || grep -Eq "UnionTech OS|UOS" /etc/*-release; then
        DISTRO='UOS'
        if command -v apt >/dev/null 2>&1; then
            PM='apt'
        elif command -v yum >/dev/null 2>&1; then
            PM='yum'
        fi
    elif grep -Eqi "Kylin Linux Desktop" /etc/issue || grep -Eq "Kylin Linux Desktop" /etc/*-release; then
        DISTRO='Kylin'
        PM='apt'
    else
        DISTRO='unknow'
    fi
    Get_OS_Bit
}

Get_RHEL_Version()
{
    Get_Dist_Name
    if [ "${DISTRO}" = "RHEL" ]; then
        if grep -Eqi "release 5." /etc/redhat-release; then
            echo "当前版本：RHEL 5"
            RHEL_Ver='5'
        elif grep -Eqi "release 6." /etc/redhat-release; then
            echo "当前版本：RHEL 6"
            RHEL_Ver='6'
        elif grep -Eqi "release 7." /etc/redhat-release; then
            echo "当前版本：RHEL 7"
            RHEL_Ver='7'
        elif grep -Eqi "release 8." /etc/redhat-release; then
            echo "当前版本：RHEL 8"
            RHEL_Ver='8'
        elif grep -Eqi "release 9." /etc/redhat-release; then
            echo "当前版本：RHEL 9"
            RHEL_Ver='9'
        elif grep -Eqi "release 10." /etc/redhat-release; then
            echo "当前版本：RHEL 10"
            RHEL_Ver='10'
        fi
        RHEL_Version="$(cat /etc/redhat-release | sed 's/.*release\ //' | sed 's/\ .*//')"
    fi
}

Get_OS_Bit()
{
    if [[ `getconf WORD_BIT` = '32' && `getconf LONG_BIT` = '64' ]] ; then
        Is_64bit='y'
        ARCH='x86_64'
        DB_ARCH='x86_64'
    else
        Is_64bit='n'
        ARCH='i386'
        DB_ARCH='i686'
    fi

    if uname -m | grep -Eqi "arm|aarch64"; then
        Is_ARM='y'
        if uname -m | grep -Eqi "armv7|armv6"; then
            ARCH='armhf'
        elif uname -m | grep -Eqi "aarch64"; then
            ARCH='aarch64'
            DB_ARCH='aarch64'
        else
            ARCH='arm'
        fi
    fi
}

# Verify_Download_File <文件名> [retry]：SHA256 完整性校验。
# 清单缺失、条目缺失或哈希不匹配时终止安装。
# 带 retry 时哈希不匹配只删除文件并返回 2，由调用方重新下载一次。
# 组件版本变更必须同步更新 src/checksums.sha256。
Verify_Download_File()
{
    local FileName=$1
    local Retry_Mode=${2:-}
    local Checksum_File="${cur_dir}/src/checksums.sha256"
    local Expected_SHA256=""
    local Actual_SHA256=""

    # 关闭完整性校验时必须在终端和日志中明确警告。
    if [ "${Enable_Download_Checksum}" != "y" ]; then
        Echo_Red "!! 完整性校验已关闭（Enable_Download_Checksum='${Enable_Download_Checksum}'），${FileName} 未经校验。"
        Echo_Red "!! 这只应用于排查问题。此次安装的组件无法保证与上游一致，不可用于上线。"
        Checksum_Disabled_Warned='y'
        return 0
    fi

    if [ ! -s "${Checksum_File}" ]; then
        Echo_Red "致命错误：找不到校验清单 ${Checksum_File}"
        Echo_Red "完整性校验是强制要求，拒绝使用 ${FileName}。"
        Echo_Red "仅排查问题时可在 lnmp.conf 设置 Enable_Download_Checksum='n' 跳过（不推荐）。"
        rm -f "${FileName}"
        exit 1
    fi

    Expected_SHA256=$(awk -v file="${FileName}" '$1 !~ /^#/ && $2 == file {print $1; exit}' "${Checksum_File}")
    if [ "${Expected_SHA256}" = "" ]; then
        Echo_Red "致命错误：${Checksum_File} 中没有 ${FileName} 的校验值。"
        Echo_Red "未登记的文件不会被使用，请先将其 SHA256 写入校验清单。"
        rm -f "${FileName}"
        exit 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        Actual_SHA256=$(sha256sum "${FileName}" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        Actual_SHA256=$(shasum -a 256 "${FileName}" | awk '{print $1}')
    else
        Echo_Red "致命错误：系统没有 sha256sum 或 shasum，无法校验 ${FileName}。"
        exit 1
    fi

    if [ "${Actual_SHA256}" != "${Expected_SHA256}" ]; then
        rm -f "${FileName}"
        if [ "${Retry_Mode}" = "retry" ]; then
            Echo_Yellow "${FileName} 的 SHA256 与清单不符，已删除该文件。"
            Echo_Yellow "  期望值：${Expected_SHA256}"
            Echo_Yellow "  实际值：${Actual_SHA256}"
            Echo_Yellow "上次下载中断会留下残缺文件，现在重新下载一次。"
            return 2
        fi
        Echo_Red "致命错误：${FileName} 的 SHA256 不匹配。"
        Echo_Red "  期望值：${Expected_SHA256}"
        Echo_Red "  实际值：${Actual_SHA256}"
        Echo_Red "该文件已删除；重新下载后仍不匹配，下载内容可能被篡改。"
        exit 1
    fi
    Echo_Green "${FileName} 的 SHA256 校验通过。"
    return 0
}

# 探测模式：Download_Files 只把待下载地址写入 Download_Probe_File，不下载也不校验，
# 供安装前预检复用现有下载流程收集本次安装真正要取的链接。
Download_Probe_Only='n'
Download_Probe_File=''

# Require_File <文件名> <描述>
# 下载后的存在性检查，防止下载失败后继续编译。
# 所有入口脚本均加载 main.sh，因此该函数在此统一定义。
Require_File()
{
    [ "${Download_Probe_Only}" = "y" ] && return 0
    if [ ! -s "$1" ]; then
        Echo_Red "错误：无法下载 $2。"
        Echo_Red "请手动下载到 src 目录：$1"
        sleep 5
        exit 1
    fi
}

# 安装侧使用固定版本和 src/checksums.sha256。
# Download_Fetch 强制 HTTPS，禁止重定向降级并限制重定向次数。
Download_Files()
{
    local URL=$1
    local FileName=$2
    local Verify_RC=0

    [ "${FileName}" = "" ] && FileName="${URL##*/}"

    # 探测模式只登记「文件名 + 地址」，src 下已有的文件不依赖网络，不必登记。
    # 返回非零使调用方继续登记备用地址（如 MySQL 的 archives 路径），
    # 预检按文件名分组判定，任一地址可用即算可下载。
    if [ "${Download_Probe_Only}" = "y" ]; then
        [ -s "${FileName}" ] || printf '%s\t%s\n' "${FileName}" "${URL}" >> "${Download_Probe_File}"
        return 1
    fi

    # 已存在的文件校验失败时，多半是上次下载被中断留下的残缺包，
    # 删除后走下面的下载流程重取一次，再失败才按内容异常终止。
    if [ -s "${FileName}" ]; then
        echo "${FileName} [已存在]"
        Verify_Download_File "${FileName}" retry
        Verify_RC=$?
        [ "${Verify_RC}" -eq 2 ] || return "${Verify_RC}"
    fi

    if [ "${Verify_RC}" -eq 2 ]; then
        echo "提示：正在重新下载 ${FileName}..."
    else
        echo "提示：未找到 ${FileName}，现在开始下载..."
    fi
    if [ "${Download_Insecure}" = "y" ]; then
        # 仅用于证书故障诊断；该模式不验证 TLS 证书。
        Echo_Red "警告：Download_Insecure='y' 会关闭 TLS 证书校验。"
        wget -c --progress=dot -e dotbytes=20M --prefer-family=IPv4 \
             --max-redirect=${DL_MAX_REDIRECT:-5} --no-check-certificate \
             "${URL}" -O "${FileName}" || return 1
    else
        Download_Fetch "${URL}" "${FileName}" || return 1
    fi
    Verify_Download_File "${FileName}"
}

# Tar_Cd <包名> [解压后的目录名]：目录切换、解压或目标检查失败时终止。
# Check_Conf_Applied <文件> <期望匹配的正则> <说明>
# 配置模板改动可能使 sed 未命中却仍返回成功，因此写入后验证目标值，
# 防止服务监听端口与防火墙放行端口不一致。
Check_Conf_Applied()
{
    local file="$1" pattern="$2" what="$3"
    if [ ! -s "${file}" ]; then
        Echo_Red "${what}：找不到配置文件 ${file}"
        return 1
    fi
    if ! grep -Eq -- "${pattern}" "${file}"; then
        Echo_Red "${what} 未能写入 ${file}（模板结构可能变了）。"
        Echo_Red "服务会用模板里的默认端口启动，与防火墙规则对不上。"
        Echo_Red "请手工核对该文件后再启动服务。"
        return 1
    fi
    return 0
}

# Get_Actual_DB_Port [配置文件]
# 输出本机数据库实际监听的端口，取不到时退回 lnmp.conf 的 DB_Port。
# 返回 0 表示取自配置文件，返回 1 表示用的是退回值。
# 环境变量指定的安装端口不会回写 lnmp.conf，后续安装 phpMyAdmin 时需读取
# /etc/my.cnf 的 [mysqld] 端口，确保 TCP 连接使用数据库当前监听值。
Get_Actual_DB_Port()
{
    local conf="${1:-/etc/my.cnf}" port=''

    if [ -s "${conf}" ]; then
        port=$(awk '
            /^[[:space:]]*\[/ {
                section = $0
                sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
                sub(/[[:space:]]*\].*$/, "", section)
                next
            }
            section == "mysqld" && /^[[:space:]]*port[[:space:]]*=/ {
                value = $0
                sub(/^[^=]*=[[:space:]]*/, "", value)
                sub(/[[:space:]#].*$/, "", value)
                if (value != "") last = value
            }
            END { if (last != "") print last }
        ' "${conf}" 2>/dev/null)
    fi

    case "${port}" in
        ''|*[!0-9]*) port='' ;;
        *) [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ] || port='' ;;
    esac

    if [ -z "${port}" ]; then
        printf '%s\n' "${DB_Port}"
        return 1
    fi
    printf '%s\n' "${port}"
    return 0
}

# 输出数据库实际使用的 socket 路径，[client] 优先，其次 [mysqld]。
# --defaults-file 不读 /etc/my.cnf，临时凭据必须自带 socket 才能连上。
Get_Actual_DB_Socket()
{
    local conf="${1:-/etc/my.cnf}" sock=''

    if [ -s "${conf}" ]; then
        sock=$(awk '
            /^[[:space:]]*\[/ {
                section = $0
                sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
                sub(/[[:space:]]*\].*$/, "", section)
                next
            }
            /^[[:space:]]*socket[[:space:]]*=/ {
                value = $0
                sub(/^[^=]*=[[:space:]]*/, "", value)
                sub(/[[:space:]#].*$/, "", value)
                if (value == "") next
                if (section == "client" && client == "") client = value
                else if (section == "mysqld" && server == "") server = value
            }
            END { print (client != "" ? client : server) }
        ' "${conf}" 2>/dev/null)
    fi
    printf '%s' "${sock:-/run/mysqld/mysqld.sock}"
}

# 探测本机对外 IPv4，取默认路由的源地址；取不到不输出并返回 1。
# 不查询外部服务，避免安装收尾阶段因网络阻塞。
Get_Server_IP()
{
    local addr

    addr=$(ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -n "${addr}" ] || return 1
    printf '%s' "${addr}"
}

# 探测系统当前实际监听的 SSH 端口。sshd_config 尚未重载或 ExecStart 使用
# -o Port= 覆盖时，配置文件值可能与真实监听端口不同。
# 优先看真实监听的 socket（ss/netstat 能看到内核当前的状态），
# 两者都不可用时才退回解析 sshd_config（含 Debian/Ubuntu 默认
# Include 的 /etc/ssh/sshd_config.d/*.conf）；配置文件存在但没有
# 显式 Port 行，按 OpenSSH 的默认值处理，即 22。
# 输出：每行一个端口号，按数字升序去重。彻底探测不到（没有 ss/netstat，
# 也找不到 sshd_config）时不输出并返回 1。
Get_Actual_SSH_Port()
{
    local port
    local -a ports=()

    if command -v ss >/dev/null 2>&1; then
        while read -r port; do
            case "${port}" in ''|*[!0-9]*) continue ;; esac
            ports+=("${port}")
        done < <(ss -Htlnp 2>/dev/null | grep -F 'sshd' | awk '{print $4}' | sed -E 's/.*://')
    fi

    if [ ${#ports[@]} -eq 0 ] && command -v netstat >/dev/null 2>&1; then
        while read -r port; do
            case "${port}" in ''|*[!0-9]*) continue ;; esac
            ports+=("${port}")
        done < <(netstat -tlnp 2>/dev/null | grep -F 'sshd' | awk '{print $4}' | sed -E 's/.*://')
    fi

    if [ ${#ports[@]} -eq 0 ] && [ -s /etc/ssh/sshd_config ]; then
        while read -r port; do
            case "${port}" in ''|*[!0-9]*) continue ;; esac
            ports+=("${port}")
        done < <(Get_Sshd_Config_Ports)
        [ ${#ports[@]} -eq 0 ] && ports=(22)
    fi

    if [ ${#ports[@]} -eq 0 ]; then
        return 1
    fi
    printf '%s\n' "${ports[@]}" | sort -un
    return 0
}

# Get_Sshd_Config_Ports [sshd_config 路径]
#
# 解析 sshd_config 及同目录 sshd_config.d/*.conf 中的 Port 指令，覆盖
# Debian/Ubuntu 默认 Include 布局；默认读取 /etc/ssh/sshd_config。
Get_Sshd_Config_Ports()
{
    local conf="${1:-/etc/ssh/sshd_config}"
    local conf_dir f
    local -a files

    conf_dir=$(dirname "${conf}")
    files=("${conf}" "${conf_dir}/sshd_config.d/"*.conf)

    for f in "${files[@]}"; do
        [ -s "${f}" ] || continue
        grep -Eio '^[[:space:]]*Port[[:space:]]+[0-9]+' "${f}" 2>/dev/null | awk '{print $2}'
    done
}

# 在任何安装动作前统一校验端口。变量会进入配置、sed 和防火墙命令，
# 非数字、越界或互相冲突都应在下载、停服务或改系统之前直接拒绝。
Validate_Service_Ports()
{
    local names=(DB_Port DB_X_Port Redis_Port Memcached_Port
                 Pureftpd_Port Pureftpd_Data_Port)
    local values=("${DB_Port}" "${DB_X_Port}" "${Redis_Port}"
                  "${Memcached_Port}" "${Pureftpd_Port}" "${Pureftpd_Data_Port}")
    local i j name value

    for i in "${!names[@]}"; do
        name="${names[$i]}"
        value="${values[$i]}"
        case "${value}" in
            ''|*[!0-9]*)
                Echo_Red "${name} 必须是 1-65535 的整数，当前值：'${value}'"
                return 1
                ;;
        esac
        if [ "${value}" -lt 1 ] || [ "${value}" -gt 65535 ]; then
            Echo_Red "${name} 超出端口范围 1-65535：${value}"
            return 1
        fi
    done

    for name in Pureftpd_Passive_Min Pureftpd_Passive_Max; do
        value="${!name}"
        case "${value}" in
            ''|*[!0-9]*)
                Echo_Red "${name} 必须是 1-65535 的整数，当前值：'${value}'"
                return 1
                ;;
        esac
        if [ "${value}" -lt 1 ] || [ "${value}" -gt 65535 ]; then
            Echo_Red "${name} 超出端口范围 1-65535：${value}"
            return 1
        fi
    done
    if [ "${Pureftpd_Passive_Min}" -gt "${Pureftpd_Passive_Max}" ]; then
        Echo_Red "Pureftpd_Passive_Min 不能大于 Pureftpd_Passive_Max。"
        return 1
    fi

    for i in "${!names[@]}"; do
        for ((j=i+1; j<${#names[@]}; j++)); do
            if [ "${values[$i]}" -eq "${values[$j]}" ]; then
                Echo_Red "端口冲突：${names[$i]} 与 ${names[$j]} 都是 ${values[$i]}。"
                return 1
            fi
        done
        if [ "${values[$i]}" -ge "${Pureftpd_Passive_Min}" ] \
           && [ "${values[$i]}" -le "${Pureftpd_Passive_Max}" ]; then
            Echo_Red "端口冲突：${names[$i]}=${values[$i]} 落在 Pure-FTPd 被动端口范围内。"
            return 1
        fi
    done
    return 0
}

Tar_Cd()
{
    local FileName=$1
    local DirName=$2
    local extension=${FileName##*.}

    if ! cd "${cur_dir}/src"; then
        Echo_Red "致命错误：无法进入目录 ${cur_dir}/src"
        exit 1
    fi
    [[ -d "${DirName}" ]] && rm -rf "${DirName}"
    echo "正在解压 ${FileName}..."
    case "${extension}" in
    gz|tgz) tar zxf "${FileName}" ;;
    bz2)    tar jxf "${FileName}" ;;
    xz)     tar Jxf "${FileName}" ;;
    *)
        Echo_Red "致命错误：${FileName} 使用了未知的归档扩展名 '${extension}'。"
        exit 1
        ;;
    esac
    if [ $? -ne 0 ]; then
        Echo_Red "致命错误：${FileName} 解压失败。"
        exit 1
    fi

    if [ -n "${DirName}" ]; then
        echo "正在进入目录 ${DirName}..."
        if ! cd "${DirName}"; then
            Echo_Red "致命错误：${FileName} 解压后没有预期的目录 ${DirName}。"
            Echo_Red "归档结构与预期不符，拒绝在错误的目录里继续编译。"
            exit 1
        fi
    fi
}

Check_LNMPConf()
{
    if [ ! -s "${cur_dir}/lnmp.conf" ]; then
        Echo_Red "lnmp.conf 不存在。"
        exit 1
    fi
    if [[ "${MySQL_Data_Dir}" = "" || "${MariaDB_Data_Dir}" = "" || "${Default_Website_Dir}" = "" ]]; then
        Echo_Red "无法从 lnmp.conf 读取必要配置。"
        exit 1
    fi
    if [[ "${MySQL_Data_Dir}" = "/" || "${MariaDB_Data_Dir}" = "/" || "${Default_Website_Dir}" = "/" ]]; then
        Echo_Red "MySQL、MariaDB 或网站目录不能设置为根目录 /。"
        exit 1
    fi
}

# 选择版本前提醒核对 lnmp.conf 中的端口、数据库目录、网站目录和
# phpMyAdmin 开关。非交互执行仅提示。
Confirm_LNMPConf_Reviewed()
{
    local ans

    Echo_Yellow "=========================================================================="
    Echo_Yellow "开始安装前，请根据实际需求检查并确认 ${cur_dir}/lnmp.conf 中的配置："
    Echo_Yellow "  - DB_Port 等端口是否与系统实际配置一致。"
    Echo_Yellow "  - Default_Website_Dir / MySQL_Data_Dir 等目录是否符合预期。"
    Echo_Yellow "  - Enable_PhpMyAdmin 等开关是否需要现在就打开。"
    Echo_Yellow "=========================================================================="

    if [ ! -t 0 ] || [ "${LNMP_Auto}" = "y" ]; then
        Echo_Yellow "当前为非交互执行，按 lnmp.conf 现有配置继续。"
        return 0
    fi

    read -r -p "已检查/确认无需修改，继续安装请输入 y。需要修改 lnmp.conf 请输入其它任意键退出： " ans
    case "${ans}" in
        [yY]) return 0 ;;
        *)
            Echo_Red "已退出。请改好 ${cur_dir}/lnmp.conf 后重新执行本命令。"
            exit 1
            ;;
    esac
}

# Get_Nginx_Modules_Summary <变量名>：把 lnmp.conf 中 Nginx 附加模块开关的最终取值
# 汇总到指定变量，整栈摘要与单独安装摘要共用同一份取值。
Get_Nginx_Modules_Summary()
{
    local __summary_var=$1 summary=''

    [ "${Enable_Nginx_Lua}" = "y" ] && summary='Lua'
    if [ "${Enable_Ngx_Brotli}" = "y" ]; then
        summary="${summary}${summary:+, }Brotli"
    fi
    if [ "${Enable_Ngx_CachePurge}" = "y" ]; then
        summary="${summary}${summary:+, }Cache Purge"
    fi
    if [ "${Enable_Ngx_FancyIndex}" = "y" ]; then
        summary="${summary}${summary:+, }FancyIndex"
    fi
    [ -n "${Nginx_Modules_Options}" ] && \
        printf -v summary '%s%s自定义选项：%s' "${summary}" \
            "${summary:+；}" "${Nginx_Modules_Options}"
    [ -n "${summary}" ] || printf -v summary '无'
    printf -v "${__summary_var}" '%s' "${summary}"
}

Print_APP_Ver()
{
    local nginx_modules='' php_modules='' ssh_ports

    echo "将安装 ${Stack} 技术栈。"
    if [ "${Stack}" != "lamp" ]; then
        if [ "${WebServer}" = "openresty" ]; then
            if [ "${OpenResty_Install_Mode}" = "source" ]; then
                echo "${OpenResty_Ver} (源码编译)"
            else
                echo "openresty (官方仓库预编译包，版本以仓库为准)"
            fi
        else
            echo "${Nginx_Ver}"
        fi
    fi

    if [ "${DB_Kind}" = "none" ]; then
        echo "不安装 MySQL/MariaDB。"
    else
        echo "${DB_Ver}"
    fi

    echo "${Php_Ver}"

    if [ "${Stack}" != "lnmp" ]; then
        echo "${Apache_Ver}"
    fi

    if [ "${SelectMalloc}" = "2" ]; then
        echo "${Jemalloc_Ver}"
    elif [ "${SelectMalloc}" = "3" ]; then
        echo "${TCMalloc_Ver}"
    fi
    [ "${DB_Kind}" != "none" ] && echo "启用 InnoDB：${InstallInnodb}"
    echo "lnmp.conf 配置信息："
    echo "下载来源：仅限上游官方来源"
    echo "完整性校验：${Enable_Download_Checksum}"

    if [ "${Stack}" = "lamp" ]; then
        printf -v nginx_modules '未安装'
    elif [ "${WebServer}" = "openresty" ]; then
        printf -v nginx_modules 'OpenResty 内置 LuaJIT/lua-resty 模块'
        [ -n "${OpenResty_Modules_Options}" ] && \
            printf -v nginx_modules '%s；自定义选项：%s' \
                "${nginx_modules}" "${OpenResty_Modules_Options}"
        [ "${#OpenResty_Custom_Modules[@]}" -gt 0 ] && \
            printf -v nginx_modules '%s；自定义源码模块：%s 个' \
                "${nginx_modules}" "${#OpenResty_Custom_Modules[@]}"
    else
        Get_Nginx_Modules_Summary nginx_modules
    fi

    [ "${Enable_PHP_Fileinfo}" = "y" ] && php_modules='fileinfo'
    [ "${Enable_PHP_Exif}" = "y" ] && php_modules="${php_modules}${php_modules:+, }exif"
    [ "${Enable_PHP_Ldap}" = "y" ] && php_modules="${php_modules}${php_modules:+, }ldap"
    [ "${Enable_PHP_Bz2}" = "y" ] && php_modules="${php_modules}${php_modules:+, }bz2"
    [ "${Enable_PHP_Sodium}" = "y" ] && php_modules="${php_modules}${php_modules:+, }sodium"
    [ "${Enable_PHP_Imap}" = "y" ] && php_modules="${php_modules}${php_modules:+, }imap"
    [ "${Enable_PHP_Default_Opcache}" = "y" ] && php_modules="${php_modules}${php_modules:+, }opcache"
    [ "${Enable_PHP_Default_Igbinary}" = "y" ] && php_modules="${php_modules}${php_modules:+, }igbinary"
    [ "${Enable_PHP_Default_Redis}" = "y" ] && php_modules="${php_modules}${php_modules:+, }redis"
    [ "${Enable_PHP_Default_Imagick}" = "y" ] && php_modules="${php_modules}${php_modules:+, }imagick"
    [ -n "${PHP_Modules_Options}" ] && \
        printf -v php_modules '%s%s自定义选项：%s' "${php_modules}" \
            "${php_modules:+；}" "${PHP_Modules_Options}"
    [ -n "${php_modules}" ] || printf -v php_modules '无'

    echo "Nginx 附加模块：${nginx_modules}"
    echo "PHP 附加模块：${php_modules}"
    # 摘要中给出 lnmp.conf 里 Web 工具开关的最终取值，便于确认前复核。
    echo "Web 工具（lnmp.conf 开关）："
    echo "  phpMyAdmin：${Enable_PhpMyAdmin}"
    echo "  phpinfo 页面：${Enable_PHPInfo_Page}"
    echo "  Memcached 演示页：${Enable_Memcached_Test_Page}"
    echo "  Redis 演示页：${Enable_Redis_Test_Page}"
    # 是否安装数据库在组件列表处已经说过，这里只补数据库目录。
    if [ "${DB_Kind}" != "none" ]; then
        echo "数据库目录：${DB_Data_Dir}"
    fi
    echo "默认网站目录：${Default_Website_Dir}"
    ssh_ports=$(Get_Actual_SSH_Port | paste -sd ' ' -)
    echo "SSH 端口（防火墙将放行）：${ssh_ports:-未探测到，不处理}"
    if [ "${DB_Kind}" != "none" ]; then
        echo "数据库端口（防火墙将阻止公网访问）：${DB_Port} / ${DB_X_Port}"
    fi
}

# 单独安装 Nginx 的确认摘要：只列本入口实际读取的 lnmp.conf 项和将发生的系统变更。
Print_Nginx_Only_Summary()
{
    local nginx_modules='' ssh_ports

    Echo_Yellow "=========================================================================="
    Echo_Yellow "单独安装模式：只安装 Nginx，不安装数据库和 PHP。"
    echo "即将安装：${Nginx_Ver}"
    if [ "${Enable_Nginx_Openssl}" = "y" ]; then
        echo "OpenSSL：${Openssl_New_Ver}（随 Nginx 一起编译）"
    else
        echo "OpenSSL：使用系统自带版本"
    fi
    Get_Nginx_Modules_Summary nginx_modules
    echo "附加模块（lnmp.conf 开关）：${nginx_modules}"
    echo "默认网站目录：${Default_Website_Dir}"
    echo "完整性校验：${Enable_Download_Checksum}"
    ssh_ports=$(Get_Actual_SSH_Port | paste -sd ' ' -)
    echo "防火墙将放行：80、443；SSH 端口：${ssh_ports:-未探测到，不处理}"
    if [ -s /usr/local/nginx/sbin/nginx ]; then
        Echo_Yellow "本机已有 /usr/local/nginx/sbin/nginx，本次会重新编译并覆盖该二进制。"
        Check_Stack
        if [ "${Get_Stack}" = "unknow" ] && [ -s /usr/local/nginx/conf/nginx.conf ]; then
            Echo_Yellow "识别不出已装的栈，现有 /usr/local/nginx/conf/nginx.conf 会保留。"
        else
            Echo_Yellow "现有安装识别为 ${Get_Stack}，/usr/local/nginx/conf/nginx.conf 会被随包模板覆盖。"
        fi
        Echo_Yellow "vhost 配置、证书和网站目录不在本次改动范围内。"
    fi
    echo "本入口不读取 DB_Port、MySQL_Data_Dir、Enable_PhpMyAdmin 等选项。"
    Echo_Yellow "=========================================================================="
}

# 单独安装数据库的确认摘要，调用点在版本选择之后，此处版本和目录均已确定。
Print_DB_Only_Summary()
{
    local ssh_ports

    Echo_Yellow "=========================================================================="
    Echo_Yellow "单独安装模式：只安装数据库，不安装 Web 服务器和 PHP。"
    echo "即将安装：${DB_Ver}"
    if [ "${Bin}" = "y" ]; then
        echo "安装方式：官方通用二进制"
    else
        echo "安装方式：源码编译"
    fi
    echo "数据目录：${DB_Data_Dir}"
    echo "启用 InnoDB：${InstallInnodb}"
    echo "完整性校验：${Enable_Download_Checksum}"
    echo "数据库端口（防火墙将阻止公网访问）：${DB_Port} / ${DB_X_Port}"
    ssh_ports=$(Get_Actual_SSH_Port | paste -sd ' ' -)
    echo "防火墙将放行的 SSH 端口：${ssh_ports:-未探测到，不处理}"
    if [ "${DB_Root_Password_Random}" = "y" ]; then
        echo "数据库 root 口令：随机生成，安装结束只打印在终端，不写入日志。"
    else
        echo "数据库 root 口令：使用已输入的口令，不回显也不写入日志。"
    fi
    echo "本入口不读取 Default_Website_Dir、Enable_PhpMyAdmin 等选项。"
    Echo_Yellow "=========================================================================="
}

# 单独安装 Pure-FTPd 的确认摘要：端口在安装时一并写入服务配置和防火墙，
# 装完再改需要同时改两处，因此在动系统前先列出生效值。
Print_Pureftpd_Only_Summary()
{
    local ssh_ports cur_conf=/usr/local/pureftpd/etc/pure-ftpd.conf
    local cur_port='' cur_passive=''

    Echo_Yellow "=========================================================================="
    Echo_Yellow "单独安装模式：只安装 Pure-FTPd，不改动 Nginx、数据库和 PHP。"
    echo "即将安装：${Pureftpd_Ver}"
    echo "控制端口（写入 pure-ftpd.conf 的 Bind，防火墙将放行）：${Pureftpd_Port}"
    echo "数据端口（防火墙将放行）：${Pureftpd_Data_Port}"
    echo "被动端口范围（写入 PassivePortRange，防火墙将放行）：${Pureftpd_Passive_Min}-${Pureftpd_Passive_Max}"
    echo "完整性校验：${Enable_Download_Checksum}"
    ssh_ports=$(Get_Actual_SSH_Port | paste -sd ' ' -)
    echo "防火墙将放行的 SSH 端口：${ssh_ports:-未探测到，不处理}"
    Echo_Yellow "改端口：改 lnmp.conf 的 Pureftpd_Port / Pureftpd_Passive_Min / Pureftpd_Passive_Max"
    Echo_Yellow "后重跑，或用环境变量临时覆盖："
    Echo_Yellow "  Pureftpd_Port=2121 Pureftpd_Passive_Min=40000 Pureftpd_Passive_Max=40100 ./pureftpd.sh"
    Echo_Yellow "装后改端口：改 pure-ftpd.conf 并重启服务，再执行 lnmp fw sync"
    if [ -s /usr/local/pureftpd/sbin/pure-ftpd ]; then
        Echo_Yellow "本机已有 /usr/local/pureftpd/sbin/pure-ftpd，本次会重新编译并覆盖该二进制，"
        Echo_Yellow "/usr/local/pureftpd/etc/pure-ftpd.conf 会被随包模板覆盖（已有 FTP 用户数据保留）。"
        # 现有配置端口与本次将写入的值不同时单独点出，避免重跑把已调好的端口改回默认。
        if [ -s "${cur_conf}" ]; then
            cur_port=$(awk '$1 == "Bind" {sub(/^.*,/, "", $2); print $2; exit}' "${cur_conf}")
            cur_passive=$(awk '$1 == "PassivePortRange" {print $2 "-" $3; exit}' "${cur_conf}")
            if [ "${cur_port}" != "${Pureftpd_Port}" ] \
               || [ "${cur_passive}" != "${Pureftpd_Passive_Min}-${Pureftpd_Passive_Max}" ]; then
                Echo_Yellow "当前生效端口为控制 ${cur_port:-未知}、被动 ${cur_passive:-未知}，与上面将写入的值不同。"
            fi
        fi
    fi
    echo "本入口不读取 Default_Website_Dir、DB_Port 等选项。"
    Echo_Yellow "=========================================================================="
}

Print_Sys_Info()
{
    echo "LNMP 版本：${LNMP_Ver}"
    eval echo "${DISTRO} \${${DISTRO}_Version}"
    cat /etc/issue
    cat /etc/*-release
    uname -a
    MemTotal=$(awk '/MemTotal/ {printf( "%d\n", $2 / 1024 )}' /proc/meminfo)
    echo "内存：${MemTotal} MB"
    df -h
    Check_Openssl
}

StartUp()
{
    local init_name=$1
    echo "正在将 ${init_name} 服务设为开机启动..."
    if Use_Systemd_Unit "${init_name}"; then
        systemctl daemon-reload
        systemctl enable "${init_name}.service"
    else
        if [ "$PM" = "yum" ]; then
            chkconfig --add ${init_name}
            chkconfig ${init_name} on
        elif [ "$PM" = "apt" ]; then
            update-rc.d -f ${init_name} defaults
        fi
    fi
}

Remove_StartUp()
{
    local init_name=$1
    local unit="/etc/systemd/system/${init_name}.service"

    echo "正在取消 ${init_name} 服务的开机启动..."

    # 先通过 systemd 停止并重置服务，清除 SysV 兼容单元可能保留的过期状态。
    if Systemd_Is_Running; then
        systemctl stop "${init_name}.service" 2>/dev/null
        systemctl reset-failed "${init_name}.service" 2>/dev/null
    fi

    if Use_Systemd_Unit "${init_name}"; then
        systemctl disable "${init_name}.service"
    else
        if [ "$PM" = "yum" ]; then
            chkconfig ${init_name} off
            chkconfig --del ${init_name}
        elif [ "$PM" = "apt" ]; then
            update-rc.d -f ${init_name} remove
        fi
    fi

    # 删除由 LNMP 部署且 ExecStart 指向 LNMP 组件的单元，避免卸载后仍被识别
    # 为可用服务；发行版位于系统单元目录的同名服务不在删除范围内。
    local esc_name=${init_name//./\\.}
    if [ -f "${unit}" ] && grep -qE \
        "^ExecStart=[^[:space:]]*(/usr/local/|/etc/init\.d/${esc_name}([[:space:]]|$))" \
        "${unit}"; then
        rm -f "${unit}"
        systemctl daemon-reload 2>/dev/null
    fi
}

# 下载统一使用上游官方源，不依赖外部地理探测。
country='US'

# 编译前检查发行版下限。
# PHP 8.0+、MySQL 8.0+、OpenSSL 3.5 和 nginx 1.30 需要较新的编译器与系统库。
Check_Supported_Distro()
{
    local why=''

    if echo "${CentOS_Version}"      | grep -Eqi "^[1-7]\b"   ; then why="CentOS ${CentOS_Version}"
    elif echo "${RHEL_Version}"      | grep -Eqi "^[1-7]\b"   ; then why="RHEL ${RHEL_Version}"
    elif echo "${Oracle_Version}"    | grep -Eqi "^[1-7]\b"   ; then why="Oracle Linux ${Oracle_Version}"
    elif echo "${Rocky_Version}"     | grep -Eqi "^[1-7]\b"   ; then why="Rocky ${Rocky_Version}"
    elif echo "${Alma_Version}"      | grep -Eqi "^[1-7]\b"   ; then why="AlmaLinux ${Alma_Version}"
    elif echo "${Anolis_Version}"    | grep -Eqi "^[1-7]\b"   ; then why="Anolis ${Anolis_Version}"
    elif echo "${Debian_Version}"    | grep -Eqi "^[1-9]$"    ; then why="Debian ${Debian_Version}"
    elif echo "${Raspbian_Version}"  | grep -Eqi "^[1-9]$"    ; then why="Raspbian ${Raspbian_Version}"
    elif echo "${Ubuntu_Version}"    | grep -Eqi "^(1[0-7])\."; then why="Ubuntu ${Ubuntu_Version}"
    elif echo "${Mint_Version}"      | grep -Eqi "^(1[0-8])$" ; then why="Mint ${Mint_Version}"
    elif echo "${Fedora_Version}"    | grep -Eqi "^([12][0-9])$"; then why="Fedora ${Fedora_Version}"
    fi

    if [ -n "${why}" ]; then
        Echo_Red "不支持的系统版本：${why}"
        Echo_Red ""
        Echo_Red "本包的组件下限是 PHP 8.0+ / MySQL 8.0+ / OpenSSL 3.5 / nginx 1.30，"
        Echo_Red "这些在该版本的编译器和系统库上装不起来。"
        Echo_Red "支持范围：EL8 及以上、Debian 10+、Ubuntu 18.04+、Fedora 30+ 及同代系统。"
        Echo_Red ""
        Echo_Red "（此前没有这道检查，老系统会一路走到编译阶段才失败。）"
        exit 1
    fi
}

Check_CMPT()
{
    Check_Supported_Distro

    # MySQL 8.x 源码编译需要较新的发行版
    if [ "${DB_Kind}" = "mysql" ] && [ "${Bin}" != "y" ] && Version_GE "${DB_Branch}" 8.0; then
        if echo "${Ubuntu_Version}" | grep -Eqi "^1[0-7]\." || echo "${Debian_Version}" | grep -Eqi "^[4-8]" || echo "${Raspbian_Version}" | grep -Eqi "^[4-8]" || echo "${CentOS_Version}" | grep -Eqi "^[4-7]"  || echo "${RHEL_Version}" | grep -Eqi "^[4-7]" || echo "${Fedora_Version}" | grep -Eqi "^2[0-3]"; then
            Echo_Red "MySQL 8.* 需要较新的 Linux 发行版。"
            exit 1
        fi
    fi
    # PHP 7.4 及以上需要较新的发行版
    if Version_GE "${PHP_Branch}" 7.4; then
        if echo "${Ubuntu_Version}" | grep -Eqi "^1[0-7]\." || echo "${Debian_Version}" | grep -Eqi "^[4-8]" || echo "${Raspbian_Version}" | grep -Eqi "^[4-8]" || echo "${CentOS_Version}" | grep -Eqi "^[4-6]"  || echo "${RHEL_Version}" | grep -Eqi "^[4-6]" || echo "${Fedora_Version}" | grep -Eqi "^2[0-3]"; then
            Echo_Red "PHP 7.4 和 PHP 8.* 需要较新的 Linux 发行版。"
            exit 1
        fi
    fi
    # PHP 5.2 在过新的发行版上无法编译
    if [ "${PHP_Branch}" = "5.2" ]; then
        if echo "${Ubuntu_Version}" | grep -Eqi "^19|2[0-7]\." || echo "${Debian_Version}" | grep -Eqi "^1[0-9]" || echo "${Raspbian_Version}" | grep -Eqi "^1[0-9]" || echo "${Deepin_Version}" | grep -Eqi "^2[0-9]" || echo "${UOS_Version}" | grep -Eqi "^2[0-9]" || echo "${Fedora_Version}" | grep -Eqi "^29|3[0-9]"; then
            Echo_Red "PHP 5.2 不支持 Ubuntu 19+、Debian 10、Deepin 20+、Fedora 29+ 等较新的 Linux 发行版。"
            exit 1
        fi
    fi
}

# Version_GE <a> <b>：版本号 a 大于或等于 b 时返回 0，判断不依赖菜单编号。
Version_GE()
{
    [ -z "$1" ] && return 1
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# Check_Version_String <值> [组件名]
# 升级入口只接受三段或四段数字版本，防止版本值改变下载与解压路径。
Check_Version_String()
{
    local value="$1" label="$2"
    [ -n "${label}" ] || printf -v label '版本号'

    if [[ ! "${value}" =~ ^[0-9]+(\.[0-9]+){2,3}$ ]]; then
        Echo_Red "${label}格式无效：'${value}'（只接受三段或四段数字版本）"
        return 1
    fi
    return 0
}


Version_Compare()
{
    if [ "$1" = "$2" ]; then
        echo 0
    elif [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; then
        echo 1
    else
        echo 2
    fi
}

Check_Server_Admin_Email()
{
    local value="$1"
    if [[ ! "${value}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]; then
        Echo_Red "管理员邮箱格式无效：'${value}'"
        return 1
    fi
    return 0
}

Color_Text()
{
  echo -e " \e[0;$2m$1\e[0m"
}

Echo_Red()
{
  echo "$(Color_Text "$1" "31")"
}

Echo_Green()
{
  echo "$(Color_Text "$1" "32")"
}

Echo_Yellow()
{
  echo "$(Color_Text "$1" "33")"
}

Echo_Blue()
{
  echo "$(Color_Text "$1" "34")"
}

Get_PHP_Ext_Dir()
{
    Cur_PHP_Version="`/usr/local/php/bin/php-config --version`"
    zend_ext_dir="`/usr/local/php/bin/php-config --extension-dir`/"
}

Check_Stack()
{
    if [[ -s /usr/local/php/sbin/php-fpm && -s /usr/local/php/etc/php-fpm.conf && -s /etc/init.d/php-fpm && -s /usr/local/nginx/sbin/nginx ]]; then
        Get_Stack="lnmp"
    elif [[ -s /usr/local/nginx/sbin/nginx && -s /usr/local/apache/bin/httpd && -s /usr/local/apache/conf/httpd.conf && -s /etc/init.d/httpd && ! -s /usr/local/php/sbin/php-fpm ]]; then
        Get_Stack="lnmpa"
    elif [[ -s /usr/local/apache/bin/httpd && -s /usr/local/apache/conf/httpd.conf && -s /etc/init.d/httpd && ! -s /usr/local/php/sbin/php-fpm ]]; then
        Get_Stack="lamp"
    else
        Get_Stack="unknow"
    fi
}

# First_Executable <候选路径...>：返回第一个可执行文件。
# MariaDB 11.x 已把 mysql、mysqldump 等旧程序名标记为弃用，但不同版本和
# 安装形态提供的新旧名称不完全相同，因此优先使用新名称，缺失时回退旧名称。
First_Executable()
{
    local candidate

    for candidate in "$@"; do
        if [ -x "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

Check_DB()
{
    local mariadb_client mariadb_config mariadb_safe

    if mariadb_client=$(First_Executable /usr/local/mariadb/bin/mariadb /usr/local/mariadb/bin/mysql) \
        && mariadb_config=$(First_Executable /usr/local/mariadb/bin/mariadb_config /usr/local/mariadb/bin/mysql_config) \
        && mariadb_safe=$(First_Executable /usr/local/mariadb/bin/mariadbd-safe /usr/local/mariadb/bin/mysqld_safe) \
        && [ -s /etc/my.cnf ]; then
        MySQL_Bin="${mariadb_client}"
        MySQL_Config="${mariadb_config}"
        MySQL_Dir="/usr/local/mariadb"
        Is_MySQL="n"
        DB_Name="mariadb"
    elif [[ -s /usr/local/mysql/bin/mysql && -s /usr/local/mysql/bin/mysqld_safe && -s /etc/my.cnf ]]; then
        MySQL_Bin="/usr/local/mysql/bin/mysql"
        MySQL_Config="/usr/local/mysql/bin/mysql_config"
        MySQL_Dir="/usr/local/mysql"
        Is_MySQL="y"
        DB_Name="mysql"
    else
        Is_MySQL="None"
        DB_Name="None"
    fi
}

# SQL 使用权限受限的随机临时文件，避免共享目录中的文件名预测和符号链接覆盖。
Do_Query()
{
    local sql_file rc
    sql_file=$(mktemp /tmp/.lnmp-sql.XXXXXXXX) || return 1
    chmod 600 "${sql_file}"
    printf '%s\n' "$1" > "${sql_file}"
    Check_DB
    ${MySQL_Bin} --defaults-file="${HOME}/.my.cnf" < "${sql_file}"
    rc=$?
    rm -f "${sql_file}"
    return ${rc}
}

# SQL_Escape <字符串>
#
# 转义单引号字符串字面量中的反斜杠和单引号。
# MySQL 的 SQL 字面量与选项文件的引号内取值使用同一套转义规则，两处通用。
# 未转义时，含这两个字符的密码会截断语句，导致设置的密码与输入不一致。
SQL_Escape()
{
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"
}

# 写临时的 ~/.my.cnf 供后续命令免密登录。
#
# 写入临时客户端配置前备份现有 ~/.my.cnf，清理时恢复。
Make_TempMycnf()
{
    if [ -s ~/.my.cnf ] && [ ! -e ~/.my.cnf.lnmp-bak ]; then
        cp -p ~/.my.cnf ~/.my.cnf.lnmp-bak
    fi
    ( umask 077; cat >~/.my.cnf<<EOF
[client]
user=root
password='$(SQL_Escape "$1")'
socket=$(Get_Actual_DB_Socket)
EOF
    )
    chmod 600 ~/.my.cnf
}

Verify_DB_Password()
{
    Check_DB
    status=1
    while [ $status -eq 1 ]; do
        read -s -p "请输入当前数据库 root 密码（输入不回显）: " DB_Root_Password
        Make_TempMycnf "${DB_Root_Password}"
        Do_Query ""
        status=$?
    done
    echo "数据库 root 密码验证通过。"
}

TempMycnf_Clean()
{
    rm -f ~/.my.cnf
    # 存在备份时恢复原客户端配置。
    if [ -e ~/.my.cnf.lnmp-bak ]; then
        mv -f ~/.my.cnf.lnmp-bak ~/.my.cnf
    fi
    # 清理旧版本使用的固定临时文件。
    rm -f /tmp/.mysql.tmp
}

# 通过 /run/systemd/system 判断 systemd 是否实际运行，适用于服务器和 WSL。
Systemd_Is_Running()
{
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

Systemd_Unit_Exists()
{
    local service=$1 dir template

    for dir in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
        [ -s "${dir}/${service}.service" ] && return 0
    done
    # 模板实例（如 php-fpm@8.3）没有独立 unit 文件，改判其模板是否存在。
    case "${service}" in
    *@*)
        template="${service%@*}@"
        for dir in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
            [ -s "${dir}/${template}.service" ] && return 0
        done
        ;;
    esac
    return 1
}

# 统一选择 systemd 或 init 脚本，保证服务启动与状态检查使用同一管理方式。
Use_Systemd_Unit()
{
    local service=$1
    Systemd_Is_Running && Systemd_Unit_Exists "${service}"
}

StartOrStop()
{
    local action=$1
    local service=$2
    if Use_Systemd_Unit "${service}"; then
        systemctl ${action} ${service}.service
    else
        /etc/init.d/${service} ${action}
    fi
}

# Ensure_Runtime_Directory <目录> <用户> <组>
# /run 会在重启后清空，服务启动前必须安全地重建专属目录。
Ensure_Runtime_Directory()
{
    local dir="$1" owner="$2" group="$3"

    if [ -L "${dir}" ] || { [ -e "${dir}" ] && [ ! -d "${dir}" ]; }; then
        Echo_Red "运行目录不是安全的实体目录：${dir}"
        return 1
    fi
    install -d -o "${owner}" -g "${group}" -m 0755 "${dir}" || return 1
    [ ! -L "${dir}" ] && [ -d "${dir}" ]
}

# Patch_Init_Runtime_Directory <init脚本> <目录> <用户> <组>
# SysV 和 systemd 生成的兼容服务都可能直接执行 init 脚本，因此把重建逻辑
# 写进入口；固定标记保证升级或回滚时重复调用不会重复插入。
# 升级前的搬迁必须整体成功：逐项检查存在性、目标未占用和 mv 返回码，
# 记录已完成项以便失败时按逆序还原。任何路径都不删除数据。
LNMP_Moved_Items=()

Move_For_Upgrade()
{
    local src="$1" dst="$2"

    if [ ! -e "${src}" ]; then
        Echo_Red "待搬迁的路径不存在：${src}"
        return 1
    fi
    if [ -e "${dst}" ]; then
        Echo_Red "搬迁目标已存在，拒绝覆盖：${dst}"
        return 1
    fi
    if ! mv -- "${src}" "${dst}"; then
        Echo_Red "搬迁失败：${src} -> ${dst}"
        Echo_Red "数据目录是独立挂载点或只读文件系统时会出现该错误，原数据未被改动。"
        return 1
    fi
    if [ -e "${src}" ] || [ ! -e "${dst}" ]; then
        Echo_Red "搬迁后状态异常：${src} -> ${dst}"
        return 1
    fi
    LNMP_Moved_Items+=("${dst}|${src}")
    return 0
}

# 按逆序把已搬迁的项目放回原位；还原失败时打印确切路径，供人工处理。
Rollback_Upgrade_Moves()
{
    local i entry dst src rc=0

    for (( i=${#LNMP_Moved_Items[@]} - 1; i >= 0; i-- )); do
        entry="${LNMP_Moved_Items[i]}"
        dst="${entry%%|*}"
        src="${entry#*|}"
        if mv -- "${dst}" "${src}"; then
            echo "已还原：${dst} -> ${src}"
        else
            Echo_Red "还原失败，请手工处理：${dst} -> ${src}"
            rc=1
        fi
    done
    LNMP_Moved_Items=()
    return ${rc}
}

# 搬迁失败的统一出口：还原已搬项目，说明数据未被删除，然后退出。
Abort_Upgrade_Move()
{
    Echo_Red "升级前的搬迁未全部成功，已停止升级。"
    Rollback_Upgrade_Moves
    Echo_Yellow "原数据库数据未被删除；确认上述路径后可执行 lnmp start 恢复服务。"
    exit 1
}

# 数据库进程必须真正退出后才能搬迁数据目录。
Ensure_DB_Stopped()
{
    local pattern="$1" i

    command -v pgrep >/dev/null 2>&1 || return 0
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "${pattern}" >/dev/null 2>&1 || return 0
        sleep 2
    done
    Echo_Red "数据库进程仍在运行（${pattern}），未搬迁任何文件，升级中止。"
    return 1
}

# 新实例只初始化到空目录：目录非空一律拒绝，绝不清空既有数据目录。
Require_Empty_Data_Dir()
{
    local dir="$1"

    if [ ! -e "${dir}" ]; then
        mkdir -p -- "${dir}" || { Echo_Red "无法创建数据目录：${dir}"; return 1; }
        return 0
    fi
    if [ ! -d "${dir}" ]; then
        Echo_Red "数据目录路径存在但不是目录：${dir}"
        return 1
    fi
    if [ -n "$(ls -A -- "${dir}" 2>/dev/null)" ]; then
        Echo_Red "数据目录非空：${dir}"
        Echo_Red "升级不会清空既有数据目录。请确认其中内容后自行处理，再重新执行升级。"
        return 1
    fi
    return 0
}

Patch_Init_Runtime_Directory()
{
    local initd="$1" dir="$2" owner="$3" group="$4" tmp

    [ -f "${initd}" ] || return 1
    grep -q '^# LNMP runtime directory$' "${initd}" && return 0
    tmp=$(mktemp "${initd}.lnmp.XXXXXX") || return 1
    if ! {
        IFS= read -r first || exit 1
        printf '%s\n' "${first}"
        printf '%s\n' \
            '# LNMP runtime directory' \
            "if [ -L '${dir}' ] || { [ -e '${dir}' ] && [ ! -d '${dir}' ]; }; then" \
            "    echo 'Unsafe runtime directory: ${dir}' >&2" \
            '    exit 1' \
            'fi' \
            "install -d -o '${owner}' -g '${group}' -m 0755 '${dir}' || exit 1"
        cat
    } < "${initd}" > "${tmp}" ||
       ! chmod --reference="${initd}" "${tmp}" ||
       ! chown --reference="${initd}" "${tmp}" ||
       ! mv -f "${tmp}" "${initd}"; then
        rm -f "${tmp}"
        return 1
    fi
    return 0
}

Check_Openssl()
{
    if ! command -v openssl >/dev/null 2>&1; then
        Echo_Blue "[+] 正在安装 OpenSSL..."
        if [ "${PM}" = "yum" ]; then
            yum install -y openssl
        elif [ "${PM}" = "apt" ]; then
            Apt_Get update -y
            [[ $? -ne 0 ]] && Apt_Get update --allow-releaseinfo-change -y
            Apt_Get install -y openssl
        fi
    fi
    openssl version
    if openssl version | grep -Eqi "OpenSSL 3.*"; then
        isOpenSSL3='y'
    fi
}
# 计算横幅文本的终端显示宽度：ASCII 占 1 列，中日韩字符占 2 列。
Text_Display_Width()
{
    local text="$1" bytes ascii_bytes wide_chars
    bytes=$(printf '%s' "${text}" | LC_ALL=C wc -c)
    ascii_bytes=$(printf '%s' "${text}" | LC_ALL=C tr -cd '\000-\177' | wc -c)
    wide_chars=$(( (bytes - ascii_bytes) / 3 ))
    printf '%d' $((ascii_bytes + wide_chars * 2))
}

# 写入演示页后检查默认站点是否允许访问。
# default 站点默认拒绝执行 PHP。新装环境的配置模板已按固定文件名放行
# phpinfo、redis 和 memcached 演示页；旧配置可能返回 404。检查仅提示，
# 不修改用户已定制的站点配置，也不影响安装结果。
Warn_Demo_Page_Not_Served()
{
    local page="$1"
    # Nginx 与 Apache 模板均包含固定文件名分支，可使用同一字符串检查。
    local pattern='(phpinfo|redis|memcached)'
    local ngx_default='/usr/local/nginx/conf/vhost/default.conf'
    local apache_vhosts='/usr/local/apache/conf/extra/httpd-vhosts.conf'
    local missing='' conf

    if [ -s "${ngx_default}" ] && ! grep -qF "${pattern}" "${ngx_default}"; then
        missing="${missing} ${ngx_default}"
    fi
    if [ -s "${apache_vhosts}" ] && ! grep -qF "${pattern}" "${apache_vhosts}"; then
        missing="${missing} ${apache_vhosts}"
    fi
    [ -z "${missing}" ] && return 0

    Echo_Yellow " ${page} 已写入 ${Default_Website_Dir}，但以下配置未放行该文件："
    for conf in ${missing}; do
        echo "   ${conf}"
    done
    echo " default 站点默认拒绝执行 PHP，现在访问该页面会返回 404。"
    echo " 需要时参照 conf/lnmp 中 default 站点的写法补上放行规则，再重载 Web 服务。"
    return 0
}

Print_Banner()
{
    local width=72 border text text_width padding left right
    for text in "$@"; do
        text_width=$(Text_Display_Width "${text}")
        [ "${text_width}" -gt "${width}" ] && width=${text_width}
    done
    border=$(printf '%*s' "${width}" '' | tr ' ' '-')
    printf '+%s+\n' "${border}"
    for text in "$@"; do
        text_width=$(Text_Display_Width "${text}")
        padding=$((width - text_width))
        left=$((padding / 2))
        right=$((padding - left))
        printf '|%*s%s%*s|\n' "${left}" '' "${text}" "${right}" ''
    done
    printf '+%s+\n' "${border}"
}
