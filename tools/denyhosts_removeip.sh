#!/usr/bin/env bash
# Remove an IP from DenyHosts blocklist

HOST=$1
if [ -z "${HOST}" ]; then
    echo "Usage:$0 IP"
    exit 1
fi

echo "Remove IP:${HOST} from denyhosts..."
/etc/init.d/denyhosts stop
echo '
/etc/hosts.deny
/var/lib/denyhosts/hosts
/var/lib/denyhosts/hosts-restricted
/var/lib/denyhosts/hosts-root
/var/lib/denyhosts/hosts-valid
/var/lib/denyhosts/users-hosts
' | grep -v "^$" | xargs sed -i "/${HOST}/d"

# DenyHosts 走的是 /etc/hosts.deny（tcp_wrappers），本身不写防火墙规则。
# 若该 IP 另外被 fail2ban 用 nftables 封过，需要单独解封，例如：
#   fail2ban-client set sshd unbanip ${HOST}
# 手工加过的 nft 规则可用 `nft -a list ruleset` 查 handle 后删除。
echo " done"
/etc/init.d/denyhosts start