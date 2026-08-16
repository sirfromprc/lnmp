#!/usr/bin/env bash

FW_TABLE='inet lnmp'
FW_CHAIN='input'

# LNMP 规则单独保存在此文件，避免覆盖系统防火墙主配置。
FW_INCLUDE_FILE='/etc/nftables.d/lnmp.nft'

# 防火墙配置失败时由 end.sh 汇总提示。
FW_Failed='n'

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

    # 主配置仅在缺少引用时追加 include，保留其余现有内容。
    if [ -f "${main_conf}" ]; then
        if ! grep -q "${FW_INCLUDE_FILE}" "${main_conf}"; then
            printf '\n# LNMP 安装脚本追加：加载 LNMP 自己的防火墙规则\ninclude "%s"\n' \
                "${FW_INCLUDE_FILE}" >> "${main_conf}"
        fi
    else
        printf '#!/usr/sbin/nft -f\ninclude "%s"\n' "${FW_INCLUDE_FILE}" > "${main_conf}"
        chmod 600 "${main_conf}"
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

# 安装前核对实际 SSH 监听端口与 lnmp.conf，防止最终防火墙规则阻断远程登录。
# 端口不一致时停止安装；使用默认端口 22 时要求交互确认；非默认端口仅提示。
# 无法探测端口时以 SSH_Port 为准。非交互环境可能没有 sshd，因此只提示配置值。
Check_SSH_Port_Policy()
{
    local raw detect_rc p ans matched=n
    local -a detected=()

    if [ ! -t 0 ] || [ "${LNMP_Auto}" = "y" ]; then
        Echo_Yellow "非交互执行，跳过 SSH 端口检测，按 lnmp.conf 的 SSH_Port=${SSH_Port} 放行防火墙。"
        return 0
    fi

    raw=$(Get_Actual_SSH_Port)
    detect_rc=$?
    if [ -n "${raw}" ]; then
        while read -r p; do
            detected+=("${p}")
        done <<< "${raw}"
    fi

    if [ ${detect_rc} -ne 0 ]; then
        Echo_Yellow "未能自动探测到系统实际监听的 SSH 端口，以下按 lnmp.conf 里的"
        Echo_Yellow "SSH_Port=${SSH_Port} 处理，请自行确认这与实际使用的 SSH 端口一致。"
        matched=y
        detected=("${SSH_Port}")
    else
        for p in "${detected[@]}"; do
            [ "${p}" = "${SSH_Port}" ] && matched=y
        done
    fi

    if [ "${matched}" != "y" ]; then
        Echo_Red "======================================================================"
        Echo_Red "检测到系统当前实际监听的 SSH 端口：${detected[*]}"
        Echo_Red "lnmp.conf 里的 SSH_Port=${SSH_Port} 与之不一致。"
        Echo_Red "装完防火墙只会放行 SSH_Port 这一个端口——继续下去，真实在用的 SSH"
        Echo_Red "端口很可能没被放行，或者该挡的端口没挡住。"
        Echo_Red "请把 lnmp.conf 里的 SSH_Port 改成 ${detected[*]} 后重新执行本脚本。"
        Echo_Red "======================================================================"
        return 1
    fi

    Echo_Yellow "=========================================================================="
    Echo_Yellow "即将放行防火墙 SSH 端口：${SSH_Port}"

    if [ "${SSH_Port}" != "22" ]; then
        Echo_Yellow "=========================================================================="
        return 0
    fi

    Echo_Red "当前是 OpenSSH 默认端口 22，公网扫描器几乎全天候在扫这个端口。"
    Echo_Red "建议换成其它端口降低被爆破概率或使用证书登录："
    Echo_Red "  1. 编辑 /etc/ssh/sshd_config，把 \"#Port 22\" 改成例如 \"Port 52222\"；"
    Echo_Red "  2. systemctl restart sshd；"
    Echo_Red "  3. 保留当前连接，另开一个终端用新端口验证能登录后再关掉旧连接；"
    Echo_Red "  4. 把 lnmp.conf 里的 SSH_Port 改成同一个值。"
    Echo_Red "=========================================================================="
    read -r -p "保持默认 22 端口继续安装请输入 y；要改端口请输入其它任意键退出： " ans
    case "${ans}" in
        [yY]) return 0 ;;
        *)
            Echo_Yellow "已退出。改好 SSH 端口和 lnmp.conf 的 SSH_Port 后，并测试能登录后再重新执行本命令。"
            return 1
            ;;
    esac
}
