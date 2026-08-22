#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# 安装软件并写入系统配置需要 root 权限。
if [ $(id -u) != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi

# 从脚本路径确定源码根目录，供下载流程读取 src/checksums.sha256 校验文件。
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
    for packages in python3 python3-setuptools python3-systemd nftables rsyslog;
    do yum install $packages -y; done
    service rsyslog restart
elif [ "${PM}" = "apt" ]; then
    Apt_Get update
    for packages in python3 python3-setuptools nftables rsyslog;
    do Apt_Get install -y $packages; done
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart rsyslog
    else
        /etc/init.d/rsyslog restart
    fi
fi

echo "正在下载 fail2ban..."
cd "${cur_dir}/src"
Download_Files https://github.com/fail2ban/fail2ban/archive/refs/tags/1.1.0.tar.gz fail2ban-1.1.0.tar.gz
Require_File "fail2ban-1.1.0.tar.gz" "fail2ban"
tar zxf fail2ban-1.1.0.tar.gz && cd fail2ban-1.1.0
echo "正在安装 fail2ban..."
python3 setup.py install

echo "正在复制 fail2ban 配置文件..."
\cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sed -i '/^#mode   = normal/a \
enabled  = true\
filter   = sshd\
maxretry = 5\
bantime  = 604800' /etc/fail2ban/jail.local

# 使用 fail2ban 1.1.0 自带的 nftables 动作，与系统安装的防火墙组件保持一致。
# 默认 iptables-multiport 在 iptables 未安装时无法生效，错误仅记录在 fail2ban 日志中。
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

echo "正在复制 fail2ban 服务脚本..."
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

echo "正在启动 fail2ban..."
/etc/init.d/fail2ban start
