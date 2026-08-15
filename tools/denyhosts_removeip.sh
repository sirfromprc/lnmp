#!/usr/bin/env bash
# 从 DenyHosts 阻止列表中移除 IP

HOST=$1
if [ -z "${HOST}" ]; then
    echo "用法：$0 IP"
    exit 1
fi

echo "正在从 DenyHosts 中移除 IP：${HOST}..."
/etc/init.d/denyhosts stop
echo '
/etc/hosts.deny
/var/lib/denyhosts/hosts
/var/lib/denyhosts/hosts-restricted
/var/lib/denyhosts/hosts-root
/var/lib/denyhosts/hosts-valid
/var/lib/denyhosts/users-hosts
' | grep -v "^$" | xargs sed -i "/${HOST}/d"

# DenyHosts 通过 /etc/hosts.deny（tcp_wrappers）限制访问，不创建防火墙规则。
# 同一 IP 若也被 fail2ban 通过 nftables 封禁，还需单独解封：
#   fail2ban-client set sshd unbanip ${HOST}
# 手动添加的 nftables 规则可通过 `nft -a list ruleset` 查询 handle 后删除。
echo " 完成"
/etc/init.d/denyhosts start
