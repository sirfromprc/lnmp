#!/usr/bin/env bash

Install_PHP_Sodium()
{
    cd ${cur_dir}/src
    echo "====== 正在安装 PHP Sodium 扩展 ======"
    Press_Start

    Addons_Get_PHP_Ext_Dir
    if echo "${Cur_PHP_Version}" | grep -Eqi '^5.[2-6].'; then
        zend_ext="${zend_ext_dir}libsodium.so"
    else
        zend_ext="${zend_ext_dir}sodium.so"
    fi

    ${PHP_Path}/bin/php -m|grep sodium
    if [ $? -eq 0 ]; then
        Echo_Red "PHP 模块 sodium 已加载！"
        return 1
    fi

    if [ "$PM" = "yum" ]; then
        if [ "${DISTRO}" = "Oracle" ]; then
            yum -y install oracle-epel-release
        else
            yum -y install epel-release
        fi
        yum -y install libsodium-devel
    elif [ "$PM" = "apt" ]; then
        apt-get install -y libsodium-dev
    fi

    # 保留的 PHP 全部 >= 8.0，sodium 一律从 PHP 源码树的 ext/sodium 编译。
    # 原判断 '^7.[234].|8.[0-3].' 会让 PHP 8.4/8.5 落空。
    Download_PHP_Src

    Tar_Cd php-${Cur_PHP_Version}.tar.bz2 php-${Cur_PHP_Version}/ext/sodium
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config
    make && make install
    cd -
    rm -rf php-${Cur_PHP_Version}

    echo 'extension = "sodium.so"' > ${PHP_Path}/conf.d/009-sodium.ini

    Restart_PHP
    if [ -s "${zend_ext}" ]; then
        Echo_Green "====== PHP Sodium 扩展安装完成 ======"
        Echo_Green "PHP Sodium 扩展安装成功。"
        return 0
    else
        rm -f ${PHP_Path}/conf.d/009-sodium.ini
        Echo_Red "PHP Sodium 扩展安装失败！"
        return 1
    fi
}

Uninstall_PHP_Sodium()
{
    echo "即将卸载 PHP Sodium 扩展..."
    Press_Start
    rm -f ${PHP_Path}/conf.d/009-sodium.ini
    Restart_PHP
    Echo_Green "PHP Sodium 扩展卸载完成。"
}
