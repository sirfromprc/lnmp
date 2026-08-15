#!/usr/bin/env bash
#
# PHP 升级。2.3 起仅支持升级到 PHP 8.0+。
#
# 原文件 1225 行，含 Upgrade_PHP_52 / _53 / _54 / _556 / _7 / _72 / _73 / _74
# 八个已停止支持分支的升级函数（合计 678 行），以及 Upgrade_PHP_80..83 四份
# 几乎逐字相同的副本。现全部收敛为单个 Upgrade_PHP_8x。
#
# 同时移除：
#   - Zend Guard Loader / ZendOptimizer 下载（闭源二进制，仅 PHP 5.x 可用，
#     且下载地址走站长镜像 ${Download_Mirror}/web/zend/...）
#   - src/patch/php-5.* 系列补丁调用
#   - libphp5.so / libphp7.so 分支（PHP 8 统一为 libphp.so）
#   - Install_PHP_Dependent 中 country=CN 的 EPEL 镜像改写

Check_Stack_Choose()
{
    Check_Stack
    if [[ "${Get_Stack}" = "lnmp" && "${Stack}" = "" ]]; then
        echo "当前架构：${Get_Stack}，请执行：./upgrade.sh php"
        exit 1
    elif [[ "${Get_Stack}" = "lnmpa" || "${Get_Stack}" = "lamp" ]] && [[ "${Stack}" = "lnmp" ]]; then
        echo "当前架构：${Get_Stack}，请执行：./upgrade.sh phpa"
        exit 1
    fi
}

Start_Upgrade_PHP()
{
    Check_Stack_Choose
    Check_DB
    php_version=""
    Get_PHP_Ext_Dir
    echo "当前 PHP 版本：${Cur_PHP_Version}"
    echo "可在 https://www.php.net/downloads 查看可用版本号。"
    read -p "请输入目标 PHP 版本：" php_version
    if [ "${php_version}" = "" ]; then
        echo "错误：必须输入正确的 PHP 版本号！"
        exit 1
    fi

    if ! echo "${php_version}" | grep -Eq '^8\.[0-9]+\.[0-9]+$'; then
        Echo_Red "仅支持 PHP 8.0.0 及以上版本，输入值：${php_version}"
        Echo_Red "支持范围：8.0.x、8.1.x、8.2.x、8.3.x、8.4.x、8.5.x"
        exit 1
    fi
    if ! Version_GE "${php_version}" 8.0; then
        Echo_Red "PHP ${php_version} 已停止生命周期支持，本项目不再支持。"
        exit 1
    fi

    Press_Start
    cd ${cur_dir}/src

    if ! Download_Verified php "${php_version}" \
         "https://www.php.net/distributions/php-${php_version}.tar.bz2" \
         "php-${php_version}.tar.bz2"; then
        echo "输入的 PHP 版本为：${php_version}"
        Echo_Red "错误！PHP ${php_version} 下载或校验失败，请检查版本号。"
        exit 1
    fi

    Check_PHP_Option
    Install_PHP_Dependent
    Check_Openssl
}

# ---------------------------------------------------------------------------
# 升级 PHP 的事务辅助：切换、回滚、冒烟测试
#
# 顺序：构建 → 装到暂存目录 → 冒烟测试 → 停服务 → 原子切换 → 起服务 → 复检
# 任何一步失败都把旧目录、init 脚本、Apache 模块与配置换回去并重启服务。
# ---------------------------------------------------------------------------
PHP_Old_Dir=""

Rollback_PHP()
{
    Echo_Red "正在回滚到升级前的 PHP..."
    [ -d /usr/local/php ] && rm -rf /usr/local/php
    if [ -n "${PHP_Old_Dir}" ] && [ -d "${PHP_Old_Dir}" ]; then
        mv "${PHP_Old_Dir}" /usr/local/php
    fi
    if [ "${Stack}" = "lnmp" ]; then
        if [ -s "/usr/local/php/init.d.php-fpm.bak.${Upgrade_Date}" ]; then
            \cp "/usr/local/php/init.d.php-fpm.bak.${Upgrade_Date}" /etc/init.d/php-fpm
            chmod +x /etc/init.d/php-fpm
        fi
    else
        [ -s "/usr/local/apache/modules/libphp.so.bak.${Upgrade_Date}" ] && \
            \cp "/usr/local/apache/modules/libphp.so.bak.${Upgrade_Date}" /usr/local/apache/modules/libphp.so
        [ -s "/usr/local/apache/conf/httpd.conf.bak.${Upgrade_Date}" ] && \
            \cp "/usr/local/apache/conf/httpd.conf.bak.${Upgrade_Date}" /usr/local/apache/conf/httpd.conf
    fi
    Ln_PHP_Bin
    lnmp start
    Echo_Red "已恢复升级前的 PHP。请检查站点是否正常。"
}

# 用暂存目录里的新 PHP 做冒烟测试：能不能跑、版本对不对
Smoke_Test_PHP()
{
    local root="$1" out
    if [ ! -x "${root}/usr/local/php/bin/php" ]; then
        Echo_Red "暂存目录里没有可执行的 php：${root}/usr/local/php/bin/php"
        return 1
    fi
    out=$("${root}/usr/local/php/bin/php" -v 2>&1 | head -n1)
    if ! echo "${out}" | grep -q "PHP ${php_version}"; then
        Echo_Red "新构建的 PHP 版本不符：期望 ${php_version}，实际 '${out}'"
        return 1
    fi
    Echo_Green "新 PHP 冒烟测试通过：${out}"
    return 0
}

# 停服务 → 备份旧目录 → 把暂存目录搬到 /usr/local/php
Switch_To_New_PHP()
{
    local stage="$1"
    PHP_Old_Dir="/usr/local/oldphp${Upgrade_Date}"

    echo "冒烟测试通过，开始切换（此时才停服务）..."
    lnmp stop

    if [ "${Stack}" = "lnmp" ]; then
        mv /usr/local/php "${PHP_Old_Dir}" || return 1
        mv /etc/init.d/php-fpm "${PHP_Old_Dir}/init.d.php-fpm.bak.${Upgrade_Date}"
    else
        # PHP 8 的 Apache 模块统一为 libphp.so；原 libphp5.so / libphp7.so
        # 备份分支与「7.x 降级到 5.x 时删 LoadModule」的处理已随旧分支删除。
        [ -s /usr/local/apache/modules/libphp.so ] && \
            \cp /usr/local/apache/modules/libphp.so /usr/local/apache/modules/libphp.so.bak.${Upgrade_Date}
        mv /usr/local/php "${PHP_Old_Dir}" || return 1
        \cp /usr/local/apache/conf/httpd.conf /usr/local/apache/conf/httpd.conf.bak.${Upgrade_Date}
    fi

    if ! mv "${stage}/usr/local/php" /usr/local/php; then
        Echo_Red "把新 PHP 搬到 /usr/local/php 失败。"
        return 1
    fi
    rm -rf "${stage}"
    return 0
}
Install_PHP_Dependent()
{
    echo "正在安装 PHP 依赖包..."
    if [ "$PM" = "yum" ]; then
        if [ "${DISTRO}" = "Oracle" ]; then
            yum -y install oracle-epel-release
        else
            yum -y install epel-release
        fi
        for packages in make gcc gcc-c++ gcc-g77 libjpeg libjpeg-devel libjpeg-turbo-devel libpng libpng-devel libpng10 libpng10-devel gd gd-devel libxml2 libxml2-devel zlib zlib-devel glib2-devel bzip2-devel libzip-devel libevent libevent-devel ncurses ncurses-devel curl-devel libcurl libcurl-devel e2fsprogs-devel krb5 krb5-devel libidn libidn-devel openssl-devel gettext-devel ncurses-devel gmp-devel pspell-devel libc-client-devel libXpm-devel libtirpc-devel cyrus-sasl-devel c-ares-devel libicu-devel libxslt libxslt-devel xz expat-devel libzip-devel bzip2 bzip2-devel sqlite-devel oniguruma-devel libwebp-devel;
        do yum -y install $packages; done
    elif [ "$PM" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        for packages in debian-keyring debian-archive-keyring build-essential gcc g++ make libzip-dev libc6-dev libbz2-dev libncurses5 libncurses5-dev libevent-dev libssl-dev libsasl2-dev libltdl3-dev libltdl-dev zlib1g zlib1g-dev libbz2-1.0 libbz2-dev libglib2.0-0 libglib2.0-dev libpng3 libjpeg-dev libpng-dev libpng12-0 libpng12-dev libkrb5-dev curl libcurl3-gnutls libcurl4-gnutls-dev libcurl4-openssl-dev libpq-dev libpq5 libpng12-dev libxml2-dev libcap-dev libc-client2007e-dev libaio-dev libtirpc-dev libc-ares-dev libicu-dev e2fsprogs libxslt1.1 libxslt1-dev libc-client-dev xz-utils libexpat1-dev bzip2 libbz2-dev libsqlite3-dev libonig-dev libwebp-dev;
        do apt-get --no-install-recommends install -y $packages; done
    fi

    if echo "${CentOS_Version}" | grep -Eqi "^8" || echo "${RHEL_Version}" | grep -Eqi "^8" || echo "${Rocky_Version}" | grep -Eqi "^8" || echo "${Alma_Version}" | grep -Eqi "^8" || echo "${Anolis_Version}" | grep -Eqi "^8" || echo "${OpenCloudOS_Version}" | grep -Eqi "^8"; then
        Check_PowerTools
        if [ "${repo_id}" != "" ]; then
            echo "正在安装 PowerTools 仓库中的依赖包..."
            for c8packages in rpcgen re2c oniguruma-devel;
            do dnf --enablerepo=${repo_id} install ${c8packages} -y; done
        fi
        dnf install libarchive -y
    fi

    if echo "${CentOS_Version}" | grep -Eqi "^9" || echo "${Alma_Version}" | grep -Eqi "^9" || echo "${Rocky_Version}" | grep -Eqi "^9"; then
        for cs9packages in oniguruma-devel libzip-devel libtirpc-devel;
        do dnf --enablerepo=crb install ${cs9packages} -y; done
    fi

    if [ "${DISTRO}" = "Oracle" ] && echo "${Oracle_Version}" | grep -Eqi "^8"; then
        Check_Codeready
        for o8packages in rpcgen re2c oniguruma-devel;
        do dnf --enablerepo=${repo_id} install ${o8packages} -y; done
        dnf install libarchive -y
    fi

    if echo "${CentOS_Version}" | grep -Eqi "^7" || echo "${RHEL_Version}" | grep -Eqi "^7"  || echo "${Aliyun_Version}" | grep -Eqi "^2" || echo "${Alibaba_Version}" | grep -Eqi "^2" || echo "${Oracle_Version}" | grep -Eqi "^7" || echo "${Anolis_Version}" | grep -Eqi "^7"; then
        # 原此处在 country=CN 时把 EPEL 的 metalink 改写为 mirrors.ustc.edu.cn，
        # 地理探测移除后一并删除，统一用官方 EPEL。
        if [ "${DISTRO}" = "Oracle" ]; then
            yum -y install oracle-epel-release
        else
            yum -y install epel-release
        fi
        yum -y install oniguruma oniguruma-devel
        yum -y install libsodium-devel
        yum -y install libc-client-devel uw-imap-devel
    fi

    if [ "${DISTRO}" = "UOS" ]; then
        Check_PowerTools
        if [ "${repo_id}" != "" ]; then
            echo "正在安装 PowerTools 仓库中的依赖包..."
            for uospackages in rpcgen re2c oniguruma-devel;
            do dnf --enablerepo=${repo_id} install ${uospackages} -y; done
        fi
    fi

    if [ -d /usr/include/x86_64-linux-gnu/curl ]; then
        ln -sf /usr/include/x86_64-linux-gnu/curl /usr/include/
    elif [ -d /usr/include/i386-linux-gnu/curl ]; then
        ln -sf /usr/include/i386-linux-gnu/curl /usr/include/
    fi

    if [ -d /usr/include/arm-linux-gnueabihf/curl ]; then
        ln -sf /usr/include/arm-linux-gnueabihf/curl /usr/include/
    fi

    ldconfig
}
Check_PHP_Upgrade_Files()
{
    Echo_LNMPA_Upgrade_PHP_Failed()
    {
        Echo_Red "======== PHP 升级失败 ======"
        Echo_Red "PHP 升级日志：/root/upgrade_a_php${Upgrade_Date}.log"
    }
    rm -rf ${cur_dir}/src/php-${php_version}

    if [ "${Stack}" = "lnmp" ]; then
        if [[ ! -s /usr/local/php/sbin/php-fpm || ! -s /etc/init.d/php-fpm || ! -s /usr/local/php/etc/php.ini || ! -s /usr/local/php/bin/php ]]; then
            Echo_Red "======== PHP 升级失败 ======"
            Echo_Red "PHP 升级日志：/root/upgrade_lnmp_php${Upgrade_Date}.log"
            return 1
        fi
    else

        if [[ ! -s /usr/local/apache/bin/httpd || ! -s /usr/local/apache/modules/libphp.so || ! -s /usr/local/apache/conf/httpd.conf ]]; then
            Echo_LNMPA_Upgrade_PHP_Failed
            return 1
        fi
    fi

    # 文件在只是最低标准，还要确认跑起来的确实是目标版本
    local run_ver
    run_ver=$(/usr/local/php/bin/php -v 2>&1 | head -n1)
    if ! echo "${run_ver}" | grep -q "PHP ${php_version}"; then
        Echo_Red "升级后运行的 PHP 版本不符：期望 ${php_version}，实际 '${run_ver}'"
        return 1
    fi
    if [ "${Stack}" = "lnmp" ] && ! pgrep -f 'php-fpm: master' >/dev/null 2>&1; then
        Echo_Red "php-fpm master 进程未启动。"
        return 1
    fi

    Echo_Green "======== PHP 升级完成 ======"
    Echo_Green "${run_ver}"
    return 0
}

# Upgrade_PHP_8x — PHP 8.x 升级的唯一实现
#
# 原 Upgrade_PHP_80 / _81 / _82 / _83 是四份逐字相同的副本
# （_84 / _85 已是调用 _83 的壳），差异只有 8.0 需要的 openssl3 补丁。
Upgrade_PHP_8x()
{
    Install_Libzip
    Echo_Blue "[+] 正在安装 PHP ${php_version}"
    Tar_Cd php-${php_version}.tar.bz2 php-${php_version}
    PHP_Openssl3_Patch

    if [ "${Stack}" = "lnmp" ]; then
        ./configure --prefix=/usr/local/php --with-config-file-path=/usr/local/php/etc --with-config-file-scan-dir=/usr/local/php/conf.d --enable-fpm --with-fpm-user=www --with-fpm-group=www --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --with-iconv=/usr/local --with-freetype=/usr/local/freetype --with-jpeg --with-zlib --enable-xml --disable-rpath --enable-bcmath --enable-shmop --enable-sysvsem ${with_curl} --enable-mbregex --enable-mbstring --enable-intl --enable-pcntl --enable-ftp --enable-gd ${with_openssl} --with-mhash --enable-pcntl --enable-sockets --with-zip --enable-soap --with-gettext ${with_fileinfo} --enable-opcache --with-xsl --with-pear --with-webp ${PHP_Buildin_Option} ${PHP_Modules_Options}
    else
        ./configure --prefix=/usr/local/php --with-config-file-path=/usr/local/php/etc --with-config-file-scan-dir=/usr/local/php/conf.d --with-apxs2=/usr/local/apache/bin/apxs --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --with-iconv=/usr/local --with-freetype=/usr/local/freetype --with-jpeg --with-zlib --enable-xml --disable-rpath --enable-bcmath --enable-shmop --enable-sysvsem ${with_curl} --enable-mbregex --enable-mbstring --enable-intl --enable-pcntl --enable-ftp --enable-gd ${with_openssl} --with-mhash --enable-pcntl --enable-sockets --with-zip --enable-soap --with-gettext ${with_fileinfo} --enable-opcache --with-xsl --with-pear --with-webp ${PHP_Buildin_Option} ${PHP_Modules_Options}
    fi

    if [ $? -ne 0 ]; then
        Echo_Red "PHP ${php_version} 的 configure 失败。**线上 PHP 未做任何改动。**"
        exit 1
    fi

    # 装到暂存目录而不是直接覆盖 /usr/local/php。
    # PHP 的 make install 支持 INSTALL_ROOT（等价于 DESTDIR），
    # 产出落在 ${PHP_Stage}/usr/local/php，路径前缀仍是编译时定的 /usr/local/php。
    PHP_Stage="${cur_dir}/src/.php-stage.$$"
    rm -rf "${PHP_Stage}"
    mkdir -p "${PHP_Stage}" || exit 1

    make ZEND_EXTRA_LIBS='-liconv' -j"$(Build_Jobs)"
    if [ $? -ne 0 ]; then
        Echo_Yellow "并行编译失败，退回串行重试..."
        if ! make ZEND_EXTRA_LIBS='-liconv'; then
            Echo_Red "PHP ${php_version} 编译失败。**线上 PHP 未做任何改动。**"
            rm -rf "${PHP_Stage}"
            exit 1
        fi
    fi
    if ! make install INSTALL_ROOT="${PHP_Stage}"; then
        Echo_Red "PHP ${php_version} 安装到暂存目录失败。**线上 PHP 未做任何改动。**"
        rm -rf "${PHP_Stage}"
        exit 1
    fi

    if ! Smoke_Test_PHP "${PHP_Stage}"; then
        Echo_Red "**线上 PHP 未做任何改动。**"
        rm -rf "${PHP_Stage}"
        exit 1
    fi

    # 到这里才停服务并切换；失败自动回滚
    if ! Switch_To_New_PHP "${PHP_Stage}"; then
        Rollback_PHP
        rm -rf "${PHP_Stage}"
        exit 1
    fi

    Ln_PHP_Bin

    echo "正在复制新的 PHP 配置文件..."
    mkdir -p /usr/local/php/{etc,conf.d}
    \cp php.ini-production /usr/local/php/etc/php.ini

    # php extensions
    echo "正在修改 php.ini..."
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
    echo "正在创建新的 php-fpm 配置文件..."
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

    echo "正在复制 php-fpm init.d 服务脚本..."
    \cp ${cur_dir}/src/php-${php_version}/sapi/fpm/init.d.php-fpm /etc/init.d/php-fpm
    chmod +x /etc/init.d/php-fpm
    LNMP_PHP_Opt
fi
    if [ "${Stack}" != "lnmp" ]; then
        # 清理旧模块的 LoadModule 行（从 PHP 5/7 升上来的遗留）
        sed -i '/^LoadModule php5_module/d' /usr/local/apache/conf/httpd.conf
        sed -i '/^LoadModule php7_module/d' /usr/local/apache/conf/httpd.conf
    fi
    lnmp start

    if ! Check_PHP_Upgrade_Files; then
        Echo_Red "升级后的自检未通过。"
        Rollback_PHP
        return 1
    fi
    Echo_Green "旧版本保留在 ${PHP_Old_Dir}，确认无误后可自行删除。"
    return 0
}

Upgrade_PHP()
{
    Start_Upgrade_PHP
    # 版本白名单已在 Start_Upgrade_PHP 中校验，此处直接走统一实现
    Upgrade_PHP_8x
}
