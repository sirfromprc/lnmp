#!/usr/bin/env bash
#
# t/bump_version.sh - 应用 check_upstream.sh 生成的版本更新建议
#
# 用法：
#   bash t/bump_version.sh                 # 只应用 AUTO
#   bash t/bump_version.sh --kinds AUTO,COUPLED
#   bash t/bump_version.sh --dry-run       # 仅显示拟修改内容
#
# 读入 .upstream/bumps.tsv（由 t/check_upstream.sh 生成）。
#
# ---------------------------------------------------------------------------
# 跨文件版本同步
#
# 同一个版本号在本仓库里最多出现在 5 个功能性位置：
#
#   include/version.sh    大部分组件的唯一定义处
#   include/profile.sh    DB / PHP / Apache / phpMyAdmin，包含两处：
#                         菜单文本数组（DB_Info…）和 Set_*_Profile 的 case 分支
#   t/probe_urls.sh       硬编码的 MYSQL_VERS / MARIADB_VERS / PHP_VERS…
#   t/gen_checksums.sh    同样硬编码的采集列表
#   t/test_profile.sh     断言的期望值
#
# 各位置必须同步更新，最后由 t/consistency.sh 执行交叉检查。
# ---------------------------------------------------------------------------

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BUMPS="${OUT_DIR:-.upstream}/bumps.tsv"
KINDS='AUTO'
DRY=''

while [ $# -gt 0 ]; do
    case "$1" in
        --kinds)   KINDS="$2"; shift 2 ;;
        --dry-run) DRY='y'; shift ;;
        *)         echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

[ -s "${BUMPS}" ] || { echo "没有待应用的升级建议（${BUMPS} 为空）"; exit 0; }

CHANGED=''      # 记录 key->old->new，供 refresh_checksums.sh 按组件筛选
applied=0

valid_key()
{
    case "$1" in
        ''|[0-9]*|*[!0-9A-Za-z_.-]*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_version_value()
{
    case "$1" in
        ''|*[!0-9A-Za-z._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# 仅在指定文件中替换完整版本值，避免修改注释和示例中的版本片段。
subst()
{
    local old="$1" new="$2"; shift 2
    local f
    for f in "$@"; do
        [ -f "${f}" ] || continue
        if grep -qF -- "${old}" "${f}"; then
            if [ -n "${DRY}" ]; then
                echo "    [dry] ${f}: ${old} -> ${new}"
            else
                OLD_VALUE="${old}" NEW_VALUE="${new}" \
                    perl -pi -e 's/\Q$ENV{OLD_VALUE}\E/$ENV{NEW_VALUE}/g' "${f}"
                echo "    ${f}"
            fi
        fi
    done
}

# 只替换探测脚本里指定组件的版本，避免相同裸版本号误伤其它组件。
subst_probe()
{
    local family="$1" old="$2" new="$3"
    if [ -n "${DRY}" ]; then
        echo "    [dry] ${PROBE}: ${family} ${old} -> ${new}"
    else
        case "${family}" in
        php)
            OLD_VALUE="${old}" NEW_VALUE="${new}" perl -pi -e \
                'if (/^PHP_VERS=/ || /probe php /) { s/\Q$ENV{OLD_VALUE}\E/$ENV{NEW_VALUE}/g }' "${PROBE}"
            ;;
        mysql)
            OLD_VALUE="${old}" NEW_VALUE="${new}" perl -pi -e \
                'if (/^MYSQL_VERS=/ || /mysql-/) { s/\Q$ENV{OLD_VALUE}\E/$ENV{NEW_VALUE}/g }' "${PROBE}"
            ;;
        mariadb)
            OLD_VALUE="${old}" NEW_VALUE="${new}" perl -pi -e \
                'if (/^MARIADB_VERS=/ || /mariadb-/) { s/\Q$ENV{OLD_VALUE}\E/$ENV{NEW_VALUE}/g }' "${PROBE}"
            ;;
        *) return 1 ;;
        esac
        echo "    ${PROBE}"
    fi
}

# gen_checksums.sh 的 PHP/MariaDB 采集列表是 for-loop 里的裸版本号（如
# "for v in 8.4.24 8.5.9; do"），不是 subst() 匹配的 "prefix-版本" 字面量，
# 普通全文替换不会命中，需要按 for-loop 所在代码块定位替换。
subst_gensum_ver()
{
    local family="$1" old="$2" new="$3" before after
    if [ -n "${DRY}" ]; then
        echo "    [dry] ${GENSUM}: grab_upstream ${family} 列表 ${old} -> ${new}"
        return 0
    fi
    before=$(sha256sum "${GENSUM}" | awk '{print $1}')
    OLD_VALUE="${old}" NEW_VALUE="${new}" FAMILY="${family}" perl -0777 -pi -e '
        my $old = quotemeta($ENV{OLD_VALUE});
        my $new = $ENV{NEW_VALUE};
        my $fam = quotemeta($ENV{FAMILY});
        s/(for v in )([^\n]*)(\n\s*grab_upstream $fam )/
            my ($pre, $list, $post) = ($1, $2, $3);
            $list =~ s{(?<![\w.])$old(?![\w.])}{$new};
            $pre . $list . $post
        /e;
    ' "${GENSUM}"
    after=$(sha256sum "${GENSUM}" | awk '{print $1}')
    if [ "${before}" = "${after}" ]; then
        echo "    !! ${GENSUM} 的 ${family} 采集列表未替换 ${old}，需手工核对" >&2
        return 1
    fi
    echo "    ${GENSUM}"
}

VERSION_SH='include/version.sh'
PROFILE_SH='include/profile.sh'
PROBE='t/probe_urls.sh'
GENSUM='t/gen_checksums.sh'
TESTPF='t/test_profile.sh'

while IFS=$'\t' read -r key old new kind extra; do
    [ -z "${key}" ] && continue
    if ! valid_key "${key}" || ! valid_version_value "${old}" ||
       ! valid_version_value "${new}" || [ -n "${extra}" ]; then
        echo "拒绝非法升级建议：key=${key}, old=${old}, new=${new}" >&2
        exit 1
    fi
    case "${kind}" in
        AUTO|COUPLED|MANUAL) ;;
        *) echo "拒绝非法升级类别：${kind}" >&2; exit 1 ;;
    esac
    case ",${KINDS}," in *",${kind},"*) ;; *) continue ;; esac

    echo "==> ${key}: ${old} -> ${new}  (${kind})"

    case "${key}" in
    PHP_*)
        # old/new 是裸版本号，如 8.3.33 -> 8.3.34
        # TESTPF 必须同步：t/test_profile.sh 里 expect_php 断言的是完整版本号，
        # 漏掉它会让升版后的常规 CI 因断言旧版本而失败。
        subst "php-${old}" "php-${new}" "${PROFILE_SH}" "${TESTPF}"
        subst "PHP ${old}" "PHP ${new}" "${PROFILE_SH}"
        subst_probe php "${old}" "${new}"
        subst_gensum_ver php "${old}" "${new}"
        ;;
    MySQL_*)
        subst "mysql-${old}" "mysql-${new}" "${PROFILE_SH}" "${GENSUM}" "${TESTPF}"
        subst "MySQL ${old}" "MySQL ${new}" "${PROFILE_SH}"
        subst_probe mysql "${old}" "${new}"
        # 二进制包 URL 中的 MySQL-8.4/ 为分支号，无需修改
        ;;
    MariaDB_*)
        subst "mariadb-${old}" "mariadb-${new}" "${PROFILE_SH}" "${TESTPF}"
        subst "MariaDB ${old}" "MariaDB ${new}" "${PROFILE_SH}"
        subst_probe mariadb "${old}" "${new}"
        subst_gensum_ver mariadb "${old}" "${new}"
        ;;
    Apache_Ver)
        # 同 PHP：t/test_profile.sh 断言 httpd-<版本>，需一并更新。
        subst "httpd-${old}" "httpd-${new}" "${PROFILE_SH}" "${GENSUM}" "${PROBE}" "${TESTPF}"
        subst "Apache ${old}" "Apache ${new}" "${PROFILE_SH}"
        ;;
    PhpMyAdmin_Ver)
        subst "${old}" "${new}" "${PROFILE_SH}" "${PROBE}" "${GENSUM}"
        ;;
    *)
        # include/version.sh 中的普通变量：Key='old' -> Key='new'
        if [ -n "${DRY}" ]; then
            echo "    [dry] ${VERSION_SH}: ${key}='${new}'"
        else
            if awk -v prefix="${key}='" 'index($0, prefix) == 1 { found=1 } END { exit !found }' "${VERSION_SH}"; then
                VERSION_KEY="${key}" NEW_VALUE="${new}" perl -pi -e '
                    BEGIN { $key=$ENV{"VERSION_KEY"}; $new=$ENV{"NEW_VALUE"} }
                    if (index($_, $key . "=") == 0) {
                        $_=$key . "=" . chr(39) . $new . chr(39) . "\n"
                    }
                ' "${VERSION_SH}"
                echo "    ${VERSION_SH}"
            else
                echo "    !! ${VERSION_SH} 里找不到 ${key}=，跳过" >&2
                continue
            fi
        fi
        ;;
    esac

    CHANGED="${CHANGED}${key}	${old}	${new}
"
    applied=$((applied+1))
done < "${BUMPS}"

if [ -z "${DRY}" ]; then
    printf '%s' "${CHANGED}" > "${OUT_DIR:-.upstream}/changed.tsv"
fi

echo
echo "已应用 ${applied} 项。"
[ -n "${DRY}" ] && { echo "（dry-run，未写盘）"; exit 0; }

echo
echo "下一步："
echo "  1. bash t/refresh_checksums.sh   # 重算受影响条目的 sha256"
echo "  2. bash t/consistency.sh         # 跨文件一致性回检"
echo "  3. bash t/probe_urls.sh          # 确认新 URL 全部可达"
exit 0
