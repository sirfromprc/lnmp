#!/usr/bin/env bash

Backup_MariaDB()
{
    local dump_bin client_bin

    dump_bin=$(First_Executable /usr/local/mariadb/bin/mariadb-dump /usr/local/mariadb/bin/mysqldump) || exit 1
    client_bin=$(First_Executable /usr/local/mariadb/bin/mariadb /usr/local/mariadb/bin/mysql) || exit 1
    echo "正在备份全部数据库..."
    echo "数据库较大时，备份所需时间会更长。"
    "${dump_bin}" --defaults-file="${HOME}/.my.cnf" --all-databases > /root/mariadb_all_backup${Upgrade_Date}.sql
    if [ $? -eq 0 ]; then
        echo "MariaDB 数据库备份成功。";
    else
        echo "MariaDB 数据库备份失败，请手动备份数据库！"
        exit 1
    fi
    # 同时确认备份结束标记，并记录升级前库列表供完成后核对。
    Check_DB_Backup "/root/mariadb_all_backup${Upgrade_Date}.sql" || exit 1
    Snapshot_DB_List "${client_bin}" "${DB_List_Before}" || exit 1
    lnmp stop
    Ensure_DB_Stopped "/usr/local/mariadb/bin/mariadbd|/usr/local/mariadb/bin/mysqld" || exit 1

    LNMP_Moved_Items=()
    Move_For_Upgrade /usr/local/mariadb "/usr/local/oldmariadb${Upgrade_Date}" || Abort_Upgrade_Move
    Move_For_Upgrade /etc/init.d/mariadb \
        "/usr/local/oldmariadb${Upgrade_Date}/init.d.mariadb.bak.${Upgrade_Date}" || Abort_Upgrade_Move
    Move_For_Upgrade /etc/my.cnf \
        "/usr/local/oldmariadb${Upgrade_Date}/my.cnf.mariadb.bak.${Upgrade_Date}" || Abort_Upgrade_Move
    if [ "${MariaDB_Data_Dir}" != "/usr/local/mariadb/var" ]; then
        Move_For_Upgrade "${MariaDB_Data_Dir}" "${MariaDB_Data_Dir}${Upgrade_Date}" || Abort_Upgrade_Move
    fi

    # 旧实例已搬走，此后任何退出都要自动放回并重新启动。
    Arm_DB_Upgrade_Guard "/root/mariadb_all_backup${Upgrade_Date}.sql" \
        "/usr/local/oldmariadb${Upgrade_Date}" mariadb \
        "/usr/local/oldmariadb${Upgrade_Date}/bin/mariadb" /usr/local/mariadb
}

Upgrade_MariaDB()
{
    local config_bin install_db client_bin upgrade_bin safe_bin

    Check_DB
    if [ "${Is_MySQL}" = "y" ]; then
        Echo_Red "当前数据库是 MySQL，不能运行 MariaDB 升级脚本。"
        exit 1
    fi

    Verify_DB_Password

    config_bin=$(First_Executable /usr/local/mariadb/bin/mariadb_config /usr/local/mariadb/bin/mysql_config) || exit 1
    cur_mariadb_version=$("${config_bin}" --version)
    mariadb_version=""
    echo "当前 MariaDB 版本：${cur_mariadb_version}"
    echo "可在 https://downloads.mariadb.org/ 查看可用版本号。"
    Echo_Yellow "请输入目标 MariaDB 版本（10.11.x / 11.4.x / 11.8.x）。"
    read -p "版本号（例如 11.8.8）：" mariadb_version
    if [ "${mariadb_version}" = "" ]; then
        echo "错误：必须输入 MariaDB 版本号！"
        exit 1
    fi
    Check_Version_String "${mariadb_version}" "MariaDB 版本号" || exit 1

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
        read -p "是否使用官方通用二进制包 [Y/n]（默认 y，推荐）：" Bin
        case "${Bin}" in
        [nN][oO]|[nN])
            echo "将使用源码安装 MariaDB ${mariadb_version}。"
            Bin="n"
            ;;
        *)
            echo "将使用官方通用二进制包安装 MariaDB ${mariadb_version}。"
            Bin="y"
            ;;
        esac
    else
        Bin="n"
    fi

    # 选择是否启用 InnoDB 存储引擎。
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
    esac

    echo "====================================================================="
    echo "即将把 MariaDB ${cur_mariadb_version} 升级到 ${mariadb_version}"
    echo "====================================================================="

    if [ -s /usr/local/include/jemalloc/jemalloc.h ] && lsof -n|grep "libjemalloc.so"|grep -q "mysqld"; then
        MariaDBMAOpt=''
    elif [ -s /usr/local/include/gperftools/tcmalloc.h ] && lsof -n|grep "libtcmalloc.so"|grep -q "mysqld"; then
        MariaDBMAOpt="-DCMAKE_EXE_LINKER_FLAGS='-ltcmalloc' -DWITH_SAFEMALLOC=OFF"
    else
        MariaDBMAOpt=''
    fi

    Press_Start || exit 1

    echo "============================ 检查文件 ============================"
    cd "${cur_dir}/src" || return 1
    if [ "${Bin}" = "y" ]; then
        MariaDB_FileName="mariadb-${mariadb_version}-linux-systemd-${DB_ARCH}"
    else
        MariaDB_FileName="mariadb-${mariadb_version}"
    fi
    # Download_Verified 对新下载和本地缓存统一核对上游公布的 SHA256。

    Download_Verified mariadb "${mariadb_version}" \
        "https://downloads.mariadb.org/rest-api/mariadb/${mariadb_version}/${MariaDB_FileName}.tar.gz" \
        "${MariaDB_FileName}.tar.gz"
    if [ $? -eq 0 ]; then
        echo "${MariaDB_FileName}.tar.gz 下载成功！"
    else
        echo "输入的 MariaDB 版本为：${mariadb_version}"
        Echo_Red "错误！版本号不正确或无法从 MariaDB 镜像下载，请检查！"
        sleep 5
        exit 1
    fi
    echo "============================ 文件检查结束 ========================"

    Backup_MariaDB

    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] 正在使用官方通用二进制包升级 ${Mariadb_Ver}..."
        Tar_Cd ${MariaDB_FileName}.tar.gz
        mkdir /usr/local/mariadb
        mv ${MariaDB_FileName}/* /usr/local/mariadb/
    else
        Echo_Blue "[+] 正在使用源码升级 ${Mariadb_Ver}..."
        Tar_Cd mariadb-${mariadb_version}.tar.gz mariadb-${mariadb_version}
        MariaDB_WITHSSL

        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DMYSQL_UNIX_ADDR=/run/mysqld/mysqld.sock -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITHOUT_TOKUDB=1
        if ! Make_Install; then
            Echo_Red "编译失败，升级中止，旧数据库将自动放回并重新启动。"
            exit 1
        fi
    fi

    groupadd mariadb
    useradd -s /sbin/nologin -M -g mariadb mariadb
cat > /etc/my.cnf<<EOF
[client]
#password	= your_password
port		= ${DB_Port}
socket		= /run/mysqld/mysqld.sock

[mysqld]
port		= ${DB_Port}
socket		= /run/mysqld/mysqld.sock
# 升级后的数据库继续仅监听回环地址，避免重写配置时撤销访问限制。
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
    # 搬迁成功后该路径应当为空；非空说明上一步没搬干净，此时拒绝而不是清空。
    Require_Empty_Data_Dir "${MariaDB_Data_Dir}" || exit 1
    chown -R mariadb:mariadb /usr/local/mariadb
    install_db=$(First_Executable \
        /usr/local/mariadb/scripts/mariadb-install-db /usr/local/mariadb/scripts/mysql_install_db \
        /usr/local/mariadb/bin/mariadb-install-db /usr/local/mariadb/bin/mysql_install_db) || exit 1
    "${install_db}" --defaults-file=/etc/my.cnf --basedir=/usr/local/mariadb \
        --datadir="${MariaDB_Data_Dir}" --user=mariadb || exit 1
    chown -R mariadb:mariadb ${MariaDB_Data_Dir}
    Secure_Initial_DB_Password mariadb mariadb || exit 1
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    Install_Systemd_Unit "${cur_dir}/init.d/mariadb.service" /etc/systemd/system/mariadb.service || exit 1
    chmod 755 /etc/init.d/mariadb
    Rewrite_MariaDB_Initd_Names /etc/init.d/mariadb /usr/local/mariadb/bin
    Patch_Init_Runtime_Directory /etc/init.d/mariadb /run/mysqld mariadb mariadb || exit 1

    Mariadb_Sec_Setting || exit 1
    /etc/init.d/mariadb start

    client_bin=$(First_Executable /usr/local/mariadb/bin/mariadb /usr/local/mariadb/bin/mysql) || exit 1
    upgrade_bin=$(First_Executable /usr/local/mariadb/bin/mariadb-upgrade /usr/local/mariadb/bin/mysql_upgrade) || exit 1
    safe_bin=$(First_Executable /usr/local/mariadb/bin/mariadbd-safe /usr/local/mariadb/bin/mysqld_safe) || exit 1
    echo "正在恢复数据库备份..."
    if ! "${client_bin}" --defaults-file="${HOME}/.my.cnf" < /root/mariadb_all_backup${Upgrade_Date}.sql; then
        Echo_Red "备份导入失败，数据未完整恢复。"
        exit 1
    fi
    echo "正在检查并修复数据库..."
    if ! "${upgrade_bin}" --defaults-file="${HOME}/.my.cnf"; then
        Echo_Red "MariaDB 升级程序执行失败。"
        exit 1
    fi

    /etc/init.d/mariadb stop
    TempMycnf_Clean
    cd ${cur_dir} && rm -rf ${cur_dir}/src/mariadb-${mariadb_version}

    lnmp start
    # 升级成功需确认服务可连接、数据库列表完整且仍保持本地监听限制。
    if [[ -x "${client_bin}" && -x "${safe_bin}" && -s /etc/my.cnf ]] \
        && Verify_DB_Upgraded "${client_bin}" "${DB_List_Before}" "${DB_Port}"; then
        Disarm_DB_Upgrade_Guard
        Echo_Green "======== MariaDB 升级完成 ======"
        rm -f "${DB_List_Before}"
    else
        Echo_Red "======== MariaDB 升级失败 ======"
        Echo_Red "MariaDB 升级日志：/root/upgrade_mariadb${Upgrade_Date}.log"
        exit 1
    fi
}
