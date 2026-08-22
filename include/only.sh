#!/usr/bin/env bash

Nginx_Dependent()
{
    if [ "$PM" = "yum" ]; then
        rpm -e httpd httpd-tools --nodeps
        yum -y remove httpd*
        for packages in make gcc gcc-c++ gcc-g77 wget crontabs zlib zlib-devel openssl openssl-devel perl patch bzip2 initscripts xz gzip brotli-devel gnupg2;
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
        for packages in debian-keyring debian-archive-keyring build-essential gcc g++ make autoconf automake wget cron openssl libssl-dev zlib1g zlib1g-dev bzip2 xz-utils gzip libbrotli-dev gnupg gpgv;
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
    cd ${cur_dir}/src
    Get_Dist_Version
    Modify_Source
    Check_Host_Repo_Trust
    Nginx_Dependent
    cd ${cur_dir}/src
    Download_Files https://downloads.sourceforge.net/pcre/${Pcre_Ver}.tar.bz2 ${Pcre_Ver}.tar.bz2
    Require_File "${Pcre_Ver}.tar.bz2" "PCRE"
    Install_Pcre
    if [ `grep -L '/usr/local/lib'    '/etc/ld.so.conf'` ]; then
        echo "/usr/local/lib" >> /etc/ld.so.conf
    fi
    ldconfig
    Download_Files https://nginx.org/download/${Nginx_Ver}.tar.gz ${Nginx_Ver}.tar.gz
    Require_File "${Nginx_Ver}.tar.gz" "nginx"
    Install_Nginx
    StartUp nginx
    rm -rf ${cur_dir}/src/${Nginx_Ver}

    [[ -d "${cur_dir}/src/${Openssl_New_Ver}" ]] && rm -rf ${cur_dir}/src/${Openssl_New_Ver}
    StartOrStop start nginx
    Add_Iptables_Rules
    \cp ${cur_dir}/conf/index.html ${Default_Website_Dir}/index.html
    # 默认站点自带 favicon，避免浏览器请求在 error_log 中反复记录 404
    \cp ${cur_dir}/conf/favicon.ico ${Default_Website_Dir}/favicon.ico ||
        Echo_Red "favicon.ico 部署失败，默认站点仍会记录 /favicon.ico 404。"
    Install_Current_LNMP_Command lnmp || return 1
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
        for packages in make cmake gcc gcc-c++ gcc-g77 flex bison wget zlib zlib-devel openssl openssl-devel ncurses ncurses-devel libaio-devel rpcgen libtirpc-devel patch cyrus-sasl-devel pkg-config pcre-devel libxml2-devel hostname ncurses-libs numactl-devel libxcrypt gnutls-devel initscripts libxcrypt-compat perl xz gzip;
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
        for packages in debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf automake wget openssl libssl-dev zlib1g zlib1g-dev libncurses5 libncurses5-dev bison libaio-dev libtirpc-dev libsasl2-dev pkg-config libpcre2-dev libxml2-dev libtinfo-dev libnuma-dev gnutls-dev xz-utils gzip;
        do Apt_Get --no-install-recommends install -y $packages; done
        # 数据库通用二进制客户端需要 ncurses 5 兼容运行库。
        Deb_Ncurses5_Compat
    fi
}

Install_Database()
{
    echo "============================ 检查文件 ============================"
    DB_Download_Files
    echo "============================ 文件检查结束 ========================"

    Echo_Blue "正在安装依赖包..."
    Get_Dist_Version
    Modify_Source
    Check_Host_Repo_Trust
    DB_Dependent
    Check_Openssl
    Dispatch "${DB_Install}" || return 1
    TempMycnf_Clean

    if [ "${DB_Kind}" != "none" ]; then
        StartUp "${DB_Service}"
        StartOrStop start "${DB_Service}"
    fi

    # 独立安装数据库也必须限制 DB_Port 和 DB_X_Port；防火墙失败时安装返回非零。
    Add_Iptables_Rules || return 1

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
        echo "检测到 ${DB_Name} 已安装。"
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
        Print_DB_Password_Notice
    fi
    return ${rc}
}
