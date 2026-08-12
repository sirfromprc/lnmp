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
        sed -i "s/LNMP_DB_PORT/${DB_Port}/g" ${PhpMyAdmin_Dir}/config.inc.php
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

# Detect_PhpMyAdmin_Stack
#
# 独立安装入口不能沿用参数 Stack=phpmyadmin；Config_PhpMyAdmin_Access 需要知道
# 现有环境究竟是 LNMP、LNMPA 还是 LAMP，才能生成正确的映射。
Detect_PhpMyAdmin_Stack()
{
    if [ ! -s /bin/lnmp ]; then
        Echo_Red "未检测到已安装的 LNMP/LNMPA/LAMP 环境，请先安装主栈。"
        return 1
    fi

    if grep -q '^lnmpa_start()' /bin/lnmp; then
        Stack='lnmpa'
    elif grep -q '^lamp_start()' /bin/lnmp; then
        Stack='lamp'
    elif grep -q '^lnmp_start()' /bin/lnmp; then
        Stack='lnmp'
    else
        Echo_Red "无法从 /bin/lnmp 识别现有安装类型，拒绝写入 Web 配置。"
        return 1
    fi

    case "${Stack}" in
    lnmp)
        [ -x /usr/local/nginx/sbin/nginx ] || {
            Echo_Red "现有 LNMP 环境缺少 Nginx，无法启用 phpMyAdmin。"; return 1; }
        ;;
    lnmpa)
        [ -x /usr/local/nginx/sbin/nginx ] && [ -x /usr/local/apache/bin/httpd ] || {
            Echo_Red "现有 LNMPA 环境的 Nginx 或 Apache 不完整，无法启用 phpMyAdmin。"; return 1; }
        ;;
    lamp)
        [ -x /usr/local/apache/bin/httpd ] || {
            Echo_Red "现有 LAMP 环境缺少 Apache，无法启用 phpMyAdmin。"; return 1; }
        ;;
    esac
}

Ensure_PhpMyAdmin_Config_Hooks()
{
    local nginx_conf='/usr/local/nginx/conf/nginx.conf'
    local apache_conf='/usr/local/apache/conf/httpd.conf'
    local tmp

    PMA_Nginx_Main_Backup=''
    PMA_Apache_Main_Backup=''

    if [ "${Stack}" = 'lnmp' ] || [ "${Stack}" = 'lnmpa' ]; then
        if ! grep -q 'include phpmyadmin\.\*\.conf;' "${nginx_conf}"; then
            PMA_Nginx_Main_Backup="${cur_dir}/src/.nginx-pma-backup.$$"
            tmp="${cur_dir}/src/.nginx-pma-new.$$"
            \cp -p "${nginx_conf}" "${PMA_Nginx_Main_Backup}" || return 1
            if ! awk -v website_root="${Default_Website_Dir}" '
                /^[[:space:]]*server[[:space:]]*\{/ { in_server=1; is_default=0 }
                in_server && /^[[:space:]]*listen[[:space:]].*default_server/ { is_default=1 }
                {
                    print
                    line=$0
                    sub(/^[[:space:]]*/, "", line)
                    sub(/[[:space:]]*;[[:space:]]*$/, "", line)
                    if (is_default && line == "root  " website_root) {
                        print "        include phpmyadmin.*.conf;"
                        inserted=1
                        is_default=0
                    }
                }
                END { if (!inserted) exit 1 }
            ' "${nginx_conf}" > "${tmp}"; then
                Echo_Red "未能在 Nginx 默认站点中定位 phpMyAdmin 配置入口。"
                rm -f "${tmp}"
                return 1
            fi
            chmod --reference="${nginx_conf}" "${tmp}" 2>/dev/null || chmod 644 "${tmp}"
            if ! mv "${tmp}" "${nginx_conf}"; then
                rm -f "${tmp}"
                return 1
            fi
        fi
    fi

    if [ "${Stack}" = 'lamp' ] || [ "${Stack}" = 'lnmpa' ]; then
        if ! grep -q 'IncludeOptional conf/extra/phpmyadmin\.\*\.conf' "${apache_conf}"; then
            PMA_Apache_Main_Backup="${cur_dir}/src/.apache-pma-backup.$$"
            \cp -p "${apache_conf}" "${PMA_Apache_Main_Backup}" || return 1
            printf '\n# phpMyAdmin optional access mapping\nIncludeOptional conf/extra/phpmyadmin.*.conf\n' \
                >> "${apache_conf}" || return 1
        fi
    fi
    return 0
}

Check_PhpMyAdmin_Web_Config()
{
    case "${Stack}" in
    lnmp)
        /usr/local/nginx/sbin/nginx -t
        ;;
    lnmpa)
        /usr/local/nginx/sbin/nginx -t && /usr/local/apache/bin/httpd -t
        ;;
    lamp)
        /usr/local/apache/bin/httpd -t
        ;;
    esac
}

Get_PhpMyAdmin_HTTP_Port()
{
    local port=''

    if [ "${Stack}" = 'lnmp' ] || [ "${Stack}" = 'lnmpa' ]; then
        port=$(/usr/local/nginx/sbin/nginx -T 2>/dev/null | \
            awk '/^[[:space:]]*listen[[:space:]]+[0-9]+([[:space:];]|$)/ {
                value=$2; sub(/;.*/, "", value); print value; exit
            }')
    else
        port=$(/usr/local/apache/bin/httpd -t -D DUMP_RUN_CFG 2>/dev/null | \
            awk '/Listen:/ && $0 !~ /127\.0\.0\.1:/ {
                value=$2; sub(/^.*:/, "", value); print value; exit
            }')
    fi
    case "${port}" in
    ''|*[!0-9]*)
        Echo_Red "无法读取现有 Web 服务的 HTTP 监听端口。"
        return 1
        ;;
    esac
    printf '%s\n' "${port}"
}

Reload_PhpMyAdmin_Web()
{
    case "${Stack}" in
    lnmp)
        StartOrStop reload nginx
        ;;
    lnmpa)
        StartOrStop reload nginx && StartOrStop reload httpd
        ;;
    lamp)
        StartOrStop reload httpd
        ;;
    esac
}

PhpMyAdmin_Access_Status()
{
    local nginx_live='/usr/local/nginx/conf/phpmyadmin.enable.conf'
    local apache_live='/usr/local/apache/conf/extra/phpmyadmin.enable.conf'
    local enabled='y'

    if [ ! -s "${PhpMyAdmin_Dir}/index.php" ] || [ ! -s "${PhpMyAdmin_Url_File}" ]; then
        Echo_Red "phpMyAdmin 未安装。"
        return 1
    fi
    case "${Stack}" in
    lnmp) [ -s "${nginx_live}" ] || enabled='n' ;;
    lnmpa) [ -s "${nginx_live}" ] && [ -s "${apache_live}" ] || enabled='n' ;;
    lamp) [ -s "${apache_live}" ] || enabled='n' ;;
    esac
    if [ "${enabled}" = 'y' ]; then
        Echo_Green "phpMyAdmin 访问已开启：http://<服务器IP>/$(cat "${PhpMyAdmin_Url_File}")/"
    else
        Echo_Yellow "phpMyAdmin 访问已关闭，程序和配置保留在 ${PhpMyAdmin_Dir}。"
    fi
}

Install_PhpMyAdmin_Manager_Command()
{
    local manager='/bin/lnmp'
    local helper='/bin/lnmp-phpmyadmin'
    local tmp

    PMA_Manager_Backup=''
    PMA_Helper_Backup=''
    PMA_Helper_Was_Absent='n'

    [ -s "${manager}" ] || return 1
    [ -s "${cur_dir}/tools/lnmp-phpmyadmin.sh" ] || return 1

    if [ -e "${helper}" ]; then
        PMA_Helper_Backup="${cur_dir}/src/.lnmp-pma-helper-backup.$$"
        \cp -p "${helper}" "${PMA_Helper_Backup}" || return 1
    else
        PMA_Helper_Was_Absent='y'
    fi
    if ! \cp "${cur_dir}/tools/lnmp-phpmyadmin.sh" "${helper}" ||
       ! chmod 755 "${helper}"; then
        return 1
    fi

    if ! grep -q '^[[:space:]]*phpmyadmin)' "${manager}"; then
        PMA_Manager_Backup="${cur_dir}/src/.lnmp-manager-backup.$$"
        tmp="${cur_dir}/src/.lnmp-manager-new.$$"
        \cp -p "${manager}" "${PMA_Manager_Backup}" || return 1
        if ! awk -v stack="${Stack}" '
            /^case "\$\{arg1\}" in$/ { in_main=1 }
            in_main && /^[[:space:]]*ssl\)/ && !inserted {
                print "    phpmyadmin)"
                print "        /bin/lnmp-phpmyadmin " stack " \"${arg2}\""
                print "        exit $?"
                print "        ;;"
                inserted=1
            }
            { print }
            END { if (!inserted) exit 1 }
        ' "${manager}" > "${tmp}"; then
            rm -f "${tmp}"
            return 1
        fi
        chmod --reference="${manager}" "${tmp}" 2>/dev/null || chmod 755 "${tmp}"
        mv "${tmp}" "${manager}" || { rm -f "${tmp}"; return 1; }
    fi
    return 0
}

Set_PhpMyAdmin_Access()
{
    local action="$1"
    local nginx_live='/usr/local/nginx/conf/phpmyadmin.enable.conf'
    local apache_live='/usr/local/apache/conf/extra/phpmyadmin.enable.conf'
    local nginx_saved='/usr/local/nginx/conf/.phpmyadmin.enable.conf.disabled'
    local apache_saved='/usr/local/apache/conf/extra/.phpmyadmin.enable.conf.disabled'
    local nginx_moved='n' apache_moved='n'

    if [ ! -s "${PhpMyAdmin_Dir}/index.php" ] || [ ! -s "${PhpMyAdmin_Url_File}" ]; then
        Echo_Red "phpMyAdmin 未安装，无法修改访问状态。"
        return 1
    fi
    case "${action}" in
    status)
        PhpMyAdmin_Access_Status
        return $?
        ;;
    disable)
        if { [ -e "${nginx_live}" ] && [ -e "${nginx_saved}" ]; } ||
           { [ -e "${apache_live}" ] && [ -e "${apache_saved}" ]; }; then
            Echo_Red "phpMyAdmin 访问配置同时存在启用和停用副本，请先人工核对。"
            return 1
        fi
        if [ "${Stack}" = 'lnmp' ] || [ "${Stack}" = 'lnmpa' ]; then
            [ ! -e "${nginx_live}" ] || {
                mv "${nginx_live}" "${nginx_saved}" || return 1; nginx_moved='y'; }
        fi
        if [ "${Stack}" = 'lamp' ] || [ "${Stack}" = 'lnmpa' ]; then
            if [ -e "${apache_live}" ]; then
                if ! mv "${apache_live}" "${apache_saved}"; then
                    [ "${nginx_moved}" = 'y' ] && mv "${nginx_saved}" "${nginx_live}"
                    return 1
                fi
                apache_moved='y'
            fi
        fi
        if [ "${nginx_moved}" = 'n' ] && [ "${apache_moved}" = 'n' ]; then
            PhpMyAdmin_Access_Status
            return 0
        fi
        ;;
    enable)
        if { [ -e "${nginx_live}" ] && [ -e "${nginx_saved}" ]; } ||
           { [ -e "${apache_live}" ] && [ -e "${apache_saved}" ]; }; then
            Echo_Red "phpMyAdmin 访问配置同时存在启用和停用副本，请先人工核对。"
            return 1
        fi
        if [ "${Stack}" = 'lnmp' ] || [ "${Stack}" = 'lnmpa' ]; then
            [ -e "${nginx_live}" ] || {
                [ -s "${nginx_saved}" ] || { Echo_Red "找不到停用的 Nginx 访问配置。"; return 1; }
                mv "${nginx_saved}" "${nginx_live}" || return 1; nginx_moved='y'; }
        fi
        if [ "${Stack}" = 'lamp' ] || [ "${Stack}" = 'lnmpa' ]; then
            if [ ! -e "${apache_live}" ]; then
                if [ ! -s "${apache_saved}" ] || ! mv "${apache_saved}" "${apache_live}"; then
                    [ "${nginx_moved}" = 'y' ] && mv "${nginx_live}" "${nginx_saved}"
                    Echo_Red "找不到或无法恢复停用的 Apache 访问配置。"
                    return 1
                fi
                apache_moved='y'
            fi
        fi
        if [ "${nginx_moved}" = 'n' ] && [ "${apache_moved}" = 'n' ]; then
            PhpMyAdmin_Access_Status
            return 0
        fi
        ;;
    *)
        Echo_Red "Usage: ./install.sh phpmyadmin {enable|disable|status}"
        return 1
        ;;
    esac

    if ! Check_PhpMyAdmin_Web_Config || ! Reload_PhpMyAdmin_Web; then
        if [ "${action}" = 'disable' ]; then
            [ "${nginx_moved}" = 'y' ] && mv "${nginx_saved}" "${nginx_live}"
            [ "${apache_moved}" = 'y' ] && mv "${apache_saved}" "${apache_live}"
        else
            [ "${nginx_moved}" = 'y' ] && mv "${nginx_live}" "${nginx_saved}"
            [ "${apache_moved}" = 'y' ] && mv "${apache_live}" "${apache_saved}"
        fi
        Check_PhpMyAdmin_Web_Config >/dev/null 2>&1 &&
            Reload_PhpMyAdmin_Web >/dev/null 2>&1 || true
        Echo_Red "Web 配置测试或重载失败，phpMyAdmin 访问状态已恢复。"
        return 1
    fi
    PhpMyAdmin_Access_Status
}

Smoke_Test_PhpMyAdmin_HTTP()
{
    local url="$1"
    local output="$2"
    local attempt

    command -v curl >/dev/null 2>&1 || return 1
    for attempt in 1 2 3 4 5; do
        if curl -fsS --max-time 15 "${url}" -o "${output}" &&
           grep -qi 'phpMyAdmin' "${output}"; then
            return 0
        fi
        rm -f "${output}"
        [ "${attempt}" -lt 5 ] && sleep 1
    done
    return 1
}

Rollback_PhpMyAdmin_Install()
{
    rm -f /usr/local/nginx/conf/phpmyadmin.enable.conf \
          /usr/local/apache/conf/extra/phpmyadmin.enable.conf
    if [ -n "${PMA_Nginx_Main_Backup}" ] && [ -s "${PMA_Nginx_Main_Backup}" ]; then
        mv -f "${PMA_Nginx_Main_Backup}" /usr/local/nginx/conf/nginx.conf
    fi
    if [ -n "${PMA_Apache_Main_Backup}" ] && [ -s "${PMA_Apache_Main_Backup}" ]; then
        mv -f "${PMA_Apache_Main_Backup}" /usr/local/apache/conf/httpd.conf
    fi
    if [ -n "${PMA_Manager_Backup}" ] && [ -s "${PMA_Manager_Backup}" ]; then
        mv -f "${PMA_Manager_Backup}" /bin/lnmp
    fi
    if [ -n "${PMA_Helper_Backup}" ] && [ -s "${PMA_Helper_Backup}" ]; then
        mv -f "${PMA_Helper_Backup}" /bin/lnmp-phpmyadmin
    elif [ "${PMA_Helper_Was_Absent}" = 'y' ]; then
        rm -f /bin/lnmp-phpmyadmin
    fi
    # 模板缓存目录也是本次安装建的，回滚要一并撤掉；但只删本次新建的那次，
    # 上一次安装留下的内容不能因为这次失败被清掉。
    [ "${PMA_Vardir_Was_Absent:-n}" = 'y' ] && rm -rf /var/lib/phpmyadmin
    [ -n "${PhpMyAdmin_Dir}" ] && [ "${PhpMyAdmin_Dir}" != '/' ] && \
        rm -rf "${PhpMyAdmin_Dir}"
}

Clean_PhpMyAdmin_Config_Backups()
{
    [ -n "${PMA_Nginx_Main_Backup}" ] && rm -f "${PMA_Nginx_Main_Backup}"
    [ -n "${PMA_Apache_Main_Backup}" ] && rm -f "${PMA_Apache_Main_Backup}"
    [ -n "${PMA_Manager_Backup}" ] && rm -f "${PMA_Manager_Backup}"
    [ -n "${PMA_Helper_Backup}" ] && rm -f "${PMA_Helper_Backup}"
}

Install_Only_phpMyAdmin()
{
    local action="${1:-}"
    local pma_ver pma_stage access_url smoke_body http_port

    echo "+-----------------------------------------------------------------------+"
    echo "|                    Install phpMyAdmin for LNMP                       |"
    echo "+-----------------------------------------------------------------------+"

    Detect_PhpMyAdmin_Stack || return 1

    if [ -n "${action}" ]; then
        Set_PhpMyAdmin_Access "${action}"
        return $?
    fi

    if [ ! -x /usr/local/php/bin/php ]; then
        Echo_Red "未检测到 /usr/local/php/bin/php，请先安装完整主栈。"
        return 1
    fi
    if ! /usr/local/php/bin/php -r \
        'exit(version_compare(PHP_VERSION, "7.2.5", ">=") ? 0 : 1);'; then
        Echo_Red "当前 PHP 版本低于 phpMyAdmin 5.2 所需的 PHP 7.2.5。"
        return 1
    fi
    if ! /usr/local/php/bin/php -m | grep -Eqi '^mysqli$'; then
        Echo_Red "当前 PHP 未启用 mysqli 扩展，phpMyAdmin 无法连接数据库。"
        return 1
    fi
    if ! id www >/dev/null 2>&1; then
        Echo_Red "未检测到 www 运行用户，现有主栈不完整。"
        return 1
    fi

    if [ -e "${PhpMyAdmin_Dir}" ] || \
       [ -e /usr/local/nginx/conf/phpmyadmin.enable.conf ] || \
       [ -e /usr/local/nginx/conf/.phpmyadmin.enable.conf.disabled ] || \
       [ -e /usr/local/apache/conf/extra/.phpmyadmin.enable.conf.disabled ] || \
       [ -e /usr/local/apache/conf/extra/phpmyadmin.enable.conf ]; then
        Echo_Red "phpMyAdmin 已安装或已有启用配置，未覆盖现有文件。"
        Echo_Red "如需升级，请执行：./upgrade.sh phpmyadmin"
        return 1
    fi

    Set_PHP_Profile "${PHP_Default}" || return 1
    pma_ver="${PhpMyAdmin_Ver#phpMyAdmin-}"
    pma_ver="${pma_ver%-all-languages}"
    pma_stage="${cur_dir}/src/.phpmyadmin-install.$$"

    cd "${cur_dir}/src" || return 1
    Download_Files \
        "https://files.phpmyadmin.net/phpMyAdmin/${pma_ver}/${PhpMyAdmin_Ver}.tar.xz" \
        "${PhpMyAdmin_Ver}.tar.xz" || return 1
    Require_File "${PhpMyAdmin_Ver}.tar.xz" "phpMyAdmin"

    rm -rf "${pma_stage}"
    mkdir -p "${pma_stage}" || return 1
    if ! tar Jxf "${PhpMyAdmin_Ver}.tar.xz" -C "${pma_stage}" || \
       [ ! -s "${pma_stage}/${PhpMyAdmin_Ver}/index.php" ]; then
        Echo_Red "phpMyAdmin 解压失败或归档结构异常，未修改现有环境。"
        rm -rf "${pma_stage}"
        return 1
    fi

    if ! \cp "${cur_dir}/conf/config.inc.php" \
        "${pma_stage}/${PhpMyAdmin_Ver}/config.inc.php"; then
        Echo_Red "写入 phpMyAdmin 配置失败，未修改现有环境。"
        rm -rf "${pma_stage}"
        return 1
    fi
    access_url="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')_phpmyadmin"
    if [ -z "${access_url}" ]; then
        Echo_Red "生成 phpMyAdmin 随机访问路径失败。"
        rm -rf "${pma_stage}"
        return 1
    fi
    sed -i "s/LNMPORG/$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')/g" \
        "${pma_stage}/${PhpMyAdmin_Ver}/config.inc.php" || {
        rm -rf "${pma_stage}"; return 1; }
    sed -i "s/LNMP_DB_PORT/${DB_Port}/g" \
        "${pma_stage}/${PhpMyAdmin_Ver}/config.inc.php" || {
        rm -rf "${pma_stage}"; return 1; }
    printf '%s\n' "${access_url}" > \
        "${pma_stage}/${PhpMyAdmin_Ver}/.access_url" || {
        rm -rf "${pma_stage}"; return 1; }

    PMA_Vardir_Was_Absent='n'
    [ -e /var/lib/phpmyadmin ] || PMA_Vardir_Was_Absent='y'
    mkdir -p /var/lib/phpmyadmin/tmp || { rm -rf "${pma_stage}"; return 1; }
    chown -R www:www /var/lib/phpmyadmin || { rm -rf "${pma_stage}"; return 1; }
    chmod 700 /var/lib/phpmyadmin/tmp || { rm -rf "${pma_stage}"; return 1; }
    chmod 755 -R "${pma_stage}/${PhpMyAdmin_Ver}" || { rm -rf "${pma_stage}"; return 1; }
    chown -R www:www "${pma_stage}/${PhpMyAdmin_Ver}" || { rm -rf "${pma_stage}"; return 1; }
    chmod 600 "${pma_stage}/${PhpMyAdmin_Ver}/.access_url" || {
        rm -rf "${pma_stage}"; return 1; }

    if ! mv "${pma_stage}/${PhpMyAdmin_Ver}" "${PhpMyAdmin_Dir}"; then
        Echo_Red "部署 phpMyAdmin 失败，未修改 Web 配置。"
        rm -rf "${pma_stage}"
        return 1
    fi
    rm -rf "${pma_stage}"

    # 独立入口显式开启，但不改 lnmp.conf；以后完整安装仍然默认不装。
    Enable_PhpMyAdmin='y'
    if ! Ensure_PhpMyAdmin_Config_Hooks || \
       ! Config_PhpMyAdmin_Access || ! Check_PhpMyAdmin_Web_Config; then
        Echo_Red "Web 配置测试未通过，正在撤销本次 phpMyAdmin 安装。"
        Rollback_PhpMyAdmin_Install
        Check_PhpMyAdmin_Web_Config >/dev/null 2>&1 || true
        return 1
    fi
    if ! Reload_PhpMyAdmin_Web; then
        Echo_Red "Web 服务重载失败，正在撤销本次 phpMyAdmin 安装。"
        Rollback_PhpMyAdmin_Install
        Check_PhpMyAdmin_Web_Config >/dev/null 2>&1 && \
            Reload_PhpMyAdmin_Web >/dev/null 2>&1 || true
        return 1
    fi

    if [ ! -s "${PhpMyAdmin_Dir}/index.php" ] || \
       [ ! -s "${PhpMyAdmin_Url_File}" ]; then
        Echo_Red "phpMyAdmin 安装产物不完整。"
        Rollback_PhpMyAdmin_Install
        Reload_PhpMyAdmin_Web >/dev/null 2>&1 || true
        return 1
    fi

    smoke_body="${pma_stage}.smoke"
    http_port=$(Get_PhpMyAdmin_HTTP_Port) || {
        Rollback_PhpMyAdmin_Install; Reload_PhpMyAdmin_Web >/dev/null 2>&1 || true; return 1; }
    if ! Smoke_Test_PhpMyAdmin_HTTP \
        "http://127.0.0.1:${http_port}/${access_url}/" "${smoke_body}"; then
        Echo_Red "phpMyAdmin 本机 HTTP 冒烟验证失败，正在撤销本次安装。"
        rm -f "${smoke_body}"
        Rollback_PhpMyAdmin_Install
        Reload_PhpMyAdmin_Web >/dev/null 2>&1 || true
        return 1
    fi
    rm -f "${smoke_body}"
    if ! Install_PhpMyAdmin_Manager_Command; then
        Echo_Red "安装 phpMyAdmin 管理命令失败，正在撤销本次安装。"
        Rollback_PhpMyAdmin_Install
        Reload_PhpMyAdmin_Web >/dev/null 2>&1 || true
        return 1
    fi
    Clean_PhpMyAdmin_Config_Backups

    Echo_Green "phpMyAdmin ${pma_ver} install completed."
    Echo_Green "访问地址：http://<服务器IP>/${access_url}/"
    return 0
}
