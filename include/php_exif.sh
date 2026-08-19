#!/usr/bin/env bash

Install_PHP_Exif()
{
    cd ${cur_dir}/src
    echo "====== 正在安装 PHP EXIF 扩展 ======"
    Press_Start || return 1

    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}exif.so"

    ${PHP_Path}/bin/php -m|grep exif
    if [ $? -eq 0 ]; then
        Echo_Red "PHP 模块 exif 已加载！"
        return 1
    fi

    Download_PHP_Src

    Tar_Cd php-${Cur_PHP_Version}.tar.bz2 php-${Cur_PHP_Version}/ext/exif
    if echo "${Cur_PHP_Version}" | grep -Eqi '^8.' && gcc -dumpversion|grep -Eq "^[3-4].";then
        export CFLAGS="-std=c99"
    fi
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config
    make && make install
    cd -
    rm -rf php-${Cur_PHP_Version}

    cat >${PHP_Path}/conf.d/009-exif.ini<<EOF
extension = "exif.so"
EOF

    Restart_PHP
    if [ -s "${zend_ext}" ]; then
        Echo_Green "====== PHP EXIF 扩展安装完成 ======"
        Echo_Green "PHP EXIF 扩展安装成功。"
        return 0
    else
        rm -f ${PHP_Path}/conf.d/009-exif.ini
        Echo_Red "PHP EXIF 扩展安装失败！"
        return 1
    fi
}

Uninstall_PHP_Exif()
{
    echo "即将卸载 PHP EXIF 扩展..."
    Press_Start || return 1
    rm -f ${PHP_Path}/conf.d/009-exif.ini
    Restart_PHP
    Echo_Green "PHP EXIF 扩展卸载完成。"
}
