#!/usr/bin/env bash
#
# lnmp-tgnotice 用于从 LNMP 脚本发送 Telegram 通知。
#
#   tgnotice "备份失败：wpdemo"            默认 HTML 格式
#   tgnotice "*已完成*" md                 MarkdownV2 格式
#
# 支持两种调用方式：
#
#   1. 当命令用：/bin/lnmp-tgnotice "文本" [md]
#   2. 被 source 之后当函数用：. /bin/lnmp-tgnotice && tgnotice "文本"
#
# 安装后由 /etc/profile.d/lnmp-tgnotice.sh 自动加载，交互式 shell 和管理脚本
# 可直接调用 tgnotice。
#
# ---------------------------------------------------------------------------
# 安全与发送规则
#
# Bot token 和消息内容可能包含敏感信息，均写入权限 600 的临时 curl 配置。
# 命令行参数仅包含 --config，防止其他本机用户通过进程列表读取凭据。
#
# 消息保留 HTML 或 MarkdownV2 标记以支持格式化内容。Telegram 解析失败时，
# 自动降级为纯文本重发一次，避免因保留字符导致通知丢失。
#
# 发送成功返回 0，失败返回非 0。不需要因通知失败中断主任务时，
# 可使用 `tgnotice "..." || true`。
# ---------------------------------------------------------------------------

TG_Conf_File="${TG_Conf_File:-/etc/lnmp/notify.conf}"

# Telegram 单条消息上限为 4096 字符。
TG_Max_Len=4000

_tg_color() { if [ -t 2 ]; then printf '\033[%sm%s\033[0m\n' "$1" "$2" >&2; else printf '%s\n' "$2" >&2; fi; }
_tg_err()   { _tg_color "0;31" "$*"; }
_tg_warn()  { _tg_color "0;33" "$*"; }
_tg_ok()    { _tg_color "0;32" "$*"; }

# 转义 curl 配置中的反斜杠、双引号和换行符。
_tg_escape()
{
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/\\n}"
    printf '%s' "${s}"
}

_tg_load_conf()
{
    local perm
    TG_Enable="${TG_Enable:-0}"
    TG_Bot_Token="${TG_Bot_Token:-}"
    TG_Chat_Id="${TG_Chat_Id:-}"
    TG_Parse_Mode="${TG_Parse_Mode:-HTML}"
    TG_Timeout="${TG_Timeout:-10}"
    TG_Retry="${TG_Retry:-2}"
    TG_Disable_Preview="${TG_Disable_Preview:-1}"
    if [ -r "${TG_Conf_File}" ]; then
        perm=$(stat -c '%a' "${TG_Conf_File}" 2>/dev/null || stat -f '%Lp' "${TG_Conf_File}" 2>/dev/null)
        case "${perm}" in
            600|400) : ;;
            *) _tg_err "${TG_Conf_File} 权限是 ${perm:-未知}，必须是 600 或 400，拒绝加载。"; return 1 ;;
        esac
        # shellcheck disable=SC1090
        . "${TG_Conf_File}" || { _tg_err "读取 ${TG_Conf_File} 失败。"; return 1; }
    fi
    return 0
}

# _tg_send <文本> <parse_mode 或空字符串>
# parse_mode 为空时按纯文本发送。
_tg_send()
{
    local text="$1" mode="$2" cfg rc body attempt=1
    cfg=$(mktemp "${TMPDIR:-/tmp}/.lnmp-tg.XXXXXXXX") || return 1
    chmod 600 "${cfg}"

    {
        printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$(_tg_escape "${TG_Bot_Token}")"
        printf 'data-urlencode = "chat_id=%s"\n' "$(_tg_escape "${TG_Chat_Id}")"
        printf 'data-urlencode = "text=%s"\n' "$(_tg_escape "${text}")"
        [ -n "${mode}" ] && printf 'data-urlencode = "parse_mode=%s"\n' "${mode}"
        [ "${TG_Disable_Preview}" = "1" ] && printf 'data-urlencode = "disable_web_page_preview=true"\n'
        printf 'silent\nshow-error\n'
        printf 'max-time = %s\n' "${TG_Timeout}"
    } > "${cfg}"

    while :; do
        body=$(curl --config "${cfg}" 2>&1)
        rc=$?
        if [ "${rc}" -eq 0 ] && case "${body}" in *'"ok":true'*) true ;; *) false ;; esac; then
            rm -f "${cfg}"
            printf '%s' "${body}"
            return 0
        fi
        if [ "${attempt}" -ge "$(( TG_Retry + 1 ))" ]; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    rm -f "${cfg}"
    printf '%s' "${body}"
    return 1
}

# ---------------------------------------------------------------------------
# tgnotice <文本> [md|html]
# ---------------------------------------------------------------------------
tgnotice()
{
    local text="${1:-}" fmt="${2:-}" mode body rc

    if [ -z "${text}" ]; then
        _tg_err "tgnotice: 消息不能为空。用法：tgnotice \"文本\" [md]"
        return 1
    fi

    _tg_load_conf || return 1

    # 通知未启用时直接返回成功，避免可选通知干扰主任务输出。
    [ "${TG_Enable}" = "1" ] || return 0

    if [ -z "${TG_Bot_Token}" ] || [ -z "${TG_Chat_Id}" ]; then
        _tg_err "tgnotice: 已启用但缺少 TG_Bot_Token 或 TG_Chat_Id，检查 ${TG_Conf_File}"
        return 1
    fi

    case "${fmt}" in
        ''|html|HTML|h)          mode="HTML" ;;
        md|MD|markdown|MarkdownV2|markdownv2) mode="MarkdownV2" ;;
        text|plain|raw)          mode="" ;;
        *) _tg_err "tgnotice: 未知格式 '${fmt}'，可用：md、html、text"; return 1 ;;
    esac
    # 未指定第二个参数时使用配置中的默认格式。
    [ -z "${fmt}" ] && mode="${TG_Parse_Mode}"

    if [ "${#text}" -gt "${TG_Max_Len}" ]; then
        text="${text:0:${TG_Max_Len}}
…（已截断，Telegram 单条上限 4096 字符）"
    fi

    body=$(_tg_send "${text}" "${mode}")
    rc=$?
    [ "${rc}" -eq 0 ] && return 0

    # HTML 或 MarkdownV2 保留字符导致解析失败时，降级为纯文本重发。
    case "${body}" in
        *"can't parse entities"*|*"can't find end"*|*"Unsupported start tag"*|*"Character '"*)
            _tg_warn "tgnotice: ${mode} 解析失败，已改为纯文本重发。原因：${body}"
            body=$(_tg_send "${text}" "")
            rc=$?
            [ "${rc}" -eq 0 ] && return 0
            ;;
    esac

    _tg_err "tgnotice: 发送失败。${body}"
    return 1
}

# ---------------------------------------------------------------------------
# 命令行入口
# ---------------------------------------------------------------------------
_tgnotice_usage()
{
    cat <<'EOF'
用法：
  lnmp-tgnotice "文本"          发送通知（默认 HTML 格式）
  lnmp-tgnotice "文本" md       用 MarkdownV2 格式
  lnmp-tgnotice "文本" text     纯文本，不做格式解析
  lnmp-tgnotice --init          交互式写入 /etc/lnmp/notify.conf
  lnmp-tgnotice --test          发送一条测试消息
  lnmp-tgnotice --status        显示当前配置（不显示完整令牌）

在脚本里用（推荐）：
  tgnotice "备份失败：wpdemo"
  tgnotice "*备份完成*" md

  函数由 /etc/profile.d/lnmp-tgnotice.sh 自动加载。
  在非交互脚本里如果取不到，显式加载一次：
      . /bin/lnmp-tgnotice
EOF
}

_tgnotice_init()
{
    local token chat mode ans
    [ "$(id -u)" = "0" ] || { _tg_err "--init 需要 root 权限。"; return 1; }
    mkdir -p "${TG_Conf_File%/*}" && chmod 700 "${TG_Conf_File%/*}" || return 1

    if [ -f "${TG_Conf_File}" ]; then
        _tg_warn "配置已存在：${TG_Conf_File}"
        printf '是否覆盖 [y/N]（默认 n）：'
        if ! read -r ans; then
            echo
            _tg_err "读取覆盖确认时遇到 EOF。"
            return 1
        fi
        [ "${ans}" = "y" ] || { echo "保留现有配置。"; return 0; }
    fi

    echo "在 Telegram 里通过 @BotFather 创建机器人并取得令牌；"
    echo "把机器人加入目标群或私聊后发送一条消息，再访问"
    echo "  https://api.telegram.org/bot<TOKEN>/getUpdates"
    echo "即可查看会话 ID（群组 ID 为负数）。"
    echo ""
    printf '机器人令牌：'
    if ! read -r -s token; then
        echo
        _tg_err "读取机器人令牌时遇到 EOF。"
        return 1
    fi
    echo
    printf '会话 ID：'
    if ! read -r chat; then
        echo
        _tg_err "读取会话 ID 时遇到 EOF。"
        return 1
    fi
    printf '默认格式 [HTML/MarkdownV2]（默认 HTML）：'
    if ! read -r mode; then
        echo
        _tg_err "读取默认格式时遇到 EOF。"
        return 1
    fi
    case "${mode}" in
        MarkdownV2|markdownv2|md) mode="MarkdownV2" ;;
        *) mode="HTML" ;;
    esac
    if [ -z "${token}" ] || [ -z "${chat}" ]; then
        _tg_err "机器人令牌和会话 ID 都不能为空。"
        return 1
    fi

    ( umask 077; cat > "${TG_Conf_File}" <<EOF
# LNMP 通知配置 —— 由 lnmp-tgnotice --init 生成
# 权限必须为 600，防止其他本机用户读取机器人令牌。

TG_Enable=1
TG_Bot_Token="${token}"
TG_Chat_Id="${chat}"

# 默认消息格式：HTML 或 MarkdownV2。
TG_Parse_Mode="${mode}"

# 单次请求超时（秒）和失败重试次数。
TG_Timeout=10
TG_Retry=2

# 链接预览：1 禁用，0 允许。
TG_Disable_Preview=1
EOF
    )
    chmod 600 "${TG_Conf_File}"
    _tg_ok "已写入 ${TG_Conf_File}（600）。"
    echo "发一条测试消息确认：lnmp-tgnotice --test"
    return 0
}

_tgnotice_status()
{
    _tg_load_conf || return 1
    echo "配置文件：${TG_Conf_File}"
    if [ ! -r "${TG_Conf_File}" ]; then
        _tg_warn "配置不存在。执行 lnmp-tgnotice --init 生成。"
        return 0
    fi
    echo "启用    ：$([ "${TG_Enable}" = "1" ] && echo 是 || echo 否)"
    if [ -n "${TG_Bot_Token}" ]; then
        echo "机器人令牌：${TG_Bot_Token%%:*}:****（只显示前段）"
    else
        echo "机器人令牌：未设置"
    fi
    echo "会话 ID：${TG_Chat_Id:-未设置}"
    echo "默认格式：${TG_Parse_Mode}"
    echo "超时/重试：${TG_Timeout}s / ${TG_Retry} 次"
    return 0
}

_tgnotice_main()
{
    case "${1:-}" in
        ''|-h|--help|help) _tgnotice_usage; return 1 ;;
        --init)   _tgnotice_init ;;
        --status) _tgnotice_status ;;
        --test)
            _tg_load_conf || return 1
            if [ "${TG_Enable}" != "1" ]; then
                _tg_err "通知未启用（TG_Enable=0）。先执行 lnmp-tgnotice --init。"
                return 1
            fi
            # 测试消息包含 HTML，用于同时验证发送和格式解析。
            if tgnotice "<b>LNMP</b> 测试通知 —— $(hostname 2>/dev/null) $(date '+%F %T')"; then
                _tg_ok "测试消息已发送。"
            else
                return 1
            fi
            ;;
        *) tgnotice "$@" ;;
    esac
}

# source 加载时仅定义函数，直接执行时运行命令行入口。
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    _tgnotice_main "$@"
fi
