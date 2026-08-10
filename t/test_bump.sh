#!/usr/bin/env bash
#
# t/test_bump.sh - 自动升版的跨文件同步回归测试
#
# 背景：t/bump_version.sh 按组件分支决定要改哪些文件，各分支的文件清单是
# 分别维护的。MySQL/MariaDB 分支会同步 t/test_profile.sh，PHP 与 Apache 分支
# 曾经漏掉，结果是自动升版产出的分支能通过 t/consistency.sh，却在常规 CI 的
# 映射表单元测试上失败：故障出在升版脚本，报错却出现在测试里。
#
# 本测试对每类在 t/test_profile.sh 中有断言的组件各做一次真实升版
# （在临时副本上进行，不触碰工作区），随后执行 t/test_profile.sh。
# 只要某个分支漏掉需要同步的文件，该用例即失败。
#
# 版本号从当前 t/test_profile.sh 中提取，无需随组件升级维护本文件。

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TESTPF='t/test_profile.sh'
fail=0

# 构造一个不会与真实版本冲突的目标版本：把末段数字替换为 77777。
Fake_Next()
{
    printf '%s' "$1" | sed 's/[0-9][0-9]*$/77777/'
}

# run_case <说明> <bumps.tsv 的 key> <当前版本> <目标版本>
run_case()
{
    local desc="$1" key="$2" old="$3" new="$4"
    local work out rc

    work=$(mktemp -d) || { echo "FAIL 无法创建临时目录"; fail=1; return 1; }
    mkdir -p "${work}/include" "${work}/t" "${work}/.upstream"
    cp include/main.sh include/version.sh include/profile.sh "${work}/include/"
    cp t/bump_version.sh t/test_profile.sh t/probe_urls.sh t/gen_checksums.sh "${work}/t/"
    [ -f lnmp.conf ] && cp lnmp.conf "${work}/"

    printf '%s\t%s\t%s\tAUTO\n' "${key}" "${old}" "${new}" > "${work}/.upstream/bumps.tsv"

    if ! ( cd "${work}" && bash t/bump_version.sh --kinds AUTO ) >/dev/null 2>&1; then
        printf 'FAIL %-30s 升版脚本执行失败\n' "${desc}"
        fail=1
        rm -rf "${work}"
        return 1
    fi

    out=$( cd "${work}" && bash t/test_profile.sh 2>&1 )
    rc=$?
    if [ ${rc} -eq 0 ]; then
        printf 'ok   %-30s %s -> %s\n' "${desc}" "${old}" "${new}"
    else
        printf 'FAIL %-30s %s -> %s\n' "${desc}" "${old}" "${new}"
        printf '%s\n' "${out}" | grep '^FAIL' | sed 's/^/       /'
        echo "       升版后映射表与测试期望值不一致，"
        echo "       检查 t/bump_version.sh 中 ${key} 所属分支的文件清单。"
        fail=1
    fi
    rm -rf "${work}"
}

echo "=== 升版跨文件同步 ==="

# PHP：expect_php <编号> <分支> php-<版本> ...
while read -r br ver; do
    [ -z "${ver}" ] && continue
    run_case "PHP ${br}" "PHP_${br}" "${ver}" "$(Fake_Next "${ver}")"
done < <(awk '/^expect_php /{sub(/^php-/,"",$4); print $3, $4}' "${TESTPF}")

# Apache：check "apache<n>.ver" "httpd-<版本>"
while read -r ver; do
    [ -z "${ver}" ] && continue
    run_case "Apache" "Apache_Ver" "${ver}" "$(Fake_Next "${ver}")"
done < <(grep -oE '"httpd-[0-9.]+"' "${TESTPF}" | tr -d '"' | sed 's/^httpd-//' | sort -u)

# MySQL / MariaDB：这两类分支原本就同步 test_profile.sh，
# 纳入用例是为了防止后续重构时被一并改坏。
# expect_db <编号> <kind> <kind>-<版本> ...，key 用去掉末段的分支号。
while read -r kind ver; do
    [ -z "${ver}" ] && continue
    case "${kind}" in
        mysql)   run_case "MySQL ${ver%.*}"   "MySQL_${ver%.*}"   "${ver}" "$(Fake_Next "${ver}")" ;;
        mariadb) run_case "MariaDB ${ver%.*}" "MariaDB_${ver%.*}" "${ver}" "$(Fake_Next "${ver}")" ;;
    esac
done < <(awk '/^expect_db /{v=$4; sub(/^[a-z]+-/,"",v); print $3, v}' "${TESTPF}" | sort -u)

echo
if [ ${fail} -eq 0 ]; then
    echo "全部通过。"
else
    echo "存在失败用例。"
fi
exit ${fail}
