#!/usr/bin/env bash

Install_PHPMemcache()
{
    echo "正在安装 PHP memcache 扩展..."
    cd ${cur_dir}/src
    # PHP 8.x 使用 PHP8Memcache_Ver 指定的 PECL 官方版本。
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
        Apt_Get install libsasl2-2 sasl2-bin libsasl2-2 libsasl2-dev libsasl2-modules -y
    fi
    Download_Files https://launchpad.net/libmemcached/1.0/${Libmemcached_Ver#libmemcached-}/+download/${Libmemcached_Ver}.tar.gz ${Libmemcached_Ver}.tar.gz
    Require_File "${Libmemcached_Ver}.tar.gz" "libmemcached"
    Tar_Cd ${Libmemcached_Ver}.tar.gz ${Libmemcached_Ver}
    # GCC 7 及以上需要兼容补丁，版本判断覆盖后续两位数版本。
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

# memcached 依赖 libevent 开发头文件；addons 是独立入口，不能假定主安装的依赖已装齐。
Install_Memcached_Deps()
{
    [ -s /usr/include/event2/event.h ] && return 0
    Get_Dist_Name
    if [ "${PM}" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        Apt_Get install -y libevent-dev >/dev/null 2>&1
    elif [ "${PM}" = "yum" ]; then
        yum install -y libevent-devel >/dev/null 2>&1
    fi
    [ -s /usr/include/event2/event.h ]
}

# 服务端未装成时的统一出口：撤掉本次写入的 PHP ini，不部署 unit、开机自启和防火墙规则。
Memcached_Abort()
{
    rm -f ${PHP_Path}/conf.d/005-memcached.ini
    Echo_Red "$1"
    Echo_Red "已移除 005-memcached.ini，未部署服务单元、开机自启和防火墙规则。"
    return 0
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
    Press_Start || return 1

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
        Install_Memcached_Deps || { Memcached_Abort "缺少 libevent 开发包，无法编译 memcached。"; return 1; }
        Tar_Cd ${Memcached_Ver}.tar.gz ${Memcached_Ver}
        # configure 失败时不能继续往下部署服务，否则失败点被推迟到启动阶段。
        if ! ./configure --prefix=/usr/local/memcached; then
            cd ../
            Memcached_Abort "memcached 的 configure 失败，请按上面的输出补齐依赖后重试。"
            return 1
        fi
        if ! Make_Install; then
            cd ../
            Memcached_Abort "memcached 编译或安装失败。"
            return 1
        fi
        cd ../
        rm -rf ${cur_dir}/src/${Memcached_Ver}

        ln -sf /usr/local/memcached/bin/memcached /usr/bin/memcached

        \cp ${cur_dir}/init.d/init.d.memcached /etc/init.d/memcached
        # 服务监听端口与 lnmp.conf 及防火墙规则保持一致。
        sed -i "s/^PORT=.*/PORT=${Memcached_Port}/" /etc/init.d/memcached
        if ! Check_Conf_Applied /etc/init.d/memcached "^PORT=${Memcached_Port}\$"             "Memcached 端口 ${Memcached_Port}"; then
            Memcached_Abort "Memcached init 脚本端口未写入。"
            return 1
        fi
        chmod +x /etc/init.d/memcached

        if ! id -u memcached >/dev/null 2>&1; then
            useradd -r -M -s /sbin/nologin memcached 2>/dev/null || \
                useradd -r -M -s /usr/sbin/nologin memcached 2>/dev/null
        fi
    fi

    if [ ! -d /var/lock/subsys ]; then
      mkdir -p /var/lock/subsys
    fi

    # 重复安装时也部署 systemd 单元，确保服务通过统一入口管理。
    \cp ${cur_dir}/init.d/memcached.service /etc/systemd/system/memcached.service
    StartUp memcached

    # PHP 扩展失败后仍完成服务启动、防火墙和验收，以分别报告服务端与扩展状态。
    local ext_rc=0
    if [ "${ver}" = "1" ]; then
        Install_PHPMemcache || ext_rc=1
    elif [ "${ver}" = "2" ]; then
        Install_PHPMemcached || ext_rc=1
    fi

    # 测试页无鉴权且会读写缓存，可能暴露 Memcached 的可用状态，因此默认不部署。
    if [ "${Enable_Memcached_Test_Page}" = "y" ]; then
        echo "正在复制 Memcached PHP 测试文件..."
        \cp ${cur_dir}/conf/memcached${ver}.php ${Default_Website_Dir}/memcached.php
        Warn_Demo_Page_Not_Served memcached.php
    else
        echo "未部署 Memcached 测试页面（Enable_Memcached_Test_Page='n'）。"
        echo "如需自测：cp conf/memcached${ver}.php ${Default_Website_Dir}/memcached.php"
    fi

    Restart_PHP

    # Memcached 无认证，需阻止公网访问缓存内容并避免 UDP 反射风险。
    Firewall_Block tcp "${Memcached_Port}"
    Firewall_Block udp "${Memcached_Port}"
    Firewall_Save

    echo "正在启动 Memcached..."
    # 按系统能力选择 systemd 或 SysV 启动服务。
    StartOrStop start memcached

    # 分别检查服务端和 PHP 扩展，便于定位未完成的安装部分。
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
    Press_Start || return 1
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
