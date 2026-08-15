#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi

# cur_dir 必须设，理由同 tools/denyhosts.sh：Download_Files 的校验会读
# ${cur_dir}/src/checksums.sha256，没设时解析成 /src/... 直接 fail-closed 退出。
cur_dir=$(cd "$(dirname "$0")/.." && pwd)

# 脚本被复制到源码目录之外执行时，上面推导出的 cur_dir 是错的，加载会失败。
# 不检查的话后面每个公共函数都会 command not found，却还继续往下跑。
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
