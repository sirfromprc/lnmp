#!/usr/bin/env bash

Nginx_Dependent()
{
    if [ "$PM" = "yum" ]; then
        rpm -e httpd httpd-tools --nodeps
        yum -y remove httpd*
        for packages in make gcc gcc-c++ gcc-g77 wget crontabs zlib zlib-devel openssl openssl-devel perl patch bzip2 initscripts xz gzip brotli-devel gnupg2 nftables;
        do yum -y install $packages; done
        if [ "${DISTRO}" = "Fedora" ] || echo "${CentOS_Version}" | grep -Eqi "^9"; then
            dnf install chkconfig -y
        fi
    elif [ "$PM" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        Apt_Get update -y
        [[ $? -ne 0 ]] && Apt_Get update --allow-releaseinfo-change -y
        # 仅清理实际已安装的旧 Apache 软件包。
        Deb_Purge_Installed apache2 apache2-bin apache2-data apache2-utils apache2-doc \
                            libapache2-mod-php
        for packages in debian-keyring debian-archive-keyring build-essential gcc g++ make autoconf automake wget cron openssl libssl-dev zlib1g zlib1g-dev bzip2 xz-utils gzip libbrotli-dev gnupg gpgv nftables;
        do Apt_Get --no-install-recommends install -y $packages; done
    fi
}

Install_Only_Nginx()
{
    clear 2>/dev/null || true
    Print_Banner \
        "LNMP 独立安装：Nginx" \
        "仅安装 Nginx，不安装数据库和 PHP" \
        "仅使用上游官方源码，并强制校验完整性"
    Press_Install
    Echo_Blue "安装依赖软件包..."
    cd "${cur_dir}/src" || return 1
    Get_Dist_Version
    Modify_Source
    Check_Host_Repo_Trust
    Nginx_Dependent
    if [ -n "$(grep -L '/usr/local/lib' '/etc/ld.so.conf')" ]; then
        echo "/usr/local/lib" >> /etc/ld.so.conf
    fi
    ldconfig
    Nginx_Reinstall "${Nginx_Ver#nginx-}" nginx none || return 1
    StartUp nginx
    # 重复执行本入口时 nginx 通常在运行，必须重启并核对运行中的二进制。
    if ! Restart_And_Verify_Nginx; then
        Echo_Red "Nginx 未以本次编译的二进制运行，独立安装未完成。"
        return 1
    fi
    Add_Firewall_Rules
    \cp ${cur_dir}/conf/index.html ${Default_Website_Dir}/index.html
    # 默认站点自带 favicon，避免浏览器请求在 error_log 中反复记录 404
    \cp ${cur_dir}/conf/favicon.ico ${Default_Website_Dir}/favicon.ico ||
        Echo_Red "favicon.ico 部署失败，默认站点仍会记录 /favicon.ico 404。"
    Install_Current_LNMP_Command lnmp || return 1
    # 定时任务装不上不影响已装好的 Nginx，不改变本函数的返回码。
    Install_Cutlogs_Timer
    Install_Logrotate_Conf
    Check_Nginx_Files
}

DB_Dependent()
{
    if [ "$PM" = "yum" ]; then
        yum -y remove mysql-server mysql mysql-libs mariadb-server mariadb mariadb-libs
        rpm -qa|grep mysql
        if [ $? -ne 0 ]; then
            rpm -e mysql mysql-libs --nodeps
            rpm -e mariadb mariadb-libs --nodeps
        fi
        for packages in make cmake gcc gcc-c++ gcc-g77 flex bison wget zlib zlib-devel openssl openssl-devel ncurses ncurses-devel libaio-devel rpcgen libtirpc-devel patch cyrus-sasl-devel pkg-config pcre-devel libxml2-devel hostname ncurses-libs numactl-devel libxcrypt gnutls-devel initscripts libxcrypt-compat perl xz gzip nftables;
        do yum -y install $packages; done
        if echo "${CentOS_Version}" | grep -Eqi "^8" || echo "${RHEL_Version}" | grep -Eqi "^8" || echo "${Rocky_Version}" | grep -Eqi "^8" || echo "${Alma_Version}" | grep -Eqi "^8"; then
            Check_PowerTools
            dnf --enablerepo=${repo_id} install rpcgen -y
            dnf install libarchive -y

            dnf install gcc-toolset-10 -y
        fi

        if [ "${DISTRO}" = "Oracle" ] && echo "${Oracle_Version}" | grep -Eqi "^8"; then
            Check_Codeready
            dnf --enablerepo=${repo_id} install rpcgen re2c -y
            dnf install libarchive -y
        fi

        if [ "${DISTRO}" = "Oracle" ] && echo "${Oracle_Version}" | grep -Eqi "^9"; then
            Check_Codeready
            dnf --enablerepo=${repo_id} install libtirpc-devel -y
            DB_Toolchain_EL9
        fi

        if [ "${DISTRO}" = "Fedora" ] || echo "${CentOS_Version}" | grep -Eqi "^9" || echo "${Alma_Version}" | grep -Eqi "^9" || echo "${Rocky_Version}" | grep -Eqi "^9"; then
            dnf install chkconfig -y
        fi

        if echo "${CentOS_Version}" | grep -Eqi "^9" || echo "${Alma_Version}" | grep -Eqi "^9" || echo "${Rocky_Version}" | grep -Eqi "^9"; then
            dnf --enablerepo=crb install libtirpc-devel libxcrypt-compat -y
            DB_Toolchain_EL9
        fi

        if [ -s /usr/lib64/libtinfo.so.6 ]; then
            ln -sf /usr/lib64/libtinfo.so.6 /usr/lib64/libtinfo.so.5
        elif [ -s /usr/lib/libtinfo.so.6 ]; then
            ln -sf /usr/lib/libtinfo.so.6 /usr/lib/libtinfo.so.5
        fi

        if [ -s /usr/lib64/libncurses.so.6 ]; then
            ln -sf /usr/lib64/libncurses.so.6 /usr/lib64/libncurses.so.5
        elif [ -s /usr/lib/libncurses.so.6 ]; then
            ln -sf /usr/lib/libncurses.so.6 /usr/lib/libncurses.so.5
        fi
    elif [ "$PM" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        Apt_Get update -y
        [[ $? -ne 0 ]] && Apt_Get update --allow-releaseinfo-change -y
        Deb_Purge_Installed mysql-server mysql-client mysql-common \
                            mariadb-server mariadb-client mariadb-common libmariadbd-dev
        for packages in debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf automake wget openssl libssl-dev zlib1g zlib1g-dev libncurses5 libncurses5-dev bison libaio-dev libtirpc-dev libsasl2-dev pkg-config libpcre2-dev libxml2-dev libtinfo-dev libnuma-dev gnutls-dev xz-utils gzip nftables;
        do Apt_Get --no-install-recommends install -y $packages; done
        # 数据库通用二进制客户端需要 ncurses 5 兼容运行库。
        Deb_Ncurses5_Compat
    fi
}

Install_Database()
{
    echo "============================ 检查文件 ============================"
    Download_DB_Sources
    echo "============================ 文件检查结束 ========================"

    Echo_Blue "正在安装依赖包..."
    Get_Dist_Version
    Modify_Source
    Check_Host_Repo_Trust
    DB_Dependent
    Check_Openssl
    Database_Install "${DB_Kind}" "${DB_Ver#*-}" "$(DB_Install_Mode)" || return 1
    TempMycnf_Clean

    if [ "${DB_Kind}" != "none" ] && ! Start_And_Verify "${DB_Service}"; then
        Echo_Red "${DB_Service} 未能启动，独立安装未完成。"
        return 1
    fi

    # 独立安装数据库也必须限制 DB_Port 和 DB_X_Port；防火墙失败时安装返回非零。
    Add_Firewall_Rules || return 1

    Clean_DB_Src_Dir
    Check_DB_Files
    if [ "${isDB}" != "ok" ]; then
        return 1
    fi
    # 安全初始化 SQL 全部通过后才能报告数据库安装成功。
    Check_DB_Init_Result || return 1
    if [ "${DB_Kind}" != "none" ]; then
        Echo_Green "${DB_Ver} 安装完成。"
    fi
    return 0
}

Install_Only_Database()
{
    clear 2>/dev/null || true
    Print_Banner \
        "LNMP 独立安装：MySQL/MariaDB" \
        "仅安装数据库，不安装 Web 服务器和 PHP" \
        "仅使用上游官方源码，并强制校验完整性"

    Get_Dist_Name
    Check_DB
    if [ "${DB_Name}" != "None" ]; then
        Echo_Red "检测到 ${DB_Name} 已安装（/usr/local/${DB_Name} 与 /etc/my.cnf 都存在）。"
        Echo_Red "本入口只装数据库，不会动现有实例，已中止。"
        Echo_Yellow "要重装整套环境时执行 bash install.sh lnmp，"
        Echo_Yellow "安装前的残留检测会列出现有组件并在确认后清理，数据目录先移到 /root 备份。"
        Echo_Yellow "只想换掉数据库时，请先自行停止并备份现有实例。"
        exit 1
    fi

    Database_Selection
    if [ "${DB_Kind}" = "none" ]; then
        echo "已选择不安装 MySQL 或 MariaDB。"
        exit 1
    fi
    Echo_Red "警告：脚本将删除通过 yum 或 apt-get 安装的 MySQL/MariaDB 及其数据库！"
    Press_Install
    # 返回安装命令的退出码，避免 tee 成功掩盖安装失败。
    Install_Database 2>&1 | tee /root/install_database.log
    local rc=${PIPESTATUS[0]}

    # 密码提示仅输出到终端，不写入安装日志。
    if [ ${rc} -eq 0 ]; then
        Install_Current_LNMP_Command lnmp || return 1
        # 定时任务装不上不影响已装好的数据库，不改变本函数的返回码。
        Install_Health_Timer
        Install_Logrotate_Conf
        Print_DB_Password_Notice
    fi
    return ${rc}
}

# Install_Only_Apache [lnmpa|lamp]：单独安装或补齐 Apache。栈缺省按已部署的管理命令识别；
# Apache 已就绪时不写文件，只确认服务运行。
Install_Only_Apache()
{
    local stack=${1:-} rc

    [ -n "${stack}" ] || stack=$(Detect_Installed_LNMP_Command_Stack)
    case "${stack}" in
    lnmpa|lamp) ;;
    *)
        Echo_Red "无法确定 Apache 所属的栈，请执行 ./install.sh apache lnmpa 或 ./install.sh apache lamp。"
        return 1
        ;;
    esac

    clear 2>/dev/null || true
    Print_Banner \
        "LNMP 单项安装：Apache（${stack}）" \
        "只安装或补齐 Apache，不改动数据库、PHP 与 Nginx" \
        "仅使用上游官方源码，并强制校验完整性"
    Apache_Selection || return 1
    Apache_Only_Stack=${stack}
    Press_Install
    Get_Dist_Version
    if [ "${PM}" = "yum" ]; then
        CentOS_Dependent
    elif [ "${PM}" = "apt" ]; then
        Deb_Dependent || return 1
    fi
    Apache_Install "${Apache_Ver#httpd-}" "${stack}"
    rc=$?
    [ ${rc} -eq 0 ] || return ${rc}
    Start_And_Verify httpd || return 1
    Apache_Verify "${Apache_Ver#httpd-}" "${stack}" || return 1
    if [ -x /usr/local/php/bin/php ] && [ ! -s /usr/local/apache/modules/libphp.so ]; then
        Echo_Yellow "Apache 中没有 PHP 模块 libphp.so，请执行 ./install.sh php 重新安装 PHP。"
    fi
    return 0
}

# PHP 编译依赖的 libiconv 与 freetype 缺失时安装，已安装时跳过。旧安装函数失败时 exit，在子 shell 中调用。
Install_PHP_Base_Libs()
{
    if [ ! -e /usr/local/lib/libiconv.so ]; then
        cd "${cur_dir}/src" || return 1
        Download_Source_Rows "libiconv" < <(Lib_Sources libiconv)
        Install_Libiconv
    fi
    if [ ! -e /usr/local/freetype/lib/libfreetype.so ]; then
        Install_Freetype
    fi
    return 0
}

# Install_Only_PHP [lnmp|lnmpa|lamp]：单独安装或补齐主 PHP 与默认扩展。栈缺省按已部署的管理命令识别；
# 版本缺省取已装主 PHP 的分支。PHP 已就绪时不重新编译，只补齐默认扩展并重启服务。
Install_Only_PHP()
{
    local stack=${1:-} sapi svc=php-fpm ver tune rc

    [ -n "${stack}" ] || stack=$(Detect_Installed_LNMP_Command_Stack)
    case "${stack}" in
    lnmp|lnmpa|lamp) sapi=$(PHP_Detect_Sapi "${stack}"); [ "${sapi}" = apxs ] && svc=httpd ;;
    *)
        Echo_Red "无法确定 PHP 所属的栈，请执行 ./install.sh php lnmp、./install.sh php lnmpa 或 ./install.sh php lamp。"
        return 1
        ;;
    esac
    if [ "${sapi}" = apxs ] && [ ! -x /usr/local/apache/bin/apxs ]; then
        Echo_Red "${stack} 的 PHP 以 Apache 模块方式编译，需要 /usr/local/apache/bin/apxs。"
        Echo_Red "请先执行 ./install.sh apache ${stack}。"
        return 1
    fi

    clear 2>/dev/null || true
    Print_Banner \
        "LNMP 单项安装：PHP（${stack}）" \
        "只安装或补齐主 PHP 与默认扩展，不改动数据库与 Web 服务器" \
        "仅使用上游官方源码，并强制校验完整性"
    PHP_Selection_Installed /usr/local/php
    PHP_Only_Stack=${stack}
    PHP_Only_Sapi=${sapi}
    Press_Install
    Get_Dist_Version
    if [ "${PM}" = "yum" ]; then
        CentOS_Dependent
    elif [ "${PM}" = "apt" ]; then
        Deb_Dependent || return 1
    fi
    ( Install_PHP_Base_Libs ) || { Echo_Red "PHP 依赖库 libiconv 或 freetype 安装失败。"; return 1; }

    ver=${Php_Ver#php-}
    tune=$(Tune_PHP_Spec main)
    PHP_Install /usr/local/php "${sapi}" "${ver}" "${tune}"
    rc=$?
    [ ${rc} -eq 0 ] || return ${rc}
    if [ "${Enable_Composer:-y}" = 'y' ] && [ ! -x /usr/local/bin/composer ]; then
        Install_Composer || Echo_Yellow "Composer 安装失败，不影响 PHP 运行。"
    fi
    Install_PHP_Default_Ext /usr/local/php "${tune##*:}"
    StartUp "${svc}"
    StartOrStop stop "${svc}" >/dev/null 2>&1
    Start_And_Verify "${svc}" || return 1
    PHP_Verify /usr/local/php "${sapi}" "${ver}" || return 1
    if [ -n "${PHP_Default_Ext_Failed}" ]; then
        Echo_Yellow "以下默认扩展未装上：${PHP_Default_Ext_Failed# }，可用 ./addons.sh 单独安装。"
    fi
    return 0
}
