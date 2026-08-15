#!/usr/bin/env bash

# 返回当前操作的 MySQL 主版本号；安装使用 DB_Branch，升级使用输入版本。
MySQL_Branch()
{
    if [ "${DB_Kind}" = "mysql" ] && [ -n "${DB_Branch}" ]; then
        echo "${DB_Branch}"
    elif [ -n "${mysql_version}" ]; then
        echo "${mysql_version}" | cut -d. -f1-2
    fi
}

MySQL_Sec_Setting()
{
    if [ -d "/proc/vz" ]; then
        ulimit -s unlimited
    fi

    if [ -d "/etc/mysql" ]; then
        mv /etc/mysql /etc/mysql.backup.$(date +%Y%m%d)
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable mysql.service
    fi
    Clean_Stale_DB_Socket || return 1
    /etc/init.d/mysql start

    ln -sf /usr/local/mysql/bin/mysql /usr/bin/mysql
    ln -sf /usr/local/mysql/bin/mysqldump /usr/bin/mysqldump
    ln -sf /usr/local/mysql/bin/myisamchk /usr/bin/myisamchk
    ln -sf /usr/local/mysql/bin/mysqld_safe /usr/bin/mysqld_safe
    ln -sf /usr/local/mysql/bin/mysqlcheck /usr/bin/mysqlcheck

    /etc/init.d/mysql restart
    sleep 2

    # 安全初始化依赖可用的客户端，因此在执行 SQL 前先验证运行能力。
    Check_DB_Client_Runnable /usr/local/mysql/bin/mysql

    # 仅加载 /etc/my.cnf，避免残留的 ~/.my.cnf 携带旧密码。第一种设置方式
    # 失败时尝试空密码连接，两种方式均失败才显示原始错误。
    local first_error
    first_error=$(/usr/local/mysql/bin/mysqladmin --defaults-file=/etc/my.cnf \
                  -u root password "${DB_Root_Password}" 2>&1)
    if [ $? -ne 0 ]; then
        echo "mysqladmin 方式未生效，改用空密码连接设置（安装流程的正常分支）。"
        /etc/init.d/mysql restart
        ( umask 077; cat >"${HOME}/.emptymy.cnf"<<EOF
[client]
user=root
password=''
socket=/tmp/mysql.sock
EOF
        )
        if /usr/local/mysql/bin/mysql --defaults-file="${HOME}/.emptymy.cnf" \
             -e "SET PASSWORD FOR 'root'@'localhost' = '$(SQL_Escape "${DB_Root_Password}")';"; then
            echo "root 密码设置成功。"
        else
            Echo_Red "root 密码设置失败，两种方式均未成功。"
            Echo_Red "mysqladmin 的报错：${first_error}"
            DB_Init_Failed='y'
            DB_Init_Errors="${DB_Init_Errors}
  - 设置 root 密码"
        fi
        rm -f "${HOME}/.emptymy.cnf"
    fi
    /etc/init.d/mysql restart

    Make_TempMycnf "${DB_Root_Password}"
    Do_Query ""
    if [ $? -eq 0 ]; then
        echo "MySQL root 密码验证通过。"
    fi
    DB_Init_Step "更新 root 密码" \
        "SET PASSWORD FOR 'root'@'localhost' = '$(SQL_Escape "${DB_Root_Password}")';"
    DB_Init_Step "删除匿名用户" \
        "DELETE FROM mysql.user WHERE User='';"
    DB_Init_Step "禁止 root 远程登录" \
        "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    DB_Init_Step "删除测试数据库" \
        "DROP DATABASE IF EXISTS test;"
    DB_Init_Step "刷新权限表" \
        "FLUSH PRIVILEGES;"

    /etc/init.d/mysql restart
    /etc/init.d/mysql stop
}

MySQL_Opt()
{
    if [[ ${MemTotal} -gt 1024 && ${MemTotal} -lt 2048 ]]; then
        sed -i "s#^key_buffer_size.*#key_buffer_size = 32M#" /etc/my.cnf
        sed -i "s#^table_open_cache.*#table_open_cache = 128#" /etc/my.cnf
        sed -i "s#^sort_buffer_size.*#sort_buffer_size = 768K#" /etc/my.cnf
        sed -i "s#^read_buffer_size.*#read_buffer_size = 768K#" /etc/my.cnf
        sed -i "s#^myisam_sort_buffer_size.*#myisam_sort_buffer_size = 8M#" /etc/my.cnf
        sed -i "s#^thread_cache_size.*#thread_cache_size = 16#" /etc/my.cnf
        sed -i "s#^query_cache_size.*#query_cache_size = 16M#" /etc/my.cnf
        sed -i "s#^tmp_table_size.*#tmp_table_size = 32M#" /etc/my.cnf
        sed -i "s#^innodb_buffer_pool_size.*#innodb_buffer_pool_size = 128M#" /etc/my.cnf
        sed -i "s#^innodb_log_file_size.*#innodb_log_file_size = 32M#" /etc/my.cnf
        sed -i "s#^performance_schema_max_table_instances.*#performance_schema_max_table_instances = 1000#" /etc/my.cnf
    elif [[ ${MemTotal} -ge 2048 && ${MemTotal} -lt 4096 ]]; then
        sed -i "s#^key_buffer_size.*#key_buffer_size = 64M#" /etc/my.cnf
        sed -i "s#^table_open_cache.*#table_open_cache = 256#" /etc/my.cnf
        sed -i "s#^sort_buffer_size.*#sort_buffer_size = 1M#" /etc/my.cnf
        sed -i "s#^read_buffer_size.*#read_buffer_size = 1M#" /etc/my.cnf
        sed -i "s#^myisam_sort_buffer_size.*#myisam_sort_buffer_size = 16M#" /etc/my.cnf
        sed -i "s#^thread_cache_size.*#thread_cache_size = 32#" /etc/my.cnf
        sed -i "s#^query_cache_size.*#query_cache_size = 32M#" /etc/my.cnf
        sed -i "s#^tmp_table_size.*#tmp_table_size = 64M#" /etc/my.cnf
        sed -i "s#^innodb_buffer_pool_size.*#innodb_buffer_pool_size = 256M#" /etc/my.cnf
        sed -i "s#^innodb_log_file_size.*#innodb_log_file_size = 64M#" /etc/my.cnf
        sed -i "s#^performance_schema_max_table_instances.*#performance_schema_max_table_instances = 2000#" /etc/my.cnf
    elif [[ ${MemTotal} -ge 4096 && ${MemTotal} -lt 8192 ]]; then
        sed -i "s#^key_buffer_size.*#key_buffer_size = 128M#" /etc/my.cnf
        sed -i "s#^table_open_cache.*#table_open_cache = 512#" /etc/my.cnf
        sed -i "s#^sort_buffer_size.*#sort_buffer_size = 2M#" /etc/my.cnf
        sed -i "s#^read_buffer_size.*#read_buffer_size = 2M#" /etc/my.cnf
        sed -i "s#^myisam_sort_buffer_size.*#myisam_sort_buffer_size = 32M#" /etc/my.cnf
        sed -i "s#^thread_cache_size.*#thread_cache_size = 64#" /etc/my.cnf
        sed -i "s#^query_cache_size.*#query_cache_size = 64M#" /etc/my.cnf
        sed -i "s#^tmp_table_size.*#tmp_table_size = 64M#" /etc/my.cnf
        sed -i "s#^innodb_buffer_pool_size.*#innodb_buffer_pool_size = 512M#" /etc/my.cnf
        sed -i "s#^innodb_log_file_size.*#innodb_log_file_size = 128M#" /etc/my.cnf
        sed -i "s#^performance_schema_max_table_instances.*#performance_schema_max_table_instances = 4000#" /etc/my.cnf
    elif [[ ${MemTotal} -ge 8192 && ${MemTotal} -lt 16384 ]]; then
        sed -i "s#^key_buffer_size.*#key_buffer_size = 256M#" /etc/my.cnf
        sed -i "s#^table_open_cache.*#table_open_cache = 1024#" /etc/my.cnf
        sed -i "s#^sort_buffer_size.*#sort_buffer_size = 4M#" /etc/my.cnf
        sed -i "s#^read_buffer_size.*#read_buffer_size = 4M#" /etc/my.cnf
        sed -i "s#^myisam_sort_buffer_size.*#myisam_sort_buffer_size = 64M#" /etc/my.cnf
        sed -i "s#^thread_cache_size.*#thread_cache_size = 128#" /etc/my.cnf
        sed -i "s#^query_cache_size.*#query_cache_size = 128M#" /etc/my.cnf
        sed -i "s#^tmp_table_size.*#tmp_table_size = 128M#" /etc/my.cnf
        sed -i "s#^innodb_buffer_pool_size.*#innodb_buffer_pool_size = 1024M#" /etc/my.cnf
        sed -i "s#^innodb_log_file_size.*#innodb_log_file_size = 256M#" /etc/my.cnf
        sed -i "s#^performance_schema_max_table_instances.*#performance_schema_max_table_instances = 6000#" /etc/my.cnf
    elif [[ ${MemTotal} -ge 16384 && ${MemTotal} -lt 32768 ]]; then
        sed -i "s#^key_buffer_size.*#key_buffer_size = 512M#" /etc/my.cnf
        sed -i "s#^table_open_cache.*#table_open_cache = 2048#" /etc/my.cnf
        sed -i "s#^sort_buffer_size.*#sort_buffer_size = 8M#" /etc/my.cnf
        sed -i "s#^read_buffer_size.*#read_buffer_size = 8M#" /etc/my.cnf
        sed -i "s#^myisam_sort_buffer_size.*#myisam_sort_buffer_size = 128M#" /etc/my.cnf
        sed -i "s#^thread_cache_size.*#thread_cache_size = 256#" /etc/my.cnf
        sed -i "s#^query_cache_size.*#query_cache_size = 256M#" /etc/my.cnf
        sed -i "s#^tmp_table_size.*#tmp_table_size = 256M#" /etc/my.cnf
        sed -i "s#^innodb_buffer_pool_size.*#innodb_buffer_pool_size = 2048M#" /etc/my.cnf
        sed -i "s#^innodb_log_file_size.*#innodb_log_file_size = 512M#" /etc/my.cnf
        sed -i "s#^performance_schema_max_table_instances.*#performance_schema_max_table_instances = 8000#" /etc/my.cnf
    elif [[ ${MemTotal} -ge 32768 ]]; then
        sed -i "s#^key_buffer_size.*#key_buffer_size = 1024M#" /etc/my.cnf
        sed -i "s#^table_open_cache.*#table_open_cache = 4096#" /etc/my.cnf
        sed -i "s#^sort_buffer_size.*#sort_buffer_size = 16M#" /etc/my.cnf
        sed -i "s#^read_buffer_size.*#read_buffer_size = 16M#" /etc/my.cnf
        sed -i "s#^myisam_sort_buffer_size.*#myisam_sort_buffer_size = 256M#" /etc/my.cnf
        sed -i "s#^thread_cache_size.*#thread_cache_size = 512#" /etc/my.cnf
        sed -i "s#^query_cache_size.*#query_cache_size = 512M#" /etc/my.cnf
        sed -i "s#^tmp_table_size.*#tmp_table_size = 512M#" /etc/my.cnf
        sed -i "s#^innodb_buffer_pool_size.*#innodb_buffer_pool_size = 4096M#" /etc/my.cnf
        sed -i "s#^innodb_log_file_size.*#innodb_log_file_size = 1024M#" /etc/my.cnf
        sed -i "s#^performance_schema_max_table_instances.*#performance_schema_max_table_instances = 10000#" /etc/my.cnf
    fi
}

# 将 /etc/my.cnf 中 MySQL 8.4 弃用项转换为等价配置：
#   binlog_format            8.4 只剩 ROW 一种取值，显式设置已无意义
#   innodb_log_file_size     \ 两项合并为 innodb_redo_log_capacity
#   innodb_log_files_in_group/  （8.0.30 引入，8.4 起是唯一的配置方式）
# MySQL_Opt 先按内存确定日志文件大小，再按两个日志文件换算 redo 总容量。
# 只对 8.4 及以上生效；8.0 仍然接受旧写法，不动它以免影响既有实例的行为。
MySQL_Deprecated_Opt()
{
    local branch size num unit

    # 升级时以目标版本为准，避免使用安装配置中的旧分支。
    if [ -n "${mysql_version:-}" ]; then
        branch=$(echo "${mysql_version}" | cut -d. -f1-2)
    else
        branch=$(MySQL_Branch)
    fi
    [ -n "${branch}" ] || return 0
    Version_GE "${branch}" 8.4 || return 0
    [ -s /etc/my.cnf ] || return 0

    size=$(awk -F= '/^innodb_log_file_size/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' /etc/my.cnf)
    num=${size%[MGmg]}
    unit=${size#"${num}"}
    # 无法解析日志大小时使用 MySQL 默认的 100M redo 总容量。
    if [ -z "${num}" ] || echo "${num}" | grep -qv '^[0-9]\+$'; then
        num=50
        unit=M
    fi
    [ -z "${unit}" ] && unit=M

    sed -i "s#^innodb_log_file_size.*#innodb_redo_log_capacity = $((num * 2))${unit}#" /etc/my.cnf
    sed -i '/^innodb_log_files_in_group/d' /etc/my.cnf
    # MySQL 8.4 的 binlog_format 仅支持默认值 ROW，无需显式配置。
    sed -i '/^binlog_format/d' /etc/my.cnf
}

Check_MySQL_Data_Dir()
{
    if [ -d "${MySQL_Data_Dir}" ]; then
        datetime=$(date +"%Y%m%d%H%M%S")
        mkdir -p /root/mysql-data-dir-backup${datetime}/
        \cp ${MySQL_Data_Dir}/* /root/mysql-data-dir-backup${datetime}/
        rm -rf ${MySQL_Data_Dir}/*
    else
        mkdir -p ${MySQL_Data_Dir}
    fi
}

Install_MySQL_80()
{
    rm -f /etc/my.cnf
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] 正在使用官方通用二进制包安装 ${Mysql_Ver}..."
        Install_DB_Bin_Tarball "${DB_Bin_Tarball}" /usr/local/mysql
    else
        Echo_Blue "[+] 正在使用源码安装 ${Mysql_Ver}..."
        Tar_Cd ${Mysql_Ver}.tar.gz ${Mysql_Ver}
        Install_Boost
        # Boost 准备完成后返回 MySQL 源码目录继续构建。
        cd "${cur_dir}/src/${Mysql_Ver}" || exit 1
        mkdir build && cd build
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local/mysql -DSYSCONFDIR=/etc -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 ${MySQL_WITH_BOOST}
        Make_Install || exit 1
    fi

    groupadd mysql
    useradd -s /sbin/nologin -M -g mysql mysql
    cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = ${DB_Port}
socket      = /tmp/mysql.sock

[mysqld]
port        = ${DB_Port}
socket      = /tmp/mysql.sock
# 仅监听回环地址，防止防火墙失效时数据库直接暴露到公网。
# 远程访问应绑定具体地址，并按来源 IP 配置防火墙和账号 Host 权限。
bind-address = 127.0.0.1
# X Protocol 使用独立监听地址；loose- 前缀兼容已关闭 X Plugin 的配置。
loose-mysqlx-bind-address = 127.0.0.1
loose-mysqlx-port = ${DB_X_Port}
datadir = ${MySQL_Data_Dir}
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
tmp_table_size = 16M
performance_schema_max_table_instances = 500

explicit_defaults_for_timestamp = true
#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535
default_authentication_plugin = mysql_native_password

log-bin=mysql-bin
binlog_format=mixed
server-id   = 1
binlog_expire_logs_seconds = 864000
early-plugin-load = ""

default_storage_engine = InnoDB
innodb_file_per_table = 1
innodb_data_home_dir = ${MySQL_Data_Dir}
innodb_data_file_path = ibdata1:10M:autoextend
innodb_log_group_home_dir = ${MySQL_Data_Dir}
innodb_buffer_pool_size = 16M
innodb_log_file_size = 5M
innodb_log_buffer_size = 8M
innodb_flush_log_at_trx_commit = 1
innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer_size = 2M
write_buffer_size = 2M

[mysqlhotcopy]
interactive-timeout

${MySQLMAOpt}
EOF

    MySQL_Opt
    # MySQL 8.4 及以上转换弃用配置，8.0 保持原配置。
    MySQL_Deprecated_Opt
    Check_MySQL_Data_Dir
    chown -R mysql:mysql /usr/local/mysql
    # 数据目录初始化失败时停止，避免继续执行无效的启动和安全设置。
    if ! /usr/local/mysql/bin/mysqld --initialize-insecure --basedir=/usr/local/mysql --datadir=${MySQL_Data_Dir} --user=mysql; then
        Echo_Red "MySQL 数据目录初始化失败：${MySQL_Data_Dir}"
        Echo_Red "请根据上面 mysqld 的报错处理后重新安装。"
        return 1
    fi
    chown -R mysql:mysql ${MySQL_Data_Dir}
    \cp /usr/local/mysql/support-files/mysql.server /etc/init.d/mysql
    \cp ${cur_dir}/init.d/mysql.service /etc/systemd/system/mysql.service
    chmod 755 /etc/init.d/mysql
    cat > /etc/ld.so.conf.d/mysql.conf<<EOF
    /usr/local/mysql/lib
    /usr/local/lib
EOF
    ldconfig
    ln -sf /usr/local/mysql/lib/mysql /usr/lib/mysql
    ln -sf /usr/local/mysql/include/mysql /usr/include/mysql

    MySQL_Sec_Setting
}

Install_MySQL_84()
{
    rm -f /etc/my.cnf
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] 正在使用官方通用二进制包安装 ${Mysql_Ver}..."
        Install_DB_Bin_Tarball "${DB_Bin_Tarball}" /usr/local/mysql
    else
        Echo_Blue "[+] 正在使用源码安装 ${Mysql_Ver}..."
        Tar_Cd ${Mysql_Ver}.tar.gz ${Mysql_Ver}
        Install_Boost
        # Boost 准备完成后返回 MySQL 源码目录继续构建。
        cd "${cur_dir}/src/${Mysql_Ver}" || exit 1
        mkdir build && cd build
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local/mysql -DSYSCONFDIR=/etc -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 ${MySQL_WITH_BOOST}
        Make_Install || exit 1
    fi

    groupadd mysql
    useradd -s /sbin/nologin -M -g mysql mysql
    cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = ${DB_Port}
socket      = /tmp/mysql.sock

[mysqld]
port        = ${DB_Port}
socket      = /tmp/mysql.sock
# 仅监听回环地址，防止防火墙失效时数据库直接暴露到公网。
# 远程访问应绑定具体地址，并按来源 IP 配置防火墙和账号 Host 权限。
bind-address = 127.0.0.1
# X Protocol 使用独立监听地址；loose- 前缀兼容已关闭 X Plugin 的配置。
loose-mysqlx-bind-address = 127.0.0.1
loose-mysqlx-port = ${DB_X_Port}
datadir = ${MySQL_Data_Dir}
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
tmp_table_size = 16M
performance_schema_max_table_instances = 500

explicit_defaults_for_timestamp = true
#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535
mysql_native_password=ON

log-bin=mysql-bin
binlog_format=mixed
server-id   = 1
binlog_expire_logs_seconds = 864000
early-plugin-load = ""

default_storage_engine = InnoDB
innodb_file_per_table = 1
innodb_data_home_dir = ${MySQL_Data_Dir}
innodb_data_file_path = ibdata1:10M:autoextend
innodb_log_group_home_dir = ${MySQL_Data_Dir}
innodb_buffer_pool_size = 16M
innodb_log_file_size = 5M
innodb_log_buffer_size = 8M
innodb_flush_log_at_trx_commit = 1
innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer_size = 2M
write_buffer_size = 2M

[mysqlhotcopy]
interactive-timeout

${MySQLMAOpt}
EOF

    MySQL_Opt
    # MySQL 8.4 及以上转换弃用配置，8.0 保持原配置。
    MySQL_Deprecated_Opt
    Check_MySQL_Data_Dir
    chown -R mysql:mysql /usr/local/mysql
    # 数据目录初始化失败时停止，避免继续执行无效的启动和安全设置。
    if ! /usr/local/mysql/bin/mysqld --initialize-insecure --basedir=/usr/local/mysql --datadir=${MySQL_Data_Dir} --user=mysql; then
        Echo_Red "MySQL 数据目录初始化失败：${MySQL_Data_Dir}"
        Echo_Red "请根据上面 mysqld 的报错处理后重新安装。"
        return 1
    fi
    chown -R mysql:mysql ${MySQL_Data_Dir}
    \cp /usr/local/mysql/support-files/mysql.server /etc/init.d/mysql
    \cp ${cur_dir}/init.d/mysql.service /etc/systemd/system/mysql.service
    chmod 755 /etc/init.d/mysql
    cat > /etc/ld.so.conf.d/mysql.conf<<EOF
    /usr/local/mysql/lib
    /usr/local/lib
EOF
    ldconfig
    ln -sf /usr/local/mysql/lib/mysql /usr/lib/mysql
    ln -sf /usr/local/mysql/include/mysql /usr/include/mysql

    MySQL_Sec_Setting
}
