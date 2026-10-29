#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# 安装软件并写入系统配置需要 root 权限。
if [ "$(id -u)" != "0" ]; then
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
. "${cur_dir}/include/version.sh"
. "${cur_dir}/include/init.sh"
. "${cur_dir}/include/lock.sh"
Get_Dist_Name
Get_Dist_Version

Lock_Acquire "tools/denyhosts.sh" || exit 2
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
    Apt_Get update
    for packages in python rsyslog python-ipaddr;
    do Apt_Get install $packages -y; done
    /etc/init.d/rsyslog restart
fi

# DenyHosts 3.1 依赖 python 命令及 distutils、ipaddr 模块，缺失时在下载与写配置前中止。
if ! python -c 'import distutils.core, ipaddr' >/dev/null 2>&1; then
    Echo_Red "缺少 DenyHosts 3.1 所需的 python 命令或 distutils、ipaddr 模块，未写入 DenyHosts 文件与配置。"
    Echo_Red "Python 3.12 起已移除 distutils，Debian 13 等系统无法安装 DenyHosts，请改用 tools/fail2ban.sh。"
    exit 1
fi

echo "正在下载 DenyHosts..."
cd "${cur_dir}/src" || exit 1
Download_Source_Rows "DenyHosts" < <(Lib_Sources denyhosts)
Tar_Cd "${Denyhosts_Ver}.tar.gz" "${Denyhosts_Ver}"
echo "正在安装 DenyHosts..."
python setup.py install || { Echo_Red "DenyHosts 安装失败。"; exit 1; }

echo "正在复制 DenyHosts 文件..."
\cp denyhosts.conf /etc || exit 1

if [ "${PM}" = "yum" ]; then
    sed -i 's@^SECURE_LOG = /var/log/auth.log@#SECURE_LOG = /var/log/auth.log@g' /etc/denyhosts.conf
    sed -i 's@^#SECURE_LOG = /var/log/secure@SECURE_LOG = /var/log/secure@g' /etc/denyhosts.conf
    \cp /usr/bin/daemon-control-dist /usr/bin/daemon-control || exit 1
    chown root /usr/bin/daemon-control
    chmod 700 /usr/bin/daemon-control
    \cp /usr/bin/daemon-control /etc/init.d/denyhosts || exit 1

    ln -sf /usr/bin/denyhosts.py /usr/sbin/denyhosts
elif [ "${PM}" = "apt" ]; then
    \cp /usr/local/bin/daemon-control-dist /usr/local/bin/daemon-control || exit 1
    chown root /usr/local/bin/daemon-control
    chmod 700 /usr/local/bin/daemon-control
    \cp /usr/local/bin/daemon-control /etc/init.d/denyhosts || exit 1

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
rm -rf -- "${Denyhosts_Ver:?}"

StartUp denyhosts
echo "正在启动 DenyHosts..."
/etc/init.d/denyhosts start
