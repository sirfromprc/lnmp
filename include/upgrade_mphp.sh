#!/usr/bin/env bash
#
# 多版本 PHP 升级。2.3 起仅支持 PHP 8.0+。
#
# 原文件 999 行，含 Upgrade_MPHP5.6 / 7.0 / 7.1 / 7.2 / 7.3 / 7.4 / 8.0 / 8.1 / 8.2
# 九个函数（其中 8.x 那几个与通用版 Upgrade_MPHP8x 逐字相同），现全部收敛为
# 单个 Upgrade_MPHP8x。
#
# 同时移除：MPHP_Select 的 12 项硬编码菜单与两处 12 分支派发、
# ${Download_Mirror} 下载、Zend Guard Loader 下载。

Upgrade_Multiplephp()
{
    Get_Dist_Name
    Check_DB
    Check_Stack
    . include/upgrade_php.sh

    if [ "${Get_Stack}" != "lnmp" ]; then
        echo "Multiple PHP Versions ONLY for LNMP Stack!"
        exit 1
    fi

    local i found_any=0
    declare -a MPHP_Found_Branch

    echo "List all multiple php, Please select the PHP version."
    i=1
    while [ ${i} -le ${PHP_Count} ]; do
        Set_PHP_Profile "${i}"
        if [[ -s "${MPHP_Path}/sbin/php-fpm" && -s "/usr/local/nginx/conf/${Enable_PHP_Config}" && -s "/etc/init.d/php-fpm${PHP_Branch}" ]]; then
            Echo_Green "${i}: PHP ${PHP_Branch} [found]"
            MPHP_Found_Branch[${i}]="${PHP_Branch}"
            found_any=1
        fi
        i=$((i+1))
    done

    if [ ${found_any} -eq 0 ]; then
        echo "Multiple php version not found!"
        exit 1
    fi

    while :; do
        MPHP_Select=""
        read -p "Please select which multiple php version to upgrade: " MPHP_Select
        if [ "${MPHP_Select}" = "" ]; then
            Echo_Red "Error: Please input number!"
            continue
        fi
        if ! Set_PHP_Profile "${MPHP_Select}"; then
            Echo_Red "Error: invalid selection."
            continue
        fi
        if [ -z "${MPHP_Found_Branch[${MPHP_Select}]}" ]; then
            Echo_Red "Error: PHP ${PHP_Branch} is not installed."
            continue
        fi
        break
    done

    # 编号已翻译为语义，后续只用 PHP_Branch / MPHP_Path
    Cur_MPHP_Big_Ver="${PHP_Branch}"
    Cur_MPHP_Path="${MPHP_Path}"

    Echo_Yellow "Note: you can't upgrade php cross-version!"

    php_version=""
    Cur_MPHP_Version=$("${Cur_MPHP_Path}/bin/php-config" --version)
    echo "Current PHP Version: ${Cur_MPHP_Version}"
    echo "You can get version number from https://www.php.net/downloads"
    read -p "Please enter a PHP Version you want: " php_version
    if [ "${php_version}" = "" ]; then
        Echo_Red "Error: You must enter a correct php version!!"
        exit 1
    fi

    # 只接受 8.x，且必须与当前大版本一致（不允许跨大版本升级）
    if ! echo "${php_version}" | grep -Eq '^8\.[0-9]+\.[0-9]+$'; then
        Echo_Red "Only PHP 8.x is supported, got: ${php_version}"
        exit 1
    fi
    # 原判断用 grep -Eqi "${Cur_MPHP_Big_Ver}" 做子串匹配，
    # "8.1" 会误匹配 "8.10.x"、"18.1.x" 之类。改为精确前缀比较。
    if [ "$(echo "${php_version}" | cut -d. -f1-2)" != "${Cur_MPHP_Big_Ver}" ]; then
        Echo_Red "Error: You can't upgrade php cross-version!"
        Echo_Red "Current branch is ${Cur_MPHP_Big_Ver}, but you entered ${php_version}"
        exit 1
    fi
    Echo_Blue "You will upgrade php ${Cur_MPHP_Version} to ${php_version}."

    Press_Start
    cd ${cur_dir}/src
    # 只从 php.net 官方获取。
    # 走 Download_Verified 的理由同 upgrade_php.sh。
    if ! Download_Verified php "${php_version}" \
         "https://www.php.net/distributions/php-${php_version}.tar.bz2" \
         "php-${php_version}.tar.bz2"; then
        echo "You enter PHP Version was:"${php_version}
        Echo_Red "Error! PHP ${php_version} 下载或校验失败，请检查版本号。"
        exit 1
    fi

    Check_PHP_Option
    cat /etc/issue
    cat /etc/*-release
    Install_PHP_Dependent
    Check_Openssl

    Upgrade_MPHP8x
}

# Upgrade_MPHP8x — 多版本 PHP 升级的唯一实现
Upgrade_MPHP8x()
{
    cd ${cur_dir}/src
    Install_Libzip
    Echo_Blue "[+] Upgrading php-${php_version}"
    Tar_Cd php-${php_version}.tar.bz2 php-${php_version}
    PHP_Openssl3_Patch
    ./configure --prefix=${Cur_MPHP_Path} --with-config-file-path=${Cur_MPHP_Path}/etc --with-config-file-scan-dir=${Cur_MPHP_Path}/conf.d --enable-fpm --with-fpm-user=www --with-fpm-group=www --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --with-iconv=/usr/local --with-freetype=/usr/local/freetype --with-jpeg --with-zlib --enable-xml --disable-rpath --enable-bcmath --enable-shmop --enable-sysvsem ${with_curl} --enable-mbregex --enable-mbstring --enable-intl --enable-pcntl --enable-ftp --enable-gd ${with_openssl} --with-mhash --enable-pcntl --enable-sockets --with-zip --enable-soap --with-gettext ${with_fileinfo} --enable-opcache --with-xsl --with-pear --with-webp ${PHP_Buildin_Option} ${PHP_Modules_Options}
    if [ $? -ne 0 ]; then
        Echo_Red "PHP ${php_version} 的 configure 失败。**现有的多版本 PHP 未做任何改动。**"
        exit 1
    fi

    # 装到暂存目录，构建期间线上完全不受影响
    MPHP_Stage="${cur_dir}/src/.mphp-stage.$$"
    MPHP_Backup="/usr/local/mphp-${Cur_MPHP_Big_Ver}-backup${Upgrade_Date}"
    rm -rf "${MPHP_Stage}"
    mkdir -p "${MPHP_Stage}" || exit 1

    make ZEND_EXTRA_LIBS='-liconv' -j `grep 'processor' /proc/cpuinfo | wc -l`
    if [ $? -ne 0 ]; then
        Echo_Yellow "并行编译失败，退回串行重试..."
        if ! make ZEND_EXTRA_LIBS='-liconv'; then
            Echo_Red "PHP ${php_version} 编译失败。**现有的多版本 PHP 未做任何改动。**"
            rm -rf "${MPHP_Stage}"
            exit 1
        fi
    fi
    if ! make install INSTALL_ROOT="${MPHP_Stage}"; then
        Echo_Red "安装到暂存目录失败。**现有的多版本 PHP 未做任何改动。**"
        rm -rf "${MPHP_Stage}"
        exit 1
    fi

    Staged_PHP="${MPHP_Stage}${Cur_MPHP_Path}"
    Smoke_Out=$("${Staged_PHP}/bin/php" -v 2>&1 | head -n1)
    if ! echo "${Smoke_Out}" | grep -q "PHP ${php_version}"; then
        Echo_Red "新构建的 PHP 冒烟测试未通过：期望 ${php_version}，实际 '${Smoke_Out}'"
        Echo_Red "**现有的多版本 PHP 未做任何改动。**"
        rm -rf "${MPHP_Stage}"
        exit 1
    fi
    Echo_Green "新 PHP 冒烟测试通过：${Smoke_Out}"

    # 到这里才停服务并切换
    Rollback_MPHP()
    {
        Echo_Red "正在恢复升级前的 PHP ${Cur_MPHP_Big_Ver}..."
        rm -rf "${Cur_MPHP_Path}"
        [ -d "${MPHP_Backup}" ] && mv "${MPHP_Backup}" "${Cur_MPHP_Path}"
        if [ -s "${Cur_MPHP_Path}/init.d.php-fpm.bak.${Upgrade_Date}" ]; then
            \cp "${Cur_MPHP_Path}/init.d.php-fpm.bak.${Upgrade_Date}" /etc/init.d/php-fpm${Cur_MPHP_Big_Ver}
            chmod +x /etc/init.d/php-fpm${Cur_MPHP_Big_Ver}
        fi
        lnmp start
        Echo_Red "已恢复。请检查站点是否正常。"
    }

    lnmp stop
    Echo_Blue "Backup old multiple php version..."
    if ! mv "${Cur_MPHP_Path}" "${MPHP_Backup}"; then
        Echo_Red "备份原 ${Cur_MPHP_Path} 失败，放弃升级。"
        lnmp start
        rm -rf "${MPHP_Stage}"
        exit 1
    fi
    mv /etc/init.d/php-fpm${Cur_MPHP_Big_Ver} "${MPHP_Backup}/init.d.php-fpm.bak.${Upgrade_Date}"
    if ! mv "${Staged_PHP}" "${Cur_MPHP_Path}"; then
        Echo_Red "部署新 PHP 失败。"
        Rollback_MPHP
        rm -rf "${MPHP_Stage}"
        exit 1
    fi
    rm -rf "${MPHP_Stage}"

    echo "Copy new php configure file..."
    mkdir -p ${Cur_MPHP_Path}/{etc,conf.d}
    \cp php.ini-production ${Cur_MPHP_Path}/etc/php.ini

    # php extensions
    echo "Modify php.ini......"
    sed -i 's/post_max_size =.*/post_max_size = 50M/g' ${Cur_MPHP_Path}/etc/php.ini
    sed -i 's/upload_max_filesize =.*/upload_max_filesize = 50M/g' ${Cur_MPHP_Path}/etc/php.ini
    sed -i 's/;date.timezone =.*/date.timezone = PRC/g' ${Cur_MPHP_Path}/etc/php.ini
    sed -i 's/short_open_tag =.*/short_open_tag = On/g' ${Cur_MPHP_Path}/etc/php.ini
    sed -i 's/;cgi.fix_pathinfo=.*/cgi.fix_pathinfo=0/g' ${Cur_MPHP_Path}/etc/php.ini
    # 关闭 X-Powered-By 响应头，避免对外暴露 PHP 版本号。
    sed -i 's/^expose_php =.*/expose_php = Off/g' ${Cur_MPHP_Path}/etc/php.ini
    sed -i 's/max_execution_time =.*/max_execution_time = 300/g' ${Cur_MPHP_Path}/etc/php.ini
    sed -i 's/disable_functions =.*/disable_functions = passthru,exec,system,chroot,chgrp,chown,shell_exec,proc_open,proc_get_status,popen,ini_alter,ini_restore,dl,openlog,syslog,readlink,symlink,popepassthru,stream_socket_server/g' ${Cur_MPHP_Path}/etc/php.ini

    cd ${cur_dir}/src

    echo "Creating new php-fpm configure file..."
    cat >${Cur_MPHP_Path}/etc/php-fpm.conf<<EOF
[global]
pid = ${Cur_MPHP_Path}/var/run/php-fpm.pid
error_log = ${Cur_MPHP_Path}/var/log/php-fpm.log
log_level = notice

[www]
listen = /tmp/php-cgi${Cur_MPHP_Big_Ver}.sock
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
request_terminate_timeout = 100
request_slowlog_timeout = 0
slowlog = var/log/slow.log
EOF

    echo "Copy php-fpm init.d file..."
    \cp ${cur_dir}/src/php-${php_version}/sapi/fpm/init.d.php-fpm /etc/init.d/php-fpm${Cur_MPHP_Big_Ver}
    chmod +x /etc/init.d/php-fpm${Cur_MPHP_Big_Ver}
    sed -i "s@# Provides:          php-fpm@# Provides:          php-fpm${Cur_MPHP_Big_Ver}@g" /etc/init.d/php-fpm${Cur_MPHP_Big_Ver}

    StartUp php-fpm${Cur_MPHP_Big_Ver}

    \cp ${cur_dir}/conf/enable-php${Cur_MPHP_Big_Ver}.conf /usr/local/nginx/conf/enable-php${Cur_MPHP_Big_Ver}.conf

    sleep 2

    lnmp start

    rm -rf ${cur_dir}/src/php-${php_version}

    if [ ! -s ${Cur_MPHP_Path}/sbin/php-fpm ] || [ ! -s ${Cur_MPHP_Path}/etc/php.ini ] || [ ! -s ${Cur_MPHP_Path}/bin/php ]; then
        Echo_Red "Failed to upgrade php-${php_version}, see /root/upgrade_mphp${Upgrade_Date}.log for details."
        Rollback_MPHP
        return 1
    fi
    Run_Ver=$(${Cur_MPHP_Path}/bin/php -v 2>&1 | head -n1)
    if ! echo "${Run_Ver}" | grep -q "PHP ${php_version}"; then
        Echo_Red "升级后运行的版本不符：期望 ${php_version}，实际 '${Run_Ver}'"
        Rollback_MPHP
        return 1
    fi
    echo "==========================================="
    Echo_Green "You have successfully upgrade to php-${php_version} "
    Echo_Green "旧版本保留在 ${MPHP_Backup}，确认无误后可自行删除。"
    echo "==========================================="
    return 0
}
