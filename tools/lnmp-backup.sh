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
#   lnmp backup remote-setup [s3]    配置 SFTP 或 S3 兼容对象存储异地上传
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
# 对象存储无目录改名，核对通过后写入提交清单对象，无清单的批次视为未提交。
# 旧批次只在新恢复点可用后清理，传输失败时仍保留现有备份。
#
# 数据库口令保存在权限 0600 的 option file 中，SFTP 上传使用 SSH 密钥，
# 对象存储访问密钥保存在权限 0600 的 rclone 配置中，防止凭据出现在命令行参数中。
# ---------------------------------------------------------------------------

set -u

# 服务运行部分：源码目录中执行时按相对路径加载，部署时由 include/rt/cli_assemble.sh 以文件内容替换本行。
. "$(dirname "${BASH_SOURCE[0]}")/../include/rt/svc.sh" # @RT_SVC@
. "$(dirname "${BASH_SOURCE[0]}")/../include/rt/db.sh" # @RT_DB@

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
Rclone_Remote="lnmp"
Rclone_Commit=".lnmp-commit"

# rclone 固定版本，哈希取自官方 SHA256SUMS（PGP 签名已核对），与 src/checksums.sha256 一致。
Rclone_Ver="1.75.2"
Rclone_Sha256_amd64="349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702"
Rclone_Sha256_arm64="7e1e8d69654941b7b7df84ee74c5f7fb09cce7d5496947fb7bf16b55ff427d10"
Rclone_Min_Ver="1.60.0"

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
    # 仅 s3 使用。
    Remote_S3_Bucket=""
    Remote_S3_Delete=0
    Remote_Bwlimit=""
    Rclone_Bin=""
    Rclone_Conf="${Conf_Dir}/backup-rclone.conf"
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
        sftp|ftps|ftp|s3) : ;;
        *) Die "Remote_Protocol 只能是 sftp、ftps、ftp 或 s3，当前是 '${Remote_Protocol}'" ;;
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

# ---------------------------------------------------------------------------
# 并发锁保证同一时刻只运行一个备份任务，避免批次写入、上传和清理互相干扰。
# ---------------------------------------------------------------------------
Lock_Dir=""
Tmp_Work=""
Tmp_File=""

# 退出时统一删除锁目录、临时工作目录和临时文件。
Cleanup_All()
{
    [ -n "${Lock_Dir}" ] && [ -d "${Lock_Dir}" ] && rm -rf -- "${Lock_Dir}"
    [ -n "${Tmp_Work}" ] && [ -d "${Tmp_Work}" ] && rm -rf -- "${Tmp_Work}"
    [ -n "${Tmp_File}" ] && [ -f "${Tmp_File}" ] && rm -f -- "${Tmp_File}"
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
        --max-allowed-packet=1G --single-transaction --quick --routines --triggers --events \
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
    # 磁盘写满时留下的不完整转储，判定规则与数据库模块 _Database_Check_Backup 一致。
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
    case "${Remote_Protocol}" in
        sftp|ftps|ftp)
            [ -n "${Remote_Host}" ] && [ -n "${Remote_User}" ] || { Log ERROR "远端主机或账号未配置"; return 1; } ;;
    esac
    case "${Remote_Protocol}" in
        sftp) Check_Remote_Conf_Sftp ;;
        ftps|ftp) Check_Remote_Conf_Ftp ;;
        s3) Check_Remote_Conf_S3 ;;
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

# ---------------------------------------------------------------------------
# S3 兼容对象存储（rclone）
#
# 对象路径为 <桶>/<Remote_Dir>/<类型>/<批次>/<文件>。文件直接上传到批次前缀，
# 按大小与 MD5 核对后写入提交清单对象 .lnmp-commit，无清单的批次视为未提交。
# Remote_S3_Delete=0 表示访问密钥不含删除权限，过期批次与未完成分片由桶生命周期规则清理。
# ---------------------------------------------------------------------------
Find_Rclone()
{
    local c
    if [ -n "${Rclone_Bin}" ]; then
        [ -x "${Rclone_Bin}" ]
        return
    fi
    for c in /usr/local/bin/rclone /usr/bin/rclone; do
        [ -x "${c}" ] || continue
        Rclone_Bin="${c}"
        return 0
    done
    return 1
}

Rclone_Version()
{
    "$1" version 2>/dev/null | awk 'NR == 1 { v = $2; sub(/^v/, "", v); sub(/-.*/, "", v); print v; exit }'
}

# 凭据只在 --config 指定的文件中，命令行不含访问密钥。
Rclone_Run()
{
    local -a opt=(--config "${Rclone_Conf}" --contimeout 30s --timeout 5m
                  --retries 3 --low-level-retries 5 --stats 0)
    [ -n "${Remote_Bwlimit}" ] && opt+=(--bwlimit "${Remote_Bwlimit}")
    "${Rclone_Bin}" "${opt[@]}" "$@"
}

S3_Path() { printf '%s:%s/%s%s' "${Rclone_Remote}" "${Remote_S3_Bucket}" "${Remote_Dir}" "${1:+/$1}"; }

Check_Remote_Conf_S3()
{
    Find_Rclone || { Log ERROR "找不到 rclone，执行 lnmp backup remote-setup s3 安装并配置。"; return 1; }
    [ -n "${Remote_S3_Bucket}" ] || { Log ERROR "s3 需要配置 Remote_S3_Bucket。"; return 1; }
    [ -n "${Remote_Dir}" ] || { Log ERROR "s3 需要配置 Remote_Dir 作为对象前缀。"; return 1; }
    [ -f "${Rclone_Conf}" ] || { Log ERROR "缺少 rclone 配置：${Rclone_Conf}"; return 1; }
    Check_Perm "${Rclone_Conf}" || return 1
    case "${Remote_S3_Delete}" in
        0|1) return 0 ;;
        *) Log ERROR "Remote_S3_Delete 只能是 0 或 1。"; return 1 ;;
    esac
}

Upload_Batch_S3()
{
    local type="$1" batch="$2" dir="${Backup_Home}/$1/$2"
    local dst f base out rc line local_size local_md5 remote_size remote_md5 manifest ok=1

    dst=$(S3_Path "${type}/${batch}")
    Log INFO "上传 ${type}/${batch} 到 s3://${Remote_S3_Bucket}/${Remote_Dir}"
    out=$(Rclone_Run copy --max-depth 1 --exclude '.*' "${dir}" "${dst}" 2>&1); rc=$?
    if [ "${rc}" -ne 0 ]; then
        Log ERROR "上传失败（rclone 退出码 ${rc}）：
${out}"
        return 1
    fi

    out=$(Rclone_Run lsf --files-only --format psh --hash MD5 --separator '|' "${dst}" 2>&1); rc=$?
    if [ "${rc}" -ne 0 ]; then
        Log ERROR "列出远端批次失败（rclone 退出码 ${rc}）：
${out}"
        return 1
    fi
    manifest=$(mktemp) || return 1
    Tmp_File="${manifest}"
    for f in "${dir}"/*; do
        [ -f "${f}" ] || continue
        base="${f##*/}"
        local_size=$(stat -c '%s' "${f}" 2>/dev/null || stat -f '%z' "${f}" 2>/dev/null)
        local_md5=$(md5sum < "${f}" | awk '{ print $1 }')
        line=$(printf '%s
' "${out}" | awk -F'|' -v n="${base}" '$1 == n' | tail -n 1)
        if [ -z "${line}" ]; then
            Log ERROR "远端缺少文件：${base}"; ok=0; continue
        fi
        remote_size=$(printf '%s' "${line}" | cut -d'|' -f2)
        remote_md5=$(printf '%s' "${line}" | cut -d'|' -f3)
        if [ "${remote_size}" != "${local_size}" ]; then
            Log ERROR "远端文件大小不符：${base} 本地 ${local_size} 远端 ${remote_size}"; ok=0; continue
        fi
        if [ -z "${remote_md5}" ]; then
            Log ERROR "远端未返回 MD5，无法核对内容：${base}"; ok=0; continue
        fi
        if [ "${remote_md5}" != "${local_md5}" ]; then
            Log ERROR "远端文件 MD5 不符：${base}"; ok=0; continue
        fi
        printf '%s  %s  %s\n' "${local_md5}" "${local_size}" "${base}" >> "${manifest}"
    done
    if [ "${ok}" -ne 1 ]; then
        rm -f "${manifest}"; Tmp_File=""
        Log ERROR "远端核对未通过，不写提交清单，批次保持未提交。"
        return 1
    fi

    out=$(Rclone_Run copyto "${manifest}" "${dst}/${Rclone_Commit}" 2>&1); rc=$?
    rm -f "${manifest}"; Tmp_File=""
    if [ "${rc}" -ne 0 ]; then
        Log ERROR "写入提交清单失败（rclone 退出码 ${rc}）：
${out}"
        return 1
    fi
    Log INFO "远端已提交：${type}/${batch}"
    return 0
}

# 无删除权限时不发起删除；删除失败只告警，不影响本次已提交的批次。
Cleanup_Remote_S3()
{
    local type="$1" days="$2" out rc b batches
    if [ "${Remote_S3_Delete}" != "1" ]; then
        Log INFO "Remote_S3_Delete=0，远端 ${type} 过期批次由桶生命周期规则清理。"
        return 0
    fi
    batches=$(Rclone_Run lsf --dirs-only "$(S3_Path "${type}")" 2>/dev/null) \
        || { Log WARN "无法列出远端 ${type} 目录，跳过远端清理。"; return 0; }
    for b in ${batches}; do
        b="${b%/}"
        Batch_Older_Than "${b}" "${days}" || continue
        Log INFO "清理远端过期批次：${type}/${b}"
        out=$(Rclone_Run purge "$(S3_Path "${type}/${b}")" 2>&1); rc=$?
        if [ "${rc}" -ne 0 ]; then
            Log WARN "删除远端批次 ${type}/${b} 失败（rclone 退出码 ${rc}），停止本次远端清理：
${out}
访问密钥不含删除权限时设置 Remote_S3_Delete=0，并在桶上配置生命周期规则。"
            return 0
        fi
    done
    return 0
}

# 每行输出一个批次；缺少提交清单的批次附加“未提交”标注。
List_Remote_Batches_S3()
{
    local type="$1" out rc b c
    out=$(Rclone_Run lsf -R --max-depth 2 "$(S3_Path "${type}")" 2>&1); rc=$?
    # 前缀不存在时 rclone 返回 3（directory not found），按空列表处理。
    [ "${rc}" -eq 3 ] && return 0
    if [ "${rc}" -ne 0 ]; then
        printf '%s\n' "${out}" | tail -n 3 >&2
        return "${rc}"
    fi
    printf '%s\n' "${out}" | tr -d '\r' | awk -F'/' -v c="${Rclone_Commit}" '
        $1 !~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]$/ { next }
        { seen[$1] = 1 }
        NF == 2 && $2 == c { done[$1] = 1 }
        END { for (b in seen) print b, ((b in done) ? 1 : 0) }' | sort | while read -r b c; do
        if [ "${c}" = 1 ]; then printf '%s\n' "${b}"; else printf '%s  [未提交]\n' "${b}"; fi
    done
}

# 上传按“传输、核对、提交”的顺序执行，任一步失败都保留正式目录中的现有备份。
# SFTP、FTP 和 FTPS 以改名提交，S3 以提交清单对象提交。
Upload_Batch()
{
    Check_Remote_Conf || return 1
    case "${Remote_Protocol}" in
        sftp)     Upload_Batch_Sftp "$@" ;;
        ftps|ftp) Upload_Batch_Ftp  "$@" ;;
        s3)       Upload_Batch_S3   "$@" ;;
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
        s3)       Cleanup_Remote_S3   "$@" ;;
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
        s3)
            List_Remote_Batches_S3 "${type}"
            return
            ;;
        *)
            Log ERROR "未知的 Remote_Protocol：${Remote_Protocol}"
            return 1
            ;;
    esac
    [ "${rc}" -eq 0 ] || return "${rc}"
    printf '%s\n' "${out}" | tr -d '\r' | grep -v '^sftp>' | sed 's#.*/##; /^$/d'
}

# 备份机 lnmp-backup-vault 写回的归档索引，每行为“类型 批次”；文件不存在时输出为空。
Remote_Vault_Index()
{
    local tmp
    tmp=$(mktemp) || return 1
    printf -- '-get %s/.vault-index %s\nbye\n' "${Remote_Dir}" "${tmp}" | Sftp_Run >/dev/null 2>&1
    grep -E '^(db|www) [0-9]{8}-[0-9]{6}$' "${tmp}" 2>/dev/null
    rm -f "${tmp}"
    return 0
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
    local batch="$1" entry db out failed=0 n=0
    local dir="${Backup_Home}/db/${batch}"
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
    local batch="$1" entry domain path out failed=0 n=0 rc
    local dir="${Backup_Home}/www/${batch}"
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
    if [ "${Enable_Remote_Backup}" != "1" ]; then
        Say "异地上传：未启用"
    elif [ "${Remote_Protocol}" = "s3" ]; then
        Say "异地上传：启用（s3） → ${Remote_S3_Bucket}/${Remote_Dir}，远端清理：$([ "${Remote_S3_Delete}" = "1" ] && echo "本机执行" || echo "桶生命周期规则")"
    else
        Say "异地上传：启用（${Remote_Protocol}） → ${Remote_User}@${Remote_Host}:${Remote_Dir}"
    fi
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
    local what="${1:-all}" type b dir size remote mark index='' n
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
        [ "${Remote_Protocol}" = "sftp" ] && index=$(Remote_Vault_Index)
        for type in db www; do
            case "${what}" in db) [ "${type}" = "db" ] || continue ;; web) [ "${type}" = "www" ] || continue ;; esac
            Say "=== 远端 ${type} 批次 ==="
            if ! remote=$(List_Remote_Batches "${type}"); then
                Err "无法列出远端 ${type} 批次。"
                return 1
            fi
            printf '%s\n' "${remote}" | sed '/^$/d; s/^/  /'
            # 备份机守护移走的批次只出现在归档索引中。
            n=$(printf '%s\n' "${index}" | grep -c "^${type} ")
            [ "${n}" -eq 0 ] || Say "  备份机已归档 ${n} 个，最新 $(printf '%s\n' "${index}" \
                | awk -v t="${type}" '$1 == t { print $2 }' | sort | tail -n 1)"
        done
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 子命令：restore
# ---------------------------------------------------------------------------
Latest_Batch() { List_Batches "$1" | tail -n 1; }

# 按时间倒序找出最近一个可用批次：既要有校验清单、含目标文件，也要校验通过。
# 只取最新目录会被指定站点备份或部分失败留下的新批次挡住，导致明明有完整的
# 恢复点却报找不到。
# Find_Usable_Batch <类型> <文件名，空表示任意数据库转储>
Find_Usable_Batch()
{
    local type="$1" want="$2" batch dir picked=''

    while read -r batch; do
        [ -n "${batch}" ] || continue
        dir="${Backup_Home}/${type}/${batch}"
        if [ ! -f "${dir}/SHA256SUMS" ]; then
            Say "跳过批次 ${batch}：缺少校验清单，属于未完成的备份。" >&2
            continue
        fi
        if [ -n "${want}" ]; then
            if [ ! -f "${dir}/${want}" ] && [ ! -f "${dir}/${want}.enc" ]; then
                Say "跳过批次 ${batch}：不含 ${want}。" >&2
                continue
            fi
        elif [ -z "$(find "${dir}" -maxdepth 1 -type f \
                     \( -name 'db-*.sql.gz' -o -name 'db-*.sql.gz.enc' \) -print -quit)" ]; then
            Say "跳过批次 ${batch}：不含数据库转储。" >&2
            continue
        fi
        if ! Verify_Checksums "${dir}" >/dev/null 2>&1; then
            Say "跳过批次 ${batch}：SHA256 校验不通过。" >&2
            continue
        fi
        picked="${batch}"
        break
    done < <(List_Batches "${type}" | sort -r)

    [ -n "${picked}" ] || return 1
    printf '%s\n' "${picked}"
}

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

# 恢复与试恢复都用 root option file 执行 dump 里的全部 SQL，
# 校验清单只能证明文件未损坏，不能证明语义只影响目标库。
Check_Restore_Sql_Boundary()
{
    local target="$1" file="$2" bin="/bin/lnmp-sqlguard"

    if [ ! -x "${bin}" ]; then
        Err "找不到 ${bin}，无法确认这份备份只影响数据库 ${target}，已拒绝。"
        Err "可从源码目录补装：cp tools/lnmp-sqlguard.sh /bin/lnmp-sqlguard && chmod +x /bin/lnmp-sqlguard"
        return 1
    fi
    "${bin}" check "${target}" "${file}" && return 0
    Err "这份备份包含越出数据库 ${target} 的语句，恢复会改动目标库以外的数据，已拒绝。"
    return 1
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

    # 显式指定批次时保持严格语义：只看这一个批次，缺文件就失败。
    if [ "${kind}" = "db" ]; then
        [ -n "${batch}" ] || batch=$(Find_Usable_Batch db "db-${name}.sql.gz")
        dir="${Backup_Home}/db/${batch}"
        file="${dir}/db-${name}.sql.gz"
    else
        [ -n "${batch}" ] || batch=$(Find_Usable_Batch www "www-${name}.tar.gz")
        dir="${Backup_Home}/www/${batch}"
        file="${dir}/www-${name}.tar.gz"
    fi
    [ -n "${batch}" ] || { Err "没有同时满足「有校验清单、含 ${name}、校验通过」的批次。"; return 1; }
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
        if [ "${LNMP_Restore_Allow_Cross_Db:-}" = "yes" ]; then
            Warn "已显式允许跨库语句（LNMP_Restore_Allow_Cross_Db=yes），跳过边界检查。"
        else
            Check_Restore_Sql_Boundary "${name}" "${payload}" || return 1
        fi
        Warn "即将把备份导入数据库 ${name}，库中同名表会被覆盖，且无法撤销。"
        Say "5 秒后开始，Ctrl+C 取消..."
        sleep 5
        gzip -dc "${payload}" | "${mysql_bin}" --defaults-file="${MySQL_Option_File}" \
            --max-allowed-packet=1G --default-character-set=utf8mb4 "${name}"
        pipe_st=("${PIPESTATUS[@]}")
        gz_rc=${pipe_st[0]}; mysql_rc=${pipe_st[1]}
        if [ "${gz_rc}" -ne 0 ] || [ "${mysql_rc}" -ne 0 ]; then
            Err "导入失败（gzip=${gz_rc} mysql=${mysql_rc}）。"
            return 1
        fi
        Ok "数据库 ${name} 已从批次 ${batch} 恢复。"
    else
        local target stage top count
        target=$(printf '%s\n' "${Backup_Site[@]}" | awk -F'|' -v d="${name}" '$1 == d { print $2 }' | head -n 1)
        [ -n "${target}" ] || { Err "配置里没有站点 ${name}，无法确定恢复目录。"; return 1; }

        # 归档顶层目录是备份时的目录名，站点改名或迁移后与当前目标不同。
        # 直接 tar -C "${target%/*}" 会解到旧目录，却报告恢复到了新目录，
        # 因此先解到私有暂存目录，确认只有一个顶层目录，再同步到当前目标。
        stage="${work}/site"
        mkdir -p "${stage}" || { Err "无法创建暂存目录。"; return 1; }
        tar zxf "${payload}" -C "${stage}" || { Err "解压失败。"; return 1; }
        count=$(find "${stage}" -mindepth 1 -maxdepth 1 | wc -l)
        if [ "${count}" -ne 1 ]; then
            Err "归档里有 ${count} 个顶层条目，预期只有站点目录本身，已拒绝恢复。"
            return 1
        fi
        top=$(find "${stage}" -mindepth 1 -maxdepth 1)
        [ -d "${top}" ] || { Err "归档顶层不是目录：${top##*/}"; return 1; }
        if [ "${top##*/}" != "${target##*/}" ]; then
            Warn "归档里的目录名是 ${top##*/}，当前站点目录是 ${target##*/}，按当前目录恢复。"
        fi

        Warn "即将把备份内容覆盖到 ${target}，同名文件会被替换。"
        Say "5 秒后开始，Ctrl+C 取消..."
        sleep 5
        mkdir -p "${target}" || { Err "无法创建 ${target}。"; return 1; }

        # 站点 .user.ini 由建站流程置为 immutable，不先解除就写不进去，
        # 整次同步会中断。解除前记下原状态，同步后按原状态还原。
        local uini="${target}/.user.ini" had_i='n'
        if [ -f "${uini}" ] && lsattr -d "${uini}" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
            had_i='y'
            chattr -i "${uini}" 2>/dev/null || Warn "无法解除 ${uini} 的 immutable，同步可能失败。"
        fi

        local sync_rc=0
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "${top}/" "${target}/" || sync_rc=1
        else
            ( cd "${top}" && tar cf - . ) | ( cd "${target}" && tar xf - ) || sync_rc=1
        fi

        # 无论同步成败都把 immutable 加回去，不留下可被站点覆盖的 .user.ini。
        if [ "${had_i}" = 'y' ] && [ -f "${uini}" ] && ! chattr +i "${uini}" 2>/dev/null; then
            Warn "无法为 ${uini} 重新设置 immutable，请手工执行：chattr +i ${uini}"
        fi
        [ "${sync_rc}" -eq 0 ] || { Err "同步到 ${target} 失败。"; return 1; }
        # 报告成功前确认目标确实被写入。
        if [ -z "$(ls -A "${target}" 2>/dev/null)" ]; then
            Err "同步后 ${target} 仍为空，恢复未生效。"
            return 1
        fi
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

    batch=$(Find_Usable_Batch db "")
    [ -n "${batch}" ] || { Err "没有可用于试恢复的完整数据库批次。"; return 1; }
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
    # 试恢复对外承诺不影响现有数据，因此不提供跳过边界检查的开关。
    # dump 里的对象都会落进临时库，跨库限定名按目标库为 tmpdb 判断。
    if ! Check_Restore_Sql_Boundary "${tmpdb}" "${payload}"; then
        Err "试恢复中止：备份内容会影响临时库以外的数据库。"
        return 1
    fi
    "${mysql_bin}" --defaults-file="${MySQL_Option_File}" \
        -e "CREATE DATABASE \`${tmpdb}\`;" || { Err "无法创建临时库 ${tmpdb}。"; return 1; }

    gzip -dc "${payload}" | "${mysql_bin}" --defaults-file="${MySQL_Option_File}" \
        --max-allowed-packet=1G --default-character-set=utf8mb4 "${tmpdb}"
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
    local f root domain db src frag
    # LNMPA 的站点在 Nginx 与 Apache 两个 vhost 目录各有一份配置，两端一致时只输出一条；
    # 两端的域名或目录不一致时都会列出，便于发现配置漂移。
    {
    for f in /usr/local/nginx/conf/vhost/*.conf; do
        [ -f "${f}" ] || continue
        domain=$(awk '/^[ \t]*server_name/ {gsub(/;/,""); print $2; exit}' "${f}")
        root=$(awk '/^[ \t]*root/ {gsub(/;/,""); print $2; exit}' "${f}")
        [ -n "${domain}" ] && [ -n "${root}" ] || continue
        # default 站点的 server_name 是 _，列表与 -default 排除写法统一显示为 default。
        [ "${domain}" = '_' ] && domain='default'
        db=$(Guess_Db "${root}")
        printf '%s|%s|%s\n' "${domain}" "${root%/}" "${db}"
    done
    for f in /usr/local/apache/conf/vhost/*.conf; do
        [ -f "${f}" ] || continue
        src="${f}"
        # 片段结构的站点参数在 shared/ 下的片段里，主文件只有 VirtualHost 与 Include。
        if ! grep -Eq '^[ \t]*ServerName' "${src}"; then
            frag="/usr/local/apache/conf/vhost/shared/$(basename "${f}")"
            [ -f "${frag}" ] && src="${frag}"
        fi
        domain=$(awk '/^[ \t]*ServerName/ {print $2; exit}' "${src}")
        root=$(awk '/^[ \t]*DocumentRoot/ {gsub(/"/,""); print $2; exit}' "${src}")
        [ -n "${domain}" ] && [ -n "${root}" ] || continue
        db=$(Guess_Db "${root}")
        printf '%s|%s|%s\n' "${domain}" "${root%/}" "${db}"
    done
    } | awk '!seen[$0]++'
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
    local rc

    Svc_Install_Timer "${Systemd_Service}" "${Systemd_Timer}" "$(cat <<'EOF'
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
)" "$(cat <<EOF
[Unit]
Description=LNMP backup timer

[Timer]
OnCalendar=*-*-* ${hour}:30:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
)"
    rc=$?
    case "${rc}" in
    0) Ok "已启用 systemd timer：每天 ${hour}:30 前后执行（带随机延迟）。" ;;
    2) Err "启用 lnmp-backup.timer 失败，请手工检查。" ;;
    *) Err "写入 ${Systemd_Service} 或 ${Systemd_Timer} 失败。" ;;
    esac
    return "${rc}"
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

# 生成数据库 option file 并校验连通性。密码为空表示只用 unix_socket 免密连接。
# 返回：0 成功，1 写入失败，2 校验失败，3 找不到 mysql 客户端。
Write_My_Cnf()
{
    local db_pass="$1" db_sock tmp mysql_bin pass_line=''

    if ! mysql_bin=$(Find_Mysql_Client); then
        return 3
    fi
    db_sock=$(Db_Socket)
    tmp=$(mktemp "${My_Cnf}.XXXXXXXX") || return 1
    if [ -n "${db_pass}" ]; then
        # option file 在引号内将反斜杠解析为转义符，写入前需加倍。
        pass_line="password='${db_pass//\\/\\\\}'"
    fi
    # 免密时不写 password 行，避免配置里留下空行。
    (
        umask 077
        {
            printf '[mysqldump]\nuser=root\n'
            [ -n "${pass_line}" ] && printf '%s\n' "${pass_line}"
            printf 'socket=%s\n\n[client]\nuser=root\n' "${db_sock}"
            [ -n "${pass_line}" ] && printf '%s\n' "${pass_line}"
            printf 'socket=%s\n' "${db_sock}"
        } > "${tmp}"
    ) || { rm -f "${tmp}"; return 1; }
    chmod 600 "${tmp}" || { rm -f "${tmp}"; return 1; }
    if ! "${mysql_bin}" --defaults-file="${tmp}" -e "SELECT 1;" >/dev/null 2>&1; then
        rm -f "${tmp}"
        return 2
    fi
    mv -f "${tmp}" "${My_Cnf}" || { rm -f "${tmp}"; return 1; }
    return 0
}

Cmd_Init()
{
    local sites site_lines ans hour db_pass cnf_rc mysql_bin
    local backup_home="/home/backup"

    Say "init 会扫描已有站点，生成备份配置、备份目录与定时任务。"
    Say "配置生成后位于：${Conf_File}，之后可按需修改备份计划等参数，改完直接生效。"
    Say "异地上传默认关闭，SFTP 方式可执行 lnmp backup remote-setup 配置。"
    Say "S3 兼容对象存储可执行 lnmp backup remote-setup s3 配置。"
    Say "使用 ftp/ftps 上传时，接收端需提供 FTP 服务（可用 pureftpd.sh 搭建），本机需有 curl。"
    Say ""
    printf '确认开始配置请输入 y，其它输入一律取消：'
    # 返回 0 只代表配置真正写入；取消与 EOF 都必须返回非 0。
    if ! read -r ans; then
        echo
        Err "读取确认时遇到 EOF，未做任何配置。"
        return 1
    fi
    if [ "${ans}" != "y" ]; then
        Say "已取消，未做任何配置。"
        return 1
    fi

    [ "$(id -u)" = "0" ] || { Err "init 需要 root 权限。"; return 1; }
    mkdir -p "${Conf_Dir}" && chmod 700 "${Conf_Dir}" || { Err "无法创建 ${Conf_Dir}"; return 1; }
    mkdir -p "${State_Dir}" "${Log_File%/*}" 2>/dev/null

    if [ -f "${Conf_File}" ]; then
        Warn "配置已存在：${Conf_File}"
        printf '覆盖并重新生成？[y/N]（默认 n）：'
        if ! read -r ans; then
            echo
            Err "读取确认时遇到 EOF，保留现有配置。"
            return 1
        fi
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

    # 优先用 root 的 unix_socket 免密连接，连得通就不再询问口令。
    # 口令仅在免密不可用时索取，写入权限 0600 的 option file，不出现在命令行或备份配置中。
    if [ ! -f "${My_Cnf}" ]; then
        Write_My_Cnf ""; cnf_rc=$?
        case "${cnf_rc}" in
            0) Ok "root 可通过 unix_socket 免密连接，凭据已写入 ${My_Cnf}（600）。" ;;
            3) Warn "找不到 mysql 客户端，跳过数据库凭据，库备份会因此失败。" ;;
            1) Err "写入 ${My_Cnf} 失败。"; return 1 ;;
            *)
                Say "socket 免密连接不可用，导出数据库需要 root 口令。"
                printf '输入数据库 root 密码（留空则跳过，不回显）：'
                if ! read -r -s db_pass; then
                    echo
                    Err "读取数据库 root 密码时遇到 EOF。"
                    return 1
                fi
                echo
                if [ -z "${db_pass}" ]; then
                    Warn "跳过数据库凭据，库备份会因此失败。稍后可重跑 init 补上。"
                else
                    Write_My_Cnf "${db_pass}"; cnf_rc=$?
                    case "${cnf_rc}" in
                        0) Ok "数据库凭据校验通过，已写入 ${My_Cnf}（600）。" ;;
                        2) Err "数据库凭据校验失败，未写入配置，也未启用定时任务。"; return 1 ;;
                        *) Err "写入 ${My_Cnf} 失败。"; return 1 ;;
                    esac
                fi
                ;;
        esac
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
# 数据库凭据文件，由 init 生成（600）；socket 免密时其中不含密码。
# 该文件缺失或不可读时，库备份、restore 与 test 都会失败。
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

# 上传方式：sftp 使用 SSH 密钥，ftps 使用 TLS 和密码，ftp 为明文传输，s3 为 S3 兼容对象存储。
# sftp 通常使用端口 22，ftp 和 ftps 通常使用端口 21。根据备份服务器实际端口号修改。
Remote_Protocol="sftp"

Remote_Host=""
Remote_Port=22
Remote_User=""
Remote_Dir="backup"

# 以下两项仅 sftp 使用。专用备份密钥，避免复用日常登录密钥。
Remote_SSH_Key="/root/.ssh/lnmp_backup"
# 由 lnmp backup remote-setup 生成密钥并在核对后写入主机指纹。
Remote_Known_Hosts="/root/.ssh/lnmp_backup_known_hosts"

# 以下三项仅 ftp 和 ftps 使用。
Remote_Password=""
# FTPS 证书校验；自签证书应通过 Remote_Ftp_CA 指定 CA。
Remote_Ftp_Verify=1
Remote_Ftp_CA=""

# 以下各项仅 s3 使用，由 lnmp backup remote-setup s3 写入；Remote_Dir 为桶内对象前缀。
Remote_S3_Bucket=""
# 1 表示访问密钥有删除权限，由本机清理过期批次；0 表示由桶生命周期规则清理。
Remote_S3_Delete=0
# 上传限速，如 10M 表示 10 MiB/s，留空不限速。
Remote_Bwlimit=""
# 留空则依次查找 /usr/local/bin/rclone、/usr/bin/rclone。
Rclone_Bin=""
# 访问密钥所在的 rclone 配置（600）。
Rclone_Conf="${Conf_Dir}/backup-rclone.conf"

# ---- 可选加密 ----
Enable_Encrypt=0
Encrypt_Tool="age"
Encrypt_Recipient=""
Encrypt_Identity="/root/.config/lnmp/backup-age.key"
EOF
    if [ ! -s "${Conf_File}" ]; then
        Err "写入 ${Conf_File} 失败。"
        return 1
    fi
    chmod 600 "${Conf_File}" || { Err "设置 ${Conf_File} 权限失败。"; return 1; }
    Ok "配置已写入 ${Conf_File}（600）。"

    if ! mkdir -p "${backup_home}" || ! chmod 700 "${backup_home}"; then
        Err "无法准备备份目录 ${backup_home}。"
        return 1
    fi

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
    Say "  配置异地上传：lnmp backup remote-setup（对象存储：remote-setup s3）"
    Say ""
    return 0
}

# ---------------------------------------------------------------------------
# 子命令：remote-setup —— 配置 SFTP 异地上传
#
# 生成专用密钥，提示在备份机执行 lnmp-backup-vault setup，抓取并确认主机指纹，
# 试连并试写通过后才改写配置；取消或任一步失败时 backup.conf 不变。
# ---------------------------------------------------------------------------
Ask_Reply=''

# Ask_Valid <提示> <默认值> <正则> <错误说明>：结果写入 Ask_Reply；EOF 或连续三次无效返回 1。
Ask_Valid()
{
    local tries=0
    while [ "${tries}" -lt 3 ]; do
        if [ -n "$2" ]; then printf '%s（默认 %s）：' "$1" "$2"; else printf '%s：' "$1"; fi
        read -r Ask_Reply || { echo; Err "读取输入时遇到 EOF，配置未改动。"; return 1; }
        [ -n "${Ask_Reply}" ] || Ask_Reply="$2"
        # 补换行使空输入也构成一行，可匹配允许留空的规则。
        printf '%s\n' "${Ask_Reply}" | grep -Eq "$3" && return 0
        Err "$4"
        tries=$((tries + 1))
    done
    Err "连续三次输入无效，配置未改动。"
    return 1
}

Remote_Setup_Key()
{
    local key="${Remote_SSH_Key}"
    if [ -f "${key}" ]; then
        Check_Perm "${key}" || return 1
        if [ ! -s "${key}.pub" ]; then
            ssh-keygen -y -f "${key}" > "${key}.pub" || { Err "无法从 ${key} 导出公钥。"; return 1; }
        fi
        Say "沿用已有密钥：${key}"
        return 0
    fi
    [ -d "${key%/*}" ] || { mkdir -p "${key%/*}" && chmod 700 "${key%/*}"; } || return 1
    ssh-keygen -q -t ed25519 -N '' -C "lnmp-backup@$(hostname -s 2>/dev/null)" -f "${key}" \
        || { Err "生成密钥失败：${key}"; return 1; }
    chmod 600 "${key}"
    Ok "已生成专用密钥：${key}"
}

# 指纹与已记录的一致时直接沿用；不同或首次记录时须人工确认，known_hosts 经同目录临时文件替换。
Remote_Setup_Hostkey()
{
    local tmp ans old new
    [ -d "${Remote_Known_Hosts%/*}" ] || { mkdir -p "${Remote_Known_Hosts%/*}" && chmod 700 "${Remote_Known_Hosts%/*}"; } || return 1
    tmp=$(mktemp "${Remote_Known_Hosts%/*}/.lnmp_known_hosts.XXXXXXXX") || return 1
    ssh-keyscan -T 10 -p "${Remote_Port}" "${Remote_Host}" 2>/dev/null | grep -v '^#' > "${tmp}"
    if [ ! -s "${tmp}" ]; then
        rm -f "${tmp}"
        Err "无法从 ${Remote_Host}:${Remote_Port} 取得主机公钥，检查地址、端口与备份机防火墙。"
        return 1
    fi
    if [ -s "${Remote_Known_Hosts}" ]; then
        if [ "$(sort "${Remote_Known_Hosts}")" = "$(sort "${tmp}")" ]; then
            rm -f "${tmp}"
            Ok "主机公钥与 ${Remote_Known_Hosts} 中记录的一致。"
            return 0
        fi
        # 公钥不变、仅地址或端口变化时更新记录，无需重新确认。
        old=$(awk '{ print $2, $3 }' "${Remote_Known_Hosts}" | sort)
        new=$(awk '{ print $2, $3 }' "${tmp}" | sort)
        if [ "${old}" = "${new}" ]; then
            chmod 600 "${tmp}" && mv -f "${tmp}" "${Remote_Known_Hosts}" || { rm -f "${tmp}"; return 1; }
            Ok "主机公钥与已记录的一致，已按新地址或端口更新 ${Remote_Known_Hosts}。"
            return 0
        fi
        Warn "主机公钥与 ${Remote_Known_Hosts} 中记录的不同。只有备份机重装或更换主机时才会这样，否则可能是中间人。"
    fi
    Say "备份机主机指纹："
    ssh-keygen -l -f "${tmp}" | sed 's/^/  /'
    Say "与备份机执行 lnmp-backup-vault setup 时显示的指纹逐字核对。"
    printf '指纹一致？[y/N]：'
    read -r ans || ans=''
    case "${ans}" in
        y|Y) : ;;
        *) rm -f "${tmp}"; Say "已取消，配置未改动。"; return 1 ;;
    esac
    chmod 600 "${tmp}" && mv -f "${tmp}" "${Remote_Known_Hosts}" || { rm -f "${tmp}"; return 1; }
    Ok "主机指纹已写入 ${Remote_Known_Hosts}"
}

# 在 .incoming 中上传并删除一个探测文件，同时验证登录、目录与写权限。
Remote_Setup_Test()
{
    local probe name out rc
    probe=$(mktemp) || return 1
    printf 'lnmp-backup probe\n' > "${probe}"
    name=".lnmp-probe-$$"
    out=$(printf -- '-mkdir %s/.incoming\nput %s %s/.incoming/%s\nrm %s/.incoming/%s\nbye\n' \
            "${Remote_Dir}" "${probe}" "${Remote_Dir}" "${name}" "${Remote_Dir}" "${name}" \
            | Sftp_Run 2>&1); rc=$?
    rm -f "${probe}"
    [ "${rc}" -eq 0 ] && return 0
    Err "试连或试写失败（sftp 退出码 ${rc}）："
    printf '%s\n' "${out}" | grep -v '^sftp>' | tail -n 5 | sed 's/^/  /' >&2
    case "${out}" in
        *'Permission denied (publickey'*)
            Err "公钥未生效：确认已在备份机执行上面的 setup 命令，且账号名一致。" ;;
        *'Connection refused'*|*'timed out'*|*'No route'*)
            Err "连接失败：检查地址、端口与备份机防火墙。" ;;
        *'Host key verification failed'*)
            Err "主机指纹校验失败：重新执行 remote-setup 并核对指纹。" ;;
        *'No such file'*|*'not found'*)
            Err "远端目录 ${Remote_Dir} 不存在，应与备份机配置的 Data_Dir 一致。" ;;
        *'Permission denied'*)
            Err "远端目录不可写：在备份机重新执行 lnmp-backup-vault setup ${Remote_User}。" ;;
    esac
    return 1
}

# Conf_Update <键=值>...：替换配置中同名键的首个赋值行，缺失的键追加到末尾；改名前备份，读回失败时恢复。
Conf_Update()
{
    local tmp bak
    tmp=$(mktemp "${Conf_File}.XXXXXXXX") || return 1
    LNMP_KV="$(printf '%s\n' "$@")" awk '
        BEGIN {
            n = split(ENVIRON["LNMP_KV"], a, "\n")
            for (i = 1; i <= n; i++) {
                if (a[i] == "") continue
                k = a[i]; sub(/=.*/, "", k)
                val[k] = a[i]; order[++m] = k
            }
        }
        match($0, /^[A-Za-z_][A-Za-z0-9_]*=/) {
            k = substr($0, 1, RLENGTH - 1)
            if ((k in val) && !(k in done)) { print val[k]; done[k] = 1; next }
        }
        { print }
        END { for (i = 1; i <= m; i++) if (!(order[i] in done)) print val[order[i]] }
    ' "${Conf_File}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
    chmod 600 "${tmp}" || { rm -f "${tmp}"; return 1; }
    bak="${Conf_File}.bak.$(date '+%Y%m%d%H%M%S')"
    cp -p "${Conf_File}" "${bak}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "${Conf_File}" || { rm -f "${tmp}"; return 1; }
    if ! ( Load_Conf ) >/dev/null 2>&1; then
        cp -p "${bak}" "${Conf_File}"
        Err "改写后的配置无法读取，已恢复原配置。"
        return 1
    fi
    Say "原配置已备份：${bak}"
}

Cmd_Remote_Setup()
{
    local ans c pub
    case "${1:-sftp}" in
        sftp|s3) : ;;
        *) Err "用法：lnmp backup remote-setup [sftp|s3]"; return 1 ;;
    esac
    [ "$(id -u)" = "0" ] || { Err "remote-setup 需要 root 权限。"; return 1; }
    Load_Conf || return 1
    if [ "${1:-sftp}" = "s3" ]; then
        Cmd_Remote_Setup_S3
        return
    fi
    for c in ssh-keygen ssh-keyscan sftp; do
        command -v "${c}" >/dev/null 2>&1 || { Err "找不到 ${c} 命令（openssh-client）。"; return 1; }
    done

    Say "配置 SFTP 异地上传：生成专用密钥、核对备份机指纹、试连试写，全部通过后才改写 ${Conf_File}。"
    Say "备份机需先放好随包的 tools/lnmp-backup-vault.sh，步骤见 HowtoGuides 8.6。"
    Say ""
    if [ "${Remote_Protocol}" != "sftp" ]; then
        Warn "当前上传方式为 ${Remote_Protocol}，完成后改为 sftp。"
        [ "${Remote_Port}" != "21" ] || Remote_Port=22
    fi

    Ask_Valid "备份机地址" "${Remote_Host}" \
        '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' "地址须为域名或 IPv4，只能含字母、数字、点和连字符。" || return 1
    Remote_Host="${Ask_Reply}"
    while :; do
        Ask_Valid "SSH 端口" "${Remote_Port}" '^[1-9][0-9]{0,4}$' "端口须为 1-65535。" || return 1
        [ "${Ask_Reply}" -le 65535 ] && break
        Err "端口须为 1-65535。"
    done
    Remote_Port="${Ask_Reply}"
    Ask_Valid "备份机账号" "${Remote_User:-backupuser}" '^[a-z_][a-z0-9_-]{0,31}$' \
        "账号名只能含小写字母、数字、下划线和连字符，且不以数字开头。" || return 1
    Remote_User="${Ask_Reply}"
    Ask_Valid "远端数据目录" "${Remote_Dir:-backup}" \
        '^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$' \
        "目录为相对 chroot 根的路径，只能含字母、数字、点、下划线和连字符，不以 / 或 . 开头。" || return 1
    Remote_Dir="${Ask_Reply}"

    Remote_Setup_Key || return 1
    pub=$(awk '{ print $1, $2; exit }' "${Remote_SSH_Key}.pub")
    Say ""
    Say "在备份机上以 root 执行（安装后也可用 lnmp-backup-vault 代替 bash lnmp-backup-vault.sh）："
    Say ""
    Say "  bash lnmp-backup-vault.sh setup ${Remote_User} '${pub}'"
    Say ""
    [ "${Remote_Dir}" = "backup" ] || Warn "远端数据目录不是默认的 backup，须先把备份机配置中的 Data_Dir 改为 ${Remote_Dir}。"
    printf '执行完成后按回车继续，输入 q 退出（配置不变）：'
    if ! read -r ans; then
        echo
        Err "读取输入时遇到 EOF，配置未改动。"
        return 1
    fi
    case "${ans}" in
        q|Q) Say "已退出，配置未改动；密钥已保留，可重新执行 lnmp backup remote-setup。"; return 1 ;;
    esac

    Remote_Setup_Hostkey || return 1
    Say "试连并试写 ${Remote_User}@${Remote_Host}:${Remote_Dir} ..."
    if ! Remote_Setup_Test; then
        Err "配置未改动，处理后重新执行 lnmp backup remote-setup。"
        return 1
    fi
    Ok "试连与试写通过。"

    Conf_Update 'Enable_Remote_Backup=1' 'Remote_Protocol="sftp"' \
        "Remote_Host=\"${Remote_Host}\"" "Remote_Port=${Remote_Port}" \
        "Remote_User=\"${Remote_User}\"" "Remote_Dir=\"${Remote_Dir}\"" \
        || { Err "写入 ${Conf_File} 失败，配置未改动。"; return 1; }
    Ok "已启用异地上传：sftp → ${Remote_User}@${Remote_Host}:${Remote_Port}/${Remote_Dir}"
    Say "下一步：lnmp backup run all，再用 lnmp backup list 查看远端批次。"
    return 0
}

# ---------------------------------------------------------------------------
# 子命令：remote-setup s3 —— 配置 S3 兼容对象存储异地上传
#
# 确认 rclone 可用（缺少时下载固定版本并校验 SHA-256），询问服务商参数与访问密钥，
# 以临时 rclone 配置试写探测对象，通过后才替换 rclone 配置并改写 backup.conf。
# ---------------------------------------------------------------------------
Rclone_Url_Base="https://downloads.rclone.org"
Rclone_Install_Path="/usr/local/bin/rclone"

# 下载官方 zip 并核对 SHA-256，只取出 rclone 可执行文件，经同目录临时文件改名安装。
Rclone_Install()
{
    local arch sum name zip got c
    case "$(uname -m)" in
        x86_64|amd64)  arch=amd64; sum="${Rclone_Sha256_amd64}" ;;
        aarch64|arm64) arch=arm64; sum="${Rclone_Sha256_arm64}" ;;
        *) Err "不支持的架构 $(uname -m)，请用发行版包安装 rclone（不低于 ${Rclone_Min_Ver}）。"; return 1 ;;
    esac
    for c in curl unzip sha256sum; do
        command -v "${c}" >/dev/null 2>&1 || { Err "找不到 ${c} 命令。"; return 1; }
    done
    name="rclone-v${Rclone_Ver}-linux-${arch}"
    Tmp_Work=$(mktemp -d "${TMPDIR:-/tmp}/.lnmp-rclone.XXXXXXXX") || return 1
    zip="${Tmp_Work}/${name}.zip"
    Say "下载 ${Rclone_Url_Base}/v${Rclone_Ver}/${name}.zip"
    if ! curl -fsSL --proto '=https' --connect-timeout 30 --max-time 900 \
            -o "${zip}" "${Rclone_Url_Base}/v${Rclone_Ver}/${name}.zip"; then
        Err "下载失败。"
        return 1
    fi
    got=$(sha256sum "${zip}" | awk '{ print $1 }')
    if [ "${got}" != "${sum}" ]; then
        Err "SHA-256 不符，已拒绝安装：期望 ${sum}，实际 ${got}"
        return 1
    fi
    mkdir -p "${Rclone_Install_Path%/*}" || return 1
    Tmp_File=$(mktemp "${Rclone_Install_Path%/*}/.rclone.XXXXXXXX") || return 1
    if ! unzip -p "${zip}" "${name}/rclone" > "${Tmp_File}" || [ ! -s "${Tmp_File}" ]; then
        Err "从 ${name}.zip 取出 rclone 失败。"
        return 1
    fi
    chmod 755 "${Tmp_File}" || return 1
    got=$(Rclone_Version "${Tmp_File}")
    if [ "${got}" != "${Rclone_Ver}" ]; then
        Err "取出的 rclone 版本为 ${got:-未知}，与 ${Rclone_Ver} 不符。"
        return 1
    fi
    mv -f "${Tmp_File}" "${Rclone_Install_Path}" || return 1
    Tmp_File=""
    rm -rf -- "${Tmp_Work}"; Tmp_Work=""
    Rclone_Bin="${Rclone_Install_Path}"
    Ok "已安装 rclone ${Rclone_Ver}：${Rclone_Bin}"
}

Rclone_Ensure()
{
    local ver ans
    if Find_Rclone; then
        ver=$(Rclone_Version "${Rclone_Bin}")
        if [ -n "${ver}" ] && [ "$(printf '%s\n%s\n' "${Rclone_Min_Ver}" "${ver}" | sort -V | head -n 1)" = "${Rclone_Min_Ver}" ]; then
            Say "使用 rclone ${ver}：${Rclone_Bin}"
            return 0
        fi
        Warn "${Rclone_Bin} 的版本为 ${ver:-未知}，低于 ${Rclone_Min_Ver}。"
    fi
    printf '下载官方 rclone %s 并校验 SHA-256，安装到 %s？[Y/n]：' "${Rclone_Ver}" "${Rclone_Install_Path}"
    if ! read -r ans; then
        echo
        Err "读取输入时遇到 EOF，配置未改动。"
        return 1
    fi
    case "${ans}" in
        ''|y|Y) Rclone_Install ;;
        *) Say "已取消，配置未改动。"; return 1 ;;
    esac
}

# Rclone_Conf_Get <键>：读取现有 rclone 配置中 lnmp 段的值，用作向导默认值。
Rclone_Conf_Get()
{
    [ -f "${Rclone_Conf}" ] || return 0
    awk -v r="[${Rclone_Remote}]" -v k="$1" '
        /^\[/ { in_r = ($0 == r); next }
        in_r && index($0, k " = ") == 1 { print substr($0, length(k) + 4); exit }' "${Rclone_Conf}"
}

# 以指定 rclone 配置写入并读回探测对象；声明有删除权限时同时验证删除。
Remote_S3_Probe()
{
    local Rclone_Conf="$1" probe dst out rc size
    probe=$(mktemp) || return 1
    printf 'lnmp-backup probe\n' > "${probe}"
    dst=$(S3_Path ".lnmp-probe/$(hostname -s 2>/dev/null || echo host)-$$")
    out=$(Rclone_Run copyto "${probe}" "${dst}" 2>&1); rc=$?
    if [ "${rc}" -eq 0 ]; then
        size=$(Rclone_Run lsf --format s "${dst}" 2>&1); rc=$?
        [ "${rc}" -eq 0 ] && [ "${size}" != "$(wc -c < "${probe}" | tr -d ' ')" ] && { out="读回大小不符：${size}"; rc=1; }
    fi
    rm -f "${probe}"
    if [ "${rc}" -ne 0 ]; then
        Err "试写失败（rclone 退出码 ${rc}）："
        printf '%s\n' "${out}" | tail -n 5 | sed 's/^/  /' >&2
        case "${out}" in
            *InvalidAccessKeyId*|*SignatureDoesNotMatch*|*'invalid key'*)
                Err "访问密钥无效：核对 Access Key ID 与 Secret。" ;;
            *NoSuchBucket*)
                Err "桶 ${Remote_S3_Bucket} 不存在：先在服务商控制台创建。" ;;
            *AccessDenied*|*'403'*)
                Err "访问被拒绝：确认密钥对桶 ${Remote_S3_Bucket} 有读取与写入权限。" ;;
            *'no such host'*|*timeout*|*'connection refused'*)
                Err "连接失败：检查 Endpoint 与本机出站网络。" ;;
        esac
        return 1
    fi
    if [ "${Remote_S3_Delete}" = "1" ]; then
        if ! out=$(Rclone_Run deletefile "${dst}" 2>&1); then
            Err "删除探测对象失败，密钥可能不含删除权限："
            printf '%s\n' "${out}" | tail -n 3 | sed 's/^/  /' >&2
            Err "重新执行并对删除权限选择 n，由桶生命周期规则清理过期批次。"
            return 1
        fi
    else
        Say "探测对象 ${dst#*:} 保留，由生命周期规则清理。"
    fi
    return 0
}

Cmd_Remote_Setup_S3()
{
    local provider endpoint region key secret old_secret tries ans ep_re tmp bak

    Say "配置 S3 兼容对象存储异地上传：确认 rclone、填写服务商参数、试写探测对象，全部通过后才改写 ${Conf_File}。"
    Say ""
    Rclone_Ensure || return 1

    Say ""
    Say "服务商："
    Say "  1) Cloudflare R2   2) AWS S3   3) Backblaze B2"
    Say "  4) 阿里云 OSS      5) 腾讯云 COS   6) 其他 S3 兼容服务"
    Ask_Valid "选择编号" "" '^[1-6]$' "只能输入 1-6。" || return 1
    region=''
    case "${Ask_Reply}" in
        1) provider=Cloudflare; region=auto
           Say "Endpoint 形如 https://<账户 ID>.r2.cloudflarestorage.com" ;;
        2) provider=AWS ;;
        3) provider=Other
           Say "Endpoint 形如 s3.us-west-004.backblazeb2.com（桶详情页的 Endpoint）" ;;
        4) provider=Alibaba
           Say "Endpoint 形如 oss-cn-hangzhou.aliyuncs.com" ;;
        5) provider=TencentCOS
           Say "Endpoint 形如 cos.ap-guangzhou.myqcloud.com" ;;
        6) provider=Other ;;
    esac
    ep_re='^(https://)?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$'
    if [ "${provider}" = "AWS" ]; then
        endpoint=''
        Ask_Valid "区域（如 us-east-1）" "$(Rclone_Conf_Get region)" '^[a-z0-9-]+$' "区域只能含小写字母、数字和连字符。" || return 1
        region="${Ask_Reply}"
    else
        Ask_Valid "Endpoint" "$(Rclone_Conf_Get endpoint)" "${ep_re}" \
            "Endpoint 为域名，可带 https:// 与端口，不接受 http://。" || return 1
        endpoint="${Ask_Reply}"
        if [ "${provider}" != "Cloudflare" ]; then
            Ask_Valid "区域（可留空）" "$(Rclone_Conf_Get region)" '^[A-Za-z0-9-]*$' "区域只能含字母、数字和连字符。" || return 1
            region="${Ask_Reply}"
        fi
    fi
    Ask_Valid "桶名" "${Remote_S3_Bucket}" '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' \
        "桶名为 3-63 位小写字母、数字、点和连字符。" || return 1
    Remote_S3_Bucket="${Ask_Reply}"
    Ask_Valid "桶内前缀（多台机器共用一个桶时各用一个）" "${Remote_Dir:-backup}" \
        '^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$' \
        "前缀只能含字母、数字、点、下划线、连字符和 /，不以 / 或 . 开头。" || return 1
    Remote_Dir="${Ask_Reply}"
    Ask_Valid "Access Key ID" "$(Rclone_Conf_Get access_key_id)" '^[A-Za-z0-9]{8,128}$' \
        "Access Key ID 只能含字母和数字。" || return 1
    key="${Ask_Reply}"

    old_secret=$(Rclone_Conf_Get secret_access_key)
    tries=0; secret=''
    while [ -z "${secret}" ]; do
        if [ -n "${old_secret}" ]; then
            printf 'Secret Access Key（不回显，回车沿用已保存的）：'
        else
            printf 'Secret Access Key（不回显）：'
        fi
        if ! read -r -s secret; then
            echo
            Err "读取输入时遇到 EOF，配置未改动。"
            return 1
        fi
        echo
        [ -n "${secret}" ] || secret="${old_secret}"
        case "${secret}" in
            *[[:space:]]*) Err "Secret 不能含空白字符。"; secret='' ;;
        esac
        [ -n "${secret}" ] && break
        tries=$((tries + 1))
        [ "${tries}" -lt 3 ] || { Err "连续三次输入无效，配置未改动。"; return 1; }
    done

    printf '访问密钥是否有删除权限？有则由本机清理过期批次，无则由桶生命周期规则清理 [y/N]：'
    if ! read -r ans; then
        echo
        Err "读取输入时遇到 EOF，配置未改动。"
        return 1
    fi
    case "${ans}" in y|Y) Remote_S3_Delete=1 ;; *) Remote_S3_Delete=0 ;; esac
    Ask_Valid "上传限速（如 10M 表示 10 MiB/s，0 表示不限速）" "${Remote_Bwlimit:-0}" \
        '^[0-9]+(\.[0-9]+)?[KMGkmg]?$' "限速为数字加可选单位 K、M、G。" || return 1
    Remote_Bwlimit="${Ask_Reply}"
    [ "${Remote_Bwlimit}" != "0" ] || Remote_Bwlimit=''

    tmp=$(mktemp "${Rclone_Conf}.XXXXXXXX") || return 1
    Tmp_File="${tmp}"
    {
        printf '[%s]\ntype = s3\nprovider = %s\nenv_auth = false\n' "${Rclone_Remote}" "${provider}"
        printf 'access_key_id = %s\nsecret_access_key = %s\n' "${key}" "${secret}"
        [ -z "${endpoint}" ] || printf 'endpoint = %s\n' "${endpoint}"
        [ -z "${region}" ] || printf 'region = %s\n' "${region}"
        # 访问密钥通常不含建桶权限，上传时不检查与创建桶。
        printf 'no_check_bucket = true\n'
    } > "${tmp}" && chmod 600 "${tmp}" || { Err "写入临时 rclone 配置失败。"; return 1; }

    Say "试写 s3://${Remote_S3_Bucket}/${Remote_Dir} ..."
    if ! Remote_S3_Probe "${tmp}"; then
        rm -f "${tmp}"; Tmp_File=""
        Err "配置未改动，处理后重新执行 lnmp backup remote-setup s3。"
        return 1
    fi
    Ok "试写通过。"

    bak=''
    if [ -f "${Rclone_Conf}" ]; then
        bak="${Rclone_Conf}.bak.$(date '+%Y%m%d%H%M%S')"
        cp -p "${Rclone_Conf}" "${bak}" || { rm -f "${tmp}"; Tmp_File=""; Err "备份 ${Rclone_Conf} 失败，配置未改动。"; return 1; }
    fi
    mv -f "${tmp}" "${Rclone_Conf}" || { rm -f "${tmp}"; Tmp_File=""; Err "替换 ${Rclone_Conf} 失败，配置未改动。"; return 1; }
    Tmp_File=""
    if ! Conf_Update 'Enable_Remote_Backup=1' 'Remote_Protocol="s3"' \
            "Remote_S3_Bucket=\"${Remote_S3_Bucket}\"" "Remote_Dir=\"${Remote_Dir}\"" \
            "Remote_S3_Delete=${Remote_S3_Delete}" "Remote_Bwlimit=\"${Remote_Bwlimit}\"" \
            "Rclone_Bin=\"${Rclone_Bin}\"" "Rclone_Conf=\"${Rclone_Conf}\""; then
        if [ -n "${bak}" ]; then cp -p "${bak}" "${Rclone_Conf}"; else rm -f "${Rclone_Conf}"; fi
        Err "写入 ${Conf_File} 失败，已恢复原 rclone 配置。"
        return 1
    fi
    Ok "已启用异地上传：s3 → ${Remote_S3_Bucket}/${Remote_Dir}"
    Say "建议在桶上配置生命周期规则："
    Say "  前缀 ${Remote_Dir}/db/   不早于 $((Keep_Days_Db + 1)) 天后过期"
    Say "  前缀 ${Remote_Dir}/www/  不早于 $((Keep_Days_Web + 1)) 天后过期"
    Say "  前缀 ${Remote_Dir}/.lnmp-probe/  1 天后过期"
    Say "  未完成的分段上传 1 天后中止"
    [ "${Remote_S3_Delete}" = "1" ] || Warn "Remote_S3_Delete=0：未配置过期规则时远端批次不会被删除，容量会持续增长。"
    Say "下一步：lnmp backup run all，再用 lnmp backup list 查看远端批次。"
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
  remote-setup              配置 SFTP 异地上传：生成密钥、核对指纹、试连后写入配置
  remote-setup s3           配置 S3 兼容对象存储：安装 rclone、填写访问密钥、试写后写入配置

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
        remote-setup) Cmd_Remote_Setup "$@" ;;
        help|-h|--help) Usage ;;
        *)       Usage; return 1 ;;
    esac
}

Main "$@"
