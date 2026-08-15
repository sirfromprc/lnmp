#!/usr/bin/env bash

# DB_Info / PHP_Info / Apache_Info 已移至 include/profile.sh，
# 与编号映射表放在一起，避免菜单文本和版本表分居两地而脱节。

# phpMyAdmin 装在网站根目录之外。放在根目录下时，Web 服务器配置一旦失效
# （改错、被覆盖、模块未加载），整套源码连同 config.inc.php 就会被当作
# 静态文件下载。访问入口由 Web 服务器映射，见 Config_PhpMyAdmin_Access。
PhpMyAdmin_Dir='/usr/local/phpmyadmin'

# 记录随机访问路径，供安装结束提示与 lnmp status 读取。
PhpMyAdmin_Url_File="${PhpMyAdmin_Dir}/.access_url"

# Check_DB_Source_Build — 源码编译数据库前的可行性把关
#
# 本包的典型用户是 1-2GB 内存的小 VPS，而 MySQL 8.x 源码编译对内存和磁盘都不
# 便宜：Debian 12 / 8 核 6GB 实测，编译目录涨到约 7.8GB，`make -j8` 还在
# sql_gis 处被 OOM 杀掉过（cc1plus 单进程 anon-rss 787MB）。这种机器上选源码
# 编译，结果不是跑几个小时就是中途失败，而官方通用二进制几分钟装完、功能一样。
#
# 分三档处理：
#   低于硬下限（profile 的 DB_Min_Mem_MB 与 2048MB 取大者，或磁盘不足）
#       直接拒绝，并指明改用通用二进制；
#   够用但低于推荐值，说明代价，交互式必须显式确认；
#   非交互（无终端或 LNMP_Auto=y）打印警告后继续，不破坏已有自动化。
Check_DB_Source_Build()
{
    local mem_mb disk_mb min_mem rec_mem=4096 min_disk=15360 ans jobs

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
#which MySQL Version do you want to install?
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
        #set mysql root password
        #
        # 密码输入不回显，且不得写入安装日志。
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

        #do you want to enable or disable the InnoDB Storage Engine?
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
        *)
            echo "输入无效，按默认设置启用 InnoDB 存储引擎。"
            InstallInnodb="y"
        esac
    fi
}

PHP_Selection()
{
#which PHP Version do you want to install?
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
#which Memory Allocator do you want to install?
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

# ---------------------------------------------------------------------------
# Web_Selection — 选 nginx 还是 OpenResty（互斥）。
#
# 产出：
#   WebServer               nginx | openresty
#   OpenResty_Install_Mode  pkg | source（仅 WebServer=openresty 时有意义）
#
# 非交互用法：
#   WebSelect=1                          装 nginx（默认，行为与改动前完全一致）
#   WebSelect=2 ORMode=1                 装 OpenResty，官方仓库预编译包
#   WebSelect=2 ORMode=2                 装 OpenResty，源码编译
#
# 仅 lnmp 和 lnmpa 需要此选项；lamp 不安装 nginx。
# ---------------------------------------------------------------------------
Web_Selection()
{
    WebServer='nginx'
    OpenResty_Install_Mode=''

    # lamp 不含 nginx，直接跳过
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
        echo "将安装 OpenResty。"
        ;;
    *)
        WebServer='nginx'
        [ -z "${WebSelect}" ] && echo "未输入选项，使用默认项 Nginx。" \
                              || echo "已选择安装 Nginx。"
        # 互斥是双向的：机器上已经有 OpenResty 时也不能再装 nginx
        Check_WebServer_Conflict nginx || exit 1
        return 0
        ;;
    esac

    # 选了 OpenResty 才问装法
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
        echo "将从源码编译安装 OpenResty ${OpenResty_Ver#openresty-}。"
        ;;
    *)
        OpenResty_Install_Mode='pkg'
        echo "将从官方软件仓库安装 OpenResty。"
        ;;
    esac

    # 互斥的第一道闸：菜单阶段就拦住，别等编译完一堆东西才发现装不了
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
    #set Server Administrator Email Address
    if [ -z ${ServerAdmin} ]; then
        ServerAdmin=""
        read -p "请输入服务器管理员邮箱（默认 webmaster@example.com）: " ServerAdmin
    fi
    if [ "${ServerAdmin}" == "" ]; then
        echo "未输入，服务器管理员邮箱将设为 webmaster@example.com。"
        ServerAdmin="webmaster@example.com"
    else
        echo "==========================="
        echo "服务器管理员邮箱：${ServerAdmin}"
        echo "==========================="
    fi
    echo "==========================="

    # Apache 仅支持 2.4；保留 ApacheSelect 以兼容命令行参数。
    [ -z "${ApacheSelect}" ] && ApacheSelect="${Apache_Default}"
    Set_Apache_Profile "${ApacheSelect}" || Invalid_Selection Apache "${ApacheSelect}"
    echo "将安装 ${Apache_Info[$((ApacheSelect-1))]}。"
}

# ---------------------------------------------------------------------------
# Wait_PM：在限定时间内等待包管理器锁释放。
# 不终止包管理器进程，也不删除活动锁文件，避免破坏 dpkg/rpm 数据库。
# Kill_PM 保留为兼容别名。
# ---------------------------------------------------------------------------
PM_Lock_Wait_Sec=300

PM_Lock_Busy()
{
    # fuser 直接检查锁文件是否由进程持有。
    local f
    if [ "${PM}" = "yum" ]; then
        for f in /var/run/yum.pid /var/lib/rpm/.rpm.lock; do
            [ -e "${f}" ] || continue
            fuser "${f}" >/dev/null 2>&1 && return 0
        done
        # 老版本 yum 只留 pid 文件不加锁，退化为检查该 pid 是否还活着
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

# 兼容旧调用点
Kill_PM()
{
    Wait_PM
}

Press_Install()
{
    . include/version.sh
    Set_Profiles

    case "${Stack}" in
    lnmp|lnmpa|lamp)
        # 完整安装：选择做完之后，把版本、端口这些会真正影响系统的信息摆
        # 出来，用户看完再决定是否继续——原来的"press any key"敲任意键都
        # 能过，等于没有确认。
        Echo_Yellow "=========================================================================="
        Echo_Yellow "您即将安装/编译以下模块，请确认！" 
        Print_APP_Ver
        Confirm_Start_Install || exit 1
        ;;
    *)
        if [ -z ${LNMP_Auto} ]; then
            echo ""
            Echo_Green "按任意键开始安装，或按 Ctrl+C 取消。"
            OLDCONFIG=`stty -g`
            stty -icanon -echo min 1 time 0
            dd count=1 2>/dev/null
            stty ${OLDCONFIG}
        fi
        ;;
    esac

    Kill_PM
}

# lnmp/lnmpa/lamp 完整安装在真正开始装依赖、编译前的最后一道确认。
# 非交互（无终端或 LNMP_Auto=y）不阻断，打印提示后直接继续。
Confirm_Start_Install()
{
    local ans

    if [ ! -t 0 ] || [ "${LNMP_Auto}" = "y" ]; then
        Echo_Yellow "当前为非交互执行，按以上信息直接开始安装。"
        return 0
    fi

    echo ""
    read -r -p "确认以上信息，开始安装请输入 y，其它输入一律取消： " ans
    case "${ans}" in
        [yY]) return 0 ;;
        *)
            Echo_Yellow "已取消安装。"
            return 1
            ;;
    esac
}

# 菜单选择完成后，把编号翻译成语义变量。必须在 version.sh 之后调用，
# 因为二者共同构成完整的版本信息（version.sh 提供与选择无关的组件版本，
# profile.sh 提供随选择变化的部分）。
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

# 非法编号必须显式报错，禁止静默回退到默认版本。
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

Press_Start()
{
    echo ""
    Echo_Green "按任意键开始，或按 Ctrl+C 取消。"
    OLDCONFIG=`stty -g`
    stty -icanon -echo min 1 time 0
    dd count=1 2>/dev/null
    stty ${OLDCONFIG}
}

Install_LSB()
{
    echo "[+] 正在安装 lsb..."
    if [ "$PM" = "yum" ]; then
        yum -y install redhat-lsb
    elif [ "$PM" = "apt" ]; then
        apt-get update
        apt-get --no-install-recommends install -y lsb-release
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

# Verify_Download_File <文件名>：SHA256 完整性校验。
# 清单缺失、条目缺失或哈希不匹配时终止安装。
# 组件版本变更必须同步更新 src/checksums.sha256。
Verify_Download_File()
{
    local FileName=$1
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
        Echo_Red "致命错误：${FileName} 的 SHA256 不匹配。"
        Echo_Red "  期望值：${Expected_SHA256}"
        Echo_Red "  实际值：${Actual_SHA256}"
        Echo_Red "该文件已删除；下载内容可能被篡改。"
        rm -f "${FileName}"
        exit 1
    fi
    Echo_Green "${FileName} 的 SHA256 校验通过。"
    return 0
}

# ---------------------------------------------------------------------------
# Require_File <文件名> <描述>
#
# 下载后的存在性检查，防止下载失败后继续编译。
# 所有入口脚本均加载 main.sh，因此该函数在此统一定义。
# ---------------------------------------------------------------------------
Require_File()
{
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

    [ "${FileName}" = "" ] && FileName="${URL##*/}"

    if [ -s "${FileName}" ]; then
        echo "${FileName} [已存在]"
        Verify_Download_File "${FileName}"
        return $?
    fi

    echo "提示：未找到 ${FileName}，现在开始下载..."
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

# Tar_Cd <包名> [解压后的目录名]
#
# 目录切换、解压和目标目录检查任一步失败时立即终止。
# ---------------------------------------------------------------------------
# Check_Conf_Applied <文件> <期望匹配的正则> <说明>
#
# 端口这类值是"模板里有默认值 + 安装时按 lnmp.conf 覆写"的模式。
# 如果上游模板换了写法，sed 会一条都匹配不上却仍然返回 0：
# 服务用模板里的默认端口跑起来，防火墙按 lnmp.conf 的端口放行，
# 两边对不上，而且全程没有任何报错。这里在覆写后确认一次。
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Get_Actual_DB_Port [配置文件]
#
# 输出本机数据库实际监听的端口，取不到时退回 lnmp.conf 的 DB_Port。
# 返回 0 表示取自配置文件，返回 1 表示用的是退回值。
# 参数只为定向测试传入替身配置，实际调用一律用默认的 /etc/my.cnf。
#
# lnmp.conf 里写的是 DB_Port="${DB_Port:-3306}"：装主栈时可以用环境变量
# 指定非默认端口（DB_Port=3307 ./install.sh lnmp），该值进了 /etc/my.cnf，
# 但不会回写 lnmp.conf。事后单独补装或升级 phpMyAdmin 时环境变量早已不在，
# 读到的仍是 3306，写进 config.inc.php 就是错的 —— 而 config.inc.php 用
# host = 127.0.0.1 走 TCP（不用 localhost，见该文件注释），端口错了直接连不上库。
#
# 只认 [mysqld] 段里的 port：[client] 段那条是客户端默认值，管理员可能单独改过。
# MySQL 与 MariaDB 的模板都写在 /etc/my.cnf，两者取法相同。
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Get_Actual_SSH_Port — 探测系统当前实际监听的 SSH 端口
#
# 不能只信 lnmp.conf 里的 SSH_Port：sshd_config 改了没重启、或者用
# ExecStart 的 -o Port= 覆盖过，配置文件里的值和真实监听端口会对不上。
# 优先看真实监听的 socket（ss/netstat 能看到内核当前的状态），
# 两者都不可用时才退回解析 sshd_config（含 Debian/Ubuntu 默认
# Include 的 /etc/ssh/sshd_config.d/*.conf）；配置文件存在但没有
# 显式 Port 行，按 OpenSSH 的默认值处理，即 22。
#
# 输出：每行一个端口号，按数字升序去重。彻底探测不到（没有 ss/netstat，
# 也找不到 sshd_config）时不输出、返回 1，交调用方决定怎么处理。
# ---------------------------------------------------------------------------
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
# 解析 sshd_config 里的 Port 指令，跟随 Debian/Ubuntu 默认的
# `Include /etc/ssh/sshd_config.d/*.conf`（取主配置所在目录下的
# sshd_config.d/*.conf）。只覆盖这一种固定的 Include 布局，不做通用
# Include 解析——本包主线是 Debian 12。
# 参数只为定向测试传入替身配置，实际调用一律用默认的 /etc/ssh/sshd_config。
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
    local names=(SSH_Port DB_Port DB_X_Port Redis_Port Memcached_Port
                 Pureftpd_Port Pureftpd_Data_Port)
    local values=("${SSH_Port}" "${DB_Port}" "${DB_X_Port}" "${Redis_Port}"
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

# ---------------------------------------------------------------------------
# Confirm_LNMPConf_Reviewed — 正式开始选择版本前提醒检查 lnmp.conf
#
# 典型事故：SSH 端口已经在系统里改过、但 lnmp.conf 的 SSH_Port 还是默认值，
# 装完防火墙只放行旧端口，等于把当前的登录方式关在门外；数据库目录、
# 网站目录、是否开 phpMyAdmin 同理，装完再改往往比装之前改麻烦得多。
#
# 非交互（无终端或 LNMP_Auto=y）打印提示后继续，不阻断已有自动化。
# ---------------------------------------------------------------------------
Confirm_LNMPConf_Reviewed()
{
    local ans

    Echo_Yellow "=========================================================================="
    Echo_Yellow "开始安装前，请根据实际需求检查并确认 ${cur_dir}/lnmp.conf 中的配置："
    Echo_Yellow "  - SSH_Port 等端口是否与系统实际配置一致；已经改过 SSH 端口的话，这里必须"
    Echo_Yellow "    跟着改，否则装完防火墙会把当前的 SSH 连接方式关在门外。"
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

Print_APP_Ver()
{
    local nginx_modules='' php_modules=''

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
    echo "启用 InnoDB：${InstallInnodb}"
    echo "lnmp.conf 配置信息："
    echo "下载来源：仅限上游官方来源"
    echo "完整性校验：${Enable_Download_Checksum}"

    if [ "${Stack}" = "lamp" ]; then
        nginx_modules='未安装'
    elif [ "${WebServer}" = "openresty" ]; then
        nginx_modules='OpenResty 内置 LuaJIT/lua-resty 模块'
        [ -n "${OpenResty_Modules_Options}" ] && \
            nginx_modules="${nginx_modules}；自定义选项：${OpenResty_Modules_Options}"
        [ "${#OpenResty_Custom_Modules[@]}" -gt 0 ] && \
            nginx_modules="${nginx_modules}；自定义源码模块：${#OpenResty_Custom_Modules[@]} 个"
    else
        [ "${Enable_Nginx_Lua}" = "y" ] && nginx_modules='Lua'
        if [ "${Enable_Ngx_Brotli}" = "y" ]; then
            nginx_modules="${nginx_modules}${nginx_modules:+, }Brotli"
        fi
        if [ "${Enable_Ngx_CachePurge}" = "y" ]; then
            nginx_modules="${nginx_modules}${nginx_modules:+, }Cache Purge"
        fi
        if [ "${Enable_Ngx_FancyIndex}" = "y" ]; then
            nginx_modules="${nginx_modules}${nginx_modules:+, }FancyIndex"
        fi
        [ -n "${Nginx_Modules_Options}" ] && \
            nginx_modules="${nginx_modules}${nginx_modules:+；}自定义选项：${Nginx_Modules_Options}"
        [ -n "${nginx_modules}" ] || nginx_modules='无'
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
        php_modules="${php_modules}${php_modules:+；}自定义选项：${PHP_Modules_Options}"
    [ -n "${php_modules}" ] || php_modules='无'

    echo "Nginx 附加模块：${nginx_modules}"
    echo "PHP 附加模块：${php_modules}"
    if [ "${DB_Kind}" = "none" ]; then
        echo "不安装 MySQL/MariaDB。"
    else
        echo "数据库目录：${DB_Data_Dir}"
    fi
    echo "默认网站目录：${Default_Website_Dir}"
    echo "SSH 端口（防火墙将放行）：${SSH_Port}"
    if [ "${DB_Kind}" != "none" ]; then
        echo "数据库端口（防火墙将阻止公网访问）：${DB_Port} / ${DB_X_Port}"
    fi
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

    # 先按 systemd 停一次，且不看 unit 是不是本包部署的。
    # 只装 init 脚本时（例如 OpenResty 只写 /etc/init.d/nginx），systemd 会用
    # sysv-generator 生成一个 unit，开机启动后状态是 active (exited)。
    # 用 lnmp stop 或 init 脚本停服务，systemd 并不知道，该状态会一直留着；
    # 卸载删掉文件也不清除它。重装写入新 unit 并 daemon-reload 同样不会重置
    # 已有的 active 状态，于是随后的 systemctl start 认为服务已在运行、直接
    # 返回成功，服务实际从未被启动，而 lnmp status 显示的是上一次的 active。
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

    # 本包部署的 unit 必须随之删除。只 disable 会把 ExecStart 指向已删除二进制的
    # unit 留在系统里，后续 Service_Exists 仍判定该服务存在，管理脚本的整体启停
    # 会去启动一个根本不存在的服务并报错。
    # 判定"本包部署"看 ExecStart：nginx/php-fpm/httpd/pureftpd/redis 指向
    # /usr/local/ 下的二进制，mysql/mariadb/memcached 的 unit 则包装
    # /etc/init.d/<服务名>。发行版自带的同名 unit 在 /lib/systemd/system，
    # 不在这里，不会被误删。
    local esc_name=${init_name//./\\.}
    if [ -f "${unit}" ] && grep -qE \
        "^ExecStart=[^[:space:]]*(/usr/local/|/etc/init\.d/${esc_name}([[:space:]]|$))" \
        "${unit}"; then
        rm -f "${unit}"
        systemctl daemon-reload 2>/dev/null
    fi
}

# 下载路径不再依据外部地理探测结果切换，统一使用上游官方源。
country='US'

# ---------------------------------------------------------------------------
# Check_Supported_Distro：在编译前检查发行版下限。
# PHP 8.0+、MySQL 8.0+、OpenSSL 3.5 和 nginx 1.30 需要较新的编译器与系统库。
# ---------------------------------------------------------------------------
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

# Version_GE <a> <b> — 版本号 a >= b 时返回 0
# 替代按菜单编号划定版本区间的写法，编号变化不再影响这类判断。
Version_GE()
{
    [ -z "$1" ] && return 1
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
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

Color_Text()
{
  echo -e " \e[0;$2m$1\e[0m"
}

Echo_Red()
{
  echo $(Color_Text "$1" "31")
}

Echo_Green()
{
  echo $(Color_Text "$1" "32")
}

Echo_Yellow()
{
  echo $(Color_Text "$1" "33")
}

Echo_Blue()
{
  echo $(Color_Text "$1" "34")
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

# First_Executable <候选路径...> — 返回第一个可执行文件。
#
# MariaDB 11.x 已把 mysql、mysqldump 等旧程序名标记为弃用，但不同版本和
# 安装形态提供的新旧名称不完全相同。调用点统一按文件能力优先新名称，
# 缺失时回退旧名称，不按版本号猜测实际包布局。
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

# SQL 走临时文件而不是固定的 /tmp/.mysql.tmp。
#
# mktemp 配合 umask 077，避免共享临时目录中的文件名预测和符号链接覆盖。
Do_Query()
{
    local sql_file rc
    sql_file=$(mktemp /tmp/.lnmp-sql.XXXXXXXX) || return 1
    chmod 600 "${sql_file}"
    printf '%s\n' "$1" > "${sql_file}"
    Check_DB
    ${MySQL_Bin} --defaults-file=~/.my.cnf < "${sql_file}"
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

# 只按实际运行能力判断 systemd，不再把 WSL 等开发环境名称当作能力。
# WSL 可以启用 systemd，普通服务器也可能没有运行 systemd；检查环境名字会
# 同时产生误判和漏判。/run/systemd/system 是 systemd 启动后创建的运行标志。
Systemd_Is_Running()
{
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

Systemd_Unit_Exists()
{
    local service=$1
    [ -s "/etc/systemd/system/${service}.service" ] || \
    [ -s "/lib/systemd/system/${service}.service" ] || \
    [ -s "/usr/lib/systemd/system/${service}.service" ]
}

# 这次启动到底走不走 systemd，判断只留一份。
# 安装收尾要在启动后核对服务状态，核对方式取决于走了哪条分支：
# 各自再写一遍条件，迟早出现「用 systemctl 启动、用 pid 文件判断」这类错配。
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

Check_Openssl()
{
    if ! command -v openssl >/dev/null 2>&1; then
        Echo_Blue "[+] 正在安装 OpenSSL..."
        if [ "${PM}" = "yum" ]; then
            yum install -y openssl
        elif [ "${PM}" = "apt" ]; then
            apt-get update -y
            [[ $? -ne 0 ]] && apt-get update --allow-releaseinfo-change -y
            apt-get install -y openssl
        fi
    fi
    openssl version
    if openssl version | grep -Eqi "OpenSSL 3.*"; then
        isOpenSSL3='y'
    fi
}
# 计算 UTF-8 文本在常见终端中的显示宽度：ASCII 占 1 列，三字节中日韩字符占 2 列。
# 本项目的 banner 文案只使用这两类字符，借此保证中文框线可以稳定对齐。
Text_Display_Width()
{
    local text="$1" bytes ascii_bytes wide_chars
    bytes=$(printf '%s' "${text}" | LC_ALL=C wc -c)
    ascii_bytes=$(printf '%s' "${text}" | LC_ALL=C tr -cd '\000-\177' | wc -c)
    wide_chars=$(( (bytes - ascii_bytes) / 3 ))
    printf '%d' $((ascii_bytes + wide_chars * 2))
}

# Warn_Demo_Page_Not_Served — 演示页写入 default 根目录后核对 Web 配置是否放行
#
# default 站点默认拒绝执行 PHP。新装环境的配置模板已按固定文件名放行
# phpinfo / redis / memcached 三个演示页；在此之前装好的环境没有这段规则，
# 页面文件写进去了也只会返回 404。这里只做检查和提示，不去改使用者可能
# 已经定制过的站点配置。始终返回 0，不影响调用方的安装结果。
Warn_Demo_Page_Not_Served()
{
    local page="$1"
    # nginx 与 Apache 两份模板里放行规则的写法不同，但都含这段固定的文件名
    # 分支，用固定串匹配，免去两套正则转义。
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
