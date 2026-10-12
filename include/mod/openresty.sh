#!/usr/bin/env bash
#
# OpenResty 模块：官方仓库预编译包或源码编译的安装、升级与移除，自定义编译模块与 Lua 库。
# 与源码版 Nginx 互斥；安装后以 /usr/local/nginx 软链接兼容虚拟主机、服务脚本与管理命令路径。
# 模式为 pkg（官方 apt/yum 仓库，完整性由包管理器签名保证）或 source（官方源码，PGP 验签）。
#
#   OpenResty_Sources <版本> <模式>         输出下载清单，不下载、不写文件
#   OpenResty_Mode                          输出已装的安装方式：pkg、source 或 none
#   OpenResty_Installed                     输出已装的 "<版本>\t<模式>"；0 已装；1 未装；2 程序不可读
#   OpenResty_Check   <版本> <模式>         0 就绪；1 缺失或不完整；2 安装方式或版本不符，或已装源码版 Nginx；3 参数错误
#   OpenResty_Install <版本> <模式> <栈>    Check 为 0 时不写文件
#   OpenResty_Health                        不比较版本与安装方式：0 配置与服务文件完整且配置测试通过；1 文件缺失；2 配置测试未通过
#   OpenResty_Upgrade <模式> [版本]         0 成功；1 失败，线上未改动；2 已改动线上文件后失败，需人工处理
#   OpenResty_Remove                        卸载程序、仓库定义与兼容软链接，不删除站点与日志
#
# 自定义模块配置格式：名称|下载地址|SHA256|static或dynamic。源码安装后编译配置记录在
# /etc/lnmp/openresty-build.conf，升级时 lnmp.conf 未显式配置则沿用。
# 约定：不交互、不 exit、不改变调用方工作目录；编译在 src/ 下的私有目录与子 shell 中进行。

_OpenResty_Prefix()
{
    printf '%s\n' "${LNMP_OR_PREFIX:-/usr/local/openresty}"
}

_OpenResty_Build_Conf()
{
    printf '%s\n' "${LNMP_OR_BUILD_CONF:-/etc/lnmp/openresty-build.conf}"
}

_OpenResty_Initd_Dir()
{
    printf '%s\n' "${LNMP_INITD_DIR:-/etc/init.d}"
}

_OpenResty_Ver_Ok()
{
    [[ "$1" =~ ^[0-9]+(\.[0-9]+){2,3}$ ]]
}

_OpenResty_Field()
{
    printf '%s' "$1" | awk -F'|' -v i="$2" '{gsub(/^[ \t]+|[ \t]+$/,"",$i); print $i}'
}

# 模块名用于路径和文件名，因此限制为安全字符集。
_OpenResty_Module_Name_Ok()
{
    case "$1" in
    ''|*[!A-Za-z0-9._-]*)
        Echo_Red "模块名 '$1' 不合法：只允许字母、数字、点、下划线和连字符。"
        return 1 ;;
    .*|*..*)
        Echo_Red "模块名 '$1' 不合法：不能以点开头或包含 '..'。"
        return 1 ;;
    esac
    return 0
}

# _OpenResty_Configured：配置了编译模块或 Lua 库时返回 0。
_OpenResty_Configured()
{
    [ "${#OpenResty_Custom_Modules[@]}" -gt 0 ] && return 0
    [ -n "${OpenResty_Modules_Options}" ] && return 0
    [ -n "${OpenResty_Custom_Lualib}" ] && return 0
    [ "${#OpenResty_Opm_Packages[@]}" -gt 0 ] && return 0
    [ "${#OpenResty_Luarocks_Packages[@]}" -gt 0 ] && return 0
    return 1
}

# 官方预编译包的模块集合固定，配置自定义编译模块时必须改用源码安装。
_OpenResty_Pkg_Conflict()
{
    _OpenResty_Configured || return 0
    Echo_Red "配置了 OpenResty 自定义编译模块，但安装方式选的是官方软件包（ORMode=1）。"
    Echo_Red "预编译包无法加入编译期模块。二选一："
    Echo_Red "  1) 改用源码编译：ORMode=2 ./install.sh lnmp"
    Echo_Red "  2) 清空 lnmp.conf 里的 OpenResty_Custom_Modules 和 OpenResty_Modules_Options"
    return 1
}

# _OpenResty_Modules：校验自定义模块配置，每个模块输出 名称、地址、SHA256、类型，TAB 分隔。
_OpenResty_Modules()
{
    local entry name url sha kind

    for entry in "${OpenResty_Custom_Modules[@]}"; do
        case "${entry}" in ''|\#*) continue ;; esac
        name=$(_OpenResty_Field "${entry}" 1)
        url=$(_OpenResty_Field "${entry}" 2)
        sha=$(_OpenResty_Field "${entry}" 3)
        kind=$(_OpenResty_Field "${entry}" 4)
        [ -n "${kind}" ] || kind=static
        _OpenResty_Module_Name_Ok "${name}" || return 1
        if [ -z "${url}" ]; then
            Echo_Red "模块 ${name} 缺少下载地址。格式：名称|下载地址|SHA256|static或dynamic"
            return 1
        fi
        case "${url}" in
        https://*) ;;
        *) Echo_Red "模块 ${name} 的下载地址必须是 https://：${url}"; return 1 ;;
        esac
        if [ -z "${sha}" ]; then
            Echo_Red "模块 ${name} 缺少 SHA256。编译进 nginx 的代码必须校验来源。"
            Echo_Red "先下载再算：sha256sum <文件>，把结果填进配置的第三段。"
            return 1
        fi
        case "${kind}" in
        static|dynamic) ;;
        *) Echo_Red "模块 ${name} 的类型只能是 static 或 dynamic，当前是 '${kind}'"; return 1 ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "${name}" "${url}" "${sha}" "${kind}"
    done
    return 0
}

OpenResty_Sources()
{
    local ver=$1 mode=$2 file name url sha mods

    _OpenResty_Ver_Ok "${ver}" || return 1
    case "${mode}" in
    pkg) return 0 ;;
    source) ;;
    *) return 1 ;;
    esac
    mods=$(_OpenResty_Modules) || return 1
    file="openresty-${ver}.tar.gz"
    printf 'openresty\t/usr/local/openresty\t%s\t%s\thttps://openresty.org/download/%s\tpgp\thttps://openresty.org/download/%s.asc\n' \
        "${ver}" "${file}" "${file}" "${file}"
    [ -n "${mods}" ] || return 0
    while IFS=$'\t' read -r name url sha _; do
        printf 'openresty-module\t%s\t-\tor-modules/or-mod-%s.tar.gz\t%s\tsha256\t%s\n' \
            "${name}" "${name}" "${url}" "${sha}"
    done <<< "${mods}"
}

OpenResty_Mode()
{
    if [ ! -d "$(_OpenResty_Prefix)" ]; then
        echo none
    elif [ "${PM}" = apt ] && dpkg -l openresty 2>/dev/null | grep -q '^ii'; then
        echo pkg
    elif [ "${PM}" = yum ] && rpm -q openresty >/dev/null 2>&1; then
        echo pkg
    else
        echo source
    fi
}

OpenResty_Installed()
{
    local bin ver

    [ -d "$(_OpenResty_Prefix)" ] || return 1
    bin="$(_OpenResty_Prefix)/nginx/sbin/nginx"
    [ -x "${bin}" ] || return 2
    ver=$("${bin}" -v 2>&1 | sed -n 's#.*openresty/\([^ ]*\).*#\1#p')
    [ -n "${ver}" ] || return 2
    printf '%s\t%s\n' "${ver}" "$(OpenResty_Mode)"
}

OpenResty_Check()
{
    local ver=$1 mode=$2 prefix bin have

    _OpenResty_Ver_Ok "${ver}" || return 3
    case "${mode}" in pkg|source) ;; *) return 3 ;; esac
    prefix=$(_OpenResty_Prefix)
    bin="${prefix}/nginx/sbin/nginx"
    [ -d /usr/local/nginx ] && [ ! -L /usr/local/nginx ] && return 2
    [ -x "${bin}" ] || return 1
    [ "$(OpenResty_Mode)" = "${mode}" ] || return 2
    if [ "${mode}" = source ]; then
        have=$("${bin}" -v 2>&1 | sed -n 's#.*openresty/\([^ ]*\).*#\1#p')
        [ "${have}" = "${ver}" ] || return 2
        [ -s "$(_OpenResty_Build_Conf)" ] || return 1
    fi
    [ -L /usr/local/nginx ] && [ -s "${prefix}/nginx/conf/vhost/default.conf" ] \
        && [ -s "${prefix}/nginx/conf/lua_paths.conf" ] && [ -s "${prefix}/nginx/conf/load_modules.conf" ] \
        && [ -s "$(_OpenResty_Initd_Dir)/nginx" ] || return 1
    return 0
}

OpenResty_Health()
{
    local prefix

    prefix=$(_OpenResty_Prefix)
    [ -x "${prefix}/nginx/sbin/nginx" ] && [ -L /usr/local/nginx ] && [ -s "${prefix}/nginx/conf/vhost/default.conf" ] \
        && [ -s "${prefix}/nginx/conf/lua_paths.conf" ] && [ -s "${prefix}/nginx/conf/load_modules.conf" ] \
        && [ -s "$(_OpenResty_Initd_Dir)/nginx" ] || return 1
    "${prefix}/nginx/sbin/nginx" -t >/dev/null 2>&1 || return 2
}

# 获取当前发行版在 OpenResty 仓库中的代号，无法确定时返回非零。
_OpenResty_Codename()
{
    local cn=''

    command -v lsb_release >/dev/null 2>&1 && cn=$(lsb_release -sc 2>/dev/null)
    if [ -z "${cn}" ] && [ -s /etc/os-release ]; then
        cn=$(awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
    fi
    [ -n "${cn}" ] || return 1
    printf '%s' "${cn}"
}

# _OpenResty_Install_Pkg：在子 shell 中调用，从官方仓库安装预编译包。
_OpenResty_Install_Pkg()
{
    local codename repo_url or_tmp or_key rf='openresty.repo'

    if [ "${PM}" = apt ]; then
        if ! codename=$(_OpenResty_Codename); then
            Echo_Red "无法确定当前发行版代号（lsb_release 与 /etc/os-release 都没给出）。"
            Echo_Red "请改用源码编译方式安装 OpenResty。"
            return 1
        fi
        # 写入 APT 源前确认发行版目录存在，避免无效源影响后续 apt 操作。
        repo_url="https://openresty.org/package/debian/dists/${codename}/Release"
        [ "${DISTRO}" = Ubuntu ] && repo_url="https://openresty.org/package/ubuntu/dists/${codename}/Release"
        echo "检查 OpenResty 官方仓库是否提供 ${DISTRO} ${codename} 的包..."
        if ! Download_Head_OK "${repo_url}"; then
            Echo_Red "OpenResty 官方仓库没有 ${codename} 的软件包（已探测：${repo_url}）。"
            Echo_Yellow "这是上游尚未发布该发行版的包。可改用源码编译方式安装 OpenResty，或改用 nginx 官方版。"
            return 1
        fi
        Echo_Green "仓库中存在 ${codename} 的包，继续。"
        Apt_Get -y install --no-install-recommends wget gnupg ca-certificates lsb-release >/dev/null 2>&1

        # 通过 signed-by 将公钥限定到 OpenResty 软件源；公钥下载使用权限受限的随机临时目录。
        mkdir -p /usr/share/keyrings || return 1
        or_tmp=$(umask 077; mktemp -d) || { Echo_Red "无法创建临时目录。"; return 1; }
        or_key="${or_tmp}/pubkey.gpg"
        if ! Download_Fetch "https://openresty.org/package/pubkey.gpg" "${or_key}"; then
            rm -rf "${or_tmp}"
            Echo_Red "下载 OpenResty 仓库公钥失败。"
            return 1
        fi
        # 公钥已经是二进制格式时直接安装。
        if ! gpg --dearmor < "${or_key}" > /usr/share/keyrings/openresty.gpg 2>/dev/null \
           && ! cp -f "${or_key}" /usr/share/keyrings/openresty.gpg; then
            rm -rf "${or_tmp}"
            return 1
        fi
        rm -rf "${or_tmp}"
        chmod 644 /usr/share/keyrings/openresty.gpg
        if [ "${DISTRO}" = Ubuntu ]; then
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openresty.gpg] https://openresty.org/package/ubuntu ${codename} main" \
                > /etc/apt/sources.list.d/openresty.list
        else
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openresty.gpg] https://openresty.org/package/debian ${codename} openresty" \
                > /etc/apt/sources.list.d/openresty.list
        fi
        Apt_Get update -y
        if ! Apt_Get -y install --no-install-recommends openresty; then
            Echo_Red "安装 openresty 包失败，可执行 apt-get install openresty 查看具体报错，或改用源码编译方式。"
            return 1
        fi
    elif [ "${PM}" = yum ]; then
        # EL9 及以上使用 openresty2.repo，EL8 及更早使用 openresty.repo。
        case "${DISTRO_Version}" in 9*|10*) rf='openresty2.repo' ;; esac
        echo "使用 https://openresty.org/package/centos/${rf}"
        if ! Download_Fetch "https://openresty.org/package/centos/${rf}" /etc/yum.repos.d/openresty.repo; then
            Echo_Red "下载 OpenResty 仓库定义失败。若当前发行版不受支持，请改用源码编译方式。"
            return 1
        fi
        if ! ${PM} install -y openresty; then
            Echo_Red "安装 openresty 包失败。请改用源码编译方式，或检查 ${rf} 是否适配本系统。"
            return 1
        fi
    else
        Echo_Red "未知的包管理器（PM=${PM}），无法用仓库方式安装 OpenResty，请改用源码编译方式。"
        return 1
    fi

    if [ ! -s "$(_OpenResty_Prefix)/nginx/sbin/nginx" ]; then
        Echo_Red "包装好了，但没找到 $(_OpenResty_Prefix)/nginx/sbin/nginx，上游可能改了安装前缀。"
        return 1
    fi
    return 0
}

# _OpenResty_Fetch <版本>：在子 shell 中调用。源码包经上游 PGP 签名验证，自定义模块按配置的 SHA256 校验。
_OpenResty_Fetch()
{
    local ver=$1 file url sha kind

    mkdir -p "${cur_dir}/src/or-modules" || return 1
    cd "${cur_dir}/src" || return 1
    while IFS=$'\t' read -r kind _ _ file url _ sha; do
        if [ ! -s "${file}" ]; then
            echo "下载 ${file} ..."
            Download_Fetch "${url}" "${cur_dir}/src/${file}" || { Echo_Red "下载失败：${url}"; rm -f "${file}"; return 1; }
        else
            echo "${file} [已找到]"
        fi
        if [ "${kind}" = openresty ]; then
            if ! Verify_OpenResty_Signature "${cur_dir}/src/${file}" "${url}"; then
                Echo_Red "OpenResty 源码包验签未通过。"
                rm -f "${file}"
                return 1
            fi
        elif ! Verify_SHA256_Value "${file}" "${sha}"; then
            Echo_Red "${file} 校验未通过，已删除下载的文件。"
            rm -f "${file}"
            return 1
        fi
    done < <(OpenResty_Sources "${ver}" source)
}

# _OpenResty_Unpack_Module <归档> <目标目录>：去除上游归档的可变顶层目录，使 configure 使用稳定路径。
_OpenResty_Unpack_Module()
{
    local tarball=$1 dir=$2 link target

    if tar -tzf "${tarball}" 2>/dev/null | grep -qE '^/|(^|/)\.\.(/|$)'; then
        return 1
    fi
    mkdir -p "${dir}" || return 1
    tar zxf "${tarball}" -C "${dir}" --strip-components=1 --no-same-owner --no-same-permissions || return 1
    while IFS= read -r link; do
        target=$(readlink "${link}")
        case "${target}" in /*|*..*) return 1 ;; esac
    done < <(find "${dir}" -type l)
    return 0
}

# _OpenResty_Configure_Args <构建目录>：每行一个 configure 参数，自定义模块位于构建目录的 or-mod-<名称>。
_OpenResty_Configure_Args()
{
    local bdir=$1 name kind sslv
    local -a extra=()

    printf '%s\n' "-j$(nproc 2>/dev/null || echo 2)" --prefix=/usr/local/openresty --with-pcre-jit --with-ipv6 \
        --with-http_ssl_module --with-http_v2_module --with-http_realip_module \
        --with-http_stub_status_module --with-http_gzip_static_module
    # 链接系统 OpenSSL：HTTP/3 需要 1.1.1 及以上，低于 3.5.1 时由 nginx 兼容层提供 QUIC。
    sslv=$(openssl version 2>/dev/null | awk '{ print $2 }')
    Version_GE "${sslv%%[!0-9.]*}" 1.1.1 && printf '%s\n' --with-http_v3_module
    read -r -a extra <<< "${OpenResty_Modules_Options}"
    [ "${#extra[@]}" -gt 0 ] && printf '%s\n' "${extra[@]}"
    while IFS=$'\t' read -r name _ _ kind; do
        if [ "${kind}" = dynamic ]; then
            printf '%s\n' "--add-dynamic-module=${bdir}/or-mod-${name}"
        else
            printf '%s\n' "--add-module=${bdir}/or-mod-${name}"
        fi
    done < <(_OpenResty_Modules)
}

# _OpenResty_Build <版本> <构建目录>：在子 shell 中调用。编译安装到 /usr/local/openresty，
# 并在构建目录写入 .built-modules（本次生成的动态模块 .so 名称）。
_OpenResty_Build()
{
    local ver=$1 bdir=$2 name kind so
    local -a args=()

    if ! Unpack_Checked "${cur_dir}/src/openresty-${ver}.tar.gz" "${bdir}" "openresty-${ver}"; then
        Echo_Red "openresty-${ver}.tar.gz 解压失败或归档成员不合规。"
        return 1
    fi
    while IFS=$'\t' read -r name _ _ kind; do
        if ! _OpenResty_Unpack_Module "${cur_dir}/src/or-modules/or-mod-${name}.tar.gz" "${bdir}/or-mod-${name}"; then
            Echo_Red "解压模块 ${name} 失败或归档成员不合规。"
            return 1
        fi
        if [ ! -s "${bdir}/or-mod-${name}/config" ]; then
            Echo_Red "模块 ${name} 解压后没有 config 文件，不像是 nginx 模块源码，确认下载地址指向模块仓库的归档包。"
            return 1
        fi
        echo "  模块 ${name}：${kind}"
    done < <(_OpenResty_Modules)

    cd "${bdir}/openresty-${ver}" || return 1
    mapfile -t args < <(_OpenResty_Configure_Args "${bdir}")
    if ! ./configure "${args[@]}" || ! Check_Makefile_Ready; then
        Echo_Red "OpenResty configure 失败。常见原因是缺少 libpcre2-dev / libssl-dev。"
        return 1
    fi
    make -j"$(Build_Jobs)" || { Echo_Red "OpenResty 编译失败。"; return 1; }
    # 模块配置名不一定等于 .so 文件名，以构建目录中的产物为准。
    for so in build/nginx-*/objs/*.so; do
        [ -f "${so}" ] && printf '%s\n' "${so##*/}"
    done | LC_ALL=C sort -u > "${bdir}/.built-modules" || return 1
    make install || { Echo_Red "OpenResty make install 失败。"; return 2; }
    [ -s /usr/local/openresty/nginx/sbin/nginx ] || { Echo_Red "编译完成但未生成 /usr/local/openresty/nginx/sbin/nginx。"; return 2; }
}

_OpenResty_Cleanup()
{
    case "$1" in
    "${cur_dir}"/src/.openresty-build.*) rm -rf -- "$1" ;;
    esac
}

# _OpenResty_Load_Modules_Conf <本次构建的模块清单>：动态模块的 load_module 指令。
# --add-dynamic-module 只把 .so 放进 modules/，nginx 不会自动加载；
# 只删除 LNMP 上次加载但本次未构建的模块，保留手工放置的 .so。
_OpenResty_Load_Modules_Conf()
{
    local built=$1 prefix conf moddir name old n=0 tmp

    prefix=$(_OpenResty_Prefix)
    conf="${prefix}/nginx/conf/load_modules.conf"
    moddir="${prefix}/nginx/modules"
    mkdir -p "${conf%/*}" || return 1
    tmp=$(mktemp "${conf}.XXXXXXXX") || return 1
    if [ -f "${built}" ] && [ -f "${conf}" ]; then
        old=$(sed -n 's#^[[:space:]]*load_module[[:space:]]\+modules/\([^;]*\.so\);#\1#p' "${conf}")
        for name in ${old}; do
            grep -Fxq -- "${name}" "${built}" && continue
            rm -f -- "${moddir}/${name}" || { rm -f "${tmp}"; return 1; }
        done
    fi
    {
        echo "# 由 lnmp 自动生成：OpenResty 动态模块的加载指令。"
        echo "# 重新编译（安装或 ./upgrade.sh openresty）时会重写本文件，手工修改会丢失。"
        if [ -f "${built}" ]; then
            while IFS= read -r name; do
                [ -n "${name}" ] || continue
                if [ ! -f "${moddir}/${name}" ]; then
                    Echo_Red "本次构建记录了 ${name}，但 make install 后未找到 ${moddir}/${name}。"
                    rm -f "${tmp}"
                    return 1
                fi
                printf 'load_module modules/%s;\n' "${name}"
                n=$((n + 1))
            done < "${built}"
        fi
        if [ "${n}" -eq 0 ]; then echo "# （当前没有动态模块）"; fi
    } > "${tmp}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "${conf}" || { rm -f "${tmp}"; return 1; }
    chmod 644 "${conf}"
    if [ "${n}" -gt 0 ]; then echo "已生成 ${n} 条 load_module 指令：${conf}"; fi
    return 0
}

# 自定义 lualib 目录要进 lua_package_path，单独成文件由 nginx.conf include。
_OpenResty_Lua_Paths_Conf()
{
    local prefix conf tmp extra_lua='' extra_c=''

    prefix=$(_OpenResty_Prefix)
    conf="${prefix}/nginx/conf/lua_paths.conf"
    if [ -n "${OpenResty_Custom_Lualib}" ]; then
        case "${OpenResty_Custom_Lualib}" in
        /*) ;;
        *) Echo_Red "OpenResty_Custom_Lualib 必须是绝对路径：${OpenResty_Custom_Lualib}"; return 1 ;;
        esac
        if [ ! -d "${OpenResty_Custom_Lualib}" ]; then
            echo "自定义 Lua 库目录不存在，创建：${OpenResty_Custom_Lualib}"
            mkdir -p "${OpenResty_Custom_Lualib}" || return 1
        fi
        extra_lua="${OpenResty_Custom_Lualib}/?.lua;${OpenResty_Custom_Lualib}/?/init.lua;"
        extra_c="${OpenResty_Custom_Lualib}/?.so;"
    fi
    mkdir -p "${conf%/*}" || return 1
    tmp=$(mktemp "${conf}.XXXXXXXX") || return 1
    {
        echo "# 由 lnmp 自动生成：OpenResty 的 Lua 搜索路径。"
        echo "# 自定义目录来自 lnmp.conf 的 OpenResty_Custom_Lualib，重新编译时会重写。"
        echo "# 结尾的 \";;\" 表示保留 Lua 的默认搜索路径。"
        printf 'lua_package_path "%s/lualib/?.lua;%s/lualib/?/init.lua;%s;;";\n' \
            "/usr/local/openresty" "/usr/local/openresty" "${extra_lua%;}"
        printf 'lua_package_cpath "%s/lualib/?.so;%s;;";\n' "/usr/local/openresty" "${extra_c%;}"
    } > "${tmp}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "${conf}" || { rm -f "${tmp}"; return 1; }
    chmod 644 "${conf}"
}

# opm 装 lua-resty-* 这类纯 Lua 库；luarocks 仅在系统已安装时使用。
# Lua 包失败不影响 Web 服务，可稍后补装。
_OpenResty_Lua_Packages()
{
    local pkg failed=0 opm rocks

    opm="$(_OpenResty_Prefix)/bin/opm"
    if [ "${#OpenResty_Opm_Packages[@]}" -gt 0 ]; then
        if [ ! -x "${opm}" ]; then
            Echo_Red "配置了 OpenResty_Opm_Packages，但没有 ${opm}（包安装方式可能不带 opm）。"
            failed=1
        else
            for pkg in "${OpenResty_Opm_Packages[@]}"; do
                case "${pkg}" in ''|\#*) continue ;; esac
                echo "opm get ${pkg}"
                "${opm}" get "${pkg}" || { Echo_Red "opm 安装失败：${pkg}"; failed=1; }
            done
        fi
    fi
    if [ "${#OpenResty_Luarocks_Packages[@]}" -gt 0 ]; then
        rocks=$(command -v luarocks 2>/dev/null)
        if [ -z "${rocks}" ]; then
            Echo_Red "配置了 OpenResty_Luarocks_Packages，但系统里没有 luarocks，先安装 luarocks 再重跑。"
            failed=1
        else
            for pkg in "${OpenResty_Luarocks_Packages[@]}"; do
                case "${pkg}" in ''|\#*) continue ;; esac
                echo "luarocks install ${pkg}"
                # 包名后可跟版本号，按空白拆分为参数。
                # shellcheck disable=SC2086
                "${rocks}" install ${pkg} || { Echo_Red "luarocks 安装失败：${pkg}"; failed=1; }
            done
        fi
    fi
    [ "${failed}" -eq 0 ] || Echo_Red "部分 Lua 包未安装成功，Web 服务不受影响，可稍后手工补装。"
    return 0
}

# 保存本次编译配置，使升级时继续包含相同模块和 Lua 库。
_OpenResty_Persist()
{
    local conf tmp m

    conf=$(_OpenResty_Build_Conf)
    mkdir -p "${conf%/*}" 2>/dev/null && chmod 700 "${conf%/*}" 2>/dev/null
    tmp=$(mktemp "${conf}.XXXXXXXX") || return 1
    {
        echo "# OpenResty 编译期配置 —— 由安装流程自动生成。"
        echo "# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
        echo "#"
        echo "# ./upgrade.sh openresty 会读取本文件，用同一组模块重新编译。"
        echo "# lnmp.conf 里显式配置了模块时以 lnmp.conf 为准，本文件作为后备。"
        echo ""
        printf 'OpenResty_Modules_Options=%q\n' "${OpenResty_Modules_Options}"
        printf 'OpenResty_Custom_Lualib=%q\n' "${OpenResty_Custom_Lualib}"
        echo "OpenResty_Custom_Modules=("
        for m in "${OpenResty_Custom_Modules[@]}"; do printf '    %q\n' "${m}"; done
        echo ")"
        echo "OpenResty_Opm_Packages=("
        for m in "${OpenResty_Opm_Packages[@]}"; do printf '    %q\n' "${m}"; done
        echo ")"
        echo "OpenResty_Luarocks_Packages=("
        for m in "${OpenResty_Luarocks_Packages[@]}"; do printf '    %q\n' "${m}"; done
        echo ")"
    } > "${tmp}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "${conf}" || { rm -f "${tmp}"; return 1; }
    chmod 600 "${conf}"
    echo "编译期配置已记录到 ${conf}，升级时会自动沿用。"
}

# 升级时优先使用 lnmp.conf 的显式配置；未配置时加载安装阶段保存的设置。
_OpenResty_Load_Persisted()
{
    local conf

    conf=$(_OpenResty_Build_Conf)
    [ -f "${conf}" ] || return 0
    if _OpenResty_Configured; then
        echo "使用当前配置中的 OpenResty 模块设置（未沿用 ${conf}）。"
        return 0
    fi
    # shellcheck disable=SC1090
    . "${conf}" || { Echo_Red "读取 ${conf} 失败。"; return 1; }
    _OpenResty_Configured && echo "沿用初装时记录的 OpenResty 模块配置（${conf}）。"
    return 0
}

# _OpenResty_Post_Build <本次构建的模块清单>：模块加载与 Lua 路径配置，附加 Lua 包。
_OpenResty_Post_Build()
{
    _OpenResty_Load_Modules_Conf "$1" || return 1
    _OpenResty_Lua_Paths_Conf || return 1
    _OpenResty_Lua_Packages
}

# _OpenResty_Configure <栈> <模块清单>：模板、包含文件、兼容软链接与服务脚本。
_OpenResty_Configure()
{
    local stack=$1 ordir conf_stack

    ordir="$(_OpenResty_Prefix)/nginx"
    echo "配置 OpenResty ..."
    id -u www >/dev/null 2>&1 || useradd -M -U -s /sbin/nologin www 2>/dev/null
    mkdir -p "${ordir}/conf/vhost" "${Default_Website_Dir}" || return 1
    mkdir -p /home/wwwlogs
    [ -s "${ordir}/conf/nginx.conf" ] && [ ! -s "${ordir}/conf/nginx.conf.orig" ] && \
        cp -a "${ordir}/conf/nginx.conf" "${ordir}/conf/nginx.conf.orig"

    # OpenResty 使用独立模板：Lua 搜索路径指向自带的 lualib，与源码版 nginx 的路径不能混用。
    \cp "${cur_dir}/conf/openresty.conf" "${ordir}/conf/nginx.conf" || return 1
    \cp -r "${cur_dir}/conf/rewrite" "${ordir}/conf/" || return 1
    \cp "${cur_dir}/conf/pathinfo.conf" "${ordir}/conf/pathinfo.conf" || return 1
    \cp "${cur_dir}/conf/enable-php.conf" "${ordir}/conf/enable-php.conf" || return 1
    \cp "${cur_dir}/conf/enable-php-pathinfo.conf" "${ordir}/conf/enable-php-pathinfo.conf" || return 1
    mkdir -p "${ordir}/conf/example" && \cp -r "${cur_dir}/conf/example/." "${ordir}/conf/example/" 2>/dev/null
    # 源码树属主随解包者而定；覆盖复制不改已有文件属主，统一归 root。
    chown -R root:root "${ordir}/conf/rewrite" "${ordir}/conf/example" || return 1

    if [ -e /usr/local/nginx ] && [ ! -L /usr/local/nginx ]; then
        Echo_Red "/usr/local/nginx 已存在且不是软链，无法建立到 OpenResty 的链接。"
        return 1
    fi
    ln -sfn "${ordir}" /usr/local/nginx || return 1
    echo "已建立软链 /usr/local/nginx -> ${ordir}"

    # 禁用软件包自带的服务单元，避免与 LNMP 同时管理同一进程和 pid 文件。
    if systemctl list-unit-files 2>/dev/null | grep -q '^openresty\.service'; then
        systemctl stop openresty >/dev/null 2>&1
        systemctl disable openresty >/dev/null 2>&1
        echo "已停用随包的 openresty.service，服务改由 lnmp / /etc/init.d/nginx 管理。"
    fi

    chown -R www:www "${Default_Website_Dir}" 2>/dev/null
    # 安装进程可能继承 umask 077，mkdir 出来的目录会是 700，需显式校正。
    chmod 755 "${Default_Website_Dir}"
    chown root:root /home/wwwlogs
    chmod 755 /home/wwwlogs

    # .user.ini 会被置为 immutable，放在递归授权之后。
    conf_stack=$(Nginx_Conf_Stack "${stack}")
    Nginx_Site_Conf "${ordir}/conf" "${conf_stack}" install || return 1
    # 在 nginx -t 前生成动态模块和 Lua 搜索路径配置，确保 include 文件存在。
    if ! _OpenResty_Post_Build "$2"; then
        Echo_Red "生成模块与 Lua 路径配置失败。"
        return 1
    fi
    if ! "${ordir}/sbin/nginx" -t; then
        Echo_Red "OpenResty 配置检查未通过，请查看上面的报错。"
        return 1
    fi
    _OpenResty_Write_Initd
}

# _OpenResty_Write_Initd：同目录暂存后换名写入随包 init 脚本。
_OpenResty_Write_Initd()
{
    local initd tmp

    initd=$(_OpenResty_Initd_Dir)
    tmp=$(mktemp "${initd}/.nginx.XXXXXX") || return 1
    if ! \cp "${cur_dir}/init.d/init.d.nginx" "${tmp}" || ! chmod 755 "${tmp}" \
       || ! mv -f "${tmp}" "${initd}/nginx"; then
        rm -f "${tmp}"
        Echo_Red "写入 ${initd}/nginx 失败。"
        return 1
    fi
}

OpenResty_Install()
{
    local ver=$1 mode=$2 stack=$3 rc bdir built=''

    OpenResty_Check "${ver}" "${mode}"
    rc=$?
    case "${rc}" in
    0) Echo_Green "OpenResty 已就绪，无需安装。"; return 0 ;;
    2) Echo_Red "已安装的 OpenResty 安装方式或版本与期望不符，或已安装源码版 Nginx，未改动。"; return 2 ;;
    3) Echo_Red "OpenResty 安装参数错误：${ver} ${mode}"; return 3 ;;
    esac
    Echo_Blue "[+] 正在安装 OpenResty（${mode}）..."
    Nginx_Conflict openresty || return 1

    if [ "${mode}" = pkg ]; then
        _OpenResty_Pkg_Conflict || return 1
        ( _OpenResty_Install_Pkg ) || return 1
    else
        ( _OpenResty_Fetch "${ver}" ) || return 1
        bdir=$(mktemp -d "${cur_dir}/src/.openresty-build.XXXXXXXX") || return 1
        if ! ( _OpenResty_Build "${ver}" "${bdir}" ); then
            _OpenResty_Cleanup "${bdir}"
            return 1
        fi
        built="${bdir}/.built-modules"
    fi
    if ! _OpenResty_Configure "${stack}" "${built}"; then
        [ -n "${bdir}" ] && _OpenResty_Cleanup "${bdir}"
        return 1
    fi
    [ -n "${bdir}" ] && _OpenResty_Cleanup "${bdir}"
    if [ "${mode}" = source ] && ! _OpenResty_Persist; then
        Echo_Red "OpenResty 已安装，但编译期配置持久化失败，不能报告安装完成。"
        return 1
    fi
    Echo_Green "OpenResty 安装完成：$("$(_OpenResty_Prefix)/nginx/sbin/nginx" -v 2>&1)"
    return 0
}

# _OpenResty_Upgrade_Pkg：通过系统包管理器升级，--force-confold 保留当前站点配置。
_OpenResty_Upgrade_Pkg()
{
    if [ "${PM}" = apt ]; then
        Apt_Get update -y
        if ! DEBIAN_FRONTEND=noninteractive Apt_Get -y -o Dpkg::Options::="--force-confold" \
             install --only-upgrade openresty; then
            Echo_Red "apt 升级 openresty 失败。"
            return 1
        fi
    elif [ "${PM}" = yum ]; then
        ${PM} update -y openresty || { Echo_Red "${PM} 升级 openresty 失败。"; return 1; }
    else
        Echo_Red "未知的包管理器（PM=${PM}），无法升级。"
        return 1
    fi
}

# _OpenResty_Upgrade_Source <版本>：0 成功；1 线上未改动；2 make install 之后失败。
_OpenResty_Upgrade_Source()
{
    local ver=$1 bdir bak rc

    bak="$(_OpenResty_Prefix)/nginx/conf.bak.$(date +%Y%m%d%H%M%S)"
    # 沿用安装时的模块配置，避免升级后缺少现有功能。
    _OpenResty_Load_Persisted || { Echo_Red "读取已记录的模块配置失败，升级中止。"; return 1; }
    ( _OpenResty_Fetch "${ver}" ) || { Echo_Red "**现有 OpenResty 未做任何改动。**"; return 1; }
    cp -a "$(_OpenResty_Prefix)/nginx/conf" "${bak}" && echo "已备份配置到 ${bak}"
    bdir=$(mktemp -d "${cur_dir}/src/.openresty-build.XXXXXXXX") || return 1
    ( _OpenResty_Build "${ver}" "${bdir}" )
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        _OpenResty_Cleanup "${bdir}"
        if [ "${rc}" -eq 2 ]; then
            Echo_Red "安装可能处于半完成状态，配置备份在 ${bak}"
            return 2
        fi
        Echo_Red "现有安装未被替换。"
        return 1
    fi
    if ! _OpenResty_Post_Build "${bdir}/.built-modules"; then
        _OpenResty_Cleanup "${bdir}"
        Echo_Red "生成模块与 Lua 路径配置失败。"
        return 2
    fi
    _OpenResty_Cleanup "${bdir}"
    _OpenResty_Persist || { Echo_Red "OpenResty 已升级，但编译期配置持久化失败。"; return 2; }
}

OpenResty_Upgrade()
{
    local mode=$1 ver=${2:-} cur new bin rc conf_stack

    bin="$(_OpenResty_Prefix)/nginx/sbin/nginx"
    cur=$("${bin}" -v 2>&1 | sed 's/.*openresty\///;s/ .*//')
    case "${mode}" in
    pkg) _OpenResty_Upgrade_Pkg; rc=$? ;;
    source)
        _OpenResty_Ver_Ok "${ver}" || { Echo_Red "OpenResty 版本号不合法：${ver}"; return 1; }
        _OpenResty_Upgrade_Source "${ver}"; rc=$?
        ;;
    *) Echo_Red "未检测到 OpenResty（$(_OpenResty_Prefix) 不存在）。若装的是 nginx 官方版，请用：./upgrade.sh nginx"; return 1 ;;
    esac
    [ "${rc}" -eq 0 ] || return "${rc}"
    new=$("${bin}" -v 2>&1 | sed 's/.*openresty\///;s/ .*//')
    echo "升级后版本：${new:-未知}"

    # 补齐缺失的反代包含文件，已存在的保留站点自己的修改。
    conf_stack=$(Nginx_Conf_Stack nginx)
    Nginx_Site_Conf "$(_OpenResty_Prefix)/nginx/conf" "${conf_stack}" keep \
        || Echo_Red "补齐反代包含文件失败，可手工 cp conf/proxy.conf 到 $(_OpenResty_Prefix)/nginx/conf/。"
    if ! "${bin}" -t; then
        Echo_Red "升级后配置检查未通过 —— 服务**没有**重载，站点仍在用旧进程。"
        Echo_Red "请先修正配置，再执行：/etc/init.d/nginx restart"
        return 2
    fi
    # make install 把运行中的二进制改名为 .old，旧版 init 脚本据此判为未运行，重启前换为随包版本。
    if [ "${mode}" = source ] && ! _OpenResty_Write_Initd; then
        Echo_Red "站点仍在用旧进程，请手工执行：/etc/init.d/nginx restart"
        return 2
    fi
    "$(_OpenResty_Initd_Dir)/nginx" restart || return 2
    Echo_Green "OpenResty 升级完成：${cur:-未知} -> ${new:-未知}"
    return 0
}

OpenResty_Remove()
{
    echo "移除 OpenResty ..."
    if ! Preserve_Paths "$(_OpenResty_Prefix)/nginx/conf/vhost" "$(_OpenResty_Prefix)/nginx/conf/ssl"; then
        Echo_Red "虚拟主机配置或证书未能保存，未移除 OpenResty。"
        return 1
    fi
    [ -x "$(_OpenResty_Initd_Dir)/nginx" ] && "$(_OpenResty_Initd_Dir)/nginx" stop 2>/dev/null
    systemctl stop openresty 2>/dev/null
    systemctl disable openresty 2>/dev/null
    if [ "${PM}" = apt ] && dpkg -l openresty 2>/dev/null | grep -q '^ii'; then
        Apt_Get -y remove --purge openresty 2>/dev/null
        rm -f /etc/apt/sources.list.d/openresty.list /usr/share/keyrings/openresty.gpg
    elif [ "${PM}" = yum ] && rpm -q openresty >/dev/null 2>&1; then
        ${PM} remove -y openresty 2>/dev/null
        rm -f /etc/yum.repos.d/openresty.repo
    fi
    # 先删除兼容软链接，再清理 OpenResty 实际目录。
    [ -L /usr/local/nginx ] && rm -f /usr/local/nginx
    rm -rf -- "$(_OpenResty_Prefix)"
    Echo_Green "OpenResty 已移除。"
    return 0
}
