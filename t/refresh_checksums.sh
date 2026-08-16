#!/usr/bin/env bash
#
# t/refresh_checksums.sh - 只重算受版本变更影响的 sha256 条目
#
# 用法：
#   bash t/refresh_checksums.sh            # 读 .upstream/changed.tsv
#   bash t/refresh_checksums.sh MySQL_8.4 8.4.7 8.4.8 [更多 key old new 三元组...]
#
# 不使用 t/gen_checksums.sh 全量重算，避免下载全部 MySQL 和 MariaDB
# 二进制包，也避免未经确认地更新未发生版本变更的校验值。
#
# 做法：找出清单里含旧版本号的行，按同样的替换规则推出新文件名，
# 下载新文件算哈希，原地替换那一行（保持行序和上下文注释不变）。

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

cur_dir=$(pwd)
Echo_Red()    { printf '%s\n' "$*" >&2; }
Echo_Yellow() { printf '%s\n' "$*" >&2; }
Echo_Green()  { printf '%s\n' "$*" >&2; }
. include/verify.sh

SUMS='src/checksums.sha256'
CHANGED="${OUT_DIR:-.upstream}/changed.tsv"

[ -f "${SUMS}" ] || { echo "找不到 ${SUMS}" >&2; exit 1; }

# 收集 key->old->new 三元组
PAIRS=''
if [ $# -ge 3 ]; then
    [ $(( $# % 3 )) -eq 0 ] || { echo "参数必须按 key old new 三元组传入" >&2; exit 1; }
    while [ $# -ge 3 ]; do
        PAIRS="${PAIRS}$1	$2	$3
"
        shift 3
    done
elif [ -s "${CHANGED}" ]; then
    PAIRS=$(cat "${CHANGED}")
else
    echo "没有版本变更需要处理。"
    exit 0
fi

WORK=$(mktemp -d /tmp/lnmp-sums.XXXXXX) || exit 1
trap 'rm -rf "${WORK}"' EXIT

# 通过 gen_checksums.sh 的只读模式取得 URL，避免重复维护下载地址。
declare -A URL_OF
url_count=0
while IFS= read -r line; do
    # 形如：<URL> <落地文件名>
    read -r url name extra <<< "${line}"
    if [ -n "${url}" ] && [ -n "${name}" ] && [ -z "${extra}" ]; then
        URL_OF["${name}"]="${url}"
        url_count=$((url_count+1))
    fi
done < <(LIST_ONLY=1 bash t/gen_checksums.sh 2>/dev/null | grep -E '^https?://')

if [ ${url_count} -eq 0 ]; then
    echo "!! 无法从 t/gen_checksums.sh 取得 URL 清单（需要它支持 LIST_ONLY=1）" >&2
    exit 1
fi

updated=0
failed=0
TMP="${WORK}/sums.new"
cp "${SUMS}" "${TMP}"

checksum_prefix()
{
    case "$1" in
        PHP_*) echo 'php-' ;;
        MySQL_*) echo 'mysql-' ;;
        MariaDB_*) echo 'mariadb-' ;;
        Apache_Ver) echo 'httpd-' ;;
        PhpMyAdmin_Ver) echo '' ;;
        *) echo '' ;;
    esac
}

valid_key()
{
    case "$1" in ''|[0-9]*|*[!0-9A-Za-z_.-]*) return 1 ;; *) return 0 ;; esac
}

valid_version_value()
{
    case "$1" in ''|*[!0-9A-Za-z._-]*) return 1 ;; *) return 0 ;; esac
}

published_sum()
{
    local url="$1" tmp sum=''
    tmp=$(mktemp "${WORK}/published.XXXXXX") || return 1
    if Download_Fetch "${url}" "${tmp}" >/dev/null 2>&1; then
        sum=$(grep -oiE '[0-9a-f]{64}' "${tmp}" | head -1)
    fi
    rm -f "${tmp}"
    printf '%s' "${sum}"
}

# 对已有机器可读官方依据的组件强制交叉核对。
verify_upstream_file()
{
    local key="$1" new="$2" name="$3" file="$4" url="$5"
    local project='' ver="${new}" expected=''

    case "${key}" in
    PHP_*) project=php ;;
    MariaDB_*) project=mariadb ;;
    PhpMyAdmin_Ver)
        project=phpmyadmin
        ver="${new#phpMyAdmin-}"; ver="${ver%-all-languages}"
        ;;
    Openssl_New_Ver|Apache_Ver|APR_Ver|APR_Util_Ver)
        expected=$(published_sum "${url}.sha256")
        ;;
    Nginx_Ver)
        Verify_Nginx_Signature "${file}" "${url}" >/dev/null
        return $?
        ;;
    *) return 0 ;;
    esac

    if [ -n "${project}" ]; then
        expected=$(Upstream_SHA256 "${project}" "${ver}" "${name}")
    fi
    if ! echo "${expected}" | grep -Eq '^[0-9a-f]{64}$'; then
        echo "!! 无法取得 ${name} 的上游 SHA256" >&2
        return 1
    fi
    Verify_SHA256_Value "${file}" "${expected}" >/dev/null
}

while IFS=$'\t' read -r key old new extra; do
    [ -z "${old}" ] && continue
    if ! valid_key "${key}" || ! valid_version_value "${old}" ||
       ! valid_version_value "${new}" || [ -n "${extra}" ]; then
        echo "!! 拒绝非法版本变更：key=${key}, old=${old}, new=${new}" >&2
        failed=$((failed+1))
        continue
    fi
    prefix=$(checksum_prefix "${key}")
    while IFS= read -r stale; do
        [ -z "${stale}" ] && continue
        old_name=$(printf '%s' "${stale}" | awk '{print $2}')
        new_name=$(printf '%s' "${old_name}" | OLD_VALUE="${old}" NEW_VALUE="${new}" \
            perl -pe 's/\Q$ENV{OLD_VALUE}\E/$ENV{NEW_VALUE}/g')
        [ "${old_name}" = "${new_name}" ] && continue

        url="${URL_OF["${new_name}"]:-}"
        if [ -z "${url}" ]; then
            echo "!! ${new_name} 在 gen_checksums.sh 里没有对应 URL，跳过（需手工补）" >&2
            failed=$((failed+1))
            continue
        fi

        echo "重算 ${new_name}"
        if ! Download_Fetch "${url}" "${WORK}/f" >/dev/null; then
            echo "!! 下载失败：${url}" >&2
            failed=$((failed+1))
            continue
        fi
        if ! verify_upstream_file "${key}" "${new}" "${new_name}" "${WORK}/f" "${url}"; then
            echo "!! ${new_name} 与上游公布值或签名不一致" >&2
            rm -f "${WORK}/f"
            failed=$((failed+1))
            continue
        fi
        sum=$(sha256sum "${WORK}/f" | awk '{print $1}')
        rm -f "${WORK}/f"

        if ! echo "${sum}" | grep -Eq '^[0-9a-f]{64}$'; then
            echo "!! ${new_name} 的本地 SHA256 计算结果非法" >&2
            failed=$((failed+1))
            continue
        fi

        # 以两列精确匹配原条目，并用 awk 重写完整行，保持清单行序和换行边界。
        NEXT="${WORK}/sums.next"
        if ! awk -v old_name="${old_name}" -v new_name="${new_name}" -v sum="${sum}" '
            $1 ~ /^[0-9a-f]{64}$/ && $2 == old_name { print sum "  " new_name; changed++; next }
            { print }
            END { if (changed != 1) exit 1 }
        ' "${TMP}" > "${NEXT}" || ! mv "${NEXT}" "${TMP}"; then
            echo "!! 替换 ${old_name} 失败" >&2
            failed=$((failed+1))
            continue
        fi
        updated=$((updated+1))
    done < <(awk -v prefix="${prefix}" -v old="${old}" '
        $1 ~ /^[0-9a-f]{64}$/ && index($2, old) > 0 &&
        (prefix == "" || index($2, prefix) == 1) { print }
    ' "${SUMS}")
done <<< "${PAIRS}"

# 写回前先核对格式：清单是 fail-closed 校验的唯一依据，一旦被写坏，
# 安装要到下载完那个文件才会中止。宁可这里不写回，也不要放行坏清单。
if [ ${updated} -gt 0 ]; then
    bad_lines=$(grep -vcE '^([0-9a-f]{64}  [^[:space:]]+|#.*|)$' "${TMP}")
    if [ "${bad_lines}" -ne 0 ]; then
        echo "!! 生成的清单有 ${bad_lines} 行不符合 '<64位sha256><两个空格><文件名>' 格式，已放弃写回：" >&2
        grep -nvE '^([0-9a-f]{64}  [^[:space:]]+|#.*|)$' "${TMP}" | head -5 >&2
        exit 1
    fi
    if ! mv "${TMP}" "${SUMS}"; then
        echo "!! 写回 ${SUMS} 失败" >&2
        exit 1
    fi
fi

echo
echo "已更新 ${updated} 条校验值，失败 ${failed} 条。"
[ ${failed} -eq 0 ]
