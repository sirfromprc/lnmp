#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi
cur_dir=$(pwd)
action=$1

. lnmp.conf
. include/main.sh
. include/verify.sh
. include/firewall.sh
. include/init.sh
. include/end.sh

Validate_Service_Ports || exit 1
Get_Dist_Name

clear
Print_Banner \
    "LNMP Pure-FTPd 安装工具" \
    "为现有 LNMP 环境安装 FTP 服务" \
    "用法：./pureftpd.sh"

Install_Pureftpd()
{
    Press_Install

    Echo_Blue "安装依赖软件包..."
    if [ "$PM" = "yum" ]; then
        for packages in make gcc gcc-c++ gcc-g77 openssl openssl-devel bzip2;
        do yum -y install $packages; done
    elif [ "$PM" = "apt" ]; then
        apt-get update -y
        [[ $? -ne 0 ]] && apt-get update --allow-releaseinfo-change -y
        for packages in build-essential gcc g++ make openssl libssl-dev bzip2;
        do apt-get --no-install-recommends install -y $packages; done
    fi
    Echo_Blue "正在下载文件..."
    cd ${cur_dir}/src
    Download_Files https://download.pureftpd.org/pub/pure-ftpd/releases/${Pureftpd_Ver}.tar.bz2 ${Pureftpd_Ver}.tar.bz2
    Require_File "${Pureftpd_Ver}.tar.bz2" "Pure-FTPd"
    if [ $? -eq 0 ]; then
        echo "${Pureftpd_Ver}.tar.bz2 下载成功。"
    else
        Download_Files https://download.pureftpd.org/pub/pure-ftpd/releases/${Pureftpd_Ver}.tar.bz2 ${Pureftpd_Ver}.tar.bz2
    fi

    Echo_Blue "正在安装 Pure-FTPd..."
    Tar_Cd ${Pureftpd_Ver}.tar.bz2 ${Pureftpd_Ver}
    ./configure --prefix=/usr/local/pureftpd CFLAGS=-O2 --with-puredb --with-quotas --with-cookie --with-virtualhosts --with-diraliases --with-sysquotas --with-ratios --with-altlog --with-paranoidmsg --with-shadow --with-welcomemsg --with-throttling --with-uploadscript --with-language=english --with-rfc2640 --with-ftpwho --with-tls

    Make_Install || exit 1

    Echo_Blue "正在复制配置文件..."
    mkdir /usr/local/pureftpd/etc
    \cp ${cur_dir}/conf/pure-ftpd.conf /usr/local/pureftpd/etc/pure-ftpd.conf
    # 端口跟随 lnmp.conf：控制端口写 Bind，被动范围写 PassivePortRange。
    # 这三个值同时决定下面的放行规则，改一处即可。
    sed -i "s|^PassivePortRange .*|PassivePortRange             ${Pureftpd_Passive_Min} ${Pureftpd_Passive_Max}|" \
        /usr/local/pureftpd/etc/pure-ftpd.conf
    if grep -q '^Bind ' /usr/local/pureftpd/etc/pure-ftpd.conf; then
        sed -i "s|^Bind .*|Bind                         0.0.0.0,${Pureftpd_Port}|" \
            /usr/local/pureftpd/etc/pure-ftpd.conf
    else
        printf '\n# 监听地址与端口，由 lnmp.conf 的 Pureftpd_Port 决定\nBind                         0.0.0.0,%s\n' \
            "${Pureftpd_Port}" >> /usr/local/pureftpd/etc/pure-ftpd.conf
    fi
    # 覆写之后确认真的写进去了：上游模板改了写法时 sed 会一条都匹配不上，
    # 服务就会用模板里的默认端口起来，与下面的放行规则对不上。
    Check_Conf_Applied /usr/local/pureftpd/etc/pure-ftpd.conf \
        "^Bind[[:space:]]+0\.0\.0\.0,${Pureftpd_Port}\$" \
        "FTP 控制端口 ${Pureftpd_Port}" || exit 1
    Check_Conf_Applied /usr/local/pureftpd/etc/pure-ftpd.conf \
        "^PassivePortRange[[:space:]]+${Pureftpd_Passive_Min}[[:space:]]+${Pureftpd_Passive_Max}\$" \
        "FTP 被动端口范围 ${Pureftpd_Passive_Min}-${Pureftpd_Passive_Max}" || exit 1
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
        Echo_Blue "正在为 FTPS 生成自签名证书..."
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/CN=$(hostname -f 2>/dev/null || hostname)" \
            -keyout /usr/local/pureftpd/etc/pure-ftpd.pem \
            -out /usr/local/pureftpd/etc/pure-ftpd.pem >/dev/null 2>&1
        chmod 600 /usr/local/pureftpd/etc/pure-ftpd.pem
    fi

    StartUp pureftpd

    cd ..
    rm -rf ${cur_dir}/src/${Pureftpd_Ver}

    Firewall_Allow tcp "${Pureftpd_Data_Port}"
    Firewall_Allow tcp "${Pureftpd_Port}"
    Firewall_Allow tcp "${Pureftpd_Passive_Min}-${Pureftpd_Passive_Max}"
    Firewall_Save

    if [ ! -s /bin/lnmp ]; then
        Install_LNMP_Command lnmp || exit 1
    else
        Install_Current_LNMP_Command lnmp || exit 1
    fi
    id -u www
    if [ $? -ne 0 ]; then
        groupadd www
        useradd -s /sbin/nologin -g www www
    fi

    if [[ -s /usr/local/pureftpd/sbin/pure-ftpd && -s /usr/local/pureftpd/etc/pure-ftpd.conf && -s /etc/init.d/pureftpd ]]; then
        Echo_Blue "正在启动 Pure-FTPd..."
        # 走 StartOrStop 而不是只检查 systemctl 命令是否存在；必须确认 systemd
        # 实际运行且 unit 存在，否则退回 SysV 脚本。
        StartOrStop start pureftpd
        Pureftpd_Start_Rc=$?
        if [ "${Pureftpd_Start_Rc}" -eq 0 ]; then
            # init 脚本的 status 只打印文字、恒返回 0，不能当判据。
            # 走 systemd 就问 systemctl，否则看 pid 文件对应的进程还在不在。
            if Use_Systemd_Unit pureftpd; then
                systemctl is-active --quiet pureftpd.service || Pureftpd_Start_Rc=1
            elif ! { [ -s /var/run/pure-ftpd.pid ] \
                     && kill -0 "$(cat /var/run/pure-ftpd.pid)" 2>/dev/null; }; then
                Pureftpd_Start_Rc=1
            fi
        fi
        if [ "${Pureftpd_Start_Rc}" -eq 0 ]; then
            Print_Banner \
                "Pure-FTPd 安装完成" \
                "使用 lnmp ftp {add|list|del|show} 管理 FTP 用户" \
                "安装包来自官方站点 download.pureftpd.org"
        else
            Echo_Red "Pure-FTPd 启动失败。"
            exit 1
        fi
    else
        Echo_Red "Pure-FTPd 安装失败。"
    fi
}

Uninstall_Pureftpd()
{
    if [ ! -f /usr/local/pureftpd/sbin/pure-ftpd ]; then
        Echo_Red "未检测到已安装的 Pure-FTPd。"
        exit 1
    fi
    echo "正在停止 Pure-FTPd..."
    /etc/init.d/pureftpd stop
    echo "正在删除服务配置..."
    Remove_StartUp pureftpd
    echo "正在删除文件..."
    rm -f /etc/init.d/pureftpd
    rm -rf /usr/local/pureftpd
    echo "Pure-FTPd 卸载完成。"
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
