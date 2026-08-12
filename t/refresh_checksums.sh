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

SUMS='src/checksums.sha256'
CHANGED="${OUT_DIR:-.upstream}/changed.tsv"

[ -f "${SUMS}" ] || { echo "找不到 ${SUMS}" >&2; exit 1; }

# 收集 key->old->new 三元组
PAIRS=''
if [ $# -ge 3 ]; then
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
while IFS= read -r line; do
    # 形如：<URL> <落地文件名>
    set -- ${line}
    [ $# -ge 2 ] && URL_OF["$2"]="$1"
done < <(LIST_ONLY=1 bash t/gen_checksums.sh 2>/dev/null | grep -E '^https?://')

if [ ${#URL_OF[@]} -eq 0 ]; then
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
        PhpMyAdmin_Ver) echo 'phpMyAdmin-' ;;
        *) echo '' ;;
    esac
}

while IFS=$'\t' read -r key old new; do
    [ -z "${old}" ] && continue
    prefix=$(checksum_prefix "${key}")
    escaped_old=$(printf '%s' "${old}" | sed 's/[][\\.^$*+?{}|()]/\\&/g')
    # profile 组件用文件名前缀限定；version.sh 组件使用自身带前缀的完整值。
    if [ -n "${prefix}" ]; then
        pattern="${prefix}[^[:space:]]*${escaped_old}"
    else
        pattern="${escaped_old}"
    fi
    while IFS= read -r stale; do
        [ -z "${stale}" ] && continue
        old_name=$(printf '%s' "${stale}" | awk '{print $2}')
        new_name=$(printf '%s' "${old_name}" | sed "s/$(printf '%s' "${old}" | sed 's/[.[\*^$]/\\&/g')/${new}/g")
        [ "${old_name}" = "${new_name}" ] && continue

        url="${URL_OF[${new_name}]:-}"
        if [ -z "${url}" ]; then
            echo "!! ${new_name} 在 gen_checksums.sh 里没有对应 URL，跳过（需手工补）" >&2
            failed=$((failed+1))
            continue
        fi

        echo "重算 ${new_name}"
        if ! wget -q --timeout=90 --tries=2 --max-redirect=10 -O "${WORK}/f" "${url}"; then
            echo "!! 下载失败：${url}" >&2
            failed=$((failed+1))
            continue
        fi
        sum=$(sha256sum "${WORK}/f" | awk '{print $1}')
        rm -f "${WORK}/f"

        # 原位替换并保持清单行序。
        # 行尾只能用水平空白 \h，不能用 \s：\s 含换行，贪婪匹配会把行尾的 \n
        # 一起吃掉，替换串又不带换行，结果是本行与下一行被拼成一行 ——
        # 两条校验值同时失效，而 Verify_Download_File 按 awk '$2 == 文件名'
        # 精确取值，合并行一条都匹配不到，安装会在下载后 fail-closed 中止。
        if ! perl -pi -e "s|^[0-9a-f]{64}\h+\Q${old_name}\E\h*\$|${sum}  ${new_name}|" "${TMP}"; then
            echo "!! 替换 ${old_name} 失败" >&2
            failed=$((failed+1))
            continue
        fi
        updated=$((updated+1))
    done < <(grep -E "^[0-9a-f]{64}[[:space:]]+${pattern}" "${SUMS}")
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
