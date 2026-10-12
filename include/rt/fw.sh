# shellcheck shell=bash
# 防火墙运行部分：规则表常量、后端判定、链重建、规则文件持久化、跟随单元、清除，
# 以及安装期与 lnmp fw 共用的 SSH、Redis、Memcached 端口探测。
# 安装器经 include/main.sh 加载；tools/lnmp-fw.sh 部署时由 include/rt/cli_assemble.sh 并入产物。
# 依赖 include/rt/svc.sh。除下列常量外只含函数定义，不引用组件变量；错误信息写标准错误。

FW_TABLE='inet lnmp'
FW_CHAIN='input'
# LNMP 规则单独保存在此文件，不覆盖系统防火墙主配置。
FW_INCLUDE_FILE="${LNMP_FW_NFT_FILE:-/etc/nftables.d/lnmp.nft}"
# 跟随 nftables.service 加载上述规则文件的单元。
FW_UNIT_NAME='lnmp-nftables'
FW_UNIT_FILE="/etc/systemd/system/${FW_UNIT_NAME}.service"
FW_Backend="${FW_Backend:-}"
# 实际监听的 SSH 端口，由 Resolve_SSH_Ports 填充。
SSH_Ports=()

# Firewall_Backend：选择防火墙后端，结果记入 FW_Backend（firewalld、nft 或 none）。
Firewall_Backend()
{
    [ -n "${FW_Backend}" ] && return 0
    if command -v firewall-cmd >/dev/null 2>&1 \
       && systemctl is-active firewalld >/dev/null 2>&1; then
        FW_Backend='firewalld'
    elif command -v nft >/dev/null 2>&1; then
        FW_Backend='nft'
    else
        FW_Backend='none'
    fi
}

# Fw_Rebuild_Chain：建立 inet lnmp 表并删链重建，防止重复执行造成规则累积。链内无规则。
Fw_Rebuild_Chain()
{
    if ! nft add table ${FW_TABLE} 2>/dev/null; then
        echo "无法创建 nftables 表 ${FW_TABLE}。" >&2
        return 1
    fi
    nft delete chain ${FW_TABLE} ${FW_CHAIN} 2>/dev/null
    if ! nft add chain ${FW_TABLE} ${FW_CHAIN} \
         '{ type filter hook input priority filter; policy accept; }' 2>/dev/null; then
        echo "无法创建 nftables 链 ${FW_TABLE} ${FW_CHAIN}。" >&2
        return 1
    fi
    return 0
}

# Fw_Write_Rules <生成者说明> <重新加载命令>：导出内核中的 inet lnmp 表，
# 采集完整且 nft -c 校验通过后原子替换 FW_INCLUDE_FILE。
Fw_Write_Rules()
{
    local tmp

    mkdir -p "$(dirname "${FW_INCLUDE_FILE}")" || return 1
    tmp=$(mktemp "${FW_INCLUDE_FILE}.XXXXXXXX") || return 1
    {
        echo '#!/usr/sbin/nft -f'
        echo "# $1"
        echo '# 本文件只定义 LNMP 自己的 inet lnmp 表，不影响系统其他防火墙规则。'
        echo "# 重新加载：$2"
        echo
        echo 'table inet lnmp'
        echo 'delete table inet lnmp'
        nft list table ${FW_TABLE}
    } > "${tmp}" 2>/dev/null

    if [ ! -s "${tmp}" ] || ! grep -q "chain ${FW_CHAIN}" "${tmp}"; then
        echo "采集 nftables 规则失败，未修改 ${FW_INCLUDE_FILE}。" >&2
        rm -f "${tmp}"
        return 1
    fi
    if ! nft -c -f "${tmp}" >/dev/null 2>&1; then
        echo "生成的规则文件语法校验（nft -c -f）未通过，未修改 ${FW_INCLUDE_FILE}。" >&2
        rm -f "${tmp}"
        return 1
    fi
    if ! chmod 600 "${tmp}" || ! mv -f "${tmp}" "${FW_INCLUDE_FILE}"; then
        echo "写入 ${FW_INCLUDE_FILE} 失败。" >&2
        rm -f "${tmp}"
        return 1
    fi
    return 0
}

# Fw_Install_Unit [单元模板]：给出模板时按模板写入 lnmp-nftables.service（nft 路径按本机替换），
# 模板为空时沿用已部署的单元；随后启用并登记为已启动。
# 该单元 After/PartOf nftables.service，nftables 启动或重启后重新加载 FW_INCLUDE_FILE。
Fw_Install_Unit()
{
    local src="${1:-}" nft_bin tmp

    Svc_Systemd || return 1
    if [ -n "${src}" ]; then
        [ -s "${src}" ] || return 1
        nft_bin=$(command -v nft) || return 1
        tmp=$(mktemp "${FW_UNIT_FILE}.XXXXXXXX") || return 1
        if ! sed "s#^\(ExecStart=\|ExecStop=-\)/usr/sbin/nft #\1${nft_bin} #" "${src}" > "${tmp}" \
           || ! chmod 644 "${tmp}" || ! mv -f "${tmp}" "${FW_UNIT_FILE}"; then
            rm -f "${tmp}"
            return 1
        fi
        Svc_Reload_Units
    fi
    [ -s "${FW_UNIT_FILE}" ] || return 1
    systemctl enable "${FW_UNIT_NAME}" >/dev/null 2>&1
    systemctl is-enabled "${FW_UNIT_NAME}" >/dev/null 2>&1 || return 1
    # 规则已在内存中，只登记服务状态，避免后续 restart 时被判为未启动。
    systemctl start "${FW_UNIT_NAME}" >/dev/null 2>&1
    return 0
}

# Fw_Purge：删除跟随单元、inet lnmp 表与规则文件。删除失败返回 1。
Fw_Purge()
{
    local rc=0

    command -v systemctl >/dev/null 2>&1 && systemctl disable --now "${FW_UNIT_NAME}" >/dev/null 2>&1
    if [ -f "${FW_UNIT_FILE}" ] && ! rm -f "${FW_UNIT_FILE}"; then
        echo "删除 ${FW_UNIT_FILE} 失败。" >&2
        rc=1
    fi
    Svc_Reload_Units
    command -v nft >/dev/null 2>&1 && nft delete table ${FW_TABLE} 2>/dev/null
    if [ -f "${FW_INCLUDE_FILE}" ] && ! rm -f "${FW_INCLUDE_FILE}"; then
        echo "删除 ${FW_INCLUDE_FILE} 失败。" >&2
        rc=1
    fi
    # 目录为本包创建，仅在没有其他规则文件时移除。
    rmdir "$(dirname "${FW_INCLUDE_FILE}")" 2>/dev/null
    return ${rc}
}

# Fw_Valid_Port <值>：1～65535 的十进制端口返回 0。
Fw_Valid_Port()
{
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Fw_Redis_Port <redis.conf> [默认端口]：输出 Redis 的 TCP 端口；读不到或不合法时用默认值。
# port 0 表示只监听 unixsocket，返回 1；读不到且无默认值也返回 1。
Fw_Redis_Port()
{
    local port

    port=$(awk '$1 == "port" { print $2; exit }' "$1" 2>/dev/null)
    [ "${port}" = "0" ] && return 1
    Fw_Valid_Port "${port}" || port="${2:-}"
    [ -n "${port}" ] || return 1
    printf '%s\n' "${port}"
}

# Fw_Memcached_Port <init 脚本> [默认端口]：输出 Memcached 端口；读不到或不合法时用默认值，无默认值返回 1。
Fw_Memcached_Port()
{
    local port

    port=$(awk -F= '$1 == "PORT" { gsub(/"/, "", $2); print $2; exit }' "$1" 2>/dev/null)
    Fw_Valid_Port "${port}" || port="${2:-}"
    [ -n "${port}" ] || return 1
    printf '%s\n' "${port}"
}

# Get_Sshd_Config_Ports [sshd_config]：输出主配置与 sshd_config.d 中的 Port 值。
Get_Sshd_Config_Ports()
{
    local conf="${1:-/etc/ssh/sshd_config}"
    local conf_dir f
    local -a files

    conf_dir=$(dirname "${conf}")
    files=("${conf}" "${conf_dir}/sshd_config.d/"*.conf)

    for f in "${files[@]}"; do
        [ -s "${f}" ] || continue
        grep -Eio '^[[:space:]]*Port[[:space:]]+[0-9]+' "${f}" 2>/dev/null | awk '{print $2}'
    done
}

# Get_Actual_SSH_Port：输出 sshd 实际监听的端口，去重排序。
# 依次取 ss、netstat，都取不到时读配置，配置无 Port 时为 22；sshd_config 不存在时返回 1。
Get_Actual_SSH_Port()
{
    local port
    local -a ports=()

    if command -v ss >/dev/null 2>&1; then
        while read -r port; do
            case "${port}" in ''|*[!0-9]*) continue ;; esac
            ports+=("${port}")
        done < <(ss -Htlnp 2>/dev/null | grep -F 'sshd' | awk '{print $4}' | sed -E 's/.*://')
    fi

    if [ ${#ports[@]} -eq 0 ] && command -v netstat >/dev/null 2>&1; then
        while read -r port; do
            case "${port}" in ''|*[!0-9]*) continue ;; esac
            ports+=("${port}")
        done < <(netstat -tlnp 2>/dev/null | grep -F 'sshd' | awk '{print $4}' | sed -E 's/.*://')
    fi

    if [ ${#ports[@]} -eq 0 ] && [ -s /etc/ssh/sshd_config ]; then
        while read -r port; do
            case "${port}" in ''|*[!0-9]*) continue ;; esac
            ports+=("${port}")
        done < <(Get_Sshd_Config_Ports)
        [ ${#ports[@]} -eq 0 ] && ports=(22)
    fi

    if [ ${#ports[@]} -eq 0 ]; then
        return 1
    fi
    printf '%s\n' "${ports[@]}" | sort -un
    return 0
}

# Resolve_SSH_Ports：探测 SSH 端口存入 SSH_Ports，丢弃 1～65535 之外的值；无端口时返回 1。
# 放行错端口会把自己关在门外，因此以实际监听为准，不取配置项。
Resolve_SSH_Ports()
{
    local p

    SSH_Ports=()
    while read -r p; do
        Fw_Valid_Port "${p}" && SSH_Ports+=("${p}")
    done < <(Get_Actual_SSH_Port)

    [ ${#SSH_Ports[@]} -gt 0 ]
}
