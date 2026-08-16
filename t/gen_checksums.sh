#!/usr/bin/env bash
#
# t/gen_checksums.sh - 采集 src/checksums.sha256 所需的哈希
#
# 用法（在可信且可访问外网的环境中执行）：
#   bash t/gen_checksums.sh            # 全量
#   bash t/gen_checksums.sh core       # 仅处理默认 lnmp 安装路径所需组件
#
# 输出直接就是 checksums.sha256 的正文格式，重定向覆盖即可：
#   bash t/gen_checksums.sh > /tmp/sums.txt
#
# ---------------------------------------------------------------------------
# 信任模型
#
# 本脚本下载文件后计算哈希，不能独立证明文件未被篡改。生成的清单用于
# 验证后续下载内容与采集时的文件是否一致。
#
# 来源可信度由以下措施提供：
#   1. 全部走 HTTPS 上游官方域名（见 t/lint.sh 的 C9 / C13）
#   2. 有官方公布校验值的组件，下面会额外做交叉核对（标 [x-check]）
#
# 应在可信网络环境中生成清单。
# ---------------------------------------------------------------------------

cd "$(dirname "$0")/.." || exit 1
. include/version.sh

cur_dir=$(pwd)
Echo_Red()    { printf '%s\n' "$*" >&2; }
Echo_Yellow() { printf '%s\n' "$*" >&2; }
Echo_Green()  { printf '%s\n' "$*" >&2; }
. include/verify.sh

SCOPE="${1:-all}"
WORK=$(mktemp -d /tmp/lnmp-sums.XXXXXX)
trap 'rm -rf "${WORK}"' EXIT

ok=0
bad=0
XCHECK_LOG=''

# ---------------------------------------------------------------------------
# grab <URL> <保存文件名> [官方公布的sha256]
#
# 保存文件名必须与 Download_Files 的第二个参数完全一致。校验按
# 落地文件名查表的，URL 的 basename 常常不同（GitHub tag 归档尤其明显：
# URL 是 v0.33.tar.gz，落地名是 lua-resty-redis-0.33.tar.gz）。
#
# 计算哈希后立即删除下载文件，控制临时磁盘占用。
# ---------------------------------------------------------------------------
grab()
{
    local url="$1" name="$2" want="${3:-}" sum

    # LIST_ONLY=1：只把「URL 落地文件名」打印出来，不下载、不算哈希。
    # t/refresh_checksums.sh 通过该模式读取本文件维护的下载地址。
    if [ -n "${LIST_ONLY:-}" ]; then
        printf '%s %s\n' "${url}" "${name}"
        return 0
    fi

    if ! Download_Fetch "${url}" "${WORK}/${name}" >/dev/null; then
        echo "# !! 下载失败: ${name}  <- ${url}" >&2
        bad=$((bad+1))
        rm -f "${WORK}/${name}"
        return 1
    fi

    sum=$(sha256sum "${WORK}/${name}" | awk '{print $1}')
    rm -f "${WORK}/${name}"

    if [ -n "${want}" ]; then
        if [ "${sum}" = "${want}" ]; then
            XCHECK_LOG="${XCHECK_LOG}
#   [x-check ok] ${name}"
        else
            echo "# !! 交叉核对失败: ${name}" >&2
            echo "# !!   官方公布: ${want}" >&2
            echo "# !!   实际下载: ${sum}" >&2
            bad=$((bad+1))
            return 1
        fi
    fi

    printf '%s  %s\n' "${sum}" "${name}"
    ok=$((ok+1))
}

# 官方为该文件提供 SHA256 时，取不到或不匹配都必须失败。
grab_upstream()
{
    local project="$1" ver="$2" url="$3" name="$4" want

    if [ -n "${LIST_ONLY:-}" ]; then
        grab "${url}" "${name}"
        return $?
    fi
    want=$(Upstream_SHA256 "${project}" "${ver}" "${name}")
    if ! echo "${want}" | grep -Eq '^[0-9a-f]{64}$'; then
        echo "# !! 无法取得 ${name} 的上游 SHA256" >&2
        bad=$((bad+1))
        return 1
    fi
    grab "${url}" "${name}" "${want}"
}

grab_published()
{
    local url="$1" name="$2" sum_url="$3" want

    if [ -n "${LIST_ONLY:-}" ]; then
        grab "${url}" "${name}"
        return $?
    fi
    want=$(fetch_sum "${sum_url}")
    if ! echo "${want}" | grep -Eq '^[0-9a-f]{64}$'; then
        echo "# !! 无法取得 ${name} 的上游 SHA256" >&2
        bad=$((bad+1))
        return 1
    fi
    grab "${url}" "${name}" "${want}"
}

grab_nginx()
{
    local url="$1" name="$2" sum

    if [ -n "${LIST_ONLY:-}" ]; then
        grab "${url}" "${name}"
        return $?
    fi
    if ! Download_Fetch "${url}" "${WORK}/${name}" >/dev/null; then
        echo "# !! 下载失败: ${name}  <- ${url}" >&2
        bad=$((bad+1))
        rm -f "${WORK}/${name}"
        return 1
    fi
    if ! Verify_Nginx_Signature "${WORK}/${name}" "${url}" >/dev/null; then
        echo "# !! PGP 交叉核对失败: ${name}" >&2
        bad=$((bad+1))
        rm -f "${WORK}/${name}"
        return 1
    fi
    sum=$(sha256sum "${WORK}/${name}" | awk '{print $1}')
    rm -f "${WORK}/${name}"
    printf '%s  %s\n' "${sum}" "${name}"
    XCHECK_LOG="${XCHECK_LOG}
#   [x-check ok] ${name} (PGP)"
    ok=$((ok+1))
}

grab_mysql()
{
    # 与 DB_Download_Files 一致：先用当前下载区，失败后查 archives。
    # LIST_ONLY 用于升版后的增量校验，新版本应优先从 Downloads 获取。
    local branch="$1" name="$2"
    local primary="https://cdn.mysql.com/Downloads/MySQL-${branch}/${name}"
    local fallback="https://cdn.mysql.com/archives/mysql-${branch}/${name}"

    if [ -n "${LIST_ONLY:-}" ]; then
        grab "${primary}" "${name}"
    elif wget -q --spider --timeout=30 --tries=1 --max-redirect=10 "${primary}"; then
        grab "${primary}" "${name}"
    else
        grab "${fallback}" "${name}"
    fi
}

# 获取上游公布的校验值。
fetch_sum()
{
    local tmp sum=''
    # LIST_ONLY 模式不联网
    [ -n "${LIST_ONLY:-}" ] && return 0
    tmp=$(mktemp "${WORK}/published.XXXXXX") || return 1
    if Download_Fetch "$1" "${tmp}" >/dev/null 2>&1; then
        sum=$(grep -oiE '[0-9a-f]{64}' "${tmp}" | head -1)
    fi
    rm -f "${tmp}"
    printf '%s' "${sum}"
}

echo "# ======================================================================"
echo "# 由 t/gen_checksums.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "# 采集范围: ${SCOPE}"
echo "# ======================================================================"
echo

echo "# --- 基础库 ---"
grab_nginx "https://nginx.org/download/${Nginx_Ver}.tar.gz" "${Nginx_Ver}.tar.gz"
grab_published \
    "https://github.com/openssl/openssl/releases/download/${Openssl_New_Ver}/${Openssl_New_Ver}.tar.gz" \
    "${Openssl_New_Ver}.tar.gz" \
    "https://github.com/openssl/openssl/releases/download/${Openssl_New_Ver}/${Openssl_New_Ver}.tar.gz.sha256"
grab "https://downloads.sourceforge.net/pcre/${Pcre_Ver}.tar.bz2" "${Pcre_Ver}.tar.bz2"
grab "https://ftp.gnu.org/gnu/libiconv/${Libiconv_Ver}.tar.gz" "${Libiconv_Ver}.tar.gz"
grab "https://ftp.gnu.org/gnu/autoconf/${Autoconf_Ver}.tar.gz" "${Autoconf_Ver}.tar.gz"
grab "https://curl.se/download/${Curl_Ver}.tar.bz2" "${Curl_Ver}.tar.bz2"
grab "https://downloads.sourceforge.net/freetype/${Freetype_New_Ver}.tar.xz" "${Freetype_New_Ver}.tar.xz"
grab "https://libzip.org/download/${Libzip_Ver}.tar.xz" "${Libzip_Ver}.tar.xz"

echo
echo "# --- PHP（php.net 官方 releases API 有公布 sha256，逐个交叉核对）---"
for v in 8.0.30 8.1.34 8.2.33 8.3.33 8.4.24 8.5.9; do
    grab_upstream php "${v}" "https://www.php.net/distributions/php-${v}.tar.bz2" "php-${v}.tar.bz2"
done

echo
echo "# --- MySQL ---"
grab_mysql 8.0 mysql-8.0.46.tar.gz
grab_mysql 8.4 mysql-8.4.7.tar.gz
grab_mysql 8.0 mysql-8.0.46-linux-glibc2.28-x86_64.tar.xz
grab_mysql 8.4 mysql-8.4.7-linux-glibc2.17-x86_64.tar.xz

echo
echo "# --- MariaDB ---"
for v in 10.11.18 11.4.12 11.8.8; do
    grab_upstream mariadb "${v}" \
        "https://downloads.mariadb.org/rest-api/mariadb/${v}/mariadb-${v}.tar.gz" \
        "mariadb-${v}.tar.gz"
    grab_upstream mariadb "${v}" \
        "https://downloads.mariadb.org/rest-api/mariadb/${v}/mariadb-${v}-linux-systemd-x86_64.tar.gz" \
        "mariadb-${v}-linux-systemd-x86_64.tar.gz"
done

echo
echo "# --- boost（MySQL 源码编译用）---"
for boost in "${Boost_Ver}" "${Boost_New_Ver}"; do
    boost_ver=$(echo "${boost#boost_}" | tr '_' '.')
    grab "https://archives.boost.io/release/${boost_ver}/source/${boost}.tar.bz2" "${boost}.tar.bz2"
done

if [ "${SCOPE}" = "core" ]; then
    echo
    echo "# （core 模式，可选组件未采集）"
    echo "# 成功 ${ok} 项，失败 ${bad} 项" >&2
    [ ${bad} -eq 0 ]
    exit $?
fi

echo
echo "# --- Apache / phpMyAdmin ---"
# phpMyAdmin 版本在 profile.sh 里（由 Set_PHP_Profile 填充），本脚本只 source
# 了 version.sh，因此从映射表中读取，避免重复维护版本号。
PMA_FULL=$(grep -oE 'phpMyAdmin-[0-9.]+-all-languages' include/profile.sh | head -1)
PMA_NUM="${PMA_FULL#phpMyAdmin-}"; PMA_NUM="${PMA_NUM%-all-languages}"
grab_published "https://archive.apache.org/dist/httpd/httpd-2.4.68.tar.bz2" \
    "httpd-2.4.68.tar.bz2" \
    "https://archive.apache.org/dist/httpd/httpd-2.4.68.tar.bz2.sha256"
grab_published "https://archive.apache.org/dist/apr/${APR_Ver}.tar.bz2" \
    "${APR_Ver}.tar.bz2" \
    "https://archive.apache.org/dist/apr/${APR_Ver}.tar.bz2.sha256"
grab_published "https://archive.apache.org/dist/apr/${APR_Util_Ver}.tar.bz2" \
    "${APR_Util_Ver}.tar.bz2" \
    "https://archive.apache.org/dist/apr/${APR_Util_Ver}.tar.bz2.sha256"
grab_upstream phpmyadmin "${PMA_NUM}" \
    "https://files.phpmyadmin.net/phpMyAdmin/${PMA_NUM}/phpMyAdmin-${PMA_NUM}-all-languages.tar.xz" \
    "phpMyAdmin-${PMA_NUM}-all-languages.tar.xz"

echo
echo "# --- 内存分配器 ---"
grab "https://github.com/jemalloc/jemalloc/releases/download/${Jemalloc_Ver#jemalloc-}/${Jemalloc_Ver}.tar.bz2" "${Jemalloc_Ver}.tar.bz2"
grab "https://github.com/gperftools/gperftools/releases/download/${TCMalloc_Ver}/${TCMalloc_Ver}.tar.gz" "${TCMalloc_Ver}.tar.gz"
grab "https://github.com/libunwind/libunwind/releases/download/v${Libunwind_Ver#libunwind-}/${Libunwind_Ver}.tar.gz" "${Libunwind_Ver}.tar.gz"

echo
echo "# --- nginx 模块 ---"
grab "https://github.com/nghttp2/nghttp2/releases/download/v${Nghttp2_Ver#nghttp2-}/${Nghttp2_Ver}.tar.xz" "${Nghttp2_Ver}.tar.xz"
grab "https://github.com/aperezdc/ngx-fancyindex/releases/download/v${NgxFancyIndex_Ver#ngx-fancyindex-}/${NgxFancyIndex_Ver}.tar.xz" "${NgxFancyIndex_Ver}.tar.xz"
grab "https://github.com/openresty/luajit2/archive/refs/tags/v${Luajit_Ver#luajit2-}.tar.gz" "${Luajit_Ver}.tar.gz"
grab "https://github.com/openresty/lua-nginx-module/archive/refs/tags/v${LuaNginxModule#lua-nginx-module-}.tar.gz" "${LuaNginxModule}.tar.gz"
grab "https://github.com/vision5/ngx_devel_kit/archive/refs/tags/v${NgxDevelKit#ngx_devel_kit-}.tar.gz" "${NgxDevelKit}.tar.gz"
grab "https://github.com/openresty/lua-cjson/archive/refs/tags/${LuaCjson#lua-cjson-}.tar.gz" "${LuaCjson}.tar.gz"
grab "https://github.com/google/ngx_brotli/archive/${NgxBrotli_Commit}.tar.gz" "${NgxBrotli_Ver}.tar.gz"
grab "https://github.com/FRiCKLE/ngx_cache_purge/archive/${NgxCachePurge_Ver#ngx_cache_purge-}.tar.gz" "${NgxCachePurge_Ver}.tar.gz"

echo
echo "# --- lua-resty-* （纯 Lua 库）---"
for lib in "${LuaRestyCore}" "${LuaRestyLrucache}" "${LuaRestyLock}" "${LuaRestyString}" \
           "${LuaRestyRedis}" "${LuaRestyMysql}" "${LuaRestyUpload}" \
           "${LuaRestyWebsocket}" "${LuaRestyDns}" "${LuaRestyMemcached}" \
           "${LuaRestyLimitTraffic}"; do
    # 正则需匹配预发布后缀，否则无法从文件名中正确提取仓库名。
    repo=$(echo "${lib}" | sed -E 's/-[0-9][0-9.]*([a-zA-Z]+[0-9]*)?$//')
    grab "https://github.com/openresty/${repo}/archive/refs/tags/v${lib##${repo}-}.tar.gz" "${lib}.tar.gz"
done

echo
echo "# --- PHP 扩展（pecl）---"
for p in "${PHPNewApcu_Ver}" "${Imagick_Ver}" "${PHPSwoole_Ver}" "${PHP8Memcache_Ver}" \
         "${PHP8Memcached_Ver}" "${PHPRedis_Ver}" "${PHPIgbinary_Ver}"; do
    grab "https://pecl.php.net/get/${p}.tgz" "${p}.tgz"
done

echo
echo "# --- 其他服务 ---"
grab "https://memcached.org/files/${Memcached_Ver}.tar.gz" "${Memcached_Ver}.tar.gz"
grab "https://launchpad.net/libmemcached/1.0/${Libmemcached_Ver#libmemcached-}/+download/${Libmemcached_Ver}.tar.gz" "${Libmemcached_Ver}.tar.gz"
grab "https://download.redis.io/releases/${Redis_Stable_Ver}.tar.gz" "${Redis_Stable_Ver}.tar.gz"
grab "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${ImageMagick_Ver#ImageMagick-}.tar.gz" "${ImageMagick_Ver}.tar.gz"
grab "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz" "ioncube_loaders_lin_x86-64.tar.gz"
grab "https://download.pureftpd.org/pub/pure-ftpd/releases/${Pureftpd_Ver}.tar.bz2" "${Pureftpd_Ver}.tar.bz2"
grab "https://github.com/denyhosts/denyhosts/archive/refs/tags/v3.1.tar.gz" "denyhosts-3.1.tar.gz"
grab "https://github.com/fail2ban/fail2ban/archive/refs/tags/1.1.0.tar.gz" "fail2ban-1.1.0.tar.gz"

echo
echo "# ----------------------------------------------------------------------"
echo "# 采集完成：成功 ${ok} 项，失败 ${bad} 项"
if [ -n "${XCHECK_LOG}" ]; then
    echo "# 与上游公布值交叉核对通过的条目：${XCHECK_LOG}"
fi
echo "# ----------------------------------------------------------------------"

echo "采集完成：成功 ${ok} 项，失败 ${bad} 项" >&2
[ ${bad} -eq 0 ]
