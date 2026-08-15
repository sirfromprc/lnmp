#!/usr/bin/env bash

# MariaDB_Branch — 返回当前操作的 MariaDB 主版本号（如 10.11 / 11.4）
# 安装路径由 Set_DB_Profile 设定 DB_Branch；升级路径只有用户输入的 mariadb_version。
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

# Install_MariaDB_Compat_Command <旧名称> <新名称> [源目录] [目标目录]
#
# 直接把 /usr/bin/mysql 软链到 mariadb 仍会把旧程序名传给 MariaDB，11.8
# 因而继续打印 Deprecated program name。包装器通过 exec 新名称消除提示，
# 同时完整保留参数、标准输入输出和退出码；新名称不存在时回退旧二进制。
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

# ---------------------------------------------------------------------------
# Rewrite_MariaDB_Initd_Names — 让 init 脚本改用 MariaDB 新程序名
#
# /etc/init.d/mariadb 是上游 support-files/mysql.server 的原样拷贝，内部按
# $bindir/mysqld_safe、$bindir/mysqladmin 调用。这两个路径直指
# /usr/local/mariadb/bin，绕过 Install_MariaDB_Command_Compat 在 /usr/bin 建立
# 的新名包装，于是每次启动服务都会往 stderr 打印：
#   /usr/local/mariadb/bin/mysqld_safe: Deprecated program name.
#   It will be removed in a future release, use 'mariadbd-safe' instead
# 提示本身只是噪声，但这些旧入口一旦被上游删除，服务就会直接起不来。
#
# 只在对应新名确实存在时替换，缺失时保留原样。
# ---------------------------------------------------------------------------
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
    local mariadb_client mariadb_admin

    cat > /etc/ld.so.conf.d/mariadb.conf<<EOF
    /usr/local/mariadb/lib
    /usr/local/lib
EOF
    ldconfig

    if [ -d "/proc/vz" ];then
        ulimit -s unlimited
    fi

    if [ -d "/etc/mysql" ]; then
        mv /etc/mysql /etc/mysql.backup.$(date +%Y%m%d)
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable mariadb.service
    fi
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
    mariadb_admin=$(First_Executable /usr/local/mariadb/bin/mariadb-admin /usr/local/mariadb/bin/mysqladmin) || {
        Echo_Red "找不到可执行的 MariaDB 管理客户端。"
        DB_Init_Failed='y'
        DB_Init_Errors="${DB_Init_Errors}
  - 检测 MariaDB 管理客户端"
        return 1
    }

    /etc/init.d/mariadb restart
    sleep 2

    # 客户端跑不起来时后面每一步都会失败，先探一次并置标记，理由同 mysql.sh。
    Check_DB_Client_Runnable "${mariadb_client}"

    # 指定 --defaults-file 使其只读 /etc/my.cnf，理由同 mysql.sh：
    # 残留的 ~/.my.cnf 会让客户端带旧密码连接。
    #
    # 与 mysql.sh 一样，这里失败还有下面的空密码分支兜底，报错先收起来。
    local first_error
    first_error=$("${mariadb_admin}" --defaults-file=/etc/my.cnf \
                  -u root password "${DB_Root_Password}" 2>&1)

    /etc/init.d/mariadb restart

    Make_TempMycnf "${DB_Root_Password}"
    Do_Query ""
    if [ $? -ne 0 ]; then
        echo "mysqladmin 方式未生效，改用空密码连接设置（安装流程的正常分支）。"
        [ -n "${first_error}" ] && echo "（mysqladmin 的报错留作诊断：${first_error}）"
        /etc/init.d/mariadb restart
        ( umask 077; cat >"${HOME}/.emptymy.cnf"<<EOF
[client]
user=root
password=''
socket=/tmp/mysql.sock
EOF
        )
        if "${mariadb_client}" --defaults-file="${HOME}/.emptymy.cnf" -e "SET PASSWORD = PASSWORD('$(SQL_Escape "${DB_Root_Password}")');"; then
            echo "root 密码设置成功。"
        else
            echo "root 密码设置失败！"
            DB_Init_Failed='y'
            DB_Init_Errors="${DB_Init_Errors}
  - 设置 root 密码"
        fi
        "${mariadb_client}" --defaults-file="${HOME}/.emptymy.cnf" -e "FLUSH PRIVILEGES;"
        [ $? -eq 0 ] && echo "权限表刷新成功。" || echo "权限表刷新失败！"
        rm -f "${HOME}/.emptymy.cnf"
    fi

    Do_Query ""
    if [ $? -eq 0 ]; then
        echo "数据库 root 密码验证通过。"
    fi
    # 「不存在」不是失败，理由同 mysql.sh。
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
    if [ -d "${MariaDB_Data_Dir}" ]; then
        datetime=$(date +"%Y%m%d%H%M%S")
        mkdir /root/mariadb-data-dir-backup${datetime}/
        \cp ${MariaDB_Data_Dir}/* /root/mariadb-data-dir-backup${datetime}/
        rm -rf ${MariaDB_Data_Dir}/*
    else
        mkdir -p ${MariaDB_Data_Dir}
    fi
}

# Install_MariaDB_1011 是唯一的真实实现，11.4 / 11.8 复用它。
# 10.11 / 11.4 / 11.8 的编译参数与目录布局完全一致。
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
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DMYSQL_UNIX_ADDR=/tmp/mysql.sock -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITHOUT_TOKUDB=1 ${MariaDBWITHSSL}
        Make_Install || exit 1
    fi

    groupadd mariadb
    useradd -s /sbin/nologin -M -g mariadb mariadb

cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = ${DB_Port}
socket      = /tmp/mysql.sock

[mysqld]
port        = ${DB_Port}
socket      = /tmp/mysql.sock
# 默认仅监听回环地址，避免数据库在安装完成后直接暴露到公网。
#
# 防火墙里虽然有一条 3306 drop，但那是第二道防线：nftables 缺失、
# 规则写入失败、或者管理员自己调整防火墙时，唯一还挡着的就是这一行。

#
# 确实需要远程连库时，改成具体地址（不要用 0.0.0.0），
# 同时在防火墙里按来源 IP 放行，并确认账号的 Host 授权范围。
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
    Check_MariaDB_Data_Dir
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
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    \cp ${cur_dir}/init.d/mariadb.service /etc/systemd/system/mariadb.service
    chmod 755 /etc/init.d/mariadb
    Rewrite_MariaDB_Initd_Names /etc/init.d/mariadb /usr/local/mariadb/bin

    Mariadb_Sec_Setting
}

Install_MariaDB_114()
{
    Install_MariaDB_1011
}

Install_MariaDB_118()
{
    Install_MariaDB_1011
}
