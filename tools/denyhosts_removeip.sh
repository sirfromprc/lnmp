#!/usr/bin/env bash
# 从 DenyHosts 阻止列表中移除 IP

HOST="${1:-}"
if [ -z "${HOST}" ]; then
    echo "用法：$0 IP"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "错误：缺少 python3，无法严格校验 IP 地址。"
    exit 1
fi
if ! python3 - "${HOST}" <<'PY'
import ipaddress
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
then
    echo "错误：不是合法的 IPv4 或 IPv6 地址：${HOST}"
    exit 1
fi

files=(
    /etc/hosts.deny
    /var/lib/denyhosts/hosts
    /var/lib/denyhosts/hosts-restricted
    /var/lib/denyhosts/hosts-root
    /var/lib/denyhosts/hosts-valid
    /var/lib/denyhosts/users-hosts
)
tmp=''
denyhosts_stopped='n'
cleanup()
{
    [ -n "${tmp}" ] && rm -f -- "${tmp}"
    if [ "${denyhosts_stopped}" = 'y' ]; then
        /etc/init.d/denyhosts start >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT HUP INT TERM

echo "正在从 DenyHosts 中移除 IP：${HOST}..."
if ! /etc/init.d/denyhosts stop; then
    echo "错误：DenyHosts 停止失败，未修改阻止列表。"
    exit 1
fi
denyhosts_stopped='y'

for file in "${files[@]}"; do
    [ -f "${file}" ] || continue
    tmp=$(mktemp "${file}.lnmp.XXXXXX") || exit 1
    if ! python3 - "${HOST}" "${file}" "${tmp}" <<'PY'
import os
import re
import sys

host = sys.argv[1].encode('ascii')
source, target = sys.argv[2], sys.argv[3]
pattern = re.compile(rb'(?<![0-9A-Fa-f:.])' + re.escape(host) + rb'(?![0-9A-Fa-f:.])')
st = os.stat(source, follow_symlinks=False)
with open(source, 'rb') as src, open(target, 'wb') as dst:
    for line in src:
        if not pattern.search(line):
            dst.write(line)
    os.fchmod(dst.fileno(), st.st_mode & 0o7777)
    os.fchown(dst.fileno(), st.st_uid, st.st_gid)
PY
    then
        echo "错误：更新 ${file} 失败。"
        exit 1
    fi
    if ! mv -f -- "${tmp}" "${file}"; then
        echo "错误：写回 ${file} 失败。"
        exit 1
    fi
    tmp=''
done

# DenyHosts 通过 /etc/hosts.deny（tcp_wrappers）限制访问，不创建防火墙规则。
# 同一 IP 若也被 fail2ban 通过 nftables 封禁，还需单独解封：
#   fail2ban-client set sshd unbanip ${HOST}
# 手动添加的 nftables 规则可通过 `nft -a list ruleset` 查询 handle 后删除。
echo " 完成"
if ! /etc/init.d/denyhosts start; then
    echo "错误：DenyHosts 重新启动失败。"
    exit 1
fi
denyhosts_stopped='n'
trap - EXIT HUP INT TERM
