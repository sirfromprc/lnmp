#!/usr/bin/env bash

# imap 已不提供安装，只保留卸载既有安装。
Uninstall_PHP_Imap()
{
    Addons_Remove_Ext imap "PHP IMAP 扩展"
}
