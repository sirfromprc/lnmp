#!/usr/bin/env bash
#
# t/build_test.sh - 构建与运行验证
#
# 用法：
#   bash t/build_test.sh lua         # Nginx + Lua 运行库，启动后请求 Lua location
#   bash t/build_test.sh nginx       # Nginx 全部可选模块，核对编译参数，验证 Lua、brotli 与 HTTP/3
#   bash t/build_test.sh openresty   # OpenResty 源码编译，核对编译参数，验证 Lua 与 HTTP/3
#   bash t/build_test.sh php         # profile.sh 默认分支的主 PHP 与默认扩展
#   bash t/build_test.sh all
#
# 下载、校验、configure 参数与编译调用 include/mod/ 的模块函数，与实际安装路径一致。
# 需要 root，在一次性容器或验证机中执行：会写入 /usr/local/luajit、/usr/local/nginx/lib/lua、
# /usr/local/openresty、/usr/local/php 等安装目录。运行验证的临时实例与日志位于 BUILD_WORK。
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
# 该断言在 Lua 运行时执行。版本不匹配时 configure、make、nginx -t 与启动均通过，
# 首次访问包含 Lua 的 location 时返回 500，因此必须请求并核对响应内容。
# ---------------------------------------------------------------------------

cd "$(dirname "$0")/.." || exit 1
cur_dir=$(pwd)
MODE="${1:-lua}"
WORK="${BUILD_WORK:-/tmp/lnmp-buildtest}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m!! %s\033[0m\n' "$*"; exit 1; }

# 与 install.sh 相同的加载顺序。
for f in include/product.sh lnmp.conf include/version.sh include/main.sh include/tune.sh \
         include/verify.sh include/firewall.sh include/profile.sh include/dbcommon.sh include/init.sh \
         include/mod/database.sh include/php.sh include/mod/php.sh include/mod/nginx.sh \
         include/mod/openresty.sh include/end.sh include/only.sh include/imageMagick.sh \
         include/mod/php_ext.sh include/php_default_ext.sh; do
    # shellcheck disable=SC1090
    . "${cur_dir}/${f}" || die "加载 ${f} 失败"
done

[ "$(id -u)" = 0 ] || die "需要 root"
mkdir -p "${WORK}" || die "无法创建 ${WORK}"

deps()
{
    step "安装依赖（Deb_Dependent）"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=300 update -qq || die "apt-get update 失败"
    apt-get -o DPkg::Lock::Timeout=300 install -y -qq --no-install-recommends \
        ca-certificates wget curl gnupg lsb-release >/dev/null || die "基础工具安装失败"
    Get_Dist_Name
    Get_Dist_Version
    [ "${PM}" = apt ] || die "仅支持 Debian 系环境，当前 ${DISTRO}"
    Deb_Dependent || die "依赖安装失败"
    getent group www >/dev/null 2>&1 || groupadd www
    id -u www >/dev/null 2>&1 || useradd -s /sbin/nologin -g www www
}

# opts_cover <期望参数文件> <实际参数文件>：期望中的每个 --with-* 均出现在实际参数中。
opts_cover()
{
    local miss
    miss=$(grep -- '^--with-' "$1" | grep -vxFf "$2")
    [ -z "${miss}" ] && return 0
    echo "实际编译参数缺少："
    printf '  %s\n' ${miss}
    return 1
}

# self_cert <目录>：生成本机验证用的自签名证书。
self_cert()
{
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
        -subj /CN=localhost -addext subjectAltName=DNS:localhost \
        -keyout "$1/k.pem" -out "$1/c.pem" >/dev/null 2>&1
}

# run_instance <nginx 二进制> <名称> <lua 搜索路径配置> <是否验证 HTTP/3 y|n>
# 以独立前缀启动临时实例，请求 Lua 与 HTTP/3，结束后停止。日志保留在 ${WORK}/<名称>/logs。
run_instance()
{
    local bin=$1 d="${WORK}/$2" luapath=$3 h3=$4 h3conf='' r rc=0

    rm -rf -- "${d}"
    mkdir -p "${d}/logs" "${d}/conf" || return 1
    if [ "${h3}" = y ]; then
        self_cert "${d}/conf" || { echo "生成自签名证书失败"; return 1; }
        h3conf="
    server {
        listen 18443 ssl;
        listen 18443 quic reuseport;
        http2 on;
        server_name localhost;
        ssl_certificate ${d}/conf/c.pem;
        ssl_certificate_key ${d}/conf/k.pem;
        add_header Alt-Svc 'h3=\":18443\"; ma=86400' always;
        location / { default_type text/plain; return 200 \"h3-ok\\n\"; }
    }"
    fi
    cat > "${d}/conf/nginx.conf" <<EOF
worker_processes 2;
error_log ${d}/logs/error.log info;
pid ${d}/logs/nginx.pid;
events { worker_connections 128; }
http {
    access_log off;
    ${luapath}
    server {
        listen 18080;
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
                ngx.say("resty-core-ok:", (c:get("k")))
            }
        }
        location /cjson {
            default_type text/plain;
            content_by_lua_block { ngx.say(require("cjson").encode({ok = 1})) }
        }
    }${h3conf}
}
EOF
    "${bin}" -p "${d}" -c "${d}/conf/nginx.conf" -t || return 1
    "${bin}" -p "${d}" -c "${d}/conf/nginx.conf" || return 1
    sleep 2

    r=$(curl -s --max-time 10 http://127.0.0.1:18080/lua)
    echo "  /lua       -> ${r:-<空>}"
    [ "${r}" = "lua-ok" ] || { echo "!! content_by_lua 未正常执行"; rc=1; }
    r=$(curl -s --max-time 10 http://127.0.0.1:18080/restycore)
    echo "  /restycore -> ${r:-<空>}"
    if [ "${r}" != "resty-core-ok:v" ]; then
        echo "!! resty.core 加载失败，通常是 lua-resty-core 与 lua-nginx-module 版本不配套：${LuaNginxModule} + ${LuaRestyCore}"
        echo "   base.lua 中 ngx_lua_version 应等于 major*1000000 + minor*1000 + patch"
        rc=1
    fi
    r=$(curl -s --max-time 10 http://127.0.0.1:18080/cjson)
    echo "  /cjson     -> ${r:-<空>}"
    [ "${r}" = '{"ok":1}' ] || { echo "!! cjson 未正常加载"; rc=1; }

    if [ "${h3}" = y ]; then
        r=$(curl -sk --max-time 10 -D - -o /dev/null --resolve localhost:18443:127.0.0.1 https://localhost:18443/ \
            | tr -d '\r' | grep -i '^alt-svc:')
        echo "  HTTP/2 Alt-Svc -> ${r:-<空>}"
        [ -n "${r}" ] || { echo "!! HTTPS 响应缺少 Alt-Svc"; rc=1; }
        r=$(curl -sk --http3-only --max-time 10 -o /dev/null -w '%{http_version} %{http_code}' \
            --resolve localhost:18443:127.0.0.1 https://localhost:18443/)
        echo "  HTTP/3     -> ${r:-<空>}"
        [ "${r}" = "3 200" ] || { echo "!! HTTP/3 请求未成功"; rc=1; }
    fi

    "${bin}" -p "${d}" -c "${d}/conf/nginx.conf" -s stop 2>/dev/null
    if [ "${rc}" -ne 0 ]; then
        echo "--- error.log 尾部 ---"
        tail -30 "${d}/logs/error.log" 2>/dev/null
    fi
    return "${rc}"
}

# nginx_build <功能>：按模块函数下载、校验并编译到构建目录的 objs/nginx，结果写入 NGX_BIN。
nginx_build()
{
    local feats=$1 ver=${Nginx_Ver#nginx-} bdir

    step "Nginx ${ver}（功能：${feats}）下载与校验"
    ( _Nginx_Fetch "${ver}" "${feats}" ) || die "Nginx 源码或依赖下载、校验失败"
    bdir=$(mktemp -d "${cur_dir}/src/.nginx-build.XXXXXXXX") || die "无法创建构建目录"
    step "编译（_Nginx_Build）"
    ( _Nginx_Build "${ver}" none "${bdir}" "${feats}" objs ) || die "Nginx 编译失败"
    NGX_BIN="${bdir}/nginx-${ver}/objs/nginx"

    step "核对编译参数与模块函数一致"
    _Nginx_Expected_Opts none "${feats}" > "${WORK}/nginx.expected"
    _Nginx_Built_Opts "${NGX_BIN}" > "${WORK}/nginx.built"
    if ! diff "${WORK}/nginx.expected" "${WORK}/nginx.built"; then
        die "编译产物的参数与 _Nginx_Configure_Args 不一致"
    fi
}

build_lua()
{
    nginx_build lua
    step "启动并请求（触发 base.lua 的版本断言）"
    run_instance "${NGX_BIN}" nginx-lua \
        'lua_package_path "/usr/local/nginx/lib/lua/?.lua;;"; lua_package_cpath "/usr/local/luajit/lib/lua/5.1/?.so;;";' n \
        || die "Lua 运行验证未通过"
    step "Lua 运行验证通过"
}

build_nginx_full()
{
    curl -V | grep -qw HTTP3 || die "curl 不支持 HTTP/3，无法验证（需要 Debian 13 或更新的 curl）"
    nginx_build openssl,lua,brotli,purge,fancy
    step "确认 brotli 链接系统库"
    ldd "${NGX_BIN}" | grep -q brotli || die "nginx 未链接 brotli"
    step "启动并请求 Lua 与 HTTP/3"
    run_instance "${NGX_BIN}" nginx-full \
        'lua_package_path "/usr/local/nginx/lib/lua/?.lua;;"; lua_package_cpath "/usr/local/luajit/lib/lua/5.1/?.so;;";' y \
        || die "Nginx 运行验证未通过"
    step "Nginx 全模块验证通过"
}

build_openresty()
{
    local ver=${OpenResty_Ver#openresty-} bdir bin=/usr/local/openresty/nginx/sbin/nginx

    curl -V | grep -qw HTTP3 || die "curl 不支持 HTTP/3，无法验证（需要 Debian 13 或更新的 curl）"
    step "OpenResty ${ver} 下载与验签"
    ( _OpenResty_Fetch "${ver}" ) || die "OpenResty 下载或校验失败"
    bdir=$(mktemp -d "${cur_dir}/src/.openresty-build.XXXXXXXX") || die "无法创建构建目录"
    step "编译（_OpenResty_Build）"
    ( _OpenResty_Build "${ver}" "${bdir}" ) || die "OpenResty 编译失败"

    step "核对编译参数与模块函数一致"
    _OpenResty_Configure_Args "${bdir}" | grep -- '^--with-' | LC_ALL=C sort > "${WORK}/openresty.expected"
    "${bin}" -V 2>&1 | sed -n 's/^configure arguments: //p' | tr ' ' '\n' | LC_ALL=C sort > "${WORK}/openresty.built"
    opts_cover "${WORK}/openresty.expected" "${WORK}/openresty.built" \
        || die "编译产物的参数与 _OpenResty_Configure_Args 不一致"
    grep -qx -- --with-http_v3_module "${WORK}/openresty.expected" || die "当前系统 OpenSSL 未启用 http_v3"

    step "启动并请求 Lua 与 HTTP/3"
    run_instance "${bin}" openresty '' y || die "OpenResty 运行验证未通过"
    step "OpenResty 验证通过"
}

build_php()
{
    local ver m loaded opt=()

    Set_PHP_Profile "${PHP_Default}" >/dev/null || die "无法从 profile.sh 取得默认 PHP 版本"
    ver=${Php_Ver#php-}
    step "PHP ${ver}（profile.sh 默认分支）"
    # 主 PHP 的 systemd unit 固定写入，容器中该目录可能不存在。
    mkdir -p /etc/systemd/system
    ( Install_PHP_Base_Libs ) || die "libiconv 或 freetype 安装失败"
    PHP_Install /usr/local/php fpm "${ver}" '' || die "PHP_Install 失败"
    PHP_Verify /usr/local/php fpm "${ver}" || die "PHP_Verify 未通过"

    step "默认扩展（Install_PHP_Default_Ext）"
    PHP_Default_Ext_Failed=''
    Install_PHP_Default_Ext /usr/local/php
    [ -z "${PHP_Default_Ext_Failed}" ] || die "默认扩展未装成功：${PHP_Default_Ext_Failed# }"
    loaded=$(/usr/local/php/bin/php -m 2>&1)
    # 可选内置扩展按 lnmp.conf 开关判断
    [ "${Enable_PHP_Exif}" = "n" ] || opt+=(exif)
    [ "${Enable_PHP_Fileinfo}" = "n" ] || opt+=(fileinfo)
    [ "${Enable_PHP_Ldap}" = "y" ] && opt+=(ldap)
    [ "${Enable_PHP_Bz2}" = "y" ] && opt+=(bz2)
    [ "${Enable_PHP_Sodium}" = "y" ] && opt+=(sodium)
    for m in $(Default_Ext_List) 'Zend OPcache' intl gd "${opt[@]}"; do
        printf '%s\n' "${loaded}" | grep -qixF -- "${m}" || die "PHP 未加载 ${m}"
    done
    printf '%s\n' "${loaded}" | grep -qiE '^(PHP )?(Warning|Fatal)' && die "PHP 加载扩展有告警"
    /usr/local/php/sbin/php-fpm -t || die "php-fpm 配置测试未通过"
    /usr/local/php/bin/php -v
    step "PHP ${ver} 验证通过"
}

case "${MODE}" in
    lua|nginx|openresty|php|all) deps ;;
    *) die "未知模式：${MODE}（可选 lua / nginx / openresty / php / all）" ;;
esac
case "${MODE}" in
    lua)       build_lua ;;
    nginx)     build_nginx_full ;;
    openresty) build_openresty ;;
    php)       build_php ;;
    all)       build_nginx_full; build_openresty; build_php ;;
esac

step "build_test.sh (${MODE}) 全部通过"
