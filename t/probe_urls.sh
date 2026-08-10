#!/usr/bin/env bash
#
# t/probe_urls.sh - 下载 URL 可达性探测
#
# 下载 URL 由各上游项目的命名规则生成，且部分上游会移除旧版本文件，
# 因此需要定期验证 version.sh 所引用文件的可达性。
#
# 本脚本只发 HEAD 请求（wget --spider），不下载文件、不改动系统。
# 在能出网的机器上执行：bash t/probe_urls.sh
#
# 退出码：全部可达返回 0，有不可达返回 1。

cd "$(dirname "$0")/.." || exit 1

. include/version.sh

# profile.sh 里的版本由菜单选择填充，这里直接取表中全部取值逐一探测。
MYSQL_VERS='8.0.46 8.4.7'
MARIADB_VERS='10.11.18 11.4.12 11.8.8'
PHP_VERS='8.0.30 8.1.34 8.2.33 8.3.33 8.4.24 8.5.9'
APACHE_VER='httpd-2.4.68'
PMA_VER='phpMyAdmin-5.2.3-all-languages'

TIMEOUT=15
ok=0
fail=0
FAILED=''

probe()
{
    # probe <分类> <URL>
    local tag="$1" url="$2" code
    printf '%-14s %-72s ' "${tag}" "$(echo "${url}" | cut -c1-72)"

    code=$(wget --spider --server-response --timeout=${TIMEOUT} --tries=1 \
                --max-redirect=10 "${url}" 2>&1 \
           | awk '/^  HTTP\/|^HTTP\//{c=$2} END{print c}')

    # 405 = 该站点不接受 HEAD（files.phpmyadmin.net 就是如此），
    # 不代表文件不存在。退化成 GET 取头几个字节判断。
    if [ "${code}" = "405" ] || [ "${code}" = "501" ]; then
        if [ -n "$(wget -qO- --timeout=${TIMEOUT} --tries=1 --max-redirect=10 \
                        "${url}" 2>/dev/null | head -c 4)" ]; then
            code=200
        fi
    fi

    case "${code}" in
        200|204)
            echo "OK ${code}"
            ok=$((ok+1))
            ;;
        '')
            echo "FAIL (无响应/DNS/超时)"
            fail=$((fail+1))
            FAILED="${FAILED}
  ${tag}  ${url}  → 无响应"
            ;;
        *)
            echo "FAIL ${code}"
            fail=$((fail+1))
            FAILED="${FAILED}
  ${tag}  ${url}  → HTTP ${code}"
            ;;
    esac
}

echo "=== 核心组件（lnmp 默认路径必经）==="
probe nginx    "https://nginx.org/download/${Nginx_Ver}.tar.gz"
probe openssl  "https://github.com/openssl/openssl/releases/download/${Openssl_New_Ver}/${Openssl_New_Ver}.tar.gz"
probe openssl备 "https://www.openssl.org/source/${Openssl_New_Ver}.tar.gz"
probe pcre     "https://downloads.sourceforge.net/pcre/${Pcre_Ver}.tar.bz2"
probe libiconv "https://ftp.gnu.org/gnu/libiconv/${Libiconv_Ver}.tar.gz"
probe autoconf "https://ftp.gnu.org/gnu/autoconf/${Autoconf_Ver}.tar.gz"
probe curl     "https://curl.se/download/${Curl_Ver}.tar.bz2"
probe freetype "https://downloads.sourceforge.net/freetype/${Freetype_New_Ver}.tar.xz"
probe libzip   "https://libzip.org/download/${Libzip_Ver}.tar.xz"

echo
echo "=== PHP 源码 ==="
for v in ${PHP_VERS}; do
    probe php "https://www.php.net/distributions/php-${v}.tar.bz2"
done

echo
echo "=== MySQL（源码 + 二进制）==="
for v in ${MYSQL_VERS}; do
    branch="${v%.*}"
    probe mysql源码 "https://cdn.mysql.com/Downloads/MySQL-${branch}/mysql-${v}.tar.gz"
done
probe mysql二进制 "https://cdn.mysql.com/Downloads/MySQL-8.0/mysql-8.0.46-linux-glibc2.28-x86_64.tar.xz"
probe mysql二进制 "https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-8.4.7-linux-glibc2.17-x86_64.tar.xz"

echo
echo "=== MariaDB（源码 + 二进制）==="
for v in ${MARIADB_VERS}; do
    probe mariadb源码 "https://downloads.mariadb.org/rest-api/mariadb/${v}/mariadb-${v}.tar.gz"
    probe mariadb二进制 "https://downloads.mariadb.org/rest-api/mariadb/${v}/mariadb-${v}-linux-systemd-x86_64.tar.gz"
done

echo
echo "=== boost（MySQL 源码编译需要）==="
probe boost "https://archives.boost.io/release/1.59.0/source/${Boost_Ver}.tar.bz2"
probe boost "https://archives.boost.io/release/1.67.0/source/${Boost_New_Ver}.tar.bz2"

echo
echo "=== Apache / phpMyAdmin ==="
probe apache   "https://archive.apache.org/dist/httpd/${APACHE_VER}.tar.bz2"
probe apr      "https://archive.apache.org/dist/apr/${APR_Ver}.tar.bz2"
probe apr-util "https://archive.apache.org/dist/apr/${APR_Util_Ver}.tar.bz2"
PMA_NUM="${PMA_VER#phpMyAdmin-}"; PMA_NUM="${PMA_NUM%-all-languages}"
probe phpmyadmin "https://files.phpmyadmin.net/phpMyAdmin/${PMA_NUM}/${PMA_VER}.tar.xz"

echo
echo "=== 可选：内存分配器 ==="
probe jemalloc   "https://github.com/jemalloc/jemalloc/releases/download/${Jemalloc_Ver#jemalloc-}/${Jemalloc_Ver}.tar.bz2"
probe gperftools "https://github.com/gperftools/gperftools/releases/download/${TCMalloc_Ver}/${TCMalloc_Ver}.tar.gz"
probe libunwind  "https://github.com/libunwind/libunwind/releases/download/v${Libunwind_Ver#libunwind-}/${Libunwind_Ver}.tar.gz"

echo
echo "=== 可选：nginx 模块 ==="
probe nghttp2    "https://github.com/nghttp2/nghttp2/releases/download/v${Nghttp2_Ver#nghttp2-}/${Nghttp2_Ver}.tar.xz"
probe fancyindex "https://github.com/aperezdc/ngx-fancyindex/releases/download/v${NgxFancyIndex_Ver#ngx-fancyindex-}/${NgxFancyIndex_Ver}.tar.xz"
probe luajit2    "https://github.com/openresty/luajit2/archive/refs/tags/v${Luajit_Ver#luajit2-}.tar.gz"
probe lua-nginx  "https://github.com/openresty/lua-nginx-module/archive/refs/tags/v${LuaNginxModule#lua-nginx-module-}.tar.gz"
probe ngx-devel  "https://github.com/vision5/ngx_devel_kit/archive/refs/tags/v${NgxDevelKit#ngx_devel_kit-}.tar.gz"
probe lua-core   "https://github.com/openresty/lua-resty-core/archive/refs/tags/v${LuaRestyCore#lua-resty-core-}.tar.gz"
probe lua-lru    "https://github.com/openresty/lua-resty-lrucache/archive/refs/tags/v${LuaRestyLrucache#lua-resty-lrucache-}.tar.gz"
probe lua-cjson  "https://github.com/openresty/lua-cjson/archive/refs/tags/${LuaCjson#lua-cjson-}.tar.gz"
# 纯 Lua 的 resty 库，命名规律一致，用与 nginx.sh 相同的方式推导仓库名与 tag
for lib in "${LuaRestyLock}" "${LuaRestyString}" "${LuaRestyRedis}" \
           "${LuaRestyMysql}" "${LuaRestyUpload}" "${LuaRestyWebsocket}" \
           "${LuaRestyDns}" "${LuaRestyMemcached}" "${LuaRestyLimitTraffic}"; do
    repo=$(echo "${lib}" | sed -E 's/-[0-9][0-9.]*([a-zA-Z]+[0-9]*)?$//')
    probe "${repo#lua-resty-}" "https://github.com/openresty/${repo}/archive/refs/tags/v${lib##${repo}-}.tar.gz"
done
probe brotli     "https://github.com/google/ngx_brotli/archive/${NgxBrotli_Commit}.tar.gz"
probe cache_purge "https://github.com/FRiCKLE/ngx_cache_purge/archive/${NgxCachePurge_Ver#ngx_cache_purge-}.tar.gz"

echo
echo "=== 可选：PHP 扩展（pecl）==="
probe apcu      "https://pecl.php.net/get/${PHPNewApcu_Ver}.tgz"
probe imagick   "https://pecl.php.net/get/${Imagick_Ver}.tgz"
probe swoole    "https://pecl.php.net/get/${PHPSwoole_Ver}.tgz"
probe memcache  "https://pecl.php.net/get/${PHP8Memcache_Ver}.tgz"
probe memcached "https://pecl.php.net/get/${PHP8Memcached_Ver}.tgz"
probe phpredis  "https://pecl.php.net/get/${PHPRedis_Ver}.tgz"
probe igbinary  "https://pecl.php.net/get/${PHPIgbinary_Ver}.tgz"

echo
echo "=== 可选：缓存 / 其他服务 ==="
probe memcached库 "https://memcached.org/files/${Memcached_Ver}.tar.gz"
probe libmemcached "https://launchpad.net/libmemcached/1.0/${Libmemcached_Ver#libmemcached-}/+download/${Libmemcached_Ver}.tar.gz"
probe redis     "https://download.redis.io/releases/${Redis_Stable_Ver}.tar.gz"
probe imagemagick "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${ImageMagick_Ver#ImageMagick-}.tar.gz"
probe ioncube   "https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz"
probe pureftpd  "https://download.pureftpd.org/pub/pure-ftpd/releases/${Pureftpd_Ver}.tar.bz2"
probe composer  "https://getcomposer.org/installer"

echo
echo "=== 可选：安全工具 ==="
probe denyhosts "https://github.com/denyhosts/denyhosts/archive/refs/tags/v3.1.tar.gz"
probe fail2ban  "https://github.com/fail2ban/fail2ban/archive/refs/tags/1.1.0.tar.gz"

echo
echo "============================================================"
echo "可达 ${ok} 个，不可达 ${fail} 个"
if [ ${fail} -gt 0 ]; then
    echo "不可达清单：${FAILED}"
    exit 1
fi
exit 0
