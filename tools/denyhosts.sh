#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# 安装软件并写入系统配置需要 root 权限。
if [ $(id -u) != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi

cur_dir=$(cd "$(dirname "$0")/.." && pwd)

# 校验源码目录，避免在其他位置执行时因公共函数未加载而继续安装。
if [ ! -f "${cur_dir}/include/main.sh" ]; then
    echo "错误：找不到 ${cur_dir}/include/main.sh。"
    echo "请在 LNMP 源码目录内执行本脚本，例如 ./tools/$(basename "$0")。"
    exit 1
fi

. "${cur_dir}/lnmp.conf"
. "${cur_dir}/include/main.sh"
. "${cur_dir}/include/verify.sh"
Get_Dist_Name
Get_Dist_Version

Press_Start || exit 1

if [ "${PM}" = "yum" ]; then
    for packages in python rsyslog python-ipaddr;
    do yum -y install $packages; done
    if [ "${DISTRO}" = "CentOS" ] && echo "${CentOS_Version}" | grep -Eqi "^8"; then
        dnf install python2 -y
        alternatives --set python /usr/bin/python2
        pip2 install ipaddr
    fi
    service rsyslog restart
elif [ "${PM}" = "apt" ]; then
    apt-get update
    for packages in python rsyslog python-ipaddr;
    do apt-get install $packages -y; done
    /etc/init.d/rsyslog restart
fi

echo "正在下载 DenyHosts..."
cd "${cur_dir}/src"
Download_Files https://github.com/denyhosts/denyhosts/archive/refs/tags/v3.1.tar.gz denyhosts-3.1.tar.gz
Require_File "denyhosts-3.1.tar.gz" "DenyHosts"
Tar_Cd denyhosts-3.1.tar.gz denyhosts-3.1
echo "正在安装 DenyHosts..."
python setup.py install

echo "正在复制 DenyHosts 文件..."
\cp denyhosts.conf /etc

if [ "${PM}" = "yum" ]; then
    sed -i 's@^SECURE_LOG = /var/log/auth.log@#SECURE_LOG = /var/log/auth.log@g' /etc/denyhosts.conf
    sed -i 's@^#SECURE_LOG = /var/log/secure@SECURE_LOG = /var/log/secure@g' /etc/denyhosts.conf
    \cp /usr/bin/daemon-control-dist /usr/bin/daemon-control
    chown root /usr/bin/daemon-control
    chmod 700 /usr/bin/daemon-control
    \cp /usr/bin/daemon-control /etc/init.d/denyhosts

    ln -sf /usr/bin/denyhosts.py /usr/sbin/denyhosts
elif [ "${PM}" = "apt" ]; then
    \cp /usr/local/bin/daemon-control-dist /usr/local/bin/daemon-control
    chown root /usr/local/bin/daemon-control
    chmod 700 /usr/local/bin/daemon-control
    \cp /usr/local/bin/daemon-control /etc/init.d/denyhosts

    ln -sf /usr/local/bin/denyhosts.py /usr/sbin/denyhosts
    cat >lsb.ini<<EOF
### BEGIN INIT INFO
# Provides:          denyhosts
# Required-Start:    \$syslog \$local_fs \$time
# Required-Stop:     \$syslog \$local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start denyhosts and watch .
### END INIT INFO
EOF
    sed -i '9 r lsb.ini' /etc/init.d/denyhosts
    rm -f lsb.ini
fi

sed -i 's#/run/denyhosts.pid#/var/run/denyhosts.pid#g' /etc/init.d/denyhosts
sed -i 's#^PURGE_DENY =.*#PURGE_DENY =1d#g' /etc/denyhosts.conf
sed -i 's@^#PURGE_THRESHOLD = 0@PURGE_THRESHOLD = 3@g' /etc/denyhosts.conf
sed -i '/^IPTABLES/s/^/#/' /etc/denyhosts.conf
sed -i '/^ADMIN_EMAIL/s/^/#/' /etc/denyhosts.conf
sed -i 's#^DENY_THRESHOLD_ROOT =.*#DENY_THRESHOLD_ROOT = 3#g' /etc/denyhosts.conf

sed -i '/STATE_LOCK_EXISTS\ \=\ \-2/aif not os.path.exists("/var/lock/subsys"): os.makedirs("/var/lock/subsys")' /etc/init.d/denyhosts
cd ..
rm -rf denyhosts-3.1

StartUp denyhosts
echo "正在启动 DenyHosts..."
/etc/init.d/denyhosts start
