#!/usr/bin/env bash

Install_PHPMemcache()
{
    echo "Install memcache php extension..."
    cd ${cur_dir}/src
    # 保留的 PHP 全部是 8.x，统一用 PHP8Memcache_Ver，改走 pecl 官方源
    Download_Files https://pecl.php.net/get/${PHP8Memcache_Ver}.tgz ${PHP8Memcache_Ver}.tgz
    Require_File "${PHP8Memcache_Ver}.tgz" "pecl memcache"
    Tar_Cd ${PHP8Memcache_Ver}.tgz ${PHP8Memcache_Ver}
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config
    Make_Install || exit 1
    cd ../
}

Install_PHPMemcached()
{
    echo "Install memcached php extension..."
    cd ${cur_dir}/src
    Get_Dist_Name
    if [ "$PM" = "yum" ]; then
        yum install cyrus-sasl-devel -y
        Get_Dist_Version
    elif [ "$PM" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install libsasl2-2 sasl2-bin libsasl2-2 libsasl2-dev libsasl2-modules -y
    fi
    Download_Files https://launchpad.net/libmemcached/1.0/${Libmemcached_Ver#libmemcached-}/+download/${Libmemcached_Ver}.tar.gz ${Libmemcached_Ver}.tar.gz
    Require_File "${Libmemcached_Ver}.tar.gz" "libmemcached"
    Tar_Cd ${Libmemcached_Ver}.tar.gz ${Libmemcached_Ver}
    # gcc 7 及以上需要此补丁；原正则 "^[7-9]|1[0-5]" 的第二段未锚定且 gcc 16+ 不匹配
    if gcc -dumpversion | grep -Eq "^([7-9]|[1-9][0-9])"; then
        patch -p1 < ${cur_dir}/src/patch/libmemcached-1.0.18-gcc7.patch
    fi
    ./configure --prefix=/usr/local/libmemcached --with-memcached
    Make_Install || exit 1
    cd ../

    cd ${cur_dir}/src
    [[ -d "${PHP8Memcached_Ver}" ]] && rm -rf "${PHP8Memcached_Ver}"
    Download_Files https://pecl.php.net/get/${PHP8Memcached_Ver}.tgz ${PHP8Memcached_Ver}.tgz
    Require_File "${PHP8Memcached_Ver}.tgz" "pecl memcached"
    Tar_Cd ${PHP8Memcached_Ver}.tgz ${PHP8Memcached_Ver}
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config --enable-memcached --with-libmemcached-dir=/usr/local/libmemcached
    Make_Install || exit 1
    cd ../
}

Install_Memcached()
{
    ver="1"
    echo "Which memcached php extension do you choose:"
    echo "Install php-memcache, please enter: 1"
    echo "Install php-memcached, please enter: 2"
    read -p "Enter 1 or 2 (Default 1): " ver

    if [ "${ver}" = "1" ]; then
        echo "You choose php-memcache"
        PHP_ZTS="memcache.so"
    elif [ "${ver}" = "2" ]; then
        echo "You choose php-memcached"
        PHP_ZTS="memcached.so"
    else
        ver="1"
        echo "You choose php-memcache"
        PHP_ZTS="memcache.so"
    fi

    echo "====== Installing memcached ======"
    Press_Start

    rm -f ${PHP_Path}/conf.d/005-memcached.ini
    Addons_Get_PHP_Ext_Dir
    zend_ext=${zend_ext_dir}${PHP_ZTS}
    if [ -s "${zend_ext}" ]; then
        rm -f "${zend_ext}"
    fi
    cat >${PHP_Path}/conf.d/005-memcached.ini<<EOF
extension = ${PHP_ZTS}
EOF

    echo "Install memcached..."
    cd ${cur_dir}/src
    if [ -s /usr/local/memcached/bin/memcached ]; then
        echo "Memcached already exists."
    else
        Download_Files https://memcached.org/files/${Memcached_Ver}.tar.gz ${Memcached_Ver}.tar.gz
        Require_File "${Memcached_Ver}.tar.gz" "memcached"
        Tar_Cd ${Memcached_Ver}.tar.gz ${Memcached_Ver}
        ./configure --prefix=/usr/local/memcached
        make &&make install
        cd ../
        rm -rf ${cur_dir}/src/${Memcached_Ver}

        ln -sf /usr/local/memcached/bin/memcached /usr/bin/memcached

        \cp ${cur_dir}/init.d/init.d.memcached /etc/init.d/memcached
        # 端口跟随 lnmp.conf，与防火墙阻断规则用同一个变量
        sed -i "s/^PORT=.*/PORT=${Memcached_Port}/" /etc/init.d/memcached
        Check_Conf_Applied /etc/init.d/memcached "^PORT=${Memcached_Port}\$"             "Memcached 端口 ${Memcached_Port}" || return 1
        chmod +x /etc/init.d/memcached

        if ! id -u memcached >/dev/null 2>&1; then
            useradd -r -M -s /sbin/nologin memcached 2>/dev/null || \
                useradd -r -M -s /usr/sbin/nologin memcached 2>/dev/null
        fi
    fi

    if [ ! -d /var/lock/subsys ]; then
      mkdir -p /var/lock/subsys
    fi

    StartUp memcached

    if [ "${ver}" = "1" ]; then
        Install_PHPMemcache
    elif [ "${ver}" = "2" ]; then
        Install_PHPMemcached
    fi

    # 演示页会部署到网站根目录且没有鉴权，因此默认不部署；与 phpinfo、
    # phpMyAdmin 同一口径。它会连上 memcached
    # 并读写 key，等于把「本机有 memcached 且可用」这一事实公开出去。
    if [ "${Enable_Memcached_Test_Page}" = "y" ]; then
        echo "Copy Memcached PHP Test file..."
        \cp ${cur_dir}/conf/memcached${ver}.php ${Default_Website_Dir}/memcached.php
    else
        echo "Memcached test page not deployed (Enable_Memcached_Test_Page='n')."
        echo "如需自测：cp conf/memcached${ver}.php ${Default_Website_Dir}/memcached.php"
    fi

    Restart_PHP

    # memcached 无认证，暴露到公网等于把缓存内容和 UDP 反射放大面一起开放
    Firewall_Block tcp "${Memcached_Port}"
    Firewall_Block udp "${Memcached_Port}"
    Firewall_Save

    echo "Starting Memcached..."
    /etc/init.d/memcached start

    if [ -s "${zend_ext}" ] && [ -s /usr/local/memcached/bin/memcached ]; then
        Echo_Green "====== Memcached install completed ======"
        Echo_Green "Memcached installed successfully, enjoy it!"
    else
        rm -f ${PHP_Path}/conf.d/005-memcached.ini
        Echo_Red "Memcached install failed!"
    fi
}

Uninstall_Memcached()
{
    echo "You will uninstall Memcached..."
    Press_Start
    rm -f ${PHP_Path}/conf.d/005-memcached.ini
    Restart_PHP
    Remove_StartUp memcached
    echo "Delete Memcached files..."
    rm -rf /usr/local/libmemcached
    rm -rf /usr/local/memcached
    rm -rf /etc/init.d/memcached
    rm -rf /usr/bin/memcached
    Firewall_Unblock tcp "${Memcached_Port}"
    Firewall_Unblock udp "${Memcached_Port}"
    Firewall_Save
    Echo_Green "Uninstall Memcached completed."
}
