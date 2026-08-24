#!/usr/bin/env bash

export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

umask 077

if [ "$(id -u)" != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本！"
    exit 1
fi

cur_dir=$(cd "$(dirname "$0")/.." && pwd)
# 校验源码目录，避免在其他位置执行时因公共函数未加载而继续重置密码。
if [ ! -f "${cur_dir}/include/main.sh" ]; then
    echo "错误：找不到 ${cur_dir}/include/main.sh。"
    echo "请在 LNMP 源码目录内执行本脚本，例如 ./tools/$(basename "$0")。"
    exit 1
fi
. "${cur_dir}/include/main.sh"

Print_Banner \
    "重置 LNMP 的 MySQL/MariaDB root 密码" \
    "使用官方 --init-file 恢复流程，全程不开放无鉴权数据库"

if [ -x /usr/local/mariadb/bin/mariadb ] || [ -x /usr/local/mariadb/bin/mysql ]; then
    DB_Name='mariadb'
    DB_Kind='mariadb'
elif [ -s /usr/local/mysql/bin/mysql ]; then
    DB_Name='mysql'
    DB_Kind='mysql'
else
    echo "未找到 MySQL/MariaDB！"
    exit 1
fi

DB_Dir="/usr/local/${DB_Name}"
DB_Config=''
DB_Admin=''
DB_Client=''
DB_Safe=''
if [ "${DB_Kind}" = 'mariadb' ]; then
    for candidate in "${DB_Dir}/bin/mariadb_config" "${DB_Dir}/bin/mysql_config"; do
        if [ -x "${candidate}" ]; then
            DB_Config="${candidate}"
            break
        fi
    done
    for candidate in "${DB_Dir}/bin/mariadb-admin" "${DB_Dir}/bin/mysqladmin"; do
        if [ -x "${candidate}" ]; then
            DB_Admin="${candidate}"
            break
        fi
    done
    for candidate in "${DB_Dir}/bin/mariadb" "${DB_Dir}/bin/mysql"; do
        if [ -x "${candidate}" ]; then
            DB_Client="${candidate}"
            break
        fi
    done
    for candidate in "${DB_Dir}/bin/mariadbd-safe" "${DB_Dir}/bin/mysqld_safe"; do
        if [ -x "${candidate}" ]; then
            DB_Safe="${candidate}"
            break
        fi
    done
else
    DB_Config="${DB_Dir}/bin/mysql_config"
    DB_Admin="${DB_Dir}/bin/mysqladmin"
    DB_Client="${DB_Dir}/bin/mysql"
    DB_Safe="${DB_Dir}/bin/mysqld_safe"
fi

if [ ! -x "${DB_Config}" ] || [ ! -x "${DB_Admin}" ] \
    || [ ! -x "${DB_Client}" ] || [ ! -x "${DB_Safe}" ]; then
    echo "错误：${DB_Name} 客户端工具不完整。"
    exit 1
fi

DB_Ver=$("${DB_Config}" --version 2>/dev/null)
if [ -z "${DB_Ver}" ]; then
    echo "错误：无法读取 ${DB_Name} 版本（${DB_Config}）。"
    exit 1
fi
echo "检测到：${DB_Name} ${DB_Ver}"

# Version_GE <a> <b>：a >= b 时返回 0；sort -V 按版本段比较，避免字典序误判。
Version_GE()
{
    [ -z "$1" ] && return 1
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}


if [ "${DB_Kind}" = 'mysql' ]; then
    Min_Ver='5.7'
else
    Min_Ver='10.2'
fi
if ! Version_GE "${DB_Ver}" "${Min_Ver}"; then
    echo "错误：本脚本只支持 ${DB_Kind} >= ${Min_Ver}，当前为 ${DB_Ver}。"
    echo "请按该版本官方文档的密码恢复流程操作。"
    exit 1
fi

# --- 读取密码：不回显并要求两次输入一致 -----------------------------
# 只在真实终端重试；EOF 直接失败，避免非交互执行时空转刷屏。
if [ ! -t 0 ]; then
    echo "错误：标准输入不是终端，无法安全读取新密码。" >&2
    echo "请在交互终端执行本脚本。" >&2
    exit 1
fi
while :; do
    DB_Root_Password=''
    DB_Root_Password2=''
    if ! read -r -s -p "请输入新的 ${DB_Name} root 密码：" DB_Root_Password; then
        echo
        echo "错误：读取密码时输入已结束，未修改任何内容。" >&2
        exit 1
    fi
    echo
    if [ -z "${DB_Root_Password}" ]; then
        echo "错误：密码不能为空。"
        continue
    fi
    if ! read -r -s -p "请再次输入新密码：" DB_Root_Password2; then
        echo
        echo "错误：读取确认密码时输入已结束，未修改任何内容。" >&2
        exit 1
    fi
    echo
    if [ "${DB_Root_Password}" != "${DB_Root_Password2}" ]; then
        echo "错误：两次输入不一致，请重来。"
        continue
    fi
    break
done
unset DB_Root_Password2

# 转义 SQL 单引号字符串中的反斜杠和单引号，防止合法密码引发语法错误或改变 SQL 语义。
# 使用参数展开可避免外部命令依赖。反斜杠必须先转义，否则后续新增的转义符会被重复处理。
Sql_Escape()
{
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\'/\\\'}"
    printf '%s' "${v}"
}
Sql_Escaped_Password=$(Sql_Escape "${DB_Root_Password}")

# --- 私有工作目录：限制访问并在退出时清理 -------------------------
Work_Dir=$(mktemp -d /run/lnmp-dbreset.XXXXXXXX 2>/dev/null) \
    || Work_Dir=$(mktemp -d /tmp/lnmp-dbreset.XXXXXXXX) || exit 1
chmod 700 "${Work_Dir}"

Cleanup()
{
    [ -n "${Work_Dir}" ] && rm -rf "${Work_Dir}"
}
trap Cleanup EXIT INT TERM

Init_Sql="${Work_Dir}/reset.sql"
Tmp_Sock="${Work_Dir}/reset.sock"
Tmp_Pid="${Work_Dir}/reset.pid"
Tmp_Log="${Work_Dir}/reset.log"
cat > "${Init_Sql}" <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${Sql_Escaped_Password}';
EOF
chmod 600 "${Init_Sql}"

# mysqld 使用数据库服务账号运行，该账号需要读取 init-file 并写入工作目录。
DB_User=$(awk -F= '/^[[:space:]]*user[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' /etc/my.cnf 2>/dev/null)
[ -z "${DB_User}" ] && DB_User="${DB_Name}"
if id "${DB_User}" >/dev/null 2>&1; then
    chown -R "${DB_User}" "${Work_Dir}"
else
    echo "警告：用户 ${DB_User} 不存在，按 root 运行临时实例。"
    DB_User='root'
fi

# --- 停止当前数据库服务 ----------------------------------------------------
echo "正在停止 ${DB_Name}..."
/etc/init.d/${DB_Name} stop >/dev/null 2>&1
Waited=0
DB_Server_Running()
{
    pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1
}

while DB_Server_Running; do
    if [ ${Waited} -ge 60 ]; then
        echo "错误：60 秒后仍有 mysqld 在运行，中止。"
        echo "请先确认没有别的实例占用，再重新执行本脚本。"
        exit 1
    fi
    sleep 2
    Waited=$((Waited + 2))
done

# --- 使用官方 --init-file 流程启动临时实例 -------------------------------
#
# --skip-networking 强制仅通过 Unix socket 访问，密码重置期间不开放网络连接。
# --socket 和 --pid-file 使用私有目录，以便准确识别并关闭临时实例。
echo "正在启动临时 ${DB_Name} 实例（仅使用 init-file 和本地 socket）..."
"${DB_Safe}" \
    --user="${DB_User}" \
    --init-file="${Init_Sql}" \
    --skip-networking \
    --socket="${Tmp_Sock}" \
    --pid-file="${Tmp_Pid}" \
    >"${Tmp_Log}" 2>&1 &

# 通过 ping 轮询临时实例，最长等待 120 秒。
Ready='n'
Waited=0
while [ ${Waited} -lt 120 ]; do
    if "${DB_Admin}" --socket="${Tmp_Sock}" ping >/dev/null 2>&1; then
        Ready='y'
        break
    fi
    sleep 2
    Waited=$((Waited + 2))
done

if [ "${Ready}" != 'y' ]; then
    echo "错误：临时实例未能在 120 秒内就绪，密码未修改。"
    echo "启动日志："
    sed 's/^/    /' "${Tmp_Log}" 2>/dev/null | tail -n 30
    pkill -F "${Tmp_Pid}" >/dev/null 2>&1
    /etc/init.d/${DB_Name} start >/dev/null 2>&1
    exit 1
fi

# 指定的 pid 文件必须存在，用于确认后续操作针对本次启动的临时实例。
if [ ! -s "${Tmp_Pid}" ]; then
    echo "错误：临时实例没有写出预期的 pid 文件，无法确认身份，中止。"
    exit 1
fi
Tmp_Mysqld_Pid=$(cat "${Tmp_Pid}")

# --- 关闭临时实例并恢复正常服务 -----------------------------------------
echo "正在关闭临时实例..."
# ALTER USER 执行后新密码已生效，无凭据的 mysqladmin shutdown 无法使用。
# 向专用 pid 文件标识的进程发送 SIGTERM，可正常关闭临时实例，
# 且无需将新密码写入命令行或配置文件。
if ! kill -TERM "${Tmp_Mysqld_Pid}" 2>/dev/null; then
    echo "错误：无法向临时实例发送关闭信号（pid ${Tmp_Mysqld_Pid}）。"
    exit 1
fi
Waited=0
while kill -0 "${Tmp_Mysqld_Pid}" 2>/dev/null; do
    if [ ${Waited} -ge 60 ]; then
        echo "错误：临时实例未能正常退出（pid ${Tmp_Mysqld_Pid}），请手工处理后再启动服务。"
        exit 1
    fi
    sleep 2
    Waited=$((Waited + 2))
done

echo "正在启动 ${DB_Name} 服务..."
if ! /etc/init.d/${DB_Name} start; then
    echo "错误：${DB_Name} 服务启动失败，请检查 ${DB_Name} 错误日志。"
    exit 1
fi

# 密码不回显且不写入文件，防止终端记录或安装日志泄露凭据。
echo "${DB_Name} root 密码已重置完成。"
echo "验证：${DB_Client} -u root -p"
exit 0
