#!/usr/bin/env bash

FW_TABLE='inet lnmp'
FW_CHAIN='input'

# 本包只维护这一个文件，不得改写系统的防火墙主配置。
FW_INCLUDE_FILE='/etc/nftables.d/lnmp.nft'

# 供 end.sh 汇总时提示用：防火墙没配成功时置 y
FW_Failed='n'

# ---------------------------------------------------------------------------
# Firewall_Backend — 决定用哪套后端，结果放进 FW_Backend
#   firewalld / nft / none
# ---------------------------------------------------------------------------
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

Firewall_Available()
{
    Firewall_Backend
    [ "${FW_Backend}" != 'none' ]
}

# ---------------------------------------------------------------------------
# Firewall_Init — 准备后端
#
# firewalld：什么都不用建，直接用它的 zone。
# nft：建自己的表和链，并写入基础放行规则。
#      幂等：基础规则先清空再写，避免多次安装后出现重复规则。
#      只操作 `inet lnmp` 这一个表，系统其他表原样不动。
# ---------------------------------------------------------------------------
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
    # 已存在则先删掉整条链，保证规则不重复累积（只删自己这张表里的链）
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

# ---------------------------------------------------------------------------
# Firewall_Allow <proto> <port> — 放行端口
# 端口可以是 22、也可以是 20000-30000 这样的区间。
# ---------------------------------------------------------------------------
Firewall_Allow()
{
    Firewall_Backend
    case "${FW_Backend}" in
    firewalld)
        # firewalld 的区间写法是 20000-30000/tcp，与 nft 的一致
        firewall-cmd --permanent --add-port="$2/$1" >/dev/null 2>&1
        ;;
    nft)
        # pureftpd.sh 等入口会直接调本函数而不先 Firewall_Init，
        # 表/链不在时 nft add rule 会静默失败，所以这里补一次确保。
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

# ---------------------------------------------------------------------------
# Firewall_Allow_ICMP — 放行 ping
# ---------------------------------------------------------------------------
Firewall_Allow_ICMP()
{
    Firewall_Backend
    case "${FW_Backend}" in
    firewalld)
        # firewalld 默认就放行 echo-request，无需额外动作
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

# ---------------------------------------------------------------------------
# Firewall_Block <proto> <port> — 挡掉端口的外部新建连接
#
# nft 后端：链里前两条是 lo accept 与 established accept，本机访问不受影响。
#           先删同规则再加，避免重复执行时堆叠。
# firewalld：它本身就是默认拒绝，"挡掉"等价于"确保这个端口没被放行"。
# ---------------------------------------------------------------------------
Firewall_Block()
{
    Firewall_Backend
    case "${FW_Backend}" in
    firewalld)
        firewall-cmd --permanent --remove-port="$2/$1" >/dev/null 2>&1
        return 0
        ;;
    nft)
        # 表/链可能还不存在（比如只装了 memcached 没走完整 LNMP 安装）
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

# ---------------------------------------------------------------------------
# Firewall_Unblock <proto> <port> — 撤销上面那条 drop
#
# nftables 删规则要按 handle 删，故先查 handle 再删。
# ---------------------------------------------------------------------------
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

    # 采集失败会产生不完整文件；校验失败时保留原文件，不执行部分替换。
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

    # 主配置只追加一行 include，且只在确实没有的时候。已有内容一律不动。
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

# ---------------------------------------------------------------------------
# Check_SSH_Port_Policy — 装依赖/编译前，确认即将放行的 SSH 端口没问题
#
# Add_Iptables_Rules 只会放行 lnmp.conf 里 SSH_Port 这一个端口，而且它跑在
# 安装流程的最后（编译完 DB/PHP/Web 之后）——真出问题用户也只能干等几十
# 分钟到几小时后才发现。所以这一步要在真正开始装依赖前就做完：
#   1) 探测到的实际监听端口与 SSH_Port 不一致 —— 直接拒绝，让用户把
#      lnmp.conf 改对，不去猜哪个是对的；
#   2) 一致但仍是 22（OpenSSH 默认值）—— 醒目提示即将放行 22，并强制
#      二选一：继续（保持 22）或退出去改端口，不允许含糊带过；
#   3) 一致且已不是 22 —— 只提示，不阻塞；
#   4) 探测失败（没有 ss/netstat，也没找到 sshd_config）—— 没法比对，
#      按 lnmp.conf 的 SSH_Port 处理，同样走上面 2/3 的判断。
#
# 非交互（无终端或 LNMP_Auto=y）不做比对和强制二选一，只打印提示后继续，
# 不阻断已有自动化——那些场景往往是刚起的容器/CI，没有真实 sshd。
# ---------------------------------------------------------------------------
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
