#!/usr/bin/env bash

Install_Apcu()
{
    Addons_Install_Ext apcu "APCu" || return 1
    Tune_Advise_PHP_Pools
    return 0
}

Uninstall_Apcu()
{
    Addons_Remove_Ext apcu "APCu"
}
