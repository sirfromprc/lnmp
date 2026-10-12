# shellcheck shell=bash
# 数据库运行部分：安装目录识别、my.cnf 取值、socket 与端口。
# 安装器经 include/main.sh 加载；管理命令与 tools/lnmp-* 部署时由 include/rt/cli_assemble.sh 并入产物。
# 本文件只含函数定义，不含顶层语句，不引用组件变量。

# Db_Detect：输出已安装数据库的 "种类<TAB>目录<TAB>客户端<TAB>配置程序"，种类为 mysql 或 mariadb。
# 未安装或 /etc/my.cnf 缺失时返回 1，不输出。MariaDB 优先，新旧命令名均可识别。
Db_Detect()
{
    local dir=/usr/local/mariadb client='' config='' safe='' f

    if [ -s /etc/my.cnf ]; then
        for f in "${dir}/bin/mariadb" "${dir}/bin/mysql"; do
            [ -x "${f}" ] && { client=${f}; break; }
        done
        for f in "${dir}/bin/mariadb_config" "${dir}/bin/mysql_config"; do
            [ -x "${f}" ] && { config=${f}; break; }
        done
        for f in "${dir}/bin/mariadbd-safe" "${dir}/bin/mysqld_safe"; do
            [ -x "${f}" ] && { safe=${f}; break; }
        done
        if [ -n "${client}" ] && [ -n "${config}" ] && [ -n "${safe}" ]; then
            printf 'mariadb\t%s\t%s\t%s\n' "${dir}" "${client}" "${config}"
            return 0
        fi
        dir=/usr/local/mysql
        if [ -s "${dir}/bin/mysql" ] && [ -s "${dir}/bin/mysqld_safe" ]; then
            printf 'mysql\t%s\t%s\t%s\n' "${dir}" "${dir}/bin/mysql" "${dir}/bin/mysql_config"
            return 0
        fi
    fi
    return 1
}

# Db_Conf_Value <键> [配置文件]：输出 [mysqld] 段中该键的首个值，未配置时输出空。
Db_Conf_Value()
{
    local key="$1" conf="${2:-/etc/my.cnf}"

    [ -n "${key}" ] && [ -s "${conf}" ] || return 0
    awk -v key="${key}" '
        /^[[:space:]]*\[/ {
            section = $0
            sub(/^[[:space:]]*\[[[:space:]]*/, "", section)
            sub(/[[:space:]]*\].*$/, "", section)
            next
        }
        section == "mysqld" && found == "" && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            value = $0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            sub(/[[:space:]#].*$/, "", value)
            found = value
        }
        END { if (found != "") print found }
    ' "${conf}"
}

# Db_Socket [配置文件]：输出客户端连接用的 socket，[client] 优先，其次 [mysqld]。
# --defaults-file 不读 /etc/my.cnf，临时凭据必须自带 socket 才能连上。
Db_Socket()
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
        ' "${conf}" 2>/dev/null)
    fi
    printf '%s' "${sock:-/run/mysqld/mysqld.sock}"
}

# Db_Server_Socket [配置文件]：输出服务端监听的 socket，只读 [mysqld] 与 [server] 段。
Db_Server_Socket()
{
    local conf="${1:-/etc/my.cnf}" sock

    sock=$(awk -F= '
        /^[[:space:]]*\[/ { in_srv = ($0 ~ /\[(mysqld|server)\]/) }
        in_srv && $1 ~ /^[[:space:]]*socket[[:space:]]*$/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit
        }
    ' "${conf}" 2>/dev/null)
    printf '%s' "${sock:-/run/mysqld/mysqld.sock}"
}

# Db_Port [配置文件] [退回值]：输出 [mysqld] 段最后一个有效端口。
# 返回 0 表示取自配置文件；取不到时输出退回值（默认 3306）并返回 1。
Db_Port()
{
    local conf="${1:-/etc/my.cnf}" fallback="${2:-3306}" port=''

    if [ -s "${conf}" ]; then
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
        ' "${conf}" 2>/dev/null)
    fi

    case "${port}" in
        ''|*[!0-9]*) port='' ;;
        *) [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ] || port='' ;;
    esac

    if [ -z "${port}" ]; then
        printf '%s\n' "${fallback}"
        return 1
    fi
    printf '%s\n' "${port}"
    return 0
}
