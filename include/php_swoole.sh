#!/usr/bin/env bash

Install_PHP_Swoole()
{
    cd ${cur_dir}/src
    echo "====== 正在安装 PHP Swoole 扩展 ======"
    Press_Start || return 1

    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}swoole.so"

    ${PHP_Path}/bin/php -m|grep swoole
    if [ $? -eq 0 ]; then
        Echo_Red "PHP 模块 swoole 已加载！"
        return 1
    fi

    # 当前 PHP 8.x 统一使用 PHPSwoole_Ver 指定的 PECL 官方版本。
    Download_Files https://pecl.php.net/get/${PHPSwoole_Ver}.tgz ${PHPSwoole_Ver}.tgz
    Require_File "${PHPSwoole_Ver}.tgz" "pecl swoole"
    Tar_Cd ${PHPSwoole_Ver}.tgz ${PHPSwoole_Ver}
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config --enable-openssl --enable-http2 --enable-swoole-json
    make && make install
    cd -
    rm -rf ${PHPSwoole_Ver}

    cat >${PHP_Path}/conf.d/009-swoole.ini<<EOF
extension = "swoole.so"
EOF

    Restart_PHP
    if [ -s "${zend_ext}" ]; then
        Echo_Green "====== PHP Swoole 扩展安装完成 ======"
        Echo_Green "PHP Swoole 扩展安装成功。"
        return 0
    else
        rm -f ${PHP_Path}/conf.d/009-swoole.ini
        Echo_Red "PHP Swoole 扩展安装失败！"
        return 1
    fi
}

Uninstall_PHP_Swoole()
{
    echo "即将卸载 PHP Swoole 扩展..."
    Press_Start || return 1
    rm -f ${PHP_Path}/conf.d/009-swoole.ini
    Restart_PHP
    Echo_Green "PHP Swoole 扩展卸载完成。"
}
