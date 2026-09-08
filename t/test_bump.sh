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

# 组件在 gen_checksums.sh 采集列表中的文件名前缀
Gensum_Prefix()
{
    case "$1" in
        PHP_*)      printf 'php-' ;;
        MySQL_*)    printf 'mysql-' ;;
        MariaDB_*)  printf 'mariadb-' ;;
        Apache_Ver) printf 'httpd-' ;;
        *)          printf '' ;;
    esac
}

# 采集列表是否跟上升版：refresh_checksums.sh 按新文件名到 gen_checksums.sh
# 取下载地址，列表漏改会让升版分支停在重算校验值这一步。
Gensum_Synced()
{
    local work="$1" key="$2" old="$3" new="$4" prefix names
    prefix=$(Gensum_Prefix "${key}")
    [ -n "${prefix}" ] || return 0
    names=$( cd "${work}" && LIST_ONLY=1 bash t/gen_checksums.sh 2>/dev/null |
             awk '$1 ~ /^https?:\/\// { print $2 }' )
    printf '%s\n' "${names}" | grep -qE "^${prefix}${new//./\\.}[-.]" || return 1
    ! printf '%s\n' "${names}" | grep -qE "^${prefix}${old//./\\.}[-.]"
}

# run_case <说明> <bumps.tsv 的 key> <当前版本> <目标版本>
run_case()
{
    local desc="$1" key="$2" old="$3" new="$4"
    local work out rc

    work=$(mktemp -d) || { echo "FAIL 无法创建临时目录"; fail=1; return 1; }
    mkdir -p "${work}/include" "${work}/t" "${work}/.upstream"
    cp include/main.sh include/version.sh include/profile.sh include/verify.sh "${work}/include/"
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
    if [ ${rc} -ne 0 ]; then
        printf 'FAIL %-30s %s -> %s\n' "${desc}" "${old}" "${new}"
        printf '%s\n' "${out}" | grep '^FAIL' | sed 's/^/       /'
        echo "       升版后映射表与测试期望值不一致，"
        echo "       检查 t/bump_version.sh 中 ${key} 所属分支的文件清单。"
        fail=1
        rm -rf "${work}"
        return 1
    fi

    if ! Gensum_Synced "${work}" "${key}" "${old}" "${new}"; then
        printf 'FAIL %-30s %s -> %s\n' "${desc}" "${old}" "${new}"
        echo "       t/gen_checksums.sh 采集列表未同步到新版本，"
        echo "       t/refresh_checksums.sh 会取不到新文件的下载地址。"
        fail=1
        rm -rf "${work}"
        return 1
    fi

    printf 'ok   %-30s %s -> %s\n' "${desc}" "${old}" "${new}"
    rm -rf "${work}"
}

run_collision_case()
{
    local work same='8.3.33' next='8.3.77777'
    work=$(mktemp -d) || { fail=1; return 1; }
    mkdir -p "${work}/include" "${work}/t" "${work}/.upstream"
    cp include/main.sh include/version.sh include/profile.sh include/verify.sh "${work}/include/"
    cp t/bump_version.sh t/test_profile.sh t/probe_urls.sh t/gen_checksums.sh "${work}/t/"
    cp lnmp.conf "${work}/"

    # 人为让 MariaDB 与 PHP 使用同一个三段版本号，再只升级 PHP。
    perl -pi -e "s/10\\.11\\.18/${same}/g" "${work}/include/profile.sh" \
        "${work}/t/probe_urls.sh" "${work}/t/gen_checksums.sh" "${work}/t/test_profile.sh"
    printf 'PHP_8.3\t%s\t%s\tAUTO\n' "${same}" "${next}" > "${work}/.upstream/bumps.tsv"

    if ( cd "${work}" && bash t/bump_version.sh --kinds AUTO ) >/dev/null 2>&1 &&
       grep -q "MARIADB_VERS='${same}" "${work}/t/probe_urls.sh" &&
       grep -q "PHP_VERS=.*${next}" "${work}/t/probe_urls.sh" &&
       grep -q $'^PHP_8.3\t8.3.33\t8.3.77777$' "${work}/.upstream/changed.tsv"; then
        printf 'ok   %-30s %s\n' '组件版本号碰撞隔离' '只修改 PHP'
    else
        printf 'FAIL %-30s %s\n' '组件版本号碰撞隔离' 'MariaDB 被误改或 changed.tsv 缺少组件键'
        fail=1
    fi
    rm -rf "${work}"
}

run_checksum_collision_case()
{
    local work old='8.3.33' new='8.3.77777' php_sum maria_sum archive_sum out
    work=$(mktemp -d) || { fail=1; return 1; }
    mkdir -p "${work}/src" "${work}/t" "${work}/include" "${work}/.upstream" "${work}/bin"
    cp t/refresh_checksums.sh "${work}/t/"
    cp include/verify.sh "${work}/include/"
    php_sum=$(printf 'a%.0s' {1..64})
    maria_sum=$(printf 'b%.0s' {1..64})
    printf '%s  php-%s.tar.bz2\n%s  mariadb-%s.tar.gz\n' \
        "${php_sum}" "${old}" "${maria_sum}" "${old}" > "${work}/src/checksums.sha256"
    printf 'PHP_8.3\t%s\t%s\n' "${old}" "${new}" > "${work}/.upstream/changed.tsv"

    cat > "${work}/t/gen_checksums.sh" <<EOF
#!/usr/bin/env bash
echo 'https://example.invalid/php-${new}.tar.bz2 php-${new}.tar.bz2'
echo 'https://example.invalid/mariadb-${new}.tar.gz mariadb-${new}.tar.gz'
EOF
    archive_sum=$(printf 'php archive' | sha256sum | awk '{print $1}')
    cat > "${work}/bin/curl" <<EOF
#!/usr/bin/env bash
url="\${!#}"
out=''
while [ \$# -gt 0 ]; do
    [ "\$1" = '-o' ] && { out="\$2"; shift 2; continue; }
    shift
done
case "\${url}" in
    *releases*) printf '%s' '{"source":[{"filename":"php-${new}.tar.gz","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"filename":"php-${new}.tar.bz2","sha256":"${archive_sum}"}]}' > "\${out}" ;;
    *) printf 'php archive' > "\${out}" ;;
esac
EOF
    chmod +x "${work}/t/gen_checksums.sh" "${work}/bin/curl"

    # 断言必须逐行整行匹配，不能用子串：两行被拼成一行时，子串 grep 仍然全部命中，
    # 会把被写坏的清单判成通过（refresh_checksums.sh 的行尾正则曾因此漏检）。
    if out=$( cd "${work}" && PATH="${work}/bin:${PATH}" bash t/refresh_checksums.sh 2>&1 ) &&
       [ "$(wc -l < "${work}/src/checksums.sha256")" -eq 2 ] &&
       [ "$(grep -cE "^[0-9a-f]{64}  [^[:space:]]+$" "${work}/src/checksums.sha256")" -eq 2 ] &&
       grep -qE "^${maria_sum}  mariadb-${old}\.tar\.gz$" "${work}/src/checksums.sha256" &&
       grep -qE "^[0-9a-f]{64}  php-${new//./\\.}\.tar\.bz2$" "${work}/src/checksums.sha256"; then
        printf 'ok   %-30s %s\n' '校验值版本碰撞隔离' '只更新 PHP，清单仍为 2 条合法行'
    else
        printf 'FAIL %-30s %s\n' '校验值版本碰撞隔离' 'MariaDB 被误选、PHP 未更新或清单行被写坏'
        printf '%s\n' "${out}" | sed 's/^/         /'
        printf '       实际清单：\n'; sed 's/^/         /' "${work}/src/checksums.sha256"
        fail=1
    fi
    rm -rf "${work}"
}

# 清单被写坏时必须拒绝写回：宁可这一步失败，也不能把坏清单交给安装流程。
run_checksum_guard_case()
{
    local work old='8.3.33' new='8.3.77777'
    work=$(mktemp -d) || { fail=1; return 1; }
    mkdir -p "${work}/src" "${work}/t" "${work}/include" "${work}/.upstream" "${work}/bin"
    cp t/refresh_checksums.sh "${work}/t/"
    cp include/verify.sh "${work}/include/"
    printf '%s  php-%s.tar.bz2\n' "$(printf 'a%.0s' {1..64})" "${old}" \
        > "${work}/src/checksums.sha256"
    printf 'PHP_8.3\t%s\t%s\n' "${old}" "${new}" > "${work}/.upstream/changed.tsv"
    cat > "${work}/t/gen_checksums.sh" <<EOF
#!/usr/bin/env bash
echo 'https://example.invalid/php-${new}.tar.bz2 php-${new}.tar.bz2'
EOF
    # sha256sum 返回一个带空格的"哈希"，逼出格式非法的清单行
    cat > "${work}/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
echo "not a valid sha256  $1"
EOF
    cat > "${work}/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
out=''
while [ $# -gt 0 ]; do [ "$1" = '-o' ] && { out="$2"; shift 2; continue; }; shift; done
case "${url}" in
    *releases*) printf '{"source":[{"filename":"php-8.3.77777.tar.gz","sha256":"%064d"},{"filename":"php-8.3.77777.tar.bz2","sha256":"%064d"}]}' 0 0 > "${out}" ;;
    *) printf 'php archive' > "${out}" ;;
esac
EOF
    chmod +x "${work}/t/gen_checksums.sh" "${work}/bin/curl" "${work}/bin/sha256sum"

    if ! ( cd "${work}" && PATH="${work}/bin:${PATH}" bash t/refresh_checksums.sh ) \
            >/dev/null 2>&1 &&
       grep -qE "^[0-9a-f]{64}  php-${old//./\\.}\.tar\.bz2$" "${work}/src/checksums.sha256"; then
        printf 'ok   %-30s %s\n' '坏清单拒绝写回' '返回非零且原清单未被覆盖'
    else
        printf 'FAIL %-30s %s\n' '坏清单拒绝写回' '格式非法的清单仍被写回或返回 0'
        fail=1
    fi
    rm -rf "${work}"
}

run_untrusted_value_case()
{
    local work marker payload
    work=$(mktemp -d) || { fail=1; return 1; }
    marker="${work}/perl-injection-ran"
    mkdir -p "${work}/include" "${work}/t" "${work}/.upstream"
    cp include/version.sh "${work}/include/"
    cp t/bump_version.sh "${work}/t/"
    printf -v payload 'x/e;system("touch %s");#' "${marker}"
    printf 'Redis_Stable_Ver\tredis-8.10.0\t%s\tAUTO\n' "${payload}" \
        > "${work}/.upstream/bumps.tsv"

    if ! ( cd "${work}" && bash t/bump_version.sh --kinds AUTO ) >/dev/null 2>&1 &&
       [ ! -e "${marker}" ] &&
       grep -qF "Redis_Stable_Ver='redis-8.10.0'" "${work}/include/version.sh"; then
        printf 'ok   %-30s %s\n' '非法上游值拒绝执行' '返回非零且文件未改动'
    else
        printf 'FAIL %-30s %s\n' '非法上游值拒绝执行' '输入未被拒绝、触发命令或改写了版本文件'
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

run_collision_case
run_checksum_collision_case
run_checksum_guard_case
run_untrusted_value_case

echo
if [ ${fail} -eq 0 ]; then
    echo "全部通过。"
else
    echo "存在失败用例。"
fi
exit ${fail}
