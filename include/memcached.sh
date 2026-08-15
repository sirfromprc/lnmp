#!/usr/bin/env bash

Install_PHPMemcache()
{
    echo "正在安装 PHP memcache 扩展..."
    cd ${cur_dir}/src
    # 保留的 PHP 全部是 8.x，统一用 PHP8Memcache_Ver，改走 pecl 官方源
    Download_Files https://pecl.php.net/get/${PHP8Memcache_Ver}.tgz ${PHP8Memcache_Ver}.tgz
    Require_File "${PHP8Memcache_Ver}.tgz" "pecl memcache"
    Tar_Cd ${PHP8Memcache_Ver}.tgz ${PHP8Memcache_Ver}
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config
    Make_Install || return 1
    cd ../
}

Install_PHPMemcached()
{
    echo "正在安装 PHP memcached 扩展..."
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
    Make_Install || return 1
    cd ../

    cd ${cur_dir}/src
    [[ -d "${PHP8Memcached_Ver}" ]] && rm -rf "${PHP8Memcached_Ver}"
    Download_Files https://pecl.php.net/get/${PHP8Memcached_Ver}.tgz ${PHP8Memcached_Ver}.tgz
    Require_File "${PHP8Memcached_Ver}.tgz" "pecl memcached"
    Tar_Cd ${PHP8Memcached_Ver}.tgz ${PHP8Memcached_Ver}
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config --enable-memcached --with-libmemcached-dir=/usr/local/libmemcached
    Make_Install || return 1
    cd ../
}

Install_Memcached()
{
    ver="1"
    echo "请选择要安装的 Memcached PHP 扩展："
    echo "1：安装 php-memcache"
    echo "2：安装 php-memcached"
    read -p "请输入 1 或 2 [默认 1]：" ver

    if [ "${ver}" = "1" ]; then
        echo "已选择 php-memcache。"
        PHP_ZTS="memcache.so"
    elif [ "${ver}" = "2" ]; then
        echo "已选择 php-memcached。"
        PHP_ZTS="memcached.so"
    else
        ver="1"
        echo "未输入或输入无效，使用默认项 php-memcache。"
        PHP_ZTS="memcache.so"
    fi

    echo "====== 正在安装 Memcached ======"
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

    echo "正在安装 Memcached..."
    cd ${cur_dir}/src
    if [ -s /usr/local/memcached/bin/memcached ]; then
        echo "Memcached 已存在。"
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

    # unit 的部署放在 if/else 外面：memcached 已经装过时上面的分支不会重跑，
    # 但那台机器同样需要这个 unit，否则启动还是绕开 systemd。
    \cp ${cur_dir}/init.d/memcached.service /etc/systemd/system/memcached.service
    StartUp memcached

    # 扩展装不上不再中断流程：memcached 服务端已经装好了，后面的启动、防火墙
    # 和验收该走完，最终由下面的检查如实给出结论，而不是把机器丢在半装状态。
    local ext_rc=0
    if [ "${ver}" = "1" ]; then
        Install_PHPMemcache || ext_rc=1
    elif [ "${ver}" = "2" ]; then
        Install_PHPMemcached || ext_rc=1
    fi

    # 演示页会部署到网站根目录且没有鉴权，因此默认不部署；与 phpinfo、
    # phpMyAdmin 同一口径。它会连上 memcached
    # 并读写 key，等于把「本机有 memcached 且可用」这一事实公开出去。
    if [ "${Enable_Memcached_Test_Page}" = "y" ]; then
        echo "正在复制 Memcached PHP 测试文件..."
        \cp ${cur_dir}/conf/memcached${ver}.php ${Default_Website_Dir}/memcached.php
        Warn_Demo_Page_Not_Served memcached.php
    else
        echo "未部署 Memcached 测试页面（Enable_Memcached_Test_Page='n'）。"
        echo "如需自测：cp conf/memcached${ver}.php ${Default_Website_Dir}/memcached.php"
    fi

    Restart_PHP

    # memcached 无认证，暴露到公网等于把缓存内容和 UDP 反射放大面一起开放
    Firewall_Block tcp "${Memcached_Port}"
    Firewall_Block udp "${Memcached_Port}"
    Firewall_Save

    echo "正在启动 Memcached..."
    # 与 nginx、php-fpm、数据库、Redis 一致走 StartOrStop：systemd 实际运行
    # 且 unit 存在时使用 systemctl，否则退回 SysV 脚本。
    StartOrStop start memcached

    # 分开报，不然用户只看到一句 failed，不知道差的是扩展还是服务。
    local svc_ok=0 ext_ok=0
    [ -s /usr/local/memcached/bin/memcached ] \
        && /etc/init.d/memcached status >/dev/null 2>&1 && svc_ok=1
    [ -s "${zend_ext}" ] && [ "${ext_rc}" -eq 0 ] && ext_ok=1

    if [ "${svc_ok}" -eq 1 ] && [ "${ext_ok}" -eq 1 ]; then
        Echo_Green "====== Memcached 安装完成 ======"
        Echo_Green "Memcached 安装成功。"
        return 0
    fi
    [ "${svc_ok}" -eq 1 ] && Echo_Green "memcached 服务端已安装并在运行。"
    [ "${svc_ok}" -eq 0 ] && Echo_Red "memcached 服务端没有装成或没能启动。"
    if [ "${ext_ok}" -eq 0 ]; then
        rm -f ${PHP_Path}/conf.d/005-memcached.ini
        Echo_Red "PHP 扩展 ${PHP_ZTS} 没有装成，已移除对应的 ini，避免 PHP 启动报警告。"
    fi
    Echo_Red "Memcached 安装失败！"
    return 1
}

Uninstall_Memcached()
{
    echo "即将卸载 Memcached..."
    Press_Start
    rm -f ${PHP_Path}/conf.d/005-memcached.ini
    Restart_PHP
    Remove_StartUp memcached
    echo "正在删除 Memcached 文件..."
    rm -rf /usr/local/libmemcached
    rm -rf /usr/local/memcached
    rm -rf /etc/init.d/memcached
    rm -rf /usr/bin/memcached
    Firewall_Unblock tcp "${Memcached_Port}"
    Firewall_Unblock udp "${Memcached_Port}"
    Firewall_Save
    Echo_Green "Memcached 卸载完成。"
}
