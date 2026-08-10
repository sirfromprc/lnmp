#!/usr/bin/env bash

Backup_MariaDB()
{
    echo "Starting backup all databases..."
    echo "If the database is large, the backup time will be longer."
    /usr/local/mariadb/bin/mysqldump --defaults-file=~/.my.cnf --all-databases > /root/mariadb_all_backup${Upgrade_Date}.sql
    if [ $? -eq 0 ]; then
        echo "MariaDB databases backup successfully.";
    else
        echo "MariaDB databases backup failed,Please backup databases manually!"
        exit 1
    fi
    # 退出码为 0 不代表备份完整，另需确认结束标记；
    # 库列表在停服前记录，供升级完成后比对是否有数据丢失。
    Check_DB_Backup "/root/mariadb_all_backup${Upgrade_Date}.sql" || exit 1
    Snapshot_DB_List /usr/local/mariadb/bin/mysql "${DB_List_Before}" || exit 1
    lnmp stop

    mv /usr/local/mariadb /usr/local/oldmariadb${Upgrade_Date}
    mv /etc/init.d/mariadb /usr/local/oldmariadb${Upgrade_Date}/init.d.mariadb.bak.${Upgrade_Date}
    mv /etc/my.cnf /usr/local/oldmariadb${Upgrade_Date}/my.cnf.mariadb.bak.${Upgrade_Date}
    if [ "${MariaDB_Data_Dir}" != "/usr/local/mariadb/var" ]; then
        mv ${MariaDB_Data_Dir} ${MariaDB_Data_Dir}${Upgrade_Date}
    fi

}

Upgrade_MariaDB()
{
    Check_DB
    if [ "${Is_MySQL}" = "y" ]; then
        Echo_Red "Current database was MySQL, Can't run MariaDB upgrade script."
        exit 1
    fi

    Verify_DB_Password

    cur_mariadb_version=`/usr/local/mariadb/bin/mysql_config --version`
    mariadb_version=""
    echo "Current MariaDB Version:${cur_mariadb_version}"
    echo "You can get version number from https://downloads.mariadb.org/"
    Echo_Yellow "Please enter MariaDB Version you want (10.11.x / 11.4.x / 11.8.x)."
    read -p "(example: 11.8.8 ): " mariadb_version
    if [ "${mariadb_version}" = "" ]; then
        echo "Error: You must input MariaDB Version!!"
        exit 1
    fi

    mariadb_short_version=$(echo "${mariadb_version}" | cut -d. -f1-2)
    case "${mariadb_short_version}" in
    10.11|11.4|11.8)
        ;;
    *)
        Echo_Red "不支持升级到 MariaDB ${mariadb_version}。"
        Echo_Red "本包只保留 10.11 / 11.4 / 11.8 三条 LTS 线，与安装侧一致。"
        Echo_Red "数据库未做任何改动。"
        exit 1
        ;;
    esac

    if [[ "${DB_ARCH}" = "x86_64" || "${DB_ARCH}" = "aarch64" ]]; then
        read -p "Using Generic Binaries [y/n]: " Bin
        case "${Bin}" in
        [nN][oO]|[nN])
            echo "You will install mariadb-${mariadb_version} from Source."
            Bin="n"
            ;;
        *)
            echo "You will install mariadb-${mariadb_version} Using Generic Binaries."
            Bin="y"
            ;;
        esac
    else
        Bin="n"
    fi

    #do you want to install the InnoDB Storage Engine?
    echo "==========================="

    InstallInnodb="y"
    Echo_Yellow "Do you want to install the InnoDB Storage Engine?"
    read -p "(Default yes, if you want please enter: y , if not please enter: n): " InstallInnodb

    case "${InstallInnodb}" in
    [yY][eE][sS]|[yY])
        echo "You will install the InnoDB Storage Engine"
        InstallInnodb="y"
        ;;
    [nN][oO]|[nN])
        echo "You will NOT install the InnoDB Storage Engine!"
        InstallInnodb="n"
        ;;
    *)
        echo "No input, The InnoDB Storage Engine will enable."
        InstallInnodb="y"
    esac

    echo "====================================================================="
    echo "You will upgrade MariaDB V${cur_mariadb_version} to V${mariadb_version}"
    echo "====================================================================="

    if [ -s /usr/local/include/jemalloc/jemalloc.h ] && lsof -n|grep "libjemalloc.so"|grep -q "mysqld"; then
        MariaDBMAOpt=''
    elif [ -s /usr/local/include/gperftools/tcmalloc.h ] && lsof -n|grep "libtcmalloc.so"|grep -q "mysqld"; then
        MariaDBMAOpt="-DCMAKE_EXE_LINKER_FLAGS='-ltcmalloc' -DWITH_SAFEMALLOC=OFF"
    else
        MariaDBMAOpt=''
    fi

    Press_Start

    echo "============================check files=================================="
    cd ${cur_dir}/src
    if [ "${Bin}" = "y" ]; then
        MariaDB_FileName="mariadb-${mariadb_version}-linux-systemd-${DB_ARCH}"
    else
        MariaDB_FileName="mariadb-${mariadb_version}"
    fi
    # 不用 `if [ -s ]` 提前放行已存在的文件：Download_Verified 自己就处理
    # "已存在则不重复下载"，且无论是否新下载都会核对 SHA256（MariaDB 走上游
    # REST 接口逐文件公布的 sha256sum）。提前放行等于给缓存文件开免检通道。

    Download_Verified mariadb "${mariadb_version}" \
        "https://downloads.mariadb.org/rest-api/mariadb/${mariadb_version}/${MariaDB_FileName}.tar.gz" \
        "${MariaDB_FileName}.tar.gz"
    if [ $? -eq 0 ]; then
        echo "Download ${MariaDB_FileName}.tar.gz successfully!"
    else
        echo "You enter MariaDB Version was:"${mariadb_version}
        Echo_Red "Error! You entered a wrong version number or can't download from mariadb mirror, please check!"
        sleep 5
        exit 1
    fi
    echo "============================check files=================================="

    Backup_MariaDB

    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] Starting upgrade mariadb-${Mariadb_Ver} Using Generic Binaries..."
        Tar_Cd ${MariaDB_FileName}.tar.gz
        mkdir /usr/local/mariadb
        mv ${MariaDB_FileName}/* /usr/local/mariadb/
    else
        Echo_Blue "[+] Starting upgrade ${Mariadb_Ver} Using Source code..."
        Tar_Cd mariadb-${mariadb_version}.tar.gz mariadb-${mariadb_version}
        MariaDB_WITHSSL

        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DMYSQL_UNIX_ADDR=/tmp/mysql.sock -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITHOUT_TOKUDB=1
        if ! Make_Install; then
            # 数据库升级尚未做自动回滚，
            # 这里至少要把恢复所需的东西指清楚，而不是丢一句 exit 1。
            Echo_Red "编译失败，升级中止。此时旧数据库已被停止并移走。"
            Echo_Red "人工恢复："
            Echo_Red "  1) mv /usr/local/oldmariadb${Upgrade_Date} /usr/local/mariadb"
            Echo_Red "  2) \cp /usr/local/oldmariadb${Upgrade_Date}/init.d.mariadb.bak.${Upgrade_Date} /etc/init.d/mariadb"
            Echo_Red "  3) /etc/init.d/mariadb start"
            Echo_Red "数据备份在 /root/mariadb_all_backup${Upgrade_Date}.sql"
            exit 1
        fi
    fi

    groupadd mariadb
    useradd -s /sbin/nologin -M -g mariadb mariadb
cat > /etc/my.cnf<<EOF
[client]
#password	= your_password
port		= 3306
socket		= /tmp/mysql.sock

[mysqld]
port		= 3306
socket		= /tmp/mysql.sock
# 仅监听回环地址，与全新安装保持同一监听基线（见 include/mariadb.sh）。
# 升级重写 /etc/my.cnf，此处不写则原有的本地监听限制会被静默撤销。
# 需要远程连库时改为具体地址，并同步调整防火墙放行与账号 Host 授权范围。
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

#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535

log-bin=mysql-bin
binlog_format=mixed
server-id	= 1
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
        sed -i '/skip-external-locking/i\default_storage_engine = MyISAM\nloose-skip-innodb' /etc/my.cnf
    fi
    MySQL_Opt
    if [ -d "${MariaDB_Data_Dir}" ]; then
        rm -rf ${MariaDB_Data_Dir}/*
    else
        mkdir -p ${MariaDB_Data_Dir}
    fi
    chown -R mariadb:mariadb /usr/local/mariadb
    /usr/local/mariadb/scripts/mysql_install_db --defaults-file=/etc/my.cnf --basedir=/usr/local/mariadb --datadir=${MariaDB_Data_Dir} --user=mariadb
    chown -R mariadb:mariadb ${MariaDB_Data_Dir}
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    chmod 755 /etc/init.d/mariadb

    Mariadb_Sec_Setting
    /etc/init.d/mariadb start

    echo "Restore backup databases..."
    if ! /usr/local/mariadb/bin/mysql --defaults-file=~/.my.cnf < /root/mariadb_all_backup${Upgrade_Date}.sql; then
        Echo_Red "备份导入失败，数据未完整恢复。"
        DB_Upgrade_Abort "/root/mariadb_all_backup${Upgrade_Date}.sql" "/usr/local/oldmariadb${Upgrade_Date}"
        exit 1
    fi
    echo "Repair databases..."
    if ! /usr/local/mariadb/bin/mysql_upgrade --defaults-file=~/.my.cnf; then
        Echo_Red "mysql_upgrade 执行失败。"
        DB_Upgrade_Abort "/root/mariadb_all_backup${Upgrade_Date}.sql" "/usr/local/oldmariadb${Upgrade_Date}"
        exit 1
    fi

    /etc/init.d/mariadb stop
    TempMycnf_Clean
    cd ${cur_dir} && rm -rf ${cur_dir}/src/mariadb-${mariadb_version}

    lnmp start
    # 成功判定不能只看文件是否存在：还须确认服务可连接、库列表无缺失、
    # 本地监听基线未被重写的 /etc/my.cnf 撤销。
    if [[ -s /usr/local/mariadb/bin/mysql && -s /usr/local/mariadb/bin/mysqld_safe && -s /etc/my.cnf ]] \
        && Verify_DB_Upgraded /usr/local/mariadb/bin/mysql "${DB_List_Before}"; then
        Echo_Green "======== upgrade MariaDB completed ======"
        rm -f "${DB_List_Before}"
    else
        Echo_Red "======== upgrade MariaDB failed ======"
        Echo_Red "upgrade MariaDB log: /root/upgrade_mariadb${Upgrade_Date}.log"
        DB_Upgrade_Abort "/root/mariadb_all_backup${Upgrade_Date}.sql" "/usr/local/oldmariadb${Upgrade_Date}"
        exit 1
    fi
}
