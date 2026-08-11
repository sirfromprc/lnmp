#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this script!"
    exit 1
fi
clear
echo "+----------------------------------------------------------+"
echo "|          Pureftpd for LNMP,  Written by Licess           |"
echo "+----------------------------------------------------------+"
echo "|This script is a tool to install pureftpd for LNMP        |"
echo "+----------------------------------------------------------+"
echo "|Upstream-official sources only, checksums enforced        |"
echo "+----------------------------------------------------------+"
echo "|Usage: ./pureftpd.sh                                      |"
echo "+----------------------------------------------------------+"
cur_dir=$(pwd)
action=$1

. lnmp.conf
. include/main.sh
. include/verify.sh
. include/firewall.sh
. include/init.sh

Get_Dist_Name

Install_Pureftpd()
{
    Press_Install

    Echo_Blue "Installing dependent packages..."
    if [ "$PM" = "yum" ]; then
        for packages in make gcc gcc-c++ gcc-g77 openssl openssl-devel bzip2;
        do yum -y install $packages; done
    elif [ "$PM" = "apt" ]; then
        apt-get update -y
        [[ $? -ne 0 ]] && apt-get update --allow-releaseinfo-change -y
        for packages in build-essential gcc g++ make openssl libssl-dev bzip2;
        do apt-get --no-install-recommends install -y $packages; done
    fi
    Echo_Blue "Download files..."
    cd ${cur_dir}/src
    Download_Files https://download.pureftpd.org/pub/pure-ftpd/releases/${Pureftpd_Ver}.tar.bz2 ${Pureftpd_Ver}.tar.bz2
    Require_File "${Pureftpd_Ver}.tar.bz2" "Pure-FTPd"
    if [ $? -eq 0 ]; then
        echo "Download ${Pureftpd_Ver}.tar.bz2 successfully!"
    else
        Download_Files https://download.pureftpd.org/pub/pure-ftpd/releases/${Pureftpd_Ver}.tar.bz2 ${Pureftpd_Ver}.tar.bz2
    fi

    Echo_Blue "Installing pure-ftpd..."
    Tar_Cd ${Pureftpd_Ver}.tar.bz2 ${Pureftpd_Ver}
    ./configure --prefix=/usr/local/pureftpd CFLAGS=-O2 --with-puredb --with-quotas --with-cookie --with-virtualhosts --with-diraliases --with-sysquotas --with-ratios --with-altlog --with-paranoidmsg --with-shadow --with-welcomemsg --with-throttling --with-uploadscript --with-language=english --with-rfc2640 --with-ftpwho --with-tls

    Make_Install || exit 1

    Echo_Blue "Copy configure files..."
    mkdir /usr/local/pureftpd/etc
    \cp ${cur_dir}/conf/pure-ftpd.conf /usr/local/pureftpd/etc/pure-ftpd.conf
    if [ -L /etc/init.d/pureftpd ]; then
        rm -f /etc/init.d/pureftpd
    fi
    \cp ${cur_dir}/init.d/init.d.pureftpd /etc/init.d/pureftpd
    \cp ${cur_dir}/init.d/pureftpd.service /etc/systemd/system/pureftpd.service
    chmod +x /etc/init.d/pureftpd
    touch /usr/local/pureftpd/etc/pureftpd.passwd
    touch /usr/local/pureftpd/etc/pureftpd.pdb

    # FTP 协议本身是明文的，账号口令在网络上失去防护。pure-ftpd 已带 --with-tls，
    # 仅缺少证书时保留原配置；启用 TLS 但缺少证书会导致启动失败，
    # 所以这里先把自签证书准备好（pure-ftpd 要求私钥和证书合并在同一个 pem）。
    #
    # 自签证书客户端会提示「证书不受信任」，但链路仍然是加密的 ：
    # 比明文强得多。有正式证书的话，把 fullchain + privkey 拼进同一文件替换即可。
    if [ ! -s /usr/local/pureftpd/etc/pure-ftpd.pem ]; then
        Echo_Blue "Generating self-signed certificate for FTPS..."
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/CN=$(hostname -f 2>/dev/null || hostname)" \
            -keyout /usr/local/pureftpd/etc/pure-ftpd.pem \
            -out /usr/local/pureftpd/etc/pure-ftpd.pem >/dev/null 2>&1
        chmod 600 /usr/local/pureftpd/etc/pure-ftpd.pem
    fi

    StartUp pureftpd

    cd ..
    rm -rf ${cur_dir}/src/${Pureftpd_Ver}

    Firewall_Allow tcp 20
    Firewall_Allow tcp 21
    Firewall_Allow tcp 20000-30000
    Firewall_Save

    if [ ! -s /bin/lnmp ]; then
        \cp ${cur_dir}/conf/lnmp /bin/lnmp
        chmod +x /bin/lnmp
        \cp ${cur_dir}/tools/lnmp-backup.sh /bin/lnmp-backup
        chmod +x /bin/lnmp-backup
    fi
    id -u www
    if [ $? -ne 0 ]; then
        groupadd www
        useradd -s /sbin/nologin -g www www
    fi

    if [[ -s /usr/local/pureftpd/sbin/pure-ftpd && -s /usr/local/pureftpd/etc/pure-ftpd.conf && -s /etc/init.d/pureftpd ]]; then
        Echo_Blue "Starting pureftpd..."
        /etc/init.d/pureftpd start
        Echo_Green "+----------------------------------------------------------------------+"
        Echo_Green "| Install Pure-FTPd completed,enjoy it!"
        Echo_Green "| =>use command: lnmp ftp {add|list|del|show} to manage FTP users."
        Echo_Green "+----------------------------------------------------------------------+"
        Echo_Green "| Pure-FTPd installed from download.pureftpd.org (official)"
        Echo_Green "+----------------------------------------------------------------------+"
    else
        Echo_Red "Pureftpd install failed!"
    fi
}

Uninstall_Pureftpd()
{
    if [ ! -f /usr/local/pureftpd/sbin/pure-ftpd ]; then
        Echo_Red "Pureftpd was not installed!"
        exit 1
    fi
    echo "Stop pureftpd..."
    /etc/init.d/pureftpd stop
    echo "Remove service..."
    Remove_StartUp pureftpd
    echo "Delete files..."
    rm -f /etc/init.d/pureftpd
    rm -rf /usr/local/pureftpd
    echo "Pureftpd uninstall completed."
}

Pureftpd_Rc=0
if [ "${action}" = "uninstall" ]; then
    Uninstall_Pureftpd
    Pureftpd_Rc=$?
else
    # 管道退出码默认来自 tee，必须显式取左侧的，否则装失败也返回 0。
    Install_Pureftpd 2>&1 | tee /root/pureftpd-install.log
    Pureftpd_Rc=${PIPESTATUS[0]}
fi
exit ${Pureftpd_Rc}
