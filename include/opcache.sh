#!/usr/bin/env bash

Install_Opcache()
{
    echo "====== 正在安装 Zend OPcache ======"
    Press_Start || return 1

    Addons_Get_PHP_Ext_Dir
    if ! echo "${Cur_PHP_Version}" | grep -Eqi '^8.'; then
        echo "错误：无法获取 PHP 版本！"
        echo "PHP 可能尚未安装，或 PHP 配置文件存在错误，请检查。"
        sleep 3
        return 1
    fi

    # 与安装、升级共用同一份参数；8.5 起 OPcache 静态编入，不校验 opcache.so。
    if ! Enable_Opcache_Config; then
        Echo_Red "OPcache 安装失败！"
        return 1
    fi

    # OPcache 控制面板会泄露应用路径和内存统计，并提供缓存重置操作，因此不部署。
    # OPcache 以 zend_extension 注册，--ri 只认注册名 Zend OPcache。
    if Accept_PHP_Ext "Zend OPcache" "${PHP_Path}/conf.d/004-opcache.ini"; then
        Echo_Green "====== OPcache 安装完成 ======"
        Echo_Green "OPcache 安装成功。"
        return 0
    else
        Echo_Red "OPcache 安装失败！"
        return 1
    fi
}

Uninstall_Opcache()
{
    echo "即将卸载 OPcache..."
    Press_Start || return 1
    rm -f "${PHP_Path}/conf.d/004-opcache.ini"
    Restart_PHP
    # 8.5 起 OPcache 静态编入，删除配置后按内置默认值继续启用。
    if "${PHP_Path}/bin/php" -n -m 2>/dev/null | grep -qx 'Zend OPcache'; then
        Echo_Yellow "已删除 OPcache 配置；当前 PHP 静态编入 OPcache，将按内置默认值继续启用。"
        echo
        return 0
    fi
    Echo_Green "OPcache 卸载完成。"
}
