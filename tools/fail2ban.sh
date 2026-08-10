#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this script, please use root to install lnmp"
    exit 1
fi

# cur_dir 必须设，理由同 tools/denyhosts.sh：Download_Files 的校验会读
# ${cur_dir}/src/checksums.sha256，没设时解析成 /src/... 直接 fail-closed 退出。
cur_dir=$(cd "$(dirname "$0")/.." && pwd)

. "${cur_dir}/lnmp.conf"
. "${cur_dir}/include/main.sh"
. "${cur_dir}/include/verify.sh"
Get_Dist_Name
Get_Dist_Version

Press_Start

if [ "${PM}" = "yum" ]; then
    for packages in python3 python3-setuptools python3-systemd nftables rsyslog;
    do yum install $packages -y; done
    service rsyslog restart
elif [ "${PM}" = "apt" ]; then
    apt-get update
    for packages in python3 python3-setuptools nftables rsyslog;
    do apt-get install -y $packages; done
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart rsyslog
    else
        /etc/init.d/rsyslog restart
    fi
fi

echo "Downloading..."
cd "${cur_dir}/src"
Download_Files https://github.com/fail2ban/fail2ban/archive/refs/tags/1.1.0.tar.gz fail2ban-1.1.0.tar.gz
Require_File "fail2ban-1.1.0.tar.gz" "fail2ban"
tar zxf fail2ban-1.1.0.tar.gz && cd fail2ban-1.1.0
echo "Installing fail2ban..."
python3 setup.py install

echo "Copy configure file..."
\cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sed -i '/^#mode   = normal/a \
enabled  = true\
filter   = sshd\
maxretry = 5\
bantime  = 604800' /etc/fail2ban/jail.local

# 封禁动作改用 nftables。本包已不再安装 iptables 及其持久化组件，
# 若仍用默认的 iptables-multiport，fail2ban 会在首次封禁时因找不到
# iptables 而报错，且失败是静默的（只写自己的日志），很难察觉。
# fail2ban 1.1.0 自带 action.d/nftables.conf。
if [ -s /etc/fail2ban/action.d/nftables.conf ]; then
    if grep -q '^banaction' /etc/fail2ban/jail.local; then
        sed -i 's/^banaction *=.*/banaction = nftables[type=multiport]/' /etc/fail2ban/jail.local
        sed -i 's/^banaction_allports *=.*/banaction_allports = nftables[type=allports]/' /etc/fail2ban/jail.local
    else
        sed -i '/^\[DEFAULT\]/a banaction = nftables[type=multiport]\nbanaction_allports = nftables[type=allports]' /etc/fail2ban/jail.local
    fi
else
    Echo_Red "未找到 action.d/nftables.conf，fail2ban 仍会尝试用 iptables 封禁。"
fi

echo "Copy init files..."
if [ ! -d /var/run/fail2ban ];then
    mkdir /var/run/fail2ban
fi

\cp build/fail2ban.service /etc/systemd/system/fail2ban.service
if [ "${PM}" = "yum" ]; then
    \cp files/redhat-initd /etc/init.d/fail2ban
    sed -i 's#^before = paths-debian.conf#before = paths-fedora.conf#' /etc/fail2ban/jail.local
    sed -i 's/^Environment="PYTHONNOUSERSITE=1"/#Environment="PYTHONNOUSERSITE=1"/' /etc/systemd/system/fail2ban.service
    sed -i 's/-xf start/-x start/' /etc/systemd/system/fail2ban.service
elif [ "${PM}" = "apt" ]; then
    \cp files/debian-initd /etc/init.d/fail2ban
fi

chmod +x /etc/init.d/fail2ban
cd ..
rm -rf fail2ban-1.1.0

StartUp fail2ban

echo "Start fail2ban..."
/etc/init.d/fail2ban start
