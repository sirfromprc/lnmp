#!/usr/bin/env bash

# DB_Info / PHP_Info / Apache_Info 已移至 include/profile.sh，
# 与编号映射表放在一起，避免菜单文本和版本表分居两地而脱节。

# phpMyAdmin 装在网站根目录之外。放在根目录下时，Web 服务器配置一旦失效
# （改错、被覆盖、模块未加载），整套源码连同 config.inc.php 就会被当作
# 静态文件下载。访问入口由 Web 服务器映射，见 Config_PhpMyAdmin_Access。
PhpMyAdmin_Dir='/usr/local/phpmyadmin'

# 记录随机访问路径，供安装结束提示与 lnmp status 读取。
PhpMyAdmin_Url_File="${PhpMyAdmin_Dir}/.access_url"

Database_Selection()
{
#which MySQL Version do you want to install?
    if [ -z "${DBSelect}" ]; then
        Print_DB_Menu
        read -p "Enter your choice (1 - ${DB_Count}, or 0): " DBSelect
    fi

    # 编号通过 profile.sh 映射为版本、架构和默认策略。
    # 仅空输入使用默认值；非法编号必须终止安装。
    if [ -z "${DBSelect}" ]; then
        DBSelect="${DB_Default}"
        echo "No input, you will install ${DB_Info[$((DB_Default-1))]}"
    fi
    Set_DB_Profile "${DBSelect}" || Invalid_Selection DB "${DBSelect}"

    if [ "${DB_Kind}" = "none" ]; then
        echo "Do not install MySQL/MariaDB!"
    else
        Select_DB_Bin
    fi

    if [ "${Bin}" != "y" ] && [ "${DB_Min_Mem_MB}" -gt 0 ] && [ $(awk '/MemTotal/ {printf( "%d\n", $2 / 1024 )}' /proc/meminfo) -le "${DB_Min_Mem_MB}" ]; then
        echo "Memory less than ${DB_Min_Mem_MB}MB, can't build ${DB_Ver} from source!"
        exit 1
    fi

    if [[ "${DBSelect}" != "0" ]]; then
        #set mysql root password
        #
        # 密码输入不回显，且不得写入安装日志。
        DB_Root_Password_Random='n'
        if [ -z "${DB_Root_Password}" ]; then
            echo "==========================="
            Echo_Yellow "Please setup root password of MySQL (输入不回显)."
            read -r -s -p "Please enter: " DB_Root_Password
            echo
            if [ "${DB_Root_Password}" = "" ]; then
                echo "NO input, password will be generated randomly."
                DB_Root_Password="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
                DB_Root_Password_Random='y'
            fi
        fi

        #do you want to enable or disable the InnoDB Storage Engine?
        echo "==========================="

        if [ -z ${InstallInnodb} ]; then
            InstallInnodb="y"
            Echo_Yellow "Do you want to enable or disable the InnoDB Storage Engine?"
            read -p "Default enable,Enter your choice [Y/n]: " InstallInnodb
        fi

        case "${InstallInnodb}" in
        [yY][eE][sS]|[yY])
            echo "You will enable the InnoDB Storage Engine"
            InstallInnodb="y"
            ;;
        [nN][oO]|[nN])
            echo "You will disable the InnoDB Storage Engine!"
            InstallInnodb="n"
            ;;
        *)
            echo "No input,The InnoDB Storage Engine will enable."
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
        read -p "Enter your choice (1 - ${PHP_Count}): " PHPSelect
    fi

    # PHP 版本属性由 profile.sh 提供；空输入与非法输入分别处理。
    if [ -z "${PHPSelect}" ]; then
        PHPSelect="${PHP_Default}"
        echo "No input, you will install ${PHP_Info[$((PHP_Default-1))]}"
    fi
    Set_PHP_Profile "${PHPSelect}" || Invalid_Selection PHP "${PHPSelect}"
    echo "You will install ${PHP_Info[$((PHPSelect-1))]}"

    if [ "${PHP_Needs_DB}" = "y" ] && [ "${DBSelect}" = "0" ]; then
        echo "You didn't select MySQL/MariaDB can't select ${PHP_Info[$((PHPSelect-1))]}!"
        exit 1
    fi
}

MemoryAllocator_Selection()
{
#which Memory Allocator do you want to install?
    if [ -z ${SelectMalloc} ]; then
        echo "==========================="

        SelectMalloc="1"
        Echo_Yellow "You have 3 options for your Memory Allocator install."
        echo "1: Don't install Memory Allocator. (Default)"
        echo "2: Install Jemalloc"
        echo "3: Install TCMalloc"
        read -p "Enter your choice (1, 2 or 3): " SelectMalloc
    fi

    case "${SelectMalloc}" in
    1)
        echo "You will install not install Memory Allocator."
        ;;
    2)
        echo "You will install JeMalloc"
        ;;
    3)
        echo "You will Install TCMalloc"
        ;;
    *)
        echo "No input,You will not install Memory Allocator."
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
        Echo_Yellow "You have 2 options for your Web Server install."
        echo "1: Install Nginx ${Nginx_Ver#nginx-} (源码编译，默认)"
        echo "2: Install OpenResty (自带 LuaJIT 与 lua-resty-* 全家桶)"
        read -p "Enter your choice (1 or 2): " WebSelect
    fi

    case "${WebSelect}" in
    2|[oO][pP][eE][nN][rR][eE][sS][tT][yY])
        WebServer='openresty'
        echo "You will install OpenResty."
        ;;
    *)
        WebServer='nginx'
        [ -z "${WebSelect}" ] && echo "No input, you will install Nginx." \
                              || echo "You will install Nginx."
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
        read -p "Enter your choice (1 or 2): " ORMode
    fi

    case "${ORMode}" in
    2|[sS][oO][uU][rR][cC][eE])
        OpenResty_Install_Mode='source'
        echo "You will install OpenResty ${OpenResty_Ver#openresty-} from source."
        ;;
    *)
        OpenResty_Install_Mode='pkg'
        echo "You will install OpenResty from official package repository."
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
        read -p "Please enter Administrator Email Address: " ServerAdmin
    fi
    if [ "${ServerAdmin}" == "" ]; then
        echo "Administrator Email Address will set to webmaster@example.com!"
        ServerAdmin="webmaster@example.com"
    else
        echo "==========================="
        echo Server Administrator Email: "${ServerAdmin}"
        echo "==========================="
    fi
    echo "==========================="

    # Apache 仅支持 2.4；保留 ApacheSelect 以兼容命令行参数。
    [ -z "${ApacheSelect}" ] && ApacheSelect="${Apache_Default}"
    Set_Apache_Profile "${ApacheSelect}" || Invalid_Selection Apache "${ApacheSelect}"
    echo "You will install ${Apache_Info[$((ApacheSelect-1))]}"
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
    if [ -z ${LNMP_Auto} ]; then
        echo ""
        Echo_Green "Press any key to install...or Press Ctrl+c to cancel"
        OLDCONFIG=`stty -g`
        stty -icanon -echo min 1 time 0
        dd count=1 2>/dev/null
        stty ${OLDCONFIG}
    fi
    . include/version.sh
    Set_Profiles
    Kill_PM
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
    Echo_Red "FATAL: invalid ${1}Select value: '${2}'"
    case "$1" in
    DB)
        Echo_Red "Valid values: 0 (skip), 1..${DB_Count}"
        ;;
    PHP)
        Echo_Red "Valid values: 1..${PHP_Count}"
        ;;
    Apache)
        Echo_Red "Valid values: 1..${Apache_Count}"
        ;;
    esac
    exit 1
}

Press_Start()
{
    echo ""
    Echo_Green "Press any key to start...or Press Ctrl+c to cancel"
    OLDCONFIG=`stty -g`
    stty -icanon -echo min 1 time 0
    dd count=1 2>/dev/null
    stty ${OLDCONFIG}
}

Install_LSB()
{
    echo "[+] Installing lsb..."
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
            echo "Current Version: RHEL Ver 5"
            RHEL_Ver='5'
        elif grep -Eqi "release 6." /etc/redhat-release; then
            echo "Current Version: RHEL Ver 6"
            RHEL_Ver='6'
        elif grep -Eqi "release 7." /etc/redhat-release; then
            echo "Current Version: RHEL Ver 7"
            RHEL_Ver='7'
        elif grep -Eqi "release 8." /etc/redhat-release; then
            echo "Current Version: RHEL Ver 8"
            RHEL_Ver='8'
        elif grep -Eqi "release 9." /etc/redhat-release; then
            echo "Current Version: RHEL Ver 9"
            RHEL_Ver='9'
        elif grep -Eqi "release 10." /etc/redhat-release; then
            echo "Current Version: RHEL Ver 10"
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
        Echo_Red "FATAL: checksum manifest not found: ${Checksum_File}"
        Echo_Red "Integrity verification is mandatory. Refuse to use ${FileName}."
        Echo_Red "Set Enable_Download_Checksum='n' in lnmp.conf to bypass (NOT recommended)."
        rm -f "${FileName}"
        exit 1
    fi

    Expected_SHA256=$(awk -v file="${FileName}" '$1 !~ /^#/ && $2 == file {print $1; exit}' "${Checksum_File}")
    if [ "${Expected_SHA256}" = "" ]; then
        Echo_Red "FATAL: no checksum entry for ${FileName} in ${Checksum_File}"
        Echo_Red "An unlisted file will not be used. Add its SHA256 to the manifest first."
        rm -f "${FileName}"
        exit 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        Actual_SHA256=$(sha256sum "${FileName}" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        Actual_SHA256=$(shasum -a 256 "${FileName}" | awk '{print $1}')
    else
        Echo_Red "FATAL: neither sha256sum nor shasum is available, cannot verify ${FileName}."
        exit 1
    fi

    if [ "${Actual_SHA256}" != "${Expected_SHA256}" ]; then
        Echo_Red "FATAL: SHA256 mismatch for ${FileName}"
        Echo_Red "  expected: ${Expected_SHA256}"
        Echo_Red "  actual:   ${Actual_SHA256}"
        Echo_Red "The file has been removed. This may indicate a tampered download."
        rm -f "${FileName}"
        exit 1
    fi
    Echo_Green "${FileName} SHA256 checksum ok."
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
        Echo_Red "Error! Unable to download $2."
        Echo_Red "Please download it to the src directory manually: $1"
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
        echo "${FileName} [found]"
        Verify_Download_File "${FileName}"
        return $?
    fi

    echo "Notice: ${FileName} not found!!!download now..."
    if [ "${Download_Insecure}" = "y" ]; then
        # 仅用于证书故障诊断；该模式不验证 TLS 证书。
        Echo_Red "WARNING: Download_Insecure='y' disables TLS certificate verification."
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

Tar_Cd()
{
    local FileName=$1
    local DirName=$2
    local extension=${FileName##*.}

    if ! cd "${cur_dir}/src"; then
        Echo_Red "FATAL: cannot cd to ${cur_dir}/src"
        exit 1
    fi
    [[ -d "${DirName}" ]] && rm -rf "${DirName}"
    echo "Uncompress ${FileName}..."
    case "${extension}" in
    gz|tgz) tar zxf "${FileName}" ;;
    bz2)    tar jxf "${FileName}" ;;
    xz)     tar Jxf "${FileName}" ;;
    *)
        Echo_Red "FATAL: unknown archive extension '${extension}' for ${FileName}"
        exit 1
        ;;
    esac
    if [ $? -ne 0 ]; then
        Echo_Red "FATAL: failed to uncompress ${FileName}"
        exit 1
    fi

    if [ -n "${DirName}" ]; then
        echo "cd ${DirName}..."
        if ! cd "${DirName}"; then
            Echo_Red "FATAL: ${FileName} 解压后没有预期的目录 ${DirName}"
            Echo_Red "归档结构与预期不符，拒绝在错误的目录里继续编译。"
            exit 1
        fi
    fi
}

Check_LNMPConf()
{
    if [ ! -s "${cur_dir}/lnmp.conf" ]; then
        Echo_Red "lnmp.conf was not exsit!"
        exit 1
    fi
    if [[ "${MySQL_Data_Dir}" = "" || "${MariaDB_Data_Dir}" = "" || "${Default_Website_Dir}" = "" ]]; then
        Echo_Red "Can't get values from lnmp.conf!"
        exit 1
    fi
    if [[ "${MySQL_Data_Dir}" = "/" || "${MariaDB_Data_Dir}" = "/" || "${Default_Website_Dir}" = "/" ]]; then
        Echo_Red "Can't set MySQL/MariaDB/Website Directory to / !"
        exit 1
    fi
}

Print_APP_Ver()
{
    echo "You will install ${Stack} stack."
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
        echo "Do not install MySQL/MariaDB!"
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
    echo "Enable InnoDB: ${InstallInnodb}"
    echo "Print lnmp.conf infomation..."
    echo "Download Source: upstream official only"
    echo "Checksum Verify: ${Enable_Download_Checksum}"
    echo "Nginx Additional Modules: ${Nginx_Modules_Options}"
    echo "PHP Additional Modules: ${PHP_Modules_Options}"
    if [ "${Enable_PHP_Fileinfo}" = "y" ]; then
        echo "enable PHP fileinfo."
    fi
    if [ "${Enable_Nginx_Lua}" = "y" ]; then
        echo "enable Nginx Lua."
    fi
    if [ "${DB_Kind}" = "none" ]; then
        echo "Do not install MySQL/MariaDB!"
    else
        echo "Database Directory: ${DB_Data_Dir}"
    fi
    echo "Default Website Directory: ${Default_Website_Dir}"
}

Print_Sys_Info()
{
    echo "LNMP Version: ${LNMP_Ver}"
    eval echo "${DISTRO} \${${DISTRO}_Version}"
    cat /etc/issue
    cat /etc/*-release
    uname -a
    MemTotal=$(awk '/MemTotal/ {printf( "%d\n", $2 / 1024 )}' /proc/meminfo)
    echo "Memory is: ${MemTotal} MB "
    df -h
    Check_Openssl
    Check_WSL
    Check_Docker
}

StartUp()
{
    init_name=$1
    echo "Add ${init_name} service at system startup..."
    [[ "${isWSL}" = "" ]] && Check_WSL
    [[ "${isDocker}" = "" ]] && Check_Docker
    if [ "${isWSL}" = "n" ] && [ "${isDocker}" = "n" ] && command -v systemctl >/dev/null 2>&1 && [[ -s /etc/systemd/system/${init_name}.service || -s /lib/systemd/system/${init_name}.service || -s /usr/lib/systemd/system/${init_name}.service ]]; then
        systemctl daemon-reload
        systemctl enable ${init_name}.service
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
    init_name=$1
    echo "Removing ${init_name} service at system startup..."
    [[ "${isWSL}" = "" ]] && Check_WSL
    [[ "${isDocker}" = "" ]] && Check_Docker
    if [ "${isWSL}" = "n" ] && [ "${isDocker}" = "n" ] && command -v systemctl >/dev/null 2>&1 && [[ -s /etc/systemd/system/${init_name}.service || -s /lib/systemd/system/${init_name}.service || -s /usr/lib/systemd/system/${init_name}.service ]]; then
        systemctl disable ${init_name}.service
    else
        if [ "$PM" = "yum" ]; then
            chkconfig ${init_name} off
            chkconfig --del ${init_name}
        elif [ "$PM" = "apt" ]; then
            update-rc.d -f ${init_name} remove
        fi
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
            Echo_Red "MySQL 8.* please use latest linux distributions!"
            exit 1
        fi
    fi
    # PHP 7.4 及以上需要较新的发行版
    if Version_GE "${PHP_Branch}" 7.4; then
        if echo "${Ubuntu_Version}" | grep -Eqi "^1[0-7]\." || echo "${Debian_Version}" | grep -Eqi "^[4-8]" || echo "${Raspbian_Version}" | grep -Eqi "^[4-8]" || echo "${CentOS_Version}" | grep -Eqi "^[4-6]"  || echo "${RHEL_Version}" | grep -Eqi "^[4-6]" || echo "${Fedora_Version}" | grep -Eqi "^2[0-3]"; then
            Echo_Red "PHP 7.4 and PHP 8.* please use latest linux distributions!"
            exit 1
        fi
    fi
    # PHP 5.2 在过新的发行版上无法编译
    if [ "${PHP_Branch}" = "5.2" ]; then
        if echo "${Ubuntu_Version}" | grep -Eqi "^19|2[0-7]\." || echo "${Debian_Version}" | grep -Eqi "^1[0-9]" || echo "${Raspbian_Version}" | grep -Eqi "^1[0-9]" || echo "${Deepin_Version}" | grep -Eqi "^2[0-9]" || echo "${UOS_Version}" | grep -Eqi "^2[0-9]" || echo "${Fedora_Version}" | grep -Eqi "^29|3[0-9]"; then
            Echo_Red "PHP 5.2 is not supported on very new linux versions such as Ubuntu 19+, Debian 10, Deepin 20+, Fedora 29+ etc."
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

Check_DB()
{
    if [[ -s /usr/local/mariadb/bin/mysql && -s /usr/local/mariadb/bin/mysqld_safe && -s /etc/my.cnf ]]; then
        MySQL_Bin="/usr/local/mariadb/bin/mysql"
        MySQL_Config="/usr/local/mariadb/bin/mysql_config"
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
        read -s -p "Enter current root password of Database (Password will not shown): " DB_Root_Password
        Make_TempMycnf "${DB_Root_Password}"
        Do_Query ""
        status=$?
    done
    echo "OK, MySQL root password correct."
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

StartOrStop()
{
    local action=$1
    local service=$2
    [[ "${isWSL}" = "" ]] && Check_WSL
    [[ "${isDocker}" = "" ]] && Check_Docker
    if [ "${isWSL}" = "n" ] && [ "${isDocker}" = "n" ] && command -v systemctl >/dev/null 2>&1 && [[ -s /etc/systemd/system/${service}.service ]]; then
        systemctl ${action} ${service}.service
    else
        /etc/init.d/${service} ${action}
    fi
}

Check_WSL() {
    if [[ "$(< /proc/sys/kernel/osrelease)" == *[Mm]icrosoft* ]]; then
        echo "running on WSL"
        isWSL="y"
    else
        isWSL="n"
    fi
}

Check_Docker() {
    if [ -f /.dockerenv ]; then
        echo "running on Docker"
        isDocker="y"
    elif [ -f /proc/1/cgroup ] && grep -q docker /proc/1/cgroup; then
        echo "running on Docker"
        isDocker="y"
    elif [ -f /proc/self/cgroup ] && grep -q docker /proc/self/cgroup; then
        echo "running on Docker"
        isDocker="y"
    else
        isDocker="n"
    fi
}

Check_Openssl()
{
    if ! command -v openssl >/dev/null 2>&1; then
        Echo_Blue "[+] Installing openssl..."
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
