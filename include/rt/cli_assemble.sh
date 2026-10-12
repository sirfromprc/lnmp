#!/usr/bin/env bash
#
# 组装部署产物，输出到标准输出。
#   栈入口：conf/<栈> 中的标记行 "# @CLI_COMMON@" 替换为服务运行部分、数据库运行部分与公共层；
#   lnmp、lnmpa 的标记行 "# @CLI_NGINX@" 替换为 Nginx 适配层，lamp 不得含该行。
#   工具：tools/<文件>.sh 中以 "# @RT_SVC@"、"# @RT_FW@"、"# @RT_DB@" 结尾的加载行分别替换为
#   服务运行部分、防火墙运行部分与数据库运行部分，无加载行时原样输出。
#
# 用法：cli_assemble.sh <源码目录> <lnmp|lnmpa|lamp|tools/<文件>.sh>
# 栈入口默认取 <源码目录>/conf/<栈>，LNMP_CLI_ENTRY_DIR 可指定其所在目录（测试用）。
# 返回：0 成功；1 参数、文件或标记行不符合要求。

set -u

src="${1:-}"
target="${2:-}"
rt="${src}/include/rt"

case "${target}" in
    lnmp|lnmpa|lamp)
        entry="${LNMP_CLI_ENTRY_DIR:-${src}/conf}/${target}"
        nginx=1
        [ "${target}" = lamp ] && nginx=0
        # 标记 <TAB> 并入的文件（多个以 \034 分隔）<TAB> 应有行数（opt 表示 0 或 1）。
        rules="$(printf '# @CLI_COMMON@\t%s\034%s\034%s\t1\n# @CLI_NGINX@\t%s\t%s' \
                 "${rt}/svc.sh" "${rt}/db.sh" "${rt}/cli_common.sh" "${rt}/cli_nginx.sh" "${nginx}")"
        exact=1
        ;;
    tools/*.sh)
        entry="${src}/${target}"
        rules="$(printf '# @RT_SVC@\t%s\topt\n# @RT_FW@\t%s\topt\n# @RT_DB@\t%s\topt' \
                 "${rt}/svc.sh" "${rt}/fw.sh" "${rt}/db.sh")"
        exact=0
        ;;
    *) echo "cli_assemble.sh：未知目标 \"${target}\"" >&2; exit 1 ;;
esac

if [ ! -s "${entry}" ]; then
    echo "cli_assemble.sh：文件缺失：${entry}" >&2
    exit 1
fi

# 标记行行数必须符合要求，出现时所需文件必须存在。
while IFS="$(printf '\t')" read -r marker files want; do
    if [ "${exact}" = 1 ]; then
        n=$(grep -cxF -- "${marker}" "${entry}")
    else
        n=$(grep -c -- "${marker}\$" "${entry}")
    fi
    if [ "${want}" = opt ]; then
        want="${n}"
        [ "${n}" -le 1 ] || want='0 或 1'
    fi
    if [ "${n}" != "${want}" ]; then
        echo "cli_assemble.sh：${entry} 中标记行 ${marker} 应有 ${want} 行，实际 ${n} 行" >&2
        exit 1
    fi
    [ "${n}" -eq 0 ] && continue
    IFS="$(printf '\034')" read -r -a list <<< "${files}"
    for f in "${list[@]}"; do
        if [ ! -s "${f}" ]; then
            echo "cli_assemble.sh：文件缺失：${f}" >&2
            exit 1
        fi
    done
done <<< "${rules}"

awk -v exact="${exact}" -v rules="${rules}" '
BEGIN {
    n = split(rules, rl, "\n")
    nr = 0
    for (r = 1; r <= n; r++) {
        split(rl[r], kv, "\t")
        if (kv[3] == "0") continue
        nr++
        mk[nr] = kv[1]
        fl[nr] = kv[2]
    }
}
{
    hit = 0
    for (r = 1; r <= nr; r++) {
        if (exact == 1 && $0 == mk[r]) hit = r
        if (exact == 0 && length($0) >= length(mk[r]) && substr($0, length($0) - length(mk[r]) + 1) == mk[r]) hit = r
    }
    if (!hit) { print; next }
    nf = split(fl[hit], list, "\034")
    for (i = 1; i <= nf; i++) {
        while ((getline line < list[i]) > 0) print line
        close(list[i])
    }
}
' "${entry}"
