#!/usr/bin/env bash
#
# LNMP 网站与数据库备份工具，通过 `lnmp backup <子命令>` 使用。
# 安装路径为 /bin/lnmp-backup，lnmp、lnmpa 和 lamp 管理命令共用该工具。
#
#   lnmp backup init                 生成配置、目录与定时任务
#   lnmp backup run [db|web|all]     执行备份（不带参数按配置的周期决定）
#   lnmp backup run [范围] <域名>... 只备份指定站点
#   lnmp backup status               上次结果、下次计划、最近错误
#   lnmp backup list [db|web]        列出本地批次（配了远端则一并列远端）
#   lnmp backup restore ...          从备份恢复
#   lnmp backup test                 试恢复：把最新库备份导入临时库再删掉
#
# ---------------------------------------------------------------------------
# 备份与恢复规则
#
# 批次目录使用秒级时间戳，同日多次备份不会互相覆盖。
# 数据库和网站文件分开存放，可独立设置备份周期与保留天数。
#
# 完整检查 mysqldump、tar、gzip 和写盘结果，产物先写入 .part 文件，
# 全部成功后才改为最终文件名，避免将截断文件用于恢复。
#
# 远端文件先上传到 .incoming/<批次>/，逐个核对大小后再移入正式目录。
# 旧批次只在新恢复点可用后清理，传输失败时仍保留现有备份。
#
# 数据库口令保存在权限 0600 的 option file 中，SFTP 上传使用 SSH 密钥，
# 防止凭据出现在命令行参数中。
# ---------------------------------------------------------------------------

set -u

Conf_Dir="/etc/lnmp"
Conf_File="${Conf_Dir}/backup.conf"
My_Cnf="${Conf_Dir}/backup-mysql.cnf"
State_Dir="/var/lib/lnmp/backup"
State_File="${State_Dir}/state"
Log_File="/var/log/lnmp/backup.log"
Lock_File="/var/lock/lnmp-backup.lock"
Systemd_Service="/etc/systemd/system/lnmp-backup.service"
Systemd_Timer="/etc/systemd/system/lnmp-backup.timer"
Cron_File="/etc/cron.d/lnmp-backup"

# 备份包含整站源码和整库数据，文件默认仅允许 root 读取。
umask 077

# ---------------------------------------------------------------------------
# 输出与日志
# ---------------------------------------------------------------------------
Color()   { if [ -t 1 ]; then printf '\033[%sm%s\033[0m\n' "$1" "$2"; else printf '%s\n' "$2"; fi; }
Say()     { printf '%s\n' "$*"; }
Warn()    { Color "0;33" "$*"; }
Err()     { Color "0;31" "$*" >&2; }
Ok()      { Color "0;32" "$*"; }

# 日志目录按需创建；日志写入失败不中断备份任务。
Log()
{
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
    [ -d "${Log_File%/*}" ] || mkdir -p "${Log_File%/*}" 2>/dev/null
    printf '%s\n' "${line}" >> "${Log_File}" 2>/dev/null
    case "${level}" in
        ERROR) Err "${line}" ;;
        WARN)  Warn "${line}" ;;
        *)     Say "${line}" ;;
    esac
}

Die() { Log ERROR "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
Set_Conf_Defaults()
{
    Backup_Home="/home/backup"
    MySQL_Dump=""
    MySQL_Option_File="${My_Cnf}"
    Backup_Site=()
    Keep_Days_Db=14
    Keep_Days_Web=60
    Web_Interval_Days=7
    Enable_Remote_Backup=0
    # 远端协议：sftp（SSH 密钥）、ftps（TLS）或 ftp（明文）。
    Remote_Protocol="sftp"
    Remote_Host=""
    Remote_Port=22
    Remote_User=""
    Remote_Dir="backup"
    Remote_SSH_Key="/root/.ssh/lnmp_backup"
    Remote_Known_Hosts="/root/.ssh/lnmp_backup_known_hosts"
    # 仅 ftp 和 ftps 使用。
    Remote_Password=""
    Remote_Ftp_Verify=1
    Remote_Ftp_CA=""
    Enable_Encrypt=0
    Encrypt_Tool="age"
    Encrypt_Recipient=""
    Encrypt_Identity="/root/.config/lnmp/backup-age.key"
}

Load_Conf()
{
    Set_Conf_Defaults
    [ -f "${Conf_File}" ] || Die "找不到配置 ${Conf_File}，先执行：lnmp backup init"
    Check_Perm "${Conf_File}" || return 1
    # shellcheck disable=SC1090
    . "${Conf_File}" || Die "配置文件语法有误：${Conf_File}"

    Check_Backup_Home "${Backup_Home}" || Die "Backup_Home 配置有误：${Conf_File}"
    Is_Number "${Keep_Days_Db}"   || Die "Keep_Days_Db 必须是数字。"
    Is_Number "${Keep_Days_Web}"  || Die "Keep_Days_Web 必须是数字。"
    Is_Number "${Web_Interval_Days}" || Die "Web_Interval_Days 必须是数字。"
    [ "${Keep_Days_Db}" -ge 1 ]  || Die "Keep_Days_Db 至少为 1。"
    [ "${Keep_Days_Web}" -ge 1 ] || Die "Keep_Days_Web 至少为 1。"
    case "${Remote_Protocol}" in
        sftp|ftps|ftp) : ;;
        *) Die "Remote_Protocol 只能是 sftp、ftps 或 ftp，当前是 '${Remote_Protocol}'" ;;
    esac
    return 0
}

Is_Number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# 备份目录必须是非系统目录的绝对路径，防止过期批次清理误删系统文件。
# 初始化和每次读取配置时都会执行该校验。
Check_Backup_Home()
{
    local home="${1:-}"
    [ -n "${home}" ] || { Err "备份目录不能为空。"; return 1; }
    case "${home}" in
        /|/bin|/etc|/home|/root|/usr|/var) Err "备份目录不能是系统目录：${home}"; return 1 ;;
        /*) return 0 ;;
        *) Err "备份目录必须是绝对路径：${home}"; return 1 ;;
    esac
}

# option file 和私钥包含高权限凭据，权限必须限制为 600 或 400。
Check_Perm()
{
    local f="$1" perm
    [ -e "${f}" ] || { Err "文件不存在：${f}"; return 1; }
    perm=$(stat -c '%a' "${f}" 2>/dev/null || stat -f '%Lp' "${f}" 2>/dev/null)
    case "${perm}" in
        600|400) return 0 ;;
        *) Err "${f} 权限是 ${perm}，必须是 600。修复：chmod 600 ${f}"; return 1 ;;
    esac
}

Find_Mysqldump()
{
    local c
    if [ -n "${MySQL_Dump}" ] && [ -x "${MySQL_Dump}" ]; then
        case "${MySQL_Dump}" in
            /usr/local/mariadb/bin/mysqldump)
                [ -x /usr/local/mariadb/bin/mariadb-dump ] && MySQL_Dump=/usr/local/mariadb/bin/mariadb-dump
                ;;
            /usr/bin/mysqldump)
                [ -x /usr/bin/mariadb-dump ] && MySQL_Dump=/usr/bin/mariadb-dump
                ;;
        esac
        return 0
    fi
    for c in /usr/local/mysql/bin/mysqldump \
             /usr/local/mariadb/bin/mariadb-dump /usr/local/mariadb/bin/mysqldump \
             /usr/bin/mariadb-dump /usr/bin/mysqldump; do
        if [ -x "${c}" ]; then MySQL_Dump="${c}"; return 0; fi
    done
    return 1
}

Find_Mysql_Client()
{
    local c
    for c in /usr/local/mysql/bin/mysql \
             /usr/local/mariadb/bin/mariadb /usr/local/mariadb/bin/mysql \
             /usr/bin/mariadb /usr/bin/mysql; do
        if [ -x "${c}" ]; then printf '%s' "${c}"; return 0; fi
    done
    return 1
}

# 输出数据库实际使用的 socket 路径，[client] 优先，其次 [mysqld]。
# --defaults-file 不读 /etc/my.cnf，临时凭据必须自带 socket 才能连上。
Get_Actual_DB_Socket()
{
    local conf="${1:-/etc/my.cnf}" sock=''

    if [ -s "${conf}" ]; then
        sock=$(awk '
            /^[[:space:]]*\[/ {
                section = $0
                sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
                sub(/[[:space:]]*\].*$/, "", section)
                next
            }
            /^[[:space:]]*socket[[:space:]]*=/ {
                value = $0
                sub(/^[^=]*=[[:space:]]*/, "", value)
                sub(/[[:space:]#].*$/, "", value)
                if (value == "") next
                if (section == "client" && client == "") client = value
                else if (section == "mysqld" && server == "") server = value
            }
            END { print (client != "" ? client : server) }
        ' "${conf}")
    fi
    printf '%s' "${sock:-/run/mysqld/mysqld.sock}"
}

# ---------------------------------------------------------------------------
# 并发锁保证同一时刻只运行一个备份任务，避免批次写入、上传和清理互相干扰。
# ---------------------------------------------------------------------------
Lock_Dir=""
Tmp_Work=""

# 退出时统一删除锁目录和临时工作目录。
Cleanup_All()
{
    [ -n "${Lock_Dir}" ] && [ -d "${Lock_Dir}" ] && rm -rf -- "${Lock_Dir}"
    [ -n "${Tmp_Work}" ] && [ -d "${Tmp_Work}" ] && rm -rf -- "${Tmp_Work}"
    return 0
}
trap Cleanup_All EXIT
trap 'Cleanup_All; exit 130' INT TERM

Acquire_Lock()
{
    local old
    mkdir -p "${Lock_File%/*}" 2>/dev/null
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${Lock_File}" || { Err "无法创建锁文件 ${Lock_File}"; return 1; }
        if ! flock -n 9; then
            Err "另一个备份任务正在运行（锁：${Lock_File}）。"
            return 1
        fi
        return 0
    fi
    # flock 不可用时使用 mkdir 的原子创建特性获取锁。
    if ! mkdir "${Lock_File}.d" 2>/dev/null; then
        old=$(cat "${Lock_File}.d/pid" 2>/dev/null)
        if [ -n "${old}" ] && kill -0 "${old}" 2>/dev/null; then
            Err "另一个备份任务正在运行（PID ${old}）。"
            return 1
        fi
        Warn "清理上次异常退出留下的锁：${Lock_File}.d"
        rm -rf -- "${Lock_File}.d"
        mkdir "${Lock_File}.d" 2>/dev/null || { Err "无法获取锁 ${Lock_File}.d"; return 1; }
    fi
    printf '%s' "$$" > "${Lock_File}.d/pid" 2>/dev/null
    Lock_Dir="${Lock_File}.d"
    return 0
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
State_Get()
{
    local key="$1"
    [ -f "${State_File}" ] || return 1
    sed -n "s/^${key}=//p" "${State_File}" | tail -n 1
}

State_Set()
{
    local key="$1" val="$2" tmp
    mkdir -p "${State_Dir}" 2>/dev/null
    [ -f "${State_File}" ] || : > "${State_File}"
    tmp=$(mktemp "${State_Dir}/state.XXXXXXXX") || return 1
    grep -v "^${key}=" "${State_File}" > "${tmp}" 2>/dev/null
    printf '%s=%s\n' "${key}" "${val}" >> "${tmp}"
    mv -f "${tmp}" "${State_File}" && chmod 600 "${State_File}"
}

# ---------------------------------------------------------------------------
# 批次与保留
# ---------------------------------------------------------------------------
New_Batch() { date '+%Y%m%d-%H%M%S'; }

# 批次目录名格式为 20260810-033000，前 8 位与保留期截止日期比较，
# 所有早于截止日期的批次都会进入清理范围。
Batch_Older_Than()
{
    local batch="$1" days="$2" cutoff
    cutoff=$(date -d "-${days} day" '+%Y%m%d' 2>/dev/null) \
        || cutoff=$(date -v-"${days}"d '+%Y%m%d' 2>/dev/null) \
        || return 1
    case "${batch}" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
        *) return 1 ;;
    esac
    [ "${batch%%-*}" -lt "${cutoff}" ]
}

# 删除前要求目标位于 ${Backup_Home}/{db,www} 下且使用合法批次名，
# 防止配置错误或空变量扩大删除范围。
Safe_Rm_Batch()
{
    local type="$1" batch="$2" dir
    [ -n "${Backup_Home}" ] || return 1
    case "${type}" in db|www) : ;; *) return 1 ;; esac
    case "${batch}" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
        *) Err "拒绝删除：批次名不合法 ${batch}"; return 1 ;;
    esac
    dir="${Backup_Home}/${type}/${batch}"
    [ -d "${dir}" ] || return 0
    rm -rf -- "${dir}"
}

List_Batches()
{
    local type="$1" d
    [ -d "${Backup_Home}/${type}" ] || return 0
    for d in "${Backup_Home}/${type}"/*; do
        [ -d "${d}" ] || continue
        printf '%s\n' "${d##*/}"
    done | sort
}

# ---------------------------------------------------------------------------
# 备份产物
#
# 产物先写入 <目标>.part，tar、mysqldump、gzip 和写盘全部成功后再改为最终名。
# 完整检查管道各环节可防止磁盘写满时将损坏的备份记为成功。
# ---------------------------------------------------------------------------
Dump_Db()
{
    local db="$1" out="$2" part="$2.part" rc_dump rc_gzip pipe_st
    "${MySQL_Dump}" --defaults-file="${MySQL_Option_File}" \
        --single-transaction --quick --routines --triggers --events \
        --default-character-set=utf8mb4 "${db}" 2>>"${Log_File}" \
        | gzip -c > "${part}"
    # PIPESTATUS 必须一次性保存；后续赋值会重置该数组，导致管道退出码失真。
    pipe_st=("${PIPESTATUS[@]}")
    rc_dump=${pipe_st[0]}; rc_gzip=${pipe_st[1]}
    if [ "${rc_dump}" -ne 0 ] || [ "${rc_gzip}" -ne 0 ]; then
        rm -f "${part}"
        Log ERROR "导出数据库 ${db} 失败 (mysqldump=${rc_dump} gzip=${rc_gzip})"
        return 1
    fi
    if [ ! -s "${part}" ]; then
        rm -f "${part}"
        Log ERROR "导出数据库 ${db} 得到空文件"
        return 1
    fi
    # mysqldump 正常结束会写入 "-- Dump completed"，该标记用于拒绝进程中断或
    # 磁盘写满时留下的不完整转储，判定规则与 Check_DB_Backup 一致。
    if ! gzip -dc "${part}" 2>/dev/null | tail -c 200 | grep -q -- '-- Dump completed'; then
        rm -f "${part}"
        Log ERROR "导出数据库 ${db} 的转储不完整（缺少结束标记）"
        return 1
    fi
    mv -f "${part}" "${out}" || { rm -f "${part}"; return 1; }
    return 0
}

Tar_Dir()
{
    local path="$1" out="$2" part="$2.part" name parent rc_tar rc_gzip pipe_st
    if [ ! -d "${path}" ]; then
        Log ERROR "网站目录不存在：${path}"
        return 1
    fi
    name="${path##*/}"; parent="${path%/*}"
    tar cf - -C "${parent}" "${name}" 2>>"${Log_File}" | gzip -c > "${part}"
    pipe_st=("${PIPESTATUS[@]}")
    rc_tar=${pipe_st[0]}; rc_gzip=${pipe_st[1]}
    if [ "${rc_tar}" -ne 0 ] || [ "${rc_gzip}" -ne 0 ]; then
        rm -f "${part}"
        Log ERROR "打包 ${path} 失败 (tar=${rc_tar} gzip=${rc_gzip})"
        return 1
    fi
    mv -f "${part}" "${out}" || { rm -f "${part}"; return 1; }
    return 0
}

# 可选加密默认关闭；开启后校验清单按密文计算，恢复时先解密再解压。
Encrypt_File()
{
    local in="$1" out="${1}.enc" rc=0
    [ "${Enable_Encrypt}" = "1" ] || { printf '%s' "${in}"; return 0; }
    # 加密失败时同时删除输入明文，防止不完整批次保留未加密的转储。
    if [ -z "${Encrypt_Recipient}" ]; then
        rm -f "${in}"
        Log ERROR "启用了加密但没有配置 Encrypt_Recipient"
        return 1
    fi
    case "${Encrypt_Tool}" in
        age)
            if ! command -v age >/dev/null 2>&1; then
                rm -f "${in}"; Log ERROR "找不到 age 命令"; return 1
            fi
            age -r "${Encrypt_Recipient}" -o "${out}" "${in}"; rc=$?
            ;;
        gpg)
            if ! command -v gpg >/dev/null 2>&1; then
                rm -f "${in}"; Log ERROR "找不到 gpg 命令"; return 1
            fi
            gpg --batch --yes --trust-model always -e -r "${Encrypt_Recipient}" -o "${out}" "${in}"; rc=$?
            ;;
        *)
            rm -f "${in}"
            Log ERROR "Encrypt_Tool 只支持 age 或 gpg：${Encrypt_Tool}"
            return 1
            ;;
    esac
    [ "${rc}" -eq 0 ] || { rm -f "${out}" "${in}"; Log ERROR "加密失败：${in}"; return 1; }
    rm -f "${in}"
    printf '%s' "${out}"
    return 0
}

Decrypt_File()
{
    local in="$1" out="$2" rc=0
    case "${Encrypt_Tool}" in
        age)
            command -v age >/dev/null 2>&1 || { Err "找不到 age 命令"; return 1; }
            [ -f "${Encrypt_Identity}" ] || { Err "找不到解密私钥：${Encrypt_Identity}"; return 1; }
            age -d -i "${Encrypt_Identity}" -o "${out}" "${in}"; rc=$?
            ;;
        gpg)
            gpg --batch --yes -d -o "${out}" "${in}"; rc=$?
            ;;
        *) Err "Encrypt_Tool 只支持 age 或 gpg"; return 1 ;;
    esac
    return "${rc}"
}

Make_Checksums()
{
    local dir="$1"
    command -v sha256sum >/dev/null 2>&1 || { Log WARN "没有 sha256sum，跳过校验清单"; return 0; }
    ( cd "${dir}" && sha256sum -- *.gz *.enc 2>/dev/null > SHA256SUMS.part ) || true
    if [ -s "${dir}/SHA256SUMS.part" ]; then
        mv -f "${dir}/SHA256SUMS.part" "${dir}/SHA256SUMS"
        return 0
    fi
    rm -f "${dir}/SHA256SUMS.part"
    Log ERROR "生成校验清单失败：${dir}"
    return 1
}

Verify_Checksums()
{
    local dir="$1"
    [ -f "${dir}/SHA256SUMS" ] || { Err "缺少校验清单：${dir}/SHA256SUMS"; return 1; }
    command -v sha256sum >/dev/null 2>&1 || { Warn "没有 sha256sum，跳过校验"; return 0; }
    ( cd "${dir}" && sha256sum -c --quiet SHA256SUMS )
}

# ---------------------------------------------------------------------------
# 远端上传
# ---------------------------------------------------------------------------
Sftp_Run()
{
    sftp -b - \
        -P "${Remote_Port}" \
        -i "${Remote_SSH_Key}" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${Remote_Known_Hosts}" \
        -o BatchMode=yes \
        -o ConnectTimeout=30 \
        "${Remote_User}@${Remote_Host}"
}

Check_Remote_Conf()
{
    [ -n "${Remote_Host}" ] && [ -n "${Remote_User}" ] || { Log ERROR "远端主机或账号未配置"; return 1; }
    case "${Remote_Protocol}" in
        sftp) Check_Remote_Conf_Sftp ;;
        ftps|ftp) Check_Remote_Conf_Ftp ;;
        *) Log ERROR "未知的 Remote_Protocol：${Remote_Protocol}"; return 1 ;;
    esac
}

Check_Remote_Conf_Sftp()
{
    command -v sftp >/dev/null 2>&1 || { Log ERROR "找不到 sftp 命令"; return 1; }
    [ -f "${Remote_SSH_Key}" ] || { Log ERROR "缺少 SSH 私钥：${Remote_SSH_Key}"; return 1; }
    Check_Perm "${Remote_SSH_Key}" || return 1
    if [ ! -s "${Remote_Known_Hosts}" ]; then
        Log ERROR "缺少对端主机指纹文件：${Remote_Known_Hosts}
不会自动接受未知主机。先固定指纹并带外核对：
  ssh-keyscan -p ${Remote_Port} ${Remote_Host} > ${Remote_Known_Hosts}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# FTP / FTPS
#
# FTP 和 FTPS 适用于远端服务器不提供 SSH 的环境：
#
#   ftp   以明文传输账号口令和备份数据，仅应在隔离且可信的链路中使用；
#   ftps  使用 TLS 保护口令和数据，需启用对端证书校验。
#
# 上传顺序与 SFTP 一致：先传入 .incoming，核对大小后改名，最后清理旧批次。
# ---------------------------------------------------------------------------
Check_Remote_Conf_Ftp()
{
    command -v curl >/dev/null 2>&1 || { Log ERROR "找不到 curl 命令，ftp/ftps 上传依赖它。"; return 1; }
    [ -n "${Remote_Password}" ] || { Log ERROR "ftp/ftps 需要配置 Remote_Password。"; return 1; }
    if [ "${Remote_Protocol}" = "ftp" ]; then
        Log WARN "正在使用明文 FTP：账号口令与备份数据全程不加密。"
        Log WARN "条件允许时请改用 Remote_Protocol=sftp 或 ftps。"
    elif [ "${Remote_Ftp_Verify}" != "1" ]; then
        Log WARN "FTPS 已关闭证书校验，无法防中间人。仅在自签证书且已配 Remote_Ftp_CA 时才应关闭。"
    fi
    return 0
}

# URL 和账号写入权限 600 的临时 curl 配置，命令行参数仅包含 --config。
# 用法：Curl_Ftp <远端路径> [额外配置行...]
Curl_Ftp()
{
    local path="$1"; shift
    local cfg out rc
    cfg=$(mktemp "${TMPDIR:-/tmp}/.lnmp-ftp.XXXXXXXX") || return 1
    chmod 600 "${cfg}"
    {
        # 显式 FTPS 使用 ftp:// 和 AUTH TLS（ssl-reqd），不使用隐式 ftps://。
        printf 'url = "ftp://%s:%s/%s"\n' "${Remote_Host}" "${Remote_Port}" "${path}"
        printf 'user = "%s:%s"\n' "${Remote_User}" "${Remote_Password}"
        if [ "${Remote_Protocol}" = "ftps" ]; then
            printf 'ssl-reqd\n'
            if [ "${Remote_Ftp_Verify}" = "1" ]; then
                [ -n "${Remote_Ftp_CA}" ] && printf 'cacert = "%s"\n' "${Remote_Ftp_CA}"
            else
                printf 'insecure\n'
            fi
        fi
        printf 'silent\nshow-error\n'
        printf 'connect-timeout = 30\n'
        while [ "$#" -gt 0 ]; do printf '%s\n' "$1"; shift; done
    } > "${cfg}"
    out=$(curl --config "${cfg}" 2>&1)
    rc=$?
    rm -f "${cfg}"
    printf '%s' "${out}"
    return "${rc}"
}

# curl head 通过 FTP SIZE 获取 Content-Length，避免依赖不同服务器的 LIST 格式。
Ftp_Remote_Size()
{
    # Content-Length 通过 stdout 返回，因此不能设置 output = "/dev/null"，
    # 否则批次会因无法获取远端大小而保留在 .incoming。
    Curl_Ftp "$1" 'head' 2>/dev/null \
        | awk -F': ' 'tolower($1) == "content-length" { gsub(/\r/, "", $2); print $2; exit }'
}

Upload_Batch_Ftp()
{
    local type="$1" batch="$2" dir="${Backup_Home}/$1/$2"
    local staging="${Remote_Dir}/.incoming/${batch}-${type}"
    local f base rc out local_size remote_size ok=1

    Log INFO "上传 ${type}/${batch} 到 ${Remote_Protocol}://${Remote_Host}:${Remote_Port}/${Remote_Dir}"

    for f in "${dir}"/*; do
        [ -f "${f}" ] || continue
        base="${f##*/}"
        # ftp-create-dirs 同时创建 URL 路径中缺失的目录。
        if ! out=$(Curl_Ftp "${staging}/${base}" "upload-file = \"${f}\"" 'ftp-create-dirs'); then
            Log ERROR "上传失败：${base}
${out}"
            return 1
        fi
    done

    # 远端文件大小校验可发现缺失或截断，内容完整性由本地 SHA256SUMS 校验。
    for f in "${dir}"/*; do
        [ -f "${f}" ] || continue
        base="${f##*/}"
        local_size=$(stat -c '%s' "${f}" 2>/dev/null || stat -f '%z' "${f}" 2>/dev/null)
        remote_size=$(Ftp_Remote_Size "${staging}/${base}")
        if [ -z "${remote_size}" ]; then
            Log ERROR "远端缺少文件或取不到大小：${base}"; ok=0; continue
        fi
        if [ "${remote_size}" != "${local_size}" ]; then
            Log ERROR "远端文件大小不符：${base} 本地 ${local_size} 远端 ${remote_size}"; ok=0
        fi
    done
    if [ "${ok}" -ne 1 ]; then
        Log ERROR "远端核对未通过，保留 .incoming 供排查，不改名。"
        return 1
    fi

    # RNTO 需要已存在的父目录；同批次重新上传时先移除旧目录。
    # curl 的 quote 前缀 * 表示允许该命令失败。
    out=$(Curl_Ftp "" \
        "quote = \"*MKD ${Remote_Dir}\"" \
        "quote = \"*MKD ${Remote_Dir}/${type}\"" \
        "quote = \"*RMD ${Remote_Dir}/${type}/${batch}\"" \
        "quote = \"RNFR ${staging}\"" \
        "quote = \"RNTO ${Remote_Dir}/${type}/${batch}\"" \
        'list-only' 'output = "/dev/null"')
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        Log ERROR "远端改名失败（curl 退出码 ${rc}）：
${out}"
        return 1
    fi
    Log INFO "远端已提交：${type}/${batch}"
    return 0
}

Cleanup_Remote_Ftp()
{
    local type="$1" days="$2" b f out batches files
    out=$(Curl_Ftp "${Remote_Dir}/${type}/" 'list-only') || {
        Log WARN "无法列出远端 ${type} 目录，跳过远端清理。"; return 0; }
    # 先获取完整列表再遍历，确保循环状态和 Curl_Ftp 结果不被管道子 shell 隔离。
    # 批次名和文件名由脚本生成，不包含空格。
    batches=$(printf '%s\n' "${out}" | tr -d '\r')
    for b in ${batches}; do
        b="${b##*/}"
        Batch_Older_Than "${b}" "${days}" || continue
        Log INFO "清理远端过期批次：${type}/${b}"
        # FTP 不能直接删除非空目录，需先删除其中文件。
        files=$(Curl_Ftp "${Remote_Dir}/${type}/${b}/" 'list-only' 2>/dev/null | tr -d '\r')
        for f in ${files}; do
            [ -n "${f}" ] || continue
            Curl_Ftp "" "quote = \"*DELE ${Remote_Dir}/${type}/${b}/${f##*/}\"" \
                'output = "/dev/null"' >/dev/null 2>&1
        done
        Curl_Ftp "" "quote = \"*RMD ${Remote_Dir}/${type}/${b}\"" \
            'output = "/dev/null"' >/dev/null 2>&1
    done
    return 0
}

# 上传按“传输、核对、改名”的顺序执行，任一步失败都保留正式目录中的现有备份。
# SFTP、FTP 和 FTPS 使用相同提交语义。
Upload_Batch()
{
    Check_Remote_Conf || return 1
    case "${Remote_Protocol}" in
        sftp)     Upload_Batch_Sftp "$@" ;;
        ftps|ftp) Upload_Batch_Ftp  "$@" ;;
    esac
}

Upload_Batch_Sftp()
{
    local type="$1" batch="$2" dir="${Backup_Home}/$1/$2"
    local staging="${Remote_Dir}/.incoming/${batch}-${type}"
    local f base out rc local_size remote_size ok=1

    Log INFO "上传 ${type}/${batch} 到 ${Remote_User}@${Remote_Host}:${Remote_Dir}"

    {
        printf -- '-mkdir %s\n' "${Remote_Dir}"
        printf -- '-mkdir %s/.incoming\n' "${Remote_Dir}"
        printf -- '-mkdir %s\n' "${staging}"
        printf -- '-mkdir %s/%s\n' "${Remote_Dir}" "${type}"
        for f in "${dir}"/*; do
            [ -f "${f}" ] || continue
            printf 'put %s %s/\n' "${f}" "${staging}"
        done
        printf 'ls -l %s\n' "${staging}"
        printf 'bye\n'
    } > "${dir}/.sftp-put"

    out=$(Sftp_Run < "${dir}/.sftp-put" 2>&1); rc=$?
    rm -f "${dir}/.sftp-put"
    if [ "${rc}" -ne 0 ]; then
        Log ERROR "上传失败（sftp 退出码 ${rc}）：
${out}"
        return 1
    fi

    # internal-sftp 账号无法在远端执行 sha256sum，因此远端仅校验文件大小，
    # 用于发现缺失或截断；内容完整性由本地 SHA256SUMS 校验。
    for f in "${dir}"/*; do
        [ -f "${f}" ] || continue
        base="${f##*/}"
        local_size=$(stat -c '%s' "${f}" 2>/dev/null || stat -f '%z' "${f}" 2>/dev/null)
        # sftp ls -l 的最后一列包含路径和文件名，取 basename 后再与本地文件名比较。
        remote_size=$(printf '%s\n' "${out}" | awk -v n="${base}" \
            '{ p = $NF; sub(/.*\//, "", p); if (p == n) print $5 }' | tail -n 1)
        if [ -z "${remote_size}" ]; then
            Log ERROR "远端缺少文件：${base}"; ok=0; continue
        fi
        if [ "${remote_size}" != "${local_size}" ]; then
            Log ERROR "远端文件大小不符：${base} 本地 ${local_size} 远端 ${remote_size}"; ok=0
        fi
    done
    if [ "${ok}" -ne 1 ]; then
        Log ERROR "远端核对未通过，保留 .incoming 供排查，不改名。"
        return 1
    fi

    out=$(printf -- '-rm %s/%s/%s/*\n-rmdir %s/%s/%s\nrename %s %s/%s/%s\nbye\n' \
            "${Remote_Dir}" "${type}" "${batch}" \
            "${Remote_Dir}" "${type}" "${batch}" \
            "${staging}" "${Remote_Dir}" "${type}" "${batch}" | Sftp_Run 2>&1); rc=$?
    if [ "${rc}" -ne 0 ]; then
        Log ERROR "远端改名失败：
${out}"
        return 1
    fi
    Log INFO "远端已提交：${type}/${batch}"
    return 0
}

# 只在上传成功并生成新恢复点后清理远端旧批次。
Cleanup_Remote()
{
    Check_Remote_Conf || return 1
    case "${Remote_Protocol}" in
        sftp)     Cleanup_Remote_Sftp "$@" ;;
        ftps|ftp) Cleanup_Remote_Ftp  "$@" ;;
    esac
}

Cleanup_Remote_Sftp()
{
    local type="$1" days="$2" out rc b batches
    out=$(printf 'ls -1 %s/%s\nbye\n' "${Remote_Dir}" "${type}" | Sftp_Run 2>/dev/null); rc=$?
    [ "${rc}" -eq 0 ] || { Log WARN "无法列出远端 ${type} 目录，跳过远端清理。"; return 0; }
    # 先获取完整列表再遍历，避免在管道子 shell 中重复创建 SFTP 会话。
    batches=$(printf '%s\n' "${out}" | tr -d '\r')
    for b in ${batches}; do
        b="${b##*/}"
        Batch_Older_Than "${b}" "${days}" || continue
        Log INFO "清理远端过期批次：${type}/${b}"
        printf -- '-rm %s/%s/%s/*\n-rmdir %s/%s/%s\nbye\n' \
            "${Remote_Dir}" "${type}" "${b}" "${Remote_Dir}" "${type}" "${b}" \
            | Sftp_Run >/dev/null 2>&1
    done
    return 0
}

List_Remote_Batches()
{
    local type="$1" out rc err_file
    case "${Remote_Protocol}" in
        sftp)
            # SFTP 命令回显写入 stdout，错误写入 stderr；分开收集可正确判断错误类型，
            # stdout 中的 `sftp> ...` 回显在输出批次前过滤。
            err_file=$(mktemp) || return 1
            out=$(printf 'ls -1 %s/%s\nbye\n' "${Remote_Dir}" "${type}" \
                | Sftp_Run 2>"${err_file}"); rc=$?
            # 远端分类目录不存在表示该类型暂无批次，OpenSSH 的 not found 结果按空列表处理。
            if [ "${rc}" -ne 0 ] && grep -q "Can't ls:.*not found" "${err_file}"; then
                rm -f "${err_file}"
                return 0
            fi
            rm -f "${err_file}"
            ;;
        ftps|ftp)
            out=$(Curl_Ftp "${Remote_Dir}/${type}/" 'list-only' 2>/dev/null); rc=$?
            # curl 退出码 9 在列表阶段按空批次处理。FTP 无法区分目录不存在与权限不足，
            # 权限问题会在上传时返回明确错误。
            [ "${rc}" -eq 9 ] && return 0
            ;;
        *)
            Log ERROR "未知的 Remote_Protocol：${Remote_Protocol}"
            return 1
            ;;
    esac
    [ "${rc}" -eq 0 ] || return "${rc}"
    printf '%s\n' "${out}" | tr -d '\r' | grep -v '^sftp>' | sed 's#.*/##; /^$/d'
}

Cleanup_Local()
{
    local type="$1" days="$2" b
    for b in $(List_Batches "${type}"); do
        Batch_Older_Than "${b}" "${days}" || continue
        Log INFO "清理本地过期批次：${type}/${b}"
        Safe_Rm_Batch "${type}" "${b}"
    done
    return 0
}

# ---------------------------------------------------------------------------
# 站点配置解析：每行 域名|网站目录|数据库名（数据库名可为空）
# ---------------------------------------------------------------------------
Site_Field() { printf '%s' "$1" | awk -F'|' -v i="$2" '{gsub(/^[ \t]+|[ \t]+$/, "", $i); print $i}'; }

# 按域名筛选 Backup_Site，供 `lnmp backup run <域名>...` 使用。
# 任一域名不在配置中时中止任务，避免在无提示的情况下遗漏站点。
Filter_Sites()
{
    local want entry domain hit
    local -a kept=()
    for want in "$@"; do
        hit=0
        for entry in "${Backup_Site[@]}"; do
            domain=$(Site_Field "${entry}" 1)
            [ "${domain}" = "${want}" ] || continue
            hit=1
            kept+=("${entry}")
        done
        if [ "${hit}" -eq 0 ]; then
            Err "配置里没有站点 ${want}。当前配置的站点："
            for entry in "${Backup_Site[@]}"; do
                Err "  $(Site_Field "${entry}" 1)"
            done
            return 1
        fi
    done
    Backup_Site=("${kept[@]}")
    return 0
}

# ---------------------------------------------------------------------------
# 子命令：run
# ---------------------------------------------------------------------------
Run_Db()
{
    local batch="$1" dir="${Backup_Home}/db/${batch}" entry db out failed=0 n=0
    Find_Mysqldump || { Log ERROR "找不到 mysqldump，请在配置里设置 MySQL_Dump。"; return 1; }
    [ -f "${MySQL_Option_File}" ] || { Log ERROR "缺少数据库 option file：${MySQL_Option_File}"; return 1; }
    Check_Perm "${MySQL_Option_File}" || return 1

    mkdir -p "${dir}" || return 1
    chmod 700 "${dir}"
    for entry in "${Backup_Site[@]}"; do
        db=$(Site_Field "${entry}" 3)
        [ -n "${db}" ] || continue
        n=$((n + 1))
        Log INFO "导出数据库 ${db}"
        if ! Dump_Db "${db}" "${dir}/db-${db}.sql.gz"; then failed=1; continue; fi
        out=$(Encrypt_File "${dir}/db-${db}.sql.gz") || { failed=1; continue; }
    done
    if [ "${n}" -eq 0 ]; then
        Log WARN "本次选中的站点都没有配数据库名，跳过库备份。"
        rmdir "${dir}" 2>/dev/null
        return 0
    fi
    if [ "${failed}" -ne 0 ]; then
        # 全部失败时删除空批次目录；部分成功时保留已生成文件，
        # 且不生成校验清单，以便列表和恢复流程识别不完整批次。
        rmdir "${dir}" 2>/dev/null
        Log ERROR "数据库备份有失败项，批次 ${batch} 标记为不完整。"
        return 1
    fi
    Make_Checksums "${dir}" || return 1
    Log INFO "数据库备份完成：${dir}"
    return 0
}

Run_Web()
{
    local batch="$1" dir="${Backup_Home}/www/${batch}" entry domain path out failed=0 n=0 rc
    mkdir -p "${dir}" || return 1
    chmod 700 "${dir}"
    for entry in "${Backup_Site[@]}"; do
        domain=$(Site_Field "${entry}" 1)
        path=$(Site_Field "${entry}" 2)
        [ -n "${path}" ] || continue
        n=$((n + 1))
        Log INFO "打包网站 ${domain} (${path})"
        Tar_Dir "${path}" "${dir}/www-${domain}.tar.gz"; rc=$?
        [ "${rc}" -eq 0 ] || { failed=1; continue; }
        out=$(Encrypt_File "${dir}/www-${domain}.tar.gz") || { failed=1; continue; }
    done
    if [ "${n}" -eq 0 ]; then
        Log WARN "本次选中的站点都没有配网站目录，跳过网站备份。"
        rmdir "${dir}" 2>/dev/null
        return 0
    fi
    if [ "${failed}" -ne 0 ]; then
        # 全部失败时删除空批次目录，部分成功时保留已生成文件。
        rmdir "${dir}" 2>/dev/null
        Log ERROR "网站备份有失败项，批次 ${batch} 标记为不完整。"
        return 1
    fi
    Make_Checksums "${dir}" || return 1
    Log INFO "网站备份完成：${dir}"
    return 0
}

Web_Due()
{
    local last now diff
    [ "${Web_Interval_Days}" -le 1 ] && return 0
    last=$(State_Get Last_Web_Epoch 2>/dev/null)
    [ -n "${last}" ] || return 0
    now=$(date '+%s')
    diff=$(( (now - last) / 86400 ))
    [ "${diff}" -ge "${Web_Interval_Days}" ]
}

Cmd_Run()
{
    local what batch rc_db=0 rc_web=0 do_db=0 do_web=0 overall=0 partial=0

    # 用法：run [db|web|all] [域名...]
    # 首个 db、web 或 all 参数表示备份范围，其余参数均为站点域名。
    # 仅指定域名时等价于 run all <域名>，并立即备份文件和数据库。
    case "${1:-}" in
        db|web|all) what="$1"; shift ;;
        '')         what="auto" ;;
        -*)         Err "run 的用法：lnmp backup run [db|web|all] [域名...]"; return 1 ;;
        *)          what="all" ;;
    esac
    [ "$#" -eq 0 ] || partial=1

    Load_Conf || return 1
    if [ "${partial}" -eq 1 ]; then
        Filter_Sites "$@" || return 1
        Log INFO "本次只备份指定站点：$*"
    fi
    Acquire_Lock || return 1
    mkdir -p "${Backup_Home}" || Die "无法创建 ${Backup_Home}"
    chmod 700 "${Backup_Home}"

    case "${what}" in
        db)   do_db=1 ;;
        web)  do_web=1 ;;
        all)  do_db=1; do_web=1 ;;
        auto)
            do_db=1
            if Web_Due; then do_web=1; else Log INFO "网站备份未到周期（每 ${Web_Interval_Days} 天），本次跳过。"; fi
            ;;
    esac

    batch=$(New_Batch)
    Log INFO "开始备份，批次 ${batch}"
    State_Set Last_Run_Epoch "$(date '+%s')"
    State_Set Last_Run_Time "$(date '+%Y-%m-%d %H:%M:%S')"

    if [ "${do_db}" -eq 1 ]; then
        Run_Db "${batch}"; rc_db=$?
        if [ "${rc_db}" -eq 0 ] && [ -d "${Backup_Home}/db/${batch}" ]; then
            State_Set Last_Db_Batch "${batch}"
            if [ "${Enable_Remote_Backup}" = "1" ]; then
                if Upload_Batch db "${batch}"; then
                    [ "${partial}" -eq 1 ] || Cleanup_Remote db "${Keep_Days_Db}"
                else
                    rc_db=1
                fi
            fi
        fi
        [ "${rc_db}" -eq 0 ] || overall=1
    fi

    if [ "${do_web}" -eq 1 ]; then
        Run_Web "${batch}"; rc_web=$?
        if [ "${rc_web}" -eq 0 ] && [ -d "${Backup_Home}/www/${batch}" ]; then
            State_Set Last_Web_Batch "${batch}"
            # 部分站点备份不更新全量备份周期，避免下次 auto 误跳过全量网站备份。
            [ "${partial}" -eq 1 ] || State_Set Last_Web_Epoch "$(date '+%s')"
            if [ "${Enable_Remote_Backup}" = "1" ]; then
                if Upload_Batch www "${batch}"; then
                    [ "${partial}" -eq 1 ] || Cleanup_Remote www "${Keep_Days_Web}"
                else
                    rc_web=1
                fi
            fi
        fi
        [ "${rc_web}" -eq 0 ] || overall=1
    fi

    # 只在完整备份成功并生成新恢复点后清理旧批次。
    # 指定站点的部分备份不触发过期清理。
    if [ "${partial}" -eq 1 ]; then
        Log INFO "本次是指定站点的备份，跳过过期清理。"
    elif [ "${overall}" -eq 0 ]; then
        [ "${do_db}" -eq 1 ]  && Cleanup_Local db  "${Keep_Days_Db}"
        [ "${do_web}" -eq 1 ] && Cleanup_Local www "${Keep_Days_Web}"
    else
        Log WARN "本次备份存在失败项，跳过清理，旧备份全部保留。"
    fi

    State_Set Last_Run_Rc "${overall}"
    if [ "${overall}" -eq 0 ]; then
        State_Set Last_Error ""
        Log INFO "备份完成，批次 ${batch}"
        Ok "备份完成：${batch}"
    else
        State_Set Last_Error "批次 ${batch} 存在失败项，详见 ${Log_File}"
        Log ERROR "备份未完全成功，批次 ${batch}"
    fi
    return "${overall}"
}

# ---------------------------------------------------------------------------
# 子命令：status / list
# ---------------------------------------------------------------------------
Cmd_Status()
{
    local rc last err next
    Load_Conf || return 1
    Say "配置文件：${Conf_File}"
    Say "备份目录：${Backup_Home}"
    Say "保留天数：数据库 ${Keep_Days_Db} 天，网站 ${Keep_Days_Web} 天"
    Say "网站周期：每 ${Web_Interval_Days} 天"
    Say "异地上传：$([ "${Enable_Remote_Backup}" = "1" ] && echo "启用（${Remote_Protocol}） → ${Remote_User}@${Remote_Host}:${Remote_Dir}" || echo "未启用")"
    Say "加密    ：$([ "${Enable_Encrypt}" = "1" ] && echo "${Encrypt_Tool}" || echo "未启用")"
    Say ""
    last=$(State_Get Last_Run_Time); rc=$(State_Get Last_Run_Rc); err=$(State_Get Last_Error)
    if [ -z "${last}" ]; then
        Warn "还没有执行过备份。执行一次：lnmp backup run"
    else
        Say "上次执行：${last}"
        if [ "${rc:-1}" = "0" ]; then Ok "上次结果：成功"; else Err "上次结果：失败 —— ${err:-详见 ${Log_File}}"; fi
        Say "最近库批次：$(State_Get Last_Db_Batch)"
        Say "最近网站批次：$(State_Get Last_Web_Batch)"
    fi
    Say ""
    Say "本地批次：数据库 $(List_Batches db | wc -l) 个，网站 $(List_Batches www | wc -l) 个"
    if [ -f "${Systemd_Timer}" ] && command -v systemctl >/dev/null 2>&1; then
        next=$(systemctl list-timers lnmp-backup.timer --no-pager 2>/dev/null | sed -n '2p')
        Say "定时任务：systemd timer${next:+ → ${next}}"
    elif [ -f "${Cron_File}" ]; then
        Say "定时任务：cron（${Cron_File}）"
    else
        Warn "定时任务：未配置，备份不会自动执行。执行 lnmp backup init 配置。"
    fi
    Say "日志    ：${Log_File}"
    return 0
}

Cmd_List()
{
    local what="${1:-all}" type b dir size remote mark
    Load_Conf || return 1
    for type in db www; do
        case "${what}" in db) [ "${type}" = "db" ] || continue ;; web) [ "${type}" = "www" ] || continue ;; esac
        Say "=== 本地 ${type} 批次 ==="
        for b in $(List_Batches "${type}"); do
            dir="${Backup_Home}/${type}/${b}"
            size=$(du -sh "${dir}" 2>/dev/null | cut -f1)
            # SHA256SUMS 只在批次完整成功后生成；缺少清单表示该批次不可用于恢复。
            mark=''
            [ -f "${dir}/SHA256SUMS" ] || mark='  [不完整：缺校验清单]'
            printf '  %s  %s  %s 个文件%s\n' "${b}" "${size:-?}" \
                "$(find "${dir}" -maxdepth 1 -type f -name '*.gz*' 2>/dev/null | wc -l)" "${mark}"
        done
    done
    # 异地备份已启用时，远端配置或列表查询失败会返回非零状态，
    # 防止定时任务将仅列出本地批次误判为完整成功。
    if [ "${Enable_Remote_Backup}" = "1" ]; then
        Check_Remote_Conf || return 1
        for type in db www; do
            case "${what}" in db) [ "${type}" = "db" ] || continue ;; web) [ "${type}" = "www" ] || continue ;; esac
            Say "=== 远端 ${type} 批次 ==="
            if ! remote=$(List_Remote_Batches "${type}"); then
                Err "无法列出远端 ${type} 批次。"
                return 1
            fi
            printf '%s\n' "${remote}" | sed '/^$/d; s/^/  /'
        done
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 子命令：restore
# ---------------------------------------------------------------------------
Latest_Batch() { List_Batches "$1" | tail -n 1; }

Prepare_Payload()
{
    local src="$1" work="$2" base out
    base="${src##*/}"
    if [ "${base%.enc}" != "${base}" ]; then
        out="${work}/${base%.enc}"
        Decrypt_File "${src}" "${out}" || return 1
        printf '%s' "${out}"
    else
        printf '%s' "${src}"
    fi
    return 0
}

Cmd_Restore()
{
    local kind="${1:-}" name="${2:-}" batch="${3:-}" dir file work payload mysql_bin rc
    local gz_rc mysql_rc pipe_st
    Load_Conf || return 1
    case "${kind}" in
        db|web) : ;;
        *) Err "用法：lnmp backup restore db <数据库名> [批次]"
           Err "      lnmp backup restore web <站点域名> [批次]"; return 1 ;;
    esac
    [ -n "${name}" ] || { Err "缺少名称。"; return 1; }

    if [ "${kind}" = "db" ]; then
        [ -n "${batch}" ] || batch=$(Latest_Batch db)
        dir="${Backup_Home}/db/${batch}"
        file="${dir}/db-${name}.sql.gz"
    else
        [ -n "${batch}" ] || batch=$(Latest_Batch www)
        dir="${Backup_Home}/www/${batch}"
        file="${dir}/www-${name}.tar.gz"
    fi
    [ -n "${batch}" ] || { Err "没有可用批次。"; return 1; }
    [ -d "${dir}" ] || { Err "批次不存在：${dir}"; return 1; }
    [ -f "${file}" ] || [ -f "${file}.enc" ] || { Err "备份里没有 ${name}：${file}"; return 1; }
    [ -f "${file}" ] || file="${file}.enc"

    Say "批次：${batch}"
    Verify_Checksums "${dir}" || { Err "校验清单不匹配，拒绝用这份备份恢复。"; return 1; }
    Ok "SHA256 校验通过。"

    work=$(mktemp -d "${Backup_Home}/.restore.XXXXXXXX") || return 1
    Tmp_Work="${work}"
    payload=$(Prepare_Payload "${file}" "${work}") || { Err "解密失败。"; return 1; }

    if [ "${kind}" = "db" ]; then
        mysql_bin=$(Find_Mysql_Client) || { Err "找不到 mysql 客户端。"; return 1; }
        Warn "即将把备份导入数据库 ${name}，库中同名表会被覆盖，且无法撤销。"
        Say "5 秒后开始，Ctrl+C 取消..."
        sleep 5
        gzip -dc "${payload}" | "${mysql_bin}" --defaults-file="${MySQL_Option_File}" \
            --default-character-set=utf8mb4 "${name}"
        pipe_st=("${PIPESTATUS[@]}")
        gz_rc=${pipe_st[0]}; mysql_rc=${pipe_st[1]}
        if [ "${gz_rc}" -ne 0 ] || [ "${mysql_rc}" -ne 0 ]; then
            Err "导入失败（gzip=${gz_rc} mysql=${mysql_rc}）。"
            return 1
        fi
        Ok "数据库 ${name} 已从批次 ${batch} 恢复。"
    else
        local target
        target=$(printf '%s\n' "${Backup_Site[@]}" | awk -F'|' -v d="${name}" '$1 == d { print $2 }' | head -n 1)
        [ -n "${target}" ] || { Err "配置里没有站点 ${name}，无法确定恢复目录。"; return 1; }
        Warn "即将把备份解压覆盖到 ${target}，同名文件会被替换。"
        Say "5 秒后开始，Ctrl+C 取消..."
        sleep 5
        tar zxf "${payload}" -C "${target%/*}" || { Err "解压失败。"; return 1; }
        Ok "站点 ${name} 已从批次 ${batch} 恢复到 ${target}。"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 子命令：test —— 试恢复
#
# 最新数据库备份会导入临时库并检查数据表，验证完成后删除临时库，
# 用于确认备份可恢复且不影响现有数据。
# ---------------------------------------------------------------------------
Cmd_Test()
{
    local batch dir file work payload mysql_bin tmpdb rc tables
    local gz_rc mysql_rc pipe_st
    Load_Conf || return 1
    mysql_bin=$(Find_Mysql_Client) || { Err "找不到 mysql 客户端。"; return 1; }
    Check_Perm "${MySQL_Option_File}" || return 1

    batch=$(Latest_Batch db)
    [ -n "${batch}" ] || { Err "还没有任何数据库备份。"; return 1; }
    dir="${Backup_Home}/db/${batch}"
    Say "试恢复批次：${batch}"
    Verify_Checksums "${dir}" || { Err "校验清单不匹配。"; return 1; }
    Ok "SHA256 校验通过。"

    file=$(find "${dir}" -maxdepth 1 -type f \( -name 'db-*.sql.gz' -o -name 'db-*.sql.gz.enc' \) | head -n 1)
    [ -n "${file}" ] || { Err "批次里没有数据库转储。"; return 1; }

    work=$(mktemp -d "${Backup_Home}/.test.XXXXXXXX") || return 1
    Tmp_Work="${work}"
    payload=$(Prepare_Payload "${file}" "${work}") || { Err "解密失败。"; return 1; }

    tmpdb="lnmp_bktest_$(date '+%s')"
    "${mysql_bin}" --defaults-file="${MySQL_Option_File}" \
        -e "CREATE DATABASE \`${tmpdb}\`;" || { Err "无法创建临时库 ${tmpdb}。"; return 1; }

    gzip -dc "${payload}" | "${mysql_bin}" --defaults-file="${MySQL_Option_File}" \
        --default-character-set=utf8mb4 "${tmpdb}"
    pipe_st=("${PIPESTATUS[@]}")
    gz_rc=${pipe_st[0]}; mysql_rc=${pipe_st[1]}
    rc=0
    [ "${gz_rc}" -ne 0 ] && rc=1
    [ "${mysql_rc}" -ne 0 ] && rc=1

    tables=$("${mysql_bin}" --defaults-file="${MySQL_Option_File}" -N -B \
        -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${tmpdb}';" 2>/dev/null)

    "${mysql_bin}" --defaults-file="${MySQL_Option_File}" \
        -e "DROP DATABASE \`${tmpdb}\`;" >/dev/null 2>&1

    if [ "${rc}" -ne 0 ]; then
        Log ERROR "试恢复失败：gzip=${gz_rc} mysql=${mysql_rc}（批次 ${batch}）"
        return 1
    fi
    if [ -z "${tables}" ] || [ "${tables}" -eq 0 ]; then
        Log ERROR "试恢复失败：导入后临时库里没有任何表（批次 ${batch}）"
        return 1
    fi
    State_Set Last_Test_Time "$(date '+%Y-%m-%d %H:%M:%S')"
    State_Set Last_Test_Rc 0
    Log INFO "试恢复通过：批次 ${batch}，${tables} 张表"
    Ok "试恢复通过：${batch}（${tables} 张表）"
    return 0
}

# ---------------------------------------------------------------------------
# 子命令：init
# ---------------------------------------------------------------------------
# 从现有 vhost 配置读取域名和站点目录，再从 wp-config.php 读取数据库名。
# 新建站点后可重新执行 init 扫描，或直接在备份配置中添加站点。
Discover_Sites()
{
    local f root domain db
    for f in /usr/local/nginx/conf/vhost/*.conf; do
        [ -f "${f}" ] || continue
        domain=$(awk '/^[ \t]*server_name/ {gsub(/;/,""); print $2; exit}' "${f}")
        root=$(awk '/^[ \t]*root/ {gsub(/;/,""); print $2; exit}' "${f}")
        [ -n "${domain}" ] && [ -n "${root}" ] || continue
        db=$(Guess_Db "${root}")
        printf '%s|%s|%s\n' "${domain}" "${root%/}" "${db}"
    done
    for f in /usr/local/apache/conf/vhost/*.conf; do
        [ -f "${f}" ] || continue
        domain=$(awk '/^[ \t]*ServerName/ {print $2; exit}' "${f}")
        root=$(awk '/^[ \t]*DocumentRoot/ {gsub(/"/,""); print $2; exit}' "${f}")
        [ -n "${domain}" ] && [ -n "${root}" ] || continue
        db=$(Guess_Db "${root}")
        printf '%s|%s|%s\n' "${domain}" "${root%/}" "${db}"
    done
}

# 扫描后由使用者确认备份站点，可排除 default 占位站点、测试站或不需要备份的静态目录。
# 选择结果保存到 Picked_Sites，不使用 nameref 以兼容 Bash 4.2。
Picked_Sites=()
Select_Sites()
{
    local line ans tok i idx n mode tries=0 bad
    local -a all=() toks=() hit=() keep=()

    while IFS= read -r line; do
        [ -n "${line}" ] && all+=("${line}")
    done <<< "$1"
    n=${#all[@]}
    Picked_Sites=()
    [ "${n}" -gt 0 ] || return 0

    Say "发现以下站点（域名 | 目录 | 数据库）："
    for ((i = 0; i < n; i++)); do
        printf '  %2d) %s\n' "$((i + 1))" "$(printf '%s' "${all[i]}" | sed 's/|/  |  /g')"
    done
    Say ""
    Say "选择要备份的站点："
    Say "  回车        全部备份"
    Say "  1 3         只备份 1、3 号（也可以写域名）"
    Say "  -2          除 2 号以外全部备份（也可以写 -default）"

    while :; do
        printf '> '
        if ! read -r ans; then
            echo
            Warn "非交互执行，按全部站点写入配置。"
            Picked_Sites=("${all[@]}")
            return 0
        fi
        ans="${ans//,/ }"
        if [ -z "${ans// /}" ]; then
            Picked_Sites=("${all[@]}")
            return 0
        fi

        # read -a 按 IFS 分隔输入且不展开通配符，输入 * 不会转换为文件名。
        read -r -a toks <<< "${ans}"
        hit=(); for ((i = 0; i < n; i++)); do hit[i]=0; done
        mode=""; bad=0
        for tok in "${toks[@]}"; do
            case "${tok}" in
                -*) if [ "${mode}" = "keep" ]; then
                        Err "不能把“只备份”和“排除”两种写法混在一起。"; bad=1; break
                    fi
                    mode="drop"; tok="${tok#-}" ;;
                *)  if [ "${mode}" = "drop" ]; then
                        Err "不能把“只备份”和“排除”两种写法混在一起。"; bad=1; break
                    fi
                    mode="keep" ;;
            esac
            idx=-1
            if Is_Number "${tok}"; then
                [ "${tok}" -ge 1 ] && [ "${tok}" -le "${n}" ] && idx=$((tok - 1))
                [ "${idx}" -ge 0 ] && hit[idx]=1
            else
                for ((i = 0; i < n; i++)); do
                    [ "$(Site_Field "${all[i]}" 1)" = "${tok}" ] || continue
                    hit[i]=1; idx=${i}
                done
            fi
            if [ "${idx}" -lt 0 ]; then
                Err "无法识别：${tok}"; bad=1; break
            fi
        done

        if [ "${bad}" -eq 0 ]; then
            keep=()
            for ((i = 0; i < n; i++)); do
                if [ "${mode}" = "drop" ]; then
                    [ "${hit[i]}" -eq 1 ] && continue
                else
                    [ "${hit[i]}" -eq 1 ] || continue
                fi
                keep+=("${all[i]}")
            done
            if [ "${#keep[@]}" -eq 0 ]; then
                Err "这样选下来一个站点都不剩。"
                bad=1
            else
                Picked_Sites=("${keep[@]}")
                Say "本次写入配置的站点："
                printf '%s\n' "${Picked_Sites[@]}" | sed 's/^/  /'
                return 0
            fi
        fi

        tries=$((tries + 1))
        if [ "${tries}" -ge 3 ]; then
            Warn "连续三次输入无效，按全部站点写入配置。"
            Picked_Sites=("${all[@]}")
            return 0
        fi
        Say "请重新输入。"
    done
}

Guess_Db()
{
    local root="$1"
    [ -f "${root}/wp-config.php" ] || return 0
    sed -n "s/.*define(\s*['\"]DB_NAME['\"]\s*,\s*['\"]\([^'\"]*\)['\"].*/\1/p" \
        "${root}/wp-config.php" | head -n 1
}

Write_Systemd_Unit()
{
    local hour="${1:-3}"
    # unit 写入、权限设置和启用均需成功，否则定时备份无法自动执行。
    cat > "${Systemd_Service}" <<'EOF' || { Err "写入 ${Systemd_Service} 失败。"; return 1; }
[Unit]
Description=LNMP backup (websites and databases)
After=network-online.target mysql.service mariadb.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/lnmp-backup run
Nice=10
IOSchedulingClass=idle
EOF
    cat > "${Systemd_Timer}" <<EOF || { Err "写入 ${Systemd_Timer} 失败。"; return 1; }
[Unit]
Description=LNMP backup timer

[Timer]
OnCalendar=*-*-* ${hour}:30:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 "${Systemd_Service}" "${Systemd_Timer}" \
        || { Err "设置 unit 文件权限失败。"; return 1; }
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now lnmp-backup.timer >/dev/null 2>&1 \
        || { Err "启用 lnmp-backup.timer 失败，请手工检查。"; return 1; }
    Ok "已启用 systemd timer：每天 ${hour}:30 前后执行（带随机延迟）。"
    return 0
}

Write_Cron()
{
    local hour="${1:-3}"
    cat > "${Cron_File}" <<EOF || { Err "写入 ${Cron_File} 失败。"; return 1; }
# LNMP backup —— 由 lnmp backup init 生成
30 ${hour} * * * root /bin/lnmp-backup run
EOF
    chmod 644 "${Cron_File}" || { Err "设置 ${Cron_File} 权限失败。"; return 1; }
    Ok "已写入 cron：${Cron_File}"
    return 0
}

Cmd_Init()
{
    local sites site_lines ans hour db_pass db_sock mysql_bin my_cnf_tmp
    local backup_home="/home/backup"

    Say "配置文件位于：${Conf_File}，可根据实际需求修改相关参数，例如备份计划、是否上传备份文件等。"
    Say "如需开启上传功能，请先安装 pure-ftpd 并完成相关配置。"
    Say "如需修改配置，请先按 Ctrl+C 退出当前程序，修改配置文件后重新运行即可。"
    Say ""
    printf '确认开始配置请输入 y，其它输入一律取消：'
    read -r ans
    [ "${ans}" = "y" ] || { Say "已取消。"; return 0; }

    [ "$(id -u)" = "0" ] || { Err "init 需要 root 权限。"; return 1; }
    mkdir -p "${Conf_Dir}" && chmod 700 "${Conf_Dir}" || { Err "无法创建 ${Conf_Dir}"; return 1; }
    mkdir -p "${State_Dir}" "${Log_File%/*}" 2>/dev/null

    if [ -f "${Conf_File}" ]; then
        Warn "配置已存在：${Conf_File}"
        printf '覆盖并重新生成？[y/N]（默认 n）：'
        read -r ans
        [ "${ans}" = "y" ] || { Say "保留现有配置。"; return 0; }
        cp -p "${Conf_File}" "${Conf_File}.bak.$(date '+%Y%m%d%H%M%S')"
        Say "旧配置已备份。"
    fi

    Say "扫描已有站点..."
    sites=$(Discover_Sites)
    if [ -n "${sites}" ]; then
        Select_Sites "${sites}"
        site_lines=$(printf '%s\n' "${Picked_Sites[@]}" | sed 's/^/    "/; s/$/"/')
    else
        Warn "没有扫描到站点，配置里会留一条示例，请手工填写。"
        site_lines='    #"example.com|/home/wwwroot/example.com|wpdb"'
    fi

    # 数据库口令仅写入权限 0600 的 option file，不出现在命令行或备份配置中。
    if [ ! -f "${My_Cnf}" ]; then
        printf '输入数据库 root 密码（用于导出，留空则跳过，不回显）：'
        if ! read -r -s db_pass; then
            echo
            Err "读取数据库 root 密码时遇到 EOF。"
            return 1
        fi
        echo
        if [ -n "${db_pass}" ]; then
            # option file 在引号内将反斜杠解析为转义符，写入前需加倍。
            db_pass="${db_pass//\\/\\\\}"
            db_sock=$(Get_Actual_DB_Socket)
            my_cnf_tmp=$(mktemp "${My_Cnf}.XXXXXXXX") || return 1
            ( umask 077; cat > "${my_cnf_tmp}" <<EOF
[mysqldump]
user=root
password='${db_pass}'
socket=${db_sock}

[client]
user=root
password='${db_pass}'
socket=${db_sock}
EOF
            )
            chmod 600 "${my_cnf_tmp}"
            if ! mysql_bin=$(Find_Mysql_Client); then
                rm -f "${my_cnf_tmp}"
                Err "找不到 mysql 客户端，无法校验数据库凭据。"
                return 1
            fi
            if ! "${mysql_bin}" --defaults-file="${my_cnf_tmp}" -e "SELECT 1;" >/dev/null 2>&1; then
                rm -f "${my_cnf_tmp}"
                Err "数据库凭据校验失败，未写入配置，也未启用定时任务。"
                return 1
            fi
            mv -f "${my_cnf_tmp}" "${My_Cnf}" || { rm -f "${my_cnf_tmp}"; return 1; }
            Ok "数据库凭据校验通过，已写入 ${My_Cnf}（600）。"
        else
            Warn "跳过数据库凭据，库备份会因此失败。稍后可重跑 init 补上。"
        fi
    else
        Check_Perm "${My_Cnf}" || return 1
        if ! mysql_bin=$(Find_Mysql_Client); then
            Err "找不到 mysql 客户端，无法校验已有数据库凭据。"
            return 1
        fi
        if ! "${mysql_bin}" --defaults-file="${My_Cnf}" -e "SELECT 1;" >/dev/null 2>&1; then
            Err "已有数据库凭据校验失败，未改写配置或定时任务。"
            return 1
        fi
        Say "沿用已有的数据库凭据文件：${My_Cnf}"
    fi

    # 备份目录需有足够空间容纳站点文件和数据库，可在初始化时选择独立存储路径。
    while :; do
        printf '备份存放目录（回车用默认 %s）: ' "${backup_home}"
        read -r ans || { echo; Say "非交互执行，使用默认 ${backup_home}。"; break; }
        [ -n "${ans}" ] || break
        if Check_Backup_Home "${ans}"; then backup_home="${ans%/}"; break; fi
    done

    cat > "${Conf_File}" <<EOF
# LNMP 备份配置 —— 由 lnmp backup init 生成
#
# 配置文件修改后直接生效；只有调整定时任务的执行时间需重新执行 init。
#
# 站点条目格式：域名|网站目录|数据库名
#   数据库名留空表示这个站点只备份文件。
#   新建站点后需添加条目，或重新执行 lnmp backup init 扫描。

Backup_Home="${backup_home}"

# 留空则自动探测 /usr/local/{mysql,mariadb}/bin/mysqldump
MySQL_Dump=""
MySQL_Option_File="${My_Cnf}"

Backup_Site=(
${site_lines}
)

# 数据库和网站文件独立计算保留期，过期批次会被删除。
Keep_Days_Db=14
Keep_Days_Web=60

# 网站文件备份周期（天）；1 表示每天，数据库在每次任务中都会备份。
Web_Interval_Days=7

# ---- 异地上传 ----
Enable_Remote_Backup=0

# 上传方式：sftp 使用 SSH 密钥，ftps 使用 TLS 和密码，ftp 为明文传输。
# sftp 通常使用端口 22，ftp 和 ftps 通常使用端口 21。
Remote_Protocol="sftp"

Remote_Host=""
Remote_Port=22
Remote_User=""
Remote_Dir="backup"

# 仅 ftp 和 ftps 使用。
Remote_Password=""
# FTPS 证书校验；自签证书应通过 Remote_Ftp_CA 指定 CA。
Remote_Ftp_Verify=1
Remote_Ftp_CA=""
# 使用专用备份密钥，避免复用日常登录密钥。
Remote_SSH_Key="/root/.ssh/lnmp_backup"
# 预先固定并通过独立渠道核对主机指纹：
#   ssh-keyscan -p 22 <主机> > /root/.ssh/lnmp_backup_known_hosts
Remote_Known_Hosts="/root/.ssh/lnmp_backup_known_hosts"

# ---- 可选加密 ----
Enable_Encrypt=0
Encrypt_Tool="age"
Encrypt_Recipient=""
Encrypt_Identity="/root/.config/lnmp/backup-age.key"
EOF
    chmod 600 "${Conf_File}"
    Ok "配置已写入 ${Conf_File}（600）。"

    mkdir -p "${backup_home}" && chmod 700 "${backup_home}"

    printf '每天几点执行备份？(0-23，默认 3) '
    read -r hour
    case "${hour}" in ''|*[!0-9]*) hour=3 ;; esac
    [ "${hour}" -gt 23 ] 2>/dev/null && hour=3

    local timer_rc=0
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        Write_Systemd_Unit "${hour}" || timer_rc=1
    else
        Write_Cron "${hour}" || timer_rc=1
    fi

    Notice_Review_Conf "${backup_home}"
    # 配置已写入但定时任务安装失败时返回错误，避免用户误认自动备份已启用。
    if [ "${timer_rc}" -ne 0 ]; then
        Err "配置已写入，但定时任务未能安装，备份不会自动执行。"
        Err "请按上面的错误处理后重新执行 lnmp backup init，或手工配置定时任务。"
        return 1
    fi
    return 0
}

# 初始化完成后显示配置位置、备份目录和常用操作命令。
Notice_Review_Conf()
{
    local home="${1:-}"
    Say ""
    Color "1;33" "══════════════════════════════════════════════════════"
    Say "  配置已写入：${Conf_File}"
    Say "  备份目录：${home}"
    Color "1;33" "══════════════════════════════════════════════════════"
    Say "  编辑配置：nano ${Conf_File}"
    Say "  立即备份：lnmp backup run all"
    Say "  只备份一个站点：lnmp backup run <域名>"
    Say "  验证可恢复：lnmp backup test"
    Say ""
    return 0
}

# ---------------------------------------------------------------------------
Usage()
{
    cat <<'EOF'
用法：lnmp backup <子命令>

  init                      生成配置、备份目录与定时任务
  run [db|web|all]          执行备份；不带参数按配置的周期决定是否备份网站
  run <域名>...             只备份指定站点（文件与它的库）
  run db|web <域名>...      只备份指定站点的库 / 文件
  status                    上次执行结果、下次计划与配置概览
  list [db|web]             列出批次（配了异地上传则一并列远端）
  restore db  <库名> [批次]  从备份恢复数据库
  restore web <域名> [批次]  从备份恢复网站文件
  test                      试恢复：把最新库备份导入临时库校验后删除

配置文件：/etc/lnmp/backup.conf（权限 600）
日志：/var/log/lnmp/backup.log
EOF
}

Main()
{
    local cmd="${1:-}"
    [ -n "${cmd}" ] && shift
    case "${cmd}" in
        init)    Cmd_Init "$@" ;;
        run)     Cmd_Run "$@" ;;
        status)  Cmd_Status "$@" ;;
        list)    Cmd_List "$@" ;;
        restore) Cmd_Restore "$@" ;;
        test)    Cmd_Test "$@" ;;
        help|-h|--help) Usage ;;
        *)       Usage; return 1 ;;
    esac
}

Main "$@"
