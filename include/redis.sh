#!/usr/bin/env bash

Set_Redis_Loopback_Bind()
{
    local conf="$1"

    if grep -Eq '^[[:space:]]*bind[[:space:]]+' "${conf}"; then
        sed -i -E 's/^[[:space:]]*bind[[:space:]].*/bind 127.0.0.1 -::1/' "${conf}"
    else
        printf '\n# LNMP: Redis 仅监听本机回环地址。\nbind 127.0.0.1 -::1\n' >> "${conf}"
    fi
    Check_Conf_Applied "${conf}" \
        '^bind[[:space:]]+127\.0\.0\.1([[:space:]]+-::1)?[[:space:]]*$' \
        'Redis 回环监听地址' || return 1
}

# 服务以 redis 账号运行，程序目录必须可遍历、配置可读、数据目录可写。
# 安装可能继承调用者的严格 umask，因此这里按目标权限显式修正。
Normalize_Redis_Perms()
{
    id -u redis >/dev/null 2>&1 || return 0
    chmod 755 /usr/local/redis /usr/local/redis/bin 2>/dev/null
    chown root:redis /usr/local/redis/etc 2>/dev/null
    chmod 750 /usr/local/redis/etc 2>/dev/null
    chown root:redis /usr/local/redis/etc/redis.conf 2>/dev/null
    chmod 640 /usr/local/redis/etc/redis.conf 2>/dev/null
    chown -R redis:redis /usr/local/redis/var 2>/dev/null
    chmod 750 /usr/local/redis/var 2>/dev/null
    return 0
}

# 启动前以服务账号验证可执行与可读，失败时给出具体路径而不是通用提示。
Check_Redis_Runtime_Access()
{
    command -v runuser >/dev/null 2>&1 || return 0
    if ! runuser -u redis -- test -x /usr/local/redis/bin/redis-server; then
        Echo_Red "redis 账号无法执行 /usr/local/redis/bin/redis-server。"
        Echo_Red "请检查该路径各级目录权限：namei -l /usr/local/redis/bin/redis-server"
        return 1
    fi
    if ! runuser -u redis -- test -r /usr/local/redis/etc/redis.conf; then
        Echo_Red "redis 账号无法读取 /usr/local/redis/etc/redis.conf。"
        Echo_Red "请检查目录与文件权限：namei -l /usr/local/redis/etc/redis.conf"
        return 1
    fi
    if ! runuser -u redis -- test -w /usr/local/redis/var; then
        Echo_Red "redis 账号无法写入数据目录 /usr/local/redis/var。"
        return 1
    fi
    return 0
}

# vm.overcommit_memory=0 时 Redis 每次启动都告警，且低内存下 fork 保存 RDB 可能失败。
# 只在系统仍为默认值 0 时改为 1；值为 2 属使用者显式选择的严格模式，只提示不覆盖。
Set_Redis_Overcommit()
{
    local conf='/etc/sysctl.d/60-lnmp-redis.conf' current=''

    [ -r /proc/sys/vm/overcommit_memory ] || return 0
    current=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null)
    case "${current}" in
    1)  return 0 ;;
    2)  Echo_Yellow "vm.overcommit_memory 当前为 2（严格模式），未修改。"
        Echo_Yellow "Redis 会持续告警 Memory overcommit must be enabled，确认策略后可自行改为 1。"
        return 0 ;;
    esac

    cat >"${conf}"<<EOF
# Redis 后台保存 RDB 时靠 fork 复制内存，overcommit_memory=0 会在低内存下拒绝分配，
# 导致保存失败并在每次启动时告警。由 LNMP 安装 Redis 时写入。
vm.overcommit_memory = 1
EOF
    if [ ! -s "${conf}" ]; then
        Echo_Yellow "写入 ${conf} 失败，vm.overcommit_memory 保持 ${current}，Redis 启动会有告警。"
        return 0
    fi
    chmod 644 "${conf}"
    if sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1; then
        echo "已设置 vm.overcommit_memory=1（${conf}，重启后仍生效）。"
    else
        Echo_Yellow "已写入 ${conf}，但当前内核不接受该设置（容器或受限环境），重启后由宿主决定。"
    fi
    return 0
}

# 端口占用检查复用随包安装的 redis-preflight，与 redis.service 的启动前检查同一实现。
# 脚本尚未就位时不阻断启动，占用问题仍由启动结果判定暴露。
Check_Redis_Port_Free()
{
    local port="$1"

    [ -x /usr/local/redis/bin/redis-preflight ] || return 0
    /usr/local/redis/bin/redis-preflight /usr/local/redis/etc/redis.conf && return 0
    Echo_Red "排查：ss -lntp | grep :${port}"
    return 1
}

# 服务是否由本机管理入口托管；systemd 可用时以 unit 状态为准。
Redis_Service_Active()
{
    if Use_Systemd_Unit redis; then
        systemctl is-active --quiet redis.service
    else
        /etc/init.d/redis status >/dev/null 2>&1
    fi
}

Redis_Ping()
{
    local port="$1" out=''

    [ -x /usr/local/redis/bin/redis-cli ] || return 1
    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout 5 /usr/local/redis/bin/redis-cli -p "${port}" ping 2>/dev/null)
    else
        out=$(/usr/local/redis/bin/redis-cli -p "${port}" ping 2>/dev/null)
    fi
    [ "${out}" = 'PONG' ]
}

# 启动结果必须同时满足服务处于运行状态和端口可应答，避免把外部实例的
# PONG 当成本机服务启动成功。
Wait_Redis_Ready()
{
    local port="$1" i=0

    while [ ${i} -lt 30 ]; do
        if Redis_Service_Active && Redis_Ping "${port}"; then
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    if ! Redis_Service_Active && Redis_Ping "${port}"; then
        Echo_Red "端口 ${port} 有 Redis 应答，但不是 redis.service 管理的实例。"
    fi
    return 1
}

# 统一的启动入口：已托管时重启以加载新配置，未托管时先查端口再启动。
Start_Redis_Service()
{
    local port="$1"

    if Redis_Service_Active; then
        StartOrStop restart redis
    else
        Check_Redis_Port_Free "${port}" || return 1
        StartOrStop start redis
    fi
    Wait_Redis_Ready "${port}"
}

# redis.conf、init 脚本和防火墙规则必须落在同一端口。重复安装时 redis.conf
# 不重写，端口只在 init 脚本和防火墙上更新，因此这里按 lnmp.conf 对齐 redis.conf：
# 端口变化时先按旧端口停服务（停止入口用的是改写前的端口），再改配置并迁移阻断规则。
Sync_Redis_Conf_Port()
{
    # 配置路径可传入，便于定向测试；安装流程使用默认值。
    local conf="${1:-/usr/local/redis/etc/redis.conf}" old_port=''

    if [ ! -s "${conf}" ]; then
        Echo_Yellow "未找到 ${conf}，跳过端口对齐，服务仍按现有配置启动。"
        return 0
    fi

    # 取首个 port 指令；此处不用 awk 的 exit，避免与 addons 的静态检查冲突。
    old_port=$(grep -E '^port[[:space:]]+' "${conf}" | head -1 | awk '{ print $2 }')
    if [ "${old_port}" = "${Redis_Port}" ]; then
        # 端口一致，仅补齐阻断规则（上次安装可能未写入成功）。
        Firewall_Block tcp "${Redis_Port}"
        Firewall_Save
        return 0
    fi

    echo "redis.conf 当前端口为 ${old_port:-未设置}，按 lnmp.conf 改为 ${Redis_Port}。"
    if Redis_Service_Active; then
        echo "改端口前先停止现有 Redis 服务..."
        if ! StartOrStop stop redis; then
            [ -n "${old_port}" ] && [ -x /usr/local/redis/bin/redis-cli ] && \
                /usr/local/redis/bin/redis-cli -p "${old_port}" shutdown 2>/dev/null
        fi
        if Redis_Service_Active; then
            Echo_Red "无法停止现有 Redis 服务，未改动 redis.conf 和防火墙规则。"
            Echo_Red "请手工停止后重试：lnmp redis stop"
            return 1
        fi
    fi

    if [ -z "${old_port}" ]; then
        printf '\n# LNMP: 监听端口取自 lnmp.conf。\nport %s\n' "${Redis_Port}" >> "${conf}" || return 1
    else
        sed -i "s/^port .*/port ${Redis_Port}/" "${conf}" || return 1
    fi
    Check_Conf_Applied "${conf}" "^port[[:space:]]+${Redis_Port}\$" "Redis 端口 ${Redis_Port}" || return 1

    # 旧端口的阻断规则不再对应本服务，撤掉后按新端口重新阻断。
    [ -n "${old_port}" ] && Firewall_Unblock tcp "${old_port}"
    Firewall_Block tcp "${Redis_Port}"
    Firewall_Save
    return 0
}

# 重装时先把现有 phpredis 备份到临时目录，新扩展落地前不破坏可用环境。
# 只接管本包创建的 021-redis.ini，其它 *redis.ini 保留并提示。
Backup_Existing_PHPRedis()
{
    Redis_Ext_Backup_Dir=""
    Redis_Ext_Backup_Dir=$(mktemp -d /tmp/lnmp-phpredis-bak.XXXXXXXX) || return 1
    if [ -s "${PHP_Path}/conf.d/021-redis.ini" ]; then
        \cp -p "${PHP_Path}/conf.d/021-redis.ini" "${Redis_Ext_Backup_Dir}/021-redis.ini" || return 1
    fi
    if [ -s "${zend_ext}" ]; then
        \cp -p "${zend_ext}" "${Redis_Ext_Backup_Dir}/redis.so" || return 1
    fi
    return 0
}

# 安装失败时把备份的扩展放回原位并重载 PHP，避免留下没有 redis 模块的站点。
Restore_Existing_PHPRedis()
{
    local restored='n'

    [ -n "${Redis_Ext_Backup_Dir}" ] || return 0
    if [ -s "${Redis_Ext_Backup_Dir}/redis.so" ]; then
        \cp -p "${Redis_Ext_Backup_Dir}/redis.so" "${zend_ext}" && restored='y'
    fi
    if [ -s "${Redis_Ext_Backup_Dir}/021-redis.ini" ]; then
        \cp -p "${Redis_Ext_Backup_Dir}/021-redis.ini" "${PHP_Path}/conf.d/021-redis.ini" && restored='y'
    fi
    if [ "${restored}" = 'y' ]; then
        Echo_Yellow "已恢复安装前的 phpredis 扩展并重载 PHP。"
        Restart_PHP
    fi
    rm -rf "${Redis_Ext_Backup_Dir}"
    Redis_Ext_Backup_Dir=""
    return 0
}

Clear_PHPRedis_Backup()
{
    [ -n "${Redis_Ext_Backup_Dir}" ] && rm -rf "${Redis_Ext_Backup_Dir}"
    Redis_Ext_Backup_Dir=""
    return 0
}

# 端口在安装时写入服务配置、init 脚本和防火墙规则，因此在动系统前先列出生效值。
Print_Redis_Install_Summary()
{
    Echo_Yellow "=========================================================================="
    echo "服务端：${Redis_Stable_Ver}；PHP 扩展：${PHPRedis_Ver}"
    echo "监听端口（写入 redis.conf 与 /etc/init.d/redis）：${Redis_Port}"
    echo "监听地址：127.0.0.1，防火墙同时阻断该端口的公网访问"
    echo "自测页（Enable_Redis_Test_Page）：${Enable_Redis_Test_Page}"
    if [ -s /usr/local/redis/bin/redis-server ]; then
        Echo_Yellow "已装过 Redis，本次重新编译安装：先停服务，redis.conf 备份为"
        Echo_Yellow "redis.conf.bak.<时间戳> 后按模板重建，maxmemory 等改过的项会回到默认值。"
    fi
    Echo_Yellow "改端口：改 lnmp.conf 后重跑，或 Redis_Port=6380 bash addons.sh install redis"
    Echo_Yellow "装后改端口：改 redis.conf 并重启服务，再执行 lnmp fw sync"
    Echo_Yellow "=========================================================================="
}

# 重装前的准备：配置按模板重建会覆盖现有 redis.conf，因此先停服务再备份，
# 并撤销旧端口的阻断规则。停不掉服务就不动任何文件。
Prepare_Redis_Rebuild()
{
    local conf='/usr/local/redis/etc/redis.conf' old_port='' backup

    [ -s "${conf}" ] && old_port=$(grep -E '^port[[:space:]]+' "${conf}" | head -1 | awk '{ print $2 }')

    if Redis_Service_Active; then
        echo "重新编译前先停止现有 Redis 服务..."
        if ! StartOrStop stop redis; then
            [ -n "${old_port}" ] && [ -x /usr/local/redis/bin/redis-cli ] && \
                /usr/local/redis/bin/redis-cli -p "${old_port}" shutdown 2>/dev/null
        fi
        if Redis_Service_Active; then
            Echo_Red "无法停止现有 Redis 服务，未改动任何文件。"
            Echo_Red "请手工停止后重试：lnmp redis stop"
            return 1
        fi
    fi

    if [ -s "${conf}" ]; then
        backup="${conf}.bak.$(date +%Y%m%d%H%M%S)"
        if ! \cp -p "${conf}" "${backup}"; then
            Echo_Red "备份 ${conf} 失败，未改动任何文件。"
            return 1
        fi
        echo "现有配置已备份为 ${backup}，本次按模板重建。"
    fi

    # 旧端口的阻断规则不再对应本服务，重建后按新端口重新阻断。
    if [ -n "${old_port}" ] && [ "${old_port}" != "${Redis_Port}" ]; then
        Firewall_Unblock tcp "${old_port}"
    fi
    return 0
}

Install_Redis()
{
    echo "====== 正在安装 Redis ======"
    echo "正在安装稳定版 ${Redis_Stable_Ver}..."
    Print_Redis_Install_Summary
    Press_Start || return 1

    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}redis.so"

    cd "${cur_dir}/src" || return 1
    # 扩展包与服务端同属一次安装，先把 phpredis 取齐再动系统，
    # 避免服务端装完后扩展下载失败，留下未启用的服务和防火墙规则。
    if [ -s ${PHPRedis_Ver} ]; then
        rm -rf ${PHPRedis_Ver}
    fi
    Download_Files https://pecl.php.net/get/${PHPRedis_Ver}.tgz ${PHPRedis_Ver}.tgz
    Require_File "${PHPRedis_Ver}.tgz" "pecl redis"

    # 源码包就绪后才动现有扩展，并先备份以便失败恢复。
    Backup_Existing_PHPRedis || { Echo_Red "备份现有 phpredis 失败，已中止，未改动任何文件。"; return 1; }
    # 其它来源的 redis 配置不归本包管理，重复加载时由使用者决定去留。
    for redis_ini in ${PHP_Path}/conf.d/*redis.ini; do
        [ -e "${redis_ini}" ] || continue
        case "${redis_ini}" in
        */021-redis.ini) rm -f "${redis_ini}" ;;
        *) Echo_Yellow "发现非本包创建的 PHP 配置：${redis_ini}，未删除；重复加载 redis.so 时请自行处理。" ;;
        esac
    done
    [ -s "${zend_ext}" ] && rm -f "${zend_ext}"

    # 重装一律重新编译：误删过二进制、init 脚本或依赖文件时，只重写配置起不来。
    # 服务端源码包同样先取齐再动系统，避免服务停下后卡在下载失败。
    Download_Files https://download.redis.io/releases/${Redis_Stable_Ver}.tar.gz ${Redis_Stable_Ver}.tar.gz
    Require_File "${Redis_Stable_Ver}.tar.gz" "Redis server"
    if ! Prepare_Redis_Rebuild; then
        Restore_Existing_PHPRedis
        return 1
    fi
    Tar_Cd ${Redis_Stable_Ver}.tar.gz ${Redis_Stable_Ver}

    Get_OS_Bit
    if [ "${Is_ARM}" = "y" ]; then
        sed -i 's/FINAL_LIBS=-lm/FINAL_LIBS=-lm -latomic/' src/Makefile
    fi
    if [[ "${Is_64bit}" = "y" || "${Is_ARM}" = "y" ]]; then
        make PREFIX=/usr/local/redis install
    else
        make CFLAGS="-march=i686" PREFIX=/usr/local/redis install
    fi
    ln -sf /usr/local/redis/bin/redis-cli /usr/bin/redis-cli
    mkdir -p /usr/local/redis/etc/
    \cp redis.conf  /usr/local/redis/etc/

    # Redis 8.x 模板默认加载 Bloom、Search、JSON 和 TimeSeries 模块，但
    # make install 不安装对应 .so。默认关闭这些行，避免服务因模块缺失中止；
    # 需要附加功能时应先单独构建模块再启用。
    if grep -q '^loadmodule ' /usr/local/redis/etc/redis.conf; then
        echo "注释掉 Redis 8.x 默认配置里的 loadmodule（对应模块未随 make install 安装）"
        sed -i 's|^loadmodule |# loadmodule |g' /usr/local/redis/etc/redis.conf
    fi

    # systemd unit 为 Type=simple，配置保持前台模式；SysV 入口在命令行显式加
    # --daemonize yes，两个入口都不依赖这里的取值。
    sed -i 's/^daemonize yes/daemonize no/' /usr/local/redis/etc/redis.conf
    grep -Eq '^daemonize[[:space:]]+no$' /usr/local/redis/etc/redis.conf || \
        Echo_Yellow "redis.conf 未写入 daemonize no，服务仍由两个入口的命令行参数决定运行模式。"
    # 服务、init 脚本和防火墙统一使用 lnmp.conf 中的端口。
    sed -i "s/^port .*/port ${Redis_Port}/" /usr/local/redis/etc/redis.conf
    Check_Conf_Applied /usr/local/redis/etc/redis.conf             "^port[[:space:]]+${Redis_Port}\$" "Redis 端口 ${Redis_Port}" || return 1

    if ! id -u redis >/dev/null 2>&1; then
        useradd -r -M -s /sbin/nologin redis 2>/dev/null || \
            useradd -r -M -s /usr/sbin/nologin redis 2>/dev/null
    fi

    # 使用固定数据目录，避免守护进程从不同工作目录启动时改变 dump.rdb 位置。
    mkdir -p /usr/local/redis/var
    sed -i 's|^dir \./|dir /usr/local/redis/var|' /usr/local/redis/etc/redis.conf

    sed -i 's|^logfile ""|logfile /usr/local/redis/var/redis.log|' /usr/local/redis/etc/redis.conf

    # 数据、日志和 pid 目录归 Redis 账号，配置保持 root 所有且只读，
    # 防止服务进程修改持久化路径等安全设置。
    chown -R redis:redis /usr/local/redis/var
    chmod 750 /usr/local/redis/var
    chown root:redis /usr/local/redis/etc/redis.conf
    chmod 640 /usr/local/redis/etc/redis.conf
    Set_Redis_Loopback_Bind /usr/local/redis/etc/redis.conf || return 1
    # pidfile 放入 Redis 可写目录，满足降权运行要求。
    sed -i 's#^pidfile .*#pidfile /usr/local/redis/var/redis.pid#g' /usr/local/redis/etc/redis.conf
    cd ../
    Clean_Src_Dir "${Redis_Stable_Ver}"

    # Redis 默认无认证，阻止公网访问可避免未授权读写缓存。
    Firewall_Block tcp "${Redis_Port}"
    Firewall_Save

    Tar_Cd ${PHPRedis_Ver}.tgz ${PHPRedis_Ver}
    ${PHP_Path}/bin/phpize

    # igbinary 可用时保持 phpredis 的对应序列化支持。
    Redis_Igbinary_Opt=''
    if [ -s "${zend_ext_dir}igbinary.so" ]; then
        Redis_Igbinary_Opt='--enable-redis-igbinary'
        echo "检测到 igbinary，启用 phpredis 的 igbinary 序列化支持。"
    fi
    ./configure --with-php-config=${PHP_Path}/bin/php-config ${Redis_Igbinary_Opt}
    if ! Make_Install; then
        Restore_Existing_PHPRedis
        return 1
    fi
    cd ../
    cat >${PHP_Path}/conf.d/021-redis.ini<<EOF
extension = "redis.so"
EOF

    # init 脚本与防火墙按 lnmp.conf 写端口，redis.conf 必须先对齐到同一值。
    if ! Sync_Redis_Conf_Port; then
        Restore_Existing_PHPRedis
        return 1
    fi

    \cp ${cur_dir}/init.d/init.d.redis /etc/init.d/redis
    sed -i "s/^REDISPORT=.*/REDISPORT=${Redis_Port}/" /etc/init.d/redis
    if ! Check_Conf_Applied /etc/init.d/redis "^REDISPORT=${Redis_Port}\$" "Redis init 脚本端口 ${Redis_Port}"; then
        Restore_Existing_PHPRedis
        return 1
    fi
    \cp ${cur_dir}/init.d/redis.service /etc/systemd/system/redis.service
    # 启动前检查随 Redis 目录安装，卸载时一并删除；unit 在其缺失时跳过该步。
    \cp ${cur_dir}/tools/redis-preflight.sh /usr/local/redis/bin/redis-preflight
    chmod 755 /usr/local/redis/bin/redis-preflight
    chmod +x /etc/init.d/redis
    Normalize_Redis_Perms
    if ! Check_Redis_Runtime_Access; then
        Restore_Existing_PHPRedis
        return 1
    fi
    Set_Redis_Overcommit
    echo "正在加入开机自启..."
    StartUp redis
    Restart_PHP
    Start_Redis_Service "${Redis_Port}"
    local Redis_Started=$?

    # 测试页无鉴权、暴露 Redis 版本且会写入缓存，因此默认不部署。
    if [ "${Enable_Redis_Test_Page}" = "y" ]; then
        echo "正在复制 Redis PHP 测试文件..."
        \cp ${cur_dir}/conf/redis.php ${Default_Website_Dir}/redis.php
        sed -i "s/', 6379)/', ${Redis_Port})/" ${Default_Website_Dir}/redis.php
        Warn_Demo_Page_Not_Served redis.php
    else
        echo "未部署 Redis 测试页面（Enable_Redis_Test_Page='n'）。"
        echo "如需自测：cp conf/redis.php ${Default_Website_Dir}/redis.php"
    fi

    if [ ! -s "${zend_ext}" ] || [ ! -s /usr/local/redis/bin/redis-server ]; then
        rm -f ${PHP_Path}/conf.d/021-redis.ini
        Echo_Red "Redis 安装失败！（扩展或服务端二进制未生成）"
        Restore_Existing_PHPRedis
        return 1
    fi
    Clear_PHPRedis_Backup

    if [ "${Redis_Started}" -eq 0 ]; then
        Echo_Green "====== Redis 安装完成 ======"
        Echo_Green "Redis 安装成功。"
        return 0
    fi

    Echo_Red "====== Redis 装好了，但服务没能启动 ======"
    Echo_Red "PHP 扩展与服务端二进制都已就位，问题出在启动阶段。"
    Echo_Red "常见原因："
    Echo_Red "  - ${Redis_Port} 端口已被占用（旧的 redis-server 进程还在？ pgrep -a redis-server）"
    Echo_Red "  - 数据目录 /usr/local/redis/var 不存在或不可写"
    Echo_Red "  - 配置里有指向不存在文件的 loadmodule"
    Echo_Red "排查：journalctl -xeu redis.service --no-pager | tail -30"
    Echo_Red "      tail -20 /usr/local/redis/var/redis.log"
    Echo_Red "      /usr/local/redis/bin/redis-server /usr/local/redis/etc/redis.conf --daemonize no"
    return 1
}

Uninstall_Redis()
{
    echo "即将卸载 Redis..."
    Press_Start || return 1

    rm -f ${PHP_Path}/conf.d/*redis.ini
    Restart_PHP
    Remove_StartUp redis
    echo "正在删除 Redis 文件..."
    rm -rf /usr/local/redis
    rm -rf /etc/init.d/redis
    rm -f /usr/bin/redis-cli
    # 该 sysctl 文件由安装 Redis 时创建，卸载后一并删除；运行中的内核值不回改，
    # 避免影响其它正在运行的服务，重启后恢复系统默认。
    if [ -f /etc/sysctl.d/60-lnmp-redis.conf ]; then
        rm -f /etc/sysctl.d/60-lnmp-redis.conf
        echo "已删除 /etc/sysctl.d/60-lnmp-redis.conf（vm.overcommit_memory 当前值保持不变）。"
    fi
    Firewall_Unblock tcp "${Redis_Port}"
    Firewall_Save
    Echo_Green "Redis 卸载完成。"
}
