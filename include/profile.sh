#!/usr/bin/env bash
# 菜单编号与版本属性的统一映射表。
# 其他安装流程使用 DB_Kind、DB_Branch、PHP_Branch 等语义变量，避免编号变化
# 影响版本判断。case 写法用于兼容 Bash 3.2。

# 菜单显示文本。下标 0-based，菜单编号 1-based，二者相差 1。
# 数组长度不匹配时立即停止，避免菜单显示空版本。
DB_Info=('MySQL 8.0.46' 'MySQL 8.4.7 LTS' 'MariaDB 10.11.18' 'MariaDB 11.4.12 LTS' 'MariaDB 11.8.8 LTS')
PHP_Info=('PHP 8.0.30' 'PHP 8.1.34' 'PHP 8.2.33' 'PHP 8.3.33' 'PHP 8.4.24' 'PHP 8.5.9')
Apache_Info=('Apache 2.4.68')

DB_Count=5
PHP_Count=6
Apache_Count=1

DB_Default='2'      # MySQL 8.4 LTS
PHP_Default='4'     # PHP 8.3
Apache_Default='1'  # Apache 2.4（2.2 已随 EOL 移除）

[ ${#DB_Info[@]}     -eq ${DB_Count} ]     || { echo "致命错误：DB_Info 项目数异常：${#DB_Info[@]} != ${DB_Count}"; exit 1; }
[ ${#PHP_Info[@]}    -eq ${PHP_Count} ]    || { echo "致命错误：PHP_Info 项目数异常：${#PHP_Info[@]} != ${PHP_Count}"; exit 1; }
[ ${#Apache_Info[@]} -eq ${Apache_Count} ] || { echo "致命错误：Apache_Info 项目数异常：${#Apache_Info[@]} != ${Apache_Count}"; exit 1; }

Set_DB_Profile()
{
    DB_Kind='' DB_Branch='' DB_Ver='' DB_Install='' DB_Bin_Archs='' DB_Bin_Default='' DB_Bin_Glibc='' DB_Needs_Boost='n' DB_Boost_Mode='' DB_Min_Mem_MB=0 DB_Service='' DB_Data_Dir='' DB_Note=''

    case "$1" in
    # DB_Bin_Archs 仅列出上游提供且可验证完整性的通用二进制架构。
    # 当前所列 MySQL 和 MariaDB 版本仅对 x86_64 启用该路径，其他架构
    # 自动使用源码编译。
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

    if [ "${DB_Kind}" = 'mariadb' ]; then
        MySQL_Bin="${MySQL_Dir}/bin/mariadb"
        MySQL_Config="${MySQL_Dir}/bin/mariadb_config"
    elif [ "${DB_Kind}" = 'mysql' ]; then
        MySQL_Bin="${MySQL_Dir}/bin/mysql"
        MySQL_Config="${MySQL_Dir}/bin/mysql_config"
    fi

    return 0
}

# Set_PHP_Profile <编号>
# 产出：
#   PHP_Branch          主版本号（如 8.3），用于拼接路径与配置文件名
#   Php_Ver             完整版本标识（如 php-8.3.33）
#   PHP_Install         主 PHP 安装函数名
#   MPHP_Install        多版本 PHP 安装函数名
#   MPHP_Path           多版本 PHP 安装路径
#   PHP_Apache_Module   Apache 模块文件名（libphp5.so / libphp7.so / libphp.so）
#   Enable_PHP_Config   conf/ 下对应的 enable-php 配置文件名
#   PhpMyAdmin_Ver      该 PHP 版本可用的 phpMyAdmin 版本
#   PHP_Needs_DB        y | n，该版本是否必须与数据库同装（仅 PHP 5.2）
#   PHP_Note            菜单后缀标注
# 返回：0 成功，1 编号非法
Set_PHP_Profile()
{
    PHP_Branch='' Php_Ver='' PHP_Install='' MPHP_Install='' MPHP_Path=''
    PHP_Apache_Module='' Enable_PHP_Config='' PhpMyAdmin_Ver=''
    PHP_Needs_DB='n' PHP_Note=''

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

    # 当前 PHP 8.x 的 Apache 模块统一使用 libphp.so。
    PHP_Apache_Module='libphp.so'
    PhpMyAdmin_Ver='phpMyAdmin-5.2.3-all-languages'

    return 0
}

# 旧版编号无效时显示当前编号，防止自动化任务静默安装错误版本。
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

# Set_Apache_Profile <编号>
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
        Echo_Red "致命错误：分发目标为空。"
        Echo_Red "include/profile.sh 的选择表没有生成安装函数。"
        exit 1
    fi

    if ! declare -f "${func}" >/dev/null 2>&1; then
        Echo_Red "致命错误：安装函数 '${func}' 未定义。"
        Echo_Red "include/profile.sh 引用了不存在的函数。"
        exit 1
    fi

    "${func}"
}

# 判断当前架构是否有可验证的官方通用二进制包；不可用时应使用源码编译。
DB_Bin_Available()
{
    [ -z "${DB_Bin_Archs}" ] && return 1
    case " ${DB_Bin_Archs} " in
        *" ${DB_ARCH} "*) return 0 ;;
        *) return 1 ;;
    esac
}

# 根据映射表生成数据库和 PHP 菜单。菜单显示后由调用方重新设置最终选项。
Print_DB_Menu()
{
    local i note
    Echo_Yellow "数据库有 ${DB_Count} 个可安装版本："
    i=1
    while [ ${i} -le ${DB_Count} ]; do
        Set_DB_Profile "${i}"
        note="${DB_Note}"
        [ "${i}" = "${DB_Default}" ] && note="${note}（默认）"
        echo "${i}: 安装 ${DB_Info[$((i-1))]}${note}"
        i=$((i+1))
    done
    echo "0: 不安装 MySQL/MariaDB"
}

Print_PHP_Menu()
{
    local i note
    Echo_Yellow "PHP 有 ${PHP_Count} 个可安装版本："
    i=1
    while [ ${i} -le ${PHP_Count} ]; do
        Set_PHP_Profile "${i}"
        note="${PHP_Note}"
        [ "${i}" = "${PHP_Default}" ] && note="${note}（默认）"
        echo "${i}: 安装 ${PHP_Info[$((i-1))]}${note}"
        i=$((i+1))
    done
}


Select_DB_Bin()
{
    # 版本或当前架构没有可用通用二进制包时使用源码编译。
    if [ -z "${DB_Bin_Default}" ] || ! DB_Bin_Available; then
        [ -z "${DB_Bin_Default}" ] && echo "将安装 ${DB_Ver}。"
        [ -n "${DB_Bin_Default}" ] && echo "当前平台没有可用通用二进制包，将从源码编译 ${DB_Ver}。"
        Bin="n"
        return 0
    fi

    if [ -z "${Bin}" ]; then
        # 明确展示通用二进制与源码编译的资源和时间差异。
        echo "y = 使用官方通用二进制：上游构建，校验值强制核对，几分钟装完（推荐）"
        echo "n = 自行编译源码：需要 4GB 以上内存和 15GB 以上磁盘，通常要跑数小时，"
        echo "    只有确实需要定制编译参数时才选它"
        read -p "是否使用官方通用二进制包 [Y/n]（默认 y，推荐）: " Bin
    fi

    case "${Bin}" in
    [yY][eE][sS]|[yY])
        echo "将使用官方通用二进制包安装 ${DB_Ver}。"
        Bin="y"
        ;;
    [nN][oO]|[nN])
        echo "将从源码编译安装 ${DB_Ver}。"
        Bin="n"
        ;;
    *)
        if [ "${DB_Bin_Default}" = "auto" ] && [ "${CheckMirror}" != "n" ]; then
            echo "未输入，默认使用官方通用二进制包安装 ${DB_Ver}。"
            Bin="y"
        else
            echo "未输入，默认从源码编译安装 ${DB_Ver}。"
            Bin="n"
        fi
        ;;
    esac
}
