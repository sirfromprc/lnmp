#!/usr/bin/env bash
#
# LNMP 权限基线核对工具，通过 `lnmp perm <子命令>` 使用。
# 安装路径为 /bin/lnmp-perm，lnmp、lnmpa 和 lamp 管理命令共用该工具。
#
#   lnmp perm check [服务名]   核对权限基线，不带参数核对全部
#   lnmp perm status           显示钩子安装状态与上次核对结果
#   lnmp perm run              定时核对入口，仅在结果变化时推送通知
#   lnmp perm init             注入校验钩子并安装定期核对任务
#   lnmp perm uninit           剥离校验钩子并移除定期核对任务
#   lnmp perm ignore <ID>      忽略指定条目（用于有意做出的权限调整）
#   lnmp perm unignore <ID>    取消忽略
#
# ---------------------------------------------------------------------------
# 核对规则
#
# 基线写在本文件的 Baseline 数组中，不落盘生成数据文件：扫描现状得到的是
# 实际值而非期望值，属主已被改坏时会把错误状态固化成基线。
#
# 条目分 hard 与 soft 两级。hard 表示不修必然导致服务启动失败，仅用于以运行
# 账号实测可写性的检查；soft 表示属主或权限偏离安装值，只报告不阻止启动。
#
# 检查不修改任何文件，只输出当前值、期望值和可直接执行的修复命令。
# ---------------------------------------------------------------------------

set -u

Conf_Dir="/etc/lnmp"
State_File="${Conf_Dir}/perm-state"
Log_File="/var/log/lnmp/perm.log"
Diagnose_Unit="/etc/systemd/system/lnmp-perm-diagnose@.service"
Ignore_File="${Conf_Dir}/perm-ignore"
Systemd_Service="/etc/systemd/system/lnmp-perm.service"
Systemd_Timer="/etc/systemd/system/lnmp-perm.timer"
Cron_File="/etc/cron.d/lnmp-perm"
Notify_Quiet_Sec=86400
Systemd_Dir="/etc/systemd/system"
Hook_Bin="/bin/lnmp-perm"
Hook_Mark="# LNMP perm hooks"
Recurse_Report_Max=20
Diag_Quiet_Sec=600

# 状态文件记录上次核对结果，仅 root 可读。
umask 077

# 测试注入点：默认取实际系统路径。
My_Cnf="${LNMP_PERM_MYCNF:-/etc/my.cnf}"
Default_Site="${LNMP_PERM_DEFAULT_SITE:-/home/wwwroot/default}"

# ---------------------------------------------------------------------------
# 输出与日志
# ---------------------------------------------------------------------------
Color()   { if [ -t 1 ]; then printf '\033[%sm%s\033[0m\n' "$1" "$2"; else printf '%s\n' "$2"; fi; }
Say()     { printf '%s\n' "$*"; }
Warn()    { Color "0;33" "$*"; }
Err()     { Color "0;31" "$*" >&2; }
Ok()      { Color "0;32" "$*"; }

Log()
{
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] $*"
    [ -d "${Log_File%/*}" ] || mkdir -p "${Log_File%/*}" 2>/dev/null
    printf '%s\n' "${line}" >> "${Log_File}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 权限基线
#
# 字段：ID|SVC|KIND|PATH|OWNER|GROUP|MODE|SEV|OPT
#   SVC   归属服务，逗号分隔。cmd 与 sec 不参与启停钩子。
#   KIND  stat 属主与 mode 比对；stat_r 递归比对属主；write 以账号实测可写；
#         maxmode 禁止置位的权限掩码；immutable 校验 chattr +i；
#         marker 校验 init 脚本已注入运行目录重建逻辑。
#   PATH  绝对路径，或 @ 前缀的运行期令牌。
#   OWNER/GROUP/MODE  期望值，- 表示不校验。
#   SEV   hard 阻止启动；soft 仅告警。
#   OPT   opt 不存在即跳过；req 不存在即失败；parentok 不存在时改探父目录；
#         ex=<名> stat_r 的排除项。
# ---------------------------------------------------------------------------
Baseline=(
"DB01|mysql,mariadb|write|@DB_DATADIR|@DB_USER|-|-|hard|req"
"DB02|mysql,mariadb|write|@DB_LOGERROR|@DB_USER|-|-|hard|parentok"
"DB03|mysql,mariadb|maxmode|@MY_CNF|-|-|022|soft|opt"
"DB04|mysql|stat_r|/usr/local/mysql|mysql|mysql|-|soft|opt"
"DB05|mariadb|stat_r|/usr/local/mariadb|mariadb|mariadb|-|soft|opt,ex=auth_pam_tool"
"DB06|mysql|stat|/etc/init.d/mysql|root|root|755|soft|opt"
"DB07|mariadb|stat|/etc/init.d/mariadb|root|root|755|soft|opt"
"DB08|mysql|marker|/etc/init.d/mysql|-|-|-|soft|opt"
"DB09|mariadb|marker|/etc/init.d/mariadb|-|-|-|soft|opt"
"NGX01|nginx,httpd|stat|/home/wwwlogs|root|root|755|soft|opt"
"NGX02|nginx,httpd,php-fpm|stat|@DEFAULT_SITE|www|www|755|soft|opt"
"NGX03|nginx|stat|@DEFAULT_SITE/.user.ini|-|-|644|soft|opt"
"NGX04|nginx|immutable|@DEFAULT_SITE/.user.ini|-|-|-|soft|opt"
"RDS01|redis|write|/usr/local/redis/var|redis|-|-|hard|opt"
"RDS02|redis|stat|/usr/local/redis/var|redis|redis|750|soft|opt"
"RDS03|redis|stat|/usr/local/redis/etc/redis.conf|root|redis|640|soft|opt"
"FTP01|pureftpd|stat|/usr/local/pureftpd/etc/pure-ftpd.pem|-|-|600|soft|opt"
"FTP02|pureftpd|maxmode|/usr/local/pureftpd/etc/pureftpd.passwd|-|-|077|soft|opt"
"PMA01|nginx,httpd|stat_r|/usr/local/phpmyadmin|root|www|-|soft|opt,ex=.access_url"
"PMA02|nginx,httpd|stat|/usr/local/phpmyadmin/.access_url|-|-|600|soft|opt"
"PMA03|nginx,httpd|stat|/var/lib/phpmyadmin/tmp|www|www|700|soft|opt"
"PMA04|nginx,httpd|stat|/usr/local/phpmyadmin/config.inc.php|root|www|640|soft|opt"
"PMA05|nginx,httpd|maxmode|/usr/local/phpmyadmin|-|-|027|soft|opt"
"CMD01|cmd|stat|/bin/lnmp|root|root|755|soft|req"
"CMD02|cmd|stat|/bin/lnmp-backup|root|root|755|soft|opt"
"CMD03|cmd|stat|/bin/lnmp-tgnotice|root|root|755|soft|opt"
"CMD04|cmd|stat|/bin/lnmp-perm|root|root|755|soft|opt"
"CMD05|cmd|stat|/etc/profile.d/lnmp-tgnotice.sh|root|root|644|soft|opt"
"CMD06|cmd|stat|/bin/lnmp-health|root|root|755|soft|opt"
"SEC01|sec|stat|/etc/lnmp|root|root|700|soft|opt"
"SEC02|sec|stat|/etc/lnmp/backup-mysql.cnf|-|-|600|soft|opt"
"SEC03|sec|stat|/etc/lnmp/backup.conf|-|-|600|soft|opt"
"SEC04|sec|stat|/etc/lnmp/notify.conf|-|-|600|soft|opt"
"SEC05|sec|stat|/root/.ssh/lnmp_backup|-|-|600|soft|opt"
"SEC06|sec|stat|/root/.config/lnmp/backup-age.key|-|-|600|soft|opt"
"SEC07|sec|stat|/root/.lnmp_db_root_password|-|-|600|soft|opt"
"SEC08|sec|stat|/etc/nftables.d/lnmp.nft|-|-|600|soft|opt"
"SEC09|sec|stat|/etc/systemd/system/lnmp-nftables.service|root|root|644|soft|opt"
"SEC10|sec|stat|/etc/lnmp/health-state|-|-|600|soft|opt"
)

# 参与启停钩子的服务名。cmd 与 sec 只在手动核对中出现；
# memcached 无基线条目，不挂钩子。
Hook_Services="mysql mariadb nginx httpd php-fpm redis pureftpd"

# ---------------------------------------------------------------------------
# 配置读取
# ---------------------------------------------------------------------------
# 输出 my.cnf 中 [mysqld] 段指定键的值，未配置时输出空。
# 与 conf/lnmp 的 Get_Mysqld_Conf_Value 保持同一解析行为；本工具不依赖源码
# 目录，也不加载管理脚本，因此保留独立实现。
Get_Mysqld_Conf_Value()
{
    local key="$1" conf="${2:-${My_Cnf}}"

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

# 按 / 拆解并消除 . 与 ..，只做文本规范化，不访问文件系统。
Normalize_Fs_Path()
{
    local path="$1" part out=""
    local IFS=/

    for part in ${path}; do
        case "${part}" in
        ''|.) ;;
        ..)   out="${out%/*}" ;;
        *)    out="${out}/${part}" ;;
        esac
    done
    printf '%s' "${out:-/}"
}

# mysqld 把相对 log_error 解释为相对 datadir。未配置 log_error 时输出空并返回 0；
# 缺少 datadir 或解析后越出 datadir 时返回 1，由调用方按无法定位处理，绝不退回
# 当前工作目录。
Db_Log_Error_Path()
{
    local logerror datadir base resolved

    logerror=$(Get_Mysqld_Conf_Value log_error)
    [ -n "${logerror}" ] || return 0
    case "${logerror}" in
    /*) Normalize_Fs_Path "${logerror}"; return 0 ;;
    esac
    datadir=$(Get_Mysqld_Conf_Value datadir)
    [ -n "${datadir}" ] || return 1
    base=$(Normalize_Fs_Path "${datadir}")
    resolved=$(Normalize_Fs_Path "${base}/${logerror}")
    case "${resolved}" in
    "${base}"/*) printf '%s' "${resolved}"; return 0 ;;
    esac
    return 1
}

# 把基线中的 @ 令牌展开成实际路径或账号。未配置时输出空并返回 0；
# 配置了但无法定位实际路径时返回 1，调用方据此区分“没有该项”与“定位不到”。
Expand_Token()
{
    local raw="$1" base suffix value

    case "${raw}" in
    @MY_CNF)      printf '%s' "${My_Cnf}"; return 0 ;;
    @DB_USER)     Get_Mysqld_Conf_Value user; return 0 ;;
    @DB_DATADIR)  Get_Mysqld_Conf_Value datadir; return 0 ;;
    @DB_LOGERROR) Db_Log_Error_Path; return $? ;;
    @DEFAULT_SITE)        printf '%s' "${Default_Site}"; return 0 ;;
    @DEFAULT_SITE/*)
        suffix="${raw#@DEFAULT_SITE}"
        printf '%s' "${Default_Site}${suffix}"
        return 0
        ;;
    @*)
        base="${raw%%/*}"
        suffix="${raw#"${base}"}"
        value=$(Expand_Token "${base}") || return 1
        [ -n "${value}" ] || return 0
        printf '%s' "${value}${suffix}"
        return 0
        ;;
    *) printf '%s' "${raw}"; return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# 基线筛选
# ---------------------------------------------------------------------------
# 判断逗号分隔的服务列表是否包含指定服务。
Svc_Match()
{
    local list="$1" want="$2" item
    [ "${want}" = "all" ] && return 0
    local IFS=','
    for item in ${list}; do
        [ "${item}" = "${want}" ] && return 0
    done
    return 1
}

# Perm_Entries_For <服务名|all> <fast|full>
# fast 供启停钩子使用：排除递归扫描与 cmd/sec 条目，只保留 O(1) 检查。
Perm_Entries_For()
{
    local want="$1" profile="$2" entry id svc kind

    for entry in "${Baseline[@]}"; do
        IFS='|' read -r id svc kind _ <<EOF
${entry}
EOF
        Svc_Match "${svc}" "${want}" || continue
        if [ "${profile}" = "fast" ]; then
            [ "${kind}" = "stat_r" ] && continue
            case "${svc}" in
            cmd|sec) continue ;;
            esac
        fi
        printf '%s\n' "${entry}"
    done
}

# OPT 字段是否含指定标记。
Opt_Has()
{
    local opt="$1" want="$2" item
    local IFS=','
    for item in ${opt}; do
        [ "${item}" = "${want}" ] && return 0
    done
    return 1
}

# 取 OPT 中所有 ex= 排除项，每行一个。
Opt_Excludes()
{
    local opt="$1" item
    local IFS=','
    for item in ${opt}; do
        case "${item}" in
        ex=*) printf '%s\n' "${item#ex=}" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 忽略清单
# ---------------------------------------------------------------------------
# 用户有意做出的权限调整可按条目 ID 静音，避免把基线整体降级。
Is_Ignored()
{
    local id="$1"
    [ -s "${Ignore_File}" ] || return 1
    grep -qx "[[:space:]]*${id}[[:space:]]*" "${Ignore_File}" 2>/dev/null && return 0
    awk -v id="${id}" '
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
        $0 == id { found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "${Ignore_File}"
}

# 条目 ID 必须存在于基线中，避免写入拼错的名字后静音失效。
Baseline_Has_Id()
{
    local id="$1" entry
    for entry in "${Baseline[@]}"; do
        [ "${entry%%|*}" = "${id}" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# 检查原语
# ---------------------------------------------------------------------------
Stat_Mode()  { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
Stat_Owner() { stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1" 2>/dev/null; }
Stat_Group() { stat -c '%G' "$1" 2>/dev/null || stat -f '%Sg' "$1" 2>/dev/null; }

# 以指定账号实测路径可写。无法降权时返回 2，由调用方降级处理。
Writable_By()
{
    local acct="$1" path="$2" owner mode

    # 属主即运行账号且属主位可写时直接通过：这是正常状态，跳过降权探测可避免
    # 每次服务启动都在 journal 中留下 PAM 会话记录。
    owner=$(Stat_Owner "${path}")
    mode=$(Stat_Mode "${path}")
    if [ "${owner}" = "${acct}" ]; then
        case "${mode}" in
        [2367]??) return 0 ;;
        esac
    fi

    # 属主不符时仍需实测：附加组或 ACL 可能让进程照样可写。
    [ "$(id -u)" = "0" ] || return 2
    command -v runuser >/dev/null 2>&1 || return 2
    id "${acct}" >/dev/null 2>&1 || return 2
    runuser -u "${acct}" -- test -w "${path}" 2>/dev/null && return 0
    return 1
}

# 属主与 mode 字面比对。凭据类条目允许比期望更严的 400。
Check_Stat()
{
    local path="$1" want_owner="$2" want_group="$3" want_mode="$4"
    local owner group mode

    owner=$(Stat_Owner "${path}")
    group=$(Stat_Group "${path}")
    mode=$(Stat_Mode "${path}")

    if [ "${want_owner}" != "-" ] && [ "${owner}" != "${want_owner}" ]; then
        printf -v Detail '属主是 %s，期望 %s' "${owner}" "${want_owner}"
        Fix="chown ${want_owner}:${want_group} ${path}"
        [ "${want_group}" = "-" ] && Fix="chown ${want_owner} ${path}"
        return 1
    fi
    if [ "${want_group}" != "-" ] && [ "${group}" != "${want_group}" ]; then
        printf -v Detail '属组是 %s，期望 %s' "${group}" "${want_group}"
        Fix="chgrp ${want_group} ${path}"
        return 1
    fi
    if [ "${want_mode}" != "-" ] && [ "${mode}" != "${want_mode}" ]; then
        if [ "${want_mode}" = "600" ] && [ "${mode}" = "400" ]; then
            return 0
        fi
        printf -v Detail '权限是 %s，期望 %s' "${mode}" "${want_mode}"
        Fix="chmod ${want_mode} ${path}"
        return 1
    fi
    return 0
}

# 递归比对属主，命中数量超过上限时截断输出。
Check_Stat_R()
{
    local path="$1" want_owner="$2" want_group="$3" excludes="$4"
    local -a find_args
    local hits count line ex spec fix_list

    find_args=("${path}")
    while IFS= read -r ex; do
        [ -n "${ex}" ] || continue
        find_args+=(-name "${ex}" -prune -o)
    done <<EOF
${excludes}
EOF

    find_args+=(\()
    [ "${want_owner}" != "-" ] && find_args+=(-not -user "${want_owner}" -o)
    [ "${want_group}" != "-" ] && find_args+=(-not -group "${want_group}" -o)
    find_args+=(-false \) -print)

    hits=$(find "${find_args[@]}" 2>/dev/null | head -n $((Recurse_Report_Max + 1)))
    [ -n "${hits}" ] || return 0

    count=$(printf '%s\n' "${hits}" | wc -l)
    printf -v Detail '属主不是 %s:%s 的路径：' "${want_owner}" "${want_group}"
    local -a fix_paths=()
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        printf -v Detail '%s\n    %s' "${Detail}" "${line}"
        fix_paths+=("${line}")
    done <<EOF
$(printf '%s\n' "${hits}" | head -n ${Recurse_Report_Max})
EOF
    if [ "${count}" -gt "${Recurse_Report_Max}" ]; then
        printf -v Detail '%s\n    （另有未列出的路径）' "${Detail}"
    fi
    # 修复命令只处理实际命中的路径：递归 chown 整个安装目录会覆盖
    # auth_pam_tool 这类专用属主和 SUID 文件。
    spec="${want_owner}:${want_group}"
    [ "${want_owner}" = "-" ] && spec=":${want_group}"
    [ "${want_group}" = "-" ] && spec="${want_owner}"
    fix_list=$(printf '%q ' "${fix_paths[@]}")
    Fix="chown ${spec} ${fix_list% }"
    if [ "${count}" -gt "${Recurse_Report_Max}" ]; then
        Fix="${Fix} # 其余未列出路径按同样方式处理"
    fi
    return 1
}

# 禁止置位的权限掩码，用于只关心是否过宽的条目。
Check_Maxmode()
{
    local path="$1" mask="$2" mode extra

    mode=$(Stat_Mode "${path}")
    [ -n "${mode}" ] || {
        printf -v Detail '无法读取权限'
        Fix=""
        return 1
    }
    extra=$(( 8#${mode} & 8#${mask} ))
    [ "${extra}" -eq 0 ] && return 0

    printf -v Detail '权限是 %s，不应包含 %s 中的位' "${mode}" "${mask}"
    Fix="chmod o-rwx,g-w ${path}"
    [ "${mask}" = "077" ] && Fix="chmod 600 ${path}"
    return 1
}

Check_Immutable()
{
    local path="$1"

    command -v lsattr >/dev/null 2>&1 || return 0
    lsattr -d "${path}" 2>/dev/null | awk '{print $1}' | grep -q 'i' && return 0
    printf -v Detail '缺少 immutable 属性'
    Fix="chattr +i ${path}"
    return 1
}

# init 脚本是否已注入运行目录重建逻辑。
Check_Marker()
{
    local path="$1"

    grep -q '^# LNMP runtime directory$' "${path}" 2>/dev/null && return 0
    printf -v Detail '缺少运行目录重建逻辑，重启后 /run 下的目录不会被重建'
    Fix=""
    return 1
}

# ---------------------------------------------------------------------------
# 核对主循环
# ---------------------------------------------------------------------------
# Perm_Run <服务名|all> <fast|full>
# 返回 0 全部通过；1 存在软告警；2 存在硬条件失败。
# 结果计入 Pass_Count / Soft_Count / Hard_Count，失败条目 ID 记入 Failed_Ids。
Perm_Run()
{
    local want="$1" profile="$2"
    local entry id svc kind raw owner group mode sev opt
    local path acct rc degraded

    Pass_Count=0
    Soft_Count=0
    Hard_Count=0
    Ignored_Count=0
    Failed_Ids=""

    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        IFS='|' read -r id svc kind raw owner group mode sev opt <<EOF
${entry}
EOF
        Detail=""
        Fix=""
        degraded=""

        if Is_Ignored "${id}"; then
            Ignored_Count=$((Ignored_Count + 1))
            continue
        fi

        path=$(Expand_Token "${raw}")
        if [ $? -ne 0 ]; then
            # 配置里有该项但定位不到实际路径：降级为告警，不按硬条件阻止启动。
            printf -v Detail '无法定位 %s 指向的路径，请检查 %s 中的相关配置' \
                "${raw}" "${My_Cnf}"
            Fix=""
            Perm_Report "${id}" soft "${raw}" 1
            continue
        fi
        if [ -z "${path}" ]; then
            continue
        fi

        if [ ! -e "${path}" ]; then
            if Opt_Has "${opt}" "parentok"; then
                path="${path%/*}"
                [ -n "${path}" ] && [ -e "${path}" ] || continue
            elif Opt_Has "${opt}" "req"; then
                printf -v Detail '路径不存在'
                Fix=""
                Perm_Report "${id}" "${sev}" "${path}" 1
                continue
            else
                continue
            fi
        fi

        rc=0
        case "${kind}" in
        stat)
            Check_Stat "${path}" "${owner}" "${group}" "${mode}" || rc=1
            ;;
        stat_r)
            Check_Stat_R "${path}" "${owner}" "${group}" "$(Opt_Excludes "${opt}")" || rc=1
            ;;
        write)
            acct=$(Expand_Token "${owner}")
            if [ -z "${acct}" ]; then
                continue
            fi
            Writable_By "${acct}" "${path}"
            case $? in
            0) rc=0 ;;
            1)
                rc=1
                printf -v Detail '对运行账号 %s 不可写' "${acct}"
                if [ -d "${path}" ]; then
                    Fix="chown -R ${acct}:${acct} ${path}"
                else
                    Fix="chown ${acct}:${acct} ${path}"
                fi
                ;;
            *)
                # 无法降权探测时不做硬判定，避免阻止本可正常启动的服务。
                degraded=y
                if ! Check_Stat "${path}" "${acct}" "-" "-"; then
                    rc=1
                    printf -v Detail '%s（未做可写性探测）' "${Detail}"
                fi
                ;;
            esac
            ;;
        maxmode)
            Check_Maxmode "${path}" "${mode}" || rc=1
            ;;
        immutable)
            Check_Immutable "${path}" || rc=1
            ;;
        marker)
            Check_Marker "${path}" || rc=1
            ;;
        *)
            continue
            ;;
        esac

        [ -n "${degraded}" ] && sev=soft
        Perm_Report "${id}" "${sev}" "${path}" "${rc}"
    done <<EOF
$(Perm_Entries_For "${want}" "${profile}")
EOF

    [ "${Hard_Count}" -gt 0 ] && return 2
    [ "${Soft_Count}" -gt 0 ] && return 1
    return 0
}

# 输出单条结果并计数。Detail 与 Fix 由检查原语设置。
Perm_Report()
{
    local id="$1" sev="$2" path="$3" rc="$4"

    if [ "${rc}" -eq 0 ]; then
        Pass_Count=$((Pass_Count + 1))
        [ -n "${Verbose}" ] && printf 'ok   %-6s %s\n' "${id}" "${path}"
        return 0
    fi

    Failed_Ids="${Failed_Ids} ${id}"
    if [ "${sev}" = "hard" ]; then
        Hard_Count=$((Hard_Count + 1))
        Err "FAIL ${id}  ${path}"
        Err "     ${Detail}"
    else
        Soft_Count=$((Soft_Count + 1))
        Warn "WARN ${id}  ${path}"
        Warn "     ${Detail}"
    fi
    [ -n "${Fix}" ] && Say "     修复：${Fix}"
    return 0
}

# ---------------------------------------------------------------------------
# unit 钩子
# ---------------------------------------------------------------------------
# 持有 hard 条目的服务，其启动前钩子不带 - 前缀，检查失败即阻止启动。
Svc_Has_Hard()
{
    local svc="$1" entry sev
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        sev=$(printf '%s' "${entry}" | cut -d'|' -f8)
        [ "${sev}" = "hard" ] && return 0
    done <<EOF
$(Perm_Entries_For "${svc}" fast)
EOF
    return 1
}

# Patch_Unit <unit文件> <服务名>
# 幂等：已注入过标记则直接返回 0。找不到 [Service] 段或 ExecStart 时跳过。
Patch_Unit()
{
    local unit="$1" svc="$2" tmp pre_prefix post_prefix
    local start_line stop_line fail_line

    [ -f "${unit}" ] || return 0
    grep -q "^${Hook_Mark}\$" "${unit}" && return 0
    grep -q '^\[Service\]' "${unit}" || { Warn "${unit} 缺少 [Service] 段，跳过。"; return 0; }
    grep -q '^ExecStart=' "${unit}" || { Warn "${unit} 缺少 ExecStart，跳过。"; return 0; }

    if Svc_Has_Hard "${svc}"; then
        pre_prefix=""
    else
        pre_prefix="-"
    fi
    # unit 设了 User= 时 Exec* 会一并降权，钩子需要 + 前缀才能以 root 读取路径。
    if grep -q '^User=' "${unit}"; then
        pre_prefix="${pre_prefix}+"
        post_prefix="-+"
    else
        post_prefix="-"
    fi
    start_line="ExecStartPre=${pre_prefix}/bin/sh -c 'test -x ${Hook_Bin} || exit 0; exec ${Hook_Bin} hook pre ${svc}'"
    stop_line="ExecStopPost=${post_prefix}/bin/sh -c 'test -x ${Hook_Bin} || exit 0; exec ${Hook_Bin} hook post ${svc}'"
    fail_line="OnFailure=lnmp-perm-diagnose@%n.service"

    tmp=$(mktemp "${unit}.perm.XXXXXX") || return 1
    if ! awk -v mark="${Hook_Mark}" -v start="${start_line}" -v stop="${stop_line}" \
             -v fail="${fail_line}" '
        /^\[Unit\]/ { print; in_unit = 1; next }
        /^\[Service\]/ {
            if (in_unit && !unit_done) { print mark; print fail; print ""; unit_done = 1 }
            in_unit = 0
            print
            in_service = 1
            next
        }
        /^\[/ {
            if (in_unit && !unit_done) { print mark; print fail; print ""; unit_done = 1 }
            in_unit = 0
            in_service = 0
            print
            next
        }
        in_service && /^ExecStart=/ && !svc_done {
            print mark
            print start
            print stop
            svc_done = 1
            print
            next
        }
        { print }
        END {
            if (in_unit && !unit_done) { print mark; print fail }
        }
    ' "${unit}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi

    if ! grep -q '^ExecStartPre=.*lnmp-perm' "${tmp}"; then
        rm -f "${tmp}"
        Warn "${unit} 注入位置未命中，跳过。"
        return 0
    fi

    chmod 644 "${tmp}" && mv -f "${tmp}" "${unit}" || { rm -f "${tmp}"; return 1; }
    return 0
}

# 移除 Patch_Unit 写入的行，保留原有内容。
Unpatch_Unit()
{
    local unit="$1" tmp

    [ -f "${unit}" ] || return 0
    grep -q "^${Hook_Mark}\$" "${unit}" || return 0

    tmp=$(mktemp "${unit}.perm.XXXXXX") || return 1
    if ! awk -v mark="${Hook_Mark}" '
        $0 == mark { skip = 1; next }
        skip && /^(ExecStartPre|ExecStopPost|OnFailure)=/ {
            if ($0 ~ /^OnFailure=/) after_unit = 1
            next
        }
        # 段末钩子块后补写的空行随块一起移除，保证剥离后与注入前一致。
        skip && after_unit && $0 == "" { skip = 0; after_unit = 0; next }
        { skip = 0; after_unit = 0; print }
    ' "${unit}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    chmod 644 "${tmp}" && mv -f "${tmp}" "${unit}" || { rm -f "${tmp}"; return 1; }
    return 0
}

# 服务名到 unit 文件名的映射。
Unit_For_Svc()
{
    case "$1" in
    mysql)     printf 'mysql.service' ;;
    mariadb)   printf 'mariadb.service' ;;
    nginx)     printf 'nginx.service' ;;
    httpd)     printf 'httpd.service' ;;
    php-fpm)   printf 'php-fpm.service' ;;
    redis)     printf 'redis.service' ;;
    pureftpd)  printf 'pureftpd.service' ;;
    *)         return 1 ;;
    esac
}

# unit 名到服务名的反向映射，用于 OnFailure 传入的实例名。
Svc_For_Unit()
{
    local unit="${1%.service}"
    case "${unit}" in
    mysql|mariadb|nginx|httpd|php-fpm|redis|pureftpd)
        printf '%s' "${unit}"
        ;;
    # 多版本 PHP 的 unit 为 php-fpm@<版本>，权限基线与主 php-fpm 相同。
    php-fpm@*)
        printf 'php-fpm'
        ;;
    *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------
Cmd_Check()
{
    local want="${1:-all}" rc=0

    if [ "${want}" != "all" ] && ! Svc_For_Unit "${want}" >/dev/null 2>&1; then
        case "${want}" in
        cmd|sec) ;;
        *) Err "未知服务名：${want}"; return 1 ;;
        esac
    fi

    Verbose=y
    Perm_Run "${want}" full
    rc=$?
    Verbose=""

    Say ""
    if [ "${Ignored_Count}" -gt 0 ]; then
        Say "通过 ${Pass_Count}，告警 ${Soft_Count}，严重 ${Hard_Count}，已忽略 ${Ignored_Count}"
    else
        Say "通过 ${Pass_Count}，告警 ${Soft_Count}，严重 ${Hard_Count}"
    fi
    Save_State "${rc}"
    return ${rc}
}

Cmd_Status()
{
    local svc unit path patched=0 total=0

    Say "校验钩子安装状态："
    for svc in ${Hook_Services}; do
        unit=$(Unit_For_Svc "${svc}") || continue
        path="${Systemd_Dir}/${unit}"
        [ -f "${path}" ] || continue
        total=$((total + 1))
        if grep -q "^${Hook_Mark}\$" "${path}" 2>/dev/null; then
            patched=$((patched + 1))
            Say "  ${unit}  已安装"
        else
            Say "  ${unit}  未安装"
        fi
    done
    [ "${total}" -eq 0 ] && Say "  未找到本项目生成的 systemd unit"

    if [ -f "${Diagnose_Unit}" ]; then
        Say "失败诊断单元：已安装"
    else
        Say "失败诊断单元：未安装"
    fi

    Say ""
    Say "定期核对："
    if [ -f "${Systemd_Timer}" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl list-timers --no-pager lnmp-perm.timer 2>/dev/null |
                sed -n '2p;3p' | sed 's/^/  /'
        fi
        Say "  单元：${Systemd_Timer}"
    elif [ -f "${Cron_File}" ]; then
        Say "  cron：${Cron_File}"
    else
        Say "  未安装（执行 lnmp perm init 安装）"
    fi

    if [ -s "${Ignore_File}" ]; then
        Say ""
        Say "已忽略条目："
        sed 's/^/  /' "${Ignore_File}"
    fi

    if [ -s "${State_File}" ]; then
        Say ""
        Say "上次核对："
        sed 's/^/  /' "${State_File}"
    fi

    Say ""
    Say "安装钩子：lnmp perm init      移除钩子：lnmp perm uninit"
    return 0
}

# ---------------------------------------------------------------------------
# 定期核对
# ---------------------------------------------------------------------------
# systemd 是否可用于安装 unit：三个条件缺一不可，否则一律走 cron。
Has_Systemd()
{
    command -v systemctl >/dev/null 2>&1 &&
    [ -d /run/systemd/system ] &&
    [ -d "${Systemd_Dir}" ]
}

Write_Systemd_Unit()
{
    cat > "${Systemd_Service}" <<'EOF' || { Err "写入 ${Systemd_Service} 失败。"; return 1; }
[Unit]
Description=LNMP permission baseline check

[Service]
Type=oneshot
ExecStart=/bin/lnmp-perm run
Nice=10
IOSchedulingClass=idle
EOF
    cat > "${Systemd_Timer}" <<'EOF' || { Err "写入 ${Systemd_Timer} 失败。"; return 1; }
[Unit]
Description=LNMP permission baseline check timer

[Timer]
OnCalendar=*-*-* 04:20:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 "${Systemd_Service}" "${Systemd_Timer}" \
        || { Err "设置 unit 文件权限失败。"; return 1; }
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now lnmp-perm.timer >/dev/null 2>&1 \
        || { Err "启用 lnmp-perm.timer 失败，请手工检查。"; return 1; }
    Ok "已启用 systemd timer：每天 04:20 前后核对（带随机延迟）。"
    return 0
}

Write_Cron()
{
    cat > "${Cron_File}" <<'EOF' || { Err "写入 ${Cron_File} 失败。"; return 1; }
# LNMP 权限基线核对 —— 由 lnmp perm init 生成
20 4 * * * root /bin/lnmp-perm run
EOF
    chmod 644 "${Cron_File}" || { Err "设置 ${Cron_File} 权限失败。"; return 1; }
    Ok "已写入 cron：${Cron_File}"
    return 0
}

# 安装定期核对任务，systemd 不可用时退回 cron。
Install_Schedule()
{
    if Has_Systemd; then
        Write_Systemd_Unit || return 1
        return 0
    fi
    [ -d "${Cron_File%/*}" ] || {
        Err "未找到 ${Cron_File%/*}，无法安装定期核对任务。"
        return 1
    }
    Write_Cron || return 1
    return 0
}

# 删除失败要如实返回，否则 uninit 会在残留 timer 或 cron 的情况下报成功。
Remove_Schedule()
{
    local rc=0 path

    if [ -e "${Systemd_Timer}" ] && command -v systemctl >/dev/null 2>&1; then
        if ! systemctl disable --now lnmp-perm.timer >/dev/null 2>&1; then
            # unit 未加载或本就未启用时 disable 也返回非零，只有 timer 仍启用
            # 或仍在运行才算禁用失败。
            if systemctl is-enabled lnmp-perm.timer >/dev/null 2>&1 ||
               systemctl is-active lnmp-perm.timer >/dev/null 2>&1; then
                Err "禁用 lnmp-perm.timer 失败。"
                rc=1
            fi
        fi
    fi
    if [ -e "${Systemd_Timer}" ] || [ -e "${Systemd_Service}" ]; then
        rm -f "${Systemd_Timer}" "${Systemd_Service}" 2>/dev/null
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    fi
    rm -f "${Cron_File}" 2>/dev/null
    for path in "${Systemd_Timer}" "${Systemd_Service}" "${Cron_File}"; do
        [ -e "${path}" ] || continue
        Err "删除失败：${path}"
        rc=1
    done
    return ${rc}
}

# 定时任务入口：全量核对，写日志，仅在结果变化时推送。
Cmd_Run()
{
    local rc digest summary

    Verbose=""
    Perm_Run all full
    rc=$?
    digest=$(Result_Digest)
    printf -v summary '通过 %s，告警 %s，严重 %s' \
        "${Pass_Count}" "${Soft_Count}" "${Hard_Count}"
    [ "${Ignored_Count}" -gt 0 ] && \
        printf -v summary '%s，已忽略 %s' "${summary}" "${Ignored_Count}"

    case "${rc}" in
    0) Log INFO "${summary}" ;;
    1) Log WARN "${summary}；条目：${Failed_Ids# }" ;;
    *) Log ERROR "${summary}；条目：${Failed_Ids# }" ;;
    esac

    if Should_Notify "${rc}" "${digest}"; then
        if [ "${rc}" -eq 0 ]; then
            Notify "LNMP 权限核对：此前的偏差已恢复
${summary}"
        else
            Notify "LNMP 权限核对发现偏差
${summary}
条目：${Failed_Ids# }"
        fi
        Write_State "Last_Notify_Time" "$(date +%s)"
    fi

    Write_State "Last_Digest" "${digest}"
    Save_State "${rc}"
    return ${rc}
}

Cmd_Ignore()
{
    local id="${1:-}"

    [ -n "${id}" ] || { Err "用法：lnmp perm ignore <条目ID>"; return 1; }
    [ "$(id -u)" = "0" ] || { Err "ignore 需要 root 权限。"; return 1; }
    Baseline_Has_Id "${id}" || { Err "基线中没有条目 ${id}。"; return 1; }
    Is_Ignored "${id}" && { Say "${id} 已在忽略清单中。"; return 0; }

    [ -d "${Conf_Dir}" ] || mkdir -p "${Conf_Dir}" || return 1
    printf '%s\n' "${id}" >> "${Ignore_File}" || return 1
    chmod 600 "${Ignore_File}" || return 1
    Ok "已忽略条目 ${id}。"
    return 0
}

Cmd_Unignore()
{
    local id="${1:-}" tmp

    [ -n "${id}" ] || { Err "用法：lnmp perm unignore <条目ID>"; return 1; }
    [ "$(id -u)" = "0" ] || { Err "unignore 需要 root 权限。"; return 1; }
    Is_Ignored "${id}" || { Say "${id} 不在忽略清单中。"; return 0; }

    tmp=$(mktemp "${Ignore_File}.XXXXXX") || return 1
    awk -v id="${id}" '
        { line = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line) }
        line != id { print }
    ' "${Ignore_File}" > "${tmp}" || { rm -f "${tmp}"; return 1; }
    chmod 600 "${tmp}" && mv -f "${tmp}" "${Ignore_File}" || { rm -f "${tmp}"; return 1; }
    Ok "已取消忽略条目 ${id}。"
    return 0
}

Cmd_Init()
{
    local svc unit path rc=0 done_count=0

    [ "$(id -u)" = "0" ] || { Err "init 需要 root 权限。"; return 1; }
    [ -x "${Hook_Bin}" ] || { Err "${Hook_Bin} 不存在或不可执行，请先安装管理命令。"; return 1; }

    # 启停钩子依赖 systemd unit；没有 systemd 时只保留定期核对。
    if Has_Systemd; then
        for svc in ${Hook_Services}; do
            unit=$(Unit_For_Svc "${svc}") || continue
            path="${Systemd_Dir}/${unit}"
            [ -f "${path}" ] || continue
            if Patch_Unit "${path}" "${svc}"; then
                done_count=$((done_count + 1))
            else
                Err "注入失败：${path}"
                rc=1
            fi
        done
        systemctl daemon-reload >/dev/null 2>&1 || rc=1
    else
        Say "本机不使用 systemd，跳过启停钩子，仅安装定期核对任务。"
    fi

    # 启停钩子只覆盖服务状态变化的时刻，运行期间的改动靠定期核对发现。
    if ! Install_Schedule; then
        Err "定期核对任务安装失败，权限改动只能在服务启停时被发现。"
        rc=1
    fi

    if [ "${rc}" -eq 0 ]; then
        if Has_Systemd; then
            Ok "已处理 ${done_count} 个 unit，权限校验钩子生效。"
        fi
        Log INFO "perm init 完成，处理 ${done_count} 个 unit"
    fi
    return ${rc}
}

Cmd_Uninit()
{
    local svc unit path rc=0

    [ "$(id -u)" = "0" ] || { Err "uninit 需要 root 权限。"; return 1; }

    for svc in ${Hook_Services}; do
        unit=$(Unit_For_Svc "${svc}") || continue
        path="${Systemd_Dir}/${unit}"
        Unpatch_Unit "${path}" || { Err "剥离失败：${path}"; rc=1; }
    done

    Remove_Schedule || rc=1
    Remove_Diagnose_Unit || rc=1
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 ||
            { Err "systemctl daemon-reload 失败。"; rc=1; }
    fi
    if [ "${rc}" -ne 0 ]; then
        Err "清理未全部完成，请按上述路径处理后重新执行 uninit。"
        return ${rc}
    fi
    Ok "权限校验钩子与定期核对任务已移除。"
    return 0
}

# 移除失败诊断模板 unit 及其残留实例。各服务 unit 的 OnFailure 已在
# Unpatch_Unit 中剥离，此处清理才不会留下无人引用的 unit。
Remove_Diagnose_Unit()
{
    [ -e "${Diagnose_Unit}" ] || return 0
    rm -f "${Diagnose_Unit}" 2>/dev/null
    if [ -e "${Diagnose_Unit}" ]; then
        Err "删除失败：${Diagnose_Unit}"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reset-failed 'lnmp-perm-diagnose@*' >/dev/null 2>&1
    fi
    return 0
}

# hook <pre|post> <服务名>
# pre 命中硬条件时返回 1，由 systemd 阻止启动；post 一律返回 0。
Cmd_Hook()
{
    local phase="${1:-}" svc="${2:-}" rc=0

    [ -n "${phase}" ] && [ -n "${svc}" ] || return 0
    Svc_For_Unit "${svc}" >/dev/null 2>&1 || return 0

    Verbose=""
    Perm_Run "${svc}" fast
    rc=$?

    case "${phase}" in
    pre)
        if [ "${rc}" -ge 2 ]; then
            Err "${svc} 权限基线校验未通过，已阻止启动。"
            Log ERROR "hook pre ${svc} 硬条件失败：${Failed_Ids}"
            Notify "LNMP 权限告警：${svc} 因权限问题被阻止启动
失败条目：${Failed_Ids}"
            return 1
        fi
        [ "${rc}" -eq 1 ] && Log WARN "hook pre ${svc} 软告警：${Failed_Ids}"
        return 0
        ;;
    post)
        [ "${rc}" -ne 0 ] && Log WARN "hook post ${svc} 偏差：${Failed_Ids}"
        return 0
        ;;
    esac
    return 0
}

# diagnose <unit名>
# 由 OnFailure 触发，只接受已知 unit 名，始终返回 0。
Cmd_Diagnose()
{
    local unit="${1:-}" svc now last

    svc=$(Svc_For_Unit "${unit}") || return 0

    now=$(date +%s)
    last=$(Read_State "Diag_${svc}_Time")
    if [ -n "${last}" ] && [ $((now - last)) -lt "${Diag_Quiet_Sec}" ]; then
        Verbose=""
        Perm_Run "${svc}" full >/dev/null 2>&1
        return 0
    fi

    Say "=== ${unit} 启动失败，权限基线核对 ==="
    Verbose=""
    Perm_Run "${svc}" full
    Say "通过 ${Pass_Count}，告警 ${Soft_Count}，严重 ${Hard_Count}"

    case "${svc}" in
    mysql|mariadb) Diagnose_DB ;;
    esac

    Write_State "Diag_${svc}_Time" "${now}"
    # unit 进入 failed 即告警。崩溃原因与权限无关时（如 OOM）计数为 0，
    # 此时仍需通知，否则重启次数耗尽后无人知晓。
    if [ "${Hard_Count}" -gt 0 ] || [ "${Soft_Count}" -gt 0 ]; then
        Notify "LNMP 服务告警：${unit} 启动失败
权限基线失败条目：${Failed_Ids}"
    else
        Notify "LNMP 服务告警：${unit} 进入 failed
权限基线正常，需查 journalctl -xeu ${unit} 定位原因。"
    fi
    return 0
}

# 数据库启动失败时补充错误日志末尾，供权限之外的原因定位。
Diagnose_DB()
{
    local logerror

    logerror=$(Db_Log_Error_Path)
    if [ $? -ne 0 ]; then
        Say ""
        Say "无法定位数据库错误日志：log_error 为相对路径但未配置 datadir，或解析后越出数据目录。"
        return 0
    fi
    [ -n "${logerror}" ] && [ -s "${logerror}" ] || return 0
    Say ""
    Say "数据库错误日志末尾（${logerror}）："
    tail -n 15 "${logerror}"
    return 0
}

# ---------------------------------------------------------------------------
# 状态与通知
# ---------------------------------------------------------------------------
Read_State()
{
    local key="$1"
    [ -s "${State_File}" ] || return 0
    awk -F= -v k="${key}" '$1 == k { print $2; exit }' "${State_File}"
}

Write_State()
{
    local key="$1" value="$2" tmp

    [ -d "${Conf_Dir}" ] || mkdir -p "${Conf_Dir}" 2>/dev/null || return 0
    tmp=$(mktemp "${State_File}.XXXXXX" 2>/dev/null) || return 0
    if [ -s "${State_File}" ]; then
        awk -F= -v k="${key}" '$1 != k' "${State_File}" > "${tmp}" 2>/dev/null
    fi
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
    chmod 600 "${tmp}" && mv -f "${tmp}" "${State_File}" || rm -f "${tmp}"
    return 0
}

Save_State()
{
    local rc="$1"
    Write_State "Last_Rc" "${rc}"
    Write_State "Last_Time" "$(date +%s)"
    Write_State "Last_Failed" "${Failed_Ids# }"
    return 0
}

# 失败条目集合的摘要，用于判断结果是否与上次相同。
Result_Digest()
{
    local ids
    ids=$(printf '%s\n' ${Failed_Ids} | sort | tr '\n' ' ')
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "${ids}" | sha256sum | cut -d' ' -f1
    else
        # 无 sha256sum 时退回排序后的 ID 串，同样能反映结果是否变化。
        printf '%s' "${ids}" | tr -d ' '
    fi
}

# Should_Notify <返回码> <摘要>
# 结果与上次不同即通知；结果未变但仍有硬失败时，超过阻尼期再提醒一次。
Should_Notify()
{
    local rc="$1" digest="$2" last_digest last_notify now

    last_digest=$(Read_State "Last_Digest")
    last_notify=$(Read_State "Last_Notify_Time")
    now=$(date +%s)

    # 首次核对且结果干净时不打扰。
    if [ -z "${last_digest}" ] && [ "${rc}" -eq 0 ]; then
        return 1
    fi
    [ "${digest}" != "${last_digest}" ] && return 0
    [ "${rc}" -ge 2 ] || return 1
    [ -n "${last_notify}" ] || return 0
    [ $((now - last_notify)) -ge "${Notify_Quiet_Sec}" ] && return 0
    return 1
}

# 通过已安装的通知工具推送；未配置时静默返回 0。
Notify()
{
    [ -r /bin/lnmp-tgnotice ] || return 0
    . /bin/lnmp-tgnotice
    command -v tgnotice >/dev/null 2>&1 || return 0
    tgnotice "$1" text >/dev/null 2>&1 || true
    return 0
}

# ---------------------------------------------------------------------------
Usage()
{
    cat <<'EOF'
用法：lnmp perm <子命令>

  check [服务名]     核对权限基线；不带参数核对全部条目
                     服务名：mysql mariadb nginx httpd php-fpm
                             redis pureftpd cmd sec
  run                定期核对入口，仅在结果与上次不同时推送通知
  status             显示钩子与定期核对状态、忽略清单和上次结果
  init               注入校验钩子并安装每日定期核对任务
  uninit             剥离校验钩子并移除定期核对任务
  ignore <条目ID>    忽略指定条目，用于有意做出的权限调整
  unignore <条目ID>  取消忽略

返回码：0 全部通过；1 存在权限告警；2 存在会导致服务启动失败的问题
日志：/var/log/lnmp/perm.log
忽略清单：/etc/lnmp/perm-ignore（600）
EOF
}

Main()
{
    local cmd="${1:-}"
    [ -n "${cmd}" ] && shift
    case "${cmd}" in
        check)    Cmd_Check "$@" ;;
        run)      Cmd_Run "$@" ;;
        status)   Cmd_Status "$@" ;;
        ignore)   Cmd_Ignore "$@" ;;
        unignore) Cmd_Unignore "$@" ;;
        init)     Cmd_Init "$@" ;;
        uninit)   Cmd_Uninit "$@" ;;
        hook)     Cmd_Hook "$@" ;;
        diagnose) Cmd_Diagnose "$@" ;;
        help|-h|--help) Usage ;;
        *)        Usage; return 1 ;;
    esac
}

Verbose=""
Pass_Count=0
Soft_Count=0
Hard_Count=0
Ignored_Count=0
Failed_Ids=""
Detail=""
Fix=""

# 被 source 时只提供函数与基线，供定向测试调用。
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    Main "$@"
fi
