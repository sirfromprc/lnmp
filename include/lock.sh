#!/usr/bin/env bash
#
# 维护任务互斥锁，供 install.sh、upgrade.sh、addons.sh、uninstall.sh、
# bumpversion.sh 共用。
#
# 锁为 /var/lock 下的符号链接，链接目标记录持有者信息，创建即带内容，
# 不存在“已创建、未写入”的中间状态。
# 持有者退出后由伴随的监视进程移除锁；监视进程未能运行时，下一次获取
# 按持有者 PID 与进程启动时刻判定为过期并回收。不依赖 EXIT trap，
# 脚本内部替换 trap 不影响锁的释放。
#
# 锁路径可由 LNMP_LOCK_FILE 覆盖，仅用于测试。

LNMP_Lock_Script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

# Lock_Proc_Start <pid>：输出进程启动时刻（/proc/<pid>/stat 第 22 字段）。
Lock_Proc_Start()
{
    local stat
    local -a f

    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
    # comm 字段可含空格与括号，从最后一个 ") " 之后切分，起始字段为第 3 个。
    stat=${stat##*) }
    read -ra f <<< "${stat}"
    printf '%s' "${f[19]:-}"
}

# Lock_Field <持有者信息> <键>：取 key=value 字段。
Lock_Field()
{
    local s=";$1"

    case "${s}" in *";$2="*) ;; *) return 0 ;; esac
    s=${s#*";$2="}
    printf '%s' "${s%%;*}"
}

# Lock_Info_Alive <持有者信息>：持有进程仍在运行时返回 0。
Lock_Info_Alive()
{
    local pid start now stat

    pid=$(Lock_Field "$1" pid)
    start=$(Lock_Field "$1" start)
    case "${pid}" in ''|*[!0-9]*) return 1 ;; esac

    if ! kill -0 "${pid}" 2>/dev/null && [ ! -d "/proc/${pid}" ]; then
        return 1
    fi
    stat=$(cat "/proc/${pid}/stat" 2>/dev/null) || true
    stat=${stat##*) }
    [ "${stat%% *}" = "Z" ] && return 1

    now=$(Lock_Proc_Start "${pid}")
    [ -z "${start}" ] || [ -z "${now}" ] || [ "${start}" = "${now}" ]
}

# Lock_Recover <锁路径> <已判定过期的持有者信息>
# 在回收互斥内重新确认锁内容未变且持有者已退出，再移除。
Lock_Recover()
{
    local lock=$1 old=$2

    (
        if command -v flock >/dev/null 2>&1; then
            flock -x 9 || exit 1
        fi
        cur=$(readlink -- "${lock}" 2>/dev/null) || exit 0
        [ "${cur}" = "${old}" ] || exit 0
        Lock_Info_Alive "${cur}" && exit 0
        rm -f -- "${lock}"
    ) 9>>"${lock}.recover"
}

# Lock_Watch <锁路径> <pid> <启动时刻>：持有进程退出后移除属于它的锁。
Lock_Watch()
{
    local lock=$1 pid=$2 start=$3 info

    while kill -0 "${pid}" 2>/dev/null; do
        [ -z "${start}" ] || [ "$(Lock_Proc_Start "${pid}")" = "${start}" ] || break
        sleep 1
    done
    info=$(readlink -- "${lock}" 2>/dev/null) || return 0
    [ "$(Lock_Field "${info}" pid)" = "${pid}" ] && rm -f -- "${lock}"
    return 0
}

# Lock_Acquire <任务标签>
# 返回 0 已持有（含持锁进程派生的子进程）；2 被其它任务占用或锁状态未知，
# 此时系统尚未被改动。
Lock_Acquire()
{
    local label=${1:-lnmp} lock=${LNMP_LOCK_FILE:-/var/lock/lnmp-ops.lock}
    local info old start i

    if [ -n "${LNMP_LOCK_HOLDER:-}" ] \
       && info=$(readlink -- "${lock}" 2>/dev/null) \
       && [ "$(Lock_Field "${info}" pid)" = "${LNMP_LOCK_HOLDER}" ] \
       && Lock_Info_Alive "${info}"; then
        return 0
    fi

    if ! mkdir -p -- "$(dirname -- "${lock}")" 2>/dev/null; then
        printf '错误：无法创建锁目录 %s。\n' "$(dirname -- "${lock}")" >&2
        return 2
    fi

    label=${label//[$'\n\r;']/ }
    start=$(Lock_Proc_Start "$$")
    info="pid=$$;start=${start};host=${HOSTNAME:-$(hostname 2>/dev/null)};time=$(date '+%F %T');cmd=${label}"

    for i in 1 2 3; do
        # 目录等非符号链接：ln 会在其内部创建链接，必须先拒绝。
        if [ -e "${lock}" ] && [ ! -L "${lock}" ]; then
            printf '错误：%s 存在但不是由本工具创建的锁，拒绝处理。\n' "${lock}" >&2
            printf '确认没有安装、升级、卸载任务在运行后，手工删除该路径再重试。\n' >&2
            return 2
        fi
        if ln -sn -- "${info}" "${lock}" 2>/dev/null; then
            LNMP_LOCK_HOLDER=$$
            export LNMP_LOCK_HOLDER
            Lock_Spawn_Watcher "${lock}" "$$" "${start}"
            return 0
        fi
        [ -L "${lock}" ] || continue

        old=$(readlink -- "${lock}" 2>/dev/null) || continue
        if Lock_Info_Alive "${old}"; then
            printf '错误：已有 LNMP 维护任务在运行（PID %s，命令：%s，开始于 %s）。\n' \
                "$(Lock_Field "${old}" pid)" "$(Lock_Field "${old}" cmd)" \
                "$(Lock_Field "${old}" time)" >&2
            printf '请等待其结束后再执行；多个任务不能同时修改安装目录。\n' >&2
            return 2
        fi
        printf '提示：回收残留的维护锁（原持有者 PID %s 已退出）。\n' \
            "$(Lock_Field "${old}" pid)" >&2
        Lock_Recover "${lock}" "${old}"
    done

    printf '错误：无法获取维护锁 %s，请检查 /var/lock 是否可写。\n' "${lock}" >&2
    return 2
}

# 监视进程脱离会话与作业表，避免被入口脚本的 wait 或终端信号牵连。
Lock_Spawn_Watcher()
{
    [ -r "${LNMP_Lock_Script}" ] || return 0
    if command -v setsid >/dev/null 2>&1; then
        setsid bash "${LNMP_Lock_Script}" --watch "$1" "$2" "$3" </dev/null >/dev/null 2>&1 &
    else
        bash "${LNMP_Lock_Script}" --watch "$1" "$2" "$3" </dev/null >/dev/null 2>&1 &
    fi
    disown "$!" 2>/dev/null
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = "--watch" ]; then
    Lock_Watch "$2" "$3" "$4"
    exit 0
fi
