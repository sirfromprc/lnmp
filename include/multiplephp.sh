#!/usr/bin/env bash

Install_Multiplephp()
{
    Get_Dist_Name
    Check_DB
    Check_Stack
    Get_Dist_Version
    . include/upgrade_php.sh

    if [ "${Get_Stack}" != "lnmp" ]; then
        echo "多版本 PHP 仅支持 LNMP 架构！"
        exit 1
    fi

    # 选择需要并行安装的 PHP 版本。
    echo "==========================="

    PHPSelect=""
    Print_PHP_Menu
    read -p "请选择 [1-${PHP_Count}]：" PHPSelect

    if ! Set_PHP_Profile "${PHPSelect}"; then
        echo "未输入选项，必须选择一个 PHP 版本。"
        exit 1
    fi
    echo "即将安装 ${PHP_Info[$((PHPSelect-1))]}"

    Press_Install
    if [ -d "${MPHP_Path}" ]; then
        echo "${Php_Ver} 已存在！"
        exit 1
    fi
    Check_PHP_Option
    cat /etc/issue
    cat /etc/*-release
    Install_PHP_Dependent
    Check_Openssl

    MPHP_Short_Ver="${PHP_Branch}"
    # 返回安装命令的退出码，避免 tee 成功掩盖安装失败。
    Install_MPHP8x 2>&1 | tee /root/install-mphp${PHP_Branch}.log
    return ${PIPESTATUS[0]}
}


Install_MPHP8x()
{

    cd "${cur_dir}/src" || return 1
    Download_Files https://www.php.net/distributions/${Php_Ver}.tar.bz2 ${Php_Ver}.tar.bz2
    Require_File "${Php_Ver}.tar.bz2" "PHP ${PHP_Branch}"
    Install_Libzip
    Echo_Blue "[+] 正在安装 ${Php_Ver}"
    Tar_Cd ${Php_Ver}.tar.bz2 ${Php_Ver}
    PHP_Openssl3_Patch
    # configure 的 iconv 探针要能加载 /usr/local/lib 里的 libiconv.so.2。
    Ensure_Libiconv_Ldpath || exit 1
    ./configure --prefix=${MPHP_Path} --with-config-file-path=${MPHP_Path}/etc --with-config-file-scan-dir=${MPHP_Path}/conf.d --enable-fpm --with-fpm-user=www --with-fpm-group=www --enable-mysqlnd $(PHP_Common_Configure_Opts)

    PHP_Make_Install || exit 1

    echo "正在复制新的 PHP 配置文件..."
    mkdir -p ${MPHP_Path}/{etc,conf.d}
    \cp php.ini-production ${MPHP_Path}/etc/php.ini

    echo "正在修改 php.ini..."
    PHP_Ini_Tune "${MPHP_Path}/etc/php.ini" || exit 1

    cd "${cur_dir}/src" || return 1

    echo "正在创建新的 php-fpm 配置文件..."
    Write_PHP_FPM_Conf "${MPHP_Path}/etc/php-fpm.conf" "${MPHP_Path}" \
        "/run/php-fpm/php-cgi${MPHP_Short_Ver}.sock" || return 1

    echo "正在复制 php-fpm init.d 服务脚本..."
    \cp ${cur_dir}/src/${Php_Ver}/sapi/fpm/init.d.php-fpm /etc/init.d/php-fpm${MPHP_Short_Ver}
    chmod +x /etc/init.d/php-fpm${MPHP_Short_Ver}
    sed -i "s@# Provides:          php-fpm@# Provides:          php-fpm${MPHP_Short_Ver}@g" /etc/init.d/php-fpm${MPHP_Short_Ver}
    Ensure_Runtime_Directory /run/php-fpm root root || return 1
    Patch_Init_Runtime_Directory /etc/init.d/php-fpm${MPHP_Short_Ver} /run/php-fpm root root || return 1

    # 模板 unit 由所有版本共用，%i 取版本号。装上后多版本 PHP 与主 php-fpm
    # 共享同一套自动重启策略，状态也与 systemctl 一致。
    if [ -d /etc/systemd/system ]; then
        Install_Systemd_Unit "${cur_dir}/init.d/php-fpm@.service" /etc/systemd/system/php-fpm@.service || return 1
        chmod 644 /etc/systemd/system/php-fpm@.service
    fi

    StartUp php-fpm@${MPHP_Short_Ver}

    \cp ${cur_dir}/conf/enable-php${MPHP_Short_Ver}.conf /usr/local/nginx/conf/enable-php${MPHP_Short_Ver}.conf

    sleep 2

    lnmp start

    Clean_Src_Dir "${Php_Ver}"

    if [ -s ${MPHP_Path}/sbin/php-fpm ] && [ -s ${MPHP_Path}/etc/php.ini ] && [ -s ${MPHP_Path}/bin/php ]; then
        echo "==========================================="
        Echo_Green "${Php_Ver} 安装成功。"
        echo "==========================================="
    else
        rm -rf ${MPHP_Path}
        Echo_Red "${Php_Ver} 安装失败，详情请查看 /root/install-mphp${MPHP_Short_Ver}.log。"
    fi
}

# profile.sh 通过对应入口安装各 PHP 分支。
Install_MPHP8.0() { MPHP_Short_Ver="8.0"; Install_MPHP8x; }
Install_MPHP8.1() { MPHP_Short_Ver="8.1"; Install_MPHP8x; }
Install_MPHP8.2() { MPHP_Short_Ver="8.2"; Install_MPHP8x; }
Install_MPHP8.3() { MPHP_Short_Ver="8.3"; Install_MPHP8x; }
Install_MPHP8.4() { MPHP_Short_Ver="8.4"; Install_MPHP8x; }
Install_MPHP8.5() { MPHP_Short_Ver="8.5"; Install_MPHP8x; }
