#!/usr/bin/env bash

Install_Redis()
{
    echo "====== 正在安装 Redis ======"
    echo "正在安装稳定版 ${Redis_Stable_Ver}..."
    Press_Start

    # 清理所有旧 phpredis 配置，避免重复加载 redis.so。
    rm -f ${PHP_Path}/conf.d/*redis.ini
    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}redis.so"
    if [ -s "${zend_ext}" ]; then
        rm -f "${zend_ext}"
    fi

    cd ${cur_dir}/src
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
        if ! grep -Eqi '^bind[[:space:]]*127.0.0.1' /usr/local/redis/etc/redis.conf; then
            sed -i 's/^# bind 127.0.0.1/bind 127.0.0.1/g' /usr/local/redis/etc/redis.conf
        fi
        # pidfile 放入 Redis 可写目录，满足降权运行要求。
        sed -i 's#^pidfile .*#pidfile /usr/local/redis/var/redis.pid#g' /usr/local/redis/etc/redis.conf
        cd ../
        rm -rf ${cur_dir}/src/${Redis_Stable_Ver}

        # Redis 默认无认证，阻止公网访问可避免未授权读写缓存。
        Firewall_Block tcp "${Redis_Port}"
        Firewall_Save
    fi

    if [ -s ${PHPRedis_Ver} ]; then
        rm -rf ${PHPRedis_Ver}
    fi

    Download_Files https://pecl.php.net/get/${PHPRedis_Ver}.tgz ${PHPRedis_Ver}.tgz
    Require_File "${PHPRedis_Ver}.tgz" "pecl redis"
    Tar_Cd ${PHPRedis_Ver}.tgz ${PHPRedis_Ver}
    ${PHP_Path}/bin/phpize

    # igbinary 可用时保持 phpredis 的对应序列化支持。
    Redis_Igbinary_Opt=''
    if [ -s "${zend_ext_dir}igbinary.so" ]; then
        Redis_Igbinary_Opt='--enable-redis-igbinary'
        echo "检测到 igbinary，启用 phpredis 的 igbinary 序列化支持。"
    fi
    ./configure --with-php-config=${PHP_Path}/bin/php-config ${Redis_Igbinary_Opt}
    Make_Install || return 1
    cd ../
    cat >${PHP_Path}/conf.d/021-redis.ini<<EOF
extension = "redis.so"
EOF

    \cp ${cur_dir}/init.d/init.d.redis /etc/init.d/redis
    sed -i "s/^REDISPORT=.*/REDISPORT=${Redis_Port}/" /etc/init.d/redis
    Check_Conf_Applied /etc/init.d/redis "^REDISPORT=${Redis_Port}\$"         "Redis init 脚本端口 ${Redis_Port}" || return 1
    \cp ${cur_dir}/init.d/redis.service /etc/systemd/system/redis.service
    chmod +x /etc/init.d/redis
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
        rm -f ${PHP_Path}/conf.d/*redis.ini
        Echo_Red "Redis 安装失败！（扩展或服务端二进制未生成）"
        return 1
    fi

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
    Press_Start

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
