#!/usr/bin/env bash

Nginx_Dependent()
{
    if [ "$PM" = "yum" ]; then
        rpm -e httpd httpd-tools --nodeps
        yum -y remove httpd*
        for packages in make gcc gcc-c++ gcc-g77 wget crontabs zlib zlib-devel openssl openssl-devel perl patch bzip2 initscripts xz gzip;
        do yum -y install $packages; done
        if [ "${DISTRO}" = "Fedora" ] || echo "${CentOS_Version}" | grep -Eqi "^9"; then
            dnf install chkconfig -y
        fi
    elif [ "$PM" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        [[ $? -ne 0 ]] && apt-get update --allow-releaseinfo-change -y
        # 只处理确实装着的包，理由见 init.sh 的 Deb_Purge_Installed
        Deb_Purge_Installed apache2 apache2-bin apache2-data apache2-utils apache2-doc \
                            libapache2-mod-php
        for packages in debian-keyring debian-archive-keyring build-essential gcc g++ make autoconf automake wget cron openssl libssl-dev zlib1g zlib1g-dev bzip2 xz-utils gzip;
        do apt-get --no-install-recommends install -y $packages; done
    fi
}

Install_Only_Nginx()
{
    clear
    echo "+-----------------------------------------------------------------------+"
    echo "|              Install Nginx for LNMP, Written by Licess                |"
    echo "+-----------------------------------------------------------------------+"
    echo "|                     A tool to only install Nginx.                     |"
    echo "+-----------------------------------------------------------------------+"
    echo "|          Upstream-official sources only, checksums enforced            |"
    echo "+-----------------------------------------------------------------------+"
    Press_Install
    Echo_Blue "Install dependent packages..."
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
    \cp ${cur_dir}/conf/lnmp /bin/lnmp
    # 只装 nginx，没有数据库，置空服务名让 lnmp 的 Svc 跳过它
    sed -i 's#^DB_SERVICE=mysql$#DB_SERVICE=#' /bin/lnmp
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
        apt-get update -y
        [[ $? -ne 0 ]] && apt-get update --allow-releaseinfo-change -y
        Deb_Purge_Installed mysql-server mysql-client mysql-common \
                            mariadb-server mariadb-client mariadb-common libmariadbd-dev
        for packages in debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf automake wget openssl libssl-dev zlib1g zlib1g-dev libncurses5 libncurses5-dev bison libaio-dev libtirpc-dev libsasl2-dev pkg-config libpcre2-dev libxml2-dev libtinfo-dev libnuma-dev gnutls-dev xz-utils gzip;
        do apt-get --no-install-recommends install -y $packages; done
        # 通用二进制的客户端需要 ncurses 5 运行库，装不上时退回软链，理由见 init.sh
        Deb_Ncurses5_Compat
    fi
}

Install_Database()
{
    echo "============================check files=================================="
    DB_Download_Files
    echo "============================check files=================================="

    Echo_Blue "Install dependent packages..."
    Get_Dist_Version
    Modify_Source
    Check_Host_Repo_Trust
    DB_Dependent
    Check_Openssl
    Dispatch "${DB_Install}"
    TempMycnf_Clean

    if [ "${DB_Kind}" != "none" ]; then
        StartUp "${DB_Service}"
        StartOrStop start "${DB_Service}"
    fi

    Clean_DB_Src_Dir
    Check_DB_Files
    if [ "${isDB}" != "ok" ]; then
        return 1
    fi
    # 初始化 SQL 失败时不能报成功，理由见 end.sh 的 Check_DB_Init_Result
    Check_DB_Init_Result || return 1
    if [ "${DB_Kind}" != "none" ]; then
        Echo_Green "Install ${DB_Ver} completed! enjoy it."
    fi
    return 0
}

Install_Only_Database()
{
    clear
    echo "+-----------------------------------------------------------------------+"
    echo "|      Install MySQL/MariaDB database for LNMP, Written by Licess       |"
    echo "+-----------------------------------------------------------------------+"
    echo "|               A tool to install MySQL/MariaDB for LNMP                |"
    echo "+-----------------------------------------------------------------------+"
    echo "|          Upstream-official sources only, checksums enforced            |"
    echo "+-----------------------------------------------------------------------+"

    Get_Dist_Name
    Check_DB
    if [ "${DB_Name}" != "None" ]; then
        echo "You have install ${DB_Name}!"
        exit 1
    fi

    Database_Selection
    if [ "${DB_Kind}" = "none" ]; then
        echo "DO NOT Install MySQL or MariaDB."
        exit 1
    fi
    Echo_Red "The script will REMOVE MySQL/MariaDB installed via yum or apt-get and it's databases!!!"
    Press_Install
    # 同 install.sh：管道退出码默认来自 tee，必须显式取左侧的。
    Install_Database 2>&1 | tee /root/install_database.log
    local rc=${PIPESTATUS[0]}

    # 密码提示放在管道外面，只进终端不进日志。
    # DB_Root_Password / DB_Root_Password_Random 由上面的 Database_Selection
    # 在当前 shell 里设好，管道子 shell 不影响它们。
    if [ ${rc} -eq 0 ]; then
        echo "+-----------------------------------------------------------------------+"
        Print_DB_Password_Notice
        echo "+-----------------------------------------------------------------------+"
    fi
    return ${rc}
}
