#!/usr/bin/env bash
#
# LNMP 异地备份接收端守护，在备份服务器上运行，不依赖 LNMP 安装。
#
#   lnmp-backup-vault setup <账号> [公钥]   创建 SFTP 专用账号、chroot、sshd 配置与定时任务
#   lnmp-backup-vault guard                 归档已提交批次、校验、清理过期批次
#   lnmp-backup-vault status                各账号归档概况与上次守护结果
#   lnmp-backup-vault list [账号]           列出已归档批次
#
# ---------------------------------------------------------------------------
# 归档规则
#
# 生产机经 SFTP 将批次提交到 <chroot>/<数据目录>/{db,www}/<批次>。
# guard 以账号身份把批次移入 chroot 外的暂存目录，改为 root 所有后校验：
# 只允许普通文件、文件名合法、SHA256SUMS 与文件集合一致且哈希通过。
# 通过的批次改名到归档目录，失败的移入 quarantine，生产机密钥无法再删改。
# 归档保留期在备份机执行，每类至少保留 Keep_Min 个最新批次。
# ---------------------------------------------------------------------------

set -u
umask 077

Conf_File="/etc/lnmp-backup-vault.conf"
State_Dir="/var/lib/lnmp-backup-vault"
State_File="${State_Dir}/state"
Log_File="/var/log/lnmp-backup-vault.log"
Lock_File="/run/lock/lnmp-backup-vault.lock"
Install_Bin="/usr/local/sbin/lnmp-backup-vault"
Keys_Dir="/etc/ssh/lnmp-backup-vault"
Sshd_Config="/etc/ssh/sshd_config"
Systemd_Service="/etc/systemd/system/lnmp-backup-vault.service"
Systemd_Timer="/etc/systemd/system/lnmp-backup-vault.timer"
Cron_File="/etc/cron.d/lnmp-backup-vault"
Batch_Re='^[0-9]{8}-[0-9]{6}$'

Color() { if [ -t 1 ]; then printf '\033[%sm%s\033[0m\n' "$1" "$2"; else printf '%s\n' "$2"; fi; }
Say()   { printf '%s\n' "$*"; }
Warn()  { Color "0;33" "$*"; }
Err()   { Color "0;31" "$*" >&2; }
Ok()    { Color "0;32" "$*"; }

Log()
{
    local level="$1" line; shift
    line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
    printf '%s\n' "${line}" >> "${Log_File}" 2>/dev/null
    case "${level}" in
        ERROR) Err "${line}" ;;
        WARN)  Warn "${line}" ;;
        *)     Say "${line}" ;;
    esac
}

Is_Number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
Set_Conf_Defaults()
{
    Chroot_Base="/srv/sftp"
    Archive_Dir="/srv/lnmp-archive"
    Data_Dir="backup"
    Keep_Days_Db=30
    Keep_Days_Web=90
    Keep_Min=3
    Incoming_Keep_Hours=48
    Stale_Hours=48
    Vault_Users=()
}

Check_Abs_Dir()
{
    local name="$1" path="$2"
    case "${path}" in
        /|/bin|/boot|/dev|/etc|/home|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|/srv)
            Err "${name} 不能是系统目录：${path}"; return 1 ;;
        /*/|*/../*|*/..|*/./*) Err "${name} 格式不合法：${path}"; return 1 ;;
        /*) return 0 ;;
        *) Err "${name} 必须是绝对路径：${path}"; return 1 ;;
    esac
}

Valid_User() { printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; }
Valid_Rel_Dir() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$'; }

Load_Conf()
{
    local u n
    Set_Conf_Defaults
    if [ -f "${Conf_File}" ]; then
        n=$(stat -c '%u %a' "${Conf_File}" 2>/dev/null)
        case "${n}" in
            '0 600'|'0 400') : ;;
            *) Err "${Conf_File} 必须为 root 所有且权限 600，当前：${n}"; return 1 ;;
        esac
        # shellcheck disable=SC1090
        . "${Conf_File}" || { Err "配置文件语法有误：${Conf_File}"; return 1; }
    fi
    Check_Abs_Dir Chroot_Base "${Chroot_Base}" || return 1
    Check_Abs_Dir Archive_Dir "${Archive_Dir}" || return 1
    case "${Archive_Dir}/" in
        "${Chroot_Base}/"*) Err "Archive_Dir 不能位于 Chroot_Base 之内。"; return 1 ;;
    esac
    case "${Chroot_Base}/" in
        "${Archive_Dir}/"*) Err "Chroot_Base 不能位于 Archive_Dir 之内。"; return 1 ;;
    esac
    Valid_Rel_Dir "${Data_Dir}" || { Err "Data_Dir 不合法：${Data_Dir}"; return 1; }
    for n in Keep_Days_Db Keep_Days_Web Keep_Min Incoming_Keep_Hours Stale_Hours; do
        Is_Number "${!n}" || { Err "${n} 必须是非负整数。"; return 1; }
    done
    [ "${Keep_Days_Db}" -ge 1 ] && [ "${Keep_Days_Web}" -ge 1 ] || { Err "保留天数至少为 1。"; return 1; }
    [ "${Keep_Min}" -ge 1 ] || { Err "Keep_Min 至少为 1。"; return 1; }
    [ "${Incoming_Keep_Hours}" -ge 1 ] || { Err "Incoming_Keep_Hours 至少为 1。"; return 1; }
    for u in "${Vault_Users[@]}"; do
        Valid_User "${u}" || { Err "Vault_Users 中的账号名不合法：${u}"; return 1; }
    done
    return 0
}

Write_Conf()
{
    local tmp u list=''
    for u in "${Vault_Users[@]}"; do list="${list} \"${u}\""; done
    tmp=$(mktemp "${Conf_File}.XXXXXXXX") || return 1
    cat > "${tmp}" <<EOF
# LNMP 异地备份接收端配置，由 lnmp-backup-vault setup 生成，修改后下次 guard 生效。

# chroot 根目录的上级，每个账号为 \${Chroot_Base}/<账号>，各级目录须 root 所有且组和其他人不可写。
Chroot_Base="${Chroot_Base}"
# 归档目录，须在 chroot 之外；与 Chroot_Base 同一文件系统时归档为改名，否则为复制。
Archive_Dir="${Archive_Dir}"
# chroot 内的数据目录，对应生产机 Remote_Dir。
Data_Dir="${Data_Dir}"

# 归档保留天数；每类至少保留 Keep_Min 个最新批次，生产机停止上传时不会清空。
Keep_Days_Db=${Keep_Days_Db}
Keep_Days_Web=${Keep_Days_Web}
Keep_Min=${Keep_Min}

# 上传中断遗留的 .incoming 子目录超过该小时数后删除。
Incoming_Keep_Hours=${Incoming_Keep_Hours}
# 超过该小时数未收到新批次时 guard 返回失败，0 表示不检查。
Stale_Hours=${Stale_Hours}

Vault_Users=(${list# })
EOF
    chmod 600 "${tmp}" && mv -f "${tmp}" "${Conf_File}" || { rm -f "${tmp}"; return 1; }
}

State_Get()
{
    [ -f "${State_File}" ] || return 1
    sed -n "s/^$1=//p" "${State_File}" | tail -n 1
}

State_Set()
{
    local key="$1" val="$2" tmp
    mkdir -p "${State_Dir}" || return 1
    [ -f "${State_File}" ] || : > "${State_File}"
    tmp=$(mktemp "${State_Dir}/state.XXXXXXXX") || return 1
    grep -v "^${key}=" "${State_File}" > "${tmp}"
    printf '%s=%s\n' "${key}" "${val}" >> "${tmp}"
    mv -f "${tmp}" "${State_File}"
}

Need_Cmds()
{
    local c miss=''
    for c in "$@"; do command -v "${c}" >/dev/null 2>&1 || miss="${miss} ${c}"; done
    [ -z "${miss}" ] && return 0
    Err "缺少命令：${miss# }"
    return 1
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
# sshd 要求 chroot 路径上每一级目录都由 root 所有且组和其他人不可写。
Check_Chroot_Path()
{
    local p="$1" st
    while [ -n "${p}" ] && [ "${p}" != "/" ]; do
        if [ -e "${p}" ]; then
            [ -L "${p}" ] && { Err "chroot 路径不能含符号链接：${p}"; return 1; }
            st=$(stat -c '%u %a' "${p}") || return 1
            if [ "${st%% *}" != "0" ] || [ $(( 8#${st#* } & 8#022 )) -ne 0 ]; then
                Err "${p} 必须为 root 所有且组和其他人不可写（当前 uid/权限：${st}）。"
                return 1
            fi
        fi
        p="${p%/*}"
    done
    return 0
}

Nologin_Shell()
{
    local s
    for s in /usr/sbin/nologin /sbin/nologin; do
        [ -x "${s}" ] && { printf '%s' "${s}"; return 0; }
    done
    printf '/bin/false'
}

Ensure_User()
{
    local u="$1"
    id "${u}" >/dev/null 2>&1 && return 0
    # 口令字段为 *：禁止口令登录，同时不被 sshd 视为锁定账号。
    useradd -r -M -d / -s "$(Nologin_Shell)" -p '*' "${u}" || { Err "创建账号 ${u} 失败。"; return 1; }
    Ok "已创建账号 ${u}（无 shell、无口令）。"
}

# 缺失的上级目录按 755 创建，账号须能经由上级目录进入暂存目录。
Mkdir_Parents() { ( umask 022; mkdir -p -- "$1" ); }

Ensure_Dirs()
{
    local u="$1" root="${Chroot_Base}/$1" arch="${Archive_Dir}/$1" d
    Mkdir_Parents "${Chroot_Base}" || return 1
    Check_Chroot_Path "${Chroot_Base}" || return 1
    [ -L "${root}" ] && { Err "${root} 不能是符号链接。"; return 1; }
    [ -d "${root}" ] || mkdir -m 755 "${root}" || return 1
    chown root:root "${root}" && chmod 755 "${root}" || return 1
    # 数据目录逐级创建，属主为账号。
    local rest="${Data_Dir}" part
    d="${root}"
    while [ -n "${rest}" ]; do
        part="${rest%%/*}"
        if [ "${part}" = "${rest}" ]; then rest=''; else rest="${rest#*/}"; fi
        d="${d}/${part}"
        [ -L "${d}" ] && { Err "${d} 不能是符号链接。"; return 1; }
        [ -d "${d}" ] || mkdir -m 700 "${d}" || return 1
        chown -h "${u}:" "${d}" || return 1
    done

    Mkdir_Parents "${Archive_Dir}" || return 1
    chown root:root "${Archive_Dir}" && chmod 711 "${Archive_Dir}" || return 1
    [ -d "${arch}" ] || mkdir -m 711 "${arch}" || return 1
    chown root:root "${arch}" && chmod 711 "${arch}" || return 1
    for d in db www quarantine; do
        [ -d "${arch}/${d}" ] || mkdir -m 700 "${arch}/${d}" || return 1
    done
    [ -d "${arch}/.staging" ] || mkdir -m 700 "${arch}/.staging" || return 1
    chown "${u}:" "${arch}/.staging" && chmod 700 "${arch}/.staging"
}

# 公钥只保留类型与密钥两段，前缀选项统一为 restrict 与 internal-sftp；每个账号只保存一把公钥。
Install_Key()
{
    local u="$1" line="$2" tmp kt kb tok next=0 dst="${Keys_Dir}/$1.keys"
    for tok in ${line}; do
        if [ "${next}" -eq 1 ]; then kb="${tok}"; break; fi
        case "${tok}" in
            ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
                kt="${tok}"; next=1 ;;
        esac
    done
    if [ -z "${kt:-}" ] || [ -z "${kb:-}" ]; then
        Err "无法识别公钥，应为生产机 /root/.ssh/lnmp_backup.pub 的完整内容。"
        return 1
    fi
    printf '%s' "${kb}" | grep -Eq '^[A-Za-z0-9+/]+={0,2}$' || { Err "公钥内容不合法。"; return 1; }
    Mkdir_Parents "${Keys_Dir}" && chown root:root "${Keys_Dir}" && chmod 755 "${Keys_Dir}" || return 1
    tmp=$(mktemp "${Keys_Dir}/.key.XXXXXXXX") || return 1
    printf 'restrict,command="internal-sftp" %s %s lnmp-backup\n' "${kt}" "${kb}" > "${tmp}"
    if ! ssh-keygen -l -f "${tmp}" >/dev/null 2>&1; then
        rm -f "${tmp}"; Err "公钥校验失败。"; return 1
    fi
    chmod 644 "${tmp}" && mv -f "${tmp}" "${dst}" || { rm -f "${tmp}"; return 1; }
    Ok "已写入公钥：${dst}（$(ssh-keygen -l -f "${dst}" | awk '{print $2}')）"
}

Sshd_Block()
{
    local u="$1"
    cat <<EOF
# BEGIN lnmp-backup-vault ${u}
Match User ${u}
    ChrootDirectory ${Chroot_Base}/${u}
    ForceCommand internal-sftp
    AuthorizedKeysFile ${Keys_Dir}/${u}.keys
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
# END lnmp-backup-vault ${u}
EOF
}

# 本工具标记块之外出现 Match User <账号> 时拒绝修改，避免两套规则叠加。
Sshd_Conflict()
{
    local u="$1" f
    for f in "${Sshd_Config}" /etc/ssh/sshd_config.d/*.conf; do
        [ -f "${f}" ] || continue
        awk -v u="${u}" '
            $0 == "# BEGIN lnmp-backup-vault " u { skip = 1; next }
            $0 == "# END lnmp-backup-vault " u   { skip = 0; next }
            skip { next }
            tolower($1) == "match" {
                for (i = 2; i < NF; i++) if (tolower($i) == "user") {
                    n = split($(i + 1), a, ","); for (j = 1; j <= n; j++) if (a[j] == u) found = 1
                }
            }
            END { exit !found }' "${f}" && { Err "${f} 中已有针对 ${u} 的 Match 配置，请先手工处理。"; return 0; }
    done
    return 1
}

Sshd_Reload()
{
    local s
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        for s in ssh sshd; do
            systemctl is-active --quiet "${s}.service" 2>/dev/null || continue
            systemctl reload "${s}.service"
            return $?
        done
        return 3
    fi
    for s in /etc/init.d/ssh /etc/init.d/sshd; do
        [ -x "${s}" ] && { "${s}" reload; return $?; }
    done
    return 3
}

# 改写 sshd_config：同目录临时文件、语法检查、备份、改名、生效配置核对、重载；失败恢复原文件。
Sshd_Apply()
{
    local u="$1" sshd tmp bak eff rc
    sshd=$(command -v sshd || echo /usr/sbin/sshd)
    [ -x "${sshd}" ] || { Err "找不到 sshd。"; return 1; }
    [ -f "${Sshd_Config}" ] || { Err "找不到 ${Sshd_Config}。"; return 1; }
    Sshd_Conflict "${u}" && return 1
    # Debian 的 sshd -t 需要特权分离目录，服务未运行时该目录可能不存在。
    [ -d /run/sshd ] || mkdir -m 755 /run/sshd 2>/dev/null

    tmp=$(mktemp "${Sshd_Config}.lnmp.XXXXXXXX") || return 1
    {
        awk -v u="${u}" '
            $0 == "# BEGIN lnmp-backup-vault " u { skip = 1; next }
            $0 == "# END lnmp-backup-vault " u   { skip = 0; next }
            !skip' "${Sshd_Config}"
        Sshd_Block "${u}"
    } > "${tmp}" || { rm -f "${tmp}"; return 1; }
    chmod --reference="${Sshd_Config}" "${tmp}" && chown --reference="${Sshd_Config}" "${tmp}"
    if cmp -s "${tmp}" "${Sshd_Config}"; then
        rm -f "${tmp}"
        Say "sshd 配置无变化。"
        return 0
    fi
    if ! "${sshd}" -t -f "${tmp}"; then
        rm -f "${tmp}"; Err "新的 sshd 配置未通过语法检查，未做修改。"; return 1
    fi
    eff=$("${sshd}" -T -f "${tmp}" -C "user=${u},host=localhost,addr=127.0.0.1" 2>/dev/null)
    if ! printf '%s\n' "${eff}" | grep -qx "chrootdirectory ${Chroot_Base}/${u}" \
        || ! printf '%s\n' "${eff}" | grep -qx 'forcecommand internal-sftp' \
        || ! printf '%s\n' "${eff}" | grep -qx 'pubkeyauthentication yes'; then
        rm -f "${tmp}"
        Err "新配置对 ${u} 的生效结果不符（chroot、internal-sftp 或公钥认证），未做修改。"
        Err "检查 ${Sshd_Config} 及其 Include 中是否有更早的 Match 覆盖了这些项。"
        return 1
    fi
    if printf '%s\n' "${eff}" | grep -q '^allowusers ' \
        && ! printf '%s\n' "${eff}" | grep -Eq "^allowusers ${u}(@.*)?$"; then
        Warn "sshd 设置了 AllowUsers 且不含 ${u}，该账号将无法登录，需手工加入。"
    fi

    bak="${Sshd_Config}.lnmp-bak.$(date '+%Y%m%d%H%M%S')"
    cp -p "${Sshd_Config}" "${bak}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "${Sshd_Config}" || { rm -f "${tmp}"; return 1; }
    Sshd_Reload; rc=$?
    case "${rc}" in
        0) Ok "sshd 配置已更新并重载（原配置备份：${bak}）。" ;;
        3) Warn "sshd 未运行，配置在其下次启动时生效（原配置备份：${bak}）。" ;;
        *)
            Err "sshd 重载失败，恢复原配置。"
            cp -p "${bak}" "${Sshd_Config}" && Sshd_Reload
            return 1 ;;
    esac
    return 0
}

Install_Self()
{
    local self tmp
    self=$(readlink -f "${BASH_SOURCE[0]}") || return 1
    [ "${self}" = "${Install_Bin}" ] && return 0
    cmp -s "${self}" "${Install_Bin}" 2>/dev/null && return 0
    mkdir -p "${Install_Bin%/*}" || return 1
    tmp=$(mktemp "${Install_Bin}.XXXXXXXX") || return 1
    cp "${self}" "${tmp}" && chmod 755 "${tmp}" && mv -f "${tmp}" "${Install_Bin}" \
        || { rm -f "${tmp}"; Err "安装 ${Install_Bin} 失败。"; return 1; }
    Ok "已安装 ${Install_Bin}"
}

Install_Timer()
{
    local tmp
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        tmp=$(mktemp "${Systemd_Service}.XXXXXXXX") || return 1
        cat > "${tmp}" <<EOF
[Unit]
Description=LNMP backup vault guard

[Service]
Type=oneshot
ExecStart=${Install_Bin} guard
Nice=10
IOSchedulingClass=idle
EOF
        chmod 644 "${tmp}" && mv -f "${tmp}" "${Systemd_Service}" || { rm -f "${tmp}"; return 1; }
        tmp=$(mktemp "${Systemd_Timer}.XXXXXXXX") || return 1
        cat > "${tmp}" <<'EOF'
[Unit]
Description=LNMP backup vault guard timer

[Timer]
OnCalendar=*:0/15
RandomizedDelaySec=60
Persistent=true

[Install]
WantedBy=timers.target
EOF
        chmod 644 "${tmp}" && mv -f "${tmp}" "${Systemd_Timer}" || { rm -f "${tmp}"; return 1; }
        systemctl daemon-reload && systemctl enable --now lnmp-backup-vault.timer >/dev/null 2>&1 \
            || { Err "启用 lnmp-backup-vault.timer 失败。"; return 1; }
        Ok "已启用 lnmp-backup-vault.timer（每 15 分钟执行 guard）。"
    else
        tmp=$(mktemp "${Cron_File}.XXXXXXXX") || return 1
        printf '*/15 * * * * root %s guard >/dev/null 2>&1\n' "${Install_Bin}" > "${tmp}"
        chmod 644 "${tmp}" && mv -f "${tmp}" "${Cron_File}" || { rm -f "${tmp}"; return 1; }
        Ok "已写入 cron：${Cron_File}（每 15 分钟执行 guard）。"
    fi
}

Show_Host_Keys()
{
    local f
    Say "本机 SSH 主机指纹，在生产机执行 lnmp backup remote-setup 时逐字核对："
    for f in /etc/ssh/ssh_host_*_key.pub; do
        [ -f "${f}" ] && Say "  $(ssh-keygen -l -f "${f}")"
    done
}

Cmd_Setup()
{
    local u="${1:-}" key="${2:-}" x known=0
    [ -n "${u}" ] || { Err "用法：lnmp-backup-vault setup <账号> [公钥|-]"; return 1; }
    Valid_User "${u}" || { Err "账号名只能含小写字母、数字、下划线和连字符，且不以数字开头。"; return 1; }
    case "${u}" in root|nobody|daemon|bin|sys|sshd) Err "不能使用系统账号 ${u}。"; return 1 ;; esac
    if [ "${key}" = "-" ]; then
        IFS= read -r key || { Err "未从标准输入读到公钥。"; return 1; }
    fi
    Need_Cmds useradd runuser flock sha256sum ssh-keygen awk || return 1
    Load_Conf || return 1

    mkdir -p "${Lock_File%/*}"
    exec 9>"${Lock_File}" && flock -w 60 9 || { Err "无法获取锁 ${Lock_File}。"; return 1; }
    for x in "${Vault_Users[@]}"; do [ "${x}" = "${u}" ] && known=1; done
    # 已有账号只接受本工具登记过的，避免把现有登录账号改成 chroot 账号。
    if [ "${known}" -ne 1 ] && id "${u}" >/dev/null 2>&1; then
        Err "账号 ${u} 已存在且不是本工具创建的，换一个账号名。"
        return 1
    fi
    # 先登记再建账号，建账号失败后重跑仍可继续。
    if [ "${known}" -ne 1 ]; then
        Vault_Users+=("${u}")
        Write_Conf || { Err "写入 ${Conf_File} 失败。"; return 1; }
    elif [ ! -f "${Conf_File}" ]; then
        Write_Conf || { Err "写入 ${Conf_File} 失败。"; return 1; }
    fi
    Ensure_User "${u}" || return 1
    Ensure_Dirs "${u}" || { Err "创建目录失败。"; return 1; }
    if [ -n "${key}" ]; then
        Install_Key "${u}" "${key}" || return 1
    elif [ ! -s "${Keys_Dir}/${u}.keys" ]; then
        Warn "尚未写入公钥，生产机暂时无法登录。取得公钥后重新执行：lnmp-backup-vault setup ${u} '<公钥>'"
    fi
    Sshd_Apply "${u}" || return 1
    Install_Self || return 1
    Install_Timer || return 1
    mkdir -p "${State_Dir}" && chmod 700 "${State_Dir}"

    Say ""
    Ok "账号 ${u} 已就绪：chroot ${Chroot_Base}/${u}，数据目录 ${Data_Dir}，归档 ${Archive_Dir}/${u}"
    Say "生产机 backup.conf 对应：Remote_User=\"${u}\"  Remote_Dir=\"${Data_Dir}\""
    Show_Host_Keys
    return 0
}

# ---------------------------------------------------------------------------
# guard
# ---------------------------------------------------------------------------
Valid_Name() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9._@+-]*$'; }

# Check_Batch <目录>：只含普通文件，SHA256SUMS 覆盖其余全部文件且哈希一致。
Check_Batch()
{
    local dir="$1" f n listed actual
    [ -d "${dir}" ] && [ ! -L "${dir}" ] || { Say "不是目录"; return 1; }
    n=$(find "${dir}" -mindepth 1 \( ! -type f -o -links +1 \) -print | wc -l)
    [ "${n}" -eq 0 ] || { Say "含非普通文件或硬链接"; return 1; }
    [ -f "${dir}/SHA256SUMS" ] || { Say "缺少 SHA256SUMS"; return 1; }
    for f in "${dir}"/*; do
        Valid_Name "${f##*/}" || { Say "文件名不合法：${f##*/}"; return 1; }
    done
    grep -Evq '^[0-9a-f]{64} [ *][A-Za-z0-9_][A-Za-z0-9._@+-]*$' "${dir}/SHA256SUMS" \
        && { Say "SHA256SUMS 格式不合法"; return 1; }
    listed=$(sed -E 's/^[0-9a-f]{64} [ *]//' "${dir}/SHA256SUMS" | sort)
    actual=$(find "${dir}" -mindepth 1 -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | sort)
    [ -n "${listed}" ] || { Say "SHA256SUMS 为空"; return 1; }
    [ "${listed}" = "${actual}" ] || { Say "SHA256SUMS 与文件集合不一致"; return 1; }
    ( cd "${dir}" && sha256sum -c --quiet --strict SHA256SUMS >/dev/null 2>&1 ) || { Say "哈希不一致"; return 1; }
    return 0
}

# 以账号身份移出 chroot，root 不在账号可写的路径中操作。暂存条目先判断类型，
# 符号链接、非目录、含非普通文件或硬链接时原样隔离，不做任何属主或权限修改。
# 通过的批次由 root 复制为新文件后校验：生产机已打开的文件句柄无法写入归档副本。
Take_Batch()
{
    local u="$1" type="$2" b="$3"
    local src="${Chroot_Base}/$1/${Data_Dir}/$2/$3" arch="${Archive_Dir}/$1"
    local stage="${arch}/.staging/$2-$3" imp="${arch}/.import-$2-$3" why='' q f
    [ -e "${stage}" ] || [ -L "${stage}" ] && rm -rf -- "${stage}"
    [ -e "${imp}" ] && rm -rf -- "${imp}"
    if ! runuser -u "${u}" -- mv -T -- "${src}" "${stage}" 2>/dev/null; then
        Log ERROR "${u}: 无法移出 ${type}/${b}"
        return 1
    fi
    if [ -L "${stage}" ] || [ ! -d "${stage}" ]; then
        why="不是目录"
    elif [ -n "$(find "${stage}" -mindepth 1 \( ! -type f -o -links +1 \) -print -quit)" ]; then
        why="含非普通文件或硬链接"
    fi
    if [ -n "${why}" ]; then
        q="${arch}/quarantine/${type}-${b}-$(date '+%s')"
        mv -T -- "${stage}" "${q}"
        Log ERROR "${u}: ${type}/${b} 校验未通过（${why}），已隔离到 ${q}"
        return 1
    fi

    mkdir -m 700 "${imp}" || { Log ERROR "${u}: 无法创建 ${imp}"; return 1; }
    while IFS= read -r -d '' f; do
        cp --reflink=auto -- "${f}" "${imp}/" || why="复制失败"
    done < <(find "${stage}" -mindepth 1 -maxdepth 1 -type f -print0)
    rm -rf -- "${stage}"
    [ -n "${why}" ] || why=$(Check_Batch "${imp}") || why="${why:-校验失败}"
    if [ -n "${why}" ]; then
        q="${arch}/quarantine/${type}-${b}-$(date '+%s')"
        mv -T -- "${imp}" "${q}"
        Log ERROR "${u}: ${type}/${b} 校验未通过（${why}），已隔离到 ${q}"
        return 1
    fi
    if [ -e "${arch}/${type}/${b}" ]; then
        q="${arch}/quarantine/${type}-${b}-dup-$(date '+%s')"
        mv -T -- "${imp}" "${q}"
        Log ERROR "${u}: ${type}/${b} 已归档过，新的同名批次已隔离到 ${q}"
        return 1
    fi
    mv -T -- "${imp}" "${arch}/${type}/${b}" || { Log ERROR "${u}: 归档 ${type}/${b} 失败"; return 1; }
    Log INFO "${u}: 已归档 ${type}/${b}"
    return 0
}

List_Archived()
{
    local dir="$1"
    [ -d "${dir}" ] || return 0
    find "${dir}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep -E "${Batch_Re}" | sort
}

Batch_Epoch() { date -d "${1:0:4}-${1:4:2}-${1:6:2} ${1:9:2}:${1:11:2}:${1:13:2}" '+%s' 2>/dev/null; }

Prune_Archive()
{
    local u="$1" type="$2" days="$3" dir="${Archive_Dir}/$1/$2" b n i=0 now e
    local -a all=()
    mapfile -t all < <(List_Archived "${dir}")
    n=${#all[@]}
    now=$(date '+%s')
    for b in "${all[@]}"; do
        i=$((i + 1))
        [ $((n - i)) -ge "${Keep_Min}" ] || break
        e=$(Batch_Epoch "${b}") || continue
        [ $(( (now - e) / 86400 )) -ge "${days}" ] || continue
        rm -rf -- "${dir:?}/${b}"
        Log INFO "${u}: 清理过期归档 ${type}/${b}"
    done
}

Prune_Incoming()
{
    local u="$1" inc="${Chroot_Base}/$1/${Data_Dir}/.incoming" d
    [ -d "${inc}" ] && [ ! -L "${inc}" ] || return 0
    while IFS= read -r d; do
        [ -n "${d}" ] || continue
        runuser -u "${u}" -- rm -rf -- "${inc}/${d}" 2>/dev/null \
            && Log INFO "${u}: 清理中断上传遗留 .incoming/${d}"
    done < <(find "${inc}" -mindepth 1 -maxdepth 1 -mmin +$((Incoming_Keep_Hours * 60)) -printf '%f\n')
}

# 归档索引写回数据目录，供生产机 lnmp backup list 显示；写入以账号身份完成。
Write_Index()
{
    local u="$1" data="${Chroot_Base}/$1/${Data_Dir}" tmp t b rc
    tmp=$(mktemp "${Archive_Dir}/$1/.index.XXXXXXXX") || return 1
    for t in db www; do
        for b in $(List_Archived "${Archive_Dir}/${u}/${t}"); do printf '%s %s\n' "${t}" "${b}"; done
    done > "${tmp}"
    chmod 644 "${tmp}"
    runuser -u "${u}" -- cp -f -- "${tmp}" "${data}/.vault-index.tmp" \
        && runuser -u "${u}" -- mv -f -T -- "${data}/.vault-index.tmp" "${data}/.vault-index"
    rc=$?
    rm -f -- "${tmp}"
    return "${rc}"
}

Guard_User()
{
    local u="$1" data="${Chroot_Base}/$1/${Data_Dir}" type b rc=0 newest='' e
    if ! id "${u}" >/dev/null 2>&1; then
        Log ERROR "${u}: 账号不存在"; return 1
    fi
    if [ ! -d "${data}" ] || [ -L "${data}" ] || [ ! -d "${Archive_Dir}/${u}/.staging" ]; then
        Log ERROR "${u}: 目录不完整，重新执行 lnmp-backup-vault setup ${u}"; return 1
    fi
    for type in db www; do
        [ -d "${data}/${type}" ] && [ ! -L "${data}/${type}" ] || continue
        while IFS= read -r b; do
            printf '%s' "${b}" | grep -Eq "${Batch_Re}" || continue
            Take_Batch "${u}" "${type}" "${b}" || rc=1
        done < <(find "${data}/${type}" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
    done
    Prune_Archive "${u}" db "${Keep_Days_Db}"
    Prune_Archive "${u}" www "${Keep_Days_Web}"
    Prune_Incoming "${u}"
    Write_Index "${u}" || Log WARN "${u}: 写入归档索引失败"

    newest=$( { List_Archived "${Archive_Dir}/${u}/db"; List_Archived "${Archive_Dir}/${u}/www"; } | sort | tail -n 1)
    if [ -z "${newest}" ]; then
        Log WARN "${u}: 尚未收到任何批次"
    elif [ "${Stale_Hours}" -gt 0 ] && e=$(Batch_Epoch "${newest}") \
        && [ $(( ($(date '+%s') - e) / 3600 )) -ge "${Stale_Hours}" ]; then
        Log ERROR "${u}: 最新批次 ${newest} 已超过 ${Stale_Hours} 小时，生产机可能已停止上传"
        rc=1
    fi
    return "${rc}"
}

Cmd_Guard()
{
    local u rc=0
    Need_Cmds runuser flock sha256sum find || return 1
    Load_Conf || return 1
    mkdir -p "${Lock_File%/*}" "${State_Dir}"
    exec 9>"${Lock_File}" && flock -n 9 || { Err "另一个 guard 正在运行。"; return 1; }
    [ "${#Vault_Users[@]}" -gt 0 ] || { Warn "尚未配置账号，先执行 setup。"; return 0; }
    for u in "${Vault_Users[@]}"; do
        Guard_User "${u}" || rc=1
    done
    State_Set Last_Guard_Time "$(date '+%Y-%m-%d %H:%M:%S')"
    State_Set Last_Guard_Rc "${rc}"
    return "${rc}"
}

# ---------------------------------------------------------------------------
# status / list
# ---------------------------------------------------------------------------
Cmd_Status()
{
    local u t n last q p
    Load_Conf || return 1
    Say "配置：${Conf_File}"
    Say "归档：${Archive_Dir}（数据库保留 ${Keep_Days_Db} 天，网站 ${Keep_Days_Web} 天，每类至少 ${Keep_Min} 个）"
    last=$(State_Get Last_Guard_Time)
    if [ -z "${last}" ]; then
        Warn "guard 尚未执行过。"
    elif [ "$(State_Get Last_Guard_Rc)" = "0" ]; then
        Ok "上次 guard：${last}，成功"
    else
        Err "上次 guard：${last}，失败，详见 ${Log_File}"
    fi
    for u in "${Vault_Users[@]}"; do
        Say ""
        Say "账号 ${u}："
        for t in db www; do
            n=$(List_Archived "${Archive_Dir}/${u}/${t}" | wc -l)
            Say "  ${t}：已归档 ${n} 个，最新 $(List_Archived "${Archive_Dir}/${u}/${t}" | tail -n 1)"
            p=$(find "${Chroot_Base}/${u}/${Data_Dir}/${t}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
            [ "${p}" -eq 0 ] || Say "  ${t}：待归档 ${p} 个"
        done
        q=$(find "${Archive_Dir}/${u}/quarantine" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
        [ "${q}" -eq 0 ] || Err "  隔离区 ${q} 个，查看：ls ${Archive_Dir}/${u}/quarantine"
        [ -s "${Keys_Dir}/${u}.keys" ] || Warn "  尚未写入公钥"
    done
    return 0
}

Cmd_List()
{
    local only="${1:-}" u t b size
    Load_Conf || return 1
    for u in "${Vault_Users[@]}"; do
        [ -z "${only}" ] || [ "${only}" = "${u}" ] || continue
        for t in db www; do
            Say "=== ${u} ${t} ==="
            for b in $(List_Archived "${Archive_Dir}/${u}/${t}"); do
                size=$(du -sh "${Archive_Dir}/${u}/${t}/${b}" 2>/dev/null | cut -f1)
                Say "  ${b}  ${size:-?}"
            done
        done
    done
    return 0
}

Usage()
{
    cat <<'EOF'
用法：lnmp-backup-vault <子命令>

  setup <账号> [公钥|-]   创建或更新 SFTP 专用账号、chroot、sshd 配置与定时任务；- 从标准输入读公钥
  guard                   归档已提交批次、校验、清理过期批次（定时任务每 15 分钟执行）
  status                  各账号归档概况与上次 guard 结果
  list [账号]             列出已归档批次

配置：/etc/lnmp-backup-vault.conf
日志：/var/log/lnmp-backup-vault.log
EOF
}

Main()
{
    local cmd="${1:-}"
    [ -n "${cmd}" ] && shift
    case "${cmd}" in
        help|-h|--help|'') Usage; [ -n "${cmd}" ]; return ;;
    esac
    [ "$(id -u)" = "0" ] || { Err "需要 root 权限。"; return 1; }
    case "${cmd}" in
        setup)  Cmd_Setup "$@" ;;
        guard)  Cmd_Guard "$@" ;;
        status) Cmd_Status "$@" ;;
        list)   Cmd_List "$@" ;;
        *)      Usage; return 1 ;;
    esac
}

[ "${LNMP_VAULT_NO_MAIN:-}" = "1" ] || Main "$@"
