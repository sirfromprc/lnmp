 #!/usr/bin/env bash

Install_Apcu()
{
    echo "====== 正在安装 APCu ======"
    Press_Start

    rm -f ${PHP_Path}/conf.d/009-apcu.ini
    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}apcu.so"
    if [ -s "${zend_ext}" ]; then
        rm -f "${zend_ext}"
    fi

    cd ${cur_dir}/src

    # 保留的 PHP 全部是 8.x，统一用 PHPNewApcu_Ver，改走 pecl 官方源
    Download_Files https://pecl.php.net/get/${PHPNewApcu_Ver}.tgz ${PHPNewApcu_Ver}.tgz
    Require_File "${PHPNewApcu_Ver}.tgz" "pecl apcu"
    Tar_Cd ${PHPNewApcu_Ver}.tgz ${PHPNewApcu_Ver}
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config
    make
    make install


    cd ..

    # apcu_bc 仅 PHP 7 需要，随 PHP<8.0 裁剪一并移除
    rm -rf ${cur_dir}/src/${PHPNewApcu_Ver}

    cat >${PHP_Path}/conf.d/009-apcu.ini<<EOF
[apcu]
extension=apcu.so
apc.enabled=1
apc.shm_size=32M
apc.enable_cli=1

EOF

    if [ -s "${zend_ext}" ]; then
        Restart_PHP
        Echo_Green "======== APCu 安装完成 ======"
        Echo_Green "APCu 安装成功。"
        return 0
    fi
    rm -f ${PHP_Path}/conf.d/009-apcu.ini
    Echo_Red "APCu 安装失败！"
    return 1
}

Uninstall_Apcu()
{
    echo "即将卸载 APCu..."
    Press_Start
    rm -f ${PHP_Path}/conf.d/009-apcu.ini
    echo "正在删除 APCu 文件..."
    rm -f "${zend_ext}"
    Restart_PHP
    Echo_Green "APCu 卸载完成。"
}
