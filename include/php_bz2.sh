#!/usr/bin/env bash

Install_PHP_Bz2()
{
    cd "${cur_dir}/src" || return 1
    echo "====== 正在安装 PHP Bz2 扩展 ======"
    Press_Start || return 1

    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}bz2.so"

    ${PHP_Path}/bin/php -m|grep bz2
    if [ $? -eq 0 ]; then
        Echo_Red "PHP 模块 bz2 已加载！"
        return 1
    fi

    Download_PHP_Src

    Tar_Cd php-${Cur_PHP_Version}.tar.bz2 php-${Cur_PHP_Version}/ext/bz2
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config
    make && make install
    cd - || return 1
    rm -rf php-${Cur_PHP_Version}

    cat >${PHP_Path}/conf.d/009-bz2.ini<<EOF
extension = "bz2.so"
EOF

    Restart_PHP
    if [ -s "${zend_ext}" ]; then
        Echo_Green "====== PHP Bz2 扩展安装完成 ======"
        Echo_Green "PHP Bz2 扩展安装成功。"
        return 0
    else
        rm -f ${PHP_Path}/conf.d/009-bz2.ini
        Echo_Red "PHP Bz2 扩展安装失败！"
        return 1
    fi
}

Uninstall_PHP_Bz2()
{
    echo "即将卸载 PHP Bz2 扩展..."
    Press_Start || return 1
    rm -f ${PHP_Path}/conf.d/009-bz2.ini
    Restart_PHP
    Echo_Green "PHP Bz2 扩展卸载完成。"
}
