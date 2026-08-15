#!/usr/bin/env bash

export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

umask 077

if [ $(id -u) != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本！"
    exit 1
fi

cur_dir=$(cd "$(dirname "$0")/.." && pwd)
# 脚本被复制到源码目录之外执行时，上面推导出的 cur_dir 是错的，加载会失败。
# 不检查的话后面每个公共函数都会 command not found，却还继续往下跑。
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
    echo "错误：本脚本只支持 ${DB_Kind} >= ${Min_Ver}，当前为 ${DB_Ver}。"
    echo "请按该版本官方文档的密码恢复流程操作。"
    exit 1
fi

# --- 读密码：不回显、两次确认 -----------------------------------------------
while :; do
    DB_Root_Password=''
    DB_Root_Password2=''
    read -r -s -p "请输入新的 ${DB_Name} root 密码：" DB_Root_Password
    echo
    if [ -z "${DB_Root_Password}" ]; then
        echo "错误：密码不能为空。"
        continue
    fi
    read -r -s -p "请再次输入新密码：" DB_Root_Password2
    echo
    if [ "${DB_Root_Password}" != "${DB_Root_Password2}" ]; then
        echo "错误：两次输入不一致，请重来。"
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
    echo "警告：用户 ${DB_User} 不存在，按 root 运行临时实例。"
    DB_User='root'
fi

# --- 停掉正在跑的服务 --------------------------------------------------------
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

# --- 用官方 --init-file 流程拉起临时实例 -------------------------------------
#
# --skip-networking  强制只走 Unix socket，重置窗口内不对网络暴露任何东西
# --socket/--pid-file 指到私有目录，这样后面能确认"关闭的是本次启动的实例"
echo "正在启动临时 ${DB_Name} 实例（仅使用 init-file 和本地 socket）..."
"${DB_Safe}" \
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

# 确认拿到的确实是本次启动的实例：它必须写出了指定的 pid 文件
if [ ! -s "${Tmp_Pid}" ]; then
    echo "错误：临时实例没有写出预期的 pid 文件，无法确认身份，中止。"
    exit 1
fi
Tmp_Mysqld_Pid=$(cat "${Tmp_Pid}")

# --- 关掉临时实例，恢复正常服务 ---------------------------------------------
echo "正在关闭临时实例..."
# init-file 中的 ALTER USER 已经让新密码立即生效，不能再用无凭据的
# mysqladmin shutdown。前面已通过专用 pid 文件确认实例身份，向该 pid 发送
# SIGTERM 会让 mysqld 走正常关闭流程，也不需要把新密码再写进命令行或配置文件。
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
