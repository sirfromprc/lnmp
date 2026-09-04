#!/usr/bin/env bash

Install_PHP_Fileinfo()
{
    cd "${cur_dir}/src" || return 1
    echo "====== 正在安装 PHP Fileinfo 扩展 ======"
    Echo_Yellow "内存低于 1GB 时，Fileinfo 扩展可能安装失败。"
    Press_Start || return 1

    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}fileinfo.so"

    ${PHP_Path}/bin/php -m|grep fileinfo
    if [ $? -eq 0 ]; then
        Echo_Red "PHP 模块 fileinfo 已加载！"
        return 1
    fi

    Download_PHP_Src

    Tar_Cd php-${Cur_PHP_Version}.tar.bz2 php-${Cur_PHP_Version}/ext/fileinfo
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config
    make && make install
    cd - || return 1
    rm -rf php-${Cur_PHP_Version}

    cat >${PHP_Path}/conf.d/009-fileinfo.ini<<EOF
extension = "fileinfo.so"
EOF

    if Accept_PHP_Ext fileinfo "${PHP_Path}/conf.d/009-fileinfo.ini" "${zend_ext}"; then
        Echo_Green "====== PHP Fileinfo 扩展安装完成 ======"
        Echo_Green "PHP Fileinfo 扩展安装成功。"
        return 0
    else
        Echo_Red "PHP Fileinfo 扩展安装失败！"
        return 1
    fi
}

Uninstall_PHP_Fileinfo()
{
    echo "即将卸载 PHP Fileinfo 扩展..."
    Press_Start || return 1
    rm -f ${PHP_Path}/conf.d/009-fileinfo.ini
    Restart_PHP
    Echo_Green "PHP Fileinfo 扩展卸载完成。"
}
