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

CHANGED=''      # 记录 old->new，供 refresh_checksums.sh 用
applied=0

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
                # 使用 perl 的 \Q..\E 对 old 执行字面量匹配
                perl -pi -e "s/\Q${old}\E/${new}/g" "${f}"
                echo "    ${f}"
            fi
        fi
    done
}

VERSION_SH='include/version.sh'
PROFILE_SH='include/profile.sh'
PROBE='t/probe_urls.sh'
GENSUM='t/gen_checksums.sh'
TESTPF='t/test_profile.sh'

while IFS=$'\t' read -r key old new kind; do
    [ -z "${key}" ] && continue
    case ",${KINDS}," in *",${kind},"*) ;; *) continue ;; esac

    echo "==> ${key}: ${old} -> ${new}  (${kind})"

    case "${key}" in
    PHP_*)
        # old/new 是裸版本号，如 8.3.33 -> 8.3.34
        # TESTPF 必须同步：t/test_profile.sh 里 expect_php 断言的是完整版本号，
        # 漏掉它会让升版后的常规 CI 因断言旧版本而失败。
        subst "php-${old}" "php-${new}" "${PROFILE_SH}" "${GENSUM}" "${TESTPF}"
        subst "PHP ${old}" "PHP ${new}" "${PROFILE_SH}"
        subst "${old}"     "${new}"     "${PROBE}"
        ;;
    MySQL_*)
        subst "mysql-${old}" "mysql-${new}" "${PROFILE_SH}" "${GENSUM}" "${TESTPF}"
        subst "MySQL ${old}" "MySQL ${new}" "${PROFILE_SH}"
        subst "${old}"       "${new}"       "${PROBE}"
        # 二进制包 URL 中的 MySQL-8.4/ 为分支号，无需修改
        ;;
    MariaDB_*)
        subst "mariadb-${old}" "mariadb-${new}" "${PROFILE_SH}" "${GENSUM}" "${TESTPF}"
        subst "MariaDB ${old}" "MariaDB ${new}" "${PROFILE_SH}"
        subst "${old}"         "${new}"         "${PROBE}"
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
            if grep -qE "^${key}='" "${VERSION_SH}"; then
                perl -pi -e "s/^${key}='.*'/${key}='${new}'/" "${VERSION_SH}"
                echo "    ${VERSION_SH}"
            else
                echo "    !! ${VERSION_SH} 里找不到 ${key}=，跳过" >&2
                continue
            fi
        fi
        ;;
    esac

    CHANGED="${CHANGED}${old}	${new}
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
