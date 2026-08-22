#!/usr/bin/env bash

# 返回当前操作的 PHP 主版本号，按以下来源依次确定：
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
        Echo_Green "Curl 检查通过。"
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
            Apt_Get install -y libldap2-dev libsasl2-dev
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

# 当前 PHP 版本均可内建 Sodium，启用时安装系统依赖并传入构建参数。
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
            Apt_Get install -y libsodium-dev
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
                        Echo_Red "src/ 中未找到 uw-imap RPM，IMAP 支持可能编译失败。"
                    fi
                fi
            fi
            [[ -s /usr/lib64/libc-client.so ]] && ln -sf /usr/lib64/libc-client.so /usr/lib/libc-client.so
        elif [ "$PM" = "apt" ]; then
            Apt_Get install -y libc-client-dev libkrb5-dev
        fi
        with_imap='--with-imap --with-imap-ssl --with-kerberos'
    fi
}

# 当前 PHP 8.x 使用发行版提供的 ICU，无需单独安装旧版 ICU。
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
}

# php.ini 基线参数。安装、多版本安装与两条升级路径共用同一份，
# 避免各入口各写一份导致 disable_functions 等安全基线漂移。
PHP_Ini_Tune()
{
    local ini="$1"

    if [ ! -s "${ini}" ]; then
        Echo_Red "php.ini 不存在或为空：${ini}"
        return 1
    fi

    sed -i 's/post_max_size =.*/post_max_size = 50M/g' "${ini}"
    sed -i 's/upload_max_filesize =.*/upload_max_filesize = 50M/g' "${ini}"
    sed -i 's/;date.timezone =.*/date.timezone = PRC/g' "${ini}"
    sed -i 's/short_open_tag =.*/short_open_tag = On/g' "${ini}"
    sed -i 's/;cgi.fix_pathinfo=.*/cgi.fix_pathinfo=0/g' "${ini}"
    # 关闭 X-Powered-By 响应头，避免对外暴露 PHP 版本号。
    sed -i 's/^expose_php =.*/expose_php = Off/g' "${ini}"
    sed -i 's/max_execution_time =.*/max_execution_time = 300/g' "${ini}"
    # 禁用命令执行类函数。pcntl_exec 属执行类，pcntl_fork/signal/wait 不禁用。
    sed -i 's/disable_functions =.*/disable_functions = passthru,exec,system,chroot,chgrp,chown,shell_exec,proc_open,proc_get_status,popen,ini_alter,ini_restore,dl,openlog,syslog,readlink,symlink,popepassthru,stream_socket_server,pcntl_exec/g' "${ini}"

    return 0
}

Pear_Pecl_Set()
{
    pear config-set php_ini /usr/local/php/etc/php.ini
    pecl config-set php_ini /usr/local/php/etc/php.ini
}


Install_Composer()
{
    local expected actual installer signature tmpdir php_bin

    if [ "${Enable_Composer:-y}" != 'y' ]; then
        echo "已按 Enable_Composer=${Enable_Composer} 跳过 Composer 安装。"
        return 0
    fi

    if command -v php >/dev/null 2>&1; then
        php_bin=$(command -v php)
    elif [ -x /usr/local/php/bin/php ]; then
        php_bin=/usr/local/php/bin/php
    else
        Echo_Red "未找到 PHP，跳过 Composer 安装。"
        return 1
    fi

    tmpdir=$(mktemp -d "${cur_dir}/src/composer.XXXXXX") || return 1
    installer="${tmpdir}/composer-setup.php"
    signature="${tmpdir}/installer.sig"

    # 先取得官方 SHA384；缺少校验依据时不执行远程安装程序。
    echo "正在从 composer.github.io 获取 Composer 安装程序签名..."
    if ! Download_Fetch https://composer.github.io/installer.sig "${signature}"; then
        Echo_Red "Composer 安装程序签名下载失败，拒绝继续。"
        rm -rf "${tmpdir}"
        return 1
    fi
    expected=$(tr -d '[:space:]' < "${signature}")
    if ! echo "${expected}" | grep -Eq '^[0-9a-f]{96}$'; then
        Echo_Red "Composer 安装程序签名不是有效的 SHA384，拒绝继续。"
        Echo_Red "实际获取：${expected:0:120}"
        rm -rf "${tmpdir}"
        return 1
    fi

    echo "正在从 getcomposer.org 下载 Composer 安装程序..."
    if ! Download_Fetch https://getcomposer.org/installer "${installer}" \
       || [ ! -s "${installer}" ]; then
        Echo_Red "Composer 安装程序下载失败，跳过 Composer 安装。"
        rm -rf "${tmpdir}"
        return 1
    fi

    actual=$("${php_bin}" -r 'echo hash_file("sha384", $argv[1]);' "${installer}")
    if [ "${expected}" != "${actual}" ]; then
        Echo_Red "Composer 安装程序 SHA384 不匹配，拒绝执行。"
        Echo_Red "预期值=${expected}"
        Echo_Red "实际值=${actual}"
        rm -rf "${tmpdir}"
        return 1
    fi
    Echo_Green "Composer 安装程序 SHA384 校验通过。"

    "${php_bin}" "${installer}" --install-dir=/usr/local/bin --filename=composer
    rm -rf "${tmpdir}"
    if [ -s /usr/local/bin/composer ]; then
        chmod +x /usr/local/bin/composer
        echo "Composer 安装成功。"
        return 0
    fi
    Echo_Red "Composer 安装失败。"
    return 1
}

# PHP 8.0 在 OpenSSL 3.x 环境中需要兼容补丁；PHP 8.1 及以上原生支持。
PHP_Openssl3_Patch()
{
    local branch
    [ "${isOpenSSL3}" != "y" ] && return 0
    branch=$(Cur_PHP_Branch)
    [ "${branch}" != "8.0" ] && return 0

    echo "检测到 OpenSSL 3.0，正在为 PHP ${branch} 应用补丁..."
    patch -p1 < ${cur_dir}/src/patch/php-8.0-openssl3.0.patch
}


Install_PHP_8x()
{
    Install_Libzip
    Echo_Blue "[+] 正在安装 ${Php_Ver}"
    Tar_Cd ${Php_Ver}.tar.bz2 ${Php_Ver}
    PHP_Openssl3_Patch
    # configure 的 iconv 探针要能加载 /usr/local/lib 里的 libiconv.so.2。
    Ensure_Libiconv_Ldpath || exit 1

    if [ "${Stack}" = "lnmp" ]; then
        ./configure --prefix=/usr/local/php --with-config-file-path=/usr/local/php/etc --with-config-file-scan-dir=/usr/local/php/conf.d --enable-fpm --with-fpm-user=www --with-fpm-group=www --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --with-iconv=/usr/local --with-freetype=/usr/local/freetype --with-jpeg --with-zlib --enable-xml --disable-rpath --enable-bcmath --enable-shmop --enable-sysvsem ${with_curl} --enable-mbregex --enable-mbstring --enable-intl --enable-pcntl --enable-ftp --enable-gd ${with_openssl} --with-mhash --enable-pcntl --enable-sockets --with-zip --enable-soap --with-gettext ${with_fileinfo} --enable-opcache --with-xsl --with-pear --with-webp ${PHP_Buildin_Option} ${PHP_Modules_Options}
    else
        ./configure --prefix=/usr/local/php --with-config-file-path=/usr/local/php/etc --with-config-file-scan-dir=/usr/local/php/conf.d --with-apxs2=/usr/local/apache/bin/apxs --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --with-iconv=/usr/local --with-freetype=/usr/local/freetype --with-jpeg --with-zlib --enable-xml --disable-rpath --enable-bcmath --enable-shmop --enable-sysvsem ${with_curl} --enable-mbregex --enable-mbstring --enable-intl --enable-pcntl --enable-ftp --enable-gd ${with_openssl} --with-mhash --enable-pcntl --enable-sockets --with-zip --enable-soap --with-gettext ${with_fileinfo} --enable-opcache --with-xsl --with-pear --with-webp ${PHP_Buildin_Option} ${PHP_Modules_Options}
    fi

    PHP_Make_Install || exit 1

    Ln_PHP_Bin

    echo "正在复制新的 PHP 配置文件..."
    mkdir -p /usr/local/php/{etc,conf.d}
    # 重装时清掉旧 ini：它们指向上一次安装的扩展目录，保留会让 PHP 启动告警。
    rm -f /usr/local/php/conf.d/*
    \cp php.ini-production /usr/local/php/etc/php.ini

    # 配置 PHP 扩展及运行参数。
    echo "正在修改 php.ini..."
    PHP_Ini_Tune /usr/local/php/etc/php.ini || exit 1
    Pear_Pecl_Set
    Install_Composer

    cd ${cur_dir}/src

if [ "${Stack}" = "lnmp" ]; then
    # PHP-FPM socket 限定为 www 用户组访问，防止其他本地账号提交 FastCGI 请求。
    echo "正在创建新的 php-fpm 配置文件..."
    cat >/usr/local/php/etc/php-fpm.conf<<EOF
[global]
pid = /usr/local/php/var/run/php-fpm.pid
error_log = /usr/local/php/var/log/php-fpm.log
log_level = notice

[www]
    listen = /run/php-fpm/php-cgi.sock
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

    echo "正在复制 php-fpm init.d 服务脚本..."
    \cp ${cur_dir}/src/${Php_Ver}/sapi/fpm/init.d.php-fpm /etc/init.d/php-fpm
    \cp ${cur_dir}/init.d/php-fpm.service /etc/systemd/system/php-fpm.service
    chmod +x /etc/init.d/php-fpm
    Ensure_Runtime_Directory /run/php-fpm root root || return 1
    Patch_Init_Runtime_Directory /etc/init.d/php-fpm /run/php-fpm root root || return 1
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
    local pma_stage pma_secret access_url pma_vardir_was_absent='n'

    cd ${cur_dir}/src

    \cp ${cur_dir}/conf/index.html ${Default_Website_Dir}/index.html
    # 默认站点自带 favicon，避免浏览器请求在 error_log 中反复记录 404
    \cp ${cur_dir}/conf/favicon.ico ${Default_Website_Dir}/favicon.ico ||
        Echo_Red "favicon.ico 部署失败，默认站点仍会记录 /favicon.ico 404。"

    if [ "${Enable_PHPInfo_Page}" = "y" ]; then
        echo "正在创建 PHP 信息页面..."
        cat >${Default_Website_Dir}/phpinfo.php<<eof
<?php
phpinfo();
?>
eof
        Warn_Demo_Page_Not_Served phpinfo.php
    fi

    if [ "${Enable_PhpMyAdmin}" = "y" ]; then
        echo "============================ 正在安装 phpMyAdmin ============================="
        # 部署到网站根目录之外，并清理根目录中的旧版副本以避免源码泄露。
        if [ -n "${Default_Website_Dir}" ] && [ -d "${Default_Website_Dir}/phpmyadmin" ]; then
            rm -rf "${Default_Website_Dir}/phpmyadmin"
        fi
        Remove_PhpMyAdmin_Dir
        pma_stage="${cur_dir}/src/.phpmyadmin-full-install.$$"
        rm -rf "${pma_stage}"
        mkdir -p "${pma_stage}" || return 1
        if ! tar Jxf "${PhpMyAdmin_Ver}.tar.xz" -C "${pma_stage}" ||
           [ ! -s "${pma_stage}/${PhpMyAdmin_Ver}/index.php" ]; then
            Echo_Red "phpMyAdmin 解压失败或归档结构异常。"
            rm -rf "${pma_stage}"
            return 1
        fi
        if ! \cp "${cur_dir}/conf/config.inc.php" \
            "${pma_stage}/${PhpMyAdmin_Ver}/config.inc.php"; then
            Echo_Red "写入 phpMyAdmin 配置失败。"
            rm -rf "${pma_stage}"
            return 1
        fi
        # 每次生成独立的 blowfish_secret，避免不同安装共享会话加密密钥。
        pma_secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        access_url="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')_phpmyadmin"
        if [ -z "${pma_secret}" ] || [ "${access_url}" = '_phpmyadmin' ] ||
           ! sed -i "s/LNMPORG/${pma_secret}/g" \
                "${pma_stage}/${PhpMyAdmin_Ver}/config.inc.php" ||
           ! sed -i "s/LNMP_DB_PORT/${DB_Port}/g" \
                "${pma_stage}/${PhpMyAdmin_Ver}/config.inc.php" ||
           grep -qE 'LNMPORG|LNMP_DB_PORT' \
                "${pma_stage}/${PhpMyAdmin_Ver}/config.inc.php"; then
            Echo_Red "生成 phpMyAdmin 配置失败。"
            rm -rf "${pma_stage}"
            return 1
        fi
        # 随机访问路径可减少针对固定 /phpmyadmin 的批量扫描；固定后缀便于
        # 在访问控制和日志中识别用途。
        if ! printf '%s\n' "${access_url}" > \
            "${pma_stage}/${PhpMyAdmin_Ver}/.access_url"; then
            rm -rf "${pma_stage}"
            return 1
        fi
        # 可写模板缓存放在网站目录之外，防止上传内容被 Web 直接访问。
        # 导入和导出目录默认关闭，避免数据库文件落入公开目录。
        [ -e /var/lib/phpmyadmin ] || pma_vardir_was_absent='y'
        if ! mkdir -p /var/lib/phpmyadmin/tmp ||
           ! chown -R www:www /var/lib/phpmyadmin ||
           ! chmod 700 /var/lib/phpmyadmin/tmp ||
           ! Set_PhpMyAdmin_Dir_Perm "${pma_stage}/${PhpMyAdmin_Ver}" ||
           ! mv "${pma_stage}/${PhpMyAdmin_Ver}" "${PhpMyAdmin_Dir}"; then
            Echo_Red "部署 phpMyAdmin 失败。"
            rm -rf "${pma_stage}"
            Remove_PhpMyAdmin_Dir
            [ "${pma_vardir_was_absent}" = 'y' ] && rm -rf /var/lib/phpmyadmin
            return 1
        fi
        rm -rf "${pma_stage}"
        echo "============================ phpMyAdmin 安装完成 ============================="
    fi

    # 按开关同步 Web 访问入口，无需手工修改默认站点。
    if ! Config_PhpMyAdmin_Access; then
        rm -f /usr/local/nginx/conf/phpmyadmin.enable.conf \
              /usr/local/apache/conf/extra/phpmyadmin.enable.conf
        if [ "${Enable_PhpMyAdmin}" = 'y' ]; then
            Remove_PhpMyAdmin_Dir
            [ "${pma_vardir_was_absent}" = 'y' ] && rm -rf /var/lib/phpmyadmin
        fi
        return 1
    fi
    return 0
}

# 收紧 phpMyAdmin 程序目录权限：属主 root、属组 www，目录 750、文件 640。
# PHP-FPM 以 www 运行，只读即可；可写内容位于 /var/lib/phpmyadmin/tmp。
# config.inc.php 含 blowfish_secret，不能让本机其它账号读取。
Set_PhpMyAdmin_Dir_Perm()
{
    local dir="$1"
    [ -n "${dir}" ] && [ -d "${dir}" ] || return 1
    chown -R root:www "${dir}" || return 1
    find "${dir}" -type d -exec chmod 750 {} + || return 1
    find "${dir}" -type f -exec chmod 640 {} + || return 1
    [ -e "${dir}/.access_url" ] || return 0
    chown root:root "${dir}/.access_url" && chmod 600 "${dir}/.access_url"
}

# 删除 phpMyAdmin 程序目录；路径为空或为根目录时拒绝执行，防止越界删除。
Remove_PhpMyAdmin_Dir()
{
    [ -n "${PhpMyAdmin_Dir}" ] && [ "${PhpMyAdmin_Dir}" != '/' ] || return 0
    rm -rf "${PhpMyAdmin_Dir}"
}

# 按 Enable_PhpMyAdmin 同步 Web 服务器上的访问入口：开启时写入映射片段，
# 关闭时删除。片段文件名带固定前缀，主配置通过通配 include 引入，
# 通配符没有匹配到文件时不报错，所以关闭只需删文件，不必回头改主配置。
Config_PhpMyAdmin_Access()
{
    local nginx_frag='/usr/local/nginx/conf/phpmyadmin.enable.conf'
    local apache_frag='/usr/local/apache/conf/extra/phpmyadmin.enable.conf'
    # 重建入口时清理停用状态的旧片段，避免启用和停用文件同时存在。
    local nginx_saved='/usr/local/nginx/conf/.phpmyadmin.enable.conf.disabled'
    local apache_saved='/usr/local/apache/conf/extra/.phpmyadmin.enable.conf.disabled'
    local pma_url written=0

    rm -f "${nginx_saved}" "${apache_saved}"

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
            # LNMPA 仅将 phpMyAdmin 路径反向代理到 Apache，避免全站 PHP 规则
            # 使默认站点中的其他 PHP 文件可执行。
            cat >"${nginx_frag}"<<EOF || return 1
    location = /${pma_url} {
        return 301 /${pma_url}/;
    }

    location ^~ /${pma_url}/ {
        proxy_pass http://127.0.0.1:88;
        include proxy.conf;
    }
EOF
        else
            # phpMyAdmin 位于网站根目录外，需单独设置 open_basedir 和 FastCGI；
            # 独立前缀规则不会放开默认站点中的其他 PHP 文件。
            cat >"${nginx_frag}"<<EOF || return 1
    location = /${pma_url} {
        return 301 /${pma_url}/;
    }

    location ^~ /${pma_url}/ {
        alias ${PhpMyAdmin_Dir}/;
        index index.php;

        location ~ ^/${pma_url}/(.+\.php)\$ {
            alias ${PhpMyAdmin_Dir}/\$1;
            fastcgi_pass  unix:/run/php-fpm/php-cgi.sock;
            fastcgi_index index.php;
            include fastcgi.conf;
            fastcgi_param SCRIPT_FILENAME ${PhpMyAdmin_Dir}/\$1;
            fastcgi_param PHP_ADMIN_VALUE "open_basedir=${PhpMyAdmin_Dir}/:/var/lib/phpmyadmin/:/tmp/:/proc/";
        }
    }
EOF
        fi
        chmod 644 "${nginx_frag}" || return 1
        written=$((written+1))
    fi

    if [ -d /usr/local/apache/conf/extra ]; then
        cat >"${apache_frag}"<<EOF || return 1
Alias /${pma_url} "${PhpMyAdmin_Dir}"

<Directory "${PhpMyAdmin_Dir}">
    Options SymLinksIfOwnerMatch
    AllowOverride None
    Require all granted
    php_admin_value open_basedir "${PhpMyAdmin_Dir}/:/var/lib/phpmyadmin/:/tmp/:/proc/"
</Directory>
EOF
        chmod 644 "${apache_frag}" || return 1
        written=$((written+1))
    fi

    # 未找到任何 Web 配置目录时返回失败，避免报告不存在的访问入口。
    if [ "${written}" -eq 0 ]; then
        Echo_Red "未找到 Nginx 或 Apache 的配置目录，phpMyAdmin 访问入口未写入。"
        return 1
    fi
    return 0
}

# 独立安装 phpMyAdmin 时识别现有 LNMP、LNMPA 或 LAMP 环境，以生成正确映射。
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
    # 根据 default_server 的实际位置选择配置文件，兼容新旧安装目录布局。
    local nginx_conf='/usr/local/nginx/conf/nginx.conf'
    if grep -q 'default_server' /usr/local/nginx/conf/vhost/default.conf 2>/dev/null; then
        nginx_conf='/usr/local/nginx/conf/vhost/default.conf'
    fi
    local apache_conf='/usr/local/apache/conf/httpd.conf'
    local tmp

    PMA_Nginx_Main_Backup=''
    PMA_Nginx_Main_Backup_Target="${nginx_conf}"
    PMA_Apache_Main_Backup=''

    if [ "${Stack}" = 'lnmp' ] || [ "${Stack}" = 'lnmpa' ]; then
        if ! grep -q 'include phpmyadmin\.\*\.conf;' "${nginx_conf}"; then
            PMA_Nginx_Main_Backup="${cur_dir}/src/.nginx-pma-backup.$$"
            tmp="${cur_dir}/src/.nginx-pma-new.$$"
            \cp -p "${nginx_conf}" "${PMA_Nginx_Main_Backup}" || return 1
            # 以 default_server 中的 root 指令定位插入点，兼容用户修改过的网站目录。
            if ! awk '
                /^[[:space:]]*server[[:space:]]*\{/ { in_server=1; is_default=0 }
                in_server && /^[[:space:]]*listen[[:space:]].*default_server/ { is_default=1 }
                {
                    print
                    line=$0
                    sub(/^[[:space:]]*/, "", line)
                    sub(/[[:space:]]*;[[:space:]]*$/, "", line)
                    if (is_default && line ~ /^root[[:space:]]/) {
                        print "        include phpmyadmin.*.conf;"
                        inserted=1
                        is_default=0
                    }
                }
                END { if (!inserted) exit 1 }
            ' "${nginx_conf}" > "${tmp}"; then
                Echo_Red "未能在 Nginx 默认站点中定位 phpMyAdmin 配置入口。"
                Echo_Red "需要 ${nginx_conf} 里有一个带 default_server 的 server 块，且块内有 root 指令。"
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
        # 读取 Apache 展开 include 后的公网虚拟主机地址。
        port=$(/usr/local/apache/bin/httpd -t -D DUMP_VHOSTS 2>/dev/null | \
            awk '/^[[:space:]]*\*:[0-9]+[[:space:]]/ {
                value=$1; sub(/^\*:/, "", value); print value; exit
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

Smoke_Test_PhpMyAdmin_HTTP()
{
    local url="$1"
    local output="$2"
    local attempt err last_err=''

    command -v curl >/dev/null 2>&1 || return 1
    # Web 服务重载后短时间内可能仍返回旧结果；重试失败后仅显示最后一次错误。
    for attempt in 1 2 3 4 5; do
        if err=$(curl -fsS --max-time 15 "${url}" -o "${output}" 2>&1) &&
           grep -qi 'phpMyAdmin' "${output}"; then
            return 0
        fi
        [ -n "${err}" ] && last_err="${err}"
        rm -f "${output}"
        [ "${attempt}" -lt 5 ] && sleep 1
    done
    [ -n "${last_err}" ] && printf '%s\n' "${last_err}" >&2
    return 1
}

Rollback_PhpMyAdmin_Install()
{
    rm -f /usr/local/nginx/conf/phpmyadmin.enable.conf \
          /usr/local/apache/conf/extra/phpmyadmin.enable.conf
    if [ -n "${PMA_Nginx_Main_Backup}" ] && [ -s "${PMA_Nginx_Main_Backup}" ]; then
        # 将备份恢复到原配置位置，兼容不同版本的默认站点布局。
        mv -f "${PMA_Nginx_Main_Backup}" "${PMA_Nginx_Main_Backup_Target:-/usr/local/nginx/conf/nginx.conf}"
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
    # 仅在本次创建模板缓存目录时回滚，保留安装前已有内容。
    [ "${PMA_Vardir_Was_Absent:-n}" = 'y' ] && rm -rf /var/lib/phpmyadmin
    Remove_PhpMyAdmin_Dir
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
    local pma_ver pma_stage access_url smoke_body http_port db_port

    Print_Banner "为现有环境安装 phpMyAdmin"

    Detect_PhpMyAdmin_Stack || return 1

    if [ -n "${action}" ]; then
        case "${action}" in enable|disable|status) ;; *)
            Echo_Red "用法：./install.sh phpmyadmin {enable|disable|status}"
            return 1
            ;;
        esac
        if [ ! -x /bin/lnmp-phpmyadmin ]; then
            Echo_Red "未找到 /bin/lnmp-phpmyadmin，请先完成 phpMyAdmin 安装。"
            return 1
        fi
        /bin/lnmp-phpmyadmin "${Stack}" "${action}"
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
    # 补装时读取数据库实际监听端口，避免 lnmp.conf 默认值覆盖安装时的自定义端口。
    db_port=$(Get_Actual_DB_Port) || \
        Echo_Yellow "未能从 /etc/my.cnf 读到数据库端口，按 lnmp.conf 的 ${db_port} 写入。"
    [ "${db_port}" = "${DB_Port}" ] || \
        Echo_Yellow "数据库实际端口为 ${db_port}（lnmp.conf 记的是 ${DB_Port}），按实际端口写入。"
    sed -i "s/LNMP_DB_PORT/${db_port}/g" \
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
    Set_PhpMyAdmin_Dir_Perm "${pma_stage}/${PhpMyAdmin_Ver}" || {
        rm -rf "${pma_stage}"; return 1; }

    if ! mv "${pma_stage}/${PhpMyAdmin_Ver}" "${PhpMyAdmin_Dir}"; then
        Echo_Red "部署 phpMyAdmin 失败，未修改 Web 配置。"
        rm -rf "${pma_stage}"
        return 1
    fi
    rm -rf "${pma_stage}"

    # 独立安装仅在当前流程启用 phpMyAdmin，不改写 lnmp.conf 的默认选择。
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

    Echo_Green "phpMyAdmin ${pma_ver} 安装完成。"
    Echo_Green "访问地址：http://<服务器IP>/${access_url}/"
    return 0
}
