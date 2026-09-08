#!/usr/bin/env bash
#
# t/cleanup_branches.sh - 只保留一个最新的自动升级分支，删除其余的
#
# 用法：bash t/cleanup_branches.sh
#   GITHUB_REPOSITORY  owner/repo，GitHub Actions 自动注入，本地需自行导出。
#   KEEP_BRANCH        指定必须保留的分支名，留空则保留日期最大的一个。
#   DRY_RUN=1          只打印将要删除的分支，不实际删除。
#
# 自动升级不再开 PR，分支是唯一载体，因此按分支名里的日期判定新旧，
# 只留最新一个。auto/upstream-* 是改为不开 PR 之前的旧命名，一律回收。

set -u

New_Prefix='auto-'
Old_Prefix='auto/upstream-'
Repo="${GITHUB_REPOSITORY:-}"
Keep="${KEEP_BRANCH:-}"
Dry="${DRY_RUN:-0}"

if [ -z "${Repo}" ]; then
    echo "错误：未设置 GITHUB_REPOSITORY。" >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "错误：未找到 gh。" >&2
    exit 1
fi

if ! all_branches=$(gh api --paginate "repos/${Repo}/branches?per_page=100" --jq '.[].name' 2>&1); then
    echo "错误：读取分支列表失败：${all_branches}" >&2
    exit 1
fi

# 只认 8 位日期结尾的分支，避免误伤人工建的同前缀分支。
mapfile -t candidates < <(
    printf '%s\n' "${all_branches}" \
        | grep -E "^(${New_Prefix}|${Old_Prefix})[0-9]{8}$" || true
)

if [ "${#candidates[@]}" -eq 0 ]; then
    echo "没有自动升级分支，无需清理。"
    exit 0
fi

# 指定的保留目标不存在时（本轮无差异未推分支）必须回退，
# 否则 Keep 匹配不上任何候选，会把上一轮仍然有效的分支一起删掉。
if [ -n "${Keep}" ] && ! printf '%s\n' "${candidates[@]}" | grep -qxF "${Keep}"; then
    echo "指定保留的 ${Keep} 不存在，改为按日期保留。"
    Keep=''
fi

# 未指定保留目标时，取新命名里日期最大的一个；没有新命名分支则全部回收。
if [ -z "${Keep}" ]; then
    Keep=$(printf '%s\n' "${candidates[@]}" \
               | grep -E "^${New_Prefix}[0-9]{8}$" | sort | tail -1)
    if [ -n "${Keep}" ]; then
        echo "按日期保留：${Keep}"
    fi
fi

deleted=0
kept=0
failed=0

for b in "${candidates[@]}"; do
    if [ "${b}" = "${Keep}" ]; then
        echo "保留：${b}"
        kept=$((kept + 1))
        continue
    fi

    if [ "${Dry}" = "1" ]; then
        echo "[dry] 将删除：${b}"
        deleted=$((deleted + 1))
        continue
    fi

    if out=$(gh api -X DELETE "repos/${Repo}/git/refs/heads/${b}" 2>&1); then
        echo "已删除：${b}"
        deleted=$((deleted + 1))
    else
        echo "删除失败：${b}：${out}" >&2
        failed=$((failed + 1))
    fi
done

echo "清理结果：删除 ${deleted}，保留 ${kept}，失败 ${failed}。"
[ "${failed}" -eq 0 ]
