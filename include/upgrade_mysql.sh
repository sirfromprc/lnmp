#!/usr/bin/env bash

Backup_MySQL()
{
    echo "正在备份全部数据库..."
    echo "数据库较大时，备份所需时间会更长。"
    /usr/local/mysql/bin/mysqldump --defaults-file=~/.my.cnf --all-databases > /root/mysql_all_backup${Upgrade_Date}.sql
    if [ $? -eq 0 ]; then
        echo "MySQL 数据库备份成功。";
    else
        echo "MySQL 数据库备份失败，请手动备份数据库！"
        exit 1
    fi
    # 退出码为 0 不代表备份完整，另需确认结束标记；
    # 库列表在停服前记录，供升级完成后比对是否有数据丢失。
    Check_DB_Backup "/root/mysql_all_backup${Upgrade_Date}.sql" || exit 1
    Snapshot_DB_List /usr/local/mysql/bin/mysql "${DB_List_Before}" || exit 1
    lnmp stop
    mv /usr/local/mysql /usr/local/oldmysql${Upgrade_Date}
    mv /etc/init.d/mysql /usr/local/oldmysql${Upgrade_Date}/init.d.mysql.bak.${Upgrade_Date}
    mv /etc/my.cnf /usr/local/oldmysql${Upgrade_Date}/my.cnf.bak.${Upgrade_Date}
    if [ "${MySQL_Data_Dir}" != "/usr/local/mysql/var" ]; then
        mv ${MySQL_Data_Dir} ${MySQL_Data_Dir}${Upgrade_Date}
    fi

}


Upgrade_MySQL80()
{
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "正在使用官方通用二进制包升级 MySQL ${mysql_version}..."
        Tar_Cd ${mysql_src}
        mkdir /usr/local/mysql
        mv mysql-${mysql_version}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}/* /usr/local/mysql/
    else
        Echo_Blue "正在使用源码升级 MySQL ${mysql_version}..."
        Tar_Cd ${mysql_src} mysql-${mysql_version}
        Install_Boost
        mkdir build && cd build
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local/mysql -DSYSCONFDIR=/etc -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 ${MySQL_WITH_BOOST}
        if ! Make_Install; then
            # 数据库升级尚未做自动回滚，
            # 这里至少要把恢复所需的东西指清楚，而不是丢一句 exit 1。
            Echo_Red "编译失败，升级中止。此时旧数据库已被停止并移走。"
            Echo_Red "人工恢复："
            Echo_Red "  1) mv /usr/local/oldmysql${Upgrade_Date} /usr/local/mysql"
            Echo_Red "  2) \cp /usr/local/oldmysql${Upgrade_Date}/init.d.mysql.bak.${Upgrade_Date} /etc/init.d/mysql"
            Echo_Red "  3) /etc/init.d/mysql start"
            Echo_Red "数据备份在 /root/mysql_all_backup${Upgrade_Date}.sql"
            exit 1
        fi
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
# 仅监听回环地址，与全新安装保持同一监听基线（见 include/mysql.sh）。
# 升级重写 /etc/my.cnf，此处不写则原有的本地监听限制会被静默撤销。
# 需要远程连库时改为具体地址，并同步调整防火墙放行与账号 Host 授权范围。
bind-address = 127.0.0.1
# X Protocol（33060 端口）由独立选项控制，bind-address 对其无效。
# loose- 前缀用于在 mysqlx 插件被关闭时避免 mysqld 因未知选项拒绝启动。
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
    # 升到 8.4 及以上时把弃用项换成等价写法；更低版本走进去会直接返回
    MySQL_Deprecated_Opt
    if [ -d "${MySQL_Data_Dir}" ]; then
        rm -rf ${MySQL_Data_Dir}/*
    else
        mkdir -p ${MySQL_Data_Dir}
    fi
    chown -R mysql:mysql /usr/local/mysql/
    /usr/local/mysql/bin/mysqld --initialize-insecure --basedir=/usr/local/mysql --datadir=${MySQL_Data_Dir} --user=mysql
    chown -R mysql:mysql ${MySQL_Data_Dir}
    cat > /etc/ld.so.conf.d/mysql.conf<<EOF
/usr/local/mysql/lib
/usr/local/lib
EOF

    ldconfig
    ln -sf /usr/local/mysql/lib/mysql /usr/lib/mysql
    ln -sf /usr/local/mysql/include/mysql /usr/include/mysql
}

Upgrade_MySQL84()
{
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "正在使用官方通用二进制包升级 MySQL ${mysql_version}..."
        Tar_Cd ${mysql_src}
        mkdir /usr/local/mysql
        mv mysql-${mysql_version}-linux-glibc2.17-${DB_ARCH}/* /usr/local/mysql/
    else
        Echo_Blue "正在使用源码升级 MySQL ${mysql_version}..."
        Tar_Cd ${mysql_src} mysql-${mysql_version}
        Install_Boost
        mkdir build && cd build
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local/mysql -DSYSCONFDIR=/etc -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 ${MySQL_WITH_BOOST}
        if ! Make_Install; then
            # 数据库升级尚未做自动回滚，
            # 这里至少要把恢复所需的东西指清楚，而不是丢一句 exit 1。
            Echo_Red "编译失败，升级中止。此时旧数据库已被停止并移走。"
            Echo_Red "人工恢复："
            Echo_Red "  1) mv /usr/local/oldmysql${Upgrade_Date} /usr/local/mysql"
            Echo_Red "  2) \cp /usr/local/oldmysql${Upgrade_Date}/init.d.mysql.bak.${Upgrade_Date} /etc/init.d/mysql"
            Echo_Red "  3) /etc/init.d/mysql start"
            Echo_Red "数据备份在 /root/mysql_all_backup${Upgrade_Date}.sql"
            exit 1
        fi
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
# 仅监听回环地址，与全新安装保持同一监听基线（见 include/mysql.sh）。
# 升级重写 /etc/my.cnf，此处不写则原有的本地监听限制会被静默撤销。
# 需要远程连库时改为具体地址，并同步调整防火墙放行与账号 Host 授权范围。
bind-address = 127.0.0.1
# X Protocol（33060 端口）由独立选项控制，bind-address 对其无效。
# loose- 前缀用于在 mysqlx 插件被关闭时避免 mysqld 因未知选项拒绝启动。
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
    # 升到 8.4 及以上时把弃用项换成等价写法；更低版本走进去会直接返回
    MySQL_Deprecated_Opt
    if [ -d "${MySQL_Data_Dir}" ]; then
        rm -rf ${MySQL_Data_Dir}/*
    else
        mkdir -p ${MySQL_Data_Dir}
    fi
    chown -R mysql:mysql /usr/local/mysql/
    /usr/local/mysql/bin/mysqld --initialize-insecure --basedir=/usr/local/mysql --datadir=${MySQL_Data_Dir} --user=mysql
    chown -R mysql:mysql ${MySQL_Data_Dir}
    cat > /etc/ld.so.conf.d/mysql.conf<<EOF
/usr/local/mysql/lib
/usr/local/lib
EOF

    ldconfig
    ln -sf /usr/local/mysql/lib/mysql /usr/lib/mysql
    ln -sf /usr/local/mysql/include/mysql /usr/include/mysql
}

Restore_Start_MySQL()
{
    chgrp -R mysql /usr/local/mysql/.
    \cp /usr/local/mysql/support-files/mysql.server /etc/init.d/mysql
    chmod 755 /etc/init.d/mysql

    ldconfig

    MySQL_Sec_Setting
    /etc/init.d/mysql start

    echo "正在恢复数据库备份..."
    if ! /usr/local/mysql/bin/mysql --defaults-file=~/.my.cnf < /root/mysql_all_backup${Upgrade_Date}.sql; then
        Echo_Red "备份导入失败，数据未完整恢复。"
        DB_Upgrade_Abort "/root/mysql_all_backup${Upgrade_Date}.sql" "/usr/local/oldmysql${Upgrade_Date}"
        exit 1
    fi
    echo "正在检查并修复数据库..."
    MySQL_Ver_Com=$(Version_Compare 8.0.16 ${mysql_version})
    if [ "${MySQL_Ver_Com}" != "1" ]; then
        /etc/init.d/mysql stop
        echo "正在升级 MySQL 系统表..."
        /usr/local/mysql/bin/mysqld --user=mysql --upgrade=FORCE &
        mysqld_pid=$!
        echo "正在等待升级完成..."
        # --upgrade=FORCE 先完成升级再开始对外服务，因此 ping 成功即表示升级结束。
        #
        # 原实现固定 sleep 180 后直接 shutdown：大库可能尚未升完就被中断，
        # 小库则空等三分钟，且后台进程的退出状态从未被检查。
        # 改为轮询实例可用性，上限 30 分钟；进程提前退出则立即结束等待。
        upgrade_wait=0
        while [ ${upgrade_wait} -lt 1800 ]; do
            /usr/local/mysql/bin/mysqladmin --defaults-file=~/.my.cnf ping >/dev/null 2>&1 && break
            kill -0 ${mysqld_pid} 2>/dev/null || break
            sleep 1
            upgrade_wait=$((upgrade_wait + 1))
        done
        if ! /usr/local/mysql/bin/mysqladmin --defaults-file=~/.my.cnf ping >/dev/null 2>&1; then
            Echo_Red "MySQL 强制升级未能完成，等待 ${upgrade_wait} 秒后实例仍无响应。"
            kill ${mysqld_pid} 2>/dev/null
            DB_Upgrade_Abort "/root/mysql_all_backup${Upgrade_Date}.sql" "/usr/local/oldmysql${Upgrade_Date}"
            exit 1
        fi
        /usr/local/mysql/bin/mysqladmin --defaults-file=~/.my.cnf shutdown
        wait ${mysqld_pid}
    else
        if ! /usr/local/mysql/bin/mysql_upgrade --defaults-file=~/.my.cnf; then
            Echo_Red "mysql_upgrade 执行失败。"
            DB_Upgrade_Abort "/root/mysql_all_backup${Upgrade_Date}.sql" "/usr/local/oldmysql${Upgrade_Date}"
            exit 1
        fi
    fi

    /etc/init.d/mysql stop
    TempMycnf_Clean
    cd ${cur_dir} && rm -rf ${cur_dir}/src/mysql-${mysql_version}

    lnmp start
    # 成功判定不能只看文件是否存在：还须确认服务可连接、库列表无缺失、
    # 本地监听基线未被重写的 /etc/my.cnf 撤销。
    if [[ -s /usr/local/mysql/bin/mysql && -s /usr/local/mysql/bin/mysqld_safe && -s /etc/my.cnf ]] \
        && Verify_DB_Upgraded /usr/local/mysql/bin/mysql "${DB_List_Before}" "${DB_Port}" "${DB_X_Port}"; then
        Echo_Green "======== MySQL 升级完成 ======"
        rm -f "${DB_List_Before}"
    else
        Echo_Red "======== MySQL 升级失败 ======"
        Echo_Red "MySQL 升级日志：/root/upgrade_mysq${Upgrade_Date}.log"
        DB_Upgrade_Abort "/root/mysql_all_backup${Upgrade_Date}.sql" "/usr/local/oldmysql${Upgrade_Date}"
        exit 1
    fi
}

Upgrade_MySQL()
{
    Check_DB
    if [ "${Is_MySQL}" = "n" ]; then
        Echo_Red "当前数据库是 MariaDB，不能运行 MySQL 升级脚本。"
        exit 1
    fi

    Verify_DB_Password

    cur_mysql_version=`/usr/local/mysql/bin/mysql_config --version`
    mysql_version=""
    echo "当前 MySQL 版本：${cur_mysql_version}"
    echo "可在 https://dev.mysql.com/downloads/mysql/ 查看可用版本号。"
    Echo_Yellow "请输入目标 MySQL 版本（仅支持 8.0.x 或 8.4.x）。"
    read -p "版本号（例如 8.4.7）：" mysql_version
    if [ "${mysql_version}" = "" ]; then
        echo "错误：必须输入 MySQL 版本号！"
        exit 1
    fi

    if [ "${mysql_version}" == "${cur_mysql_version}" ]; then
        echo "错误：目标 MySQL 版本与当前版本相同！"
        exit 1
    fi

    mysql_short_version=$(echo "${mysql_version}" | cut -d. -f1-2)
    if [ "${mysql_short_version}" != "8.0" ] && [ "${mysql_short_version}" != "8.4" ]; then
        Echo_Red "不支持升级到 MySQL ${mysql_version}。"
        Echo_Red "本包只保留 8.0 与 8.4（LTS）两条线：5.x 系列上游已 EOL，"
        Echo_Red "对应的升级函数已随版本裁剪移除。"
        Echo_Red "数据库未做任何改动。"
        exit 1
    fi

    if [[ "${DB_ARCH}" = "x86_64" || "${DB_ARCH}" = "aarch64" ]]; then
        read -p "是否使用官方通用二进制包 [Y/n]（默认 y，推荐）：" Bin
        case "${Bin}" in
        [yY][eE][sS]|[yY])
            echo "将使用官方通用二进制包安装 MySQL ${mysql_version}。"
            Bin="y"
            ;;
        [nN][oO]|[nN])
            echo "将使用源码安装 MySQL ${mysql_version}。"
            Bin="n"
            ;;
        *)
            echo "使用默认项：官方通用二进制包安装 MySQL ${mysql_version}。"
            Bin="y"
            ;;
        esac
    else
        Bin="n"
    fi

    #do you want to install the InnoDB Storage Engine?
    echo "==========================="

    InstallInnodb="y"
    Echo_Yellow "是否启用 InnoDB 存储引擎？"
    read -p "请输入 y 或 n [默认 y]：" InstallInnodb

    case "${InstallInnodb}" in
    [yY][eE][sS]|[yY])
        echo "将启用 InnoDB 存储引擎。"
        InstallInnodb="y"
        ;;
    [nN][oO]|[nN])
        echo "将不启用 InnoDB 存储引擎！"
        InstallInnodb="n"
        ;;
    *)
        echo "使用默认项：启用 InnoDB 存储引擎。"
        InstallInnodb="y"
        ;;
    esac

    # mysql_short_version 已在前面的版本校验处求过，此处不再重复计算

    echo "=================================================="
    echo "即将把 MySQL 升级到 ${mysql_version}"
    echo "=================================================="

    Press_Start

    echo "============================ 检查文件 ============================"
    cd ${cur_dir}/src

    if [[ "${Bin}" = "y" && "${mysql_short_version}" = "8.0" ]]; then
        mysql8_glibc_ver="2.28"
        mysql_src="mysql-${mysql_version}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}.tar.xz"
    elif [[ "${Bin}" = "y" && "${mysql_short_version}" = "8.4" ]]; then
        mysql8_glibc_ver="2.17"
        mysql_src="mysql-${mysql_version}-linux-glibc2.17-${DB_ARCH}.tar.xz"
    else

        mysql_src="mysql-${mysql_version}.tar.gz"
    fi
    # MySQL 是唯一没有机器可读官方校验文件的上游：cdn.mysql.com 上
    # <file>.asc 一律 404，校验值只印在 dev.mysql.com 的下载页面上。
    # 所以这里也走 Download_Verified，但它对 mysql 只认静态清单 ：
    # 清单里没有就明确报错并告诉使用者怎么补，不得"拿不到校验值就照装"。
    # 注意：这里不用 `if [ -s ]` 提前放行已存在的文件。
    # Download_Verified 自己就处理"已存在则不重复下载"，且无论是否新下载
    # 都会核对 SHA256。缓存文件不能绕过校验；MySQL 安装包需要同等校验，
    # 因为它是唯一没有上游机器可读校验值的组件，静态清单是它仅有的一道防线。

    Download_Verified mysql "${mysql_version}" \
        "https://cdn.mysql.com/Downloads/MySQL-${mysql_short_version}/${mysql_src}" "${mysql_src}"
    if [ $? -eq 0 ]; then
        echo "${mysql_src} 检查通过"
    else
        Download_Verified mysql "${mysql_version}" \
            "https://cdn.mysql.com/archives/mysql-${mysql_short_version}/${mysql_src}" "${mysql_src}"
        if [ $? -ne 0 ]; then
            echo "输入的 MySQL 版本为：${mysql_version}"
            Echo_Red "错误！MySQL ${mysql_version} 下载或校验失败。"
            sleep 5
            exit 1
        fi
    fi
    Check_Openssl
    if [ "${Bin}" != "y" ]; then
        Echo_Blue "正在安装依赖包..."
        . ${cur_dir}/include/only.sh
        DB_Dependent
    fi
    echo "============================ 文件检查结束 ========================"

    Backup_MySQL
    if [ "${mysql_short_version}" = "8.0" ]; then
        Upgrade_MySQL80
    else
        Upgrade_MySQL84
    fi
    Restore_Start_MySQL
}
