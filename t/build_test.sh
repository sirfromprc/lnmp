#!/usr/bin/env bash
#
# t/build_test.sh - 构建与运行验证
#
# 用法：
#   bash t/build_test.sh lua       # 仅验证 Lua 组件（约 6-10 分钟）
#   bash t/build_test.sh nginx     # nginx + 全部第三方模块（含自建 OpenSSL，约 20-30 分钟）
#   bash t/build_test.sh php       # PHP 默认分支编译（约 20-35 分钟）
#   bash t/build_test.sh all
#
# 需要 root 权限安装编译依赖，可在 debian:12 容器或验证机中执行。
#
# ---------------------------------------------------------------------------
# Lua 运行时兼容性验证
#
# lua-resty-core 的版本断言写在 base.lua 里：
#
#     or ngx.config.ngx_lua_version ~= 10031
#     ...
#     error("ngx_http_lua_module 0.10.31 required but got " .. ver)
#
# 该断言在 Lua 运行时执行。版本不匹配时：
#   ./configure  通过
#   make         通过
#   nginx -t     通过
#   nginx 启动   通过
#   首次访问包含 Lua 的 location 时返回 500
#
# 因此必须请求 content_by_lua location 并核对响应内容。
# ---------------------------------------------------------------------------

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. include/version.sh

MODE="${1:-lua}"
WORK="${BUILD_WORK:-/tmp/lnmp-buildtest}"
JOBS="$(nproc 2>/dev/null || echo 2)"
mkdir -p "${WORK}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m!! %s\033[0m\n' "$*"; exit 1; }

fetch()
{
    # fetch <URL> <落地文件名>
    [ -s "${WORK}/$2" ] && return 0
    wget -q --timeout=90 --tries=3 -O "${WORK}/$2" "$1" || die "下载失败：$1"
}

deps()
{
    step "安装编译依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        build-essential ca-certificates wget curl perl \
        libpcre2-dev zlib1g-dev libssl-dev libxml2-dev \
        libbrotli-dev pkg-config >/dev/null || die "依赖安装失败"
}

# ---------------------------------------------------------------------------
# Lua 组件：编译、启动及请求验证
# ---------------------------------------------------------------------------
build_lua()
{
    step "Lua 全家桶：${Luajit_Ver} / ${LuaNginxModule} / ${LuaRestyCore} / ${LuaRestyLrucache}"

    fetch "https://github.com/openresty/luajit2/archive/refs/tags/v${Luajit_Ver#luajit2-}.tar.gz" "${Luajit_Ver}.tar.gz"
    fetch "https://github.com/openresty/lua-nginx-module/archive/refs/tags/v${LuaNginxModule#lua-nginx-module-}.tar.gz" "${LuaNginxModule}.tar.gz"
    fetch "https://github.com/openresty/lua-resty-core/archive/refs/tags/v${LuaRestyCore#lua-resty-core-}.tar.gz" "${LuaRestyCore}.tar.gz"
    fetch "https://github.com/openresty/lua-resty-lrucache/archive/refs/tags/v${LuaRestyLrucache#lua-resty-lrucache-}.tar.gz" "${LuaRestyLrucache}.tar.gz"
    fetch "https://github.com/vision5/ngx_devel_kit/archive/refs/tags/v${NgxDevelKit#ngx_devel_kit-}.tar.gz" "${NgxDevelKit}.tar.gz"
    fetch "https://nginx.org/download/${Nginx_Ver}.tar.gz" "${Nginx_Ver}.tar.gz"

    cd "${WORK}" || exit 1
    for a in "${Luajit_Ver}" "${LuaNginxModule}" "${LuaRestyCore}" "${LuaRestyLrucache}" "${NgxDevelKit}" "${Nginx_Ver}"; do
        tar zxf "${a}.tar.gz"
    done

    # GitHub 归档解出来的目录名是 <repo>-<tag（去掉 v）>，与包名不一定一致，
    # 按前缀定位解压目录，兼容归档目录名差异。
    srcdir() { (cd "${WORK}" && ls -d "$1"-* 2>/dev/null | head -1); }
    local d_jit d_mod d_core d_lru d_ndk
    d_jit=$(srcdir luajit2)             || true
    d_mod=$(srcdir lua-nginx-module)    || true
    d_core=$(srcdir lua-resty-core)     || true
    d_lru=$(srcdir lua-resty-lrucache)  || true
    d_ndk=$(srcdir ngx_devel_kit)       || true
    for v in d_jit d_mod d_core d_lru d_ndk; do
        [ -n "${!v}" ] || die "找不到源码目录：${v}"
    done

    step "编译 LuaJIT（${d_jit}）"
    cd "${WORK}/${d_jit}" || die "进不去 ${d_jit}"
    make -j"${JOBS}" PREFIX=/usr/local/luajit >/dev/null || die "LuaJIT 编译失败"
    make install PREFIX=/usr/local/luajit >/dev/null || die "LuaJIT 安装失败"

    # 与 include/nginx.sh 一致：注册动态库搜索路径，
    # 否则 nginx 启动时报 libluajit-5.1.so.2: cannot open shared object file
    mkdir -p /etc/ld.so.conf.d
    echo /usr/local/luajit/lib > /etc/ld.so.conf.d/luajit.conf
    ldconfig || die "ldconfig 失败"

    export LUAJIT_LIB=/usr/local/luajit/lib
    export LUAJIT_INC=/usr/local/luajit/include/luajit-2.1

    step "编译 nginx + ngx_devel_kit + lua-nginx-module"
    cd "${WORK}/${Nginx_Ver}" || exit 1
    ./configure --prefix=/usr/local/nginx-luatest \
        --with-http_ssl_module --with-http_stub_status_module \
        --with-ld-opt="-Wl,-rpath,/usr/local/luajit/lib" \
        --add-module="${WORK}/${d_ndk}" \
        --add-module="${WORK}/${d_mod}" \
        >/dev/null || die "nginx configure 失败"
    make -j"${JOBS}" >/dev/null || die "nginx 编译失败"
    make install >/dev/null || die "nginx 安装失败"

    step "安装 lua-resty-core / lua-resty-lrucache"
    mkdir -p /usr/local/nginx-luatest/lib/lua
    cp -a "${WORK}/${d_core}/lib/." /usr/local/nginx-luatest/lib/lua/
    cp -a "${WORK}/${d_lru}/lib/." /usr/local/nginx-luatest/lib/lua/

    step "写测试配置并启动"
    cat > /usr/local/nginx-luatest/conf/nginx.conf <<'EOF'
worker_processes 1;
error_log /usr/local/nginx-luatest/logs/error.log info;
events { worker_connections 128; }
http {
    lua_package_path "/usr/local/nginx-luatest/lib/lua/?.lua;;";
    lua_package_cpath "/usr/local/luajit/lib/lua/5.1/?.so;;";
    server {
        listen 8085;
        location /lua {
            default_type text/plain;
            content_by_lua_block { ngx.say("lua-ok") }
        }
        # require resty.core 时触发 base.lua 的版本断言
        location /restycore {
            default_type text/plain;
            content_by_lua_block {
                require "resty.core"
                local lru = require "resty.lrucache"
                local c = lru.new(8)
                c:set("k", "v")
                -- get 返回 data, stale_data, flags，用括号截断成单值
                ngx.say("resty-core-ok:", (c:get("k")))
            }
        }
    }
}
EOF

    /usr/local/nginx-luatest/sbin/nginx -t || die "nginx -t 未通过"
    /usr/local/nginx-luatest/sbin/nginx || die "nginx 启动失败"
    sleep 2

    step "真发请求（这一步才会触发 base.lua 的版本断言）"
    local r1 r2 rc=0
    r1=$(curl -s --max-time 10 http://127.0.0.1:8085/lua)
    r2=$(curl -s --max-time 10 http://127.0.0.1:8085/restycore)
    echo "  /lua       -> ${r1:-<空>}"
    echo "  /restycore -> ${r2:-<空>}"

    [ "${r1}" = "lua-ok" ] || { echo "!! content_by_lua 未正常执行"; rc=1; }
    case "${r2}" in
        resty-core-ok:v) ;;
        *) echo "!! resty.core 加载失败 ： 这几乎将是 lua-resty-core 与 lua-nginx-module 版本不配套"
           rc=1 ;;
    esac

    if [ ${rc} -ne 0 ]; then
        echo
        echo "--- error.log 尾部 ---"
        tail -30 /usr/local/nginx-luatest/logs/error.log 2>/dev/null
        echo
        echo "当前配置：${LuaNginxModule} + ${LuaRestyCore}"
        echo "对照 lua-resty-core 的 lib/resty/core/base.lua 里那句"
        echo "  ngx.config.ngx_lua_version ~= NNNNN"
        echo "NNNNN = major*1000000 + minor*1000 + patch，需与 lua-nginx-module 版本相等。"
    fi

    /usr/local/nginx-luatest/sbin/nginx -s stop 2>/dev/null
    [ ${rc} -eq 0 ] || die "Lua 全家桶验证未通过"
    step "Lua 全家桶验证通过"
}

# ---------------------------------------------------------------------------
# nginx + 第三方模块（按 include/version.sh 的实际配置）
# ---------------------------------------------------------------------------
build_nginx_full()
{
    step "nginx 全模块：${Nginx_Ver} + OpenSSL ${Openssl_New_Ver#openssl-}"

    fetch "https://nginx.org/download/${Nginx_Ver}.tar.gz" "${Nginx_Ver}.tar.gz"
    fetch "https://github.com/openssl/openssl/releases/download/${Openssl_New_Ver}/${Openssl_New_Ver}.tar.gz" "${Openssl_New_Ver}.tar.gz"
    fetch "https://github.com/google/ngx_brotli/archive/${NgxBrotli_Commit}.tar.gz" "${NgxBrotli_Ver}.tar.gz"
    fetch "https://github.com/aperezdc/ngx-fancyindex/releases/download/v${NgxFancyIndex_Ver#ngx-fancyindex-}/${NgxFancyIndex_Ver}.tar.xz" "${NgxFancyIndex_Ver}.tar.xz"

    cd "${WORK}" || exit 1
    tar zxf "${Nginx_Ver}.tar.gz"
    tar zxf "${Openssl_New_Ver}.tar.gz"
    tar zxf "${NgxBrotli_Ver}.tar.gz"
    tar Jxf "${NgxFancyIndex_Ver}.tar.xz"
    local d_fancy
    d_fancy=$(cd "${WORK}" && ls -d ngx-fancyindex-* 2>/dev/null | head -1)
    [ -n "${d_fancy}" ] || die "找不到 ngx-fancyindex 源码目录"

    # ngx_brotli 的 GitHub 归档不含子模块，deps/brotli 是空的。
    # 与 include/nginx.sh 的 Link_System_Brotli 同一套做法：把系统库软链成它期望的结构。
    step "为 ngx_brotli 软链系统 brotli（归档不含子模块）"
    local bro="${WORK}/ngx_brotli-${NgxBrotli_Commit}"
    local enc libdir
    enc=$(gcc -print-file-name=libbrotlienc.so 2>/dev/null)
    [ -n "${enc}" ] && [ "${enc}" != "libbrotlienc.so" ] || die "系统未安装 libbrotli-dev"
    libdir=$(cd "$(dirname "${enc}")" && pwd)
    mkdir -p "${bro}/deps/brotli/c/include"
    ln -sfn /usr/include/brotli "${bro}/deps/brotli/c/include/brotli"
    ln -sfn "${libdir}" "${bro}/deps/brotli/out"

    step "configure + make（OpenSSL 一起编，耗时较长）"
    cd "${WORK}/${Nginx_Ver}" || exit 1
    ./configure --prefix=/usr/local/nginx-fulltest \
        --with-openssl="${WORK}/${Openssl_New_Ver}" \
        --with-http_ssl_module --with-http_v2_module --with-http_gzip_static_module \
        --with-http_stub_status_module --with-http_realip_module \
        --add-module="${bro}" \
        --add-module="${WORK}/${d_fancy}" \
        >/dev/null || die "configure 失败"
    make -j"${JOBS}" >/dev/null || die "编译失败"
    make install >/dev/null || die "安装失败"

    step "确认 brotli 真的链上了系统库"
    ldd /usr/local/nginx-fulltest/sbin/nginx | grep -q brotli \
        || die "nginx 未链接 brotli —— 软链没生效"
    /usr/local/nginx-fulltest/sbin/nginx -V 2>&1 | tr ' ' '\n' | grep -E 'brotli|fancyindex|openssl'
    step "nginx 全模块验证通过"
}

# ---------------------------------------------------------------------------
# PHP（编译默认分支以验证 configure 参数兼容性）
# ---------------------------------------------------------------------------
build_php()
{
    # 从 profile.sh 读取默认分支版本，避免重复维护映射
    local ver
    ver=$( . include/profile.sh >/dev/null 2>&1
           Set_PHP_Profile "${PHP_Default}" >/dev/null 2>&1
           echo "${Php_Ver#php-}" )
    [ -n "${ver}" ] || die "无法从 profile.sh 取得默认 PHP 版本"
    step "PHP ${ver} 编译验证（profile.sh 的默认分支）"

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq --no-install-recommends \
        libcurl4-openssl-dev libjpeg-dev libpng-dev libwebp-dev libfreetype6-dev \
        libonig-dev libsqlite3-dev libzip-dev libxslt1-dev bison re2c >/dev/null

    fetch "https://www.php.net/distributions/php-${ver}.tar.bz2" "php-${ver}.tar.bz2"
    cd "${WORK}" || exit 1
    [ -d "php-${ver}" ] || tar jxf "php-${ver}.tar.bz2"
    cd "php-${ver}" || exit 1

    ./configure --prefix=/usr/local/php-test \
        --with-config-file-path=/usr/local/php-test/etc \
        --enable-fpm --with-openssl --with-zlib --enable-mbstring \
        --with-curl --enable-gd --with-jpeg --with-webp --with-freetype \
        --with-mysqli --with-pdo-mysql --enable-opcache --with-zip \
        --enable-sockets --enable-bcmath --enable-soap --with-xsl \
        >/dev/null || die "PHP configure 失败"
    make -j"${JOBS}" >/dev/null || die "PHP 编译失败"
    make install >/dev/null || die "PHP 安装失败"

    /usr/local/php-test/bin/php -v || die "php -v 执行失败"
    step "PHP ${ver} 编译验证通过"
}

deps
case "${MODE}" in
    lua)   build_lua ;;
    nginx) build_nginx_full ;;
    php)   build_php ;;
    all)   build_lua; build_nginx_full; build_php ;;
    *)     die "未知模式：${MODE}（可选 lua / nginx / php / all）" ;;
esac

step "build_test.sh (${MODE}) 全部通过"
