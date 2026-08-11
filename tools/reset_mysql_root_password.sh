#!/usr/bin/env bash

export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

umask 077

if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this script!"
    exit 1
fi

echo "+-------------------------------------------------------------------+"
echo "|            Reset MySQL/MariaDB root Password for LNMP             |"
echo "+-------------------------------------------------------------------+"
echo "|  使用官方 --init-file 恢复流程，全程不开放无鉴权数据库             |"
echo "+-------------------------------------------------------------------+"

if [ -s /usr/local/mariadb/bin/mysql ]; then
    DB_Name='mariadb'
    DB_Kind='mariadb'
elif [ -s /usr/local/mysql/bin/mysql ]; then
    DB_Name='mysql'
    DB_Kind='mysql'
else
    echo "MySQL/MariaDB not found!"
    exit 1
fi

DB_Dir="/usr/local/${DB_Name}"
DB_Ver=$(${DB_Dir}/bin/mysql_config --version 2>/dev/null)
if [ -z "${DB_Ver}" ]; then
    echo "Error: 无法读取 ${DB_Name} 版本（${DB_Dir}/bin/mysql_config）。"
    exit 1
fi
echo "Detected: ${DB_Name} ${DB_Ver}"

# Version_GE <a> <b>：a >= b 返回 0。使用 sort -V 避免按字典序比较版本号。
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
    echo "Error: 本脚本只支持 ${DB_Kind} >= ${Min_Ver}，当前为 ${DB_Ver}。"
    echo "请按该版本官方文档的密码恢复流程操作。"
    exit 1
fi

# --- 读密码：不回显、两次确认 -----------------------------------------------
while :; do
    DB_Root_Password=''
    DB_Root_Password2=''
    read -r -s -p "Enter new ${DB_Name} root password: " DB_Root_Password
    echo
    if [ -z "${DB_Root_Password}" ]; then
        echo "Error: Password can't be empty."
        continue
    fi
    read -r -s -p "Retype new password: " DB_Root_Password2
    echo
    if [ "${DB_Root_Password}" != "${DB_Root_Password2}" ]; then
        echo "Error: 两次输入不一致，请重来。"
        continue
    fi
    break
done
unset DB_Root_Password2

# SQL 单引号字符串的转义：反斜杠和单引号。
# 不做这一步的话，含 ' 的合法密码会让语句语法错误，构造过的输入还能改变 SQL 语义。
# 使用参数展开，避免额外的引号转义和外部命令依赖。
# 顺序不能反：必须先转反斜杠，否则会把下一步加进去的转义符再转一遍。
Sql_Escape()
{
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\'/\\\'}"
    printf '%s' "${v}"
}
Sql_Escaped_Password=$(Sql_Escape "${DB_Root_Password}")

# --- 私有工作目录：root 独占，trap 清理 -------------------------------------
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

# mysqld 以数据库自己的用户运行，得能读到 init-file 与写工作目录
DB_User=$(awk -F= '/^[[:space:]]*user[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' /etc/my.cnf 2>/dev/null)
[ -z "${DB_User}" ] && DB_User="${DB_Name}"
if id "${DB_User}" >/dev/null 2>&1; then
    chown -R "${DB_User}" "${Work_Dir}"
else
    echo "Warning: 用户 ${DB_User} 不存在，按 root 运行临时实例。"
    DB_User='root'
fi

# --- 停掉正在跑的服务 --------------------------------------------------------
echo "Stopping ${DB_Name}..."
/etc/init.d/${DB_Name} stop >/dev/null 2>&1
Waited=0
while pgrep -x mysqld >/dev/null 2>&1; do
    if [ ${Waited} -ge 60 ]; then
        echo "Error: 60 秒后仍有 mysqld 在运行，中止。"
        echo "请先确认没有别的实例占用，再重新执行本脚本。"
        exit 1
    fi
    sleep 2
    Waited=$((Waited + 2))
done

# --- 用官方 --init-file 流程拉起临时实例 -------------------------------------
#
# --skip-networking  强制只走 Unix socket，重置窗口内不对网络暴露任何东西
# --socket/--pid-file 指到私有目录，这样后面能确认"关闭的是本次启动的实例"
echo "Starting temporary ${DB_Name} instance (init-file, socket only)..."
${DB_Dir}/bin/mysqld_safe \
    --user="${DB_User}" \
    --init-file="${Init_Sql}" \
    --skip-networking \
    --socket="${Tmp_Sock}" \
    --pid-file="${Tmp_Pid}" \
    >"${Tmp_Log}" 2>&1 &

# 轮询等待就绪，而不是固定 sleep
Ready='n'
Waited=0
while [ ${Waited} -lt 120 ]; do
    if ${DB_Dir}/bin/mysqladmin --socket="${Tmp_Sock}" ping >/dev/null 2>&1; then
        Ready='y'
        break
    fi
    sleep 2
    Waited=$((Waited + 2))
done

if [ "${Ready}" != 'y' ]; then
    echo "Error: 临时实例未能在 120 秒内就绪，密码**未**修改。"
    echo "启动日志："
    sed 's/^/    /' "${Tmp_Log}" 2>/dev/null | tail -n 30
    pkill -F "${Tmp_Pid}" >/dev/null 2>&1
    /etc/init.d/${DB_Name} start >/dev/null 2>&1
    exit 1
fi

# 确认拿到的确实是本次启动的实例：它必须写出了指定的 pid 文件
if [ ! -s "${Tmp_Pid}" ]; then
    echo "Error: 临时实例没有写出预期的 pid 文件，无法确认身份，中止。"
    exit 1
fi
Tmp_Mysqld_Pid=$(cat "${Tmp_Pid}")

# --- 关掉临时实例，恢复正常服务 ---------------------------------------------
echo "Shutting down temporary instance..."
# init-file 中的 ALTER USER 已经让新密码立即生效，不能再用无凭据的
# mysqladmin shutdown。前面已通过专用 pid 文件确认实例身份，向该 pid 发送
# SIGTERM 会让 mysqld 走正常关闭流程，也不需要把新密码再写进命令行或配置文件。
if ! kill -TERM "${Tmp_Mysqld_Pid}" 2>/dev/null; then
    echo "Error: 无法向临时实例发送关闭信号（pid ${Tmp_Mysqld_Pid}）。"
    exit 1
fi
Waited=0
while kill -0 "${Tmp_Mysqld_Pid}" 2>/dev/null; do
    if [ ${Waited} -ge 60 ]; then
        echo "Error: 临时实例未能正常退出（pid ${Tmp_Mysqld_Pid}），请手工处理后再启动服务。"
        exit 1
    fi
    sleep 2
    Waited=$((Waited + 2))
done

echo "Starting ${DB_Name} service..."
if ! /etc/init.d/${DB_Name} start; then
    echo "Error: ${DB_Name} 服务启动失败，请检查 ${DB_Name} 错误日志。"
    exit 1
fi

# 密码不回显且不写入文件，防止终端记录或安装日志泄露凭据。
echo "${DB_Name} root 密码已重置完成。"
echo "验证：${DB_Dir}/bin/mysql -u root -p"
exit 0
