#!/usr/bin/env bash

Install_Opcache()
{

    echo "====== 正在安装 Zend OPcache ======"
    Press_Start || return 1

    # 清理旧 OPcache 配置，避免扩展被重复加载。
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
        echo "错误：无法获取 PHP 版本！"
        echo "PHP 可能尚未安装，或 PHP 配置文件存在错误，请检查。"
        sleep 3
        return 1
    fi

    # OPcache 控制面板会泄露应用路径和内存统计，并提供缓存重置操作，因此不部署。
    Restart_PHP
    if [ -s "${zend_ext}" ]; then
        Echo_Green "====== OPcache 安装完成 ======"
        Echo_Green "OPcache 安装成功。"
        return 0
    else
        rm -f ${PHP_Path}/conf.d/004-opcache.ini
        Echo_Red "OPcache 安装失败！"
        return 1
    fi
}

Uninstall_Opcache()
{
    echo "即将卸载 OPcache..."
    Press_Start || return 1
    rm -f ${PHP_Path}/conf.d/004-opcache.ini
    Restart_PHP
    Echo_Green "OPcache 卸载完成。"
}
