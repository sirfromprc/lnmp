#!/usr/bin/env bash

Install_PHP_Ldap()
{
    Addons_Install_Ext ldap "PHP LDAP 扩展"
}

Uninstall_PHP_Ldap()
{
    Addons_Remove_Ext ldap "PHP LDAP 扩展"
}
