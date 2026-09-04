#!/usr/bin/env bash

# 返回当前操作的 MariaDB 主版本号；安装使用 DB_Branch，升级使用输入版本。
MariaDB_Branch()
{
    if [ "${DB_Kind}" = "mariadb" ] && [ -n "${DB_Branch}" ]; then
        echo "${DB_Branch}"
    elif [ -n "${mariadb_version}" ]; then
        echo "${mariadb_version}" | cut -d. -f1-2
    fi
}

MariaDB_WITHSSL()
{


    MariaDBWITHSSL=''
}

# 为旧命令名安装兼容入口。包装器调用 MariaDB 新命令名以避免弃用提示，
# 并保留参数、标准输入输出及退出码；缺少新名称时回退旧二进制。
Install_MariaDB_Compat_Command()
{
    local legacy="$1" canonical="$2"
    local source_dir="${3:-/usr/local/mariadb/bin}"
    local destination_dir="${4:-/usr/bin}"
    local target fallback destination tmp

    target="${source_dir}/${canonical}"
    fallback="${source_dir}/${legacy}"
    destination="${destination_dir}/${legacy}"

    [ -d "${destination_dir}" ] || return 1
    if [ -d "${destination}" ] && [ ! -L "${destination}" ]; then
        return 1
    fi

    if [ -x "${target}" ]; then
        tmp=$(mktemp "${destination}.lnmp.XXXXXXXX") || return 1
        if ! printf '%s\n' \
            '#!/bin/sh' \
            '# LNMP MariaDB compatibility wrapper' \
            "exec \"${target}\" \"\$@\"" > "${tmp}" \
            || ! chmod 755 "${tmp}" \
            || ! mv -f "${tmp}" "${destination}"; then
            rm -f "${tmp}"
            return 1
        fi
        return 0
    fi

    [ -x "${fallback}" ] || return 1
    ln -sfn "${fallback}" "${destination}"
}

Install_MariaDB_Canonical_Command()
{
    local command="$1"
    local source_dir="${2:-/usr/local/mariadb/bin}"
    local destination_dir="${3:-/usr/bin}"

    [ -x "${source_dir}/${command}" ] || return 0
    [ -d "${destination_dir}" ] || return 1
    if [ -d "${destination_dir}/${command}" ] && [ ! -L "${destination_dir}/${command}" ]; then
        return 1
    fi
    ln -sfn "${source_dir}/${command}" "${destination_dir}/${command}"
}

Install_MariaDB_Command_Compat()
{
    local source_dir="${1:-/usr/local/mariadb/bin}"
    local destination_dir="${2:-/usr/bin}"
    local command rc=0

    for command in mariadb mariadb-dump mariadb-admin mariadb-check mariadb-upgrade mariadbd-safe; do
        Install_MariaDB_Canonical_Command "${command}" "${source_dir}" "${destination_dir}" || rc=1
    done

    Install_MariaDB_Compat_Command mysql mariadb "${source_dir}" "${destination_dir}" || rc=1
    Install_MariaDB_Compat_Command mysqldump mariadb-dump "${source_dir}" "${destination_dir}" || rc=1
    Install_MariaDB_Compat_Command mysqladmin mariadb-admin "${source_dir}" "${destination_dir}" || rc=1
    Install_MariaDB_Compat_Command mysqlcheck mariadb-check "${source_dir}" "${destination_dir}" || rc=1
    Install_MariaDB_Compat_Command mysql_upgrade mariadb-upgrade "${source_dir}" "${destination_dir}" || rc=1
    Install_MariaDB_Compat_Command mysqld_safe mariadbd-safe "${source_dir}" "${destination_dir}" || rc=1

    if [ -x "${source_dir}/myisamchk" ]; then
        ln -sfn "${source_dir}/myisamchk" "${destination_dir}/myisamchk" || rc=1
    fi
    return ${rc}
}

# 上游 init 脚本仍可能调用弃用的 mysqld_safe 和 mysqladmin。新命令存在时
# 替换对应入口，避免弃用提示并兼容后续移除旧命令的 MariaDB 版本。
Rewrite_MariaDB_Initd_Names()
{
    local initd=${1:-/etc/init.d/mariadb}
    local bindir=${2:-/usr/local/mariadb/bin}

    [ -f "${initd}" ] || return 0

    if [ -x "${bindir}/mariadbd-safe" ]; then
        sed -i 's|\$bindir/mysqld_safe|$bindir/mariadbd-safe|g' "${initd}" || return 1
    fi
    if [ -x "${bindir}/mariadb-admin" ]; then
        sed -i 's|\$bindir/mysqladmin|$bindir/mariadb-admin|g' "${initd}" || return 1
    fi
    return 0
}

Mariadb_Sec_Setting()
{
    local mariadb_client

    cat > /etc/ld.so.conf.d/mariadb.conf<<EOF
    /usr/local/mariadb/lib
    /usr/local/lib
EOF
    ldconfig

    if [ -d "/proc/vz" ];then
        ulimit -s unlimited
    fi

    if [ -d "/etc/mysql" ]; then
        mv /etc/mysql "/etc/mysql.backup.$(date +%Y%m%d)"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable mariadb.service
    fi
    Ensure_Runtime_Directory /run/mysqld mariadb mariadb || return 1
    Clean_Stale_DB_Socket || return 1
    StartUp mariadb
    /etc/init.d/mariadb start

    if ! Install_MariaDB_Command_Compat; then
        Echo_Red "MariaDB 命令兼容入口安装失败。"
        DB_Init_Failed='y'
        DB_Init_Errors="${DB_Init_Errors}
  - 安装 MariaDB 命令兼容入口"
    fi

    mariadb_client=$(First_Executable /usr/local/mariadb/bin/mariadb /usr/local/mariadb/bin/mysql) || {
        Echo_Red "找不到可执行的 MariaDB 客户端。"
        DB_Init_Failed='y'
        DB_Init_Errors="${DB_Init_Errors}
  - 检测 MariaDB 客户端"
        return 1
    }
    /etc/init.d/mariadb restart
    sleep 2

    # 安全初始化依赖可用的客户端，因此在执行 SQL 前先验证运行能力。
    Check_DB_Client_Runnable "${mariadb_client}"

    # root 密码已在禁网私有 socket 上设置；正式实例只做登录与权限收尾。
    Make_TempMycnf "${DB_Root_Password}"
    Do_Query ""
    if [ $? -eq 0 ]; then
        echo "数据库 root 密码验证通过。"
    fi
    # 目标账号或测试库不存在时无需报错，安全状态已满足要求。
    DB_Init_Step "删除匿名用户" \
        "DELETE FROM mysql.user WHERE User='';"
    DB_Init_Step "禁止 root 远程登录" \
        "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    DB_Init_Step "删除测试数据库" \
        "DROP DATABASE IF EXISTS test;"
    DB_Init_Step "刷新权限表" \
        "FLUSH PRIVILEGES;"

    /etc/init.d/mariadb stop
}

Check_MariaDB_Data_Dir()
{
    local datetime backup_dir started_at kept
    if [ -d "${MariaDB_Data_Dir}" ]; then
        # 已有数据目录非空说明机器上存在实际数据库，重装会让它与运行中的服务分离。
        # 默认拒绝，必须显式确认后才搬走；任何情况下都不删除数据。
        if [ -n "$(ls -A -- "${MariaDB_Data_Dir}" 2>/dev/null)" ] &&
           [ "${LNMP_Move_Existing_DB_Data:-}" != "yes" ]; then
            # 进度标记记到 db 阶段，说明该目录是上次未完成安装留下的，而非在用数据库。
            if [ "$(Install_Progress_Get stage 2>/dev/null)" = "db" ] &&
               started_at=$(Install_Progress_Get started 2>/dev/null); then
                Echo_Red "数据目录 ${MariaDB_Data_Dir} 非空，来自 ${started_at} 开始的那次未完成安装。"
                Echo_Red "该目录不会被删除，但需要确认后才能搬走并新建空实例，已中止。"
            else
                Echo_Red "数据目录 ${MariaDB_Data_Dir} 已存在且非空，里面可能是正在使用的数据库。"
                Echo_Red "本次安装会把它整体搬到 /root 下再新建空实例，不会删除数据，"
                Echo_Red "但运行中的服务会与数据分离，已中止。"
            fi
            Echo_Yellow "确认要重装并搬走现有数据时，显式声明后重试："
            echo
            echo "  LNMP_Move_Existing_DB_Data=yes bash install.sh ${Stack:-db}"
            Echo_Yellow "只想保留现有数据库时不要重装，直接使用现有实例即可。"
            return 1
        fi
        datetime=$(date +"%Y%m%d%H%M%S")
        backup_dir="/root/mariadb-data-dir-backup${datetime}"
        if [ -e "${backup_dir}" ] || ! mv -- "${MariaDB_Data_Dir}" "${backup_dir}"; then
            Echo_Red "MariaDB 数据目录备份失败，未清理原目录：${MariaDB_Data_Dir}"
            return 1
        fi
        if ! mkdir -p -- "${MariaDB_Data_Dir}"; then
            Echo_Red "无法重新创建 MariaDB 数据目录；原数据保留在 ${backup_dir}。"
            return 1
        fi
        Echo_Green "原 MariaDB 数据目录已完整移动到 ${backup_dir}。"
        # 反复中断重装会不断累积备份目录，这里只提示，不自动删除任何数据。
        kept=$(ls -d /root/mariadb-data-dir-backup* 2>/dev/null | wc -l)
        if [ "${kept}" -gt 1 ]; then
            Echo_Yellow "/root 下已有 ${kept} 份 mariadb-data-dir-backup* 目录，确认无用后请自行删除。"
        fi
    else
        mkdir -p -- "${MariaDB_Data_Dir}" || return 1
    fi
}

# MariaDB 10.11、11.4 和 11.8 使用相同的编译参数与目录布局。
Install_MariaDB_1011()
{
    local install_db

    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] 正在使用官方通用二进制包安装 ${Mariadb_Ver}..."
        Install_DB_Bin_Tarball "${DB_Bin_Tarball}" /usr/local/mariadb
    else
        Echo_Blue "[+] 正在使用源码安装 ${Mariadb_Ver}..."
        rm -f /etc/my.cnf
        Tar_Cd ${Mariadb_Ver}.tar.gz ${Mariadb_Ver}
        MariaDB_WITHSSL
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DMYSQL_UNIX_ADDR=/run/mysqld/mysqld.sock -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITHOUT_TOKUDB=1 ${MariaDBWITHSSL}
        Make_Install || exit 1
    fi

    groupadd mariadb
    useradd -s /sbin/nologin -M -g mariadb mariadb

cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = ${DB_Port}
socket      = /run/mysqld/mysqld.sock

[mysqld]
port        = ${DB_Port}
socket      = /run/mysqld/mysqld.sock
# 仅监听回环地址，防止防火墙失效时数据库直接暴露到公网。
# 远程访问应绑定具体地址，并按来源 IP 配置防火墙和账号 Host 权限。
bind-address = 127.0.0.1
user    = mariadb
basedir = /usr/local/mariadb
datadir = ${MariaDB_Data_Dir}
log_error = ${MariaDB_Data_Dir}/mariadb.err
pid-file = ${MariaDB_Data_Dir}/mariadb.pid
skip-external-locking
key_buffer_size = 16M
max_allowed_packet = 1M
table_open_cache = 64
sort_buffer_size = 512K
net_buffer_length = 8K
read_buffer_size = 256K
read_rnd_buffer_size = 512K
myisam_sort_buffer_size = 8M
thread_cache_size = 8
query_cache_size = 8M
tmp_table_size = 16M

explicit_defaults_for_timestamp = true
#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535

log-bin=mysql-bin
binlog_format=mixed
server-id   = 1
expire_logs_days = 10

default_storage_engine = InnoDB
#innodb_file_per_table = 1
#innodb_data_home_dir = ${MariaDB_Data_Dir}
#innodb_data_file_path = ibdata1:10M:autoextend
#innodb_log_group_home_dir = ${MariaDB_Data_Dir}
#innodb_buffer_pool_size = 16M
#innodb_log_file_size = 5M
#innodb_log_buffer_size = 8M
#innodb_flush_log_at_trx_commit = 1
#innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer = 2M
write_buffer = 2M

[mysqlhotcopy]
interactive-timeout

${MySQLMAOpt}
EOF
    if [ "${InstallInnodb}" = "y" ]; then
        sed -i 's/^#innodb/innodb/g' /etc/my.cnf
    else
        sed -i '/^default_storage_engine/d' /etc/my.cnf
        sed -i 's/^#loose-innodb/loose-innodb/g' /etc/my.cnf
        sed -i '/skip-external-locking/i\default_storage_engine = MyISAM\nloose-skip-innodb' /etc/my.cnf
    fi
    MySQL_Opt
    Check_MariaDB_Data_Dir || return 1
    chown -R mariadb:mariadb /usr/local/mariadb
    install_db=$(First_Executable \
        /usr/local/mariadb/scripts/mariadb-install-db \
        /usr/local/mariadb/scripts/mysql_install_db \
        /usr/local/mariadb/bin/mariadb-install-db \
        /usr/local/mariadb/bin/mysql_install_db) || {
        Echo_Red "找不到 MariaDB 初始化程序。"
        return 1
    }
    "${install_db}" --defaults-file=/etc/my.cnf --basedir=/usr/local/mariadb \
        --datadir="${MariaDB_Data_Dir}" --user=mariadb || return 1
    chown -R mariadb:mariadb ${MariaDB_Data_Dir}
    Secure_Initial_DB_Password mariadb mariadb || return 1
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    Install_Systemd_Unit "${cur_dir}/init.d/mariadb.service" /etc/systemd/system/mariadb.service || return 1
    chmod 755 /etc/init.d/mariadb
    Rewrite_MariaDB_Initd_Names /etc/init.d/mariadb /usr/local/mariadb/bin
    Patch_Init_Runtime_Directory /etc/init.d/mariadb /run/mysqld mariadb mariadb || return 1

    Mariadb_Sec_Setting || return 1
}

Install_MariaDB_114()
{
    Install_MariaDB_1011
}

Install_MariaDB_118()
{
    Install_MariaDB_1011
}
