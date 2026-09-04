#!/usr/bin/env bash
#
# LNMP 防火墙对齐工具，通过 `lnmp fw <子命令>` 使用。
# 安装路径为 /bin/lnmp-fw，lnmp、lnmpa 和 lamp 管理命令共用该工具。
#
#   lnmp fw status                     对比服务配置、nftables 规则与 lnmp.conf
#   lnmp fw sync                       按服务配置重建规则，并回写 lnmp.conf
#   lnmp fw allow   {tcp|udp} <端口>   放行端口，写入 fw.conf 后重建
#   lnmp fw block   {tcp|udp} <端口>   阻断端口，写入 fw.conf 后重建
#   lnmp fw unblock {tcp|udp} <端口>   移除 fw.conf 中的对应条目后重建
#   lnmp fw reload                     重新加载已持久化的规则，不重算端口
#   lnmp fw purge                      清除本包写入的全部防火墙内容
#
# ---------------------------------------------------------------------------
# 职责边界
#
# 端口有三份副本：lnmp.conf（重装时的真值）、服务配置（运行时的真值）、
# nftables 规则（派生结果）。本工具以服务配置为输入，写 nftables 规则，并把
# lnmp.conf 的端口变量回写成同一个值，使三者收敛。
#
# 本工具不修改任何服务配置文件。改端口的正确顺序是先改服务配置并重启服务，
# 再执行 sync；只对齐防火墙而不重装服务，用 sync，不要重跑 addons.sh。
# ---------------------------------------------------------------------------

set -u

# 与 include/firewall.sh 保持一致，两处取值不同会导致规则表分裂。
FW_TABLE='inet lnmp'
FW_CHAIN='input'
FW_INCLUDE_FILE="${LNMP_FW_NFT_FILE:-/etc/nftables.d/lnmp.nft}"
FW_UNIT_NAME='lnmp-nftables'
FW_UNIT_FILE="/etc/systemd/system/${FW_UNIT_NAME}.service"

# 测试注入点：默认取实际系统路径。
Fw_Conf="${LNMP_FW_CONF:-/etc/lnmp/fw.conf}"
# firewalld 后端记录本工具放行过的端口，供下次 sync 收回不再需要的项。
Fw_Firewalld_Ports="${LNMP_FW_FIREWALLD_PORTS:-/etc/lnmp/firewalld-ports}"
Source_Dir_File="${LNMP_FW_SOURCE_DIR_FILE:-/etc/lnmp/source-dir}"
Redis_Conf="${LNMP_FW_REDIS_CONF:-/usr/local/redis/etc/redis.conf}"
Memcached_Init="${LNMP_FW_MEMCACHED_INIT:-/etc/init.d/memcached}"
My_Cnf="${LNMP_FW_MYCNF:-/etc/my.cnf}"
Pureftpd_Conf="${LNMP_FW_PUREFTPD_CONF:-/usr/local/pureftpd/etc/pure-ftpd.conf}"
Nginx_Dir="${LNMP_FW_NGINX_DIR:-/usr/local/nginx}"
Openresty_Dir="${LNMP_FW_OPENRESTY_DIR:-/usr/local/openresty/nginx}"
Apache_Dir="${LNMP_FW_APACHE_DIR:-/usr/local/apache}"
Mysql_Dir="${LNMP_FW_MYSQL_DIR:-/usr/local/mysql}"
Mariadb_Dir="${LNMP_FW_MARIADB_DIR:-/usr/local/mariadb}"
Redis_Dir="${LNMP_FW_REDIS_DIR:-/usr/local/redis}"
Memcached_Dir="${LNMP_FW_MEMCACHED_DIR:-/usr/local/memcached}"
Pureftpd_Dir="${LNMP_FW_PUREFTPD_DIR:-/usr/local/pureftpd}"

# lnmp.conf 路径由 --conf 或 source-dir 决定，解析结果存这里。
Lnmp_Conf=''

# fw.conf 与 lnmp.conf 备份仅 root 可读。
umask 077

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
Color() { if [ -t 1 ]; then printf '\033[%sm%s\033[0m\n' "$1" "$2"; else printf '%s\n' "$2"; fi; }
Say()   { printf '%s\n' "$*"; }
Warn()  { Color "0;33" "$*"; }
Err()   { Color "0;31" "$*" >&2; }
Ok()    { Color "0;32" "$*"; }

Usage()
{
    cat <<'EOF'
用法：lnmp fw {status|sync|allow|block|unblock|reload|purge}
      lnmp fw {allow|block|unblock} {tcp|udp} <端口|起-止>

  status    对比服务配置、nftables 规则与 lnmp.conf，不改动任何内容；
            存在不一致时返回 1
  sync      按服务当前配置重建规则并持久化，同时回写 lnmp.conf 的端口变量
  allow     放行端口，条目写入 fw.conf 后重建规则
  block     阻断端口，条目写入 fw.conf 后重建规则
  unblock   从 fw.conf 移除对应条目后重建规则
  reload    重新加载已持久化的规则，不重算端口
  purge     清除本包写入的规则表、规则文件与 systemd 单元

  --conf <路径>   指定 lnmp.conf 位置，默认取自 /etc/lnmp/source-dir
  --yes           purge 在非交互执行时需要该参数
EOF
}

# ---------------------------------------------------------------------------
# 通用校验
# ---------------------------------------------------------------------------
Valid_Port()
{
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 接受单端口或 20000-30000 形式的范围。
Valid_Port_Spec()
{
    local spec="$1" lo hi
    case "${spec}" in
    *-*)
        lo=${spec%%-*}
        hi=${spec##*-}
        Valid_Port "${lo}" && Valid_Port "${hi}" && [ "${lo}" -le "${hi}" ]
        ;;
    *)
        Valid_Port "${spec}"
        ;;
    esac
}

Valid_Proto()
{
    case "$1" in tcp|udp) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# 防火墙后端
# ---------------------------------------------------------------------------
FW_Backend=''

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

Chain_Dump()
{
    nft list chain ${FW_TABLE} ${FW_CHAIN} 2>/dev/null
}

# ---------------------------------------------------------------------------
# 端口解析：一律以服务配置文件为准，服务未安装则不产出规则
# ---------------------------------------------------------------------------
Has_DB='n';        P_DB='';        P_DB_X=''
Has_Redis='n';     P_Redis=''
Has_Memcached='n'; P_Memcached=''
Has_Ftp='n';       P_Ftp_Ctl='';   P_Ftp_Data=''; P_Ftp_Pasv=''
P_Http=()
SSH_Ports=()

# my.cnf 的 [mysqld] 段可能多次出现 port，取最后一个生效值。
Port_DB()
{
    local port
    port=$(awk '
        /^[[:space:]]*\[/ {
            section = $0
            sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
            sub(/[[:space:]]*\].*$/, "", section)
            next
        }
        section == "mysqld" && /^[[:space:]]*port[[:space:]]*=/ {
            value = $0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            sub(/[[:space:]#].*$/, "", value)
            if (value != "") last = value
        }
        END { if (last != "") print last }
    ' "${My_Cnf}" 2>/dev/null)
    Valid_Port "${port}" && printf '%s\n' "${port}"
}

# MariaDB 不使用 X Protocol，配置里没有该项时不产出规则。
Port_DB_X()
{
    local port
    port=$(awk '
        /^[[:space:]]*\[/ {
            section = $0
            sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
            sub(/[[:space:]]*\].*$/, "", section)
            next
        }
        section == "mysqld" && /^[[:space:]]*(loose-)?mysqlx-port[[:space:]]*=/ {
            value = $0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            sub(/[[:space:]#].*$/, "", value)
            if (value != "") last = value
        }
        END { if (last != "") print last }
    ' "${My_Cnf}" 2>/dev/null)
    Valid_Port "${port}" && printf '%s\n' "${port}"
}

# port 0 表示只监听 unixsocket，没有 TCP 端口需要阻断。
Port_Redis()
{
    local port
    port=$(awk '$1 == "port" { print $2; exit }' "${Redis_Conf}" 2>/dev/null)
    [ "${port}" = "0" ] && return 1
    Valid_Port "${port}" || port=6379
    printf '%s\n' "${port}"
}

Port_Memcached()
{
    local port
    port=$(awk -F= '$1 == "PORT" { gsub(/"/, "", $2); print $2; exit }' \
           "${Memcached_Init}" 2>/dev/null)
    Valid_Port "${port}" || port=11211
    printf '%s\n' "${port}"
}

# Bind 形如 0.0.0.0,21；PassivePortRange 形如 20000 30000。
Resolve_Ftp_Ports()
{
    local ctl pasv_lo pasv_hi

    ctl=$(awk '$1 == "Bind" { sub(/^.*,/, "", $2); print $2; exit }' "${Pureftpd_Conf}" 2>/dev/null)
    Valid_Port "${ctl}" || ctl=21
    pasv_lo=$(awk '$1 == "PassivePortRange" { print $2; exit }' "${Pureftpd_Conf}" 2>/dev/null)
    pasv_hi=$(awk '$1 == "PassivePortRange" { print $3; exit }' "${Pureftpd_Conf}" 2>/dev/null)
    Valid_Port "${pasv_lo}" && Valid_Port "${pasv_hi}" && [ "${pasv_lo}" -le "${pasv_hi}" ] || {
        pasv_lo=20000
        pasv_hi=30000
    }

    P_Ftp_Ctl="${ctl}"
    # pure-ftpd.conf 不记录主动模式数据端口，唯一来源是 lnmp.conf；读不到用 20。
    P_Ftp_Data=''
    Resolve_Lnmp_Conf && P_Ftp_Data=$(Read_Lnmp_Conf_Port "${Lnmp_Conf}" Pureftpd_Data_Port)
    Valid_Port "${P_Ftp_Data}" || P_Ftp_Data=20
    P_Ftp_Pasv="${pasv_lo}-${pasv_hi}"
}

# 解析 nginx / apache 的监听端口；取不到时退回 80 443。
Resolve_Http_Ports()
{
    local dir f port
    local -a files=()

    for dir in "${Nginx_Dir}" "${Openresty_Dir}"; do
        [ -d "${dir}/conf" ] || continue
        files+=("${dir}/conf/nginx.conf")
        for f in "${dir}/conf/vhost/"*.conf; do
            [ -s "${f}" ] && files+=("${f}")
        done
    done
    if [ -d "${Apache_Dir}/conf" ]; then
        files+=("${Apache_Dir}/conf/httpd.conf")
        for f in "${Apache_Dir}/conf/extra/"*.conf "${Apache_Dir}/conf/vhost/"*.conf; do
            [ -s "${f}" ] && files+=("${f}")
        done
    fi

    # 80/443 由主配置、站点配置和证书流程共同管理，与安装期一样无条件放行，
    # 避免站点暂时没有 443 配置时把已有放行规则删掉。
    P_Http=(80 443)
    while read -r port; do
        Valid_Port "${port}" || continue
        case " ${P_Http[*]} " in *" ${port} "*) continue ;; esac
        P_Http+=("${port}")
    done < <(
        for f in "${files[@]-}"; do
            [ -s "${f}" ] || continue
            # listen 80; listen [::]:443 ssl; listen 127.0.0.1:8080; Listen 0.0.0.0:80
            # 先去掉注释，再匹配指令本身，避免注释掉的 listen 也被放行。
            sed -e 's/#.*//' "${f}" 2>/dev/null \
                | grep -hEio '(^|[;{[:space:]])listen[[:space:]]+[^;{]+' \
                | sed -E 's/^.*[Ll]isten[[:space:]]+//' \
                | awk '{ print $1 }' \
                | grep -vE '^(127\.|\[::1\]:|localhost:)' \
                | sed -E 's/.*://; s/[^0-9].*$//'
        done | sort -un
    )
}

# SSH 例外：以实际监听优先，探测不到才读配置。放行错端口会把自己关在门外。
Resolve_SSH_Ports()
{
    local port

    SSH_Ports=()
    # ss 会把同一端口的 IPv4 与 IPv6 监听各报一次，必须去重，否则规则重复写入。
    if command -v ss >/dev/null 2>&1; then
        while read -r port; do
            Valid_Port "${port}" && SSH_Ports+=("${port}")
        done < <(ss -Htlnp 2>/dev/null | grep -F 'sshd' | awk '{print $4}' \
                 | sed -E 's/.*://' | sort -un)
    fi
    if [ ${#SSH_Ports[@]} -eq 0 ] && command -v netstat >/dev/null 2>&1; then
        while read -r port; do
            Valid_Port "${port}" && SSH_Ports+=("${port}")
        done < <(netstat -tlnp 2>/dev/null | grep -F 'sshd' | awk '{print $4}' \
                 | sed -E 's/.*://' | sort -un)
    fi
    if [ ${#SSH_Ports[@]} -eq 0 ]; then
        while read -r port; do
            Valid_Port "${port}" && SSH_Ports+=("${port}")
        done < <(
            for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
                [ -s "${f}" ] || continue
                grep -Eio '^[[:space:]]*Port[[:space:]]+[0-9]+' "${f}" 2>/dev/null | awk '{print $2}'
            done | sort -un
        )
        [ ${#SSH_Ports[@]} -eq 0 ] && [ -s /etc/ssh/sshd_config ] && SSH_Ports=(22)
    fi
}

Resolve_Ports()
{
    if [ -d "${Mysql_Dir}" ] || [ -d "${Mariadb_Dir}" ] || [ -s "${My_Cnf}" ]; then
        P_DB=$(Port_DB)
        [ -z "${P_DB}" ] && P_DB=3306
        # MariaDB 没有 X Protocol，配置里没有该项就不写规则。
        P_DB_X=$(Port_DB_X)
        Has_DB='y'
    fi
    if [ -d "${Redis_Dir}" ] || [ -s "${Redis_Conf}" ]; then
        Has_Redis='y'
        P_Redis=$(Port_Redis) || P_Redis=''
    fi
    if [ -s "${Memcached_Init}" ] || [ -d "${Memcached_Dir}" ]; then
        Has_Memcached='y'
        P_Memcached=$(Port_Memcached)
    fi
    if [ -d "${Pureftpd_Dir}" ] || [ -s "${Pureftpd_Conf}" ]; then
        Has_Ftp='y'
        Resolve_Ftp_Ports
    fi
    Resolve_Http_Ports
    Resolve_SSH_Ports
}

# ---------------------------------------------------------------------------
# /etc/lnmp/fw.conf：allow/block 写入的自定义条目
# ---------------------------------------------------------------------------
Custom_Rules=()

Load_Fw_Conf()
{
    local line action proto spec lineno=0

    Custom_Rules=()
    [ -s "${Fw_Conf}" ] || return 0

    while IFS= read -r line || [ -n "${line}" ]; do
        lineno=$((lineno + 1))
        case "${line}" in ''|'#'*) continue ;; esac
        # shellcheck disable=SC2086
        set -- ${line}
        if [ $# -ne 3 ]; then
            Warn "${Fw_Conf} 第 ${lineno} 行格式不是「动作 协议 端口」，已跳过：${line}"
            continue
        fi
        action="$1"; proto="$2"; spec="$3"
        case "${action}" in allow|block) ;; *)
            Warn "${Fw_Conf} 第 ${lineno} 行动作只能是 allow 或 block，已跳过：${line}"
            continue
            ;;
        esac
        if ! Valid_Proto "${proto}"; then
            Warn "${Fw_Conf} 第 ${lineno} 行协议只能是 tcp 或 udp，已跳过：${line}"
            continue
        fi
        if ! Valid_Port_Spec "${spec}"; then
            Warn "${Fw_Conf} 第 ${lineno} 行端口不合法，已跳过：${line}"
            continue
        fi
        Custom_Rules+=("${action} ${proto} ${spec}")
    done < "${Fw_Conf}"
    return 0
}

# 写入 fw.conf。同一「协议 端口」只保留一条，动作以本次为准。
Write_Fw_Conf()
{
    local action="$1" proto="$2" spec="$3" tmp rule
    local -a kept=()

    for rule in ${Custom_Rules[@]+"${Custom_Rules[@]}"}; do
        case "${rule}" in
        "allow ${proto} ${spec}"|"block ${proto} ${spec}") continue ;;
        esac
        kept+=("${rule}")
    done
    [ "${action}" = 'remove' ] || kept+=("${action} ${proto} ${spec}")

    mkdir -p "$(dirname "${Fw_Conf}")" || return 1
    tmp=$(mktemp "${Fw_Conf}.XXXXXXXX") || return 1
    {
        echo '# 由 lnmp fw allow/block/unblock 维护，手工编辑同样有效。'
        echo '# 格式：allow|block  tcp|udp  端口或 起-止'
        echo '# sync 重建规则时，这些条目排在标准规则之前，显式意图优先。'
        printf '%s\n' ${kept[@]+"${kept[@]}"}
    } > "${tmp}" || { rm -f "${tmp}"; return 1; }
    chmod 600 "${tmp}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "${Fw_Conf}" || { rm -f "${tmp}"; return 1; }
    Custom_Rules=(${kept[@]+"${kept[@]}"})
    return 0
}

# ---------------------------------------------------------------------------
# 规则计划：先产出纯文本计划再执行，便于定向测试比对顺序
# ---------------------------------------------------------------------------
# 计划行格式：
#   base lo | base ct | base icmp
#   accept <proto> <端口>
#   drop   <proto> <端口>
Plan_Rules()
{
    local rule port

    echo 'base lo'
    echo 'base ct'

    # 自定义条目排在标准规则之前，使其能覆盖标准阻断。
    for rule in ${Custom_Rules[@]+"${Custom_Rules[@]}"}; do
        set -- ${rule}
        case "$1" in
        allow) echo "accept $2 $3" ;;
        block) echo "drop $2 $3" ;;
        esac
    done

    for port in ${SSH_Ports[@]+"${SSH_Ports[@]}"}; do
        echo "accept tcp ${port}"
    done
    for port in ${P_Http[@]+"${P_Http[@]}"}; do
        echo "accept tcp ${port}"
    done
    if [ "${Has_Ftp}" = 'y' ]; then
        echo "accept tcp ${P_Ftp_Data}"
        echo "accept tcp ${P_Ftp_Ctl}"
        echo "accept tcp ${P_Ftp_Pasv}"
    fi

    echo 'base icmp'

    if [ "${Has_DB}" = 'y' ]; then
        echo "drop tcp ${P_DB}"
        [ -n "${P_DB_X}" ] && echo "drop tcp ${P_DB_X}"
    fi
    if [ "${Has_Redis}" = 'y' ] && [ -n "${P_Redis}" ]; then
        echo "drop tcp ${P_Redis}"
    fi
    if [ "${Has_Memcached}" = 'y' ]; then
        echo "drop tcp ${P_Memcached}"
        echo "drop udp ${P_Memcached}"
    fi
}

# 计划中由本工具产出的标准阻断端口，供 status 判断漂移。
Planned_Drops()
{
    Plan_Rules | awk '$1 == "drop" { print $2 " " $3 }'
}

# ---------------------------------------------------------------------------
# 应用规则
# ---------------------------------------------------------------------------
Rebuild_Chain()
{
    if ! nft add table ${FW_TABLE} 2>/dev/null; then
        Err "无法创建 nftables 表 ${FW_TABLE}。"
        return 1
    fi
    # 删链重建，避免重复执行造成规则累积。
    nft delete chain ${FW_TABLE} ${FW_CHAIN} 2>/dev/null
    if ! nft add chain ${FW_TABLE} ${FW_CHAIN} \
         '{ type filter hook input priority filter; policy accept; }' 2>/dev/null; then
        Err "无法创建 nftables 链 ${FW_TABLE} ${FW_CHAIN}。"
        return 1
    fi
    return 0
}

Apply_Plan()
{
    local line rc=0

    while read -r line; do
        set -- ${line}
        case "$1" in
        base)
            case "$2" in
            lo)   nft add rule ${FW_TABLE} ${FW_CHAIN} iif lo accept 2>/dev/null || rc=1 ;;
            ct)   nft add rule ${FW_TABLE} ${FW_CHAIN} ct state established,related accept 2>/dev/null || rc=1 ;;
            icmp)
                nft add rule ${FW_TABLE} ${FW_CHAIN} icmp type echo-request accept 2>/dev/null || rc=1
                nft add rule ${FW_TABLE} ${FW_CHAIN} icmpv6 type echo-request accept 2>/dev/null || rc=1
                ;;
            esac
            ;;
        accept|drop)
            if ! nft add rule ${FW_TABLE} ${FW_CHAIN} "$2" dport "$3" "$1" 2>/dev/null; then
                Err "无法写入规则：$2 dport $3 $1"
                rc=1
            fi
            ;;
        esac
    done
    return ${rc}
}

# 从内核导出当前表并落盘，与 include/firewall.sh 的 Firewall_Save 同构。
Save_Rules()
{
    local tmp

    mkdir -p "$(dirname "${FW_INCLUDE_FILE}")" || return 1
    tmp="${FW_INCLUDE_FILE}.tmp.$$"
    {
        echo '#!/usr/sbin/nft -f'
        echo '# 由 lnmp fw 生成，见 tools/lnmp-fw.sh。'
        echo '# 本文件只定义 LNMP 自己的 inet lnmp 表，不影响系统其他防火墙规则。'
        echo '# 重新加载：lnmp fw reload'
        echo
        echo 'table inet lnmp'
        echo 'delete table inet lnmp'
        nft list table ${FW_TABLE}
    } > "${tmp}" 2>/dev/null

    if [ ! -s "${tmp}" ] || ! grep -q "chain ${FW_CHAIN}" "${tmp}"; then
        Err "采集 nftables 规则失败，未修改 ${FW_INCLUDE_FILE}。"
        rm -f "${tmp}"
        return 1
    fi
    if ! nft -c -f "${tmp}" >/dev/null 2>&1; then
        Err "生成的规则文件语法校验未通过，未修改 ${FW_INCLUDE_FILE}。"
        rm -f "${tmp}"
        return 1
    fi
    chmod 600 "${tmp}" || { rm -f "${tmp}"; return 1; }
    if ! mv -f "${tmp}" "${FW_INCLUDE_FILE}"; then
        Err "写入 ${FW_INCLUDE_FILE} 失败。"
        rm -f "${tmp}"
        return 1
    fi
    # 单元缺失时按随包模板补回，purge 之后 sync 才能完整重建。
    if Install_Fw_Unit; then
        systemctl enable nftables >/dev/null 2>&1
    else
        Warn "未能启用 ${FW_UNIT_NAME}.service，规则在重启后可能不会自动恢复。"
        Warn "确认 nftables 已开机自启：systemctl enable --now nftables"
    fi
    return 0
}

# 记录的源码目录，用于定位 lnmp.conf 与随包的 systemd 单元模板。
Source_Dir()
{
    local dir
    [ -s "${Source_Dir_File}" ] || return 1
    dir=$(head -1 "${Source_Dir_File}")
    [ -n "${dir}" ] && [ -d "${dir}" ] || return 1
    printf '%s\n' "${dir}"
}

# purge 会删掉单元，重建时需要补回，否则规则重启后不再加载。
# 与 include/firewall.sh 的 Firewall_Install_Unit 同构，模板取自记录的源码目录。
Install_Fw_Unit()
{
    local src tmp nft_bin dir

    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || return 1
    if [ ! -s "${FW_UNIT_FILE}" ]; then
        dir=$(Source_Dir) || return 1
        src="${dir}/init.d/${FW_UNIT_NAME}.service"
        [ -s "${src}" ] || return 1
        nft_bin=$(command -v nft) || return 1
        tmp=$(mktemp "${FW_UNIT_FILE}.XXXXXXXX") || return 1
        # 单元内的 nft 路径按当前系统实际位置替换。
        if ! sed "s#^\\(ExecStart=\\|ExecStop=-\\)/usr/sbin/nft #\\1${nft_bin} #" "${src}" > "${tmp}" \
           || ! chmod 644 "${tmp}" || ! mv -f "${tmp}" "${FW_UNIT_FILE}"; then
            rm -f "${tmp}"
            return 1
        fi
        systemctl daemon-reload >/dev/null 2>&1
    fi
    systemctl enable "${FW_UNIT_NAME}" >/dev/null 2>&1
    systemctl is-enabled "${FW_UNIT_NAME}" >/dev/null 2>&1 || return 1
    # 规则此刻已在内存中，仅登记服务状态，避免后续 restart 时被判为未启动。
    systemctl start "${FW_UNIT_NAME}" >/dev/null 2>&1
    return 0
}

# ---------------------------------------------------------------------------
# 回写 lnmp.conf
# ---------------------------------------------------------------------------
# 定位 lnmp.conf：--conf 优先，其次 /etc/lnmp/source-dir 记录的源码目录。
Resolve_Lnmp_Conf()
{
    local dir

    [ -n "${Lnmp_Conf}" ] && return 0
    dir=$(Source_Dir) || return 1
    [ -s "${dir}/lnmp.conf" ] || return 1
    Lnmp_Conf="${dir}/lnmp.conf"
    return 0
}

# 读取 lnmp.conf 中 VAR="${VAR:-数字}" 的默认值。
Read_Lnmp_Conf_Port()
{
    awk -v v="$2" '
        {
            pre = v "=\"${" v ":-"
            if (substr($0, 1, length(pre)) == pre) {
                rest = substr($0, length(pre) + 1)
                if (rest ~ /^[0-9]+\}"$/) { sub(/\}"$/, "", rest); print rest; exit }
            }
        }
    ' "$1" 2>/dev/null
}

# 待回写项由 Collect_Conf_Pairs 产出，格式为 "变量名 期望值"。
Collect_Conf_Pairs()
{
    [ "${Has_DB}" = 'y' ] && [ -n "${P_DB}" ] && echo "DB_Port ${P_DB}"
    [ "${Has_DB}" = 'y' ] && [ -n "${P_DB_X}" ] && echo "DB_X_Port ${P_DB_X}"
    [ "${Has_Redis}" = 'y' ] && [ -n "${P_Redis}" ] && echo "Redis_Port ${P_Redis}"
    [ "${Has_Memcached}" = 'y' ] && echo "Memcached_Port ${P_Memcached}"
    if [ "${Has_Ftp}" = 'y' ]; then
        echo "Pureftpd_Port ${P_Ftp_Ctl}"
        echo "Pureftpd_Passive_Min ${P_Ftp_Pasv%%-*}"
        echo "Pureftpd_Passive_Max ${P_Ftp_Pasv##*-}"
    fi
    return 0
}

# 只替换 VAR="${VAR:-旧值}" 整行，注释与其它内容不动。
Sync_Lnmp_Conf()
{
    local var want cur tmp backup item changed=0
    local -a pending=()

    if ! Resolve_Lnmp_Conf; then
        Warn "未找到 lnmp.conf，本次只对齐了防火墙；重装前请自行核对 lnmp.conf 的端口。"
        return 0
    fi
    if [ ! -w "${Lnmp_Conf}" ]; then
        Warn "${Lnmp_Conf} 不可写，本次只对齐了防火墙。"
        return 0
    fi

    while read -r var want; do
        [ -n "${var}" ] || continue
        cur=$(Read_Lnmp_Conf_Port "${Lnmp_Conf}" "${var}")
        if [ -z "${cur}" ]; then
            Warn "${Lnmp_Conf} 中未找到 ${var} 的标准写法，跳过该项回写。"
            continue
        fi
        [ "${cur}" = "${want}" ] && continue
        pending+=("${var} ${cur} ${want}")
    done < <(Collect_Conf_Pairs)

    [ ${#pending[@]} -eq 0 ] && return 0

    backup="${Lnmp_Conf}.bak.$(date +%Y%m%d%H%M%S)"
    if ! cp -p "${Lnmp_Conf}" "${backup}"; then
        Err "备份 ${Lnmp_Conf} 失败，未回写。"
        return 1
    fi

    for item in "${pending[@]}"; do
        set -- ${item}
        var="$1"; cur="$2"; want="$3"
        tmp=$(mktemp "${Lnmp_Conf}.XXXXXXXX") || return 1
        if ! awk -v o="${var}=\"\${${var}:-${cur}}\"" \
                 -v n="${var}=\"\${${var}:-${want}}\"" \
                 '$0 == o { print n; next } { print }' "${Lnmp_Conf}" > "${tmp}"; then
            rm -f "${tmp}"
            Err "改写 ${var} 失败，已保留备份 ${backup}。"
            return 1
        fi
        if ! cat "${tmp}" > "${Lnmp_Conf}"; then
            rm -f "${tmp}"
            Err "写回 ${Lnmp_Conf} 失败，可从 ${backup} 恢复。"
            return 1
        fi
        rm -f "${tmp}"
        if [ "$(Read_Lnmp_Conf_Port "${Lnmp_Conf}" "${var}")" != "${want}" ]; then
            Err "${var} 回读校验失败，可从 ${backup} 恢复。"
            return 1
        fi
        Say "lnmp.conf: ${var} ${cur} -> ${want}"
        changed=1
    done

    [ ${changed} -eq 1 ] && Say "已备份原文件：${backup}"
    return 0
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------
Require_Root()
{
    [ "$(id -u)" = "0" ] && return 0
    Err "需要 root 权限执行。"
    return 1
}

Cmd_Sync()
{
    Firewall_Backend
    Resolve_Ports
    Load_Fw_Conf

    case "${FW_Backend}" in
    none)
        Err "未找到 nft 与 firewall-cmd，无法配置防火墙。"
        return 1
        ;;
    firewalld)
        Sync_Firewalld || return 1
        Sync_Lnmp_Conf
        return 0
        ;;
    esac

    Rebuild_Chain || return 1
    if ! Plan_Rules | Apply_Plan; then
        Err "部分规则写入失败，请核对 nft list table ${FW_TABLE} 的输出。"
        return 1
    fi
    Save_Rules || return 1
    Ok "防火墙规则已按当前服务配置重建，并保存到 ${FW_INCLUDE_FILE}。"
    Sync_Lnmp_Conf
    return 0
}

# firewalld 下只维护端口放行，阻断由该端口不在放行列表实现。
#
# 计划里同一端口可能既有自定义项又有标准项。nft 侧靠首条匹配让自定义项生效，
# firewalld 没有这个语义，逐行执行会让后出现的标准项覆盖前面的自定义意图，
# 因此先按「协议 端口」归并成唯一动作，仍取计划中首次出现的那条。
Merge_Firewalld_Plan()
{
    Plan_Rules | awk '
        $1 == "accept" || $1 == "drop" {
            key = $2 " " $3
            if (!(key in seen)) { seen[key] = 1; print $1 " " $2 " " $3 }
        }'
}

# 读取上次由本工具放行的端口集合。文件不存在按空集处理。
Load_Firewalld_Owned()
{
    local line
    [ -s "${Fw_Firewalld_Ports}" ] || return 0
    while read -r line; do
        case "${line}" in ''|\#*) continue ;; esac
        printf '%s\n' "${line}"
    done < "${Fw_Firewalld_Ports}"
}

Save_Firewalld_Owned()
{
    local tmp
    mkdir -p "$(dirname "${Fw_Firewalld_Ports}")" || return 1
    tmp=$(mktemp "${Fw_Firewalld_Ports}.XXXXXXXX") || return 1
    {
        echo '# 由 lnmp fw 维护的 firewalld 放行端口，格式：协议 端口'
        cat
    } > "${tmp}" || { rm -f "${tmp}"; return 1; }
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${Fw_Firewalld_Ports}" || { rm -f "${tmp}"; return 1; }
    return 0
}

Sync_Firewalld()
{
    local plan wanted stale line proto port rc=0 state

    plan=$(Merge_Firewalld_Plan)
    wanted=$(printf '%s\n' "${plan}" | awk '$1 == "accept" { print $2 " " $3 }' | sort -u)

    # 上次放行、本次计划里已经没有的端口要收回，否则改端口或 unblock 之后
    # 旧端口会永久留在 firewalld 里。
    stale=$(comm -23 <(Load_Firewalld_Owned | sort -u) <(printf '%s\n' "${wanted}" | sed '/^$/d'))
    while read -r proto port; do
        [ -n "${port}" ] || continue
        firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1
    done <<< "${stale}"

    while read -r line; do
        [ -n "${line}" ] || continue
        set -- ${line}
        case "$1" in
        accept) firewall-cmd --permanent --add-port="$3/$2" >/dev/null 2>&1 || rc=1 ;;
        drop)   firewall-cmd --permanent --remove-port="$3/$2" >/dev/null 2>&1 ;;
        esac
    done <<< "${plan}"

    if ! firewall-cmd --reload >/dev/null 2>&1; then
        Err "firewall-cmd --reload 失败，端口规则可能未生效。"
        return 1
    fi

    # 回读每个端口的实际状态，不能只看 add/remove 的返回值。
    while read -r line; do
        [ -n "${line}" ] || continue
        set -- ${line}
        state='no'
        firewall-cmd --query-port="$3/$2" >/dev/null 2>&1 && state='yes'
        case "$1" in
        accept) [ "${state}" = 'yes' ] || { Err "端口 $3/$2 应放行，回读结果是未放行。"; rc=1; } ;;
        drop)   [ "${state}" = 'no' ]  || { Err "端口 $3/$2 应阻断，回读结果仍是放行。"; rc=1; } ;;
        esac
    done <<< "${plan}"

    if [ ${rc} -ne 0 ]; then
        Err "firewalld 端口状态与预期不一致，请核对 firewall-cmd --list-ports。"
        return 1
    fi

    if ! printf '%s\n' "${wanted}" | sed '/^$/d' | Save_Firewalld_Owned; then
        Warn "写入 ${Fw_Firewalld_Ports} 失败，下次 sync 无法收回本次放行的端口。"
    fi
    Ok "端口规则已通过 firewalld 持久化。"
    return 0
}

Status_Line()
{
    printf '  %-12s %-14s %-14s %-12s %s\n' "$1" "$2" "$3" "$4" "$5"
}

# 中文按显示宽度占两列，%-Ns 按字节补齐会错位，表头手工排版。
Status_Header()
{
    printf '  服务         配置端口       防火墙         lnmp.conf    判定\n'
}

# 规则文件与内核输出的缩进和外层结构不同，只比对规则正文。
Normalize_Rules()
{
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -E '(accept|drop)$'
}

Cmd_Status()
{
    local dump rc=0 cur_conf rule_state verdict
    local svc proto port

    Firewall_Backend
    Resolve_Ports
    Load_Fw_Conf

    Say "防火墙后端：${FW_Backend}"
    if [ "${FW_Backend}" != 'nft' ]; then
        [ "${FW_Backend}" = 'none' ] && { Err "未找到 nft 与 firewall-cmd。"; return 1; }
        Say "firewalld 放行端口：$(firewall-cmd --list-ports 2>/dev/null)"
        return 0
    fi

    dump=$(Chain_Dump)
    if [ -z "${dump}" ]; then
        Warn "规则表 ${FW_TABLE} 不存在，执行 lnmp fw sync 建立。"
        rc=1
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        local unit_enabled unit_active
        unit_enabled=$(systemctl is-enabled "${FW_UNIT_NAME}" 2>/dev/null)
        unit_active=$(systemctl is-active "${FW_UNIT_NAME}" 2>/dev/null)
        Say "${FW_UNIT_NAME}.service：${unit_enabled:-未部署}/${unit_active:-inactive}"
    fi
    if Resolve_Lnmp_Conf; then
        Say "lnmp.conf：${Lnmp_Conf}"
    else
        Warn "未找到 lnmp.conf（/etc/lnmp/source-dir 缺失或源码目录已移动），不检查重装端口。"
    fi

    Say ""
    Status_Header

    while read -r svc proto port; do
        rule_state='-'
        printf '%s' "${dump}" | grep -qE "[[:space:]]${proto} dport ${port} drop([[:space:]]|$)" \
            && rule_state="drop ${port}"
        cur_conf='-'
        case "${svc}" in
        mysql)     [ -n "${Lnmp_Conf}" ] && cur_conf=$(Read_Lnmp_Conf_Port "${Lnmp_Conf}" DB_Port) ;;
        mysqlx)    [ -n "${Lnmp_Conf}" ] && cur_conf=$(Read_Lnmp_Conf_Port "${Lnmp_Conf}" DB_X_Port) ;;
        redis)     [ -n "${Lnmp_Conf}" ] && cur_conf=$(Read_Lnmp_Conf_Port "${Lnmp_Conf}" Redis_Port) ;;
        memcached) [ -n "${Lnmp_Conf}" ] && cur_conf=$(Read_Lnmp_Conf_Port "${Lnmp_Conf}" Memcached_Port) ;;
        esac
        [ -z "${cur_conf}" ] && cur_conf='-'

        if [ "${rule_state}" = '-' ]; then
            printf -v verdict '缺失：该端口未阻断'
            rc=1
        elif [ "${cur_conf}" != '-' ] && [ "${cur_conf}" != "${port}" ]; then
            printf -v verdict 'lnmp.conf 未同步，重装会改回 %s' "${cur_conf}"
            rc=1
        else
            printf -v verdict '一致'
        fi
        Status_Line "${svc}" "${port}/${proto}" "${rule_state}" "${cur_conf}" "${verdict}"
    done < <(
        [ "${Has_DB}" = 'y' ] && [ -n "${P_DB}" ] && echo "mysql tcp ${P_DB}"
        [ "${Has_DB}" = 'y' ] && [ -n "${P_DB_X}" ] && echo "mysqlx tcp ${P_DB_X}"
        [ "${Has_Redis}" = 'y' ] && [ -n "${P_Redis}" ] && echo "redis tcp ${P_Redis}"
        [ "${Has_Memcached}" = 'y' ] && echo "memcached tcp ${P_Memcached}"
        [ "${Has_Memcached}" = 'y' ] && echo "memcached udp ${P_Memcached}"
        true
    )

    # 表里还挂着但当前配置已不再使用的阻断规则，就是手工改端口后的残留。
    local stale=''
    while read -r proto port; do
        [ -n "${proto}" ] || continue
        Planned_Drops | grep -qx "${proto} ${port}" || stale="${stale} ${proto}/${port}"
    done < <(printf '%s' "${dump}" | grep -oE '(tcp|udp) dport [0-9-]+ drop' | awk '{print $1, $3}')
    if [ -n "${stale}" ]; then
        Warn "以下阻断规则已不对应任何服务当前端口：${stale}"
        Warn "执行 lnmp fw sync 清理。"
        rc=1
    fi

    # 自定义条目覆盖标准阻断时必须点出，否则等于默默开放了服务端口。
    local rule
    for rule in ${Custom_Rules[@]+"${Custom_Rules[@]}"}; do
        set -- ${rule}
        [ "$1" = 'allow' ] || continue
        if Planned_Drops | grep -qx "$2 $3"; then
            Warn "fw.conf 的 allow $2 $3 覆盖了标准阻断，该服务端口对外可达。"
        fi
    done

    if [ -s "${FW_INCLUDE_FILE}" ] && [ -n "${dump}" ]; then
        if ! diff -q <(printf '%s\n' "${dump}" | Normalize_Rules) \
                     <(Normalize_Rules < "${FW_INCLUDE_FILE}") >/dev/null 2>&1; then
            Warn "内存中的规则与 ${FW_INCLUDE_FILE} 不一致，执行 lnmp fw sync 或 lnmp fw reload。"
            rc=1
        fi
    fi

    [ ${rc} -eq 0 ] && Ok "服务配置、防火墙规则与 lnmp.conf 已对齐。"
    return ${rc}
}

Cmd_Rule()
{
    local action="$1" proto="${2:-}" spec="${3:-}"

    if ! Valid_Proto "${proto}" || ! Valid_Port_Spec "${spec}"; then
        Err "用法：lnmp fw ${action} {tcp|udp} <端口|起-止>"
        return 1
    fi
    Load_Fw_Conf
    case "${action}" in
    allow|block)
        Write_Fw_Conf "${action}" "${proto}" "${spec}" || { Err "写入 ${Fw_Conf} 失败。"; return 1; }
        Say "已写入 ${Fw_Conf}：${action} ${proto} ${spec}"
        ;;
    unblock)
        Write_Fw_Conf remove "${proto}" "${spec}" || { Err "写入 ${Fw_Conf} 失败。"; return 1; }
        Say "已从 ${Fw_Conf} 移除：${proto} ${spec}"
        ;;
    esac
    Cmd_Sync
}

Cmd_Reload()
{
    Firewall_Backend
    case "${FW_Backend}" in
    firewalld)
        firewall-cmd --reload >/dev/null 2>&1 || { Err "firewall-cmd --reload 失败。"; return 1; }
        Ok "firewalld 已重新加载。"
        return 0
        ;;
    none)
        Err "未找到 nft 与 firewall-cmd。"
        return 1
        ;;
    esac

    if [ ! -s "${FW_INCLUDE_FILE}" ]; then
        Err "${FW_INCLUDE_FILE} 不存在，请先执行 lnmp fw sync。"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] \
       && systemctl is-enabled "${FW_UNIT_NAME}" >/dev/null 2>&1; then
        systemctl restart "${FW_UNIT_NAME}" >/dev/null 2>&1 || {
            Err "重启 ${FW_UNIT_NAME}.service 失败。"
            return 1
        }
    elif ! nft -f "${FW_INCLUDE_FILE}"; then
        Err "加载 ${FW_INCLUDE_FILE} 失败。"
        return 1
    fi
    Ok "已重新加载 ${FW_INCLUDE_FILE}。"
    return 0
}

Cmd_Purge()
{
    local ans="${1:-}" rc=0

    Firewall_Backend
    if [ "${FW_Backend}" = 'firewalld' ]; then
        Warn "检测到 firewalld，端口放行由 firewall-cmd 管理，未自动撤销。"
        Warn "如需收回：firewall-cmd --permanent --remove-port=<端口>/tcp"
        return 0
    fi

    if [ "${ans}" = '--yes' ]; then
        :
    elif [ ! -t 0 ]; then
        Err "非交互执行需要显式确认：lnmp fw purge --yes"
        return 1
    else
        Warn "将删除 ${FW_TABLE} 表、${FW_INCLUDE_FILE} 与 ${FW_UNIT_NAME}.service。"
        read -r -p "确认清除请输入 y，其它任意键取消 [y/N]：" ans
        case "${ans}" in
        [yY]) ;;
        *) Say "已取消，未做任何改动。"; return 0 ;;
        esac
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "${FW_UNIT_NAME}" >/dev/null 2>&1
    fi
    if [ -f "${FW_UNIT_FILE}" ] && ! rm -f "${FW_UNIT_FILE}"; then
        Err "删除 ${FW_UNIT_FILE} 失败。"
        rc=1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1
    fi
    command -v nft >/dev/null 2>&1 && nft delete table ${FW_TABLE} 2>/dev/null
    if [ -f "${FW_INCLUDE_FILE}" ] && ! rm -f "${FW_INCLUDE_FILE}"; then
        Err "删除 ${FW_INCLUDE_FILE} 失败。"
        rc=1
    fi
    rmdir "$(dirname "${FW_INCLUDE_FILE}")" 2>/dev/null

    [ ${rc} -eq 0 ] && Ok "已清除 ${FW_TABLE} 表、${FW_INCLUDE_FILE} 与 ${FW_UNIT_NAME}.service。"
    Say "规则可用 lnmp fw sync 重建。"
    return ${rc}
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
Main()
{
    local -a args=()

    while [ $# -gt 0 ]; do
        case "$1" in
        --conf)
            [ -n "${2:-}" ] || { Err "--conf 需要一个路径参数。"; return 1; }
            Lnmp_Conf="$2"
            shift 2
            ;;
        *)
            args+=("$1")
            shift
            ;;
        esac
    done
    set -- ${args[@]+"${args[@]}"}

    case "${1:-}" in
    status)
        Require_Root || return 1
        Cmd_Status
        ;;
    sync)
        Require_Root || return 1
        Cmd_Sync
        ;;
    allow|block|unblock)
        Require_Root || return 1
        Cmd_Rule "$1" "${2:-}" "${3:-}"
        ;;
    reload)
        Require_Root || return 1
        Cmd_Reload
        ;;
    purge)
        Require_Root || return 1
        Cmd_Purge "${2:-}"
        ;;
    ''|-h|--help|help)
        Usage
        [ -z "${1:-}" ] && return 1
        return 0
        ;;
    *)
        Err "未知子命令：$1"
        Usage
        return 1
        ;;
    esac
}

# 被 source 时只提供函数，供定向测试调用。
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    Main "$@"
fi
