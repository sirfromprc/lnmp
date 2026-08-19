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

Install_Redis()
{
    echo "====== 正在安装 Redis ======"
    echo "正在安装稳定版 ${Redis_Stable_Ver}..."
    Press_Start || return 1

    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}redis.so"

    cd ${cur_dir}/src
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

    if [ -s /usr/local/redis/bin/redis-server ]; then
        echo "Redis 服务端已存在。"
        ln -sf /usr/local/redis/bin/redis-cli /usr/bin/redis-cli
    else

        Download_Files https://download.redis.io/releases/${Redis_Stable_Ver}.tar.gz ${Redis_Stable_Ver}.tar.gz
        Require_File "${Redis_Stable_Ver}.tar.gz" "Redis server"
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

        sed -i 's/daemonize no/daemonize yes/g' /usr/local/redis/etc/redis.conf
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
        rm -rf ${cur_dir}/src/${Redis_Stable_Ver}

        # Redis 默认无认证，阻止公网访问可避免未授权读写缓存。
        Firewall_Block tcp "${Redis_Port}"
        Firewall_Save
    fi

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

    \cp ${cur_dir}/init.d/init.d.redis /etc/init.d/redis
    sed -i "s/^REDISPORT=.*/REDISPORT=${Redis_Port}/" /etc/init.d/redis
    if ! Check_Conf_Applied /etc/init.d/redis "^REDISPORT=${Redis_Port}\$" "Redis init 脚本端口 ${Redis_Port}"; then
        Restore_Existing_PHPRedis
        return 1
    fi
    \cp ${cur_dir}/init.d/redis.service /etc/systemd/system/redis.service
    chmod +x /etc/init.d/redis
    Normalize_Redis_Perms
    if ! Check_Redis_Runtime_Access; then
        Restore_Existing_PHPRedis
        return 1
    fi
    echo "正在加入开机自启..."
    StartUp redis
    Restart_PHP
    StartOrStop start redis

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

    if /etc/init.d/redis status >/dev/null 2>&1; then
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
    Echo_Red "排查：tail -20 /usr/local/redis/var/redis.log"
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
    Firewall_Unblock tcp "${Redis_Port}"
    Firewall_Save
    Echo_Green "Redis 卸载完成。"
}
