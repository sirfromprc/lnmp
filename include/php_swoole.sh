#!/usr/bin/env bash

Install_PHP_Swoole()
{
    Addons_Install_Ext swoole "PHP Swoole 扩展"
}

Uninstall_PHP_Swoole()
{
    Addons_Remove_Ext swoole "PHP Swoole 扩展"
}
