#!/usr/bin/env bash

Install_PHP_Fileinfo()
{
    Echo_Yellow "内存低于 1GB 时，Fileinfo 扩展可能安装失败。"
    Addons_Install_Ext fileinfo "PHP Fileinfo 扩展"
}

Uninstall_PHP_Fileinfo()
{
    Addons_Remove_Ext fileinfo "PHP Fileinfo 扩展"
}
