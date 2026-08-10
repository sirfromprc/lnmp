#!/usr/bin/env bash
#
# t/consistency.sh - 跨文件一致性检查

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
pass=0

ok()   { printf 'ok   %-5s %s\n' "$1" "$2"; pass=$((pass+1)); }
bad()  { printf 'FAIL %-5s %s\n' "$1" "$2"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# V1 profile.sh 内部：菜单文本数组 与 case 分支必须指向同一版本
#
# DB_Info=('MySQL 8.0.46' ...) 和 case 里的 DB_Ver='mysql-8.0.46'
# 是两处独立维护的字符串，必须保持一致。
# ---------------------------------------------------------------------------
check_v1()
{
    local drift=''
    local v
    for v in $(grep -oE "DB_Ver='(mysql|mariadb)-[0-9.]+'" include/profile.sh \
               | sed -e "s/.*-\([0-9.]*\)'/\1/"); do
        grep -qE "(MySQL|MariaDB) ${v//./\\.}('|\W)" include/profile.sh \
            || drift="${drift} DB:${v}"
    done
    for v in $(grep -oE "Php_Ver='php-[0-9.]+'" include/profile.sh \
               | sed -e "s/.*php-\([0-9.]*\)'/\1/"); do
        grep -qE "PHP ${v//./\\.}'" include/profile.sh || drift="${drift} PHP:${v}"
    done
    for v in $(grep -oE "Apache_Ver='httpd-[0-9.]+'" include/profile.sh \
               | sed -e "s/.*httpd-\([0-9.]*\)'/\1/"); do
        grep -qE "Apache ${v//./\\.}'" include/profile.sh || drift="${drift} Apache:${v}"
    done

    if [ -z "${drift}" ]; then
        ok V1 "profile.sh 菜单文本与 case 分支版本一致"
    else
        bad V1 "菜单文本里找不到对应版本：${drift}"
    fi
}

# ---------------------------------------------------------------------------
# V2 t/probe_urls.sh 的硬编码版本列表 必须与 profile.sh 一致
# 防止探测版本与实际安装版本不一致。
# ---------------------------------------------------------------------------
check_v2()
{
    local drift='' v
    for v in $(grep -oE "Php_Ver='php-[0-9.]+'" include/profile.sh | sed -e "s/.*php-\([0-9.]*\)'/\1/"); do
        grep -qE "PHP_VERS=.*${v//./\\.}" t/probe_urls.sh || drift="${drift} PHP:${v}"
    done
    for v in $(grep -oE "DB_Ver='mysql-[0-9.]+'" include/profile.sh | sed -e "s/.*mysql-\([0-9.]*\)'/\1/"); do
        grep -qE "MYSQL_VERS=.*${v//./\\.}" t/probe_urls.sh || drift="${drift} MySQL:${v}"
    done
    for v in $(grep -oE "DB_Ver='mariadb-[0-9.]+'" include/profile.sh | sed -e "s/.*mariadb-\([0-9.]*\)'/\1/"); do
        grep -qE "MARIADB_VERS=.*${v//./\\.}" t/probe_urls.sh || drift="${drift} MariaDB:${v}"
    done

    if [ -z "${drift}" ]; then
        ok V2 "probe_urls.sh 版本列表与 profile.sh 一致"
    else
        bad V2 "probe_urls.sh 缺少：${drift}"
    fi
}

# ---------------------------------------------------------------------------
# V3 t/gen_checksums.sh 的采集列表 必须与 profile.sh 一致
# 缺少对应版本时，安装会因无校验值而中止。
# ---------------------------------------------------------------------------
check_v3()
{
    local drift='' v
    for v in $(grep -oE "Php_Ver='php-[0-9.]+'" include/profile.sh | sed -e "s/.*php-\([0-9.]*\)'/\1/"); do
        grep -qE "${v//./\\.}" t/gen_checksums.sh || drift="${drift} PHP:${v}"
    done
    for v in $(grep -oE "DB_Ver='(mysql|mariadb)-[0-9.]+'" include/profile.sh | sed -e "s/.*-\([0-9.]*\)'/\1/"); do
        grep -qE "${v//./\\.}" t/gen_checksums.sh || drift="${drift} DB:${v}"
    done

    if [ -z "${drift}" ]; then
        ok V3 "gen_checksums.sh 采集列表与 profile.sh 一致"
    else
        bad V3 "gen_checksums.sh 缺少：${drift}"
    fi
}

# ---------------------------------------------------------------------------
# V4 校验清单覆盖率：version.sh 里每个版本号都要在 checksums.sha256 里出现
#
# 校验清单完整性是 fail-closed 校验生效的前提。
#
# 例外：OpenResty 只有 PGP 签名没有 sha256（见 version.sh 注释），
# 以及少数纯 Lua 库、被 PINNED 的老依赖走别的路径。
# ---------------------------------------------------------------------------
check_v4()
{
    local missing='' key val ver
    local skip='OpenResty_Ver|OpenResty_Modules_Options|NgxBrotli_Commit|Curl_Ver|Autoconf_Ver|Libiconv_Ver|Pcre_Ver|Libzip_Ver|Freetype_New_Ver|ZendOpcache_Ver|PHPMemcached_Ver|PHP7Memcached_Ver|PHPMemcache_Ver|PHP7Memcache_Ver|PHPOldApcu_Ver|PHPApcu_Bc_Ver|PHPSodium_Ver|Libmemcached_Ver'

    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"; val="${val%\'}"; val="${val#\'}"
        echo "${key}" | grep -qE "^(${skip})$" && continue
        # 版本号形式的值才查（跳过 NgxBrotli_Ver 这种拼接出来的）
        echo "${val}" | grep -qE '[0-9]' || continue
        grep -qF "${val}" src/checksums.sha256 || missing="${missing} ${key}=${val}"
    done < <(grep -E "^[A-Za-z_]+='[^']+'$" include/version.sh)

    if [ -z "${missing}" ]; then
        ok V4 "version.sh 各组件在校验清单中均有条目"
    else
        bad V4 "校验清单缺少：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V5 Lua 组件版本耦合：lua-resty-core 声明需要的 lua-nginx-module 版本
#     必须与 version.sh 里配的那个一致
#
# 此项为离线校验，仅比较版本号编码。lua-resty-core 的 base.lua 断言形如：
#     ngx.config.ngx_lua_version ~= 10031
# 10031 = 0*1000000 + 10*1000 + 31 = lua-nginx-module 0.10.31。
# 版本不匹配会在 nginx 首次执行 Lua 时返回 500。
#
# .github/workflows/build-test.yml 通过实际编译、启动和请求执行严格校验。
# ---------------------------------------------------------------------------
check_v5()
{
    . include/version.sh 2>/dev/null || { bad V5 "无法加载 version.sh"; return; }

    local mod="${LuaNginxModule#lua-nginx-module-}"
    local core="${LuaRestyCore#lua-resty-core-}"
    local code
    code=$(echo "${mod}" | awk -F. '{printf "%d", $1*1000000 + $2*1000 + $3}')

    # 本地存在源码时读取断言，否则由 build-test 工作流执行严格校验
    local base_lua="src/${LuaRestyCore}/lib/resty/core/base.lua"
    if [ -f "${base_lua}" ]; then
        local want
        want=$(grep -oE 'ngx\.config\.ngx_lua_version[[:space:]]*~=[[:space:]]*[0-9]+' "${base_lua}" \
               | head -1 | grep -oE '[0-9]+$')
        if [ "${want}" = "${code}" ]; then
            ok V5 "lua-resty-core ${core} 与 lua-nginx-module ${mod} 配套（断言 ${code}）"
        else
            bad V5 "lua 版本不配套：resty-core ${core} 要求 ngx_lua_version=${want}，但配的是 ${mod}(=${code})"
        fi
    else
        ok V5 "lua 版本对 ${mod} / ${core}（本地无源码，严格校验由 build-test 工作流执行）"
    fi
}

# ---------------------------------------------------------------------------
# V6 数组长度断言与实际菜单项数一致
# ---------------------------------------------------------------------------
check_v6()
{
    if bash -c '. include/profile.sh' >/dev/null 2>&1; then
        ok V6 "profile.sh 可加载，数组长度断言通过"
    else
        bad V6 "profile.sh 加载失败（多半是 *_Count 与 *_Info 长度对不上）"
    fi
}

# ---------------------------------------------------------------------------
# V7 不允许出现 CRLF 换行
#
# 本项目在 Windows 上开发、在 Linux 上运行。shell 脚本只要混进 CRLF，
# 在 Linux 上会出现 `/bin/bash^M: bad interpreter` 或
# `command not found`（行尾的 \r 被当成命令的一部分）。
#
# .gitattributes 里的 `* text=auto eol=lf` 负责在提交/检出时统一，
# CI 再次检查工作区中的实际换行格式。
#
# 排除 .gif 等二进制（它们在 .gitattributes 里标了 binary）。
# ---------------------------------------------------------------------------
check_v7()
{
    local bad_files='' f
    while IFS= read -r f; do
        case "${f}" in
            *.gif|*.png|*.jpg|*.jpeg|*.ico|*.pdf|*.tar.*|*.tgz|*.zip) continue ;;
        esac
        # grep 可直接检查短文件中的 \r
        if LC_ALL=C grep -qU $'\r' "${f}" 2>/dev/null; then
            bad_files="${bad_files} ${f}"
        fi
    done < <(
        if git rev-parse --git-dir >/dev/null 2>&1; then
            git ls-files
        else
            find . -path ./.git -prune -o -path ./.claude -prune -o \
                   -path ./.upstream -prune -o -type f -print
        fi
    )

    if [ -z "${bad_files}" ]; then
        ok V7 "无 CRLF 换行"
    else
        bad V7 "以下文件含 CRLF，在 Linux 上会出问题：${bad_files}"
    fi
}

echo "=== 跨文件一致性检查 ==="
check_v1
check_v2
check_v3
check_v4
check_v5
check_v6
check_v7

echo
echo "通过 ${pass} 项，失败 ${fail} 项。"
[ ${fail} -eq 0 ]
