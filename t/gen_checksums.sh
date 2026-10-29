#!/usr/bin/env bash
#
# t/gen_checksums.sh - 采集 src/checksums.sha256 所需的哈希
#
# 用法（在可信且可访问外网的环境中执行）：
#   bash t/gen_checksums.sh            # 全量
#   bash t/gen_checksums.sh core       # 仅处理默认 lnmp 安装路径所需组件
#
# 输出直接就是 checksums.sha256 的正文格式，重定向覆盖即可：
#   bash t/gen_checksums.sh > /tmp/sums.txt
#
# 下载地址与文件名取自 t/list_sources.sh（各模块 *_Sources），本脚本不维护地址与版本。
# LIST_ONLY=1 时每个文件只输出一行「URL 文件名」，URL 为首选地址。
#
# ---------------------------------------------------------------------------
# 信任模型
#
# 本脚本下载文件后计算哈希，不能独立证明文件未被篡改。生成的清单用于
# 验证后续下载内容与采集时的文件是否一致。
#
# 来源可信度由以下措施提供：
#   1. 全部走 HTTPS 上游官方域名（见 t/lint.sh 的 C9 / C13）
#   2. 有官方公布校验值的组件，下面会额外做交叉核对（标 [x-check]）
#
# 应在可信网络环境中生成清单。
# ---------------------------------------------------------------------------

cd "$(dirname "$0")/.." || exit 1

cur_dir=$(pwd)
Echo_Red()    { printf '%s\n' "$*" >&2; }
Echo_Yellow() { printf '%s\n' "$*" >&2; }
Echo_Green()  { printf '%s\n' "$*" >&2; }
. include/verify.sh

SCOPE="${1:-all}"
case "${SCOPE}" in all|core) ;; *) echo "用法：bash t/gen_checksums.sh [all|core]" >&2; exit 1 ;; esac
WORK=$(mktemp -d /tmp/lnmp-sums.XXXXXX)
trap 'rm -rf "${WORK}"' EXIT

ok=0
bad=0
XCHECK_LOG=''

# ---------------------------------------------------------------------------
# grab <URL> <保存文件名> [官方公布的sha256]
#
# 保存文件名必须与 Download_Files 的第二个参数完全一致。校验按
# 落地文件名查表的，URL 的 basename 常常不同（GitHub tag 归档尤其明显：
# URL 是 v0.33.tar.gz，落地名是 lua-resty-redis-0.33.tar.gz）。
#
# 计算哈希后立即删除下载文件，控制临时磁盘占用。
# ---------------------------------------------------------------------------
grab()
{
    local url="$1" name="$2" want="${3:-}" sum

    # LIST_ONLY=1：只把「URL 落地文件名」打印出来，不下载、不算哈希。
    # t/refresh_checksums.sh 通过该模式读取本文件维护的下载地址。
    if [ -n "${LIST_ONLY:-}" ]; then
        printf '%s %s\n' "${url}" "${name}"
        return 0
    fi

    if ! Download_Fetch "${url}" "${WORK}/${name}" >/dev/null; then
        echo "# !! 下载失败: ${name}  <- ${url}" >&2
        bad=$((bad+1))
        rm -f "${WORK}/${name}"
        return 1
    fi

    sum=$(sha256sum "${WORK}/${name}" | awk '{print $1}')
    rm -f "${WORK}/${name}"

    if [ -n "${want}" ]; then
        if [ "${sum}" = "${want}" ]; then
            XCHECK_LOG="${XCHECK_LOG}
#   [x-check ok] ${name}"
        else
            echo "# !! 交叉核对失败: ${name}" >&2
            echo "# !!   官方公布: ${want}" >&2
            echo "# !!   实际下载: ${sum}" >&2
            bad=$((bad+1))
            return 1
        fi
    fi

    printf '%s  %s\n' "${sum}" "${name}"
    ok=$((ok+1))
}

# 官方为该文件提供 SHA256 时，取不到或不匹配都必须失败。
grab_upstream()
{
    local project="$1" ver="$2" url="$3" name="$4" want

    if [ -n "${LIST_ONLY:-}" ]; then
        grab "${url}" "${name}"
        return $?
    fi
    want=$(Upstream_SHA256 "${project}" "${ver}" "${name}")
    if ! echo "${want}" | grep -Eq '^[0-9a-f]{64}$'; then
        echo "# !! 无法取得 ${name} 的上游 SHA256" >&2
        bad=$((bad+1))
        return 1
    fi
    grab "${url}" "${name}" "${want}"
}

grab_published()
{
    local url="$1" name="$2" sum_url="$3" want

    if [ -n "${LIST_ONLY:-}" ]; then
        grab "${url}" "${name}"
        return $?
    fi
    want=$(fetch_sum "${sum_url}")
    if ! echo "${want}" | grep -Eq '^[0-9a-f]{64}$'; then
        echo "# !! 无法取得 ${name} 的上游 SHA256" >&2
        bad=$((bad+1))
        return 1
    fi
    grab "${url}" "${name}" "${want}"
}

grab_nginx()
{
    local url="$1" name="$2" sum

    if [ -n "${LIST_ONLY:-}" ]; then
        grab "${url}" "${name}"
        return $?
    fi
    if ! Download_Fetch "${url}" "${WORK}/${name}" >/dev/null; then
        echo "# !! 下载失败: ${name}  <- ${url}" >&2
        bad=$((bad+1))
        rm -f "${WORK}/${name}"
        return 1
    fi
    if ! Verify_Nginx_Signature "${WORK}/${name}" "${url}" >/dev/null; then
        echo "# !! PGP 交叉核对失败: ${name}" >&2
        bad=$((bad+1))
        rm -f "${WORK}/${name}"
        return 1
    fi
    sum=$(sha256sum "${WORK}/${name}" | awk '{print $1}')
    rm -f "${WORK}/${name}"
    printf '%s  %s\n' "${sum}" "${name}"
    XCHECK_LOG="${XCHECK_LOG}
#   [x-check ok] ${name} (PGP)"
    ok=$((ok+1))
}

# 获取上游公布的校验值。
fetch_sum()
{
    local tmp sum=''
    # LIST_ONLY 模式不联网
    [ -n "${LIST_ONLY:-}" ] && return 0
    tmp=$(mktemp "${WORK}/published.XXXXXX") || return 1
    if Download_Fetch "$1" "${tmp}" >/dev/null 2>&1; then
        sum=$(grep -oiE '[0-9a-f]{64}' "${tmp}" | head -1)
    fi
    rm -f "${tmp}"
    printf '%s' "${sum}"
}

echo "# ======================================================================"
echo "# 由 t/gen_checksums.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "# 采集范围: ${SCOPE}"
echo "# ======================================================================"

# 采集清单取自 t/list_sources.sh。以下组件的校验依据不在 src/checksums.sha256，不采集：
# OpenResty 与自定义模块（PGP 签名、配置内 SHA256）、Node.js 签名文件、Composer（上游 SHA384）、
# acme.sh（conf/lnmp 内的 Acme_Sh_SHA256）。
if ! rows=$(bash t/list_sources.sh "${SCOPE}"); then
    echo "# !! 下载清单生成失败：bash t/list_sources.sh ${SCOPE}" >&2
    exit 1
fi

# 按文件分组：FILES 保持清单顺序，同一文件的候选地址按尝试顺序存入 URLS，每行一个。
declare -A URLS COMP VER
FILES=()
while IFS=$'\t' read -r comp _ ver file url _; do
    case "${comp}" in ''|openresty|openresty-module|nodejs-sig|composer|acme.sh) continue ;; esac
    if [ -z "${URLS[${file}]+x}" ]; then
        FILES+=("${file}")
        COMP[${file}]=${comp}
        VER[${file}]=${ver}
    fi
    URLS[${file}]+="${url}"$'\n'
done <<< "${rows}"

# pick_url <文件名>：与安装侧逐个尝试一致，取第一个可达的候选地址；
# 只有一个候选、LIST_ONLY 或均不可达时取第一个，不额外探测。
pick_url()
{
    local url first=''
    while IFS= read -r url; do
        [ -n "${url}" ] || continue
        [ -n "${first}" ] || first=${url}
        [ -n "${LIST_ONLY:-}" ] && break
        [ "${URLS[$1]}" = "${url}"$'\n' ] && break
        Download_Head_OK "${url}" 30 && { printf '%s\n' "${url}"; return 0; }
    done <<< "${URLS[$1]}"
    printf '%s\n' "${first}"
}

last=''
for file in "${FILES[@]}"; do
    comp=${COMP[${file}]}
    if [ "${comp}" != "${last}" ]; then
        echo
        echo "# --- ${comp} ---"
        last=${comp}
    fi
    url=$(pick_url "${file}")
    # 上游公布校验值的组件逐个交叉核对，取不到或不匹配都失败。
    case "${comp}:${file}" in
    php:*|phpmyadmin:*|boost:*) grab_upstream "${comp}" "${VER[${file}]}" "${url}" "${file}" ;;
    database:mariadb-*)         grab_upstream mariadb "${VER[${file}]}" "${url}" "${file}" ;;
    nginx:nginx-*)              grab_nginx "${url}" "${file}" ;;
    *:httpd-*|*:apr-*|*:openssl-*) grab_published "${url}" "${file}" "${url}.sha256" ;;
    *)                          grab "${url}" "${file}" ;;
    esac
done

if [ "${SCOPE}" = "core" ]; then
    echo
    echo "# （core 模式，可选组件未采集）"
fi

echo
echo "# ----------------------------------------------------------------------"
echo "# 采集完成：成功 ${ok} 项，失败 ${bad} 项"
if [ -n "${XCHECK_LOG}" ]; then
    echo "# 与上游公布值交叉核对通过的条目：${XCHECK_LOG}"
fi
echo "# ----------------------------------------------------------------------"

echo "采集完成：成功 ${ok} 项，失败 ${bad} 项" >&2
[ ${bad} -eq 0 ]
