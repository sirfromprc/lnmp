#!/usr/bin/env bash

# 安装期防火墙：逐条放行、阻断与撤销。规则表常量、后端判定、链重建、规则文件持久化、
# 跟随单元与端口探测在 include/rt/fw.sh，由 include/main.sh 加载，与 lnmp fw 共用。

# 防火墙配置失败时由 end.sh 汇总提示。
FW_Failed='n'

# 未找到 nft 时用包管理器补装一次。仅供 Firewall_Init 调用，卸载路径不触发。
Firewall_Install_Nft()
{
    echo "未找到 nft，正在安装 nftables..."
    case "${PM}" in
    yum)
        yum -y install nftables >/dev/null 2>&1
        ;;
    apt)
        DEBIAN_FRONTEND=noninteractive Apt_Get --no-install-recommends install -y nftables \
            >/dev/null 2>&1
        ;;
    *)
        return 1
        ;;
    esac
    command -v nft >/dev/null 2>&1
}

# 初始化防火墙后端。firewalld 使用现有 zone；nft 使用独立的 inet lnmp
# 表和链，重建基础规则以避免重复，并保留系统中的其他规则表。
Firewall_Init()
{
    Firewall_Backend

    # 独立安装组件的依赖列表之外仍可能缺 nft，补装成功后重新判定后端。
    if [ "${FW_Backend}" = 'none' ] && Firewall_Install_Nft; then
        FW_Backend=''
        Firewall_Backend
        echo "nftables 已安装。"
    fi

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

    if ! Fw_Rebuild_Chain; then
        Echo_Red "跳过防火墙配置。"
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


# 撤销由本工具添加的放行规则。Firewall_Unblock 的语义是解除阻断，对 firewalld
# 来说恰好是放行端口，因此收回放行必须用单独的实现。
Firewall_Revoke()
{
    Firewall_Backend
    case "${FW_Backend}" in
    firewalld)
        firewall-cmd --permanent --remove-port="$2/$1" >/dev/null 2>&1
        return 0
        ;;
    nft)
        local handle
        nft list chain ${FW_TABLE} ${FW_CHAIN} >/dev/null 2>&1 || return 0
        for handle in $(nft -a list chain ${FW_TABLE} ${FW_CHAIN} 2>/dev/null \
                        | grep "$1 dport $2 accept" \
                        | grep -oE 'handle [0-9]+' | awk '{print $2}'); do
            nft delete rule ${FW_TABLE} ${FW_CHAIN} handle ${handle} 2>/dev/null
        done
        ;;
    *)
        return 1
        ;;
    esac
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

    local main_conf
    if [ -d /etc/sysconfig ] && [ "$PM" = "yum" ]; then
        main_conf='/etc/sysconfig/nftables.conf'
    else
        main_conf='/etc/nftables.conf'
    fi

    if ! Fw_Write_Rules '由 LNMP 安装脚本生成，见 include/firewall.sh。' "nft -f ${FW_INCLUDE_FILE}"; then
        Echo_Red "防火墙规则未持久化。"
        FW_Failed='y'
        return 1
    fi

    # 单元可用时由它加载规则，不改动系统主配置；不可用时才退回 include。
    if Fw_Install_Unit "${cur_dir}/init.d/${FW_UNIT_NAME}.service"; then
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
# 端口解析与 lnmp fw 共用 Fw_Redis_Port、Fw_Memcached_Port；读不到时取 lnmp.conf 的值。
Block_Addons_Ports()
{
    # 测试注入点与 lnmp-fw 保持同名，默认取实际系统路径。
    local conf="${LNMP_FW_REDIS_CONF:-/usr/local/redis/etc/redis.conf}"
    local init="${LNMP_FW_MEMCACHED_INIT:-/etc/init.d/memcached}"
    local redis_dir="${LNMP_FW_REDIS_DIR:-/usr/local/redis}"
    local memcached_dir="${LNMP_FW_MEMCACHED_DIR:-/usr/local/memcached}"
    local port

    if [ -d "${redis_dir}" ] || [ -s "${conf}" ]; then
        # port 0 表示只监听 unixsocket，没有 TCP 端口需要阻断。
        port=$(Fw_Redis_Port "${conf}" "${Redis_Port:-}") && Firewall_Block tcp "${port}"
    fi

    if [ -s "${init}" ] || [ -d "${memcached_dir}" ]; then
        if port=$(Fw_Memcached_Port "${init}" "${Memcached_Port:-}"); then
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
        # 改用 firewalld 前以 nft 后端写入的 LNMP 规则同样清除。
        [ -f "${FW_UNIT_FILE}" ] || [ -f "${FW_INCLUDE_FILE}" ] || return 0
    fi

    Fw_Purge || rc=1

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
