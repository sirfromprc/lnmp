#!/usr/bin/env bash
#
# t/check_upstream.sh - 上游版本检查
#
# 只读检查上游版本，将报告和建议清单写入 .upstream/。
# 仓库文件由 t/bump_version.sh 更新。
#
# 用法：
#   bash t/check_upstream.sh              # 全量检查
#   bash t/check_upstream.sh nginx php    # 只查指定组件
#
# 输出：
#   .upstream/bumps.tsv   建议升级清单：<变量名> <当前值> <建议值> <类别>
#   .upstream/report.md   版本检查报告
#
# 退出码：0 = 检查完成（有无升级都算成功）；1 = 检查过程本身出错。
#
# ---------------------------------------------------------------------------
# 更新类别
#
#   AUTO     可以自动升。同分支内的点版本升级，无跨组件耦合。
#   COUPLED  必须成组更新，不能单独更新。
#   MANUAL   需要人工评估的更新，仅生成报告。
#   PINNED   固定版本，不执行上游检查；理由见 include/version.sh。
#
# 新组件默认归入 MANUAL，确认可自动更新后再调整类别。
# ---------------------------------------------------------------------------

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

. include/version.sh

OUT_DIR="${OUT_DIR:-.upstream}"
mkdir -p "${OUT_DIR}"
BUMPS="${OUT_DIR}/bumps.tsv"
REPORT="${OUT_DIR}/report.md"
: > "${BUMPS}"
: > "${REPORT}"

WANT="$*"
errors=0
n_auto=0
n_coupled=0
n_manual=0

# 判断是否检查指定组件
want()
{
    [ -z "${WANT}" ] && return 0
    case " ${WANT} " in *" $1 "*) return 0 ;; esac
    return 1
}

log()  { printf '%s\n' "$*" >&2; }
note() { printf '%s\n' "$*" >> "${REPORT}"; }

# propose <变量名> <当前值> <建议值> <类别> [说明]
propose()
{
    local key="$1" cur="$2" new="$3" kind="$4" msg="${5:-}"
    [ -z "${new}" ] && return 0
    [ "${cur}" = "${new}" ] && return 0
    printf '%s\t%s\t%s\t%s\n' "${key}" "${cur}" "${new}" "${kind}" >> "${BUMPS}"
    case "${kind}" in
        AUTO)    n_auto=$((n_auto+1)) ;;
        COUPLED) n_coupled=$((n_coupled+1)) ;;
        MANUAL)  n_manual=$((n_manual+1)) ;;
    esac
    note "| \`${key}\` | ${cur} | **${new}** | ${kind} | ${msg} |"
    log "  ${kind}  ${key}: ${cur} -> ${new}"
}

# ---------------------------------------------------------------------------
# 取数工具
# ---------------------------------------------------------------------------

CURL='curl -sfL --retry 2 --retry-delay 3 --max-time 40'

gh_api()
{
    # GITHUB_TOKEN 可提高 GitHub API 的调用限额，Actions 环境应配置该变量。
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        ${CURL} -H "Accept: application/vnd.github+json" \
                -H "Authorization: Bearer ${GITHUB_TOKEN}" "$1"
    else
        ${CURL} -H "Accept: application/vnd.github+json" "$1"
    fi
}

# gh_tags <owner/repo> <ERE>：列出匹配的 tag（已去掉 v 前缀），按版本排序
gh_tags()
{
    gh_api "https://api.github.com/repos/$1/tags?per_page=100" \
        | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -e 's/.*"\(.*\)"$/\1/' -e 's/^v//' \
        | grep -E "$2" \
        | sort -V
}

# gh_latest <owner/repo> <ERE>
gh_latest() { gh_tags "$1" "$2" | tail -1; }

# url_alive <URL>：读取首字节以判断文件是否存在。
# 不用 HEAD：cdn.mysql.com、files.phpmyadmin.net 等对 HEAD 返回 403/405。
url_alive() { ${CURL} -r 0-0 -o /dev/null "$1" 2>/dev/null; }

# 列目录型站点里找最大版本： list_latest <目录URL> <文件名ERE，版本号用\1捕获>
list_latest()
{
    ${CURL} "$1" | grep -oE "$2" | sed -E "s/$2/\1/" | sort -V | uniq | tail -1
}

note "| 组件 | 当前 | 可升级到 | 类别 | 说明 |"
note "| --- | --- | --- | --- | --- |"

# ---------------------------------------------------------------------------
# 1. Lua 组件：按耦合组检查
#
# lua-resty-core 的 lib/resty/core/base.lua 包含以下断言：
#
#     or ngx.config.ngx_lua_version ~= 10032
#     ...
#     error("ngx_http_lua_module 0.10.32 required but got " .. ver)
#
# 10032 = lua-nginx-module 0.10.32（编码规则 major*1000000+minor*1000+patch）。
# 该断言在 nginx 运行 Lua 代码时触发，编译阶段无法发现版本不匹配。
#
# 先确定 lua-nginx-module 的目标版本，再查找声明依赖该版本的
# lua-resty-core tag；只有两个版本均确认后才生成更新建议。
#
# lua-resty-core 可能先发布 rc 版本（当前版本为 0.1.34rc3）：
# 新的 lua-nginx-module 发布后，配套的 resty-core 往往只有 rc，
# 此时应以版本断言的匹配结果为准，不能直接沿用上一个正式版。
# ---------------------------------------------------------------------------
check_lua_stack()
{
    want lua || return 0
    log "检查 Lua 全家桶（耦合组）..."

    local cur_mod="${LuaNginxModule#lua-nginx-module-}"
    local cur_core="${LuaRestyCore#lua-resty-core-}"

    local new_mod
    new_mod=$(gh_latest openresty/lua-nginx-module '^0\.10\.[0-9]+$')
    if [ -z "${new_mod}" ]; then
        log "  !! 取 lua-nginx-module tag 失败"
        errors=$((errors+1))
        return 0
    fi

    if [ "${new_mod}" = "${cur_mod}" ]; then
        log "  lua-nginx-module 已是最新 (${cur_mod})，整组不动"
        return 0
    fi

    # 目标模块版本编码成 base.lua 里那个整数
    local want_code
    want_code=$(echo "${new_mod}" | awk -F. '{printf "%d", $1*1000000 + $2*1000 + $3}')

    # 从最近 10 个 resty-core tag 中查找断言匹配 want_code 的版本。
    local candidate matched=''
    for candidate in $(gh_tags openresty/lua-resty-core '^0\.1\.[0-9]+' | tail -10 | tac); do
        local base_lua
        base_lua=$(${CURL} "https://raw.githubusercontent.com/openresty/lua-resty-core/v${candidate}/lib/resty/core/base.lua")
        [ -z "${base_lua}" ] && continue
        # 第一处 ngx_lua_version 断言就是 http 子系统的那条
        local code
        code=$(printf '%s' "${base_lua}" \
               | grep -oE 'ngx\.config\.ngx_lua_version[[:space:]]*~=[[:space:]]*[0-9]+' \
               | head -1 | grep -oE '[0-9]+$')
        if [ "${code}" = "${want_code}" ]; then
            matched="${candidate}"
            break
        fi
    done

    if [ -z "${matched}" ]; then
        note "| Lua 全家桶 | mod ${cur_mod} / core ${cur_core} | — | COUPLED | \
lua-nginx-module 有新版 ${new_mod}，但**尚未找到声明配套的 lua-resty-core**，整组保持不动 |"
        n_coupled=$((n_coupled+1))
        log "  lua-nginx-module ${new_mod} 已发布，但没有配套的 lua-resty-core，整组不动"
        return 0
    fi

    # 双向确认：模块 tag 也必须真的存在
    if ! url_alive "https://github.com/openresty/lua-nginx-module/archive/refs/tags/v${new_mod}.tar.gz"; then
        log "  !! lua-nginx-module v${new_mod} 归档不可达，整组不动"
        errors=$((errors+1))
        return 0
    fi

    propose LuaNginxModule "${LuaNginxModule}" "lua-nginx-module-${new_mod}" COUPLED \
        "base.lua 断言 ngx_lua_version == ${want_code}"
    propose LuaRestyCore "${LuaRestyCore}" "lua-resty-core-${matched}" COUPLED \
        "该 tag 的 base.lua 声明需要 lua-nginx-module ${new_mod}"

    # lrucache 与 luajit2 同属该运行时组件组，一并更新。
    local new_lru new_jit
    new_lru=$(gh_latest openresty/lua-resty-lrucache '^0\.[0-9.]+$')
    new_jit=$(gh_latest openresty/luajit2 '^2\.1-[0-9]{8}$')
    propose LuaRestyLrucache "${LuaRestyLrucache}" "lua-resty-lrucache-${new_lru}" COUPLED "随全家桶同升"
    propose Luajit_Ver "${Luajit_Ver}" "luajit2-${new_jit}" COUPLED "随全家桶同升"
}

# ---------------------------------------------------------------------------
# 2. nginx：仅跟踪 stable 分支
#
# nginx 的次版本号偶数为 stable、奇数为 mainline。本项目跟 stable，
# 所以只在当前分支内找更高的点版本，不得跨分支。
# 跨分支更新（如 1.30 -> 1.32）需要人工评估。
#
# nginx.org 可能移除旧点版本，因此需要 url-health 工作流检查可达性。
# ---------------------------------------------------------------------------
check_nginx()
{
    want nginx || return 0
    log "检查 nginx..."
    local cur="${Nginx_Ver#nginx-}"
    local branch="${cur%.*}"          # 1.30.4 -> 1.30
    local latest
    latest=$(list_latest "https://nginx.org/download/" \
             "nginx-(${branch//./\\.}\.[0-9]+)\.tar\.gz")
    propose Nginx_Ver "${Nginx_Ver}" "nginx-${latest}" AUTO "stable ${branch} 分支内点版本"

    # 新 stable 分支仅生成提示，不自动更新
    local newest_branch
    newest_branch=$(list_latest "https://nginx.org/download/" 'nginx-([0-9]+\.[0-9]*[02468]\.[0-9]+)\.tar\.gz')
    if [ -n "${newest_branch}" ] && [ "${newest_branch%.*}" != "${branch}" ]; then
        note "| \`Nginx_Ver\` | ${cur} | ${newest_branch} | MANUAL | \
出现了新的 stable 分支 ${newest_branch%.*}，换分支需人工评估第三方模块兼容性 |"
        n_manual=$((n_manual+1))
    fi
}

# ---------------------------------------------------------------------------
# 3. OpenSSL：固定在 3.5 LTS 分支
# 不跟踪 3.6+/4.x；仅自动更新 3.5 LTS 分支内的点版本。
# ---------------------------------------------------------------------------
check_openssl()
{
    want openssl || return 0
    log "检查 OpenSSL..."
    local cur="${Openssl_New_Ver#openssl-}"
    local branch="${cur%.*}"
    local latest
    latest=$(gh_latest openssl/openssl "^openssl-${branch//./\\.}\.[0-9]+$")
    latest="${latest#openssl-}"
    propose Openssl_New_Ver "${Openssl_New_Ver}" "openssl-${latest}" AUTO "${branch} LTS 分支内"
}

# ---------------------------------------------------------------------------
# 4. PHP：六个分支分别更新点版本
# 版本号同时出现在 include/profile.sh 的 PHP_Info 数组和 Set_PHP_Profile 的
# case 分支里，还有 t/probe_urls.sh 的 PHP_VERS，三处必须一起改
# （由 t/bump_version.sh 保证）。
# ---------------------------------------------------------------------------
check_php()
{
    want php || return 0
    log "检查 PHP..."
    local br cur latest
    for br in 8.0 8.1 8.2 8.3 8.4 8.5; do
        cur=$(grep -oE "php-${br//./\\.}\.[0-9]+" include/profile.sh | head -1)
        cur="${cur#php-}"
        [ -z "${cur}" ] && continue
# PHP API 存在两种返回结构：
        #   ?json&version=8.3   直接返回该分支最新版的对象，没有 version 字段
        #   ?json&max=1&version=8  返回以版本号为键的对象
        # 从文件名解析版本号以兼容两种结构。
        latest=$(${CURL} "https://www.php.net/releases/index.php?json&version=${br}" \
                 | grep -oE "php-${br//./\\.}\.[0-9]+\.tar\.gz" \
                 | head -1 | sed -e 's/^php-//' -e 's/\.tar\.gz$//')
        # PHP 8.0 已 EOL，API 可能不再返回该分支
        [ -z "${latest}" ] && continue
        propose "PHP_${br}" "${cur}" "${latest}" AUTO "profile.sh + probe_urls.sh 三处同步"
    done
}

# ---------------------------------------------------------------------------
# 5. MySQL：cdn.mysql.com 没有版本 API，逐个探测候选版本
# 从当前点版本开始递增探测，连续 3 个版本不存在时停止。
# 仅检查 8.0 和 8.4 LTS 分支，不跨到 9.x innovation 分支。
# ---------------------------------------------------------------------------
check_mysql()
{
    want mysql || return 0
    log "检查 MySQL..."
    local br cur best n miss
    for br in 8.0 8.4; do
        cur=$(grep -oE "mysql-${br//./\\.}\.[0-9]+" include/profile.sh | head -1)
        cur="${cur#mysql-}"
        [ -z "${cur}" ] && continue
        best="${cur##*.}"; n=$((best+1)); miss=0
        while [ ${miss} -lt 3 ]; do
            if url_alive "https://cdn.mysql.com/Downloads/MySQL-${br}/mysql-${br}.${n}.tar.gz"; then
                best="${n}"; miss=0
            else
                miss=$((miss+1))
            fi
            n=$((n+1))
        done
        propose "MySQL_${br}" "${cur}" "${br}.${best}" AUTO "源码包与二进制包一并探测"
    done
}

# ---------------------------------------------------------------------------
# 6. MariaDB：通过官方 REST API 分别跟踪三个 LTS 系列
# ---------------------------------------------------------------------------
check_mariadb()
{
    want mariadb || return 0
    log "检查 MariaDB..."
    local series cur latest
    for series in 10.11 11.4 11.8; do
        cur=$(grep -oE "MariaDB ${series//./\\.}\.[0-9]+" include/profile.sh | head -1)
        cur="${cur#MariaDB }"
        [ -z "${cur}" ] && continue
        latest=$(${CURL} "https://downloads.mariadb.org/rest-api/mariadb/${series}/" \
                 | grep -oE "\"${series//./\\.}\.[0-9]+\"" | tr -d '"' | sort -V | tail -1)
        propose "MariaDB_${series}" "${cur}" "${latest}" AUTO ""
    done
}

# ---------------------------------------------------------------------------
# 7. 其余组件按上游类型分组检查
# ---------------------------------------------------------------------------
check_misc()
{
    local latest

    if want apache; then
        log "检查 Apache..."
        local cur; cur=$(grep -oE 'Apache 2\.4\.[0-9]+' include/profile.sh | head -1); cur="${cur#Apache }"
        latest=$(list_latest "https://downloads.apache.org/httpd/" 'httpd-(2\.4\.[0-9]+)\.tar\.bz2')
        propose Apache_Ver "${cur}" "${latest}" AUTO "2.4 分支内"
    fi

    if want phpmyadmin; then
        log "检查 phpMyAdmin..."
        latest=$(${CURL} "https://www.phpmyadmin.net/home_page/version.json" \
                 | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' \
                 | sed -e 's/.*"\(.*\)"$/\1/' | head -1)
        propose PhpMyAdmin_Ver "${PhpMyAdmin_Ver}" \
                "phpMyAdmin-${latest}-all-languages" AUTO ""
    fi

    if want openresty; then
        log "检查 OpenResty..."
        latest=$(list_latest "https://openresty.org/download/" 'openresty-([0-9.]+)\.tar\.gz')
        propose OpenResty_Ver "${OpenResty_Ver}" "openresty-${latest}" MANUAL \
                "自带 nginx 版本会变，且**不进 checksums（只有 PGP 签名）**，升级前确认签名密钥未变"
    fi

    if want redis; then
        latest=$(gh_latest redis/redis '^[0-9]+\.[0-9]+\.[0-9]+$')
        propose Redis_Stable_Ver "${Redis_Stable_Ver}" "redis-${latest}" AUTO ""
    fi
    if want memcached; then
        latest=$(gh_latest memcached/memcached '^[0-9]+\.[0-9]+\.[0-9]+$')
        propose Memcached_Ver "${Memcached_Ver}" "memcached-${latest}" AUTO ""
    fi
    if want pureftpd; then
        latest=$(gh_latest jedisct1/pure-ftpd '^[0-9]+\.[0-9]+\.[0-9]+$')
        propose Pureftpd_Ver "${Pureftpd_Ver}" "pure-ftpd-${latest}" AUTO ""
    fi
    if want nghttp2; then
        latest=$(gh_latest nghttp2/nghttp2 '^[0-9]+\.[0-9]+\.[0-9]+$')
        propose Nghttp2_Ver "${Nghttp2_Ver}" "nghttp2-${latest}" AUTO ""
    fi
    if want jemalloc; then
        latest=$(gh_latest jemalloc/jemalloc '^[0-9]+\.[0-9]+\.[0-9]+$')
        propose Jemalloc_Ver "${Jemalloc_Ver}" "jemalloc-${latest}" AUTO ""
    fi
    if want gperftools; then
        latest=$(gh_latest gperftools/gperftools '^[0-9]+\.[0-9]+(\.[0-9]+)?$')
        propose TCMalloc_Ver "${TCMalloc_Ver}" "gperftools-${latest}" AUTO ""
        latest=$(gh_latest libunwind/libunwind '^[0-9]+\.[0-9]+(\.[0-9]+)?$')
        propose Libunwind_Ver "${Libunwind_Ver}" "libunwind-${latest}" AUTO ""
    fi
    if want imagemagick; then
        latest=$(gh_latest ImageMagick/ImageMagick '^7\.[0-9.]+-[0-9]+$')
        propose ImageMagick_Ver "${ImageMagick_Ver}" "ImageMagick-${latest}" AUTO ""
    fi

# PECL 扩展通过官方 stable.txt 获取版本
    if want pecl; then
        log "检查 PECL 扩展..."
        # stable.txt 可能返回预发布版本；包含字母的版本号不自动采用。
        pecl_stable()
        {
            local v
            v=$(${CURL} "https://pecl.php.net/rest/r/$1/stable.txt" | tr -d '[:space:]')
            case "${v}" in
                ''|*[!0-9.]*)
                    [ -n "${v}" ] && log "  跳过 $1：上游当前只有预发布版 ${v}"
                    return 0 ;;
            esac
            printf '%s' "${v}"
        }
        # 未取得正式版时跳过，避免生成缺少版本号的更新值。
        pecl_propose()
        {
            # pecl_propose <变量名> <当前值> <pecl包名> <前缀> [说明]
            local v; v=$(pecl_stable "$3")
            [ -n "${v}" ] || return 0
            propose "$1" "$2" "$4${v}" AUTO "${5:-}"
        }
        pecl_propose PHPRedis_Ver      "${PHPRedis_Ver}"      redis     'redis-'
        pecl_propose PHPIgbinary_Ver   "${PHPIgbinary_Ver}"   igbinary  'igbinary-' "必须先于 phpredis 编译"
        pecl_propose PHPSwoole_Ver     "${PHPSwoole_Ver}"     swoole    'swoole-'
        pecl_propose PHPNewApcu_Ver    "${PHPNewApcu_Ver}"    apcu      'apcu-'
        pecl_propose Imagick_Ver       "${Imagick_Ver}"       imagick   'imagick-'
        pecl_propose PHP8Memcached_Ver "${PHP8Memcached_Ver}" memcached 'memcached-'
    fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
log "=== 上游版本检查开始 $(date '+%F %T') ==="
check_lua_stack
check_nginx
check_openssl
check_php
check_mysql
check_mariadb
check_misc

# 在报告中列出 PINNED 组件，说明未检查原因
cat >> "${REPORT}" <<'EOF'

### 故意不查的（PINNED）

| 组件 | 锁定值 | 理由 |
| --- | --- | --- |
| `Pcre_Ver` | pcre-8.45 | PCRE1 的最终版，上游已终止；换 PCRE2 是改造不是升级 |
| `NgxBrotli_Commit` | a71f9312… | 上游只有一个 2021 年的 rc tag，固定到具体 commit 才能保证 sha256 稳定 |
| `NgxCachePurge_Ver` | 2.3 | 原仓库停更于此，用户指定 |
| `Libmemcached_Ver` | 1.0.18 | 上游停更，且需要打 gcc7 补丁 |
| `Autoconf_Ver` | 2.13 | 只服务少数老编译路径，升级会破坏它们 |
| `Curl_Ver` | 7.62.0 | 仅编译期依赖的特定路径使用，升级需人工确认调用点 |
| `ZendOpcache_Ver` / `PHP7*` / `PHPOldApcu_Ver` | — | 服务 PHP 7 及更早，本包只发 PHP 8.x，留作兼容路径 |
EOF

{
    echo
    echo "---"
    echo
    echo "**汇总**：可自动升 ${n_auto} 项，耦合组 ${n_coupled} 项，需人工判断 ${n_manual} 项。"
    if [ ${errors} -gt 0 ]; then
        echo
        echo "⚠ 检查过程中有 ${errors} 处取数失败，上面的结论可能不完整。"
    fi
} >> "${REPORT}"

log "=== 检查完成：AUTO ${n_auto} / COUPLED ${n_coupled} / MANUAL ${n_manual}，取数失败 ${errors} ==="
log "清单：${BUMPS}"
log "报告：${REPORT}"
exit 0
