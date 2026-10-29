#!/usr/bin/env bash
#
# t/probe_urls.sh - 下载 URL 可达性探测
#
# 下载 URL 由各上游项目的命名规则生成，且部分上游会移除旧版本文件，
# 因此需要定期验证所引用文件的可达性。地址取自 t/list_sources.sh，
# 即生产代码各 *_Sources 的输出，本脚本不维护地址与版本。
#
# 判定复用 include/verify.sh 的 Download_Head_Probe：HEAD 失败时回退只取首字节的
# Range GET，不下载完整文件、不改动系统。同一文件有多个地址时按顺序尝试，任一可达
# 即算可下载；全部最终响应 404/410 才判为已下线。失败条目间隔 PROBE_INTERVAL 秒重试，
# 共探测 PROBE_TRIES 轮；PROBE_REPORT 指定文件时写入最终失败条目。
# 在能出网的机器上执行：bash t/probe_urls.sh
#
# 退出码：0 全部可达；1 存在已下线；2 仅有暂不可达；3 下载清单生成失败。

cd "$(dirname "$0")/.." || exit 1

Echo_Red()    { printf '%s\n' "$*" >&2; }
Echo_Yellow() { printf '%s\n' "$*" >&2; }
Echo_Green()  { printf '%s\n' "$*" >&2; }
. include/verify.sh

TIMEOUT=15
# 失败条目在本次运行内重试：总探测次数与重试间隔秒数。
PROBE_TRIES=${PROBE_TRIES:-3}
PROBE_INTERVAL=${PROBE_INTERVAL:-30}
# 非空时写入最终失败条目，每行：类别、分类、状态码、URL，TAB 分隔。
PROBE_REPORT=${PROBE_REPORT:-}
ok=0
# 先清空失败清单，清单生成失败时不残留上次结果。
[ -n "${PROBE_REPORT}" ] && : > "${PROBE_REPORT}"

if ! rows=$(bash t/list_sources.sh all); then
    echo "下载清单生成失败：bash t/list_sources.sh all" >&2
    exit 3
fi

# 按文件分组：FILES 保持清单顺序，URLS 为该文件的候选地址，每行一个。
declare -A URLS TAGS CLASS FAILS
FILES=()
while IFS=$'\t' read -r comp _ _ file url _; do
    [ -n "${file}" ] || continue
    if [ -z "${URLS[${file}]+x}" ]; then
        FILES+=("${file}")
        TAGS[${file}]=${comp}
    fi
    URLS[${file}]+="${url}"$'\n'
done <<< "${rows}"
# 失败的文件名，留待重试。
PENDING=()

probe_file()
{
    # probe_file <文件名>：逐个探测候选地址，任一可达即返回；全部失败时记录分类与各地址状态码。
    local file=$1 tag=${TAGS[$1]} url cls code all_gone=y fails=''

    while IFS= read -r url; do
        [ -n "${url}" ] || continue
        printf '%-14s %-72s ' "${tag}" "${url:0:72}"
        IFS=$'\t' read -r cls code < <(Download_Head_Probe "${url}" "${TIMEOUT}")
        if [ "${cls}" = ok ]; then
            echo "OK ${code}"
            ok=$((ok+1))
            return 0
        fi
        echo "FAIL ${code:-000}"
        [ "${cls}" = gone ] || all_gone=n
        fails+="${code:-000}"$'\t'"${url}"$'\n'
    done <<< "${URLS[${file}]}"
    if [ "${all_gone}" = y ]; then CLASS[${file}]=gone; else CLASS[${file}]=down; fi
    FAILS[${file}]=${fails}
    PENDING+=("${file}")
}

echo "=== 下载地址（t/list_sources.sh all，共 ${#FILES[@]} 个文件）==="
for file in "${FILES[@]}"; do
    probe_file "${file}"
done

try=1
while [ ${#PENDING[@]} -gt 0 ] && [ "${try}" -lt "${PROBE_TRIES}" ]; do
    try=$((try+1))
    echo
    echo "=== 第 ${try} 次探测：${#PENDING[@]} 个失败条目，${PROBE_INTERVAL} 秒后重试 ==="
    sleep "${PROBE_INTERVAL}"
    left=("${PENDING[@]}")
    PENDING=()
    for file in "${left[@]}"; do
        probe_file "${file}"
    done
done

# list_failed <类别>：输出该类别失败文件的各地址，每行：分类、状态码、URL，TAB 分隔。
list_failed()
{
    local file code url
    for file in "${PENDING[@]}"; do
        [ "${CLASS[${file}]}" = "$1" ] || continue
        while IFS=$'\t' read -r code url; do
            [ -n "${url}" ] && printf '%s\t%s\t%s\n' "${TAGS[${file}]}" "${code}" "${url}"
        done <<< "${FAILS[${file}]}"
    done
}

gone=0
down=0
for file in "${PENDING[@]}"; do
    if [ "${CLASS[${file}]}" = gone ]; then gone=$((gone+1)); else down=$((down+1)); fi
done
if [ -n "${PROBE_REPORT}" ]; then
    for cls in gone down; do
        list_failed "${cls}" | sed "s/^/${cls}\t/" >> "${PROBE_REPORT}"
    done
fi

echo
echo "============================================================"
echo "可达 ${ok} 个，已下线 ${gone} 个，暂不可达 ${down} 个（共探测 ${try} 轮）"
if [ ${gone} -gt 0 ]; then
    echo "已下线清单（全部地址最终响应为 404/410）："
    list_failed gone | while IFS=$'\t' read -r tag code url; do
        printf '  %s  %s  → HTTP %s\n' "${tag}" "${url}" "${code}"
    done
fi
if [ ${down} -gt 0 ]; then
    echo "暂不可达清单（超时、连接失败、跳转未完成或其他状态）："
    list_failed down | while IFS=$'\t' read -r tag code url; do
        if [ "${code}" = 000 ]; then
            printf '  %s  %s  → 无响应\n' "${tag}" "${url}"
        else
            printf '  %s  %s  → HTTP %s\n' "${tag}" "${url}" "${code}"
        fi
    done
fi
[ ${gone} -gt 0 ] && exit 1
[ ${down} -gt 0 ] && exit 2
exit 0
