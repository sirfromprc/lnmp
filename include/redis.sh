#!/usr/bin/env bash

Install_Redis()
{
    echo "====== Installing Redis ======"
    echo "Install ${Redis_Stable_Ver} Stable Version..."
    Press_Start

    # 清掉所有旧的 phpredis 配置，不只是本脚本自己写过的那个。
    # 主安装路径（php_default_ext.sh）在 Enable_PHP_Default_Redis='y' 时
    # 写的是 021-redis.ini；只删 007 会留下两份 `extension = "redis.so"`，
    # 避免 PHP 启动时报 `Module "redis" is already loaded`。
    rm -f ${PHP_Path}/conf.d/*redis.ini
    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}redis.so"
    if [ -s "${zend_ext}" ]; then
        rm -f "${zend_ext}"
    fi

    cd ${cur_dir}/src
    if [ -s /usr/local/redis/bin/redis-server ]; then
        echo "Redis server already exists."
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
        mkdir -p /usr/local/redis/etc/
        \cp redis.conf  /usr/local/redis/etc/

        # 注意：Redis 8.x 的默认 redis.conf 自带 loadmodule 行：
        #     loadmodule ./modules/redisbloom/redisbloom.so
        #     loadmodule ./modules/redisearch/redisearch.so
        #     loadmodule ./modules/redisjson/rejson.so
        #     loadmodule ./modules/redistimeseries/redistimeseries.so
        # Redis 8.0 起把这几个模块并进了官方发行版，配置模板便预置了它们。
        #
        # 但 `make PREFIX=... install` 只安装二进制，不构建也不安装模块
        # （模块要各自的构建链，RediSearch 还需要 Rust）。于是 redis-server
        # 缺少对应 .so 时 redis-server 会以 `server aborting` 中止启动。
        # 这些配置从 Redis 8.x 开始出现，7.x 配置模板不包含这些行。
        #
        # 处理：注释掉。LNMP 场景用的是核心的键值/缓存能力，
        # Bloom / Search / JSON / TimeSeries 都用不到。
        # 需要它们的用户请自行构建模块后再把对应行放开。
        if grep -q '^loadmodule ' /usr/local/redis/etc/redis.conf; then
            echo "注释掉 Redis 8.x 默认配置里的 loadmodule（对应模块未随 make install 安装）"
            sed -i 's|^loadmodule |# loadmodule |g' /usr/local/redis/etc/redis.conf
        fi

        sed -i 's/daemonize no/daemonize yes/g' /usr/local/redis/etc/redis.conf

        if ! id -u redis >/dev/null 2>&1; then
            useradd -r -M -s /sbin/nologin redis 2>/dev/null || \
                useradd -r -M -s /usr/sbin/nologin redis 2>/dev/null
        fi

        # 数据目录：默认 `dir ./` 是相对路径，daemonize 之后工作目录是
        # 从 /etc/init.d 或 systemd 启动时，工作目录通常为 /，
        # dump.rdb 会直接落在根目录下。改为固定目录。
        mkdir -p /usr/local/redis/var
        sed -i 's|^dir \./|dir /usr/local/redis/var|' /usr/local/redis/etc/redis.conf

        sed -i 's|^logfile ""|logfile /usr/local/redis/var/redis.log|' /usr/local/redis/etc/redis.conf

        # 权限收口：数据/日志/pid 目录归 redis 账号，配置只读。
        # 配置文件保持 root 所有，Redis 进程无需修改自身配置
        # （能改配置就能改 dir/dbfilename，那是历史上写 SSH 公钥那类利用的前提）。
        chown -R redis:redis /usr/local/redis/var
        chmod 750 /usr/local/redis/var
        chown root:redis /usr/local/redis/etc/redis.conf
        chmod 640 /usr/local/redis/etc/redis.conf
        if ! grep -Eqi '^bind[[:space:]]*127.0.0.1' /usr/local/redis/etc/redis.conf; then
            sed -i 's/^# bind 127.0.0.1/bind 127.0.0.1/g' /usr/local/redis/etc/redis.conf
        fi
        # pidfile 必须放在 redis 账号可写的目录里。
        # 降权后的进程不能写入 root 所有的 /var/run。
        sed -i 's#^pidfile .*#pidfile /usr/local/redis/var/redis.pid#g' /usr/local/redis/etc/redis.conf
        cd ../
        rm -rf ${cur_dir}/src/${Redis_Stable_Ver}

        # redis 默认无密码，暴露到公网可被直接写入任意 key（历史上被大量用于植入 SSH 公钥）
        Firewall_Block tcp 6379
        Firewall_Save
    fi

    if [ -s ${PHPRedis_Ver} ]; then
        rm -rf ${PHPRedis_Ver}
    fi

    Download_Files https://pecl.php.net/get/${PHPRedis_Ver}.tgz ${PHPRedis_Ver}.tgz
    Require_File "${PHPRedis_Ver}.tgz" "pecl redis"
    Tar_Cd ${PHPRedis_Ver}.tgz ${PHPRedis_Ver}
    ${PHP_Path}/bin/phpize

    # 检测到 igbinary 时启用 igbinary 序列化，与主安装路径
    # （php_default_ext.sh:136 的 --enable-redis-igbinary）保持一致。
    # 不这么做的话，在已装好带 igbinary 的 phpredis 的机器上执行
    # `addons.sh install redis`，会把它降级成不支持 igbinary 的版本。
    Redis_Igbinary_Opt=''
    if [ -s "${zend_ext_dir}igbinary.so" ]; then
        Redis_Igbinary_Opt='--enable-redis-igbinary'
        echo "检测到 igbinary，启用 phpredis 的 igbinary 序列化支持。"
    fi
    ./configure --with-php-config=${PHP_Path}/bin/php-config ${Redis_Igbinary_Opt}
    Make_Install || exit 1
    cd ../
    cat >${PHP_Path}/conf.d/021-redis.ini<<EOF
extension = "redis.so"
EOF

    \cp ${cur_dir}/init.d/init.d.redis /etc/init.d/redis
    \cp ${cur_dir}/init.d/redis.service /etc/systemd/system/redis.service
    chmod +x /etc/init.d/redis
    echo "Add to auto startup..."
    StartUp redis
    Restart_PHP
    StartOrStop start redis

    # 演示页默认不部署，与 memcached、phpinfo 和 phpMyAdmin 保持一致

    # 它无鉴权、回显 Redis 版本号（便于攻击者匹配已知漏洞），
    # 且每次访问都会对生产 Redis 做一次 set/del 写操作。
    if [ "${Enable_Redis_Test_Page}" = "y" ]; then
        echo "Copy Redis PHP Test file..."
        \cp ${cur_dir}/conf/redis.php ${Default_Website_Dir}/redis.php
    else
        echo "Redis test page not deployed (Enable_Redis_Test_Page='n')."
        echo "如需自测：cp conf/redis.php ${Default_Website_Dir}/redis.php"
    fi

    if [ ! -s "${zend_ext}" ] || [ ! -s /usr/local/redis/bin/redis-server ]; then
        rm -f ${PHP_Path}/conf.d/*redis.ini
        Echo_Red "Redis install failed!（扩展或服务端二进制未生成）"
        return 1
    fi

    if /etc/init.d/redis status >/dev/null 2>&1; then
        Echo_Green "====== Redis install completed ======"
        Echo_Green "Redis installed successfully, enjoy it!"
        return 0
    fi

    Echo_Red "====== Redis 装好了，但服务没能启动 ======"
    Echo_Red "PHP 扩展与服务端二进制都已就位，问题出在启动阶段。"
    Echo_Red "常见原因："
    Echo_Red "  - 6379 端口已被占用（旧的 redis-server 进程还在？ pgrep -a redis-server）"
    Echo_Red "  - 数据目录 /usr/local/redis/var 不存在或不可写"
    Echo_Red "  - 配置里有指向不存在文件的 loadmodule"
    Echo_Red "排查：tail -20 /usr/local/redis/var/redis.log"
    Echo_Red "      /usr/local/redis/bin/redis-server /usr/local/redis/etc/redis.conf --daemonize no"
    return 1
}

Uninstall_Redis()
{
    echo "You will uninstall Redis..."
    Press_Start

    rm -f ${PHP_Path}/conf.d/*redis.ini
    Restart_PHP
    Remove_StartUp redis
    echo "Delete Redis files..."
    rm -rf /usr/local/redis
    rm -rf /etc/init.d/redis
    Firewall_Unblock tcp 6379
    Firewall_Save
    Echo_Green "Uninstall Redis completed."
}
