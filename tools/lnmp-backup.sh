#!/usr/bin/env bash
#
# lnmp-backup —— 网站与数据库备份的实现，由 `lnmp backup <子命令>` 调用。
# 安装位置 /bin/lnmp-backup，三个管理脚本（lnmp / lnmpa / lamp）共用这一份。
#
#   lnmp backup init                 生成配置、目录与定时任务
#   lnmp backup run [db|web|all]     执行备份（不带参数按配置的周期决定）
#   lnmp backup status               上次结果、下次计划、最近错误
#   lnmp backup list [db|web]        列出本地批次（配了远端则一并列远端）
#   lnmp backup restore ...          从备份恢复
#   lnmp backup test                 试恢复：把最新库备份导入临时库再删掉
#
# ---------------------------------------------------------------------------
# 设计要点
#
# 批次目录用秒级时间戳，同一天可以跑多次而不互相覆盖。
# 库和网站分开存放，各自独立的备份周期与保留天数：库通常每天一份，
# 网站源码变化少，可以每周一份、保留更久。
#
# 每一步都检查完整管道的退出码（mysqldump/tar 在管道左侧，gzip 在右侧，
# 磁盘写满时失败的往往是右侧），产物先写 .part 再改名，中途失败不会留下
# 一个看着正常、其实截断的备份文件。
#
# 远端上传先传到 .incoming/<批次>/，逐个核对远端文件大小，全部对上之后再
# rename 到正式目录，最后才清理旧批次 —— 先删后传会在传输失败时直接损失
# 一个可恢复点。
#
# 凭据不进命令行参数：数据库口令走 0600 的 option file，上传走 SSH 密钥。
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

# 备份内容是整站源码和整库数据，只允许 root 读
umask 077

# ---------------------------------------------------------------------------
# 输出与日志
# ---------------------------------------------------------------------------
Color()   { if [ -t 1 ]; then printf '\033[%sm%s\033[0m\n' "$1" "$2"; else printf '%s\n' "$2"; fi; }
Say()     { printf '%s\n' "$*"; }
Warn()    { Color "0;33" "$*"; }
Err()     { Color "0;31" "$*" >&2; }
Ok()      { Color "0;32" "$*"; }

# 日志目录可能还没建好，写不进去也不该让备份失败
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
    Remote_Host=""
    Remote_Port=22
    Remote_User=""
    Remote_Dir="backup"
    Remote_SSH_Key="/root/.ssh/lnmp_backup"
    Remote_Known_Hosts="/root/.ssh/lnmp_backup_known_hosts"
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

    [ -n "${Backup_Home}" ] || Die "Backup_Home 不能为空。"
    case "${Backup_Home}" in
        /|/bin|/etc|/home|/root|/usr|/var) Die "Backup_Home 不能是系统目录：${Backup_Home}" ;;
        /*) : ;;
        *) Die "Backup_Home 必须是绝对路径：${Backup_Home}" ;;
    esac
    Is_Number "${Keep_Days_Db}"   || Die "Keep_Days_Db 必须是数字。"
    Is_Number "${Keep_Days_Web}"  || Die "Keep_Days_Web 必须是数字。"
    Is_Number "${Web_Interval_Days}" || Die "Web_Interval_Days 必须是数字。"
    [ "${Keep_Days_Db}" -ge 1 ]  || Die "Keep_Days_Db 至少为 1。"
    [ "${Keep_Days_Web}" -ge 1 ] || Die "Keep_Days_Web 至少为 1。"
    return 0
}

Is_Number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# option file 与私钥里是最高权限凭据，权限不对直接停下
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
    [ -n "${MySQL_Dump}" ] && [ -x "${MySQL_Dump}" ] && return 0
    for c in /usr/local/mysql/bin/mysqldump /usr/local/mariadb/bin/mysqldump \
             /usr/bin/mysqldump /usr/bin/mariadb-dump; do
        if [ -x "${c}" ]; then MySQL_Dump="${c}"; return 0; fi
    done
    return 1
}

Find_Mysql_Client()
{
    local c
    for c in /usr/local/mysql/bin/mysql /usr/local/mariadb/bin/mysql /usr/bin/mysql; do
        if [ -x "${c}" ]; then printf '%s' "${c}"; return 0; fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# 并发锁：同一时刻只允许一个备份在跑，否则两次运行会写进同一批目录、
# 也可能一边在清理一边在上传。
# ---------------------------------------------------------------------------
Lock_Dir=""
Tmp_Work=""

# 统一的退出清理：锁目录和临时工作目录。分散注册 trap 会互相覆盖。
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
    # 没有 flock 的环境用 mkdir 兜底：mkdir 对已存在的目录必然失败，
    # 这一点是原子的，足以当锁用。
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

# 批次目录名形如 20260810-033000，取前 8 位与截止日期做数值比较。
# 原实现用 date -d "-N day" 拼出一个具体日期再删，只能删掉“正好 N 天前”
# 那一天的文件；某天没跑或跑在别的时刻，更早的备份就永远留下了。
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

# 删除批次目录前核对目标：必须落在 ${Backup_Home}/{db,www} 下、名字是合法批次。
# 不这样卡一道，配置写错或变量为空时 rm -rf 的目标就可能是别的地方。
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
# 统一套路：写 <目标>.part，全部退出码确认无误后再 mv 成最终名。
# tar 与 mysqldump 都在管道左侧，gzip 在右侧，磁盘写满时失败的是右侧，
# 只看左侧的退出码就会把写坏的备份当成功。
# ---------------------------------------------------------------------------
Dump_Db()
{
    local db="$1" out="$2" part="$2.part" rc_dump rc_gzip pipe_st
    "${MySQL_Dump}" --defaults-extra-file="${MySQL_Option_File}" \
        --single-transaction --quick --routines --triggers --events \
        --default-character-set=utf8mb4 "${db}" 2>>"${Log_File}" \
        | gzip -c > "${part}"
    # PIPESTATUS 必须一次性快照：第一条赋值语句本身就会把它重置成
    # 那条赋值的状态，再取 [1] 拿到的不是管道右侧的退出码 ——
    # set -u 下直接报 unbound variable，没开 set -u 则静默变成空字符串，
    # gzip / mysql 的失败会被当成没发生。
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
    # 退出码为 0 不等于转储完整：磁盘写满或进程被杀时前面的内容已经落盘，
    # 文件看着是好的。mysqldump 正常结束会写 "-- Dump completed"，
    # 用它做完整性判据（与 include/dbcommon.sh 的 Check_DB_Backup 一致）。
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
        Log WARN "网站目录不存在，跳过：${path}"
        return 2
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

# 可选加密。默认关闭；开启后校验清单针对加密后的文件计算，
# 恢复时先解密再校验解压。
Encrypt_File()
{
    local in="$1" out="${1}.enc" rc=0
    [ "${Enable_Encrypt}" = "1" ] || { printf '%s' "${in}"; return 0; }
    [ -n "${Encrypt_Recipient}" ] || { Log ERROR "启用了加密但没有配置 Encrypt_Recipient"; return 1; }
    case "${Encrypt_Tool}" in
        age)
            command -v age >/dev/null 2>&1 || { Log ERROR "找不到 age 命令"; return 1; }
            age -r "${Encrypt_Recipient}" -o "${out}" "${in}"; rc=$?
            ;;
        gpg)
            command -v gpg >/dev/null 2>&1 || { Log ERROR "找不到 gpg 命令"; return 1; }
            gpg --batch --yes --trust-model always -e -r "${Encrypt_Recipient}" -o "${out}" "${in}"; rc=$?
            ;;
        *) Log ERROR "Encrypt_Tool 只支持 age 或 gpg：${Encrypt_Tool}"; return 1 ;;
    esac
    [ "${rc}" -eq 0 ] || { rm -f "${out}"; Log ERROR "加密失败：${in}"; return 1; }
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
    command -v sftp >/dev/null 2>&1 || { Log ERROR "找不到 sftp 命令"; return 1; }
    [ -n "${Remote_Host}" ] && [ -n "${Remote_User}" ] || { Log ERROR "远端主机或账号未配置"; return 1; }
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

# 上传 → 核对 → 改名。中途任何一步失败都不动正式目录里的既有备份。
Upload_Batch()
{
    local type="$1" batch="$2" dir="${Backup_Home}/$1/$2"
    local staging="${Remote_Dir}/.incoming/${batch}-${type}"
    local f base out rc local_size remote_size ok=1

    Check_Remote_Conf || return 1
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

    # 逐个核对远端大小。受限的 internal-sftp 账号不能在远端执行 sha256sum，
    # 这里能做到的是发现截断和缺失 —— 内容级校验只能在本地清单上做，
    # 这一点不夸大成“远端已校验”。
    for f in "${dir}"/*; do
        [ -f "${f}" ] || continue
        base="${f##*/}"
        local_size=$(stat -c '%s' "${f}" 2>/dev/null || stat -f '%z' "${f}" 2>/dev/null)
        remote_size=$(printf '%s\n' "${out}" | awk -v n="${base}" '$NF == n { print $5 }' | tail -n 1)
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

# 远端清理放在上传成功之后，先有新的可恢复点再删旧的
Cleanup_Remote()
{
    local type="$1" days="$2" out rc b
    Check_Remote_Conf || return 1
    out=$(printf 'ls -1 %s/%s\nbye\n' "${Remote_Dir}" "${type}" | Sftp_Run 2>/dev/null); rc=$?
    [ "${rc}" -eq 0 ] || { Log WARN "无法列出远端 ${type} 目录，跳过远端清理。"; return 0; }
    printf '%s\n' "${out}" | tr -d '\r' | while read -r b; do
        b="${b##*/}"
        Batch_Older_Than "${b}" "${days}" || continue
        Log INFO "清理远端过期批次：${type}/${b}"
        printf -- '-rm %s/%s/%s/*\n-rmdir %s/%s/%s\nbye\n' \
            "${Remote_Dir}" "${type}" "${b}" "${Remote_Dir}" "${type}" "${b}" \
            | Sftp_Run >/dev/null 2>&1
    done
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
        Log WARN "配置里没有任何数据库，跳过库备份。"
        rmdir "${dir}" 2>/dev/null
        return 0
    fi
    if [ "${failed}" -ne 0 ]; then
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
        [ "${rc}" -eq 2 ] && continue
        [ "${rc}" -eq 0 ] || { failed=1; continue; }
        out=$(Encrypt_File "${dir}/www-${domain}.tar.gz") || { failed=1; continue; }
    done
    if [ "${n}" -eq 0 ]; then
        Log WARN "配置里没有任何网站目录，跳过网站备份。"
        rmdir "${dir}" 2>/dev/null
        return 0
    fi
    if [ "${failed}" -ne 0 ]; then
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
    local what="${1:-auto}" batch rc_db=0 rc_web=0 do_db=0 do_web=0 overall=0

    Load_Conf || return 1
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
        *) Err "run 的参数只能是 db、web 或 all"; return 1 ;;
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
                    Cleanup_Remote db "${Keep_Days_Db}"
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
            State_Set Last_Web_Epoch "$(date '+%s')"
            if [ "${Enable_Remote_Backup}" = "1" ]; then
                if Upload_Batch www "${batch}"; then
                    Cleanup_Remote www "${Keep_Days_Web}"
                else
                    rc_web=1
                fi
            fi
        fi
        [ "${rc_web}" -eq 0 ] || overall=1
    fi

    # 清理放在最后：先确认这次有了新的可恢复点，再删旧的
    if [ "${overall}" -eq 0 ]; then
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
    Say "异地上传：$([ "${Enable_Remote_Backup}" = "1" ] && echo "启用 → ${Remote_User}@${Remote_Host}:${Remote_Dir}" || echo "未启用")"
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
    local what="${1:-all}" type b dir size
    Load_Conf || return 1
    for type in db www; do
        case "${what}" in db) [ "${type}" = "db" ] || continue ;; web) [ "${type}" = "www" ] || continue ;; esac
        Say "=== 本地 ${type} 批次 ==="
        for b in $(List_Batches "${type}"); do
            dir="${Backup_Home}/${type}/${b}"
            size=$(du -sh "${dir}" 2>/dev/null | cut -f1)
            printf '  %s  %s  %s 个文件\n' "${b}" "${size:-?}" "$(find "${dir}" -maxdepth 1 -type f -name '*.gz*' 2>/dev/null | wc -l)"
        done
    done
    if [ "${Enable_Remote_Backup}" = "1" ] && Check_Remote_Conf; then
        for type in db www; do
            case "${what}" in db) [ "${type}" = "db" ] || continue ;; web) [ "${type}" = "www" ] || continue ;; esac
            Say "=== 远端 ${type} 批次 ==="
            printf 'ls -1 %s/%s\nbye\n' "${Remote_Dir}" "${type}" | Sftp_Run 2>/dev/null | tr -d '\r' | sed 's#.*/##; /^$/d; s/^/  /'
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
        gzip -dc "${payload}" | "${mysql_bin}" --defaults-extra-file="${MySQL_Option_File}" \
            --default-character-set=utf8mb4 "${name}"
        rc=${PIPESTATUS[1]}
        [ "${rc}" -eq 0 ] || { Err "导入失败（mysql 返回 ${rc}）。"; return 1; }
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
# 子命令：test —— 定期试恢复
#
# 备份“存在”和备份“能恢复”是两件事。这里把最新一份库备份导进一个临时库，
# 确认能建出表来，再把临时库删掉，不碰任何线上数据。
# ---------------------------------------------------------------------------
Cmd_Test()
{
    local batch dir file work payload mysql_bin tmpdb rc tables
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
    "${mysql_bin}" --defaults-extra-file="${MySQL_Option_File}" \
        -e "CREATE DATABASE \`${tmpdb}\`;" || { Err "无法创建临时库 ${tmpdb}。"; return 1; }

    gzip -dc "${payload}" | "${mysql_bin}" --defaults-extra-file="${MySQL_Option_File}" \
        --default-character-set=utf8mb4 "${tmpdb}"
    rc=${PIPESTATUS[1]}

    tables=$("${mysql_bin}" --defaults-extra-file="${MySQL_Option_File}" -N -B \
        -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${tmpdb}';" 2>/dev/null)

    "${mysql_bin}" --defaults-extra-file="${MySQL_Option_File}" \
        -e "DROP DATABASE \`${tmpdb}\`;" >/dev/null 2>&1

    if [ "${rc}" -ne 0 ]; then
        Log ERROR "试恢复失败：导入返回 ${rc}（批次 ${batch}）"
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
# 从已有的 vhost 配置反推站点，再到站点目录里找 wp-config.php 取库名。
# 这样新建站点后只要重跑 init（或手工加一行）就不会漏掉。
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
    cat > "${Systemd_Service}" <<'EOF'
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
    cat > "${Systemd_Timer}" <<EOF
[Unit]
Description=LNMP backup timer

[Timer]
OnCalendar=*-*-* ${hour}:30:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 "${Systemd_Service}" "${Systemd_Timer}"
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now lnmp-backup.timer >/dev/null 2>&1 \
        || { Err "启用 lnmp-backup.timer 失败，请手工检查。"; return 1; }
    Ok "已启用 systemd timer：每天 ${hour}:30 前后执行（带随机延迟）。"
    return 0
}

Write_Cron()
{
    local hour="${1:-3}"
    cat > "${Cron_File}" <<EOF
# LNMP backup —— 由 lnmp backup init 生成
30 ${hour} * * * root /bin/lnmp-backup run
EOF
    chmod 644 "${Cron_File}"
    Ok "已写入 cron：${Cron_File}"
    return 0
}

Cmd_Init()
{
    local sites site_lines ans hour db_pass mysql_bin

    [ "$(id -u)" = "0" ] || { Err "init 需要 root 权限。"; return 1; }
    mkdir -p "${Conf_Dir}" && chmod 700 "${Conf_Dir}" || { Err "无法创建 ${Conf_Dir}"; return 1; }
    mkdir -p "${State_Dir}" "${Log_File%/*}" 2>/dev/null

    if [ -f "${Conf_File}" ]; then
        Warn "配置已存在：${Conf_File}"
        printf '覆盖并重新生成？(y/N) '
        read -r ans
        [ "${ans}" = "y" ] || { Say "保留现有配置。"; return 0; }
        cp -p "${Conf_File}" "${Conf_File}.bak.$(date '+%Y%m%d%H%M%S')"
        Say "旧配置已备份。"
    fi

    Say "扫描已有站点..."
    sites=$(Discover_Sites)
    if [ -n "${sites}" ]; then
        Say "发现以下站点（域名 | 目录 | 数据库）："
        printf '%s\n' "${sites}" | sed 's/^/  /'
        site_lines=$(printf '%s\n' "${sites}" | sed 's/^/    "/; s/$/"/')
    else
        Warn "没有扫描到站点，配置里会留一条示例，请手工填写。"
        site_lines='    #"example.com|/home/wwwroot/example.com|wpdb"'
    fi

    # 数据库 option file：口令只写进 0600 文件，不进命令行、不进配置
    if [ ! -f "${My_Cnf}" ]; then
        printf '输入数据库 root 密码（用于导出，留空则跳过，不回显）: '
        read -r -s db_pass; echo
        if [ -n "${db_pass}" ]; then
            # option file 在引号内把反斜杠当转义符，写入前先加倍
            db_pass="${db_pass//\\/\\\\}"
            ( umask 077; cat > "${My_Cnf}" <<EOF
[mysqldump]
user=root
password='${db_pass}'

[client]
user=root
password='${db_pass}'
EOF
            )
            chmod 600 "${My_Cnf}"
            if mysql_bin=$(Find_Mysql_Client); then
                if "${mysql_bin}" --defaults-extra-file="${My_Cnf}" -e "SELECT 1;" >/dev/null 2>&1; then
                    Ok "数据库凭据校验通过，已写入 ${My_Cnf}（600）。"
                else
                    Err "数据库凭据校验失败，${My_Cnf} 仍已写入，请核对密码后重试。"
                fi
            fi
        else
            Warn "跳过数据库凭据，库备份会因此失败。稍后可重跑 init 补上。"
        fi
    else
        Say "沿用已有的数据库凭据文件：${My_Cnf}"
    fi

    cat > "${Conf_File}" <<EOF
# LNMP 备份配置 —— 由 lnmp backup init 生成
#
# 站点条目格式：域名|网站目录|数据库名
#   数据库名留空表示这个站点只备份文件。
#   新建站点后记得往这里加一行，或重跑 lnmp backup init 重新扫描。

Backup_Home="/home/backup"

# 留空则自动探测 /usr/local/{mysql,mariadb}/bin/mysqldump
MySQL_Dump=""
MySQL_Option_File="${My_Cnf}"

Backup_Site=(
${site_lines}
)

# 保留天数：库和网站各算各的，删除所有早于该天数的批次
Keep_Days_Db=14
Keep_Days_Web=60

# 网站文件多久备份一次（天）。1 表示每天；库总是每次都备份。
Web_Interval_Days=7

# ---- 异地上传（SFTP）----
Enable_Remote_Backup=0
Remote_Host=""
Remote_Port=22
Remote_User=""
Remote_Dir="backup"
# 专用密钥，不要复用日常登录密钥
Remote_SSH_Key="/root/.ssh/lnmp_backup"
# 必须预先固定并带外核对，脚本不会自动接受未知主机：
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

    mkdir -p "/home/backup" && chmod 700 "/home/backup"

    printf '每天几点执行备份？(0-23，默认 3) '
    read -r hour
    case "${hour}" in ''|*[!0-9]*) hour=3 ;; esac
    [ "${hour}" -gt 23 ] 2>/dev/null && hour=3

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        Write_Systemd_Unit "${hour}"
    else
        Write_Cron "${hour}"
    fi

    Say ""
    Say "接下来："
    Say "  1. 按需编辑 ${Conf_File}（保留天数、网站周期、异地上传）"
    Say "  2. 立即跑一次：lnmp backup run all"
    Say "  3. 验证可恢复：lnmp backup test"
    return 0
}

# ---------------------------------------------------------------------------
Usage()
{
    cat <<'EOF'
Usage: lnmp backup <子命令>

  init                      生成配置、备份目录与定时任务
  run [db|web|all]          执行备份；不带参数按配置的周期决定是否备份网站
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
