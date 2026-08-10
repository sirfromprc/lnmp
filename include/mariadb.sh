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

Mariadb_Sec_Setting()
{
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
    StartUp mariadb
    /etc/init.d/mariadb start

    ln -sf /usr/local/mariadb/bin/mysql /usr/bin/mysql
    ln -sf /usr/local/mariadb/bin/mysqldump /usr/bin/mysqldump
    ln -sf /usr/local/mariadb/bin/myisamchk /usr/bin/myisamchk
    ln -sf /usr/local/mariadb/bin/mysqld_safe /usr/bin/mysqld_safe
    ln -sf /usr/local/mariadb/bin/mysqlcheck /usr/bin/mysqlcheck

    /etc/init.d/mariadb restart
    sleep 2

    # 客户端跑不起来时后面每一步都会失败，先探一次并置标记，理由同 mysql.sh。
    Check_DB_Client_Runnable /usr/local/mariadb/bin/mysql

    # 指定 --defaults-file 使其只读 /etc/my.cnf，理由同 mysql.sh：
    # 残留的 ~/.my.cnf 会让客户端带旧密码连接。
    #
    # 与 mysql.sh 一样，这里失败还有下面的空密码分支兜底，报错先收起来。
    local first_error
    first_error=$(/usr/local/mariadb/bin/mysqladmin --defaults-file=/etc/my.cnf \
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
        if /usr/local/mariadb/bin/mysql --defaults-file="${HOME}/.emptymy.cnf" -e "SET PASSWORD = PASSWORD('$(SQL_Escape "${DB_Root_Password}")');"; then
            echo "Set password Sucessfully."
        else
            echo "Set password failed!"
            DB_Init_Failed='y'
            DB_Init_Errors="${DB_Init_Errors}
  - 设置 root 密码"
        fi
        /usr/local/mariadb/bin/mysql --defaults-file="${HOME}/.emptymy.cnf" -e "FLUSH PRIVILEGES;"
        [ $? -eq 0 ] && echo "FLUSH PRIVILEGES Sucessfully." || echo "FLUSH PRIVILEGES failed!"
        rm -f "${HOME}/.emptymy.cnf"
    fi

    Do_Query ""
    if [ $? -eq 0 ]; then
        echo "OK, MySQL root password correct."
    fi
    # 「不存在」不是失败，理由同 mysql.sh。
    DB_Init_Step "Remove anonymous users" \
        "DELETE FROM mysql.user WHERE User='';"
    DB_Init_Step "Disallow root login remotely" \
        "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    DB_Init_Step "Remove test database" \
        "DROP DATABASE IF EXISTS test;"
    DB_Init_Step "Reload privilege tables" \
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
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Generic Binaries..."
        Install_DB_Bin_Tarball "${DB_Bin_Tarball}" /usr/local/mariadb
    else
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Source code..."
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
port        = 3306
socket      = /tmp/mysql.sock

[mysqld]
port        = 3306
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
    /usr/local/mariadb/scripts/mysql_install_db --defaults-file=/etc/my.cnf --basedir=/usr/local/mariadb --datadir=${MariaDB_Data_Dir} --user=mariadb
    chown -R mariadb:mariadb ${MariaDB_Data_Dir}
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    \cp ${cur_dir}/init.d/mariadb.service /etc/systemd/system/mariadb.service
    chmod 755 /etc/init.d/mariadb

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
