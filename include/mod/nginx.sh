#!/usr/bin/env bash
#
# Nginx 模块：源码版 Nginx 及其第三方模块、LuaJIT 运行库的下载、编译、配置生成、服务文件、升级与回滚；
# 站点基线配置（反代包含文件、default 站点、FastCGI open_basedir 兜底）与 OpenResty 共用。
# 栈为 lnmp、lnmpa，或独立安装时的 nginx（按已装组件识别）；内存分配器为 none、jemalloc 或 tcmalloc。
#
#   Nginx_Sources   <版本> [功能]               输出下载清单，不下载、不写文件
#   Nginx_Installed                             输出已装的 "<版本>\t<分配器>"；0 已装；1 未装或为 OpenResty；2 程序不可读
#   Nginx_Check     <版本> <分配器>             0 就绪；1 缺失或不完整；2 版本或编译选项不符，或已装 OpenResty；3 参数错误
#   Nginx_Install   <版本> <栈> <分配器>        Check 为 0 时不写文件；失败时删除本次新建的安装目录
#   Nginx_Reinstall <版本> <栈> <分配器>        不论现状重新编译安装并按模板重写配置（独立安装入口使用）
#   Nginx_Upgrade   <版本>                      0 成功；1 失败，线上未改动或已回滚；2 回滚失败，保留现场
#   Nginx_Verify    <版本> <分配器>             Check 通过后做配置测试
#   Nginx_Health                                不比较版本与编译选项：0 配置与服务文件完整且配置测试通过；1 文件缺失；2 配置测试未通过
#   Nginx_Remove                                停止服务，删除启动项、init 脚本与安装目录；0 已删除；1 有残留；2 前缀为 OpenResty 软链接
#   Nginx_Site_Conf <配置目录> <栈> <install|keep>  反代包含文件；install 另写 default 站点与 PHP 基线
#   Nginx_Conflict  <nginx|openresty>           要安装的一方与已装的另一方互斥时返回 1
#
# 功能为逗号分隔的 openssl、lua、brotli、purge、fancy，缺省取 lnmp.conf 的开关。
# 约定：不交互、不 exit、不改变调用方工作目录；编译在 src/ 下的私有目录与子 shell 中进行。
# 输入为参数与只读配置（lnmp.conf 的 Enable_Nginx_*、Enable_Ngx_*、Nginx_Modules_Options、
# Default_Website_Dir，include/version.sh，cur_dir）。

_Nginx_Prefix()
{
    printf '%s\n' "${LNMP_NGINX_PREFIX:-/usr/local/nginx}"
}

_Nginx_Initd_Dir()
{
    printf '%s\n' "${LNMP_INITD_DIR:-/etc/init.d}"
}

_Nginx_Unit_Dir()
{
    printf '%s\n' "${LNMP_UNIT_DIR:-/etc/systemd/system}"
}

_Nginx_Ver_Ok()
{
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

_Nginx_Malloc_Ok()
{
    case "$1" in none|jemalloc|tcmalloc) return 0 ;; esac
    return 1
}

_Nginx_Has()
{
    case ",$1," in *",$2,"*) return 0 ;; esac
    return 1
}

# _Nginx_Brotli_Libdir：输出系统 brotli 编码库所在目录；头文件或库缺失时返回 1。
# 优先使用可随发行版更新的共享库，缺失时使用静态库。
_Nginx_Brotli_Libdir()
{
    local lib

    [ -f /usr/include/brotli/encode.h ] || return 1
    lib=$(gcc -print-file-name=libbrotlienc.so 2>/dev/null)
    [ -f "${lib}" ] || lib=$(gcc -print-file-name=libbrotlienc.a 2>/dev/null)
    [ -f "${lib}" ] || return 1
    (cd "$(dirname "${lib}")" && pwd)
}

# _Nginx_Features [nginx 二进制]：lnmp.conf 开启的功能；给出二进制时并入其已编入的模块。
# brotli 依赖缺失时不计入。
_Nginx_Features()
{
    local bin=${1:-} v='' f=''

    [ -n "${bin}" ] && v=$("${bin}" -V 2>&1)
    { [ "${Enable_Nginx_Openssl}" = y ] || [[ "${v}" == *--with-openssl=* ]]; } && f="${f},openssl"
    { [ "${Enable_Nginx_Lua}" = y ] || [[ "${v}" == *lua-nginx-module* ]]; } && f="${f},lua"
    { [ "${Enable_Ngx_Brotli}" = y ] || [[ "${v}" == *ngx_brotli* ]]; } \
        && _Nginx_Brotli_Libdir >/dev/null && f="${f},brotli"
    { [ "${Enable_Ngx_CachePurge}" = y ] || [[ "${v}" == *ngx_cache_purge* ]]; } && f="${f},purge"
    { [ "${Enable_Ngx_FancyIndex}" = y ] || [[ "${v}" == *fancyindex* ]]; } && f="${f},fancy"
    printf '%s\n' "${f#,}"
}

# _Nginx_Pcre_Src <功能>：需要随 Nginx 编译 PCRE 源码时返回 0。
# 系统没有 PCRE 8.x 开发包，或启用 Lua（lua-nginx-module 依赖 PCRE JIT）时使用源码。
_Nginx_Pcre_Src()
{
    _Nginx_Has "$1" lua && return 0
    command -v pcre-config >/dev/null 2>&1 || return 0
    pcre-config --version 2>/dev/null | grep -Eq '^8\.' && return 1
    return 0
}

_Nginx_Resty_Libs()
{
    printf '%s\n' "${LuaRestyLock}" "${LuaRestyString}" "${LuaRestyRedis}" "${LuaRestyMysql}" \
        "${LuaRestyUpload}" "${LuaRestyWebsocket}" "${LuaRestyDns}" "${LuaRestyMemcached}" \
        "${LuaRestyLimitTraffic}"
}

# _Nginx_Resty_Repo <包名>：从包名中分离仓库名，保留 rc 等预发布后缀所在的版本部分。
_Nginx_Resty_Repo()
{
    printf '%s\n' "$1" | sed -E 's/-[0-9][0-9.]*([a-zA-Z]+[0-9]*)?$//'
}

Nginx_Sources()
{
    local ver=$1 feats file lib repo check=pgp loc

    _Nginx_Ver_Ok "${ver}" || return 1
    feats=${2-$(_Nginx_Features)}
    file="nginx-${ver}.tar.gz"
    loc="https://nginx.org/download/${file}.asc"
    if awk -v f="${file}" '$1 !~ /^#/ && $2 == f {found=1} END {exit !found}' \
        "${cur_dir}/src/checksums.sha256" 2>/dev/null; then
        check=sha256
        loc=src/checksums.sha256
    fi
    printf 'nginx\t/usr/local/nginx\t%s\t%s\thttps://nginx.org/download/%s\t%s\t%s\n' \
        "${ver}" "${file}" "${file}" "${check}" "${loc}"

    {
        _Nginx_Has "${feats}" openssl && printf '%s\t%s\n' "${Openssl_New_Ver}.tar.gz" \
            "https://github.com/openssl/openssl/releases/download/${Openssl_New_Ver}/${Openssl_New_Ver}.tar.gz"
        _Nginx_Pcre_Src "${feats}" && printf '%s\t%s\n' "${Pcre_Ver}.tar.bz2" \
            "https://downloads.sourceforge.net/pcre/${Pcre_Ver}.tar.bz2"
        if _Nginx_Has "${feats}" lua; then
            printf '%s\t%s\n' \
                "${Luajit_Ver}.tar.gz" "https://github.com/openresty/luajit2/archive/refs/tags/v${Luajit_Ver#luajit2-}.tar.gz" \
                "${LuaNginxModule}.tar.gz" "https://github.com/openresty/lua-nginx-module/archive/refs/tags/v${LuaNginxModule#lua-nginx-module-}.tar.gz" \
                "${NgxDevelKit}.tar.gz" "https://github.com/vision5/ngx_devel_kit/archive/refs/tags/v${NgxDevelKit#ngx_devel_kit-}.tar.gz" \
                "${LuaRestyCore}.tar.gz" "https://github.com/openresty/lua-resty-core/archive/refs/tags/v${LuaRestyCore#lua-resty-core-}.tar.gz" \
                "${LuaRestyLrucache}.tar.gz" "https://github.com/openresty/lua-resty-lrucache/archive/refs/tags/v${LuaRestyLrucache#lua-resty-lrucache-}.tar.gz" \
                "${LuaCjson}.tar.gz" "https://github.com/openresty/lua-cjson/archive/refs/tags/${LuaCjson#lua-cjson-}.tar.gz"
            while IFS= read -r lib; do
                repo=$(_Nginx_Resty_Repo "${lib}")
                printf '%s\t%s\n' "${lib}.tar.gz" \
                    "https://github.com/openresty/${repo}/archive/refs/tags/v${lib#"${repo}"-}.tar.gz"
            done < <(_Nginx_Resty_Libs)
        fi
        _Nginx_Has "${feats}" brotli && printf '%s\t%s\n' "${NgxBrotli_Ver}.tar.gz" \
            "https://github.com/google/ngx_brotli/archive/${NgxBrotli_Commit}.tar.gz"
        _Nginx_Has "${feats}" purge && printf '%s\t%s\n' "${NgxCachePurge_Ver}.tar.gz" \
            "https://github.com/FRiCKLE/ngx_cache_purge/archive/${NgxCachePurge_Ver#ngx_cache_purge-}.tar.gz"
        _Nginx_Has "${feats}" fancy && printf '%s\t%s\n' "${NgxFancyIndex_Ver}.tar.xz" \
            "https://github.com/aperezdc/ngx-fancyindex/releases/download/v${NgxFancyIndex_Ver#ngx-fancyindex-}/${NgxFancyIndex_Ver}.tar.xz"
    } | while IFS=$'\t' read -r file loc; do
        printf 'nginx\t/usr/local/nginx\t%s\t%s\t%s\tsha256\tsrc/checksums.sha256\n' "${ver}" "${file}" "${loc}"
    done
    return 0
}

# _Nginx_Fetch <版本> <功能>：在子 shell 中调用。校验清单有记录的文件走 Download_Files，
# 其余版本的 Nginx 源码包经 Download_Verified 校验上游 PGP 签名。
_Nginx_Fetch()
{
    local ver=$1 file url check

    cd "${cur_dir}/src" || return 1
    while IFS=$'\t' read -r _ _ _ file url check _; do
        if [ "${check}" = sha256 ]; then
            Download_Files "${url}" "${file}" || return 1
        else
            Download_Verified nginx "${ver}" "${url}" "${file}" || return 1
        fi
        [ -s "${file}" ] || return 1
    done < <(Nginx_Sources "${ver}" "$2")
}

# _Nginx_Configure_Args <构建目录> <分配器> <功能>：每行一个 configure 参数。
_Nginx_Configure_Args()
{
    local bdir=$1 malloc=$2 feats=$3 ld=''
    local -a extra=()

    printf '%s\n' --user=www --group=www --prefix=/usr/local/nginx --with-http_stub_status_module \
        --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_gzip_static_module \
        --with-http_sub_module --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module \
        --with-http_realip_module
    _Nginx_Has "${feats}" openssl && printf '%s\n' "--with-openssl=${bdir}/${Openssl_New_Ver}"
    _Nginx_Pcre_Src "${feats}" && printf '%s\n' "--with-pcre=${bdir}/${Pcre_Ver}" --with-pcre-jit
    if _Nginx_Has "${feats}" lua; then
        ld='-Wl,-rpath,/usr/local/luajit/lib'
        printf '%s\n' "--add-module=${bdir}/${LuaNginxModule}" "--add-module=${bdir}/${NgxDevelKit}"
    fi
    [ "${malloc}" = jemalloc ] && ld="${ld:+${ld} }-ljemalloc"
    [ -n "${ld}" ] && printf '%s\n' "--with-ld-opt=${ld}"
    [ "${malloc}" = tcmalloc ] && printf '%s\n' --with-google_perftools_module
    _Nginx_Has "${feats}" brotli && printf '%s\n' "--add-module=${bdir}/${NgxBrotli_Ver}"
    _Nginx_Has "${feats}" purge && printf '%s\n' "--add-module=${bdir}/${NgxCachePurge_Ver}"
    _Nginx_Has "${feats}" fancy && printf '%s\n' "--add-module=${bdir}/${NgxFancyIndex_Ver}"
    read -r -a extra <<< "${Nginx_Modules_Options}"
    [ "${#extra[@]}" -gt 0 ] && printf '%s\n' "${extra[@]}"
    return 0
}

# _Nginx_Norm_Opts：标准输入每行一个参数，源码路径只保留目录名，排序后输出。
_Nginx_Norm_Opts()
{
    sed -E 's#^(--add-module|--add-dynamic-module|--with-openssl|--with-pcre)=.*/#\1=#' | LC_ALL=C sort
}

_Nginx_Expected_Opts()
{
    _Nginx_Configure_Args /nonexistent "$1" "$2" | _Nginx_Norm_Opts
}

# _Nginx_Built_Opts <nginx 二进制>：读回编译参数。含空格的取值由 nginx 以单引号括起。
_Nginx_Built_Opts()
{
    "$1" -V 2>&1 | sed -n 's/^configure arguments: //p' | xargs -n1 printf '%s\n' 2>/dev/null \
        | _Nginx_Norm_Opts
}

# _Nginx_Built_Malloc <nginx 二进制>：现有二进制使用的内存分配器；头文件缺失时按 none 重建。
_Nginx_Built_Malloc()
{
    local v

    v=$("$1" -V 2>&1)
    if [[ "${v}" == *-ljemalloc* ]] && [ -s /usr/local/include/jemalloc/jemalloc.h ]; then
        echo jemalloc
    elif [[ "${v}" == *--with-google_perftools_module* ]] && [ -s /usr/local/include/gperftools/tcmalloc.h ]; then
        echo tcmalloc
    else
        echo none
    fi
}

Nginx_Remove()
{
    local prefix init

    prefix=$(_Nginx_Prefix)
    case "${prefix}" in /|'') return 1 ;; esac
    if [ -L "${prefix}" ]; then
        Echo_Red "${prefix} 指向 OpenResty，未改动。"
        return 2
    fi
    if ! Preserve_Paths "${prefix}/conf/vhost" "${prefix}/conf/ssl"; then
        Echo_Red "虚拟主机配置或证书未能保存，未删除 ${prefix}。"
        return 1
    fi
    init="$(_Nginx_Initd_Dir)/nginx"
    [ -x "${init}" ] && "${init}" stop >/dev/null 2>&1
    Remove_StartUp nginx >/dev/null 2>&1
    rm -f "${init}"
    rm -rf -- "${prefix}"
    [ ! -e "${prefix}" ] && [ ! -e "${init}" ]
}

Nginx_Installed()
{
    local prefix bin ver

    prefix=$(_Nginx_Prefix)
    [ -e "${prefix}" ] && [ ! -L "${prefix}" ] || return 1
    bin="${prefix}/sbin/nginx"
    [ -x "${bin}" ] || return 2
    ver=$("${bin}" -v 2>&1 | sed -n 's#^nginx version: nginx/##p')
    [ -n "${ver}" ] || return 2
    printf '%s\t%s\n' "${ver}" "$(_Nginx_Built_Malloc "${bin}")"
}

Nginx_Check()
{
    local ver=$1 malloc=$2 prefix bin have

    _Nginx_Ver_Ok "${ver}" && _Nginx_Malloc_Ok "${malloc}" || return 3
    prefix=$(_Nginx_Prefix)
    [ -L "${prefix}" ] && return 2
    bin="${prefix}/sbin/nginx"
    [ -x "${bin}" ] || return 1
    have=$("${bin}" -v 2>&1 | sed -n 's#^nginx version: nginx/##p')
    [ -n "${have}" ] || return 1
    [ "${have}" = "${ver}" ] || return 2
    [ "$(_Nginx_Built_Opts "${bin}")" = "$(_Nginx_Expected_Opts "${malloc}" "$(_Nginx_Features)")" ] || return 2
    [ -s "${prefix}/conf/nginx.conf" ] && [ -s "${prefix}/conf/vhost/default.conf" ] \
        && [ -s "$(_Nginx_Initd_Dir)/nginx" ] && [ -s "$(_Nginx_Unit_Dir)/nginx.service" ] || return 1
    return 0
}

Nginx_Health()
{
    local prefix

    prefix=$(_Nginx_Prefix)
    [ -x "${prefix}/sbin/nginx" ] && [ -s "${prefix}/conf/nginx.conf" ] && [ -s "${prefix}/conf/vhost/default.conf" ] \
        && [ -s "$(_Nginx_Initd_Dir)/nginx" ] && [ -s "$(_Nginx_Unit_Dir)/nginx.service" ] || return 1
    "${prefix}/sbin/nginx" -t >/dev/null 2>&1 || return 2
}

Nginx_Verify()
{
    Nginx_Check "$1" "$2" || return 1
    if ! Nginx_Health; then
        Echo_Red "Nginx 配置检查未通过，执行 $(_Nginx_Prefix)/sbin/nginx -t 查看详情。"
        return 1
    fi
    return 0
}

# _Nginx_Unpack <构建目录> <归档> <成员>
_Nginx_Unpack()
{
    if ! Unpack_Checked "${cur_dir}/src/$2" "$1" "$3"; then
        Echo_Red "$2 解压失败或归档成员不合规。"
        return 1
    fi
}

# _Nginx_Link_Brotli <模块目录>：ngx_brotli 只从 deps/brotli 固定结构查找依赖，GitHub 归档不含该子模块。
# 映射系统头文件和库可满足 configure 检查，共享库继续接收发行版安全更新。
_Nginx_Link_Brotli()
{
    local deps="$1/deps/brotli" libdir

    if ! libdir=$(_Nginx_Brotli_Libdir); then
        Echo_Red "缺少 brotli 头文件或编码库（libbrotlienc.so / .a）。"
        Echo_Red "请先安装：Debian/Ubuntu 'apt-get install libbrotli-dev'，RHEL/CentOS 'dnf install brotli-devel'，"
        Echo_Red "或在 lnmp.conf 里设 Enable_Ngx_Brotli='n' 跳过 Brotli 压缩。"
        return 1
    fi
    rm -rf "${deps}"
    mkdir -p "${deps}/c/include" || return 1
    ln -sfn /usr/include/brotli "${deps}/c/include/brotli" || return 1
    ln -sfn "${libdir}" "${deps}/out" || return 1
    echo "ngx_brotli: 使用系统 brotli 库（头文件 /usr/include/brotli，库目录 ${libdir}）"
}

# _Nginx_Lua_Build <构建目录>：编译安装 LuaJIT、lua-cjson 与 lua-resty 库，并做冒烟测试。
# lua-resty 库依赖 Nginx 的 ngx 运行环境，此处只做语法检查；cjson 为 C 模块，可直接加载。
_Nginx_Lua_Build()
{
    local bdir=$1 lib f ok=y
    local cjson_args=(LUA_INCLUDE_DIR=/usr/local/luajit/include/luajit-2.1
        LUA_CMODULE_DIR=/usr/local/luajit/lib/lua/5.1 LUA_MODULE_DIR=/usr/local/luajit/share/lua/5.1)

    Echo_Blue "[+] 正在安装 ${Luajit_Ver}... "
    cd "${bdir}/${Luajit_Ver}" || return 1
    make || { Echo_Red "LuaJIT 编译失败。"; return 1; }
    make install PREFIX=/usr/local/luajit || { Echo_Red "LuaJIT 安装失败。"; return 1; }
    printf '%s\n' /usr/local/luajit/lib > /etc/ld.so.conf.d/luajit.conf || return 1
    if [ "$(getconf LONG_BIT)" = 64 ]; then
        ln -sf /usr/local/luajit/lib/libluajit-5.1.so.2 /lib64/libluajit-5.1.so.2
    else
        ln -sf /usr/local/luajit/lib/libluajit-5.1.so.2 /usr/lib/libluajit-5.1.so.2
    fi
    ldconfig
    printf '%s\n' 'export LUAJIT_LIB=/usr/local/luajit/lib' \
        'export LUAJIT_INC=/usr/local/luajit/include/luajit-2.1' > /etc/profile.d/luajit.sh || return 1
    export LUAJIT_LIB=/usr/local/luajit/lib LUAJIT_INC=/usr/local/luajit/include/luajit-2.1

    while IFS= read -r lib; do
        Echo_Blue "[+] 正在安装 ${lib}... "
        ( cd "${bdir}/${lib}" && make install PREFIX=/usr/local/nginx ) || { Echo_Red "安装 ${lib} 失败。"; return 1; }
    done < <(printf '%s\n' "${LuaRestyCore}" "${LuaRestyLrucache}"; _Nginx_Resty_Libs)

    # cjson 有 C 代码，针对 LuaJIT 头文件编译，由 nginx.conf 的 lua_package_cpath 引用。
    cd "${bdir}/${LuaCjson}" || return 1
    if ! make "${cjson_args[@]}" || ! make install "${cjson_args[@]}"; then
        Echo_Red "lua-cjson 编译失败。"
        return 1
    fi

    for f in /usr/local/nginx/lib/lua/resty/core.lua /usr/local/nginx/lib/lua/resty/lrucache.lua \
             /usr/local/luajit/lib/lua/5.1/cjson.so; do
        [ -s "${f}" ] || { Echo_Red "Lua 运行库缺失：${f}"; ok=n; }
    done
    for f in /usr/local/nginx/lib/lua/resty/core.lua /usr/local/nginx/lib/lua/resty/lrucache.lua; do
        /usr/local/luajit/bin/luajit -e "assert(loadfile('${f}'))" \
            || { Echo_Red "${f} 语法检查失败（文件损坏或与 LuaJIT 版本不匹配）。"; ok=n; }
    done
    LUA_CPATH='/usr/local/luajit/lib/lua/5.1/?.so;;' /usr/local/luajit/bin/luajit -e 'require("cjson")' \
        || { Echo_Red "cjson 无法 require（C 模块未正确编译或路径不对）。"; ok=n; }
    if [ "${ok}" != y ]; then
        Echo_Red "Lua 运行库冒烟测试失败，继续编译只会把问题推迟到 nginx 启动时才暴露。"
        return 1
    fi
    Echo_Green "Lua 运行库冒烟测试通过。"
}

# _Nginx_Build <版本> <分配器> <构建目录> <功能> <install|objs>：在子 shell 中调用。
# install 执行 make install；objs 只编译，产物留在构建目录的 objs/nginx。
_Nginx_Build()
{
    local ver=$1 malloc=$2 bdir=$3 feats=$4 mode=$5 lib
    local -a args=() resty=()

    _Nginx_Unpack "${bdir}" "nginx-${ver}.tar.gz" "nginx-${ver}" || return 1
    if _Nginx_Has "${feats}" openssl; then
        _Nginx_Unpack "${bdir}" "${Openssl_New_Ver}.tar.gz" "${Openssl_New_Ver}" || return 1
    fi
    if _Nginx_Pcre_Src "${feats}"; then
        _Nginx_Unpack "${bdir}" "${Pcre_Ver}.tar.bz2" "${Pcre_Ver}" || return 1
    fi
    if _Nginx_Has "${feats}" lua; then
        mapfile -t resty < <(_Nginx_Resty_Libs)
        for lib in "${Luajit_Ver}" "${LuaNginxModule}" "${NgxDevelKit}" "${LuaRestyCore}" \
                   "${LuaRestyLrucache}" "${LuaCjson}" "${resty[@]}"; do
            _Nginx_Unpack "${bdir}" "${lib}.tar.gz" "${lib}" || return 1
        done
    fi
    if _Nginx_Has "${feats}" brotli; then
        _Nginx_Unpack "${bdir}" "${NgxBrotli_Ver}.tar.gz" "${NgxBrotli_Ver}" || return 1
    fi
    if _Nginx_Has "${feats}" purge; then
        _Nginx_Unpack "${bdir}" "${NgxCachePurge_Ver}.tar.gz" "${NgxCachePurge_Ver}" || return 1
    fi
    if _Nginx_Has "${feats}" fancy; then
        _Nginx_Unpack "${bdir}" "${NgxFancyIndex_Ver}.tar.xz" "${NgxFancyIndex_Ver}" || return 1
    fi
    # 解包核对完成后再建立指向系统路径的链接。
    if _Nginx_Has "${feats}" brotli; then
        _Nginx_Link_Brotli "${bdir}/${NgxBrotli_Ver}" || return 1
    fi
    if _Nginx_Has "${feats}" lua; then
        _Nginx_Lua_Build "${bdir}" || return 1
    fi

    Echo_Blue "[+] 正在编译 nginx-${ver}... "
    cd "${bdir}/nginx-${ver}" || return 1
    mapfile -t args < <(_Nginx_Configure_Args "${bdir}" "${malloc}" "${feats}")
    if ! ./configure "${args[@]}" || ! Check_Makefile_Ready; then
        Echo_Red "nginx-${ver} 的 configure 失败。"
        return 1
    fi
    if [ "${mode}" = install ]; then
        Make_Install
        return $?
    fi
    if ! make -j"$(Build_Jobs)"; then
        Echo_Yellow "并行编译失败，退回串行重试..."
        make || { Echo_Red "nginx-${ver} 编译失败。"; return 1; }
    fi
    [ -s objs/nginx ] || { Echo_Red "编译结束但没有产出 objs/nginx。"; return 1; }
}

# _Nginx_Cleanup <目录>：只清理本模块在 src/ 下创建的私有目录。
_Nginx_Cleanup()
{
    case "$1" in
    "${cur_dir}"/src/.nginx-build.*) rm -rf -- "$1" ;;
    esac
}

Nginx_Conflict()
{
    if [ "$1" = openresty ]; then
        # 真实的 /usr/local/nginx 目录表示已安装源码版 Nginx。
        if [ -d /usr/local/nginx ] && [ ! -L /usr/local/nginx ]; then
            Echo_Red "检测到已安装 nginx（/usr/local/nginx 是真实目录）。"
            Echo_Red "OpenResty 与 nginx 官方版互斥，不能同时安装 ——"
            Echo_Red "两者都提供 nginx 二进制、都要监听 80/443。"
            Echo_Red "如需改用 OpenResty，重新执行 bash install.sh ${Stack:-lnmp}，"
            Echo_Red "安装前的残留检测会列出现有组件并在确认后清理。"
            return 1
        fi
    elif [ -d /usr/local/openresty ]; then
        Echo_Red "检测到已安装 OpenResty（/usr/local/openresty 存在）。"
        Echo_Red "nginx 官方版与 OpenResty 互斥，不能同时安装。"
        Echo_Red "如需改用 nginx，重新执行 bash install.sh ${Stack:-lnmp}，"
        Echo_Red "安装前的残留检测会列出现有组件并在确认后清理。"
        return 1
    fi
    return 0
}

# Nginx_Conf_Stack <栈>：独立安装时按已装组件识别栈，输出 lnmp、lnmpa 或 unknow。
Nginx_Conf_Stack()
{
    case "$1" in
    lnmp|lnmpa) echo "$1"; return 0 ;;
    esac
    Check_Stack
    case "${Get_Stack}" in
    lnmp|lnmpa) echo "${Get_Stack}" ;;
    *) echo unknow ;;
    esac
}

# _Nginx_Proxy_Conf <配置目录> <是否 LNMPA> <只补缺失>：反代包含文件。
# proxy.conf 是三栈通用的反代参数；proxy-pass-php.conf 只把 PHP 转给本机 Apache，仅 LNMPA 需要。
_Nginx_Proxy_Conf()
{
    local conf_dir=$1 is_lnmpa=$2 keep_existing=$3 name

    if [ ! -d "${conf_dir}" ]; then
        Echo_Red "Nginx 配置目录不存在：${conf_dir}"
        return 1
    fi
    for name in proxy.conf proxy-pass-php.conf; do
        [ "${name}" = proxy-pass-php.conf ] && [ "${is_lnmpa}" != y ] && continue
        [ "${keep_existing}" = y ] && [ -s "${conf_dir}/${name}" ] && continue
        if ! \cp "${cur_dir}/conf/${name}" "${conf_dir}/${name}"; then
            Echo_Red "写入 ${conf_dir}/${name} 失败。"
            return 1
        fi
    done
    return 0
}

# _Nginx_Default_VHost <配置目录> <栈>：静态 default 站点。LNMPA 将 PHP 请求反向代理到 Apache，
# 其余栈连接 PHP-FPM。
_Nginx_Default_VHost()
{
    local conf_dir=$1 listen_extra='' demo_php_block quic_lines='' v

    if uname -r | grep -Eq '^3\.(9|1[0-9])|^[4-9]\.'; then
        listen_extra=' reuseport'
    fi
    # 未编译 http_v3 时写入 quic 会使 nginx -t 失败。
    v=$("${conf_dir%/conf}/sbin/nginx" -V 2>&1)
    if [ -n "${listen_extra}" ] && [[ "${v}" == *--with-http_v3_module* ]]; then
        printf -v quic_lines '\n%s\n%s\n%s' \
            '    # QUIC 的 reuseport 在同一地址端口只能声明一次，由本块承担，业务站点只写 quic。' \
            '    listen 443 quic reuseport default_server;' \
            '    #listen [::]:443 quic reuseport default_server ipv6only=on;'
    fi
    if [ "$2" = lnmpa ]; then
        demo_php_block='        proxy_pass http://127.0.0.1:88;
        include proxy.conf;'
    else
        demo_php_block='        try_files $uri =404;
        fastcgi_pass  unix:/run/php-fpm/php-cgi.sock;
        fastcgi_index index.php;
        include fastcgi.conf;'
    fi

    if ! mkdir -p "${conf_dir}/vhost"; then
        Echo_Red "创建 Nginx vhost 配置目录失败：${conf_dir}/vhost"
        return 1
    fi

    cat >"${conf_dir}/vhost/default.conf"<<EOF || { Echo_Red "生成 Nginx default 站点失败。"; return 1; }
server {
    listen 80 default_server${listen_extra};
    #listen [::]:80 default_server ipv6only=on;
    server_name _;
    index index.html index.htm;
    root  ${Default_Website_Dir};

    #error_page   404   /404.html;

    # phpMyAdmin 片段按安装开关生成，关闭时默认站点保持静态。
    include phpmyadmin.*.conf;

    # 仅允许按开关部署的 phpinfo、redis 和 memcached 固定测试页执行 PHP；
    # 文件未部署时返回 404。
    location ~ ^/(phpinfo|redis|memcached)\.php\$ {
${demo_php_block}
    }

    # 默认站点除指定测试页外不执行 PHP，避免源码泄露；phpMyAdmin 使用
    # 独立的 ^~ 前缀规则，不会放开网站根目录中的其他 PHP 文件。
    location ~ [^/]\.php(/|\$) {
        return 404;
    }

    location ~ .*\.(gif|jpg|jpeg|png|bmp|swf)\$ {
        expires      30d;
    }

    location ~ .*\.(js|css)\$ {
        expires      12h;
    }

    location ^~ /.well-known/ {
        allow all;
    }

    location ~ /\. {
        deny all;
    }

    # 自定义配置--开始

    # 自定义配置--结束

    access_log  /home/wwwlogs/default.log main;
    error_log   /home/wwwlogs/default.error.log;
}

server {
    # 未匹配 SNI 的 HTTPS 请求在此终止。没有这个块时，443 上的第一个业务
    # 站点会成为隐式默认站点，IP 直连和错误 DNS 指向都会拿到它的响应。
    # 为 default 配置证书时，lnmp ssl add 会自动移除本块。
    listen 443 ssl default_server;
    #listen [::]:443 ssl default_server ipv6only=on;${quic_lines}
    ssl_reject_handshake on;
}
EOF
    return 0
}

# _Nginx_Php_Baseline <配置目录>：default 站点的 PHP 安全基线，站点级 .user.ini 与 FastCGI 层
# 按 $document_root 计算的 PHP_ADMIN_VALUE。仅连接 PHP-FPM 的栈需要。
_Nginx_Php_Baseline()
{
    local fastcgi_conf="$1/fastcgi.conf"

    if [ ! -d "${Default_Website_Dir}" ] && ! mkdir -p "${Default_Website_Dir}"; then
        Echo_Red "创建默认站点目录失败：${Default_Website_Dir}"
        return 1
    fi
    # 重复安装时旧文件可能仍带 immutable，不先解除就写不进新的 open_basedir。
    [ -f "${Default_Website_Dir}/.user.ini" ] && \
        chattr -i "${Default_Website_Dir}/.user.ini" 2>/dev/null
    if ! cat >"${Default_Website_Dir}/.user.ini"<<EOF
open_basedir=${Default_Website_Dir}:/tmp/:/var/tmp/:/proc/
EOF
    then
        Echo_Red "错误：写入 ${Default_Website_Dir}/.user.ini 失败，默认站点缺少 open_basedir 限制。"
        return 1
    fi
    chmod 644 "${Default_Website_Dir}/.user.ini"
    # immutable 是加固项，置不上不中断安装，但必须让用户看到。
    if ! chattr +i "${Default_Website_Dir}/.user.ini" 2>/dev/null; then
        Echo_Yellow "警告：无法为 ${Default_Website_Dir}/.user.ini 设置 immutable 属性。"
        Echo_Yellow "该文件可被站点内的写入覆盖，可稍后手工执行："
        Echo_Yellow "  chattr +i ${Default_Website_Dir}/.user.ini"
    fi

    if [ ! -s "${fastcgi_conf}" ]; then
        Echo_Red "找不到 ${fastcgi_conf}，无法写入 FastCGI 层的 open_basedir 兜底。"
        return 1
    fi
    _Nginx_Sync_Fastcgi_Admin_Value "${fastcgi_conf}"
}

# FastCGI 层 open_basedir 的基线路径集合，判断和重写都以它为准。
_Nginx_Fastcgi_Baseline_Paths()
{
    printf '%s\n' '$document_root/ /tmp/ /var/tmp/ /proc/'
}

# 从一行 fastcgi_param PHP_ADMIN_VALUE 中取出 open_basedir 的值；取不到输出空。
_Nginx_Fastcgi_Open_Basedir_Value()
{
    printf '%s\n' "$1" | sed -n 's/.*open_basedir=\([^";]*\).*/\1/p' | head -n 1
}

# 只判断指令存在会把值为空、open_basedir=/、旧的宽松路径或用于其它 admin 配置
# 的行当成基线已生效，兜底实际不存在。因此解析该行的实际取值逐项核对。
#
# 核对的是「基线路径都在，且没有 / 这种等于没有边界的项」，不要求整行完全相等：
# 管理员可能按站点需要额外加了缓存目录等路径，整行覆盖会静默删掉它们并弄坏站点。
# 需要重写时保留原有的额外路径，只补齐缺的基线路径并去掉 /。
_Nginx_Sync_Fastcgi_Admin_Value()
{
    local conf="$1" want count tmp line value p merged extra ok='y' base

    base=$(_Nginx_Fastcgi_Baseline_Paths)
    want="fastcgi_param PHP_ADMIN_VALUE \"open_basedir=${base// /:}\";"

    count=$(grep -c '^[[:space:]]*fastcgi_param[[:space:]]\+PHP_ADMIN_VALUE' "${conf}")
    if [ "${count}" -eq 1 ]; then
        line=$(grep '^[[:space:]]*fastcgi_param[[:space:]]\+PHP_ADMIN_VALUE' "${conf}")
        value=$(_Nginx_Fastcgi_Open_Basedir_Value "${line}")
        if [ -n "${value}" ]; then
            for p in ${base}; do
                case ":${value}:" in
                *":${p}:"*) ;;
                *) ok='n' ;;
                esac
            done
            # 单独一个 / 等于没有边界，必须去掉。
            case ":${value}:" in
            *":/:"*) ok='n' ;;
            esac
            [ "${ok}" = 'y' ] && return 0
        else
            ok='n'
        fi
    fi

    # 重写时保留原值里不属于基线、也不是 / 的额外路径。
    merged="${base// /:}"
    if [ "${count}" -eq 1 ] && [ -n "${value}" ]; then
        extra=''
        local IFS=':'
        for p in ${value}; do
            [ -z "${p}" ] && continue
            [ "${p}" = '/' ] && continue
            case " ${base} " in
            *" ${p} "*) continue ;;
            esac
            extra="${extra}:${p}"
        done
        unset IFS
        merged="${merged}${extra}"
        want="fastcgi_param PHP_ADMIN_VALUE \"open_basedir=${merged}\";"
        [ -n "${extra}" ] && Echo_Yellow "保留原有的额外路径：${extra#:}"
    fi

    if [ "${count}" -gt 0 ]; then
        Echo_Yellow "${conf} 中的 PHP_ADMIN_VALUE 缺少基线路径或含过宽的取值（共 ${count} 行），将重写。"
        grep -n '^[[:space:]]*fastcgi_param[[:space:]]\+PHP_ADMIN_VALUE' "${conf}" | sed 's/^/  原有：/'
        Echo_Yellow "  写入：${want}"
    fi

    tmp=$(mktemp "${conf}.XXXXXXXX") || {
        Echo_Red "无法创建临时文件，${conf} 未修改。"
        return 1
    }
    # 只删本参数所在的行，文件里其它 fastcgi_param 保持原样。
    # grep 返回 1 表示筛完没有剩余行，属于正常结果；大于 1 才是读取出错。
    grep -v '^[[:space:]]*fastcgi_param[[:space:]]\+PHP_ADMIN_VALUE' "${conf}" > "${tmp}"
    if [ $? -gt 1 ]; then
        rm -f "${tmp}"
        Echo_Red "读取 ${conf} 失败，未修改。"
        return 1
    fi
    printf '%s\n' "${want}" >> "${tmp}" || { rm -f "${tmp}"; return 1; }
    # 保留原有权限和属主，不因重写放宽访问。
    chmod --reference="${conf}" "${tmp}" 2>/dev/null || chmod 644 "${tmp}"
    chown --reference="${conf}" "${tmp}" 2>/dev/null
    if ! mv -f "${tmp}" "${conf}"; then
        rm -f "${tmp}"
        Echo_Red "写入 ${conf} 失败，PHP 请求缺少 FastCGI 层的 open_basedir 兜底。"
        return 1
    fi

    # 回读确认写入结果，不靠 mv 的返回值判定生效。
    count=$(grep -c '^[[:space:]]*fastcgi_param[[:space:]]\+PHP_ADMIN_VALUE' "${conf}")
    if [ "${count}" -ne 1 ] || ! grep -qxF "${want}" "${conf}"; then
        Echo_Red "回读 ${conf} 未取到期望的 PHP_ADMIN_VALUE，FastCGI 层兜底未生效。"
        return 1
    fi
    return 0
}

Nginx_Site_Conf()
{
    local conf_dir=$1 stack=$2 mode=$3 is_lnmpa=n

    [ "${stack}" = lnmpa ] && is_lnmpa=y
    if [ "${mode}" = keep ]; then
        _Nginx_Proxy_Conf "${conf_dir}" "${is_lnmpa}" y
        return $?
    fi
    _Nginx_Proxy_Conf "${conf_dir}" "${is_lnmpa}" n || return 1
    _Nginx_Default_VHost "${conf_dir}" "${stack}" || return 1
    [ "${stack}" = lnmp ] || return 0
    _Nginx_Php_Baseline "${conf_dir}"
}

# _Nginx_Write_Conf <栈> <功能> <分配器> <安装前已有 nginx.conf>：模板、包含文件、站点目录与站点配置。
_Nginx_Write_Conf()
{
    local stack=$1 feats=$2 malloc=$3 preexisting=$4 prefix conf

    prefix=$(_Nginx_Prefix)
    conf="${prefix}/conf/nginx.conf"
    # 识别不出栈且已有配置时保留原文件，不用模板覆盖用户配置。
    if [ "${stack}" = unknow ] && [ "${preexisting}" = y ]; then
        Echo_Yellow "识别不出当前安装的栈，已保留现有 ${conf}。"
        Echo_Yellow "如需改用随包模板，请对照 conf/nginx.conf 或 conf/nginx_a.conf 手工调整。"
    elif [ "${stack}" = lnmpa ]; then
        \cp "${cur_dir}/conf/nginx_a.conf" "${conf}" || return 1
    else
        \cp "${cur_dir}/conf/nginx.conf" "${conf}" || return 1
    fi
    \cp -r "${cur_dir}/conf/rewrite" "${prefix}/conf/" || return 1
    \cp "${cur_dir}/conf/pathinfo.conf" "${prefix}/conf/pathinfo.conf" || return 1
    \cp "${cur_dir}/conf/enable-php.conf" "${prefix}/conf/enable-php.conf" || return 1
    \cp "${cur_dir}/conf/enable-php-pathinfo.conf" "${prefix}/conf/enable-php-pathinfo.conf" || return 1
    # 复制目录内容：目标已存在时 cp -r 会把源目录嵌套到目标之下。
    mkdir -p "${prefix}/conf/example" && \cp -r "${cur_dir}/conf/example/." "${prefix}/conf/example/" || return 1
    # 源码树属主随解包者而定；覆盖复制不改已有文件属主，统一归 root。
    chown -R root:root "${prefix}/conf/rewrite" "${prefix}/conf/example" || return 1

    if _Nginx_Has "${feats}" lua; then
        if ! grep -q 'lua_package_path "/usr/local/nginx/lib/lua/?.lua";' "${conf}"; then
            sed -i "/server_tokens off;/i\    lua_package_path \"/usr/local/nginx/lib/lua/?.lua\";\n" "${conf}"
        fi
        # cjson.so 通过 cpath 加载，末尾的 ";;" 保留 LuaJIT 默认搜索路径。
        if ! grep -q 'lua_package_cpath' "${conf}"; then
            sed -i "/server_tokens off;/i\    lua_package_cpath \"/usr/local/luajit/lib/lua/5.1/?.so;;\";\n" "${conf}"
        fi
    elif grep -q 'location /lua' "${conf}"; then
        # 未编译 ngx_lua 时删除 /lua 示例，避免 nginx -t 报未知指令。
        sed -i '/location \/lua/,/^[[:space:]]*}[[:space:]]*$/d' "${conf}"
    fi
    # 静态 Brotli 与 gzip 由浏览器协商选择；条件取实际参与编译的功能，避免写入未知指令。
    if _Nginx_Has "${feats}" brotli && ! grep -q '^\s*brotli on;' "${conf}"; then
        sed -i "/gzip on;/i\    brotli on;\n    brotli_static on;\n    brotli_comp_level 6;\n    brotli_min_length 1k;\n    brotli_types text/plain text/css application/json application/javascript application/x-javascript text/javascript application/xml application/xml+rss image/svg+xml;\n" "${conf}"
    fi
    if [ "${malloc}" = tcmalloc ]; then
        if [ -L "${prefix}/var/tcmalloc" ] || ! mkdir -p "${prefix}/var/tcmalloc" \
           || ! chown www:www "${prefix}/var/tcmalloc" || ! chmod 0750 "${prefix}/var/tcmalloc"; then
            Echo_Red "无法安全创建 TCMalloc profile 目录。"
            return 1
        fi
        grep -q 'google_perftools_profiles' "${conf}" || sed -i '/nginx.pid/a\
google_perftools_profiles /usr/local/nginx/var/tcmalloc;' "${conf}"
    fi

    mkdir -p "${Default_Website_Dir}" || return 1
    mkdir -p /home/wwwlogs && chown root:root /home/wwwlogs && chmod 755 /home/wwwlogs
    chown -R www:www "${Default_Website_Dir}"
    chmod 755 "${Default_Website_Dir}"
    # 站点配置引用反代包含文件，缺失会让 nginx -t 失败；.user.ini 置 immutable 后 chown -R 无法改动，放在授权之后。
    Nginx_Site_Conf "${prefix}/conf" "${stack}" install
}

# _Nginx_Service_Files：init 脚本与 unit 最后写入，Check 以它们判定安装完成。
_Nginx_Service_Files()
{
    local initd tmp

    initd=$(_Nginx_Initd_Dir)
    tmp=$(mktemp "${initd}/.nginx.XXXXXX") || return 1
    if ! \cp "${cur_dir}/init.d/init.d.nginx" "${tmp}" || ! chmod 755 "${tmp}" \
       || ! mv -f "${tmp}" "${initd}/nginx"; then
        rm -f "${tmp}"
        Echo_Red "写入 ${initd}/nginx 失败。"
        return 1
    fi
    Svc_Install_Unit "${cur_dir}/init.d/nginx.service" "$(_Nginx_Unit_Dir)/nginx.service"
}

Nginx_Install()
{
    local ver=$1 stack=$2 malloc=$3 rc

    Nginx_Check "${ver}" "${malloc}"
    rc=$?
    case "${rc}" in
    0) Echo_Green "Nginx ${ver} 已就绪，无需安装。"; return 0 ;;
    2) Echo_Red "已安装的 Nginx 版本或编译选项与期望的 ${ver} 不符，或已安装 OpenResty，未改动。更换版本请执行 ./upgrade.sh nginx。"; return 2 ;;
    3) Echo_Red "Nginx 安装参数错误：${ver} ${malloc}"; return 3 ;;
    esac
    _Nginx_Do_Install "${ver}" "${stack}" "${malloc}"
}

Nginx_Reinstall()
{
    local ver=$1 stack=$2 malloc=$3

    if ! _Nginx_Ver_Ok "${ver}" || ! _Nginx_Malloc_Ok "${malloc}"; then
        Echo_Red "Nginx 安装参数错误：${ver} ${malloc}"
        return 3
    fi
    if [ -L "$(_Nginx_Prefix)" ]; then
        Echo_Red "$(_Nginx_Prefix) 指向 OpenResty，未改动。"
        return 2
    fi
    _Nginx_Do_Install "${ver}" "${stack}" "${malloc}"
}

# _Nginx_Do_Install <版本> <栈> <分配器>：编译安装并写入配置与服务文件。
# 失败时删除本次新建的安装目录与 init 脚本，已有的安装目录保留。
_Nginx_Do_Install()
{
    local ver=$1 stack=$2 malloc=$3 feats prefix bdir existed=n init_existed=n preexisting=n conf_stack

    Nginx_Conflict nginx || return 1
    prefix=$(_Nginx_Prefix)
    [ -e "${prefix}" ] && existed=y
    [ -s "${prefix}/conf/nginx.conf" ] && preexisting=y
    [ -e "$(_Nginx_Initd_Dir)/nginx" ] && init_existed=y
    conf_stack=$(Nginx_Conf_Stack "${stack}")
    feats=$(_Nginx_Features)
    if [ "${Enable_Ngx_Brotli}" = y ] && ! _Nginx_Has "${feats}" brotli; then
        Echo_Red "ngx_brotli 依赖不满足，本次安装跳过 Brotli 模块（Debian/Ubuntu 安装 libbrotli-dev）。"
    fi

    Echo_Blue "[+] 正在安装 nginx-${ver}... "
    getent group www >/dev/null 2>&1 || groupadd www
    id -u www >/dev/null 2>&1 || useradd -s /sbin/nologin -g www www
    ( _Nginx_Fetch "${ver}" "${feats}" ) || { Echo_Red "Nginx 源码或依赖下载、校验失败。"; return 1; }
    bdir=$(mktemp -d "${cur_dir}/src/.nginx-build.XXXXXXXX") || return 1
    if ( _Nginx_Build "${ver}" "${malloc}" "${bdir}" "${feats}" install ) \
       && { ln -sf "${prefix}/sbin/nginx" /usr/bin/nginx 2>/dev/null; :; } \
       && _Nginx_Write_Conf "${conf_stack}" "${feats}" "${malloc}" "${preexisting}" \
       && _Nginx_Service_Files; then
        _Nginx_Cleanup "${bdir}"
        return 0
    fi
    _Nginx_Cleanup "${bdir}"
    [ "${existed}" = n ] && rm -rf -- "${prefix}"
    [ "${init_existed}" = n ] && rm -f "$(_Nginx_Initd_Dir)/nginx"
    Echo_Red "Nginx ${ver} 安装失败。"
    return 1
}

# _Nginx_Rollback <二进制> <备份>：换名写回旧二进制并确认服务运行。无法写回时返回 1。
_Nginx_Rollback()
{
    local bin=$1 bak=$2 rc=0

    Echo_Red "正在回滚到升级前的 nginx..."
    # 新二进制此时可能已在运行，同样用换名方式写回备份。
    if ! \cp -p "${bak}" "${bin}.rollback" || ! mv -f "${bin}.rollback" "${bin}"; then
        Echo_Red "写回旧 nginx 二进制失败：${bin}"
        rm -f "${bin}.rollback"
        rc=1
    fi
    "${bin}" -t || Echo_Red "回滚后配置检查仍未通过，请手工处理：${bin} -t"
    if pgrep -x nginx >/dev/null 2>&1; then
        "${bin}" -s reload 2>/dev/null || "$(_Nginx_Initd_Dir)/nginx" restart
    else
        "$(_Nginx_Initd_Dir)/nginx" start
    fi
    return "${rc}"
}

Nginx_Upgrade()
{
    local ver=$1 prefix bin bak malloc feats bdir out='' conf_stack stamp

    _Nginx_Ver_Ok "${ver}" || { Echo_Red "Nginx 升级参数错误：${ver}"; return 1; }
    prefix=$(_Nginx_Prefix)
    bin="${prefix}/sbin/nginx"
    if [ -L "${prefix}" ]; then
        Echo_Red "${prefix} 指向 OpenResty，请执行 ./upgrade.sh openresty。"
        return 1
    fi
    [ -x "${bin}" ] || { Echo_Red "${bin} 不存在，没有可升级的 Nginx。"; return 1; }
    stamp=$(date +%Y%m%d%H%M%S)
    bak="${bin}.${stamp}"
    # 现有二进制已编入的模块在升级后保留，否则 nginx.conf 里的相关指令会变成未知指令。
    malloc=$(_Nginx_Built_Malloc "${bin}")
    feats=$(_Nginx_Features "${bin}")

    ( _Nginx_Fetch "${ver}" "${feats}" ) || { Echo_Red "nginx-${ver} 下载或校验失败，线上 nginx 未做任何改动。"; return 1; }
    bdir=$(mktemp -d "${cur_dir}/src/.nginx-build.XXXXXXXX") || return 1
    if ! ( _Nginx_Build "${ver}" "${malloc}" "${bdir}" "${feats}" objs ); then
        _Nginx_Cleanup "${bdir}"
        Echo_Red "线上 nginx 未做任何改动。"
        return 1
    fi

    # 替换前用新二进制检查现有配置，失败不会影响当前服务。
    echo "用新二进制测试现有配置（尚未替换线上文件）..."
    if ! "${bdir}/nginx-${ver}/objs/nginx" -t -p "${prefix}" -c "${prefix}/conf/nginx.conf"; then
        Echo_Red "新版 nginx 无法通过现有配置的语法检查，放弃升级。"
        Echo_Red "常见原因：新版本移除了某个指令，或本次编译少了某个模块。"
        Echo_Red "线上 nginx 未做任何改动。"
        _Nginx_Cleanup "${bdir}"
        return 1
    fi

    # 运行中的二进制不能被覆盖写（ETXTBSY），同目录写新文件后原子换名，
    # 旧 inode 仍被运行中的进程持有，路径上也不存在没有二进制的空窗。
    echo "备份旧二进制到 ${bak} 并替换..."
    if ! cp -p "${bin}" "${bak}"; then
        Echo_Red "备份旧 nginx 二进制失败，放弃升级。"
        _Nginx_Cleanup "${bdir}"
        return 1
    fi
    if ! \cp "${bdir}/nginx-${ver}/objs/nginx" "${bin}.new" || ! chmod 755 "${bin}.new" \
       || ! mv -f "${bin}.new" "${bin}"; then
        rm -f "${bin}.new"
        Echo_Red "替换 nginx 二进制失败，线上 nginx 未做任何改动。"
        _Nginx_Cleanup "${bdir}"
        return 1
    fi

    # 通过 USR2/QUIT 热升级到新二进制和工作进程，确认进程仍在运行且版本号与目标一致。
    echo "执行热升级..."
    if ! ( cd "${bdir}/nginx-${ver}" && make upgrade ); then
        Echo_Red "make upgrade 失败。"
    else
        sleep 2
        out=$("${bin}" -v 2>&1)
        if ! pgrep -x nginx >/dev/null 2>&1; then
            Echo_Red "热升级后没有 nginx 进程在运行。"
        elif [[ "${out}" != *"nginx/${ver}"* ]]; then
            Echo_Red "升级后版本号不符：期望 ${ver}，实际 '${out}'。"
        else
            out=ok
        fi
    fi
    _Nginx_Cleanup "${bdir}"
    if [ "${out}" != ok ]; then
        _Nginx_Rollback "${bin}" "${bak}" || return 2
        return 1
    fi

    # 补齐缺失的反代包含文件，已存在的保留站点自己的修改。
    conf_stack=$(Nginx_Conf_Stack nginx)
    Nginx_Site_Conf "${prefix}/conf" "${conf_stack}" keep \
        || Echo_Red "补齐反代包含文件失败，可手工 cp conf/proxy.conf 到 ${prefix}/conf/。"

    echo "下面显示升级后的 Nginx 版本："
    "${bin}" -v
    Echo_Green "======== Nginx 升级完成 ======"
    Echo_Green "旧二进制保留在 ${bak}，确认无误后可自行删除。"
    return 0
}
