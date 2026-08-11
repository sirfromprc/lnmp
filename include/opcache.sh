#!/usr/bin/env bash

Install_Opcache()
{

    echo "====== Installing zend opcache ======"
    Press_Start

    # 清理可能存在的旧 opcache 配置，避免与下面新写的重复
    rm -f ${PHP_Path}/conf.d/004-opcache.ini

    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}opcache.so"

    if echo "${Cur_PHP_Version}" | grep -Eqi '^8.'; then
        cat >${PHP_Path}/conf.d/004-opcache.ini<<EOF
[Zend Opcache]
zend_extension="opcache.so"
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
opcache.enable_cli=1

opcache.jit = 1255
opcache.jit_buffer_size = 64M
EOF

    else
        echo "Error: can't get php version!"
        echo "Maybe php was didn't install or php configuration file has errors.Please check."
        sleep 3
        return 1
    fi

    # ocp.php（opcache 控制面板）不再部署到网站根目录：
    # 它会泄露完整的缓存文件路径列表（等于暴露整个应用目录树）、内存统计，
    # 并提供 reset/invalidate 操作。
    Restart_PHP
    if [ -s "${zend_ext}" ]; then
        Echo_Green "====== Opcache install completed ======"
        Echo_Green "Opcache installed successfully, enjoy it!"
        return 0
    else
        rm -f ${PHP_Path}/conf.d/004-opcache.ini
        Echo_Red "OPcache install failed!"
        return 1
    fi
}

Uninstall_Opcache()
{
    echo "You will uninstall opcache..."
    Press_Start
    rm -f ${PHP_Path}/conf.d/004-opcache.ini
    Restart_PHP
    Echo_Green "Uninstall Opcache completed."
}
