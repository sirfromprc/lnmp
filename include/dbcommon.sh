#!/usr/bin/env bash
#
# 数据库下载、二进制安装和升级校验的共享实现。

# Require_File 位于所有安装入口都会加载的 include/main.sh。

# 通用二进制包优先使用 profile.sh 指定的 glibc 版本，auto 默认使用 2.28。
DB_Bin_Glibc_Ver()
{
    if [ "${DB_Bin_Glibc}" = "auto" ]; then
        echo "2.28"
    else
        echo "${DB_Bin_Glibc}"
    fi
}


# MySQL 和 MariaDB 通用二进制需要 libaio.so.1。仅在动态库解析缺失时，
# 为兼容 ABI 的 64 位架构在 libaio.so.1t64 所在目录建立兼容链接。
Ensure_Libaio_Compat()
{
    local server_bin=$1 t64 link_dir link

    [ -x "${server_bin}" ] || return 0
    ldd "${server_bin}" 2>/dev/null | grep -q 'libaio\.so\.1 => not found' || return 0

    # 32 位 time_t 架构存在 ABI 差异，不能链接到 libaio.so.1t64。
    case "$(uname -m)" in
        x86_64|aarch64|ppc64le|s390x|riscv64|loongarch64) ;;
        *)
            Echo_Red "错误：当前架构 $(uname -m) 缺少 libaio.so.1，且不能安全使用 libaio.so.1t64。"
            Echo_Red "请安装提供 libaio.so.1 的软件包，或改用源码方式安装数据库。"
            return 1
            ;;
    esac

    t64=$(ldconfig -p 2>/dev/null | awk '$1 == "libaio.so.1t64" {print $NF; exit}')
    if [ -z "${t64}" ] || [ ! -e "${t64}" ]; then
        Echo_Red "错误：${server_bin} 需要 libaio.so.1，但系统里找不到可用的 libaio。"
        Echo_Red "请先安装 libaio（Debian/Ubuntu：libaio1 或 libaio1t64；RHEL 系：libaio），再重新安装。"
        return 1
    fi

    link_dir=$(dirname "${t64}")
    link="${link_dir}/libaio.so.1"

    # 不覆盖发行版提供的同名实体文件，避免替换系统库。
    if [ -e "${link}" ] && [ ! -L "${link}" ]; then
        Echo_Red "错误：${link} 已存在且不是符号链接，${server_bin} 仍无法加载 libaio.so.1。"
        Echo_Red "请手工确认该文件后重新安装。"
        return 1
    fi
    if ! ln -sf "$(basename "${t64}")" "${link}"; then
        Echo_Red "错误：创建 ${link} -> ${t64} 失败。"
        return 1
    fi
    ldconfig

    if ldd "${server_bin}" 2>/dev/null | grep -q 'libaio\.so\.1 => not found'; then
        Echo_Red "错误：已建立 ${link}，${server_bin} 仍然找不到 libaio.so.1。"
        return 1
    fi

    Echo_Green "当前发行版只提供 libaio.so.1t64，已建立 ${link} -> $(basename "${t64}")。"
    return 0
}

# 清理异常终止后遗留且无进程占用的数据库 socket。
# socket 路径以 /etc/my.cnf 的 [mysqld] 配置为准，正在使用时拒绝删除。
Clean_Stale_DB_Socket()
{
    local sock

    sock=$(awk -F= '/^[[:space:]]*\[/{sec=$0} \
                    sec ~ /\[mysqld\]/ && /^[[:space:]]*socket[[:space:]]*=/ \
                    {gsub(/[[:space:]]/, "", $2); print $2; exit}' \
           /etc/my.cnf 2>/dev/null)
    [ -n "${sock}" ] || sock=/tmp/mysql.sock
    [ -S "${sock}" ] || return 0

    if fuser "${sock}" >/dev/null 2>&1 \
       || ss -lxH 2>/dev/null | awk '{print $5}' | grep -qx "${sock}"; then
        Echo_Red "错误：${sock} 正在被进程使用，可能已有数据库实例在运行。"
        Echo_Red "请先停止该实例，确认无误后再重新安装。"
        return 1
    fi

    Echo_Yellow "清理残留的数据库 socket（没有进程在使用）：${sock}"
    rm -f "${sock}"
    return 0
}

Install_DB_Bin_Tarball()
{
    local tarball=$1 target=$2 topdir rc restore_dotglob server_bin

    # 同时支持 MySQL 的 .tar.xz 和 MariaDB 的 .tar.gz 文件名。
    topdir="${cur_dir}/src/${tarball%.tar.*}"

    Tar_Cd "${tarball}"

    if [ ! -d "${topdir}" ]; then
        Echo_Red "错误：${tarball} 解压后没有预期的目录 ${tarball%.tar.*}"
        Echo_Red "归档结构与预期不符（上游可能改了包内布局），拒绝继续安装。"
        exit 1
    fi

    if [ -e "${target}" ] && [ ! -d "${target}" ]; then
        Echo_Red "错误：${target} 已存在且不是目录，拒绝覆盖。"
        exit 1
    fi
    # 允许预先挂载的空目录，非空目录会造成新旧版本文件混合。
    if [ -d "${target}" ] && [ -n "$(ls -A "${target}" 2>/dev/null)" ]; then
        Echo_Red "错误：${target} 已存在且非空。"
        Echo_Red "直接往里放会得到一个新旧版本混合的安装，这里拒绝继续。"
        Echo_Red "请先确认该目录下是否还有数据，备份后移走或删除，再重新安装。"
        exit 1
    fi

    if ! mkdir -p "${target}"; then
        Echo_Red "错误：无法创建 ${target}"
        exit 1
    fi

    # dotglob 确保归档顶层的隐藏文件一并安装。
    restore_dotglob=0
    shopt -q dotglob || restore_dotglob=1
    shopt -s dotglob
    mv "${topdir}"/* "${target}"/
    rc=$?
    [ ${restore_dotglob} -eq 1 ] && shopt -u dotglob

    if [ ${rc} -ne 0 ]; then
        Echo_Red "错误：把 ${tarball%.tar.*} 移动到 ${target} 失败（磁盘空间不足或权限不足）。"
        Echo_Red "${target} 现在很可能是不完整的，请清空后重新安装。"
        exit 1
    fi

    # 通用二进制包安装后必须包含非空的 bin 目录。
    if [ ! -d "${target}/bin" ] || [ -z "$(ls -A "${target}/bin" 2>/dev/null)" ]; then
        Echo_Red "错误：${target}/bin 不存在或为空，通用二进制包没有正确安装。"
        exit 1
    fi

    # 初始化数据目录前确认服务端二进制所需动态库可用。
    for server_bin in "${target}/bin/mariadbd" "${target}/bin/mysqld"; do
        [ -x "${server_bin}" ] || continue
        Ensure_Libaio_Compat "${server_bin}" || exit 1
        break
    done
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
            # MySQL 8.0 及以上使用 .tar.xz，较早版本使用 .tar.gz。
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

# EL9、EL10 和 Oracle 9 上的 MySQL 源码编译使用 gcc-toolset-12。
DB_Toolchain_EL9()
{
    if [ "${Bin}" = "y" ] || [ "${DB_Kind}" != "mysql" ]; then
        return 0
    fi
    dnf install gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ gcc-toolset-12-binutils gcc-toolset-12-annobin-annocheck gcc-toolset-12-annobin-plugin-gcc -y
}

# 数据库升级的分步校验
# MySQL、MariaDB 及 MySQL 转 MariaDB 共用以下校验，任一失败均中止并保留现场。

# 升级前的数据库列表快照路径。
DB_List_Before="/root/db_list_before${Upgrade_Date}.txt"

# 检查备份非空且包含 mysqldump 结束标记，防止使用截断文件升级。
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

# 记录升级前数据库列表，排除由服务端按版本维护的系统库。
# mysql 库保留在快照中，用于检查账号和授权数据。
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

# 升级后检查连接、端口、数据库列表和本地监听限制。
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
    # 仅将升级后缺失的数据库视为异常，新增数据库不影响验收。
    missing=$(LC_ALL=C comm -23 "${before}" "${after}")
    rm -f "${after}"
    if [ -n "${missing}" ]; then
        Echo_Red "以下数据库在升级后缺失："
        printf '  %s\n' ${missing}
        rc=1
    fi

    # 确认升级后的 bind-address 未开放到所有网卡。
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

# 升级失败时显示保留的备份文件和原实例目录。
DB_Upgrade_Abort()
{
    Echo_Red "======== 升级失败，已中止 ======"
    Echo_Red "数据备份：$1"
    Echo_Red "原实例目录：$2"
    Echo_Red "上述内容均未删除，可据此回滚。修复问题前请勿重复执行升级。"
    return 1
}

# 数据库安全初始化任一步骤失败都会由 end.sh 汇总并使安装返回非零状态。
DB_Init_Failed='n'
DB_Init_Errors=''

# 初始化前检查数据库客户端能否运行，以直接显示缺失动态库等原始错误。
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

    echo "正在执行：${desc}..."
    if out=$(Do_Query "${sql}" 2>&1); then
        echo " ... 成功。"
        return 0
    fi
    echo " ... 失败。"
    [ -n "${out}" ] && printf '%s\n' "${out}" | sed 's/^/     /'
    DB_Init_Failed='y'
    DB_Init_Errors="${DB_Init_Errors}
  - ${desc}"
    return 1
}
