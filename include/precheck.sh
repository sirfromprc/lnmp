#!/usr/bin/env bash

# 完整安装在改动系统前的集中预检。
#
# 磁盘、内存、端口和本次要下载的地址一次全部检查，避免串行安装时
# 每轮只暴露一个失败点、修完再跑又要把前面的组件重新编译一遍。
# 阻断项直接返回非零；仅有风险项时列出并由用户决定是否继续。

# 源码编译数据库的磁盘下限定义在 include/main.sh，与 Check_DB_Source_Build 共用。

# PHP、Web 服务器及下载包的编译磁盘下限。
Build_Min_Disk_MB=5120
# /usr/local 下安装产物的磁盘下限。
Install_Min_Disk_MB=2048
# 数据库首次初始化写入数据目录的磁盘下限。
DB_Data_Min_Disk_MB=2048
# 编译所需的内存与 swap 合计下限。
Build_Min_Mem_MB=1024
# 内存信息来源，测试可覆盖。
Precheck_Meminfo="${Precheck_Meminfo:-/proc/meminfo}"
# 单个下载地址的探测超时秒数。
Precheck_Net_Timeout=10

Precheck_Fatal=()
Precheck_Warn=()

# 收集项按 printf 格式串传入，中文只留在调用点的格式串里。
Precheck_Add_Fatal()
{
    local msg
    printf -v msg "$@"
    Precheck_Fatal+=("${msg}")
}

Precheck_Add_Warn()
{
    local msg
    printf -v msg "$@"
    Precheck_Warn+=("${msg}")
}

# 上溯到最近的已存在目录，供 df 查询。
Precheck_Real_Dir()
{
    local path="$1"
    [ -n "${path}" ] || path='/'
    while [ ! -d "${path}" ]; do
        case "${path}" in
            /|.|..|'') path='/'; break ;;
        esac
        path=$(dirname "${path}")
    done
    printf '%s' "${path}"
}

# 输出路径所在分区的可用空间（MB）；取不到时输出 0。
Precheck_Avail_MB()
{
    local avail
    avail=$(df -Pm "$(Precheck_Real_Dir "$1")" 2>/dev/null | awk 'NR==2 {print $4}')
    case "${avail}" in ''|*[!0-9]*) avail=0 ;; esac
    printf '%s' "${avail}"
}

# 输出路径所在分区的挂载点，供同分区的需求合并计算。
Precheck_Mount_Point()
{
    local mp
    mp=$(df -P "$(Precheck_Real_Dir "$1")" 2>/dev/null | awk 'NR==2 {print $6}')
    printf '%s' "${mp:-/}"
}

# 同一分区上的多项需求相加后再判定，避免重复告警并低估总占用。
Precheck_Disk()
{
    local -a dirs=() reqs=()
    local -A need_of label_of
    local i mp avail need

    if [ "${DB_Kind}" != "none" ] && [ "${Bin}" != "y" ]; then
        dirs+=("${cur_dir}"); reqs+=("${DB_Source_Build_Min_Disk_MB}")
    else
        dirs+=("${cur_dir}"); reqs+=("${Build_Min_Disk_MB}")
    fi
    dirs+=("/usr/local"); reqs+=("${Install_Min_Disk_MB}")
    if [ "${DB_Kind}" != "none" ] && [ -n "${DB_Data_Dir}" ]; then
        dirs+=("${DB_Data_Dir}"); reqs+=("${DB_Data_Min_Disk_MB}")
    fi

    for i in "${!dirs[@]}"; do
        mp=$(Precheck_Mount_Point "${dirs[$i]}")
        need_of["${mp}"]=$(( ${need_of["${mp}"]:-0} + reqs[i] ))
        if [ -n "${label_of[${mp}]:-}" ]; then
            label_of["${mp}"]="${label_of[${mp}]} ${dirs[$i]}"
        else
            label_of["${mp}"]="${dirs[$i]}"
        fi
    done

    for mp in "${!need_of[@]}"; do
        avail=$(Precheck_Avail_MB "${mp}")
        need=${need_of[${mp}]}
        if [ "${avail}" -lt "${need}" ]; then
            Precheck_Add_Fatal '分区 %s（%s）剩余 %sMB，本次安装至少需要 %sMB。' \
                "${mp}" "${label_of[${mp}]}" "${avail}" "${need}"
        elif [ "${avail}" -lt $(( need * 3 / 2 )) ]; then
            Precheck_Add_Warn '分区 %s（%s）剩余 %sMB，仅略高于所需的 %sMB，编译或数据库初始化中途可能写满。' \
                "${mp}" "${label_of[${mp}]}" "${avail}" "${need}"
        fi
    done
}

# 数据库源码编译的内存要求由 Check_DB_Source_Build 单独判定，此处只看
# 编译 PHP 和 Web 服务器所需的最低内存。
Precheck_Memory()
{
    local mem_mb swap_mb total
    mem_mb=$(awk '/^MemTotal/ {printf "%d", $2 / 1024; exit}' "${Precheck_Meminfo}" 2>/dev/null)
    swap_mb=$(awk '/^SwapTotal/ {printf "%d", $2 / 1024; exit}' "${Precheck_Meminfo}" 2>/dev/null)
    case "${mem_mb}" in ''|*[!0-9]*) mem_mb=0 ;; esac
    case "${swap_mb}" in ''|*[!0-9]*) swap_mb=0 ;; esac

    total=$((mem_mb + swap_mb))
    [ "${total}" -ge "${Build_Min_Mem_MB}" ] && return 0

    if [ "${Enable_Swap}" = "y" ]; then
        Precheck_Add_Warn '内存 %sMB 加 swap %sMB 低于编译所需的 %sMB，安装会先尝试添加 swap，编译阶段仍可能被 OOM 终止。' \
            "${mem_mb}" "${swap_mb}" "${Build_Min_Mem_MB}"
    else
        Precheck_Add_Warn '内存 %sMB 加 swap %sMB 低于编译所需的 %sMB，且 Enable_Swap=n，编译阶段可能被 OOM 终止。' \
            "${mem_mb}" "${swap_mb}" "${Build_Min_Mem_MB}"
    fi
}

# 输出监听指定端口的进程说明；未监听或无 ss 时返回非零。
Precheck_Port_Owner()
{
    local port="$1" line proc
    command -v ss >/dev/null 2>&1 || return 1
    line=$(ss -Htlnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print; exit}')
    [ -n "${line}" ] || return 1
    proc=$(printf '%s' "${line}" \
           | grep -oE '"[^"]+",pid=[0-9]+' | head -n1 | tr -d '"' | sed 's/,pid=/ pid /')
    printf '%s' "${proc}"
    return 0
}

# 端口被占用不阻断安装：系统自带的 apache2/nginx/mysql 包会在依赖处理阶段
# 被移除，其余占用则需要用户自行决定。
Precheck_Ports()
{
    local -a ports=()
    local port owner

    ports+=(80 443)
    [ "${Stack}" = "lnmpa" ] && ports+=(88)
    if [ "${DB_Kind}" != "none" ]; then
        ports+=("${DB_Port}")
        [ "${DB_Kind}" = "mysql" ] && ports+=("${DB_X_Port}")
    fi

    for port in "${ports[@]}"; do
        if owner=$(Precheck_Port_Owner "${port}"); then
            if [ -n "${owner}" ]; then
                Precheck_Add_Warn '端口 %s 已被 %s 监听，若它不是系统自带的 apache2/nginx/mysql 包，安装后的服务会因端口冲突起不来。' \
                    "${port}" "${owner}"
            else
                Precheck_Add_Warn '端口 %s 已被其它进程监听，若它不是系统自带的 apache2/nginx/mysql 包，安装后的服务会因端口冲突起不来。' "${port}"
            fi
        fi
    done
}

# 收集本次安装真正要下载的地址并逐个探测（Download_Head_OK 在 HEAD 被拒时回退 Range GET）。
# 地址列表复用 Check_Download 与 DB_Download_Files，避免在预检里另存一份 URL；
# 同一文件登记主备地址，任一可用即算可下载。
Precheck_Download_Urls()
{
    local probe reached reported name url

    [ "${CheckMirror}" = "n" ] && return 0
    probe=$(mktemp) || return 0
    reached=$(mktemp) || { rm -f "${probe}"; return 0; }
    reported=$(mktemp) || { rm -f "${probe}" "${reached}"; return 0; }

    # 子 shell 隔离探测开关和 Check_Download 的目录切换。
    (
        Download_Probe_Only='y'
        Download_Probe_File="${probe}"
        Check_Download
    ) >/dev/null 2>&1

    # 并行探测，避免逐个等待超时。
    while IFS=$'\t' read -r name url; do
        [ -n "${url}" ] || continue
        ( Download_Head_OK "${url}" "${Precheck_Net_Timeout}" \
          && printf '%s\n' "${name}" >> "${reached}" ) &
    done < "${probe}"
    wait

    while IFS=$'\t' read -r name url; do
        [ -n "${url}" ] || continue
        grep -qxF "${name}" "${reached}" 2>/dev/null && continue
        grep -qxF "${name}" "${reported}" 2>/dev/null && continue
        printf '%s\n' "${name}" >> "${reported}"
        Precheck_Add_Warn '%s 的下载地址取不到：%s' "${name}" "${url}"
    done < "${probe}"

    rm -f "${probe}" "${reached}" "${reported}"
    return 0
}

# 集中预检入口。无风险直接继续；只有风险项时交互确认，非交互执行按继续处理。
# 预检结束安装时返回 2，与安装过程中的失败区分：此时尚未做任何系统变更。
Precheck_Install()
{
    local item ans

    case "${Stack}" in
        lnmp|lnmpa|lamp) ;;
        *) return 0 ;;
    esac

    Precheck_Fatal=()
    Precheck_Warn=()

    Echo_Blue "[+] 正在检查磁盘、内存、端口和下载地址..."
    Precheck_Disk
    Precheck_Memory
    Precheck_Ports
    Precheck_Download_Urls

    if [ "${#Precheck_Fatal[@]}" -gt 0 ]; then
        Echo_Red "预检未通过，以下问题会导致安装失败，请处理后重新执行："
        for item in "${Precheck_Fatal[@]}"; do
            Echo_Red "  - ${item}"
        done
        if [ "${#Precheck_Warn[@]}" -gt 0 ]; then
            Echo_Yellow "另有以下风险项："
            for item in "${Precheck_Warn[@]}"; do
                Echo_Yellow "  - ${item}"
            done
        fi
        return 2
    fi

    # 无风险时不输出结论，直接进入安装。
    [ "${#Precheck_Warn[@]}" -eq 0 ] && return 0

    Echo_Yellow "=========================================================================="
    Echo_Yellow "预检发现以下风险，安装可能在编译或启动阶段失败："
    for item in "${Precheck_Warn[@]}"; do
        Echo_Yellow "  - ${item}"
    done
    Echo_Yellow "=========================================================================="

    if [ ! -t 0 ] || [ "${LNMP_Auto}" = "y" ]; then
        Echo_Yellow "当前为非交互执行，带上述风险继续安装。"
        return 0
    fi

    read -r -p "继续安装请输入 y，输入其它任意键退出并先处理上述风险： " ans
    case "${ans}" in
        [yY]) return 0 ;;
        *) Echo_Red "已退出。处理上述风险后重新执行本命令即可。"; return 2 ;;
    esac
}
