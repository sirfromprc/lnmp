#!/usr/bin/env bash

FW_TABLE='inet lnmp'
FW_CHAIN='input'

# LNMP 规则单独保存在此文件，避免覆盖系统防火墙主配置。
FW_INCLUDE_FILE='/etc/nftables.d/lnmp.nft'

# 跟随 nftables.service 加载上述规则文件的单元。
FW_UNIT_NAME='lnmp-nftables'
FW_UNIT_FILE="/etc/systemd/system/${FW_UNIT_NAME}.service"

# 防火墙配置失败时由 end.sh 汇总提示。
FW_Failed='n'

# 实际监听的 SSH 端口，由 Resolve_SSH_Ports 填充。
SSH_Ports=()

# 选择可用的防火墙后端，并将结果记录为 firewalld、nft 或 none。
Firewall_Backend()
{
    if [ -n "${FW_Backend}" ]; then
        return 0
    fi
    if command -v firewall-cmd >/dev/null 2>&1 \
       && systemctl is-active firewalld >/dev/null 2>&1; then
        FW_Backend='firewalld'
    elif command -v nft >/dev/null 2>&1; then
        FW_Backend='nft'
    else
        FW_Backend='none'
    fi
}


# 初始化防火墙后端。firewalld 使用现有 zone；nft 使用独立的 inet lnmp
# 表和链，重建基础规则以避免重复，并保留系统中的其他规则表。
Firewall_Init()
{
    Firewall_Backend

    case "${FW_Backend}" in
    firewalld)
        echo "检测到 firewalld 正在运行，改用 firewall-cmd 管理端口（不停用它）。"
        return 0
        ;;
    none)
        Echo_Red "未找到 nft / firewall-cmd，跳过防火墙配置。"
        Echo_Red "请手动确认 ${DB_Port:-3306} / ${Redis_Port:-6379} / ${Memcached_Port:-11211} 等端口没有暴露在公网。"
        FW_Failed='y'
        return 1
        ;;
    esac

    if ! nft add table ${FW_TABLE} 2>/dev/null; then
        Echo_Red "无法创建 nftables 表 ${FW_TABLE}，跳过防火墙配置。"
        FW_Failed='y'
        return 1
    fi
    # 重建 LNMP 专用链，防止重复安装造成规则累积。
    nft delete chain ${FW_TABLE} ${FW_CHAIN} 2>/dev/null
    if ! nft add chain ${FW_TABLE} ${FW_CHAIN} \
         '{ type filter hook input priority filter; policy accept; }' 2>/dev/null; then
        Echo_Red "无法创建 nftables 链 ${FW_TABLE} ${FW_CHAIN}，跳过防火墙配置。"
        FW_Failed='y'
        return 1
    fi

    nft add rule ${FW_TABLE} ${FW_CHAIN} iif lo accept
    nft add rule ${FW_TABLE} ${FW_CHAIN} ct state established,related accept

    return 0
}

# 放行单个端口或 20000-30000 格式的端口范围。
Firewall_Allow()
{
    Firewall_Backend
    case "${FW_Backend}" in
    firewalld)
        # firewalld 与 nft 使用相同的端口范围格式。
        firewall-cmd --permanent --add-port="$2/$1" >/dev/null 2>&1
        ;;
    nft)
        # 独立组件可能直接调用此函数，因此写入规则前需确保表和链存在。
        nft list chain ${FW_TABLE} ${FW_CHAIN} >/dev/null 2>&1 || Firewall_Init || return 1

        if ! nft add rule ${FW_TABLE} ${FW_CHAIN} "$1" dport "$2" accept 2>/dev/null; then
            Echo_Red "无法写入放行规则：$1 dport $2 accept"
            FW_Failed='y'
            return 1
        fi
        ;;
    *)
        return 1
        ;;
    esac
}

# 放行 IPv4 和 IPv6 的 ping 请求。
Firewall_Allow_ICMP()
{
    Firewall_Backend
    case "${FW_Backend}" in
    firewalld)
        # firewalld 默认允许 echo-request，无需追加规则。
        return 0
        ;;
    nft)
        nft list chain ${FW_TABLE} ${FW_CHAIN} >/dev/null 2>&1 || Firewall_Init || return 1
        nft add rule ${FW_TABLE} ${FW_CHAIN} icmp type echo-request accept 2>/dev/null
        nft add rule ${FW_TABLE} ${FW_CHAIN} icmpv6 type echo-request accept 2>/dev/null
        ;;
    *)
        return 1
        ;;
    esac
}

# 阻止外部新建连接。nft 保留回环及已建立连接，并在写入前清除同类规则；
# firewalld 通过撤销端口放行实现默认拒绝。
Firewall_Block()
{
    Firewall_Backend
    case "${FW_Backend}" in
    firewalld)
        firewall-cmd --permanent --remove-port="$2/$1" >/dev/null 2>&1
        return 0
        ;;
    nft)
        # 单独安装组件时可能尚未建立 LNMP 规则表和链。
        nft list chain ${FW_TABLE} ${FW_CHAIN} >/dev/null 2>&1 || Firewall_Init || return 1
        Firewall_Unblock "$1" "$2"

        if ! nft add rule ${FW_TABLE} ${FW_CHAIN} "$1" dport "$2" drop 2>/dev/null; then
            Echo_Red "无法写入阻断规则：$1 dport $2 drop —— 该端口可能对外可达。"
            FW_Failed='y'
            return 1
        fi
        ;;
    *)
        return 1
        ;;
    esac
}

# 撤销端口阻断；nftables 规则需先取得 handle 才能删除。
Firewall_Unblock()
{
    Firewall_Backend
    case "${FW_Backend}" in
    firewalld)
        firewall-cmd --permanent --add-port="$2/$1" >/dev/null 2>&1
        return 0
        ;;
    nft)
        local handle
        for handle in $(nft -a list chain ${FW_TABLE} ${FW_CHAIN} 2>/dev/null \
                        | grep "$1 dport $2 drop" \
                        | grep -oE 'handle [0-9]+' | awk '{print $2}'); do
            nft delete rule ${FW_TABLE} ${FW_CHAIN} handle ${handle} 2>/dev/null
        done
        ;;
    *)
        return 1
        ;;
    esac
}


# 部署并启用 lnmp-nftables.service。该单元 After/PartOf nftables.service，
# 在 nftables 启动、重启后重新加载 ${FW_INCLUDE_FILE}，因此即使用户重写
# /etc/nftables.conf 抹掉了 include 行，inet lnmp 表也不会丢失。
Firewall_Install_Unit()
{
    local src="${cur_dir}/init.d/${FW_UNIT_NAME}.service" nft_bin tmp

    Systemd_Is_Running || return 1
    [ -s "${src}" ] || return 1
    nft_bin=$(command -v nft) || return 1

    tmp=$(mktemp "${FW_UNIT_FILE}.XXXXXXXX") || return 1
    # 单元内的 nft 路径按当前系统实际位置替换。
    if ! sed "s#^\(ExecStart=\|ExecStop=-\)/usr/sbin/nft #\1${nft_bin} #" "${src}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    if ! chmod 644 "${tmp}" || ! mv -f "${tmp}" "${FW_UNIT_FILE}"; then
        rm -f "${tmp}"
        return 1
    fi

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable "${FW_UNIT_NAME}" >/dev/null 2>&1
    systemctl is-enabled "${FW_UNIT_NAME}" >/dev/null 2>&1 || return 1
    # 规则此刻已在内存中，仅登记服务状态，避免后续 restart 时被判为未启动。
    systemctl start "${FW_UNIT_NAME}" >/dev/null 2>&1
    return 0
}

# 无 systemd 单元时的退路：在主配置里补一行 include，保留其余现有内容。
Firewall_Add_Include()
{
    local main_conf=$1

    if [ -f "${main_conf}" ]; then
        grep -q "${FW_INCLUDE_FILE}" "${main_conf}" && return 0
        printf '\n%s\ninclude "%s"\n' \
            '# LNMP 安装脚本追加：加载 LNMP 自己的防火墙规则' \
            "${FW_INCLUDE_FILE}" >> "${main_conf}" || return 1
        return 0
    fi

    printf '#!/usr/sbin/nft -f\ninclude "%s"\n' "${FW_INCLUDE_FILE}" > "${main_conf}" || return 1
    chmod 600 "${main_conf}"
}

# 单元接管加载后，清除历史版本追加的 include 及其上方注释，只删本包写入的行。
Firewall_Remove_Include()
{
    local main_conf=$1 tmp

    [ -f "${main_conf}" ] || return 0
    grep -q "^include \"${FW_INCLUDE_FILE}\"" "${main_conf}" || return 0

    tmp=$(mktemp "${main_conf}.XXXXXXXX") || return 1
    if ! sed -e "\|^include \"${FW_INCLUDE_FILE}\"$|d" \
             -e '\|^# LNMP 安装脚本追加：加载 LNMP 自己的防火墙规则$|d' \
             "${main_conf}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    if ! nft -c -f "${tmp}" >/dev/null 2>&1; then
        Echo_Yellow "移除 ${main_conf} 中的 include 行后语法校验未通过，保持原样。"
        rm -f "${tmp}"
        return 1
    fi

    # 覆盖写回，保留主配置原有属主与权限。
    if ! cat "${tmp}" > "${main_conf}"; then
        rm -f "${tmp}"
        return 1
    fi
    rm -f "${tmp}"
    return 0
}

Firewall_Save()
{
    Firewall_Backend

    case "${FW_Backend}" in
    firewalld)
        if ! firewall-cmd --reload >/dev/null 2>&1; then
            Echo_Red "firewall-cmd --reload 失败，端口规则可能未生效。"
            FW_Failed='y'
            return 1
        fi
        echo "端口规则已通过 firewalld 持久化（--permanent + --reload）。"
        return 0
        ;;
    none)
        return 1
        ;;
    esac

    local main_conf tmp_file
    if [ -d /etc/sysconfig ] && [ "$PM" = "yum" ]; then
        main_conf='/etc/sysconfig/nftables.conf'
    else
        main_conf='/etc/nftables.conf'
    fi

    mkdir -p "$(dirname "${FW_INCLUDE_FILE}")"
    tmp_file="${FW_INCLUDE_FILE}.tmp.$$"

    {
        echo '#!/usr/sbin/nft -f'
        echo '# 由 LNMP 安装脚本生成，见 include/firewall.sh。'
        echo '# 本文件只定义 LNMP 自己的 inet lnmp 表，不影响系统其他防火墙规则。'
        echo '# 重新加载：nft -f '"${FW_INCLUDE_FILE}"
        echo
        echo 'table inet lnmp'
        echo 'delete table inet lnmp'
        nft list table ${FW_TABLE}
    } > "${tmp_file}" 2>/dev/null

    # 仅在规则采集完整且语法校验通过后替换持久化文件。
    if [ ! -s "${tmp_file}" ] || ! grep -q "chain ${FW_CHAIN}" "${tmp_file}"; then
        Echo_Red "采集 nftables 规则失败，未修改任何持久化文件。"
        rm -f "${tmp_file}"
        FW_Failed='y'
        return 1
    fi
    if ! nft -c -f "${tmp_file}" >/dev/null 2>&1; then
        Echo_Red "生成的规则文件语法校验（nft -c -f）未通过，未做替换。"
        rm -f "${tmp_file}"
        FW_Failed='y'
        return 1
    fi

    chmod 600 "${tmp_file}"
    if ! mv -f "${tmp_file}" "${FW_INCLUDE_FILE}"; then
        Echo_Red "写入 ${FW_INCLUDE_FILE} 失败。"
        rm -f "${tmp_file}"
        FW_Failed='y'
        return 1
    fi

    # 单元可用时由它加载规则，不改动系统主配置；不可用时才退回 include。
    if Firewall_Install_Unit; then
        systemctl enable nftables >/dev/null 2>&1
        Firewall_Remove_Include "${main_conf}"
        echo "防火墙规则已保存到 ${FW_INCLUDE_FILE}，由 ${FW_UNIT_NAME}.service 跟随 nftables 加载。"
        echo "（未改动 ${main_conf}。）"
        return 0
    fi

    Echo_Yellow "未能启用 ${FW_UNIT_NAME}.service，改为在 ${main_conf} 中 include 规则文件。"
    if ! Firewall_Add_Include "${main_conf}"; then
        Echo_Red "写入 ${main_conf} 失败，规则在重启后不会自动恢复。"
        FW_Failed='y'
        return 1
    fi

    systemctl enable nftables >/dev/null 2>&1
    if ! systemctl is-enabled nftables >/dev/null 2>&1; then
        Echo_Red "nftables 服务未能设为开机自启，规则在重启后不会自动恢复。"
        Echo_Red "规则文件已写入 ${FW_INCLUDE_FILE}，可手工执行："
        Echo_Red "  systemctl enable --now nftables"
        FW_Failed='y'
        return 1
    fi

    echo "防火墙规则已保存到 ${FW_INCLUDE_FILE}，nftables 已设为开机自启。"
    echo "（系统原有的 ${main_conf} 内容未被改动，只追加了一行 include。）"
    return 0
}

# 探测系统实际监听的 SSH 端口并存入 SSH_Ports，非法值丢弃。
# 放行规则以此为准，不再由配置指定；探测不到时不写 SSH 放行规则，
# 链策略为 accept，现有连接不受影响。
Resolve_SSH_Ports()
{
    local p

    SSH_Ports=()
    while read -r p; do
        case "${p}" in ''|*[!0-9]*) continue ;; esac
        if [ "${p}" -ge 1 ] && [ "${p}" -le 65535 ]; then
            SSH_Ports+=("${p}")
        fi
    done < <(Get_Actual_SSH_Port)

    [ ${#SSH_Ports[@]} -gt 0 ]
}

# 安装前告知防火墙将放行哪些 SSH 端口。监听 22 时提示爆破风险并要求交互确认，
# 其余情况只提示。探测不到端口不阻断安装。
Check_SSH_Port_Policy()
{
    local p ans has_22=n

    if ! Resolve_SSH_Ports; then
        Echo_Yellow "未探测到 SSH 监听端口，不写入 SSH 放行规则（链策略为 accept，不影响现有连接）。"
        return 0
    fi

    Echo_Yellow "=========================================================================="
    Echo_Yellow "防火墙将按系统实际监听放行 SSH 端口：${SSH_Ports[*]}"

    for p in "${SSH_Ports[@]}"; do
        [ "${p}" = "22" ] && has_22=y
    done
    if [ "${has_22}" != "y" ]; then
        Echo_Yellow "=========================================================================="
        return 0
    fi

    Echo_Red "其中 22 是 OpenSSH 默认端口，公网扫描器几乎全天候在扫这个端口。"
    Echo_Red "建议换成其它端口降低被爆破概率或使用证书登录："
    Echo_Red "  1. 编辑 /etc/ssh/sshd_config，把 \"#Port 22\" 改成例如 \"Port 52222\"；"
    Echo_Red "  2. systemctl restart sshd；"
    Echo_Red "  3. 保留当前连接，另开一个终端用新端口验证能登录后再关掉旧连接。"
    Echo_Red "  改完再执行本脚本，放行规则会自动跟随新端口。"
    Echo_Red "=========================================================================="

    if [ ! -t 0 ] || [ "${LNMP_Auto}" = "y" ]; then
        Echo_Yellow "非交互执行，按上述端口继续安装。"
        return 0
    fi

    read -r -p "保持默认 22 端口继续安装请输入 y；要改端口请输入其它任意键退出： " ans
    case "${ans}" in
        [yY]) return 0 ;;
        *)
            Echo_Yellow "已退出。改好 SSH 端口并测试能登录后再重新执行本命令。"
            return 1
            ;;
    esac
}

# 卸载时清除本包写入的全部防火墙内容：规则表、持久化文件、systemd 单元，
# 以及历史版本追加到主配置的 include 行。firewalld 后端只提示，不改其配置。
# addons 安装的 Redis 与 Memcached 不属于栈安装流程，重建防火墙时按实际配置
# 补回阻断规则，否则重装栈会静默丢弃这两个端口的规则。
#
# tools/lnmp-fw.sh 是独立单文件命令，运行期不保证源码目录还在，无法 source
# 本文件，因此 Resolve_Ports/Port_Redis/Port_Memcached 另有一份等价实现。
# 两份的配置路径与解析表达式由 t/consistency.sh 的 V18 检查一致性。
Block_Addons_Ports()
{
    # 测试注入点与 lnmp-fw 保持同名，默认取实际系统路径。
    local conf="${LNMP_FW_REDIS_CONF:-/usr/local/redis/etc/redis.conf}"
    local init="${LNMP_FW_MEMCACHED_INIT:-/etc/init.d/memcached}"
    local redis_dir="${LNMP_FW_REDIS_DIR:-/usr/local/redis}"
    local memcached_dir="${LNMP_FW_MEMCACHED_DIR:-/usr/local/memcached}"
    local port

    if [ -d "${redis_dir}" ] || [ -s "${conf}" ]; then
        port=''
        [ -s "${conf}" ] && port=$(awk '$1 == "port" { print $2; exit }' "${conf}" 2>/dev/null)
        [ -n "${port}" ] || port="${Redis_Port:-}"
        # port 0 表示只监听 unixsocket，没有 TCP 端口需要阻断。
        if [ -n "${port}" ] && [ "${port}" != "0" ]; then
            Firewall_Block tcp "${port}"
        fi
    fi

    if [ -s "${init}" ] || [ -d "${memcached_dir}" ]; then
        port=''
        [ -s "${init}" ] && port=$(awk -F= '$1 == "PORT" { gsub(/"/, "", $2); print $2; exit }' "${init}" 2>/dev/null)
        [ -n "${port}" ] || port="${Memcached_Port:-}"
        if [ -n "${port}" ]; then
            Firewall_Block tcp "${port}"
            Firewall_Block udp "${port}"
        fi
    fi
    return 0
}

Firewall_Purge()
{
    local main_conf rc=0

    Firewall_Backend
    if [ "${FW_Backend}" = 'firewalld' ]; then
        Echo_Yellow "检测到 firewalld，端口放行由 firewall-cmd 管理，未自动撤销。"
        Echo_Yellow "如需收回，请自行执行：firewall-cmd --permanent --remove-port=<端口>/tcp"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "${FW_UNIT_NAME}" >/dev/null 2>&1
    fi
    if [ -f "${FW_UNIT_FILE}" ] && ! rm -f "${FW_UNIT_FILE}"; then
        Echo_Red "删除 ${FW_UNIT_FILE} 失败。"
        rc=1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1
    fi

    if command -v nft >/dev/null 2>&1; then
        nft delete table ${FW_TABLE} 2>/dev/null
    fi

    if [ -f "${FW_INCLUDE_FILE}" ] && ! rm -f "${FW_INCLUDE_FILE}"; then
        Echo_Red "删除 ${FW_INCLUDE_FILE} 失败。"
        rc=1
    fi
    # 目录为本包创建，仅在没有其他规则文件时移除。
    rmdir "$(dirname "${FW_INCLUDE_FILE}")" 2>/dev/null

    if [ -d /etc/sysconfig ] && [ "$PM" = "yum" ]; then
        main_conf='/etc/sysconfig/nftables.conf'
    else
        main_conf='/etc/nftables.conf'
    fi
    Firewall_Remove_Include "${main_conf}"

    if [ ${rc} -eq 0 ]; then
        echo "已清除 ${FW_TABLE} 表、${FW_INCLUDE_FILE} 与 ${FW_UNIT_NAME}.service。"
    fi
    return ${rc}
}
