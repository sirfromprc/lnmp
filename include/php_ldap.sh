#!/usr/bin/env bash

Install_PHP_Ldap()
{
    cd ${cur_dir}/src
    echo "====== 正在安装 PHP LDAP 扩展 ======"
    Press_Start || return 1

    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}ldap.so"

    ${PHP_Path}/bin/php -m|grep ldap
    if [ $? -eq 0 ]; then
        Echo_Red "PHP 模块 ldap 已加载！"
        return 1
    fi

    if [ "$PM" = "yum" ]; then
        yum -y install openldap-devel cyrus-sasl-devel
        if [ "${Is_64bit}" == "y" ]; then
            ln -sf /usr/lib64/libldap* /usr/lib/
            ln -sf /usr/lib64/liblber* /usr/lib/
        fi
    elif [ "$PM" = "apt" ]; then
        Apt_Get install -y libldap2-dev libsasl2-dev
        if [ -s /usr/lib/x86_64-linux-gnu/libldap.so ]; then
            ln -sf /usr/lib/x86_64-linux-gnu/libldap.so /usr/lib/
            ln -sf /usr/lib/x86_64-linux-gnu/liblber.so /usr/lib/
        fi
    fi

    Download_PHP_Src

    Tar_Cd php-${Cur_PHP_Version}.tar.bz2 php-${Cur_PHP_Version}/ext/ldap
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config --with-ldap --with-ldap-sasl
    make && make install
    cd -
    rm -rf php-${Cur_PHP_Version}

    cat >${PHP_Path}/conf.d/009-ldap.ini<<EOF
extension = "ldap.so"
EOF

    Restart_PHP
    if [ -s "${zend_ext}" ]; then
        Echo_Green "====== PHP LDAP 扩展安装完成 ======"
        Echo_Green "PHP LDAP 扩展安装成功。"
        return 0
    else
        rm -f ${PHP_Path}/conf.d/009-ldap.ini
        Echo_Red "PHP LDAP 扩展安装失败！"
        return 1
    fi
}

Uninstall_PHP_Ldap()
{
    echo "即将卸载 PHP LDAP 扩展..."
    Press_Start || return 1
    rm -f ${PHP_Path}/conf.d/009-ldap.ini
    Restart_PHP
    Echo_Green "PHP LDAP 扩展卸载完成。"
}
