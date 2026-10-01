#!/usr/bin/env bash

# 按本机内存为数据库、PHP、Redis、Memcached、OPcache 统一分配预算，
# 结果写入 Tune_* 全局变量，由各组件的写配置入口读取。本文件不写任何文件。
# 取值依据 HowtoGuides.md 6.3～6.6 的 WordPress 混部起始方案：
# 先扣系统余量、Redis 与 OPcache，再定数据库缓冲池，剩余部分按单进程估算值分给 PHP。

# 取值方式：$1 下限 $2 上限 $3 待约束值。
Tune_Clamp()
{
    local lo="$1" hi="$2" v="$3"
    [ "${v}" -lt "${lo}" ] && v="${lo}"
    [ "${v}" -gt "${hi}" ] && v="${hi}"
    printf '%s' "${v}"
}

# 可用内存（MB）：Tune_Mem_MB 优先；否则取 MemTotal 与 cgroup v2 限额中较小者。
Tune_Detect_Mem()
{
    local mem limit

    case "${Tune_Mem_MB:-}" in
    ''|*[!0-9]*) ;;
    *)  if [ "${Tune_Mem_MB}" -ge 256 ]; then
            printf '%s' "${Tune_Mem_MB}"
            return 0
        fi ;;
    esac

    mem=$(awk '/^MemTotal/ {printf "%d", $2 / 1024; exit}' "${Tune_Meminfo:-/proc/meminfo}" 2>/dev/null)
    case "${mem}" in ''|*[!0-9]*) mem=1024 ;; esac
    limit=$(cat "${Tune_Cgroup_Max:-/sys/fs/cgroup/memory.max}" 2>/dev/null)
    case "${limit}" in
    ''|*[!0-9]*) ;;
    *)  limit=$((limit / 1048576))
        [ "${limit}" -gt 0 ] && [ "${limit}" -lt "${mem}" ] && mem="${limit}" ;;
    esac
    printf '%s' "${mem}"
}

Tune_Has_DB()
{
    case "${DB_Kind:-}" in
    mysql|mariadb) return 0 ;;
    none) return 1 ;;
    esac
    [ -x /usr/local/mysql/bin/mysqld ] || [ -x /usr/local/mariadb/bin/mariadbd ] ||
        [ -x /usr/local/mariadb/bin/mysqld ]
}

Tune_Has_PHP()
{
    case "${Stack:-}" in
    lnmp|lnmpa|lamp) return 0 ;;
    esac
    [ -x /usr/local/php/bin/php ]
}

# 计算全部 Tune_* 值。Enable_Auto_Tune=n 时返回 1，调用方保持模板值。
Tune_Plan()
{
    local mem cores reserve avail proc pool_raw db_overhead=256 conn_base

    [ "${Enable_Auto_Tune:-y}" = "y" ] || return 1

    mem=$(Tune_Detect_Mem)
    cores=$(nproc 2>/dev/null)
    case "${cores}" in ''|*[!0-9]*|0) cores=1 ;; esac
    proc="${Tune_PHP_Proc_MB:-100}"
    case "${proc}" in ''|*[!0-9]*) proc=100 ;; esac
    [ "${proc}" -lt 16 ] && proc=16

    Tune_Mem="${mem}"
    Tune_Cores="${cores}"
    # 系统、Nginx、页缓存与突发余量：1GB 约 400M，8GB 约 1.4G，更大内存约 15%。
    reserve=$((256 + mem * 15 / 100))
    if [ "${mem}" -lt 1024 ]; then
        Tune_Opcache_MB=64
    elif [ "${mem}" -lt 4096 ]; then
        Tune_Opcache_MB=128
    else
        Tune_Opcache_MB=256
    fi
    Tune_Redis_MB=$(Tune_Clamp 32 4096 $((mem / 16)))
    Tune_Memcached_MB=$(Tune_Clamp 64 1024 $((mem / 16)))

    Tune_DB_MB=0
    Tune_Pool_MB=0
    avail=$((mem - reserve - Tune_Redis_MB - Tune_Opcache_MB))
    if Tune_Has_DB; then
        if Tune_Has_PHP; then
            # 8GB 以内约 1/8，之上逐步提高到 20%～30%。
            pool_raw=$((mem / 8))
            [ "${mem}" -gt 8192 ] && pool_raw=$((pool_raw + (mem - 8192) / 6))
        else
            # 单装数据库：剩余内存扣除连接与内部结构开销后全部给缓冲池。
            pool_raw=$((avail - db_overhead))
        fi
        # 1G 以下按 128M、以上按 1G 就近取整：MySQL 在缓冲池 ≥1G 时默认多实例，
        # 非整数倍会被向上取整。
        if [ "${pool_raw}" -ge 1024 ]; then
            Tune_Pool_MB=$(((pool_raw + 512) / 1024 * 1024))
        else
            Tune_Pool_MB=$(Tune_Clamp 64 1024 $(((pool_raw + 64) / 128 * 128)))
        fi
        Tune_DB_MB=$((Tune_Pool_MB + db_overhead))
    fi
    Tune_PHP_MB=0
    if Tune_Has_PHP; then
        Tune_PHP_MB=$((avail - Tune_DB_MB))
        [ "${Tune_PHP_MB}" -lt 0 ] && Tune_PHP_MB=0
    fi

    # PHP-FPM：3GB 以下用 ondemand，空闲时不常驻；常驻进程数按核数，不随上限放大。
    Tune_FPM_Children=$(Tune_Clamp 4 300 $((Tune_PHP_MB / proc)))
    if [ "${mem}" -lt 3072 ]; then
        Tune_FPM_PM='ondemand'
    else
        Tune_FPM_PM='dynamic'
    fi
    Tune_FPM_Min_Spare=$(Tune_Clamp 1 $((Tune_FPM_Children / 4 > 1 ? Tune_FPM_Children / 4 : 1)) "${cores}")
    Tune_FPM_Max_Spare=$(Tune_Clamp $((Tune_FPM_Min_Spare + 1)) $((Tune_FPM_Children / 2 > Tune_FPM_Min_Spare + 1 ? Tune_FPM_Children / 2 : Tune_FPM_Min_Spare + 1)) $((cores * 2)))
    Tune_FPM_Start="${Tune_FPM_Min_Spare}"
    # 多版本 PHP 多为少量站点使用，按需拉起，上限取主版本的一半。
    Tune_MPHP_Children=$(Tune_Clamp 2 150 $((Tune_FPM_Children / 2)))

    # Apache prefork + mod_php：每个子进程含 Apache 自身开销，按 PHP 估算值加 16MB。
    # 上限 256 不超过 prefork 默认 ServerLimit，无需另设。
    Tune_Apache_Workers=$(Tune_Clamp 6 256 $((Tune_PHP_MB / (proc + 16))))
    Tune_Apache_Min_Spare=$(Tune_Clamp 2 $((Tune_Apache_Workers / 4 > 2 ? Tune_Apache_Workers / 4 : 2)) "${cores}")
    Tune_Apache_Max_Spare=$(Tune_Clamp $((Tune_Apache_Min_Spare + 1)) $((Tune_Apache_Workers / 2 > Tune_Apache_Min_Spare + 1 ? Tune_Apache_Workers / 2 : Tune_Apache_Min_Spare + 1)) $((cores * 2)))
    Tune_Apache_Start="${Tune_Apache_Min_Spare}"

    Tune_Log_MB=$(Tune_Clamp 48 1024 $((Tune_Pool_MB / 4)))
    # 每个 PHP 进程最多占一个连接；另留一半给多版本 PHP，再加 20 个给计划任务与管理工具。
    if [ "${Stack:-}" = "lnmpa" ] || [ "${Stack:-}" = "lamp" ]; then
        conn_base="${Tune_Apache_Workers}"
    else
        conn_base="${Tune_FPM_Children}"
    fi
    Tune_Max_Conn=$(Tune_Clamp 40 500 $((conn_base * 3 / 2 + 20)))
    # 单装数据库时客户端来自其它主机，连接数无法按本机进程推算，保持模板值。
    [ "${Tune_PHP_MB}" -eq 0 ] && Tune_Max_Conn=500
    Tune_Thread_Cache=$(Tune_Clamp 8 64 $((Tune_Max_Conn / 8)))
    Tune_Table_Cache=$(Tune_Clamp 400 4000 $((Tune_Pool_MB * 2)))
    if [ "${mem}" -lt 2048 ]; then
        Tune_Tmp_MB=16
    else
        Tune_Tmp_MB=32
    fi
    return 0
}

Tune_Print_Summary()
{
    Tune_Plan || {
        echo "按内存调整服务参数：关闭（Enable_Auto_Tune=n），使用模板默认值"
        return 0
    }
    echo "按内存调整服务参数：本机按 ${Tune_Mem} MB / ${Tune_Cores} 核计算（Tune_Mem_MB 可指定）"
    if [ "${Tune_DB_MB}" -gt 0 ]; then
        echo "  数据库：innodb_buffer_pool_size ${Tune_Pool_MB}M，max_connections ${Tune_Max_Conn}"
    fi
    if [ "${Tune_PHP_MB}" -gt 0 ]; then
        if [ "${Stack:-}" = "lnmpa" ] || [ "${Stack:-}" = "lamp" ]; then
            echo "  Apache prefork：MaxRequestWorkers ${Tune_Apache_Workers}；OPcache ${Tune_Opcache_MB}M"
        else
            echo "  PHP-FPM：pm ${Tune_FPM_PM}，max_children ${Tune_FPM_Children}；OPcache ${Tune_Opcache_MB}M"
        fi
    fi
    echo "  另装 Redis 时 maxmemory ${Tune_Redis_MB}M；另装 Memcached 时缓存 ${Tune_Memcached_MB}M"
}

# 在 my.cnf 的 [mysqld] 段内设置参数，不影响 [myisamchk] 等同名项。
# 参数：文件 键 值 [replace]；replace 时键不存在则不添加（InnoDB 关闭时 innodb_* 不得写入）。
Tune_Set_Mysqld()
{
    local file="$1" key="$2" val="$3" mode="${4:-upsert}" tmp

    [ -s "${file}" ] || return 1
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    if ! awk -v key="${key}" -v val="${val}" -v mode="${mode}" '
        function emit() { if (insec && !done && mode != "replace") { print key " = " val; done = 1 } }
        /^\[/ {
            emit()
            insec = ($0 ~ /^\[mysqld\][[:space:]]*$/)
            print; next
        }
        insec && $0 ~ "^" key "[[:space:]]*=" {
            if (!done) { print key " = " val; done = 1 }
            next
        }
        { print }
        END { emit() }
    ' "${file}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    chmod --reference="${file}" "${tmp}" 2>/dev/null
    chown --reference="${file}" "${tmp}" 2>/dev/null
    mv -f "${tmp}" "${file}"
}
