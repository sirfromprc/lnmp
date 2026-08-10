#!/usr/bin/env bash

# Cur_PHP_Branch — 返回当前操作的 PHP 主版本号（如 8.0 / 8.3）
#
# 三条调用路径各自提供不同的输入：
#   安装：Set_PHP_Profile 设定 PHP_Branch
#   升级：用户输入的 ${php_version}
#   其他：${Php_Ver}（形如 php-8.3.30）
Cur_PHP_Branch()
{
    if [ -n "${PHP_Branch}" ]; then
        echo "${PHP_Branch}"
    elif [ -n "${php_version}" ]; then
        echo "${php_version}" | cut -d. -f1-2
    elif [ -n "${Php_Ver}" ]; then
        echo "${Php_Ver#php-}" | cut -d. -f1-2
    fi
}

Check_Curl()
{
    if [ -s /usr/local/curl/bin/curl ]; then
        Echo_Green "Curl ...ok"
    else
        Install_Curl
    fi
}

PHP_with_curl()
{
    if [[ "${DISTRO}" = "CentOS" && "${Is_ARM}" = "y" ]]; then
        Check_Curl
        with_curl='--with-curl=/usr/local/curl'
    else
        with_curl='--with-curl'
    fi
}


PHP_with_openssl()
{
    with_openssl='--with-openssl'
}

PHP_with_fileinfo()
{
    if [ "${Enable_PHP_Fileinfo}" = "n" ]; then
        if [[ $(awk '/MemTotal/ {printf( "%d\n", $2 / 1024 )}' /proc/meminfo) -lt 1024 ]]; then
            with_fileinfo='--disable-fileinfo'
        else
            with_fileinfo=''
        fi
    else
        with_fileinfo=''
    fi
}

PHP_with_Exif()
{
    if [ "${Enable_PHP_Exif}" = "n" ]; then
        with_exif=''
    else
        with_exif='--enable-exif'
    fi
}

PHP_with_Ldap()
{
    if [ "${Enable_PHP_Ldap}" = "n" ]; then
        with_ldap=''
    else
        if [ "$PM" = "yum" ]; then
            yum -y install openldap-devel cyrus-sasl-devel
            if [ "${Is_64bit}" == "y" ]; then
                ln -sf /usr/lib64/libldap* /usr/lib/
                ln -sf /usr/lib64/liblber* /usr/lib/
            fi
        elif [ "$PM" = "apt" ]; then
            apt-get install -y libldap2-dev libsasl2-dev
            if [ -s /usr/lib/x86_64-linux-gnu/libldap.so ]; then
                ln -sf /usr/lib/x86_64-linux-gnu/libldap.so /usr/lib/
                ln -sf /usr/lib/x86_64-linux-gnu/liblber.so /usr/lib/
            fi
        fi
        with_ldap='--with-ldap --with-ldap-sasl'
    fi
}

PHP_with_Bz2()
{
    if [ "${Enable_PHP_Bz2}" = "n" ]; then
        with_bz2=''
    else
        Install_Libzip
        with_bz2='--with-bz2'
    fi
}

# 保留的 PHP 版本全部 >= 7.2，sodium 一律可内建。
# 原判断为 "^[8-9]|1[0-2]$"，交替未加括号（实际是「^[8-9] 或 1[0-2]$」），
# 导致旧编号 13~16（PHP 8.2 及以上）两侧都不匹配而落入 else 分支，
# --with-sodium 从未传给 configure。
PHP_with_Sodium()
{
    if [ "${Enable_PHP_Sodium}" = "n" ]; then
        with_sodium=''
    else
        if [ "$PM" = "yum" ]; then
            if [ "${DISTRO}" = "Oracle" ]; then
                yum -y install oracle-epel-release
            else
                yum -y install epel-release
            fi
            yum -y install libsodium-devel
        elif [ "$PM" = "apt" ]; then
            apt-get install -y libsodium-dev
        fi
        with_sodium='--with-sodium'
    fi
}

PHP_with_Imap()
{
    if [ "${Enable_PHP_Imap}" = "n" ]; then
        with_imap=''
    else
        if [ "$PM" = "yum" ]; then
            if [ "${DISTRO}" = "Oracle" ]; then
                yum -y install oracle-epel-release
            else
                yum -y install epel-release
            fi
            yum -y install libc-client-devel krb5-devel uw-imap-devel
            if echo "${CentOS_Version}${Alma_Version}${Rocky_Version}" | grep -Eq "^9"; then
                if ! rpm -qa | grep "libc-client-2007f" || ! rpm -qa | grep "uw-imap-devel"; then

                    if [ -s "${cur_dir}/src/libc-client-2007f-24.el9.${ARCH}.rpm" ]; then
                        rpm -ivh ${cur_dir}/src/libc-client-2007f-24.el9.${ARCH}.rpm ${cur_dir}/src/uw-imap-devel-2007f-24.el9.${ARCH}.rpm
                    else
                        Echo_Red "uw-imap rpm not found in src/, IMAP support may fail to build."
                    fi
                fi
            fi
            [[ -s /usr/lib64/libc-client.so ]] && ln -sf /usr/lib64/libc-client.so /usr/lib/libc-client.so
        elif [ "$PM" = "apt" ]; then
            apt-get install -y libc-client-dev libkrb5-dev
        fi
        with_imap='--with-imap --with-imap-ssl --with-kerberos'
    fi
}

# 保留的 PHP 版本全部 >= 8.0，不再需要外挂 ICU 60（那是 PHP 5.4~7.0 的约束）。
PHP_with_Intl()
{
    if pkg-config --modversion icu-i18n | grep -Eqi '^6[89]|7[0-9]'; then
        export CXX="g++ -DTRUE=1 -DFALSE=0"
        export  CC="gcc -DTRUE=1 -DFALSE=0"
    fi
}

Check_PHP_Option()
{
    PHP_with_openssl
    PHP_with_curl
    PHP_with_fileinfo
    PHP_with_Exif
    PHP_with_Ldap
    PHP_with_Bz2
    PHP_with_Sodium
    PHP_with_Imap
    PHP_with_Intl
    PHP_Buildin_Option="${with_exif} ${with_ldap} ${with_bz2} ${with_sodium} ${with_imap}"
}
Ln_PHP_Bin()
{
    ln -sf /usr/local/php/bin/php /usr/bin/php
    ln -sf /usr/local/php/bin/phpize /usr/bin/phpize
    ln -sf /usr/local/php/bin/pear /usr/bin/pear
    ln -sf /usr/local/php/bin/pecl /usr/bin/pecl
    if [ "${Stack}" = "lnmp" ]; then
        ln -sf /usr/local/php/sbin/php-fpm /usr/bin/php-fpm
    fi
    rm -f /usr/local/php/conf.d/*
}

Pear_Pecl_Set()
{
    pear config-set php_ini /usr/local/php/etc/php.ini
    pecl config-set php_ini /usr/local/php/etc/php.ini
}


Install_Composer()
{
    local expected actual installer tmpdir

    if ! command -v php >/dev/null 2>&1 && [ ! -x /usr/local/php/bin/php ]; then
        Echo_Red "php not found, skip composer install."
        return 1
    fi

    tmpdir=$(mktemp -d "${cur_dir}/src/composer.XXXXXX") || return 1
    installer="${tmpdir}/composer-setup.php"

    # 先获取签名；无法取得签名时中止，避免在没有验证依据时执行远程代码。
    echo "Fetching Composer installer signature from composer.github.io..."
    expected=$(wget -q --max-redirect=3 -O- https://composer.github.io/installer.sig)
    expected=$(echo "${expected}" | tr -d '[:space:]')
    if ! echo "${expected}" | grep -Eq '^[0-9a-f]{96}$'; then
        Echo_Red "Composer installer signature is not a valid SHA384, refuse to continue."
        Echo_Red "got: ${expected:0:120}"
        rm -rf "${tmpdir}"
        return 1
    fi

    echo "Downloading Composer installer from getcomposer.org..."
    if ! wget -q --max-redirect=3 -O "${installer}" https://getcomposer.org/installer \
        || [ ! -s "${installer}" ]; then
        Echo_Red "Composer installer download failed, skip composer install."
        rm -rf "${tmpdir}"
        return 1
    fi

    actual=$(php -r "echo hash_file('sha384', '${installer}');")
    if [ "${expected}" != "${actual}" ]; then
        Echo_Red "Composer installer SHA384 mismatch, refuse to execute."
        Echo_Red "expected=${expected}"
        Echo_Red "actual  =${actual}"
        rm -rf "${tmpdir}"
        return 1
    fi
    Echo_Green "Composer installer SHA384 ok."

    php "${installer}" --install-dir=/usr/local/bin --filename=composer
    rm -rf "${tmpdir}"
    if [ -s /usr/local/bin/composer ]; then
        chmod +x /usr/local/bin/composer
        echo "Composer install successfully."
        return 0
    fi
    Echo_Red "Composer install failed."
    return 1
}

# PHP_Openssl3_Patch — OpenSSL 3.x 下 PHP 8.0 需要打补丁
#
# 保留的版本中只有 8.0 需要（8.1+ 原生支持 OpenSSL 3），
# 故 src/patch/php-8.0-openssl3.0.patch 必须保留。
PHP_Openssl3_Patch()
{
    local branch
    [ "${isOpenSSL3}" != "y" ] && return 0
    branch=$(Cur_PHP_Branch)
    [ "${branch}" != "8.0" ] && return 0

    echo "OpenSSL 3.0, apply a patch to PHP ${branch}..."
    patch -p1 < ${cur_dir}/src/patch/php-8.0-openssl3.0.patch
}


Install_PHP_8x()
{
    Install_Libzip
    Echo_Blue "[+] Installing ${Php_Ver}"
    Tar_Cd ${Php_Ver}.tar.bz2 ${Php_Ver}
    PHP_Openssl3_Patch

    if [ "${Stack}" = "lnmp" ]; then
        ./configure --prefix=/usr/local/php --with-config-file-path=/usr/local/php/etc --with-config-file-scan-dir=/usr/local/php/conf.d --enable-fpm --with-fpm-user=www --with-fpm-group=www --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --with-iconv=/usr/local --with-freetype=/usr/local/freetype --with-jpeg --with-zlib --enable-xml --disable-rpath --enable-bcmath --enable-shmop --enable-sysvsem ${with_curl} --enable-mbregex --enable-mbstring --enable-intl --enable-pcntl --enable-ftp --enable-gd ${with_openssl} --with-mhash --enable-pcntl --enable-sockets --with-zip --enable-soap --with-gettext ${with_fileinfo} --enable-opcache --with-xsl --with-pear --with-webp ${PHP_Buildin_Option} ${PHP_Modules_Options}
    else
        ./configure --prefix=/usr/local/php --with-config-file-path=/usr/local/php/etc --with-config-file-scan-dir=/usr/local/php/conf.d --with-apxs2=/usr/local/apache/bin/apxs --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --with-iconv=/usr/local --with-freetype=/usr/local/freetype --with-jpeg --with-zlib --enable-xml --disable-rpath --enable-bcmath --enable-shmop --enable-sysvsem ${with_curl} --enable-mbregex --enable-mbstring --enable-intl --enable-pcntl --enable-ftp --enable-gd ${with_openssl} --with-mhash --enable-pcntl --enable-sockets --with-zip --enable-soap --with-gettext ${with_fileinfo} --enable-opcache --with-xsl --with-pear --with-webp ${PHP_Buildin_Option} ${PHP_Modules_Options}
    fi

    PHP_Make_Install || exit 1

    Ln_PHP_Bin

    echo "Copy new php configure file..."
    mkdir -p /usr/local/php/{etc,conf.d}
    \cp php.ini-production /usr/local/php/etc/php.ini

    # php extensions
    echo "Modify php.ini......"
    sed -i 's/post_max_size =.*/post_max_size = 50M/g' /usr/local/php/etc/php.ini
    sed -i 's/upload_max_filesize =.*/upload_max_filesize = 50M/g' /usr/local/php/etc/php.ini
    sed -i 's/;date.timezone =.*/date.timezone = PRC/g' /usr/local/php/etc/php.ini
    sed -i 's/short_open_tag =.*/short_open_tag = On/g' /usr/local/php/etc/php.ini
    sed -i 's/;cgi.fix_pathinfo=.*/cgi.fix_pathinfo=0/g' /usr/local/php/etc/php.ini
    # 关闭 X-Powered-By 响应头，避免对外暴露 PHP 版本号。
    sed -i 's/^expose_php =.*/expose_php = Off/g' /usr/local/php/etc/php.ini
    sed -i 's/max_execution_time =.*/max_execution_time = 300/g' /usr/local/php/etc/php.ini
    sed -i 's/disable_functions =.*/disable_functions = passthru,exec,system,chroot,chgrp,chown,shell_exec,proc_open,proc_get_status,popen,ini_alter,ini_restore,dl,openlog,syslog,readlink,symlink,popepassthru,stream_socket_server/g' /usr/local/php/etc/php.ini
    Pear_Pecl_Set
    Install_Composer

    cd ${cur_dir}/src

if [ "${Stack}" = "lnmp" ]; then
    # listen.mode 从 0666 收紧到 0660（另三处 pool 配置同步：multiplephp.sh、
    # upgrade_php.sh、upgrade_mphp.sh）。
    #
    # 0666 意味着机器上任何本地账号都能连 FPM socket，进而构造 FastCGI
    # 该请求会让 PHP 执行外部可控脚本，从而暴露 www 进程权限。
    # 0660 + listen.owner/group = www 后，只有 www 组成员能连；
    # nginx worker 正是以 www 运行（LNMPA/LAMP 下的 httpd 同理），不受影响。
    echo "Creating new php-fpm configure file..."
    cat >/usr/local/php/etc/php-fpm.conf<<EOF
[global]
pid = /usr/local/php/var/run/php-fpm.pid
error_log = /usr/local/php/var/log/php-fpm.log
log_level = notice

[www]
listen = /tmp/php-cgi.sock
listen.backlog = -1
listen.allowed_clients = 127.0.0.1
listen.owner = www
listen.group = www
listen.mode = 0660
user = www
group = www
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 6
pm.max_requests = 1024
pm.process_idle_timeout = 10s
request_terminate_timeout = 100
request_slowlog_timeout = 0
slowlog = var/log/slow.log
EOF

    echo "Copy php-fpm init.d file..."
    \cp ${cur_dir}/src/${Php_Ver}/sapi/fpm/init.d.php-fpm /etc/init.d/php-fpm
    \cp ${cur_dir}/init.d/php-fpm.service /etc/systemd/system/php-fpm.service
    chmod +x /etc/init.d/php-fpm
fi
}

Install_PHP_80() { Install_PHP_8x; }
Install_PHP_81() { Install_PHP_8x; }
Install_PHP_82() { Install_PHP_8x; }
Install_PHP_83() { Install_PHP_8x; }
Install_PHP_84() { Install_PHP_8x; }
Install_PHP_85() { Install_PHP_8x; }

LNMP_PHP_Opt()
{
    if [[ ${MemTotal} -gt 1024 && ${MemTotal} -le 2048 ]]; then
        sed -i "s#pm.max_children.*#pm.max_children = 20#" /usr/local/php/etc/php-fpm.conf
        sed -i "s#pm.start_servers.*#pm.start_servers = 10#" /usr/local/php/etc/php-fpm.conf
        sed -i "s#pm.min_spare_servers.*#pm.min_spare_servers = 10#" /usr/local/php/etc/php-fpm.conf
        sed -i "s#pm.max_spare_servers.*#pm.max_spare_servers = 20#" /usr/local/php/etc/php-fpm.conf
    elif [[ ${MemTotal} -gt 2048 && ${MemTotal} -le 4096 ]]; then
        sed -i "s#pm.max_children.*#pm.max_children = 40#" /usr/local/php/etc/php-fpm.conf
        sed -i "s#pm.start_servers.*#pm.start_servers = 20#" /usr/local/php/etc/php-fpm.conf
        sed -i "s#pm.min_spare_servers.*#pm.min_spare_servers = 20#" /usr/local/php/etc/php-fpm.conf
        sed -i "s#pm.max_spare_servers.*#pm.max_spare_servers = 40#" /usr/local/php/etc/php-fpm.conf
    elif [[ ${MemTotal} -gt 4096 && ${MemTotal} -le 8192 ]]; then
        sed -i "s#pm.max_children.*#pm.max_children = 60#" /usr/local/php/etc/php-fpm.conf
        sed -i "s#pm.start_servers.*#pm.start_servers = 30#" /usr/local/php/etc/php-fpm.conf
        sed -i "s#pm.min_spare_servers.*#pm.min_spare_servers = 30#" /usr/local/php/etc/php-fpm.conf
        sed -i "s#pm.max_spare_servers.*#pm.max_spare_servers = 60#" /usr/local/php/etc/php-fpm.conf
    elif [[ ${MemTotal} -gt 8192 ]]; then
        sed -i "s#pm.max_children.*#pm.max_children = 80#" /usr/local/php/etc/php-fpm.conf
        sed -i "s#pm.start_servers.*#pm.start_servers = 40#" /usr/local/php/etc/php-fpm.conf
        sed -i "s#pm.min_spare_servers.*#pm.min_spare_servers = 40#" /usr/local/php/etc/php-fpm.conf
        sed -i "s#pm.max_spare_servers.*#pm.max_spare_servers = 80#" /usr/local/php/etc/php-fpm.conf
    fi
}


Creat_PHP_Tools()
{
    cd ${cur_dir}/src

    \cp ${cur_dir}/conf/index.html ${Default_Website_Dir}/index.html
    \cp ${cur_dir}/conf/lnmp.gif ${Default_Website_Dir}/lnmp.gif

    if [ "${Enable_PHPInfo_Page}" = "y" ]; then
        echo "Create PHP Info Tool..."
        cat >${Default_Website_Dir}/phpinfo.php<<eof
<?php
phpinfo();
?>
eof
    fi

    if [ "${Enable_PhpMyAdmin}" = "y" ]; then
        echo "============================Install PHPMyAdmin================================="
        # 装到网站根目录之外，同时清掉历史版本留在根目录下的那一份
        [[ -d ${Default_Website_Dir}/phpmyadmin ]] && rm -rf ${Default_Website_Dir}/phpmyadmin
        [[ -d ${PhpMyAdmin_Dir} ]] && rm -rf ${PhpMyAdmin_Dir}
        tar Jxf ${PhpMyAdmin_Ver}.tar.xz
        mv ${PhpMyAdmin_Ver} ${PhpMyAdmin_Dir}
        \cp ${cur_dir}/conf/config.inc.php ${PhpMyAdmin_Dir}/config.inc.php
        # blowfish_secret 必须随机，否则所有安装共用同一密钥
        sed -i "s/LNMPORG/$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')/g" ${PhpMyAdmin_Dir}/config.inc.php
        # 访问路径随机化，避开针对固定 /phpmyadmin 的批量扫描与爆破。
        # 保留 _phpmyadmin 结尾：默认站点若配了严格的访问控制，
        # 这个固定后缀能让人一眼认出该路径的用途，写放行或封禁规则时好处理。
        printf '%s_phpmyadmin\n' "$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')" > ${PhpMyAdmin_Url_File}
        chmod 600 ${PhpMyAdmin_Url_File}
        # 模板缓存目录放在网站根目录之外：它需要 PHP 可写，而网站根目录下
        # 任何可写目录都是「上传 webshell 后能直接访问」的落点。
        # 不建这个目录 phpMyAdmin 也能跑，只是每次请求都要重新编译模板。
        #
        # 导入/导出用的 UploadDir、SaveDir 默认关闭（见 conf/config.inc.php），
        # 不在网站目录下创建 upload/save；导出文件包含完整数据库内容，
        # 落在网站目录里等于把整个数据库放到公网可下载的位置。
        mkdir -p /var/lib/phpmyadmin/tmp
        chown -R www:www /var/lib/phpmyadmin
        chmod 700 /var/lib/phpmyadmin/tmp
        chmod 755 -R ${PhpMyAdmin_Dir}/
        chown www:www -R ${PhpMyAdmin_Dir}/
        chmod 600 ${PhpMyAdmin_Url_File}
        echo "============================phpMyAdmin install completed======================="
    fi

    # 开启和关闭都在这里同步，不需要手工去改 default 站点的配置
    Config_PhpMyAdmin_Access
}

# Config_PhpMyAdmin_Access
#
# 按 Enable_PhpMyAdmin 同步 Web 服务器上的访问入口：开启时写入映射片段，
# 关闭时删除。片段文件名带固定前缀，主配置里用通配 include 引入——
# 通配符没有匹配到文件时不报错，所以关闭只需删文件，不必回头改主配置。
Config_PhpMyAdmin_Access()
{
    local nginx_frag='/usr/local/nginx/conf/phpmyadmin.enable.conf'
    local apache_frag='/usr/local/apache/conf/extra/phpmyadmin.enable.conf'
    local pma_url

    if [ "${Enable_PhpMyAdmin}" != "y" ]; then
        rm -f "${nginx_frag}" "${apache_frag}"
        return 0
    fi

    pma_url=$(cat "${PhpMyAdmin_Url_File}" 2>/dev/null)
    if [ -z "${pma_url}" ]; then
        Echo_Red "未能读到 phpMyAdmin 的访问路径，跳过入口配置。"
        return 1
    fi

    if [ -d /usr/local/nginx/conf ]; then
        if [ "${Stack}" = "lnmpa" ]; then
            # LNMPA 下 PHP 由 Apache 执行，nginx 只负责把该路径整体反代过去
            cat >"${nginx_frag}"<<EOF
        location = /${pma_url} {
            return 301 /${pma_url}/;
        }

        location ^~ /${pma_url}/ {
            proxy_pass http://127.0.0.1:88;
            include proxy.conf;
        }
EOF
        else
            # open_basedir 用 PHP_ADMIN_VALUE 下发：程序已不在网站根目录下，
            # 根目录里的 .user.ini 管不到它，必须在这里单独划定可访问范围。
            cat >"${nginx_frag}"<<EOF
        location = /${pma_url} {
            return 301 /${pma_url}/;
        }

        location ^~ /${pma_url}/ {
            alias ${PhpMyAdmin_Dir}/;
            index index.php;

            location ~ ^/${pma_url}/(.+\.php)\$ {
                alias ${PhpMyAdmin_Dir}/\$1;
                fastcgi_pass  unix:/tmp/php-cgi.sock;
                fastcgi_index index.php;
                include fastcgi.conf;
                fastcgi_param SCRIPT_FILENAME ${PhpMyAdmin_Dir}/\$1;
                fastcgi_param PHP_ADMIN_VALUE "open_basedir=${PhpMyAdmin_Dir}/:/var/lib/phpmyadmin/:/tmp/:/proc/";
            }
        }
EOF
        fi
        chmod 644 "${nginx_frag}"
    fi

    if [ -d /usr/local/apache/conf/extra ]; then
        cat >"${apache_frag}"<<EOF
Alias /${pma_url} "${PhpMyAdmin_Dir}"

<Directory "${PhpMyAdmin_Dir}">
    Options -Indexes +FollowSymLinks
    AllowOverride None
    Require all granted
    php_admin_value open_basedir "${PhpMyAdmin_Dir}/:/var/lib/phpmyadmin/:/tmp/:/proc/"
</Directory>
EOF
        chmod 644 "${apache_frag}"
    fi
}
