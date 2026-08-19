#!/usr/bin/env bash
# 多版本 PHP 升级。2.3 起仅支持 PHP 8.0+。
# 已安装版本由统一映射表识别，升级仅允许在相同 PHP 8.x 分支内进行。

Upgrade_Multiplephp()
{
    Get_Dist_Name
    Check_DB
    Check_Stack
    . include/upgrade_php.sh

    if [ "${Get_Stack}" != "lnmp" ]; then
        echo "多版本 PHP 仅支持 LNMP 架构！"
        exit 1
    fi

    local i found_any=0
    declare -a MPHP_Found_Branch

    echo "以下为已安装的多版本 PHP，请选择要升级的版本。"
    i=1
    while [ ${i} -le ${PHP_Count} ]; do
        Set_PHP_Profile "${i}"
        if [[ -s "${MPHP_Path}/sbin/php-fpm" && -s "/usr/local/nginx/conf/${Enable_PHP_Config}" && -s "/etc/init.d/php-fpm${PHP_Branch}" ]]; then
            Echo_Green "${i}：PHP ${PHP_Branch} [已找到]"
            MPHP_Found_Branch[${i}]="${PHP_Branch}"
            found_any=1
        fi
        i=$((i+1))
    done

    if [ ${found_any} -eq 0 ]; then
        echo "未找到多版本 PHP！"
        exit 1
    fi

    while :; do
        MPHP_Select=""
        read -p "请选择要升级的多版本 PHP 序号：" MPHP_Select
        if [ "${MPHP_Select}" = "" ]; then
            Echo_Red "错误：请输入数字！"
            continue
        fi
        if ! Set_PHP_Profile "${MPHP_Select}"; then
            Echo_Red "错误：选择无效。"
            continue
        fi
        if [ -z "${MPHP_Found_Branch[${MPHP_Select}]}" ]; then
            Echo_Red "错误：PHP ${PHP_Branch} 尚未安装。"
            continue
        fi
        break
    done

    # 后续步骤使用所选分支及对应安装路径。
    Cur_MPHP_Big_Ver="${PHP_Branch}"
    Cur_MPHP_Path="${MPHP_Path}"

    Echo_Yellow "注意：不能跨 PHP 分支升级！"

    php_version=""
    Cur_MPHP_Version=$("${Cur_MPHP_Path}/bin/php-config" --version)
    echo "当前 PHP 版本：${Cur_MPHP_Version}"
    echo "可在 https://www.php.net/downloads 查看可用版本号。"
    read -p "请输入目标 PHP 版本：" php_version
    if [ "${php_version}" = "" ]; then
        Echo_Red "错误：必须输入正确的 PHP 版本号！"
        exit 1
    fi
    Check_Version_String "${php_version}" "PHP 版本号" || exit 1

    # 仅接受与当前主次版本一致的 PHP 8.x 完整版本号。
    if ! echo "${php_version}" | grep -Eq '^8\.[0-9]+\.[0-9]+$'; then
        Echo_Red "仅支持 PHP 8.x，输入值：${php_version}"
        exit 1
    fi
    # 精确比较主次版本，避免相似字符串被识别为同一分支。
    if [ "$(echo "${php_version}" | cut -d. -f1-2)" != "${Cur_MPHP_Big_Ver}" ]; then
        Echo_Red "错误：不能跨 PHP 分支升级！"
        Echo_Red "当前分支为 ${Cur_MPHP_Big_Ver}，输入的目标版本为 ${php_version}"
        exit 1
    fi
    Echo_Blue "即将把 PHP ${Cur_MPHP_Version} 升级到 ${php_version}。"

    Press_Start
    cd ${cur_dir}/src
    # 从 php.net 官方下载并验证源码包。
    if ! Download_Verified php "${php_version}" \
         "https://www.php.net/distributions/php-${php_version}.tar.bz2" \
         "php-${php_version}.tar.bz2"; then
        echo "输入的 PHP 版本为：${php_version}"
        Echo_Red "错误！PHP ${php_version} 下载或校验失败，请检查版本号。"
        exit 1
    fi

    Check_PHP_Option
    cat /etc/issue
    cat /etc/*-release
    Install_PHP_Dependent
    Check_Openssl

    Upgrade_MPHP8x
}

# 多版本 PHP 8.x 的统一升级流程。
Upgrade_MPHP8x()
{
    cd ${cur_dir}/src
    Install_Libzip
    Echo_Blue "[+] 正在升级 PHP ${php_version}"
    Tar_Cd php-${php_version}.tar.bz2 php-${php_version}
    PHP_Openssl3_Patch
    # configure 的 iconv 探针要能加载 /usr/local/lib 里的 libiconv.so.2。
    Ensure_Libiconv_Ldpath || exit 1
    ./configure --prefix=${Cur_MPHP_Path} --with-config-file-path=${Cur_MPHP_Path}/etc --with-config-file-scan-dir=${Cur_MPHP_Path}/conf.d --enable-fpm --with-fpm-user=www --with-fpm-group=www --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --with-iconv=/usr/local --with-freetype=/usr/local/freetype --with-jpeg --with-zlib --enable-xml --disable-rpath --enable-bcmath --enable-shmop --enable-sysvsem ${with_curl} --enable-mbregex --enable-mbstring --enable-intl --enable-pcntl --enable-ftp --enable-gd ${with_openssl} --with-mhash --enable-pcntl --enable-sockets --with-zip --enable-soap --with-gettext ${with_fileinfo} --enable-opcache --with-xsl --with-pear --with-webp ${PHP_Buildin_Option} ${PHP_Modules_Options}
    if [ $? -ne 0 ]; then
        Echo_Red "PHP ${php_version} 的 configure 失败。**现有的多版本 PHP 未做任何改动。**"
        exit 1
    fi

    # 先安装到暂存目录，构建期间不替换正在运行的版本。
    MPHP_Stage="${cur_dir}/src/.mphp-stage.$$"
    MPHP_Backup="/usr/local/mphp-${Cur_MPHP_Big_Ver}-backup${Upgrade_Date}"
    rm -rf "${MPHP_Stage}"
    mkdir -p "${MPHP_Stage}" || exit 1

    make ZEND_EXTRA_LIBS='-liconv' -j"$(Build_Jobs)"
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

    # 新版本冒烟检查通过后再停服切换。
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
    Echo_Blue "正在备份旧的多版本 PHP..."
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

    echo "正在复制新的 PHP 配置文件..."
    mkdir -p ${Cur_MPHP_Path}/{etc,conf.d}
    \cp php.ini-production ${Cur_MPHP_Path}/etc/php.ini

    # 配置 PHP 扩展及运行参数。
    echo "正在修改 php.ini..."
    PHP_Ini_Tune "${Cur_MPHP_Path}/etc/php.ini" || exit 1

    cd ${cur_dir}/src

    echo "正在创建新的 php-fpm 配置文件..."
    cat >${Cur_MPHP_Path}/etc/php-fpm.conf<<EOF
[global]
pid = ${Cur_MPHP_Path}/var/run/php-fpm.pid
error_log = ${Cur_MPHP_Path}/var/log/php-fpm.log
log_level = notice

[www]
listen = /run/php-fpm/php-cgi${Cur_MPHP_Big_Ver}.sock
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

    echo "正在复制 php-fpm init.d 服务脚本..."
    \cp ${cur_dir}/src/php-${php_version}/sapi/fpm/init.d.php-fpm /etc/init.d/php-fpm${Cur_MPHP_Big_Ver}
    chmod +x /etc/init.d/php-fpm${Cur_MPHP_Big_Ver}
    sed -i "s@# Provides:          php-fpm@# Provides:          php-fpm${Cur_MPHP_Big_Ver}@g" /etc/init.d/php-fpm${Cur_MPHP_Big_Ver}
    Ensure_Runtime_Directory /run/php-fpm root root || exit 1
    Patch_Init_Runtime_Directory /etc/init.d/php-fpm${Cur_MPHP_Big_Ver} /run/php-fpm root root || exit 1

    StartUp php-fpm${Cur_MPHP_Big_Ver}

    \cp ${cur_dir}/conf/enable-php${Cur_MPHP_Big_Ver}.conf /usr/local/nginx/conf/enable-php${Cur_MPHP_Big_Ver}.conf

    sleep 2

    lnmp start

    rm -rf ${cur_dir}/src/php-${php_version}

    if [ ! -s ${Cur_MPHP_Path}/sbin/php-fpm ] || [ ! -s ${Cur_MPHP_Path}/etc/php.ini ] || [ ! -s ${Cur_MPHP_Path}/bin/php ]; then
        Echo_Red "PHP ${php_version} 升级失败，详情请查看 /root/upgrade_mphp${Upgrade_Date}.log。"
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
    Echo_Green "已成功升级到 PHP ${php_version}。"
    Echo_Green "旧版本保留在 ${MPHP_Backup}，确认无误后可自行删除。"
    echo "==========================================="
    return 0
}
