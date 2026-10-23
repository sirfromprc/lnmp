#!/usr/bin/env bash
#
# 数据库模块：MySQL 与 MariaDB 的下载清单、安装状态检查、二进制或源码安装、my.cnf 生成、
# 数据目录初始化、root 口令设置与安全收尾。实例参数为 <mysql|mariadb> <版本>，安装另带 <bin|source>。
#
#   Database_Sources <种类> <版本> <bin|source>   输出下载清单，不下载、不写文件
#   Database_Installed                            输出已装的 "<种类>\t<版本>"；0 已装；1 未装；2 程序不可读（只输出种类）
#   Database_Check   <种类> <版本>                0 就绪；1 缺失或不完整；2 已装版本或种类不同；3 参数错误
#   Database_Verify  <种类> <版本>                Check 通过后经服务端 socket 执行 ping；0 通过，1 未通过
#   Database_Install <种类> <版本> <bin|source>   Check 为 0 时不写文件；为 2 时不处理并返回 2
#   Database_Upgrade <种类> <目标版本> <bin|source> 同种类升级，失败时自动放回旧实例
#   Database_Migrate <目标 MariaDB 版本> <bin|source> MySQL 迁移到 MariaDB，失败时还原 MySQL
#   Database_Remove  <种类> [数据目录...]        数据目录先移到 /root，再删除程序与配置；2 为未删除任何文件
#
# 输入为参数与只读配置（lnmp.conf 的 DB_Port、DB_X_Port、MySQL_Data_Dir、MariaDB_Data_Dir、InstallInnodb，
# 安装选择的 DB_Root_Password，cur_dir、DB_ARCH、DB_Bin_Glibc、MySQLMAOpt）。
# 安全初始化各步骤的失败记入 DB_Init_Failed、DB_Init_Errors，由 include/end.sh 汇总。
# 约定：不交互、不 exit、不改变调用方工作目录；解包与编译在子 shell 中进行。
# 升级与迁移整体在子 shell 中执行，流程内的 exit 与回滚守卫的 trap 只作用于该子 shell；
# 口令校验、版本选择与下载由入口 include/upgrade_mysql.sh、upgrade_mariadb.sh、upgrade_mysql2mariadb.sh 完成。

# _Database_Args <种类> <版本> [bin|source]：参数合法时返回 0。
_Database_Args()
{
    case "$1" in mysql|mariadb) ;; *) return 1 ;; esac
    [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    case "${3-bin}" in bin|source) ;; *) return 1 ;; esac
    return 0
}

# Database_Sources <种类> <版本> <bin|source>
# 每行：组件、实例、版本、文件名、地址、校验类型、校验定位，TAB 分隔。
# MySQL 同一文件先列当前下载区，再列 archives，调用方按行尝试，任一成功即可。
Database_Sources()
{
    local kind=$1 ver=$2 mode=$3 branch glibc file url check=none loc=-

    _Database_Args "${kind}" "${ver}" "${mode}" || return 1
    branch=${ver%.*}
    case "${kind}" in
    mysql)
        if [ "${mode}" = bin ]; then
            glibc=${DB_Bin_Glibc:-auto}
            [ "${glibc}" = auto ] && glibc=2.28
            # MySQL 8.0 及以上使用 .tar.xz，较早版本使用 .tar.gz。
            if Version_GE "${branch}" 8.0; then
                file="mysql-${ver}-linux-glibc${glibc}-${DB_ARCH}.tar.xz"
            else
                file="mysql-${ver}-linux-glibc${glibc}-${DB_ARCH}.tar.gz"
            fi
        else
            file="mysql-${ver}.tar.gz"
        fi
        ;;
    mariadb)
        if [ "${mode}" = bin ]; then
            file="mariadb-${ver}-linux-systemd-${DB_ARCH}.tar.gz"
        else
            file="mariadb-${ver}.tar.gz"
        fi
        ;;
    esac
    if awk -v f="${file}" '$1 !~ /^#/ && $2 == f {found=1} END {exit !found}' \
        "${cur_dir}/src/checksums.sha256" 2>/dev/null; then
        check=sha256
        loc=src/checksums.sha256
    fi
    case "${kind}" in
    mysql)
        for url in "https://cdn.mysql.com/Downloads/MySQL-${branch}/${file}" \
                   "https://cdn.mysql.com/archives/mysql-${branch}/${file}"; do
            printf 'database\t/usr/local/mysql\t%s\t%s\t%s\t%s\t%s\n' "${ver}" "${file}" "${url}" "${check}" "${loc}"
        done
        ;;
    mariadb)
        printf 'database\t/usr/local/mariadb\t%s\t%s\t%s\t%s\t%s\n' "${ver}" "${file}" \
            "https://downloads.mariadb.org/rest-api/mariadb/${ver}/${file}" "${check}" "${loc}"
        ;;
    esac
    return 0
}

# _Database_Server <种类>：输出已安装的服务端程序路径，不存在时返回 1。
_Database_Server()
{
    local f
    for f in "/usr/local/$1/bin/mariadbd" "/usr/local/$1/bin/mysqld"; do
        [ "$1" = mysql ] && [ "${f##*/}" = mariadbd ] && continue
        [ -x "${f}" ] && { printf '%s\n' "${f}"; return 0; }
    done
    return 1
}

# 两种数据库目录都在时按 Db_Detect 的识别结果（MariaDB 优先）。
Database_Installed()
{
    local kind found server ver

    if found=$(Db_Detect); then
        kind=${found%%$'\t'*}
    elif [ -d /usr/local/mariadb ]; then
        kind=mariadb
    elif [ -d /usr/local/mysql ]; then
        kind=mysql
    else
        return 1
    fi
    server=$(_Database_Server "${kind}") || { printf '%s\t\n' "${kind}"; return 2; }
    ver=$("${server}" --version 2>/dev/null | grep -oE 'Ver [0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    [ -n "${ver}" ] || { printf '%s\t\n' "${kind}"; return 2; }
    printf '%s\t%s\n' "${kind}" "${ver#Ver }"
}

# Database_Check <种类> <版本>
# 安装目录、服务端程序、/etc/my.cnf、init 脚本齐全且数据目录已初始化为 0；
# 本机已装另一种数据库或版本不同为 2；其余缺失为 1。服务运行状态不参与判定。
Database_Check()
{
    local kind=$1 ver=$2 found server have datadir

    _Database_Args "${kind}" "${ver}" || return 3
    if found=$(Db_Detect) && [ "${found%%$'\t'*}" != "${kind}" ]; then
        return 2
    fi
    server=$(_Database_Server "${kind}") || return 1
    have=$("${server}" --version 2>/dev/null | grep -oE 'Ver [0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    [ -n "${have}" ] || return 1
    [ "${have#Ver }" = "${ver}" ] || return 2
    [ -s /etc/my.cnf ] && [ -x "/etc/init.d/${kind}" ] || return 1
    datadir=$(Db_Conf_Value datadir)
    [ -n "${datadir}" ] && [ -d "${datadir}/mysql" ] || return 1
    return 0
}

# Database_Verify <种类> <版本>：Check 通过后经服务端 socket 执行 ping，不需要口令。
# 0 通过；1 Check 未通过或服务端无响应。
Database_Verify()
{
    local kind=$1 ver=$2 admin sock

    Database_Check "${kind}" "${ver}" || return 1
    admin=$(First_Executable "/usr/local/${kind}/bin/mariadb-admin" "/usr/local/${kind}/bin/mysqladmin") || return 1
    sock=$(Db_Server_Socket /etc/my.cnf)
    if ! "${admin}" --no-defaults --socket="${sock}" ping >/dev/null 2>&1; then
        Echo_Red "${kind} 服务端未响应（socket ${sock}），执行 lnmp status 或查看数据库错误日志。"
        return 1
    fi
    return 0
}

# Database_Install <种类> <版本> <bin|source>
# 下载由调用方按 Database_Sources 完成；本函数只解包或编译、生成配置并初始化。
Database_Install()
{
    local kind=$1 ver=$2 mode=$3 rc cnf_bak=''

    _Database_Args "${kind}" "${ver}" "${mode}" || return 3
    Database_Check "${kind}" "${ver}"
    rc=$?
    case "${rc}" in
    0) echo "${kind} ${ver} 已安装，跳过。"; return 0 ;;
    1) ;;
    2) Echo_Red "本机已安装其它版本或种类的数据库，未改动。版本变更请使用 upgrade.sh。"; return 2 ;;
    *) return "${rc}" ;;
    esac
    # 写入任何文件前只读核对数据目录；/etc/my.cnf 先备份，安装失败时放回。
    case "${kind}" in
    mysql)   _Database_Data_Dir_Precheck "${MySQL_Data_Dir}" || return 1 ;;
    mariadb) _Database_Data_Dir_Precheck "${MariaDB_Data_Dir}" || return 1 ;;
    esac
    if [ -e /etc/my.cnf ]; then
        cnf_bak=$(mktemp /etc/my.cnf.lnmp-bak.XXXXXX) && cp -p /etc/my.cnf "${cnf_bak}" || {
            [ -n "${cnf_bak}" ] && rm -f "${cnf_bak}"
            Echo_Red "备份 /etc/my.cnf 失败，未改动。"
            return 1
        }
    fi
    case "${kind}" in
    mysql)   _Database_Install_MySQL "${ver}" "${mode}" ;;
    mariadb) _Database_Install_MariaDB "${ver}" "${mode}" ;;
    esac
    rc=$?
    if [ "${rc}" -eq 0 ]; then
        [ -n "${cnf_bak}" ] && rm -f "${cnf_bak}"
    elif [ -n "${cnf_bak}" ]; then
        mv -f "${cnf_bak}" /etc/my.cnf && Echo_Yellow "已恢复安装前的 /etc/my.cnf。"
    else
        rm -f /etc/my.cnf
    fi
    return "${rc}"
}

# _Database_Install_MySQL <版本> <bin|source>：8.0 与 8.4 的编译参数、my.cnf 模板和初始化流程相同，
# 版本差异由 _Database_MySQL_Deprecated 处理。
_Database_Install_MySQL()
{
    local ver=$1 mode=$2 stem="mysql-$1" file

    if [ "${mode}" = bin ]; then
        file=$(Database_Sources mysql "${ver}" bin | head -n1 | cut -f4)
        Echo_Blue "[+] 正在使用官方通用二进制包安装 ${stem}..."
        ( _Database_Unpack_Bin "${file}" /usr/local/mysql ) || return 1
    else
        Echo_Blue "[+] 正在使用源码安装 ${stem}..."
        (
            # Install_Boost 按 Mysql_Ver 定位源码包内置的 Boost。
            Mysql_Ver=${stem}
            Tar_Cd "${stem}.tar.gz" "${stem}"
            Install_Boost
            # Boost 准备完成后返回 MySQL 源码目录继续构建。
            cd "${cur_dir}/src/${stem}" || exit 1
            mkdir build && cd build || exit 1
            cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local/mysql -DSYSCONFDIR=/etc -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITH_UNIT_TESTS=OFF -DWITH_ROUTER=OFF ${MySQL_WITH_BOOST}
            # MySQL 的 sql_gis 等源文件单个编译进程超过 1GB，按每任务 1.5GB 计算并行数。
            Make_Install 1536 || exit 1
            # 解析得到的 Boost 版本只在本子 shell 内可见，构建完成后在此清理其解包目录。
            [ -n "${Get_Boost_Ver}" ] && [ -d "${cur_dir}/src/boost_${Get_Boost_Ver}" ] && rm -rf "${cur_dir}/src/boost_${Get_Boost_Ver}"
            exit 0
        ) || return 1
    fi

    groupadd mysql
    useradd -s /sbin/nologin -M -g mysql mysql
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
# X Protocol 使用独立监听地址；loose- 前缀兼容已关闭 X Plugin 的配置。
loose-mysqlx-bind-address = 127.0.0.1
loose-mysqlx-port = ${DB_X_Port}
datadir = ${MySQL_Data_Dir}
skip-external-locking
key_buffer_size = 16M
max_allowed_packet = 64M
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
max_allowed_packet = 64M

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

    _Database_Tune
    # MySQL 8.4 及以上转换弃用配置，8.0 保持原配置。
    _Database_MySQL_Deprecated "${ver%.*}"
    _Database_Data_Dir_Guard MySQL "${MySQL_Data_Dir}" mysql || return 1
    _Database_Own_Tree /usr/local/mysql "${MySQL_Data_Dir}" mysql || return 1
    # 数据目录初始化失败时停止，避免继续执行无效的启动和安全设置。
    if ! /usr/local/mysql/bin/mysqld --initialize-insecure --basedir=/usr/local/mysql --datadir=${MySQL_Data_Dir} --user=mysql; then
        Echo_Red "MySQL 数据目录初始化失败：${MySQL_Data_Dir}"
        Echo_Red "请根据上面 mysqld 的报错处理后重新安装。"
        return 1
    fi
    chown -R mysql:mysql ${MySQL_Data_Dir}
    _Database_Init_Password mysql mysql || return 1
    \cp /usr/local/mysql/support-files/mysql.server /etc/init.d/mysql
    Svc_Install_Unit "${cur_dir}/init.d/mysql.service" /etc/systemd/system/mysql.service || return 1
    chmod 755 /etc/init.d/mysql
    Patch_Init_Runtime_Directory /etc/init.d/mysql /run/mysqld mysql mysql || return 1
    cat > /etc/ld.so.conf.d/mysql.conf<<EOF
    /usr/local/mysql/lib
    /usr/local/lib
EOF
    ldconfig
    ln -sfn /usr/local/mysql/lib/mysql /usr/lib/mysql
    ln -sfn /usr/local/mysql/include/mysql /usr/include/mysql

    _Database_MySQL_Secure || return 1
}

# _Database_Install_MariaDB <版本> <bin|source>：10.11、11.4、11.8 和 12.3 使用相同的编译参数与目录布局。
_Database_Install_MariaDB()
{
    local ver=$1 mode=$2 stem="mariadb-$1" file install_db

    if [ "${mode}" = bin ]; then
        file=$(Database_Sources mariadb "${ver}" bin | head -n1 | cut -f4)
        Echo_Blue "[+] 正在使用官方通用二进制包安装 ${stem}..."
        ( _Database_Unpack_Bin "${file}" /usr/local/mariadb ) || return 1
    else
        Echo_Blue "[+] 正在使用源码安装 ${stem}..."
        (
            Tar_Cd "${stem}.tar.gz" "${stem}"
            cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DMYSQL_UNIX_ADDR=/run/mysqld/mysqld.sock -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITHOUT_TOKUDB=1
            Make_Install || exit 1
            exit 0
        ) || return 1
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
max_allowed_packet = 64M
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
max_allowed_packet = 64M

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
    _Database_Tune
    _Database_Data_Dir_Guard MariaDB "${MariaDB_Data_Dir}" mariadb || return 1
    _Database_Own_Tree /usr/local/mariadb "${MariaDB_Data_Dir}" mariadb || return 1
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
    _Database_Init_Password mariadb mariadb || return 1
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    Svc_Install_Unit "${cur_dir}/init.d/mariadb.service" /etc/systemd/system/mariadb.service || return 1
    chmod 755 /etc/init.d/mariadb
    _Database_MariaDB_Initd_Names /etc/init.d/mariadb /usr/local/mariadb/bin
    Patch_Init_Runtime_Directory /etc/init.d/mariadb /run/mysqld mariadb mariadb || return 1

    _Database_MariaDB_Secure || return 1
}

# _Database_Data_Dir_Precheck <数据目录>：只读检查。数据目录非空且未声明 LNMP_Move_Existing_DB_Data=yes 时返回 1。
_Database_Data_Dir_Precheck()
{
    local data_dir=$1 started_at

    # 已有数据目录非空说明机器上存在实际数据库，重装会让它与运行中的服务分离。
    # 默认拒绝，必须显式确认后才搬走；任何情况下都不删除数据。
    if [ -d "${data_dir}" ] && [ -n "$(ls -A -- "${data_dir}" 2>/dev/null)" ] &&
       [ "${LNMP_Move_Existing_DB_Data:-}" != "yes" ]; then
        # 进度标记记到 db 阶段，说明该目录是上次未完成安装留下的，而非在用数据库。
        if [ "$(Install_Progress_Get stage 2>/dev/null)" = "db" ] &&
           started_at=$(Install_Progress_Get started 2>/dev/null); then
            Echo_Red "数据目录 ${data_dir} 非空，来自 ${started_at} 开始的那次未完成安装。"
            Echo_Red "该目录不会被删除，但需要确认后才能搬走并新建空实例，已中止。"
        else
            Echo_Red "数据目录 ${data_dir} 已存在且非空，里面可能是正在使用的数据库。"
            Echo_Red "本次安装会把它整体搬到 /root 下再新建空实例，不会删除数据，"
            Echo_Red "但运行中的服务会与数据分离，已中止。"
        fi
        Echo_Yellow "确认要重装并搬走现有数据时，显式声明后重试："
        echo
        echo "  LNMP_Move_Existing_DB_Data=yes bash install.sh ${Stack:-db}"
        Echo_Yellow "只想保留现有数据库时不要重装，直接使用现有实例即可。"
        return 1
    fi
    return 0
}

# 数据目录非空时默认拒绝；显式声明 LNMP_Move_Existing_DB_Data=yes 后整体移到 /root，不删除数据。
# _Database_Data_Dir_Guard <显示名> <数据目录> <备份目录前缀>
_Database_Data_Dir_Guard()
{
    local label=$1 data_dir=$2 prefix=$3 datetime backup_dir kept

    _Database_Data_Dir_Precheck "${data_dir}" || return 1
    if [ -d "${data_dir}" ] && [ -n "$(ls -A -- "${data_dir}" 2>/dev/null)" ]; then
        datetime=$(date +"%Y%m%d%H%M%S")
        backup_dir="/root/${prefix}-data-dir-backup${datetime}"
        if [ -e "${backup_dir}" ] || ! mv -- "${data_dir}" "${backup_dir}"; then
            Echo_Red "${label} 数据目录备份失败，未清理原目录：${data_dir}"
            return 1
        fi
        if ! mkdir -p -- "${data_dir}"; then
            Echo_Red "无法重新创建 ${label} 数据目录；原数据保留在 ${backup_dir}。"
            return 1
        fi
        Echo_Green "原 ${label} 数据目录已完整移动到 ${backup_dir}。"
        # 反复中断重装会不断累积备份目录，这里只提示，不自动删除任何数据。
        kept=$(ls -d "/root/${prefix}-data-dir-backup"* 2>/dev/null | wc -l)
        if [ "${kept}" -gt 1 ]; then
            Echo_Yellow "/root 下已有 ${kept} 份 ${prefix}-data-dir-backup* 目录，确认无用后请自行删除。"
        fi
    else
        mkdir -p -- "${data_dir}" || return 1
    fi
}

# _Database_Own_Tree <安装目录> <数据目录> <运行账号>：程序文件归 root，仅数据目录归运行账号。
# mysqld_safe、db-preflight 以 root 执行，归运行账号所有时数据库进程可借服务重启提权。
_Database_Own_Tree()
{
    local prefix=$1 data_dir=$2 user=$3

    case "${prefix}" in ''|/) return 1 ;; esac
    [ -n "${data_dir}" ] && [ -n "${user}" ] || return 1
    if ! mkdir -p -- "${data_dir}" || ! chown -R root:root "${prefix}" \
       || ! chown "${user}:${user}" "${data_dir}"; then
        Echo_Red "设置 ${prefix} 属主失败。"
        return 1
    fi
    # MySQL InnoDB 启动时在数据目录上一级创建 check_sector_size，上一级归 root 时预置该文件。
    if [ "${user}" = mysql ] && [ "${data_dir%/*}" = "${prefix}" ] \
       && ! install -o mysql -g mysql -m 600 /dev/null "${prefix}/check_sector_size"; then
        Echo_Red "创建 ${prefix}/check_sector_size 失败。"
        return 1
    fi
    return 0
}

# 通用二进制包解包到安装目录：目录须不存在或为空，安装后 bin 非空，并随包安装启动前检查。
_Database_Unpack_Bin()
{
    local tarball=$1 target=$2 topdir rc restore_dotglob server_bin

    # 同时支持 MySQL 的 .tar.xz 和 MariaDB 的 .tar.gz 文件名。
    topdir="${cur_dir}/src/${tarball%.tar.*}"

    Tar_Cd "${tarball}"

    if [ ! -d "${topdir}" ]; then
        Echo_Red "错误：${tarball} 解压后没有预期的目录 ${tarball%.tar.*}"
        Echo_Red "归档结构与预期不符（上游可能改了包内布局），拒绝继续安装。"
        return 1
    fi

    if [ -e "${target}" ] && [ ! -d "${target}" ]; then
        Echo_Red "错误：${target} 已存在且不是目录，拒绝覆盖。"
        return 1
    fi
    # 允许预先挂载的空目录，非空目录会造成新旧版本文件混合。
    if [ -d "${target}" ] && [ -n "$(ls -A "${target}" 2>/dev/null)" ]; then
        Echo_Red "错误：${target} 已存在且非空。"
        Echo_Red "直接往里放会得到一个新旧版本混合的安装，这里拒绝继续。"
        Echo_Red "请先确认该目录下是否还有数据，备份后移走或删除，再重新安装。"
        return 1
    fi

    if ! mkdir -p "${target}"; then
        Echo_Red "错误：无法创建 ${target}"
        return 1
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
        return 1
    fi

    # 通用二进制包安装后必须包含非空的 bin 目录。
    if [ ! -d "${target}/bin" ] || [ -z "$(ls -A "${target}/bin" 2>/dev/null)" ]; then
        Echo_Red "错误：${target}/bin 不存在或为空，通用二进制包没有正确安装。"
        return 1
    fi

    # 启动前检查随包安装，供 systemd unit 在每次启动前调用。
    if ! \cp "${cur_dir}/tools/db-preflight.sh" "${target}/bin/db-preflight"; then
        Echo_Red "错误：安装 ${target}/bin/db-preflight 失败。"
        return 1
    fi
    chmod 755 "${target}/bin/db-preflight"

    # 初始化数据目录前确认服务端二进制所需动态库可用。
    for server_bin in "${target}/bin/mariadbd" "${target}/bin/mysqld"; do
        [ -x "${server_bin}" ] || continue
        _Database_Libaio "${server_bin}" || return 1
        break
    done
    return 0
}

# MySQL 和 MariaDB 通用二进制需要 libaio.so.1。检查与建链由 tools/db-preflight.sh
# 实现，systemd unit 的 ExecStartPre 调用同一份脚本，安装期和启动期行为一致。
_Database_Libaio()
{
    local server_bin=$1 preflight="${cur_dir}/tools/db-preflight.sh"

    [ -x "${server_bin}" ] || return 0
    if [ ! -r "${preflight}" ]; then
        Echo_Red "错误：缺少 ${preflight}，无法检查数据库运行库依赖。"
        return 1
    fi
    sh "${preflight}" "${server_bin}"
}

# 清理异常终止后遗留且无进程占用的数据库 socket。
# socket 路径以 /etc/my.cnf 的 [mysqld] 配置为准，正在使用时拒绝删除。
_Database_Clean_Socket()
{
    local sock pid exe

    sock=$(awk -F= '/^[[:space:]]*\[/{sec=$0} \
                    sec ~ /\[mysqld\]/ && /^[[:space:]]*socket[[:space:]]*=/ \
                    {gsub(/[[:space:]]/, "", $2); print $2; exit}' \
           /etc/my.cnf 2>/dev/null)
    [ -n "${sock}" ] || sock=/run/mysqld/mysqld.sock
    [ -S "${sock}" ] || return 0

    if fuser "${sock}" >/dev/null 2>&1 \
       || ss -lxH 2>/dev/null | awk '{print $5}' | grep -qx "${sock}"; then
        Echo_Red "错误：${sock} 正在被进程使用，可能已有数据库实例在运行。"
        # 中断的安装不会留下可用的 lnmp 命令，这里直接给出占用进程和处理办法。
        for pid in $(fuser "${sock}" 2>/dev/null); do
            exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null)
            Echo_Red "  占用进程：pid ${pid} ${exe:-未知}"
        done
        Echo_Red "确认该实例无用时，先 kill 上述进程，再重新执行安装。"
        Echo_Red "重新执行 install.sh 时会检测到该残留并询问是否清理。"
        return 1
    fi

    Echo_Yellow "清理残留的数据库 socket（没有进程在使用）：${sock}"
    rm -f "${sock}"
    return 0
}

# _Database_Init_Password <mysql|mariadb> <服务账号>
# 初始化工具建出的 root 尚无密码。正式服务启动前，先在 0700 私有目录中启动
# 禁网临时实例，设置并验证密码，关闭后才允许切换到正式 socket 和监听配置。
_Database_Init_Password()
(
    local kind="$1" db_user="$2" basedir safe admin
    local tmp sock pid_file log_file auth_file launcher_pid='' db_pid ready='n'

    case "${kind}" in
    mysql)
        basedir=/usr/local/mysql
        safe=/usr/local/mysql/bin/mysqld_safe
        admin=/usr/local/mysql/bin/mysqladmin
        ;;
    mariadb)
        basedir=/usr/local/mariadb
        safe=$(First_Executable "${basedir}/bin/mariadbd-safe" "${basedir}/bin/mysqld_safe") || return 1
        admin=$(First_Executable "${basedir}/bin/mariadb-admin" "${basedir}/bin/mysqladmin") || return 1
        ;;
    *)
        Echo_Red "未知数据库类型：${kind}"
        return 1
        ;;
    esac
    [ -x "${safe}" ] && [ -x "${admin}" ] || {
        Echo_Red "缺少数据库安全初始化所需程序。"
        return 1
    }

    tmp=$(mktemp -d /run/lnmp-db-init.XXXXXX) || return 1
    sock="${tmp}/mysqld.sock"
    pid_file="${tmp}/mysqld.pid"
    log_file="${tmp}/mysqld.log"
    auth_file="${tmp}/client.cnf"
    chown "${db_user}:${db_user}" "${tmp}" || { rm -rf "${tmp}"; return 1; }
    chmod 0700 "${tmp}" || { rm -rf "${tmp}"; return 1; }
    install -o "${db_user}" -g "${db_user}" -m 0600 /dev/null "${log_file}" || {
        rm -rf "${tmp}"
        return 1
    }

    cleanup_initial_db()
    {
        [ -n "${launcher_pid}" ] && kill "${launcher_pid}" >/dev/null 2>&1 || true
        if [ -s "${pid_file}" ]; then
            db_pid=$(cat "${pid_file}" 2>/dev/null)
            case "${db_pid}" in
                ''|*[!0-9]*) ;;
                *)
                    case "$(basename "$(readlink -f "/proc/${db_pid}/exe" 2>/dev/null)")" in
                        mysqld|mariadbd) kill -TERM "${db_pid}" >/dev/null 2>&1 || true ;;
                    esac
                    ;;
            esac
        fi
        rm -rf "${tmp}"
    }
    trap cleanup_initial_db EXIT HUP INT TERM

    "${safe}" --defaults-file=/etc/my.cnf --basedir="${basedir}" --user="${db_user}" \
        --skip-networking --socket="${sock}" --pid-file="${pid_file}" \
        --log-error="${log_file}" >"${tmp}/launcher.log" 2>&1 &
    launcher_pid=$!

    for _wait in $(seq 1 60); do
        if "${admin}" --no-defaults --protocol=socket --socket="${sock}" -u root ping >/dev/null 2>&1; then
            ready='y'
            break
        fi
        kill -0 "${launcher_pid}" >/dev/null 2>&1 || break
        sleep 1
    done
    if [ "${ready}" != 'y' ]; then
        Echo_Red "数据库禁网临时实例未能就绪，拒绝启动正式服务。"
        [ -s "${log_file}" ] && tail -20 "${log_file}" >&2
        return 1
    fi

    if ! "${admin}" --no-defaults --protocol=socket --socket="${sock}" \
         -u root password "${DB_Root_Password}"; then
        Echo_Red "无法在禁网临时实例上设置数据库 root 密码。"
        return 1
    fi

    ( umask 077; cat >"${auth_file}" <<EOF
[client]
user=root
password='$(SQL_Escape "${DB_Root_Password}")'
protocol=socket
socket=${sock}
EOF
    ) || return 1
    if ! "${admin}" --defaults-file="${auth_file}" ping >/dev/null 2>&1; then
        Echo_Red "数据库 root 密码设置后验证失败。"
        return 1
    fi
    if ! "${admin}" --defaults-file="${auth_file}" shutdown; then
        Echo_Red "无法关闭数据库禁网临时实例。"
        return 1
    fi
    for _wait in $(seq 1 30); do
        [ ! -S "${sock}" ] && break
        sleep 1
    done
    if [ -S "${sock}" ]; then
        Echo_Red "数据库禁网临时实例未按时退出。"
        return 1
    fi

    wait "${launcher_pid}" >/dev/null 2>&1 || true
    launcher_pid=''
    trap - EXIT HUP INT TERM
    rm -rf "${tmp}"
    Echo_Green "数据库 root 密码已在禁网私有 socket 上完成设置。"
    return 0
)

# 初始化前检查数据库客户端能否运行，以直接显示缺失动态库等原始错误。
_Database_Client_Runnable()
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

# _Database_Init_Step <步骤描述> <SQL>：失败时记入 DB_Init_Failed、DB_Init_Errors，由 end.sh 汇总。
_Database_Init_Step()
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

# 按 Tune_Plan 的数据库份额写入 [mysqld]。每连接缓冲区保持模板的小值：
# 它们按连接分配，放大后在高并发时成倍占用内存。
_Database_Tune()
{
    local conf=/etc/my.cnf

    Tune_Plan || return 0
    [ -s "${conf}" ] || return 0

    Tune_Set_Mysqld "${conf}" innodb_buffer_pool_size "${Tune_Pool_MB}M" replace &&
    Tune_Set_Mysqld "${conf}" innodb_log_file_size "${Tune_Log_MB}M" replace &&
    Tune_Set_Mysqld "${conf}" max_connections "${Tune_Max_Conn}" &&
    Tune_Set_Mysqld "${conf}" thread_cache_size "${Tune_Thread_Cache}" &&
    Tune_Set_Mysqld "${conf}" table_open_cache "${Tune_Table_Cache}" &&
    Tune_Set_Mysqld "${conf}" tmp_table_size "${Tune_Tmp_MB}M" &&
    Tune_Set_Mysqld "${conf}" max_heap_table_size "${Tune_Tmp_MB}M" &&
    Tune_Set_Mysqld "${conf}" query_cache_size 0 replace || {
        Echo_Yellow "写入 ${conf} 的内存相关参数中断，未写入的项保持模板值。"
        return 0
    }
    return 0
}

# _Database_MySQL_Deprecated <分支>：将 /etc/my.cnf 中 MySQL 8.4 弃用项转换为等价配置：
#   binlog_format            8.4 只剩 ROW 一种取值，显式设置已无意义
#   innodb_log_file_size     \ 两项合并为 innodb_redo_log_capacity
#   innodb_log_files_in_group/  （8.0.30 引入，8.4 起是唯一的配置方式）
# _Database_Tune 先按内存确定日志文件大小，再按两个日志文件换算 redo 总容量。
# 只对 8.4 及以上生效；8.0 仍然接受旧写法，不动它以免影响既有实例的行为。
_Database_MySQL_Deprecated()
{
    local branch=$1 size num unit

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

_Database_MySQL_Secure()
{
    if [ -d "/proc/vz" ]; then
        ulimit -s unlimited
    fi

    if [ -d "/etc/mysql" ]; then
        mv /etc/mysql "/etc/mysql.backup.$(date +%Y%m%d)"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable mysql.service
    fi
    Ensure_Runtime_Directory /run/mysqld mysql mysql || return 1
    _Database_Clean_Socket || return 1
    /etc/init.d/mysql start

    ln -sf /usr/local/mysql/bin/mysql /usr/bin/mysql
    ln -sf /usr/local/mysql/bin/mysqldump /usr/bin/mysqldump
    ln -sf /usr/local/mysql/bin/myisamchk /usr/bin/myisamchk
    ln -sf /usr/local/mysql/bin/mysqld_safe /usr/bin/mysqld_safe
    ln -sf /usr/local/mysql/bin/mysqlcheck /usr/bin/mysqlcheck

    /etc/init.d/mysql restart
    sleep 2

    # 安全初始化依赖可用的客户端，因此在执行 SQL 前先验证运行能力。
    _Database_Client_Runnable /usr/local/mysql/bin/mysql

    # root 密码已在禁网私有 socket 上设置；正式实例只做登录与权限收尾。
    Make_TempMycnf "${DB_Root_Password}"
    Do_Query ""
    if [ $? -eq 0 ]; then
        echo "MySQL root 密码验证通过。"
    fi
    _Database_Init_Step "更新 root 密码" \
        "SET PASSWORD FOR 'root'@'localhost' = '$(SQL_Escape "${DB_Root_Password}")';"
    _Database_Init_Step "删除匿名用户" \
        "DELETE FROM mysql.user WHERE User='';"
    _Database_Init_Step "禁止 root 远程登录" \
        "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    _Database_Init_Step "删除测试数据库" \
        "DROP DATABASE IF EXISTS test;"
    _Database_Init_Step "刷新权限表" \
        "FLUSH PRIVILEGES;"

    /etc/init.d/mysql restart
    /etc/init.d/mysql stop
}

# 为旧命令名安装兼容入口。包装器调用 MariaDB 新命令名以避免弃用提示，
# 并保留参数、标准输入输出及退出码；缺少新名称时回退旧二进制。
_Database_MariaDB_Compat_Command()
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

_Database_MariaDB_Canonical_Command()
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

_Database_MariaDB_Commands()
{
    local source_dir="${1:-/usr/local/mariadb/bin}"
    local destination_dir="${2:-/usr/bin}"
    local command rc=0

    for command in mariadb mariadb-dump mariadb-admin mariadb-check mariadb-upgrade mariadbd-safe; do
        _Database_MariaDB_Canonical_Command "${command}" "${source_dir}" "${destination_dir}" || rc=1
    done

    _Database_MariaDB_Compat_Command mysql mariadb "${source_dir}" "${destination_dir}" || rc=1
    _Database_MariaDB_Compat_Command mysqldump mariadb-dump "${source_dir}" "${destination_dir}" || rc=1
    _Database_MariaDB_Compat_Command mysqladmin mariadb-admin "${source_dir}" "${destination_dir}" || rc=1
    _Database_MariaDB_Compat_Command mysqlcheck mariadb-check "${source_dir}" "${destination_dir}" || rc=1
    _Database_MariaDB_Compat_Command mysql_upgrade mariadb-upgrade "${source_dir}" "${destination_dir}" || rc=1
    _Database_MariaDB_Compat_Command mysqld_safe mariadbd-safe "${source_dir}" "${destination_dir}" || rc=1

    if [ -x "${source_dir}/myisamchk" ]; then
        ln -sfn "${source_dir}/myisamchk" "${destination_dir}/myisamchk" || rc=1
    fi
    return ${rc}
}

# 上游 init 脚本仍可能调用弃用的 mysqld_safe 和 mysqladmin。新命令存在时
# 替换对应入口，避免弃用提示并兼容后续移除旧命令的 MariaDB 版本。
_Database_MariaDB_Initd_Names()
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

_Database_MariaDB_Secure()
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
    _Database_Clean_Socket || return 1
    StartUp mariadb
    /etc/init.d/mariadb start

    if ! _Database_MariaDB_Commands; then
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
    _Database_Client_Runnable "${mariadb_client}"

    # root 密码已在禁网私有 socket 上设置；正式实例只做登录与权限收尾。
    Make_TempMycnf "${DB_Root_Password}"
    Do_Query ""
    if [ $? -eq 0 ]; then
        echo "数据库 root 密码验证通过。"
    fi
    # 目标账号或测试库不存在时无需报错，安全状态已满足要求。
    _Database_Init_Step "删除匿名用户" \
        "DELETE FROM mysql.user WHERE User='';"
    _Database_Init_Step "禁止 root 远程登录" \
        "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    _Database_Init_Step "删除测试数据库" \
        "DROP DATABASE IF EXISTS test;"
    # mariadb-install-db 给 PUBLIC 授予 test 与 test_ 前缀库的权限，任意账号可借此建库。
    _Database_Init_Step "删除测试数据库授权" \
        "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\\\_%';"
    _Database_Init_Step "刷新权限表" \
        "FLUSH PRIVILEGES;"

    /etc/init.d/mariadb stop
}

# Database_Upgrade <mysql|mariadb> <目标版本> <bin|source>
# 同种类升级：备份、停服、整体搬走旧实例后安装新版本并导入，校验通过后解除守卫。
# 调用前由入口完成口令校验（临时客户端配置）与安装包下载。流程在子 shell 中执行：
# 搬迁后任一步失败即退出子 shell，由守卫自动放回旧实例并启动。返回 0 成功，1 失败，3 参数错误。
Database_Upgrade()
{
    local kind=$1 ver=$2 mode=$3

    _Database_Args "${kind}" "${ver}" "${mode}" || return 3
    case "${kind}" in
    mysql)   ( _Database_Upgrade_MySQL "${ver}" "${mode}" ) ;;
    mariadb) ( _Database_Upgrade_MariaDB "${ver}" "${mode}" ) ;;
    esac
}

# Database_Migrate <目标 MariaDB 版本> <bin|source>：MySQL 迁移到 MariaDB，失败时还原 MySQL 与命令链接。
# Database_Migrate <版本> <bin|source> [reset-passwords]：reset-passwords 表示同意把 MariaDB 无法沿用口令的账号改为随机口令。
Database_Migrate()
{
    _Database_Args mariadb "$1" "$2" || return 3
    case "${3:-}" in ''|reset-passwords) ;; *) return 3 ;; esac
    ( M2M_Reset=${3:-}; _Database_Migrate_Run "$1" "$2" )
}

# Database_Migrate_Accounts <MySQL 客户端>：只读，输出需迁移的业务账号，每行“用户\t主机\t认证插件\t口令哈希”。
# 哈希只对 mysql_native_password 输出；root、mysql.* 系统账号与匿名账号不迁移。
Database_Migrate_Accounts()
{
    "$1" --defaults-file="${HOME}/.my.cnf" -N -B -r -e "SELECT user, host, plugin,
        IF(plugin = 'mysql_native_password', authentication_string, '') FROM mysql.user
        WHERE user <> '' AND user <> 'root' AND user NOT LIKE 'mysql.%' ORDER BY user, host;"
}

# _Database_Migrate_Files：迁移用的业务库导出、账号 SQL 与新口令清单路径。
_Database_Migrate_Files()
{
    printf '%s\n' "/root/mysql_user_dbs${Upgrade_Date}.sql" "/root/mysql2mariadb_accounts${Upgrade_Date}.sql" \
        "/root/mysql2mariadb_passwords${Upgrade_Date}.txt"
}

# _Database_Migrate_Export：旧 MySQL 运行时导出业务库与账号。mysql 系统库结构与 MariaDB 不兼容，不导入。
_Database_Migrate_Export()
{
    local dbs_file acct_file pw_file accounts user host plugin hash acct pw grants
    local -a dbs=()

    { read -r dbs_file; read -r acct_file; read -r pw_file; } < <(_Database_Migrate_Files)
    ( umask 077; : > "${dbs_file}" && : > "${acct_file}" ) || return 1
    rm -f "${pw_file}"
    mapfile -t dbs < <(grep -vx mysql "${DB_List_Before}")
    if [ "${#dbs[@]}" -gt 0 ]; then
        /usr/local/mysql/bin/mysqldump --defaults-file="${HOME}/.my.cnf" --max-allowed-packet=1G \
            --single-transaction --routines --events --triggers --databases "${dbs[@]}" > "${dbs_file}" || return 1
        _Database_Check_Backup "${dbs_file}" || return 1
    fi
    accounts=$(Database_Migrate_Accounts /usr/local/mysql/bin/mysql) || { Echo_Red "读取 MySQL 账号失败。"; return 1; }
    while IFS=$'\t' read -r user host plugin hash; do
        [ -n "${user}" ] || continue
        acct="'$(SQL_Escape "${user}")'@'$(SQL_Escape "${host}")'"
        if [ "${plugin}" = mysql_native_password ] && [ -n "${hash}" ]; then
            printf "CREATE USER %s IDENTIFIED BY PASSWORD '%s';\n" "${acct}" "$(SQL_Escape "${hash}")" >> "${acct_file}"
        elif [ "${M2M_Reset:-}" = reset-passwords ]; then
            pw=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
            printf "CREATE USER %s IDENTIFIED BY '%s';\n" "${acct}" "${pw}" >> "${acct_file}"
            ( umask 077; printf '%s@%s\t%s\n' "${user}" "${host}" "${pw}" >> "${pw_file}" ) || return 1
        else
            Echo_Red "账号 ${user}@${host} 使用 ${plugin}，MariaDB 无法沿用其口令。"
            return 1
        fi
        grants=$(/usr/local/mysql/bin/mysql --defaults-file="${HOME}/.my.cnf" -N -B -r -e "SHOW GRANTS FOR ${acct};") || return 1
        printf '%s\n' "${grants}" | sed 's/$/;/' >> "${acct_file}"
    done <<< "${accounts}"
    echo 'FLUSH PRIVILEGES;' >> "${acct_file}"
}


# 升级与迁移在子 shell 中运行，以下变量供原有流程读取。
_Database_Upgrade_MySQL()
{
    mysql_version=$1
    Bin=n
    [ "$2" = bin ] && Bin=y
    mysql8_glibc_ver="2.28"
    if [ "${Bin}" = "y" ]; then
        mysql_src="mysql-${mysql_version}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}.tar.xz"
    else
        mysql_src="mysql-${mysql_version}.tar.gz"
    fi
    DB_List_Before="/root/db_list_before${Upgrade_Date}.txt"

    _Database_Backup_MySQL
    _Database_Build_MySQL
    _Database_Restore_MySQL
}

_Database_Upgrade_MariaDB()
{
    local install_db client_bin upgrade_bin safe_bin

    mariadb_version=$1
    Bin=n
    [ "$2" = bin ] && Bin=y
    if [ "${Bin}" = "y" ]; then
        MariaDB_FileName="mariadb-${mariadb_version}-linux-systemd-${DB_ARCH}"
    else
        MariaDB_FileName="mariadb-${mariadb_version}"
    fi
    DB_List_Before="/root/db_list_before${Upgrade_Date}.txt"

    _Database_Backup_MariaDB

    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] 正在使用官方通用二进制包升级 ${Mariadb_Ver}..."
        Tar_Cd ${MariaDB_FileName}.tar.gz
        mkdir /usr/local/mariadb
        mv ${MariaDB_FileName}/* /usr/local/mariadb/
    else
        Echo_Blue "[+] 正在使用源码升级 ${Mariadb_Ver}..."
        Tar_Cd mariadb-${mariadb_version}.tar.gz mariadb-${mariadb_version}
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
max_allowed_packet = 64M
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
max_allowed_packet = 64M

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
    _Database_Tune
    # 搬迁成功后该路径应当为空；非空说明上一步没搬干净，此时拒绝而不是清空。
    Require_Empty_Data_Dir "${MariaDB_Data_Dir}" || exit 1
    _Database_Own_Tree /usr/local/mariadb "${MariaDB_Data_Dir}" mariadb || exit 1
    install_db=$(First_Executable \
        /usr/local/mariadb/scripts/mariadb-install-db /usr/local/mariadb/scripts/mysql_install_db \
        /usr/local/mariadb/bin/mariadb-install-db /usr/local/mariadb/bin/mysql_install_db) || exit 1
    "${install_db}" --defaults-file=/etc/my.cnf --basedir=/usr/local/mariadb \
        --datadir="${MariaDB_Data_Dir}" --user=mariadb || exit 1
    chown -R mariadb:mariadb ${MariaDB_Data_Dir}
    _Database_Init_Password mariadb mariadb || exit 1
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    Svc_Install_Unit "${cur_dir}/init.d/mariadb.service" /etc/systemd/system/mariadb.service || exit 1
    chmod 755 /etc/init.d/mariadb
    _Database_MariaDB_Initd_Names /etc/init.d/mariadb /usr/local/mariadb/bin
    Patch_Init_Runtime_Directory /etc/init.d/mariadb /run/mysqld mariadb mariadb || exit 1

    _Database_MariaDB_Secure || exit 1
    /etc/init.d/mariadb start

    client_bin=$(First_Executable /usr/local/mariadb/bin/mariadb /usr/local/mariadb/bin/mysql) || exit 1
    upgrade_bin=$(First_Executable /usr/local/mariadb/bin/mariadb-upgrade /usr/local/mariadb/bin/mysql_upgrade) || exit 1
    safe_bin=$(First_Executable /usr/local/mariadb/bin/mariadbd-safe /usr/local/mariadb/bin/mysqld_safe) || exit 1
    echo "正在恢复数据库备份..."
    if ! "${client_bin}" --defaults-file="${HOME}/.my.cnf" --max-allowed-packet=1G < /root/mariadb_all_backup${Upgrade_Date}.sql; then
        Echo_Red "备份导入失败，数据未完整恢复。"
        exit 1
    fi
    echo "正在检查并修复数据库..."
    if ! "${upgrade_bin}" --defaults-file="${HOME}/.my.cnf"; then
        Echo_Red "MariaDB 升级程序执行失败。"
        exit 1
    fi

    /etc/init.d/mariadb stop
    cd "${cur_dir}" && rm -rf "${cur_dir}/src/mariadb-${mariadb_version}"

    lnmp start
    # 升级成功需确认服务可连接、数据库列表完整且仍保持本地监听限制。
    if [[ -x "${client_bin}" && -x "${safe_bin}" && -s /etc/my.cnf ]] \
        && _Database_Verify_Upgraded "${client_bin}" "${DB_List_Before}" "${DB_Port}"; then
        _Database_Guard_Disarm
        TempMycnf_Clean
        Echo_Green "======== MariaDB 升级完成 ======"
        rm -f "${DB_List_Before}"
    else
        Echo_Red "======== MariaDB 升级失败 ======"
        Echo_Red "MariaDB 升级日志：/root/upgrade_mariadb${Upgrade_Date}.log"
        exit 1
    fi
}

_Database_Migrate_Run()
{
    local install_db client_bin upgrade_bin safe_bin

    mariadb_version=$1
    Bin=n
    [ "$2" = bin ] && Bin=y
    if [ "${Bin}" = "y" ]; then
        MariaDB_FileName="mariadb-${mariadb_version}-linux-systemd-${DB_ARCH}"
    else
        MariaDB_FileName="mariadb-${mariadb_version}"
    fi
    DB_List_Before="/root/db_list_before${Upgrade_Date}.txt"

    _Database_Backup_Migrate

    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] 正在使用官方通用二进制包安装 ${Mariadb_Ver}..."
        Tar_Cd ${MariaDB_FileName}.tar.gz
        mkdir /usr/local/mariadb
        mv ${MariaDB_FileName}/* /usr/local/mariadb/
    else
        Echo_Blue "[+] 正在使用源码安装 ${Mariadb_Ver}..."
        Tar_Cd mariadb-${mariadb_version}.tar.gz mariadb-${mariadb_version}
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DMYSQL_UNIX_ADDR=/run/mysqld/mysqld.sock -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITHOUT_TOKUDB=1
        if ! Make_Install; then
            Echo_Red "编译失败，迁移中止，旧数据库将自动放回并重新启动。"
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
# 迁移后的数据库继续仅监听回环地址，避免重写配置时撤销访问限制。
# 需要远程连库时改为具体地址，并同步调整防火墙放行与账号 Host 授权范围。
bind-address = 127.0.0.1
user    = mariadb
basedir = /usr/local/mariadb
datadir = ${MariaDB_Data_Dir}
log_error = ${MariaDB_Data_Dir}/mariadb.err
pid-file = ${MariaDB_Data_Dir}/mariadb.pid
skip-external-locking
key_buffer_size = 16M
max_allowed_packet = 64M
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
max_allowed_packet = 64M

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
    _Database_Tune
    # 搬迁成功后该路径应当为空；非空说明上一步没搬干净，此时拒绝而不是清空。
    Require_Empty_Data_Dir "${MariaDB_Data_Dir}" || exit 1
    _Database_Own_Tree /usr/local/mariadb "${MariaDB_Data_Dir}" mariadb || exit 1
    install_db=$(First_Executable \
        /usr/local/mariadb/scripts/mariadb-install-db /usr/local/mariadb/scripts/mysql_install_db \
        /usr/local/mariadb/bin/mariadb-install-db /usr/local/mariadb/bin/mysql_install_db) || exit 1
    "${install_db}" --defaults-file=/etc/my.cnf --basedir=/usr/local/mariadb \
        --datadir="${MariaDB_Data_Dir}" --user=mariadb || exit 1
    chown -R mariadb:mariadb ${MariaDB_Data_Dir}
    _Database_Init_Password mariadb mariadb || exit 1
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    Svc_Install_Unit "${cur_dir}/init.d/mariadb.service" /etc/systemd/system/mariadb.service || exit 1
    chmod 755 /etc/init.d/mariadb
    _Database_MariaDB_Initd_Names /etc/init.d/mariadb /usr/local/mariadb/bin
    Patch_Init_Runtime_Directory /etc/init.d/mariadb /run/mysqld mariadb mariadb || exit 1

    _Database_MariaDB_Secure || exit 1
    /etc/init.d/mariadb start

    client_bin=$(First_Executable /usr/local/mariadb/bin/mariadb /usr/local/mariadb/bin/mysql) || exit 1
    upgrade_bin=$(First_Executable /usr/local/mariadb/bin/mariadb-upgrade /usr/local/mariadb/bin/mysql_upgrade) || exit 1
    safe_bin=$(First_Executable /usr/local/mariadb/bin/mariadbd-safe /usr/local/mariadb/bin/mysqld_safe) || exit 1
    echo "正在导入业务库与账号..."
    # 跨引擎导入不完整时立即中止，并保留原 MySQL 实例用于恢复。
    if ! "${client_bin}" --defaults-file="${HOME}/.my.cnf" --max-allowed-packet=1G < "/root/mysql_user_dbs${Upgrade_Date}.sql"; then
        Echo_Red "业务库导入失败，数据未完整迁移到 MariaDB。"
        exit 1
    fi
    if ! "${client_bin}" --defaults-file="${HOME}/.my.cnf" < "/root/mysql2mariadb_accounts${Upgrade_Date}.sql"; then
        Echo_Red "账号与授权导入失败。"
        exit 1
    fi
    echo "MariaDB 数据库导入成功。"

    echo "正在检查并修复数据库..."
    if ! "${upgrade_bin}" --defaults-file="${HOME}/.my.cnf"; then
        Echo_Red "MariaDB 升级程序执行失败。"
        _Database_Migrate_Restore_Links "/usr/local/mysql2mariadb${Upgrade_Date}"
        exit 1
    fi

    echo "正在加入开机自启..."
    StartUp mariadb
    echo "正在停止 MariaDB..."
    /etc/init.d/mariadb stop
    cd "${cur_dir}" && rm -rf "${cur_dir}/src/mariadb-${mariadb_version}"

    lnmp start
    # 迁移成功需确认服务可连接、数据库列表完整且仍保持本地监听限制。
    if [[ -x "${client_bin}" && -x "${safe_bin}" && -s /etc/my.cnf ]] \
        && _Database_Verify_Upgraded "${client_bin}" "${DB_List_Before}" "${DB_Port}"; then
        _Database_Guard_Disarm
        TempMycnf_Clean
        Echo_Green "======== MySQL 迁移到 MariaDB 完成 ======"
        rm -f "${DB_List_Before}" "/root/mysql_user_dbs${Upgrade_Date}.sql" "/root/mysql2mariadb_accounts${Upgrade_Date}.sql"
        if [ -s "/root/mysql2mariadb_passwords${Upgrade_Date}.txt" ]; then
            Echo_Yellow "以下文件列出改为随机口令的账号（仅 root 可读），请同步修改站点的数据库配置："
            Echo_Yellow "  /root/mysql2mariadb_passwords${Upgrade_Date}.txt"
        fi
    else
        Echo_Red "======== MySQL 迁移到 MariaDB 失败 ======"
        Echo_Red "迁移日志：/root/upgrade_mysql2mariadb${Upgrade_Date}.log"
        _Database_Migrate_Restore_Links "/usr/local/mysql2mariadb${Upgrade_Date}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 数据库升级失败陷阱
#
# 升级流程先停旧库并把程序、init 脚本、配置和外置数据目录整体搬走，之后才
# 构建、初始化新实例。这中间任何一步失败直接退出，都会让所有依赖数据库的站点
# 持续中断，因此搬迁完成后统一挂上陷阱，退出前自动把旧实例放回原位并启动。
# ---------------------------------------------------------------------------
# 守卫状态保存在 DB_Upgrade_Guard_* 变量中，只在升级子 shell 内有效。

# 检查备份非空且包含 mysqldump 结束标记，防止使用截断文件升级。
_Database_Check_Backup()
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
_Database_Snapshot()
{
    local bin="$1" out="$2"

    "${bin}" --defaults-file="${HOME}/.my.cnf" -N -B -e "SHOW DATABASES;" 2>/dev/null \
        | grep -Ev '^(information_schema|performance_schema|sys)$' \
        | LC_ALL=C sort > "${out}"
    if [ ! -s "${out}" ]; then
        Echo_Red "无法读取升级前的数据库列表。"
        return 1
    fi
    return 0
}

# 升级后检查连接、端口、数据库列表和本地监听限制。
_Database_Verify_Upgraded()
{
    local bin="$1" before="$2" port="${3:-3306}" xport="${4:-}"
    local after missing actual_port actual_xport rc=0

    if ! "${bin}" --defaults-file="${HOME}/.my.cnf" -e "SELECT 1;" >/dev/null 2>&1; then
        Echo_Red "升级后无法连接数据库。"
        return 1
    fi

    actual_port=$("${bin}" --defaults-file="${HOME}/.my.cnf" -N -B -e "SELECT @@port;" 2>/dev/null)
    if [ "${actual_port}" != "${port}" ]; then
        Echo_Red "升级后数据库实际端口为 ${actual_port:-未知}，期望 ${port}。"
        rc=1
    fi
    if [ -n "${xport}" ]; then
        actual_xport=$("${bin}" --defaults-file="${HOME}/.my.cnf" -N -B -e "SELECT @@mysqlx_port;" 2>/dev/null)
        if [ "${actual_xport}" != "${xport}" ]; then
            Echo_Red "升级后 MySQL X Protocol 实际端口为 ${actual_xport:-未知}，期望 ${xport}。"
            rc=1
        fi
    fi

    after=$(mktemp) || return 1
    if ! _Database_Snapshot "${bin}" "${after}"; then
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
_Database_Guard_Abort()
{
    Echo_Red "======== 自动回滚未完成，已保留现场 ======"
    Echo_Red "数据备份：$1"
    Echo_Red "原实例目录：$2"
    Echo_Red "上述内容均未删除，可据此手工回滚。修复问题前请勿重复执行升级。"
    return 1
}

# _Database_Guard_Arm <备份文件> <原实例目录> <服务名> <旧客户端路径> <新实例目录> [额外还原函数]
_Database_Guard_Arm()
{
    DB_Upgrade_Guard_Backup="$1"
    DB_Upgrade_Guard_OldPrefix="$2"
    DB_Upgrade_Guard_Service="$3"
    DB_Upgrade_Guard_Client="$4"
    DB_Upgrade_Guard_Prefix="$5"
    DB_Upgrade_Guard_Post="${6:-}"
    DB_Upgrade_Guard_Active='y'
    # INT/TERM 的处理函数返回后脚本会继续往下走，因此这两个信号显式退出。
    # 回滚需要读取临时客户端配置，因此清理排在回滚之后；成功路径在验收通过后清理。
    trap '_Database_Guard_Fire; TempMycnf_Clean' EXIT
    trap '_Database_Guard_Fire; TempMycnf_Clean; exit 130' INT
    trap '_Database_Guard_Fire; TempMycnf_Clean; exit 143' TERM
}

# 升级确认成功后解除，之后的正常退出不再触发回滚。
_Database_Guard_Disarm()
{
    DB_Upgrade_Guard_Active='n'
    trap - INT TERM
    trap 'TempMycnf_Clean' EXIT
}

_Database_Guard_Fire()
{
    [ "${DB_Upgrade_Guard_Active}" = 'y' ] || return 0
    # 回滚过程中的退出不再重复触发。
    DB_Upgrade_Guard_Active='n'
    trap - EXIT INT TERM
    _Database_Guard_Rollback
}

# 自动回滚：隔离本次新建的实例，按逆序还原旧程序、init 脚本、配置和外置数据
# 目录，再启动旧服务并确认可连接。只有回滚自身失败才保留现场并给人工命令。
_Database_Guard_Rollback()
{
    local backup="${DB_Upgrade_Guard_Backup}"
    local old_prefix="${DB_Upgrade_Guard_OldPrefix}"
    local service="${DB_Upgrade_Guard_Service}"
    local client="${DB_Upgrade_Guard_Client}"
    local prefix="${DB_Upgrade_Guard_Prefix}"

    Echo_Yellow "======== 升级未完成，正在自动回滚到升级前的数据库 ======"

    # 新实例可能已经启动，进程不退出就搬不走目录，旧实例也会撞上同一个 socket。
    # 迁移场景里新旧 init 脚本名不同，两个都尝试停止。
    local svc
    for svc in mysql mariadb; do
        [ -x "/etc/init.d/${svc}" ] && "/etc/init.d/${svc}" stop >/dev/null 2>&1
    done
    if ! Ensure_DB_Stopped "${prefix}/bin/(mysqld|mariadbd)"; then
        Echo_Red "新实例的数据库进程仍在运行，无法自动回滚。"
        _Database_Guard_Abort "${backup}" "${old_prefix}"
        return 1
    fi

    if ! Quarantine_Upgrade_Targets "${Upgrade_Date}"; then
        _Database_Guard_Abort "${backup}" "${old_prefix}"
        return 1
    fi
    if ! Rollback_Upgrade_Moves; then
        _Database_Guard_Abort "${backup}" "${old_prefix}"
        return 1
    fi
    ldconfig 2>/dev/null

    if [ -n "${DB_Upgrade_Guard_Post}" ] && ! "${DB_Upgrade_Guard_Post}"; then
        Echo_Red "回滚的额外还原步骤 ${DB_Upgrade_Guard_Post} 失败。"
        _Database_Guard_Abort "${backup}" "${old_prefix}"
        return 1
    fi

    if [ ! -x "/etc/init.d/${service}" ]; then
        Echo_Red "还原后仍找不到 /etc/init.d/${service}，无法启动旧数据库。"
        _Database_Guard_Abort "${backup}" "${old_prefix}"
        return 1
    fi
    if ! "/etc/init.d/${service}" start; then
        Echo_Red "旧数据库服务启动失败。"
        _Database_Guard_Abort "${backup}" "${old_prefix}"
        return 1
    fi
    # 启动成功不代表能登录，用升级前的凭据实际连一次。旧实例目录已还原到 /usr/local/<服务名>。
    case "${client}" in
    "${old_prefix}"/*) client="/usr/local/${service}/${client#"${old_prefix}"/}" ;;
    esac
    if [ ! -x "${client}" ] || [ ! -s "${HOME}/.my.cnf" ] \
       || ! "${client}" --defaults-file="${HOME}/.my.cnf" -e "SELECT 1;" >/dev/null 2>&1; then
        Echo_Red "旧数据库已启动，但用升级前的凭据连接失败或凭据缺失。"
        _Database_Guard_Abort "${backup}" "${old_prefix}"
        return 1
    fi

    # 升级开始时执行过 lnmp stop，回滚后把 Web 和 PHP 一并拉起来。
    [ -x /bin/lnmp ] && /bin/lnmp start

    Echo_Green "======== 已回滚到升级前的数据库，服务已恢复 ======"
    Echo_Yellow "数据备份保留在 ${backup}。"
    Echo_Yellow "本次失败的新实例以 .failed.${Upgrade_Date} 结尾保留，确认无用后可删除。"
    return 0
}

_Database_Backup_MySQL()
{
    echo "正在备份全部数据库..."
    echo "数据库较大时，备份所需时间会更长。"
    /usr/local/mysql/bin/mysqldump --defaults-file="${HOME}/.my.cnf" --max-allowed-packet=1G --all-databases > /root/mysql_all_backup${Upgrade_Date}.sql
    if [ $? -eq 0 ]; then
        echo "MySQL 数据库备份成功。";
    else
        echo "MySQL 数据库备份失败，请手动备份数据库！"
        exit 1
    fi
    # 同时确认备份结束标记，并记录升级前库列表供完成后核对。
    _Database_Check_Backup "/root/mysql_all_backup${Upgrade_Date}.sql" || exit 1
    _Database_Snapshot /usr/local/mysql/bin/mysql "${DB_List_Before}" || exit 1
    lnmp stop
    Ensure_DB_Stopped "/usr/local/mysql/bin/mysqld" || exit 1

    LNMP_Moved_Items=()
    Move_For_Upgrade /usr/local/mysql "/usr/local/oldmysql${Upgrade_Date}" || Abort_Upgrade_Move
    Move_For_Upgrade /etc/init.d/mysql \
        "/usr/local/oldmysql${Upgrade_Date}/init.d.mysql.bak.${Upgrade_Date}" || Abort_Upgrade_Move
    Move_For_Upgrade /etc/my.cnf \
        "/usr/local/oldmysql${Upgrade_Date}/my.cnf.bak.${Upgrade_Date}" || Abort_Upgrade_Move
    if [ "${MySQL_Data_Dir}" != "/usr/local/mysql/var" ]; then
        Move_For_Upgrade "${MySQL_Data_Dir}" "${MySQL_Data_Dir}${Upgrade_Date}" || Abort_Upgrade_Move
    fi

    # 旧实例已搬走，此后任何退出都要自动放回并重新启动。
    _Database_Guard_Arm "/root/mysql_all_backup${Upgrade_Date}.sql" \
        "/usr/local/oldmysql${Upgrade_Date}" mysql \
        "/usr/local/oldmysql${Upgrade_Date}/bin/mysql" /usr/local/mysql
}

# 8.0 与 8.4 的升级构建相同。
_Database_Build_MySQL()
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
        mkdir build && cd build || exit 1
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local/mysql -DSYSCONFDIR=/etc -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITH_UNIT_TESTS=OFF -DWITH_ROUTER=OFF ${MySQL_WITH_BOOST}
        if ! Make_Install 1536; then
            Echo_Red "编译失败，升级中止，旧数据库将自动放回并重新启动。"
            exit 1
        fi
    fi

    groupadd mysql
    useradd -s /sbin/nologin -M -g mysql mysql
cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = ${DB_Port}
socket      = /run/mysqld/mysqld.sock

[mysqld]
port        = ${DB_Port}
socket      = /run/mysqld/mysqld.sock
# 升级后的数据库继续仅监听回环地址，避免重写配置时撤销访问限制。
# 需要远程连库时改为具体地址，并同步调整防火墙放行与账号 Host 授权范围。
bind-address = 127.0.0.1
# X Protocol（33060 端口）由独立选项控制，bind-address 对其无效。
# loose- 前缀用于在 mysqlx 插件被关闭时避免 mysqld 因未知选项拒绝启动。
loose-mysqlx-bind-address = 127.0.0.1
loose-mysqlx-port = ${DB_X_Port}
datadir = ${MySQL_Data_Dir}
skip-external-locking
key_buffer_size = 16M
max_allowed_packet = 64M
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
max_allowed_packet = 64M

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

    _Database_Tune
    # MySQL 8.4 及以上转换弃用配置，较低版本保持原配置。
    _Database_MySQL_Deprecated "${mysql_version%.*}"
    # 搬迁成功后该路径应当为空；非空说明上一步没搬干净，此时拒绝而不是清空。
    Require_Empty_Data_Dir "${MySQL_Data_Dir}" || exit 1
    _Database_Own_Tree /usr/local/mysql "${MySQL_Data_Dir}" mysql || exit 1
    /usr/local/mysql/bin/mysqld --initialize-insecure --basedir=/usr/local/mysql --datadir=${MySQL_Data_Dir} --user=mysql || exit 1
    chown -R mysql:mysql ${MySQL_Data_Dir}
    _Database_Init_Password mysql mysql || exit 1
    cat > /etc/ld.so.conf.d/mysql.conf<<EOF
/usr/local/mysql/lib
/usr/local/lib
EOF

    ldconfig
    ln -sfn /usr/local/mysql/lib/mysql /usr/lib/mysql
    ln -sfn /usr/local/mysql/include/mysql /usr/include/mysql
}

_Database_Restore_MySQL()
{
    chgrp -R mysql /usr/local/mysql/.
    \cp /usr/local/mysql/support-files/mysql.server /etc/init.d/mysql
    Svc_Install_Unit "${cur_dir}/init.d/mysql.service" /etc/systemd/system/mysql.service || exit 1
    chmod 755 /etc/init.d/mysql
    Patch_Init_Runtime_Directory /etc/init.d/mysql /run/mysqld mysql mysql || exit 1

    ldconfig

    _Database_MySQL_Secure || exit 1
    /etc/init.d/mysql start

    echo "正在恢复数据库备份..."
    if ! /usr/local/mysql/bin/mysql --defaults-file="${HOME}/.my.cnf" --max-allowed-packet=1G < /root/mysql_all_backup${Upgrade_Date}.sql; then
        Echo_Red "备份导入失败，数据未完整恢复。"
        exit 1
    fi
    echo "正在检查并修复数据库..."
    MySQL_Ver_Com=$(Version_Compare 8.0.16 ${mysql_version})
    if [ "${MySQL_Ver_Com}" != "1" ]; then
        /etc/init.d/mysql stop
        # systemd 停止服务时按 RuntimeDirectory 删除 /run/mysqld，手工启动前须重建，否则无法创建 socket 锁文件。
        Ensure_Runtime_Directory /run/mysqld mysql mysql || exit 1
        echo "正在升级 MySQL 系统表..."
        /usr/local/mysql/bin/mysqld --user=mysql --upgrade=FORCE &
        mysqld_pid=$!
        echo "正在等待升级完成..."
        # --upgrade=FORCE 完成后才接受连接，因此轮询 ping 判断结果，最长等待
        # 30 分钟；后台进程提前退出时立即结束等待。
        upgrade_wait=0
        while [ ${upgrade_wait} -lt 1800 ]; do
            /usr/local/mysql/bin/mysqladmin --defaults-file="${HOME}/.my.cnf" ping >/dev/null 2>&1 && break
            kill -0 ${mysqld_pid} 2>/dev/null || break
            sleep 1
            upgrade_wait=$((upgrade_wait + 1))
        done
        if ! /usr/local/mysql/bin/mysqladmin --defaults-file="${HOME}/.my.cnf" ping >/dev/null 2>&1; then
            Echo_Red "MySQL 强制升级未能完成，等待 ${upgrade_wait} 秒后实例仍无响应。"
            kill ${mysqld_pid} 2>/dev/null
            exit 1
        fi
        /usr/local/mysql/bin/mysqladmin --defaults-file="${HOME}/.my.cnf" shutdown
        wait ${mysqld_pid}
    else
        if ! /usr/local/mysql/bin/mysql_upgrade --defaults-file="${HOME}/.my.cnf"; then
            Echo_Red "mysql_upgrade 执行失败。"
            exit 1
        fi
    fi

    /etc/init.d/mysql stop
    cd "${cur_dir}" && rm -rf "${cur_dir}/src/mysql-${mysql_version}"

    lnmp start
    # 升级成功需确认服务可连接、数据库列表完整且仍保持本地监听限制。
    if [[ -s /usr/local/mysql/bin/mysql && -s /usr/local/mysql/bin/mysqld_safe && -s /etc/my.cnf ]] \
        && _Database_Verify_Upgraded /usr/local/mysql/bin/mysql "${DB_List_Before}" "${DB_Port}" "${DB_X_Port}"; then
        _Database_Guard_Disarm
        TempMycnf_Clean
        Echo_Green "======== MySQL 升级完成 ======"
        rm -f "${DB_List_Before}"
    else
        Echo_Red "======== MySQL 升级失败 ======"
        Echo_Red "MySQL 升级日志：/root/upgrade_mysq${Upgrade_Date}.log"
        exit 1
    fi
}

_Database_Backup_MariaDB()
{
    local dump_bin client_bin

    dump_bin=$(First_Executable /usr/local/mariadb/bin/mariadb-dump /usr/local/mariadb/bin/mysqldump) || exit 1
    client_bin=$(First_Executable /usr/local/mariadb/bin/mariadb /usr/local/mariadb/bin/mysql) || exit 1
    echo "正在备份全部数据库..."
    echo "数据库较大时，备份所需时间会更长。"
    "${dump_bin}" --defaults-file="${HOME}/.my.cnf" --max-allowed-packet=1G --all-databases > /root/mariadb_all_backup${Upgrade_Date}.sql
    if [ $? -eq 0 ]; then
        echo "MariaDB 数据库备份成功。";
    else
        echo "MariaDB 数据库备份失败，请手动备份数据库！"
        exit 1
    fi
    # 同时确认备份结束标记，并记录升级前库列表供完成后核对。
    _Database_Check_Backup "/root/mariadb_all_backup${Upgrade_Date}.sql" || exit 1
    _Database_Snapshot "${client_bin}" "${DB_List_Before}" || exit 1
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
    _Database_Guard_Arm "/root/mariadb_all_backup${Upgrade_Date}.sql" \
        "/usr/local/oldmariadb${Upgrade_Date}" mariadb \
        "/usr/local/oldmariadb${Upgrade_Date}/bin/mariadb" /usr/local/mariadb
}

_Database_Backup_Migrate()
{
    local p

    # 新实例的路径须事先不存在，回滚时才能整体隔离而不误移其它文件。
    for p in /usr/local/mariadb /etc/init.d/mariadb; do
        if [ -e "${p}" ]; then
            Echo_Red "${p} 已存在，迁移需要该路径为空。数据库未做任何改动。"
            exit 1
        fi
    done
    echo "正在备份全部数据库..."
    echo "数据库较大时，备份所需时间会更长。"
    /usr/local/mysql/bin/mysqldump --defaults-file="${HOME}/.my.cnf" --max-allowed-packet=1G --all-databases > /root/mysql_all_backup${Upgrade_Date}.sql
    if [ $? -eq 0 ]; then
        echo "MySQL 数据库备份成功。";
    else
        echo "MySQL 数据库备份失败，请手动备份数据库！"
        exit 1
    fi
    # 同时确认备份结束标记，并记录迁移前库列表供完成后核对。
    _Database_Check_Backup "/root/mysql_all_backup${Upgrade_Date}.sql" || exit 1
    _Database_Snapshot /usr/local/mysql/bin/mysql "${DB_List_Before}" || exit 1
    # 完整备份只用于回滚；导入 MariaDB 使用业务库导出与账号 SQL。
    if ! _Database_Migrate_Export; then
        Echo_Red "导出业务库或账号失败，数据库未做任何改动。"
        _Database_Migrate_Clean_Files
        exit 1
    fi
    lnmp stop
    Ensure_DB_Stopped "/usr/local/mysql/bin/mysqld" || exit 1
    echo "正在移除旧数据库的开机自启..."
    Remove_StartUp mysql

    LNMP_Moved_Items=()
    Move_For_Upgrade /usr/local/mysql "/usr/local/mysql2mariadb${Upgrade_Date}" || Abort_Upgrade_Move
    Move_For_Upgrade /etc/init.d/mysql \
        "/usr/local/mysql2mariadb${Upgrade_Date}/init.dmysql2mariadb.bak.${Upgrade_Date}" || Abort_Upgrade_Move
    Move_For_Upgrade /etc/my.cnf \
        "/usr/local/mysql2mariadb${Upgrade_Date}/my.cnf.mysql2mariadbbak.${Upgrade_Date}" || Abort_Upgrade_Move
    if [ "${MariaDB_Data_Dir}" != "/usr/local/mariadb/var" ]; then
        Move_For_Upgrade "${MariaDB_Data_Dir}" "${MariaDB_Data_Dir}${Upgrade_Date}" || Abort_Upgrade_Move
    fi

    # 旧实例已搬走，此后任何退出都要自动放回并重新启动。
    # 本流程还改过命令链接和开机自启，交给额外还原步骤处理。
    _Database_Guard_Arm "/root/mysql_all_backup${Upgrade_Date}.sql" \
        "/usr/local/mysql2mariadb${Upgrade_Date}" mysql \
        "/usr/local/mysql2mariadb${Upgrade_Date}/bin/mysql" /usr/local/mariadb \
        _Database_Migrate_Restore_Stack
}

# 迁移回滚的额外还原：命令链接指回 MySQL，恢复开机自启。
# 管理命令每次运行时自行探测数据库服务，不需要改写。
# _Database_Migrate_Clean_Files：删除迁移用的导出、账号 SQL 与新口令清单（含口令，失败时不保留）。
_Database_Migrate_Clean_Files()
{
    local f

    while read -r f; do
        rm -f "${f}"
    done < <(_Database_Migrate_Files)
}

# 迁移回滚的额外步骤：隔离本次新建的 MariaDB 程序与服务文件，恢复 MySQL 命令链接、unit 与开机自启。
_Database_Migrate_Restore_Stack()
{
    local rc=0 p aside

    for p in /usr/local/mariadb /etc/init.d/mariadb; do
        [ -e "${p}" ] || continue
        aside="${p}.failed.${Upgrade_Date}"
        [ -e "${aside}" ] && rm -rf -- "${aside}"
        mv -- "${p}" "${aside}" && echo "已隔离本次迁移新建的：${p} -> ${aside}" || rc=1
    done
    if [ -e /etc/systemd/system/mariadb.service ]; then
        rm -f /etc/systemd/system/mariadb.service
        Svc_Reload_Units
    fi
    _Database_Remove_Command_Links mariadb
    _Database_Migrate_Restore_Links "/usr/local/mysql2mariadb${Upgrade_Date}" || rc=1
    Svc_Install_Unit "${cur_dir}/init.d/mysql.service" /etc/systemd/system/mysql.service || rc=1
    StartUp mysql || rc=1
    _Database_Migrate_Clean_Files
    return ${rc}
}

# 迁移失败时将 /usr/bin 中的数据库命令恢复到备份的 MySQL，确保服务回滚后
# 管理命令不会继续调用未完成的 MariaDB 安装。
_Database_Migrate_Restore_Links()
{
    local old_dir="$1" command path target

    for command in mariadb mariadb-dump mariadb-admin mariadb-check mariadb-upgrade mariadbd-safe; do
        path="/usr/bin/${command}"
        [ -L "${path}" ] || continue
        target=$(readlink "${path}" 2>/dev/null)
        case "${target}" in
            /usr/local/mariadb/*) rm -f "${path}" ;;
        esac
    done

    # 回滚还原后旧目录已回到 /usr/local/mysql。
    [ -d "${old_dir}" ] || old_dir=/usr/local/mysql
    for command in mysql mysqldump mysqladmin mysqlcheck mysql_upgrade mysqld_safe myisamchk; do
        [ -x "${old_dir}/bin/${command}" ] || continue
        ln -sfn "/usr/local/mysql/bin/${command}" "/usr/bin/${command}" || return 1
    done
}

# _Database_Remove_Command_Links <种类>：只删除仍指向该种类安装目录的软链接，种类为 mariadb 时
# 另删带 LNMP 标记的包装器。非本包安装的同名系统客户端不在清理范围内。
_Database_Remove_Command_Links()
{
    local kind=$1 command path target first second

    for command in mysql mysqldump mysqladmin mysqlcheck mysql_upgrade mysqld_safe \
                   mariadb mariadb-dump mariadb-admin mariadb-check mariadb-upgrade mariadbd-safe \
                   myisamchk; do
        path="/usr/bin/${command}"
        if [ -L "${path}" ]; then
            target=$(readlink "${path}" 2>/dev/null)
            case "${target}" in
                "/usr/local/${kind}/"*) rm -f "${path}" ;;
            esac
        elif [ "${kind}" = mariadb ] && [ -f "${path}" ]; then
            first=$(sed -n '1p' "${path}")
            second=$(sed -n '2p' "${path}")
            if [ "${first}" = '#!/bin/sh' ] \
                && [ "${second}" = '# LNMP MariaDB compatibility wrapper' ]; then
                rm -f "${path}"
            fi
        fi
    done
}

# _Database_Remove_Dev_Links <种类>：清理本包建立的头文件与库链接和动态库搜索路径配置。
# 只处理仍指向该种类安装目录的链接，留下的悬空链接会让下次安装的 ln 建出自指链接。
_Database_Remove_Dev_Links()
{
    local kind=$1 link target conf changed='n'

    for link in /usr/include/mysql /usr/lib/mysql \
                /usr/include/mariadb /usr/lib/mariadb; do
        [ -L "${link}" ] || continue
        target=$(readlink "${link}" 2>/dev/null)
        case "${target}" in
            "/usr/local/${kind}/"*)
                rm -f "${link}"
                changed='y'
                ;;
        esac
    done

    for conf in /etc/ld.so.conf.d/mysql.conf /etc/ld.so.conf.d/mariadb.conf; do
        [ -f "${conf}" ] || continue
        grep -Eq "^[[:space:]]*/usr/local/${kind}/lib" "${conf}" || continue
        rm -f "${conf}"
        changed='y'
    done

    [ "${changed}" = 'y' ] && ldconfig 2>/dev/null
    return 0
}

# 仅清理本包为数据库通用二进制包建立的 libaio.so.1 兼容链接：必须是符号链接，
# 且指向 libaio.so.1t64*。发行版自带的实体库或指向别处的链接一律不动。
_Database_Remove_Libaio_Link()
{
    local link target

    for link in $(ldconfig -p 2>/dev/null | awk '$1 == "libaio.so.1t64" {print $NF}' \
                  | xargs -r -n1 dirname | sort -u | sed 's:$:/libaio.so.1:'); do
        [ -L "${link}" ] || continue
        target=$(readlink "${link}")
        case "${target##*/}" in
        libaio.so.1t64*)
            rm -f "${link}"
            ldconfig
            ;;
        esac
    done
}

# Database_Remove <种类> [数据目录...]：停止服务后把 my.cnf 的 datadir 与给出的数据目录移到
# /root/databases_backup_<时间戳>，再删除程序目录、my.cnf、init 脚本、启动项与命令和库链接。
# 另一种数据库的程序目录仍在时不读取、不删除 /etc/my.cnf；本种类没有程序目录与 init 脚本时直接返回 0。
# 返回 0 已删除；1 有残留；2 服务端仍在运行或数据目录移动失败，未删除任何文件；3 参数错误。
Database_Remove()
{
    local kind=$1 other=mysql own_conf=y datadir='' dir pid exe path rc=0 seen=''

    case "${kind}" in mysql|mariadb) ;; *) return 3 ;; esac
    shift
    [ "${kind}" = mysql ] && other=mariadb
    if [ -d "/usr/local/${other}" ]; then
        [ -e "/usr/local/${kind}" ] || [ -e "/etc/init.d/${kind}" ] || return 0
        own_conf=n
    fi
    [ "${own_conf}" = y ] && datadir=$(Db_Conf_Value datadir)

    [ -x "/etc/init.d/${kind}" ] && "/etc/init.d/${kind}" stop >/dev/null 2>&1
    if command -v pgrep >/dev/null 2>&1; then
        for pid in $(pgrep -x mysqld; pgrep -x mariadbd); do
            exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null)
            case "${exe}" in
            "/usr/local/${kind}/"*)
                Echo_Red "${kind} 服务端仍在运行（pid ${pid}），未删除任何文件。"
                return 2
                ;;
            esac
        done
    fi
    for dir in "${datadir}" "$@"; do
        [ -n "${dir}" ] || continue
        case " ${seen} " in *" ${dir} "*) continue ;; esac
        seen="${seen} ${dir}"
        if ! Backup_DB_Data "${dir}"; then
            # 未删除任何文件，恢复服务。
            [ -x "/etc/init.d/${kind}" ] && "/etc/init.d/${kind}" start >/dev/null 2>&1
            return 2
        fi
    done

    Remove_StartUp "${kind}" >/dev/null 2>&1
    _Database_Remove_Command_Links "${kind}"
    _Database_Remove_Dev_Links "${kind}"
    rm -rf -- "/usr/local/${kind:?}"
    rm -f "/etc/init.d/${kind}"
    [ "${own_conf}" = y ] && rm -f /etc/my.cnf
    _Database_Remove_Libaio_Link
    if [ "${own_conf}" = y ]; then
        for path in /run/mysqld/mysqld.sock /run/mysqld/mysqld.pid; do
            [ -e "${path}" ] || continue
            if fuser "${path}" >/dev/null 2>&1; then
                Echo_Red "${path} 仍被进程占用，未删除。"
                rc=1
                continue
            fi
            rm -f "${path}"
        done
        rmdir /run/mysqld 2>/dev/null
        find /run -maxdepth 1 -name 'lnmp-db-init.*' -type d -exec rm -rf {} + 2>/dev/null
    fi

    for path in "/usr/local/${kind}" "/etc/init.d/${kind}"; do
        [ -e "${path}" ] && rc=1
    done
    [ "${own_conf}" = y ] && [ -e /etc/my.cnf ] && rc=1
    return ${rc}
}
