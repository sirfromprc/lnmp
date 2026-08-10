#!/usr/bin/env bash
#
# t/refresh_checksums.sh - 只重算受版本变更影响的 sha256 条目
#
# 用法：
#   bash t/refresh_checksums.sh            # 读 .upstream/changed.tsv
#   bash t/refresh_checksums.sh 8.4.7 8.4.8 [更多 old new 对...]
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

# 收集 old->new 对
PAIRS=''
if [ $# -ge 2 ]; then
    while [ $# -ge 2 ]; do
        PAIRS="${PAIRS}$1	$2
"
        shift 2
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

while IFS=$'\t' read -r old new; do
    [ -z "${old}" ] && continue
    # 清单里所有含旧版本号的行
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

        # 原位替换并保持清单行序
        perl -pi -e "s|^[0-9a-f]{64}\s+\Q${old_name}\E\s*\$|${sum}  ${new_name}|" "${TMP}"
        updated=$((updated+1))
    done < <(grep -E "^[0-9a-f]{64}[[:space:]]+.*$(printf '%s' "${old}" | sed 's/[.[\*^$]/\\&/g')" "${SUMS}")
done <<< "${PAIRS}"

if [ ${updated} -gt 0 ]; then
    mv "${TMP}" "${SUMS}"
fi

echo
echo "已更新 ${updated} 条校验值，失败 ${failed} 条。"
[ ${failed} -eq 0 ]
