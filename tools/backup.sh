#!/usr/bin/env bash
#
# 网站与数据库备份，可选异机上传。
#
# 这是一个模板：安装流程不会自动调度它。按下面的说明填好配置后，
# 手工执行或加进 cron（例如每天 3 点：0 3 * * * /path/to/backup.sh）。
#
# ---------------------------------------------------------------------------
# 凭据处理原则
#
# 本脚本不把任何口令放进命令行参数。原因：进程参数对同机所有用户可见，
# 一条 `ps aux` 就能看到数据库 root 密码和上传账号口令，
# 而备份脚本通常以 root 跑、且跑在有普通用户的机器上。
#
#   数据库  →  用 --defaults-extra-file 指向权限 0600 的 option file
#   异机上传 →  用 SSH 密钥，不用口令
#
# 异机上传固定走 SFTP，不再用明文 FTP：上传的是完整站点文件加数据库转储，
# 明文 FTP 会把账号口令和全部业务数据一起暴露给链路上的任何人。
# ---------------------------------------------------------------------------

set -u

########################  基本配置  ########################

Backup_Home="/home/backup"

MySQL_Dump="/usr/local/mysql/bin/mysqldump"

# 要备份的网站目录
Backup_Dir=("/home/wwwroot/example.com" "/home/wwwroot/example.net")

# 要备份的数据库
Backup_Database=("db1" "db2")

# 保留天数：早于这个天数的备份会被删除（本地与远端同步删）
Keep_Days=3

########################  数据库凭据  ########################
#
# 不在这里写密码。先建一个只有 root 能读的 option file：
#
#   umask 077
#   cat > /root/.my.cnf.backup <<'EOF'
#   [mysqldump]
#   user=root
#   password=数据库密码
#   EOF
#   chmod 600 /root/.my.cnf.backup
#
# 用 --defaults-extra-file 而不是 --defaults-file：前者是在默认配置之外
# 追加读取，socket 路径等系统默认设置仍然生效。

MySQL_Option_File="/root/.my.cnf.backup"

########################  异机备份（SFTP）  ########################

# 0 = 禁用（默认）， 1 = 启用
Enable_Remote_Backup=0

Remote_Host='backup.example.com'
Remote_Port=22
Remote_User='backupuser'
Remote_Dir='backup'

# 专用 SSH 私钥。不要复用日常登录密钥 ：
# 这把钥匙躺在被备份的这台机器上，一旦机器失陷，它能开的门越少越好。
# 生成：ssh-keygen -t ed25519 -N '' -f /root/.ssh/lnmp_backup
# 并在备份服务器上用 command="internal-sftp" 等限制这把钥匙的权限。
Remote_SSH_Key='/root/.ssh/lnmp_backup'

# 固定的对端主机指纹文件。必须预先填好，脚本不会自动接受未知主机 ：
# 自动接受等于把首次连接完全交给网络，中间人换个主机密钥就能收走全部备份。
#
# 填法：
#   ssh-keyscan -p 22 backup.example.com > /root/.ssh/lnmp_backup_known_hosts
# 然后用带外方式核对指纹（在备份服务器本机上执行
#   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
# 比对输出）。核对之前不要认为它是可信的。
Remote_Known_Hosts='/root/.ssh/lnmp_backup_known_hosts'

# ---------------------------------------------------------------------------
# 只能用 FTPS 或明文 FTP 时怎么办
#
#   FTPS：必须固定并校验对端证书（自签或私有 CA 都行），不能关校验。
#         lftp 下形如 set ssl:ca-file /path/to/ca.pem;
#         set ssl:verify-certificate yes
#   明文 FTP：先建 WireGuard / SSH 隧道，让 FTP 跑在加密隧道里面。
#             不要直接对公网跑明文 FTP。
# ---------------------------------------------------------------------------

########################  配置结束  ########################

TS=$(date +"%Y%m%d")
OLD_TS=$(date -d "-${Keep_Days} day" +"%Y%m%d" 2>/dev/null) \
    || OLD_TS=$(date -v-"${Keep_Days}"d +"%Y%m%d" 2>/dev/null)

die() { echo "Error: $*" >&2; exit 1; }

# 备份文件里有整个数据库和站点源码，只允许 root 读
umask 077

[ -x "${MySQL_Dump}" ] || die "找不到 ${MySQL_Dump}，请检查 MySQL_Dump 配置。"

if [ ! -f "${MySQL_Option_File}" ]; then
    die "缺少数据库 option file：${MySQL_Option_File}
请按本脚本开头「数据库凭据」一节创建它（权限必须 600）。"
fi

# option file 包含数据库最高权限口令，权限不符合要求时中止
perm=$(stat -c '%a' "${MySQL_Option_File}" 2>/dev/null || stat -f '%Lp' "${MySQL_Option_File}" 2>/dev/null)
case "${perm}" in
    600|400) : ;;
    *) die "${MySQL_Option_File} 权限是 ${perm}，必须是 600。修复：chmod 600 ${MySQL_Option_File}" ;;
esac

mkdir -p "${Backup_Home}" || die "无法创建 ${Backup_Home}"
chmod 700 "${Backup_Home}"

Backup_One_Dir()
{
    local path="$1" name parent
    name="${path##*/}"
    parent="${path%/*}"
    [ -d "${path}" ] || { echo "跳过（目录不存在）：${path}"; return 0; }
    tar zcf "${Backup_Home}/www-${name}-${TS}.tar.gz" -C "${parent}" "${name}"
}

Backup_One_Db()
{
    local db="$1"
    # 口令来自 option file，不出现在进程参数里
    "${MySQL_Dump}" --defaults-extra-file="${MySQL_Option_File}" \
                    --single-transaction --quick "${db}" \
        | gzip > "${Backup_Home}/db-${db}-${TS}.sql.gz"
    # mysqldump 在管道左侧，退出码要显式取
    return "${PIPESTATUS[0]}"
}

echo "备份网站文件..."
for d in "${Backup_Dir[@]}"; do
    Backup_One_Dir "${d}" || die "打包失败：${d}"
done

echo "备份数据库..."
for db in "${Backup_Database[@]}"; do
    Backup_One_Db "${db}" || die "导出失败：${db}"
done

echo "清理 ${Keep_Days} 天前的本地备份..."
if [ -n "${OLD_TS}" ]; then
    rm -f "${Backup_Home}"/www-*-"${OLD_TS}".tar.gz
    rm -f "${Backup_Home}"/db-*-"${OLD_TS}".sql.gz
fi

if [ "${Enable_Remote_Backup}" != "1" ]; then
    echo "异机备份未启用（Enable_Remote_Backup=0），本地备份完成：${Backup_Home}"
    exit 0
fi

########################  异机上传  ########################

command -v sftp >/dev/null 2>&1 \
    || die "找不到 sftp 命令。安装：apt-get install openssh-client / yum install openssh-clients"

[ -f "${Remote_SSH_Key}" ] || die "缺少 SSH 私钥：${Remote_SSH_Key}
生成：ssh-keygen -t ed25519 -N '' -f ${Remote_SSH_Key}"

kperm=$(stat -c '%a' "${Remote_SSH_Key}" 2>/dev/null || stat -f '%Lp' "${Remote_SSH_Key}" 2>/dev/null)
case "${kperm}" in
    600|400) : ;;
    *) die "${Remote_SSH_Key} 权限是 ${kperm}，必须是 600。修复：chmod 600 ${Remote_SSH_Key}" ;;
esac

if [ ! -s "${Remote_Known_Hosts}" ]; then
    die "缺少对端主机指纹文件：${Remote_Known_Hosts}

不会自动接受未知主机 —— 那等于把首次连接完全交给网络。请先固定指纹：

  ssh-keyscan -p ${Remote_Port} ${Remote_Host} > ${Remote_Known_Hosts}

然后**带外核对**：在 ${Remote_Host} 本机上执行
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
把指纹与
  ssh-keygen -lf ${Remote_Known_Hosts}
的输出逐字比对。对上了再跑本脚本。"
fi

echo "上传到 ${Remote_User}@${Remote_Host}:${Remote_Dir} ..."

# StrictHostKeyChecking=yes + 指定 UserKnownHostsFile：指纹对不上直接失败，
#   不会像 accept-new 那样在首次连接时盲信。
# IdentitiesOnly=yes：只用上面指定的这把钥匙，不让 ssh-agent 里的其它密钥参与。
# BatchMode=yes：不得交互提问，cron 里跑不会卡住。
# 前缀 - 的命令允许失败（远端可能本来就没有那天的旧文件）。
sftp -b - \
     -P "${Remote_Port}" \
     -i "${Remote_SSH_Key}" \
     -o IdentitiesOnly=yes \
     -o StrictHostKeyChecking=yes \
     -o UserKnownHostsFile="${Remote_Known_Hosts}" \
     -o BatchMode=yes \
     -o ConnectTimeout=30 \
     "${Remote_User}@${Remote_Host}" <<EOF
cd ${Remote_Dir}
-rm www-*-${OLD_TS}.tar.gz
-rm db-*-${OLD_TS}.sql.gz
put ${Backup_Home}/www-*-${TS}.tar.gz
put ${Backup_Home}/db-*-${TS}.sql.gz
bye
EOF

rc=$?
if [ ${rc} -ne 0 ]; then
    die "上传失败（sftp 退出码 ${rc}）。本地备份仍在 ${Backup_Home}。
指纹不匹配会报 HOST KEY VERIFICATION FAILED —— 那说明对端主机密钥变了，
在确认原因之前不要更新 ${Remote_Known_Hosts}。"
fi

echo "完成。"
