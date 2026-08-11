#!/usr/bin/env bash
#
# dbcommon.sh — 数据库下载与工具链的共享实现
#
# 背景：init.sh 的 Check_Download() 与 only.sh 的 Install_Database() 曾是两份
# 手工维护的副本已与主流程不一致；only.sh 在每次下载后检查 [ ! -s ]，
# init.sh 没有。结果是 `./install.sh db` 下载失败会中止，而 `./install.sh lnmp`
# 下载失败会带着空文件继续编译。
#
# 合并时取 only.sh 的严格版本。

# Require_File 已移到 include/main.sh。
#
# 它原本定义在这里，但 addons.sh / pureftpd.sh / tools/denyhosts.sh /
# tools/fail2ban.sh 未加载 dbcommon.sh，但会调用该函数；这些入口单独运行时
# 将 `command not found`，下载失败也照样往下解压编译。
# main.sh 是所有入口都会加载的模块，通用的下载守卫应该放在那里。

# ---------------------------------------------------------------------------
# DB_Bin_Glibc_Ver — 推导通用二进制包的 glibc 版本
# 正常情况下 DB_Bin_Glibc 由 profile.sh 按分支写死（实测值），此处的 auto
# 只是兜底。原兜底值 2.12 / 2.17 经实测已全部从 cdn.mysql.com 下线，
# 现使用 2.28；MySQL 8.0 的 x86_64 与 aarch64 包均使用该 glibc 版本。
# ---------------------------------------------------------------------------
DB_Bin_Glibc_Ver()
{
    if [ "${DB_Bin_Glibc}" = "auto" ]; then
        echo "2.28"
    else
        echo "${DB_Bin_Glibc}"
    fi
}


Install_DB_Bin_Tarball()
{
    local tarball=$1 target=$2 topdir rc restore_dotglob

    # ${tarball%.tar.*} 同时适配 .tar.xz（MySQL）与 .tar.gz（MariaDB）
    topdir="${cur_dir}/src/${tarball%.tar.*}"

    Tar_Cd "${tarball}"

    if [ ! -d "${topdir}" ]; then
        Echo_Red "Error: ${tarball} 解压后没有预期的目录 ${tarball%.tar.*}"
        Echo_Red "归档结构与预期不符（上游可能改了包内布局），拒绝继续安装。"
        exit 1
    fi

    if [ -e "${target}" ] && [ ! -d "${target}" ]; then
        Echo_Red "Error: ${target} 已存在且不是目录，拒绝覆盖。"
        exit 1
    fi
    # 允许目标为空目录，以支持预先挂载到 /usr/local/mysql 的独立卷。
    # 但非空一律拒绝：往里放只会得到新旧混合的安装。
    if [ -d "${target}" ] && [ -n "$(ls -A "${target}" 2>/dev/null)" ]; then
        Echo_Red "Error: ${target} 已存在且非空。"
        Echo_Red "直接往里放会得到一个新旧版本混合的安装，这里拒绝继续。"
        Echo_Red "请先确认该目录下是否还有数据，备份后移走或删除，再重新安装。"
        exit 1
    fi

    if ! mkdir -p "${target}"; then
        Echo_Red "Error: 无法创建 ${target}"
        exit 1
    fi

    # 顶层可能有 dotfile（官方包目前没有，但不该依赖这一点），开 dotglob 一并搬走。
    restore_dotglob=0
    shopt -q dotglob || restore_dotglob=1
    shopt -s dotglob
    mv "${topdir}"/* "${target}"/
    rc=$?
    [ ${restore_dotglob} -eq 1 ] && shopt -u dotglob

    if [ ${rc} -ne 0 ]; then
        Echo_Red "Error: 把 ${tarball%.tar.*} 移动到 ${target} 失败（磁盘空间不足？权限？）"
        Echo_Red "${target} 现在很可能是不完整的，请清空后重新安装。"
        exit 1
    fi

    # 落地结果自检：二进制包解开就该直接可用，bin/ 空说明前面哪一步出了问题。
    if [ ! -d "${target}/bin" ] || [ -z "$(ls -A "${target}/bin" 2>/dev/null)" ]; then
        Echo_Red "Error: ${target}/bin 不存在或为空，通用二进制包没有正确落地。"
        exit 1
    fi
    return 0
}


DB_Download_Files()
{
    local glibc name

    DB_Bin_Tarball=''
    [ "${DB_Kind}" = "none" ] && return 0

    cd ${cur_dir}/src

    case "${DB_Kind}" in
    mysql)
        if [ "${Bin}" = "y" ]; then
            glibc=$(DB_Bin_Glibc_Ver)
            # 5.5/5.6/5.7 是 .tar.gz，8.0+ 是 .tar.xz
            if Version_GE "${DB_Branch}" 8.0; then
                DB_Bin_Tarball="${Mysql_Ver}-linux-glibc${glibc}-${DB_ARCH}.tar.xz"
            else
                DB_Bin_Tarball="${Mysql_Ver}-linux-glibc${glibc}-${DB_ARCH}.tar.gz"
            fi
            Download_Files https://cdn.mysql.com/Downloads/MySQL-${DB_Branch}/${DB_Bin_Tarball} ${DB_Bin_Tarball}
            [ $? -ne 0 ] && Download_Files https://cdn.mysql.com/archives/mysql-${DB_Branch}/${DB_Bin_Tarball} ${DB_Bin_Tarball}
            Require_File "${DB_Bin_Tarball}" "MySQL ${DB_Branch} Generic Binaries"
        else
            Download_Files https://cdn.mysql.com/Downloads/MySQL-${DB_Branch}/${Mysql_Ver}.tar.gz ${Mysql_Ver}.tar.gz
            [ $? -ne 0 ] && Download_Files https://cdn.mysql.com/archives/mysql-${DB_Branch}/${Mysql_Ver}.tar.gz ${Mysql_Ver}.tar.gz
            Require_File "${Mysql_Ver}.tar.gz" "MySQL ${DB_Branch} source code"
        fi
        ;;
    mariadb)
        Mariadb_Version="${Mariadb_Ver#mariadb-}"
        if [ "${Bin}" = "y" ]; then
            name="${Mariadb_Ver}-linux-systemd-${DB_ARCH}"
            DB_Bin_Tarball="${name}.tar.gz"
        else
            name="${Mariadb_Ver}"
        fi
        Download_Files https://downloads.mariadb.org/rest-api/mariadb/${Mariadb_Version}/${name}.tar.gz ${name}.tar.gz
        Require_File "${name}.tar.gz" "MariaDB ${DB_Branch}"
        ;;
    esac
}

# ---------------------------------------------------------------------------
# DB_Toolchain_EL9 — EL9/EL10 及 Oracle 9 上为 MySQL 源码编译安装 gcc-toolset-12
#
# 原代码只判断 DBSelect=5（MySQL 8.0），漏掉了 11（MySQL 8.4），
# 导致 8.4 在 EL9+ 上源码编译拿不到工具链。改判 DB_Kind 后该 bug 消失。

# ---------------------------------------------------------------------------
DB_Toolchain_EL9()
{
    if [ "${Bin}" = "y" ] || [ "${DB_Kind}" != "mysql" ]; then
        return 0
    fi
    dnf install gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ gcc-toolset-12-binutils gcc-toolset-12-annobin-annocheck gcc-toolset-12-annobin-plugin-gcc -y
}

# ---------------------------------------------------------------------------
# 数据库升级的分步校验
#
# 三条升级路径（upgrade_mysql / upgrade_mariadb / upgrade_mysql2mariadb）都会
# 移走原数据目录、重建实例、再从 mysqldump 的输出恢复。原实现只在最后检查
# 二进制与 /etc/my.cnf 是否存在，备份截断、导入报错、升级工具失败都不影响
# 「upgrade completed」的输出，属于正常运营路径上的数据完整性风险。
#
# 以下函数供三条路径共用，任一项不通过即返回非零，由调用方中止并保留现场。
# ---------------------------------------------------------------------------

# 升级前的库列表快照路径。Upgrade_Date 由 upgrade.sh 在加载各模块之前设置；
# 其他入口加载本文件时该变量为空，但那些路径不会用到升级校验。
DB_List_Before="/root/db_list_before${Upgrade_Date}.txt"

# Check_DB_Backup — 确认备份文件可用
# $1 备份文件路径
#
# 只看 mysqldump 的退出码不足以判定备份完整：磁盘写满或进程被中断时，
# 重定向产生的文件依然存在且体积可观，但内容是截断的。mysqldump 正常结束
# 会在末尾写入 "-- Dump completed" 标记，以此区分。
Check_DB_Backup()
{
    local f="$1"

    if [ ! -s "${f}" ]; then
        Echo_Red "备份文件 ${f} 不存在或为空。"
        return 1
    fi
    if ! tail -5 "${f}" | grep -q -- "-- Dump completed"; then
        Echo_Red "备份文件 ${f} 缺少结束标记，内容可能已被截断。"
        return 1
    fi
    return 0
}

# Snapshot_DB_List — 记录当前库列表，供升级后比对
# $1 mysql 客户端路径  $2 输出文件
#
# 排除 information_schema / performance_schema / sys：这三个库由服务端按版本
# 自行维护，跨版本乃至 MySQL 与 MariaDB 之间的存在性并不一致，纳入比对会产生
# 与数据完整性无关的差异。mysql 库保留，账号与授权丢失同样属于升级事故。
Snapshot_DB_List()
{
    local bin="$1" out="$2"

    "${bin}" --defaults-file=~/.my.cnf -N -B -e "SHOW DATABASES;" 2>/dev/null \
        | grep -Ev '^(information_schema|performance_schema|sys)$' \
        | LC_ALL=C sort > "${out}"
    if [ ! -s "${out}" ]; then
        Echo_Red "无法读取升级前的数据库列表。"
        return 1
    fi
    return 0
}

# Verify_DB_Upgraded — 升级后验收
# $1 mysql 客户端路径  $2 升级前的库列表文件
# $3 经典协议端口（默认 3306）  $4 MySQL X Protocol 端口（MariaDB 留空）
#
# 依次确认服务可连接、库列表无缺失、本地监听基线未被重写的配置撤销。
Verify_DB_Upgraded()
{
    local bin="$1" before="$2" port="${3:-3306}" xport="${4:-}"
    local after missing actual_port actual_xport rc=0

    if ! "${bin}" --defaults-file=~/.my.cnf -e "SELECT 1;" >/dev/null 2>&1; then
        Echo_Red "升级后无法连接数据库。"
        return 1
    fi

    actual_port=$("${bin}" --defaults-file=~/.my.cnf -N -B -e "SELECT @@port;" 2>/dev/null)
    if [ "${actual_port}" != "${port}" ]; then
        Echo_Red "升级后数据库实际端口为 ${actual_port:-未知}，期望 ${port}。"
        rc=1
    fi
    if [ -n "${xport}" ]; then
        actual_xport=$("${bin}" --defaults-file=~/.my.cnf -N -B -e "SELECT @@mysqlx_port;" 2>/dev/null)
        if [ "${actual_xport}" != "${xport}" ]; then
            Echo_Red "升级后 MySQL X Protocol 实际端口为 ${actual_xport:-未知}，期望 ${xport}。"
            rc=1
        fi
    fi

    after=$(mktemp) || return 1
    if ! Snapshot_DB_List "${bin}" "${after}"; then
        rm -f "${after}"
        return 1
    fi
    # comm -23：只列出升级前存在、升级后缺失的库。升级后新增的库不算异常。
    missing=$(LC_ALL=C comm -23 "${before}" "${after}")
    rm -f "${after}"
    if [ -n "${missing}" ]; then
        Echo_Red "以下数据库在升级后缺失："
        printf '  %s\n' ${missing}
        rc=1
    fi

    # 升级会重写 /etc/my.cnf。此处确认 bind-address 确实生效，
    # 避免本地监听限制在升级过程中被静默撤销。
    if command -v ss >/dev/null 2>&1; then
        if ss -lnt 2>/dev/null | awk '{print $4}' \
            | grep -Eq "^(0\.0\.0\.0|\*|\[::\]):${port}$"; then
            Echo_Red "端口 ${port} 正在监听所有网卡，本地监听限制未生效。"
            Echo_Red "请检查 /etc/my.cnf 中的 bind-address 设置。"
            rc=1
        fi
    fi

    return ${rc}
}

# DB_Upgrade_Abort — 升级失败时统一提示保留现场
# $1 备份文件路径  $2 原实例的备份目录
DB_Upgrade_Abort()
{
    Echo_Red "======== 升级失败，已中止 ======"
    Echo_Red "数据备份：$1"
    Echo_Red "原实例目录：$2"
    Echo_Red "上述内容均未删除，可据此回滚。修复问题前请勿重复执行升级。"
    return 1
}

# ---------------------------------------------------------------------------
# 安装期数据库初始化的失败传递
#
# 原实现里，初始化 SQL（设 root 密码、清匿名账号、禁远程 root、删 test 库、
# 刷权限）每条只打印 Success/Failed，不影响任何返回值。客户端整体不可用时
# 六条全失败，安装照样打印 "Install lnmp V2.3 completed"，最终检查也只看
# mysqld 进程和文件在不在 —— 一台没做过任何安全初始化的库就这么交付了。
#
# 现在任一条失败即置 DB_Init_Failed='y'，由 end.sh 的 Check_DB_Init_Result
# 汇总成非零退出码，并逐条列出失败的步骤。
# ---------------------------------------------------------------------------
DB_Init_Failed='n'
DB_Init_Errors=''

# Check_DB_Client_Runnable <客户端路径>
#
# 官方通用二进制依赖的运行库不全时，客户端在动态链接阶段就退出，
# 之后每条初始化 SQL 都会失败。先单独探一次，把原始报错打在最前面，
# 免得后面五条 "Failed!" 掩盖真正的原因。
Check_DB_Client_Runnable()
{
    local bin="$1" out

    if ! out=$("${bin}" --version 2>&1); then
        Echo_Red "数据库客户端无法运行：${bin}"
        printf '%s\n' "${out}" | sed 's/^/  /'
        Echo_Red "常见原因是官方通用二进制所需的运行库缺失（如 libncurses.so.5 / libtinfo.so.5），"
        Echo_Red "Debian 系可参考 include/init.sh 的 Deb_Ncurses5_Compat 手工补齐。"
        DB_Init_Failed='y'
        DB_Init_Errors="${DB_Init_Errors}
  - 数据库客户端不可执行：${bin}"
        return 1
    fi
    return 0
}

# DB_Init_Step <步骤描述> <SQL>
DB_Init_Step()
{
    local desc="$1" sql="$2" out

    echo "${desc}..."
    if out=$(Do_Query "${sql}" 2>&1); then
        echo " ... Success."
        return 0
    fi
    echo " ... Failed!"
    [ -n "${out}" ] && printf '%s\n' "${out}" | sed 's/^/     /'
    DB_Init_Failed='y'
    DB_Init_Errors="${DB_Init_Errors}
  - ${desc}"
    return 1
}
