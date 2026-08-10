#!/usr/bin/env bash
#
# profile.sh — 菜单编号到版本语义的唯一映射表
#
# 设计约定（必须遵守）：
#   1. 编号（DBSelect / PHPSelect / ApacheSelect）只允许出现在本文件、
#      main.sh 的菜单读取处、multiplephp.sh 的菜单读取处。其余任何文件
#      出现编号判断都是漏改。用 t/lint.sh 的 C1 检查。
#   2. 其余代码一律判断语义变量：DB_Kind / DB_Branch / PHP_Branch 等。
#   3. 增删版本、重编号，只改本文件的 case 表和对应的 *_Info 数组。
#
# 不用关联数组而用 case：bash 3.2 兼容，且与 version.sh 既有风格一致，
# diff 更小、更便于人工复核。

# ---------------------------------------------------------------------------
# 菜单显示文本。下标 0-based，菜单编号 1-based，二者相差 1。
# 长度断言把"菜单项数与数组不匹配"从静默空字符串变成启动即失败。
# ---------------------------------------------------------------------------
DB_Info=('MySQL 8.0.46' 'MySQL 8.4.7 LTS' 'MariaDB 10.11.18' 'MariaDB 11.4.12 LTS' 'MariaDB 11.8.8 LTS')
PHP_Info=('PHP 8.0.30' 'PHP 8.1.34' 'PHP 8.2.33' 'PHP 8.3.33' 'PHP 8.4.24' 'PHP 8.5.9')
Apache_Info=('Apache 2.4.68')

DB_Count=5
PHP_Count=6
Apache_Count=1

DB_Default='2'      # MySQL 8.4 LTS
PHP_Default='4'     # PHP 8.3
Apache_Default='1'  # Apache 2.4（2.2 已随 EOL 移除）

[ ${#DB_Info[@]}     -eq ${DB_Count} ]     || { echo "FATAL: DB_Info arity drift: ${#DB_Info[@]} != ${DB_Count}"; exit 1; }
[ ${#PHP_Info[@]}    -eq ${PHP_Count} ]    || { echo "FATAL: PHP_Info arity drift: ${#PHP_Info[@]} != ${PHP_Count}"; exit 1; }
[ ${#Apache_Info[@]} -eq ${Apache_Count} ] || { echo "FATAL: Apache_Info arity drift: ${#Apache_Info[@]} != ${Apache_Count}"; exit 1; }

Set_DB_Profile()
{
    DB_Kind='' DB_Branch='' DB_Ver='' DB_Install='' DB_Bin_Archs='' DB_Bin_Default='' DB_Bin_Glibc='' DB_Needs_Boost='n' DB_Boost_Mode='' DB_Min_Mem_MB=0 DB_Service='' DB_Data_Dir='' DB_Note=''

    case "$1" in
    # DB_Bin_Archs 的取值口径（2026-08 复核后收紧）：
    #
    # 只列出「上游确实提供二进制」且「本包能校验其完整性」的架构。
    #
    # 旧映射将 MySQL 8.0 标为支持 x86_64 和 aarch64，将 MariaDB 11.x 标为支持 i686；前者
    # 上游确实有包但 src/checksums.sha256 里只有 x86_64 一条，后者上游根本不提供。
    # 两种情况在 fail-closed 校验下的结果一样：选到那个架构将中止安装，
    # 也就是「看着像支持、实际不支持」。
    #
    # 实测（MariaDB 经官方 REST API 逐个确认，MySQL 经 HEAD 请求确认）：
    #   mysql-8.0.46    x86_64 / aarch64 都有二进制包，但 MySQL 不公布
    #                   机器可读的校验值，aarch64 那个包无法自动核对，故不列入；
    #   mysql-8.4.7     只有 glibc2.17-x86_64，官方未提供 aarch64/i686；
    #   mariadb 三条 LTS  官方只提供 x86_64 的 linux-systemd 通用二进制。
    #
    # 非 x86_64 架构由 Select_DB_Bin 自动切换到源码编译路径，
    # 只是少了"下个二进制包直接用"的捷径。
    1)  DB_Kind='mysql'   DB_Branch='8.0'   DB_Ver='mysql-8.0.46'
        DB_Install='Install_MySQL_80'     DB_Bin_Archs='x86_64'
        DB_Bin_Default='auto' DB_Bin_Glibc='2.28' DB_Needs_Boost='y' DB_Boost_Mode='auto'
        DB_Min_Mem_MB=1024 DB_Note=' (EOL 2026-04)' ;;
    2)  DB_Kind='mysql'   DB_Branch='8.4'   DB_Ver='mysql-8.4.7'
        DB_Install='Install_MySQL_84'     DB_Bin_Archs='x86_64'
        DB_Bin_Default='auto' DB_Bin_Glibc='2.17' DB_Needs_Boost='y' DB_Boost_Mode='auto'
        DB_Min_Mem_MB=1024 ;;
    3)  DB_Kind='mariadb' DB_Branch='10.11' DB_Ver='mariadb-10.11.18'
        DB_Install='Install_MariaDB_1011' DB_Bin_Archs='x86_64'
        DB_Bin_Default='auto' DB_Min_Mem_MB=1024 ;;
    4)  DB_Kind='mariadb' DB_Branch='11.4'  DB_Ver='mariadb-11.4.12'
        DB_Install='Install_MariaDB_114'  DB_Bin_Archs='x86_64'
        DB_Bin_Default='auto' DB_Min_Mem_MB=1024 ;;
    5)  DB_Kind='mariadb' DB_Branch='11.8'  DB_Ver='mariadb-11.8.8'
        DB_Install='Install_MariaDB_118'  DB_Bin_Archs='x86_64'
        DB_Bin_Default='auto' DB_Min_Mem_MB=1024 ;;
    0)  DB_Kind='none' ;;
    *)  Legacy_Selection_Hint DB "$1"
        return 1 ;;
    esac

    case "${DB_Kind}" in
    mysql)
        Mysql_Ver="${DB_Ver}"
        MySQL_Dir='/usr/local/mysql'
        DB_Service='mysql'
        DB_Data_Dir="${MySQL_Data_Dir}"
        ;;
    mariadb)
        Mariadb_Ver="${DB_Ver}"
        MySQL_Dir='/usr/local/mariadb'
        DB_Service='mariadb'
        DB_Data_Dir="${MariaDB_Data_Dir}"
        ;;
    esac

    if [ "${DB_Kind}" != 'none' ]; then
        MySQL_Bin="${MySQL_Dir}/bin/mysql"
        MySQL_Config="${MySQL_Dir}/bin/mysql_config"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Set_PHP_Profile <编号>
#
# 产出：
#   PHP_Branch          主版本号（如 8.3），用于拼接路径与配置文件名
#   Php_Ver             完整版本标识（如 php-8.3.33）
#   PHP_Install         主 PHP 安装函数名
#   MPHP_Install        多版本 PHP 安装函数名
#   MPHP_Path           多版本 PHP 安装路径
#   PHP_Apache_Module   Apache 模块文件名（libphp5.so / libphp7.so / libphp.so）
#   Enable_PHP_Config   conf/ 下对应的 enable-php 配置文件名
#   PhpMyAdmin_Ver      该 PHP 版本可用的 phpMyAdmin 版本
#   PHP_Needs_Autoconf213  y | n，是否需要 autoconf 2.13（仅 PHP 5.2）
#   PHP_Needs_DB        y | n，该版本是否必须与数据库同装（仅 PHP 5.2）
#   PHP_Note            菜单后缀标注
#
# 返回：0 成功，1 编号非法
# ---------------------------------------------------------------------------
Set_PHP_Profile()
{
    PHP_Branch='' Php_Ver='' PHP_Install='' MPHP_Install='' MPHP_Path=''
    PHP_Apache_Module='' Enable_PHP_Config='' PhpMyAdmin_Ver=''
    PHP_Needs_Autoconf213='n' PHP_Needs_DB='n' PHP_Note=''

    case "$1" in
    1)  PHP_Branch='8.0' Php_Ver='php-8.0.30' PHP_Install='Install_PHP_80'
        PHP_Note=' (EOL)' ;;
    2)  PHP_Branch='8.1' Php_Ver='php-8.1.34' PHP_Install='Install_PHP_81' ;;
    3)  PHP_Branch='8.2' Php_Ver='php-8.2.33' PHP_Install='Install_PHP_82' ;;
    4)  PHP_Branch='8.3' Php_Ver='php-8.3.33' PHP_Install='Install_PHP_83' ;;
    5)  PHP_Branch='8.4' Php_Ver='php-8.4.24' PHP_Install='Install_PHP_84' ;;
    6)  PHP_Branch='8.5' Php_Ver='php-8.5.9'  PHP_Install='Install_PHP_85' ;;
    *)  Legacy_Selection_Hint PHP "$1"
        return 1 ;;
    esac

    MPHP_Path="/usr/local/php${PHP_Branch}"
    MPHP_Install="Install_MPHP${PHP_Branch}"
    Enable_PHP_Config="enable-php${PHP_Branch}.conf"

    # 保留的版本全是 PHP 8.x，Apache 模块统一为 libphp.so
    PHP_Apache_Module='libphp.so'
    PhpMyAdmin_Ver='phpMyAdmin-5.2.3-all-languages'

    return 0
}

# ---------------------------------------------------------------------------
# Legacy_Selection_Hint — 对旧编号给出明确提示
#
# 2.3 之前 DB 编号是 1..13、PHP 编号是 1..16。重编号后若有自动化脚本沿用
# 旧值（例如 DBSelect=12 本想装 MariaDB 11.4），静默回退到默认值会让用户
# 装错版本且毫无察觉。这里显式报错并打印新编号表。
# ---------------------------------------------------------------------------
Legacy_Selection_Hint()
{
    local kind="$1" val="$2"
    case "${val}" in
    ''|*[!0-9]*) return 0 ;;
    esac

    if [ "${kind}" = "DB" ] && [ "${val}" -gt "${DB_Count}" ]; then
        Echo_Red "DBSelect=${val} 属于 2.3 之前的编号，已失效。"
        Echo_Red "新编号：1=MySQL8.0  2=MySQL8.4(默认)  3=MariaDB10.11  4=MariaDB11.4  5=MariaDB11.8  0=不安装"
    elif [ "${kind}" = "PHP" ] && [ "${val}" -gt "${PHP_Count}" ]; then
        Echo_Red "PHPSelect=${val} 属于 2.3 之前的编号，已失效。"
        Echo_Red "新编号：1=PHP8.0  2=PHP8.1  3=PHP8.2  4=PHP8.3(默认)  5=PHP8.4  6=PHP8.5"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Set_Apache_Profile <编号>
# ---------------------------------------------------------------------------
Set_Apache_Profile()
{
    Apache_Branch='' Apache_Ver='' Apache_Install=''

    case "$1" in
    1) Apache_Branch='2.4' Apache_Ver='httpd-2.4.68' Apache_Install='Install_Apache_24' ;;
    *) return 1 ;;
    esac

    return 0
}


Dispatch()
{
    local func="$1"

    if [ -z "${func}" ]; then
        Echo_Red "FATAL: empty dispatch target."
        Echo_Red "The selection table in include/profile.sh produced no install function."
        exit 1
    fi

    if ! declare -f "${func}" >/dev/null 2>&1; then
        Echo_Red "FATAL: install function '${func}' is not defined."
        Echo_Red "include/profile.sh references a function that does not exist."
        exit 1
    fi

    "${func}"
}

# ---------------------------------------------------------------------------
# DB_Bin_Available — 当前架构是否有官方通用二进制包可用
# 返回 0 可用，1 不可用（调用方应回退到源码编译）
# ---------------------------------------------------------------------------
DB_Bin_Available()
{
    [ -z "${DB_Bin_Archs}" ] && return 1
    case " ${DB_Bin_Archs} " in
        *" ${DB_ARCH} "*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Print_DB_Menu / Print_PHP_Menu — 由映射表生成菜单，避免菜单文本与表脱节
#
# 注意：这两个函数在循环里调用 Set_*_Profile 来取标注文本，会覆盖当前的
# profile 变量。菜单只在用户尚未选择时打印，之后调用方会重新调用
# Set_*_Profile 设定最终值，所以这里的副作用无害。但若将来在选择完成后
# 再次调用本函数，必须先保存再恢复。
# ---------------------------------------------------------------------------
Print_DB_Menu()
{
    local i note
    Echo_Yellow "You have ${DB_Count} options for your DataBase install."
    i=1
    while [ ${i} -le ${DB_Count} ]; do
        Set_DB_Profile "${i}"
        note="${DB_Note}"
        [ "${i}" = "${DB_Default}" ] && note="${note} (Default)"
        echo "${i}: Install ${DB_Info[$((i-1))]}${note}"
        i=$((i+1))
    done
    echo "0: DO NOT Install MySQL/MariaDB"
}

Print_PHP_Menu()
{
    local i note
    Echo_Yellow "You have ${PHP_Count} options for your PHP install."
    i=1
    while [ ${i} -le ${PHP_Count} ]; do
        Set_PHP_Profile "${i}"
        note="${PHP_Note}"
        [ "${i}" = "${PHP_Default}" ] && note="${note} (Default)"
        echo "${i}: Install ${PHP_Info[$((i-1))]}${note}"
        i=$((i+1))
    done
}


Select_DB_Bin()
{
    # 该版本压根不提供通用二进制（如 MySQL 5.1），或当前架构没有二进制包
    if [ -z "${DB_Bin_Default}" ] || ! DB_Bin_Available; then
        [ -z "${DB_Bin_Default}" ] && echo "You will install ${DB_Ver}"
        [ -n "${DB_Bin_Default}" ] && echo "Default install ${DB_Ver} from Source."
        Bin="n"
        return 0
    fi

    if [ -z "${Bin}" ]; then
        read -p "Using Generic Binaries [y/n]: " Bin
    fi

    case "${Bin}" in
    [yY][eE][sS]|[yY])
        echo "You will install ${DB_Ver} Using Generic Binaries."
        Bin="y"
        ;;
    [nN][oO]|[nN])
        echo "You will install ${DB_Ver} from Source."
        Bin="n"
        ;;
    *)
        if [ "${DB_Bin_Default}" = "auto" ] && [ "${CheckMirror}" != "n" ]; then
            echo "Default install ${DB_Ver} Using Generic Binaries."
            Bin="y"
        else
            echo "Default install ${DB_Ver} from Source."
            Bin="n"
        fi
        ;;
    esac
}
