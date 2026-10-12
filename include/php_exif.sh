#!/usr/bin/env bash

Install_PHP_Exif()
{
    Addons_Install_Ext exif "PHP EXIF 扩展"
}

Uninstall_PHP_Exif()
{
    Addons_Remove_Ext exif "PHP EXIF 扩展"
}
