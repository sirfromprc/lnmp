#!/usr/bin/env bash
#
# Apache 模块：httpd 及随包编译的 APR、APR-util，LAMP 另带 nghttp2 与（系统 OpenSSL 低于 3 时的）OpenSSL 3；
# 配置模板、MPM 调优、init 脚本与 unit。栈为 lamp（Apache 直接对外）或 lnmpa（Nginx 反代到 127.0.0.1:88）。
# 新装 PHP 经 mod_proxy_fcgi 交给 PHP-FPM，MPM 为 event，二者在 extra/lnmp-php.conf；
# 已有 mod_php 的存量主配置沿用 prefork，不改写。
#
#   Apache_Sources <版本> <栈>   输出下载清单，不下载、不写文件
#   Apache_Installed             输出已装的版本；0 已装；1 未装；2 程序不可读
#   Apache_Check   <版本> <栈>   0 就绪；1 缺失或不完整；2 版本或编译参数不符；3 参数错误
#   Apache_Install <版本> <栈>   Check 为 0 时不写文件；失败时删除本次新建的安装目录与 init 脚本
#   Apache_Verify  <版本> <栈>   Check 通过后做配置测试
#   Apache_Health                不比较版本与编译参数：0 配置与服务文件完整且配置测试通过；1 文件缺失；2 配置测试未通过
#   Apache_Remove                停止服务，删除启动项、init 脚本与安装目录；0 已删除；1 有残留
#
# 约定：不交互、不 exit、不改变调用方工作目录；编译在 src/ 下的私有目录与子 shell 中进行。
# 输入为参数与只读配置（lnmp.conf 的 Default_Website_Dir、ServerAdmin，include/version.sh，cur_dir）。
# 例外：MPM 调优在模块内调用 Tune_Plan（codetradeoffs.md 19.42）。

_Apache_Prefix()
{
    printf '%s\n' "${LNMP_APACHE_PREFIX:-/usr/local/apache}"
}

_Apache_Initd_Dir()
{
    printf '%s\n' "${LNMP_INITD_DIR:-/etc/init.d}"
}

_Apache_Unit_Dir()
{
    printf '%s\n' "${LNMP_UNIT_DIR:-/etc/systemd/system}"
}

_Apache_Args()
{
    [[ "$1" =~ ^2\.4\.[0-9]+$ ]] || return 1
    case "$2" in lamp|lnmpa) return 0 ;; esac
    return 1
}

# _Apache_Need_Openssl <栈>：LAMP 在系统 OpenSSL 低于 3 时需自编 OpenSSL 3。
_Apache_Need_Openssl()
{
    [ "$1" = lamp ] || return 1
    ! openssl version 2>/dev/null | grep -Eqi 'OpenSSL 3\.'
}

# _Apache_Row <文件名> <URL>：附上组件、实例与版本列输出一行清单，校验依据为 src/checksums.sha256。
_Apache_Row()
{
    printf 'apache\t%s\t%s\t%s\t%s\tsha256\tsrc/checksums.sha256\n' "$(_Apache_Prefix)" "${_apache_ver}" "$1" "$2"
}

Apache_Sources()
{
    local _apache_ver=$1 stack=$2

    _Apache_Args "${_apache_ver}" "${stack}" || return 1
    _Apache_Row "httpd-${_apache_ver}.tar.bz2" "https://archive.apache.org/dist/httpd/httpd-${_apache_ver}.tar.bz2"
    _Apache_Row "${APR_Ver}.tar.bz2" "https://archive.apache.org/dist/apr/${APR_Ver}.tar.bz2"
    _Apache_Row "${APR_Util_Ver}.tar.bz2" "https://archive.apache.org/dist/apr/${APR_Util_Ver}.tar.bz2"
    [ "${stack}" = lamp ] || return 0
    _Apache_Row "${Nghttp2_Ver}.tar.xz" \
        "https://github.com/nghttp2/nghttp2/releases/download/v${Nghttp2_Ver#nghttp2-}/${Nghttp2_Ver}.tar.xz"
    if _Apache_Need_Openssl "${stack}"; then
        _Apache_Row "${Openssl_New_Ver}.tar.gz" \
            "https://github.com/openssl/openssl/releases/download/${Openssl_New_Ver}/${Openssl_New_Ver}.tar.gz"
        _Apache_Row "${Openssl_New_Ver}.tar.gz" "https://www.openssl.org/source/${Openssl_New_Ver}.tar.gz"
    fi
    return 0
}

# _Apache_Configure_Args <栈>：每行一个 configure 参数。
_Apache_Configure_Args()
{
    printf '%s\n' "--prefix=$(_Apache_Prefix)" --enable-mods-shared=most --enable-headers --enable-mime-magic \
        --enable-proxy --enable-so --enable-rewrite --enable-ssl
    if [ "$1" = lamp ]; then
        if _Apache_Need_Openssl lamp; then
            echo --with-ssl=/usr/local/openssl3
        else
            echo --with-ssl
        fi
        printf '%s\n' --enable-deflate --with-pcre --with-included-apr --with-apr-util --enable-mpms-shared=all \
            --enable-remoteip --enable-http2 --with-nghttp2=/usr/local/nghttp2
    else
        printf '%s\n' --with-ssl --enable-deflate --with-pcre --with-included-apr --with-apr-util \
            --enable-mpms-shared=all --enable-remoteip
    fi
}

# _Apache_Built_Args：从 build/config.nice 读回 configure 参数，每行一个。
_Apache_Built_Args()
{
    sed -n 's/^"\(--[^"]*\)" \\$/\1/p' "$(_Apache_Prefix)/build/config.nice" 2>/dev/null
}

# 随包 httpd.conf 模板才有的行，用于区分中断安装留下的上游默认配置。
_Apache_Template_Mark='IncludeOptional conf/vhost/\*\.conf'

# _Apache_Binary_State <版本> <栈>：0 程序与编译参数符合；1 程序缺失或不完整；2 版本或编译参数不符。
_Apache_Binary_State()
{
    local prefix have

    prefix=$(_Apache_Prefix)
    [ -x "${prefix}/bin/httpd" ] || return 1
    have=$("${prefix}/bin/httpd" -v 2>/dev/null | sed -n 's#^Server version: Apache/\([0-9.]*\).*#\1#p')
    [ -n "${have}" ] || return 1
    [ "${have}" = "$1" ] || return 2
    [ "$(_Apache_Built_Args | LC_ALL=C sort)" = "$(_Apache_Configure_Args "$2" | LC_ALL=C sort)" ] || return 2
    [ -x "${prefix}/bin/apxs" ]
}

Apache_Remove()
{
    local prefix init

    prefix=$(_Apache_Prefix)
    case "${prefix}" in /|'') return 1 ;; esac
    if ! Preserve_Paths "${prefix}/conf/vhost" "${prefix}/conf/ssl"; then
        Echo_Red "虚拟主机配置或证书未能保存，未删除 ${prefix}。"
        return 1
    fi
    init="$(_Apache_Initd_Dir)/httpd"
    [ -x "${init}" ] && "${init}" stop >/dev/null 2>&1
    Remove_StartUp httpd >/dev/null 2>&1
    rm -f "${init}"
    rm -rf -- "${prefix}"
    [ ! -e "${prefix}" ] && [ ! -e "${init}" ]
}

Apache_Installed()
{
    local prefix ver

    prefix=$(_Apache_Prefix)
    [ -d "${prefix}" ] || return 1
    [ -x "${prefix}/bin/httpd" ] || return 2
    ver=$("${prefix}/bin/httpd" -v 2>/dev/null | sed -n 's#^Server version: Apache/\([0-9.]*\).*#\1#p')
    [ -n "${ver}" ] || return 2
    printf '%s\n' "${ver}"
}

Apache_Check()
{
    local ver=$1 stack=$2 prefix rc

    _Apache_Args "${ver}" "${stack}" || return 3
    prefix=$(_Apache_Prefix)
    _Apache_Binary_State "${ver}" "${stack}"
    rc=$?
    [ "${rc}" -eq 0 ] || return "${rc}"
    grep -q "^${_Apache_Template_Mark}" "${prefix}/conf/httpd.conf" 2>/dev/null \
        && [ -s "${prefix}/conf/extra/httpd-vhosts.conf" ] \
        && [ -s "$(_Apache_Initd_Dir)/httpd" ] && [ -s "$(_Apache_Unit_Dir)/httpd.service" ] || return 1
    return 0
}

Apache_Health()
{
    local prefix

    prefix=$(_Apache_Prefix)
    [ -x "${prefix}/bin/httpd" ] && grep -q "^${_Apache_Template_Mark}" "${prefix}/conf/httpd.conf" 2>/dev/null \
        && [ -s "${prefix}/conf/extra/httpd-vhosts.conf" ] \
        && [ -s "$(_Apache_Initd_Dir)/httpd" ] && [ -s "$(_Apache_Unit_Dir)/httpd.service" ] || return 1
    "${prefix}/bin/httpd" -t >/dev/null 2>&1 || return 2
}

Apache_Verify()
{
    Apache_Check "$1" "$2" || return 1
    if ! Apache_Health; then
        Echo_Red "Apache 配置检查未通过，执行 $(_Apache_Prefix)/bin/httpd -t 查看详情。"
        return 1
    fi
    return 0
}

# _Apache_Fetch <版本> <栈>：在子 shell 中调用。同一文件列出多个地址时依次尝试，任一成功即止。
_Apache_Fetch()
{
    local file url got=''

    cd "${cur_dir}/src" || return 1
    while IFS=$'\t' read -r _ _ _ file url _; do
        case " ${got} " in *" ${file} "*) continue ;; esac
        Download_Files "${url}" "${file}" && [ -s "${file}" ] && got="${got} ${file}"
    done < <(Apache_Sources "$1" "$2")
    while IFS=$'\t' read -r _ _ _ file _; do
        case " ${got} " in *" ${file} "*) ;; *) Echo_Red "${file} 下载或校验失败。"; return 1 ;; esac
    done < <(Apache_Sources "$1" "$2")
}

# _Apache_Unpack <构建目录> <归档> <成员>
_Apache_Unpack()
{
    if ! Unpack_Checked "${cur_dir}/src/$2" "$1" "$3"; then
        Echo_Red "$2 解压失败或归档成员不合规。"
        return 1
    fi
}

# _Apache_Lib_Build <构建目录> <归档> <成员> <configure 参数...>：编译安装依赖库，在子 shell 中调用。
_Apache_Lib_Build()
{
    local bdir=$1 tarball=$2 member=$3

    shift 3
    _Apache_Unpack "${bdir}" "${tarball}" "${member}" || return 1
    Echo_Blue "[+] 正在安装 ${member}"
    cd "${bdir}/${member}" || return 1
    if [ -x ./config ] && [ ! -x ./configure ]; then
        ./config "$@" && make depend || return 1
    else
        ./configure "$@" || return 1
    fi
    Make_Install
}

# _Apache_Deps <构建目录>：LAMP 的 nghttp2 与 OpenSSL 3，已安装时跳过。
_Apache_Deps()
{
    local bdir=$1

    if _Apache_Need_Openssl lamp \
       && ! /usr/local/openssl3/bin/openssl version 2>/dev/null | grep -q 'OpenSSL 3'; then
        ( _Apache_Lib_Build "${bdir}" "${Openssl_New_Ver}.tar.gz" "${Openssl_New_Ver}" \
            -fPIC --prefix=/usr/local/openssl3 --openssldir=/usr/local/openssl3 ) || return 1
        ldconfig
    fi
    if [[ ! -s /usr/local/nghttp2/lib/libnghttp2.so || ! -s /usr/local/nghttp2/include/nghttp2/nghttp2.h ]]; then
        ( _Apache_Lib_Build "${bdir}" "${Nghttp2_Ver}.tar.xz" "${Nghttp2_Ver}" --prefix=/usr/local/nghttp2 ) || return 1
    fi
    return 0
}

# _Apache_Build <版本> <栈> <构建目录>：在子 shell 中调用。APR 与 APR-util 放入 srclib 随 httpd 编译。
_Apache_Build()
{
    local ver=$1 stack=$2 bdir=$3 src
    local -a args=()

    src="${bdir}/httpd-${ver}"
    _Apache_Unpack "${bdir}" "httpd-${ver}.tar.bz2" "httpd-${ver}" || return 1
    _Apache_Unpack "${src}/srclib" "${APR_Ver}.tar.bz2" "${APR_Ver}" || return 1
    _Apache_Unpack "${src}/srclib" "${APR_Util_Ver}.tar.bz2" "${APR_Util_Ver}" || return 1
    mv "${src}/srclib/${APR_Ver}" "${src}/srclib/apr" || return 1
    mv "${src}/srclib/${APR_Util_Ver}" "${src}/srclib/apr-util" || return 1

    Echo_Blue "[+] 正在编译 httpd-${ver}..."
    cd "${src}" || return 1
    mapfile -t args < <(_Apache_Configure_Args "${stack}")
    if ! ./configure "${args[@]}"; then
        Echo_Red "httpd-${ver} 的 configure 失败。"
        return 1
    fi
    Make_Install
}

# 按 Tune_Plan 改写 httpd-mpm.conf 的 event 段。PHP 在 FPM 中执行，Apache 线程只负责连接，
# 线程数取不小于 FPM 子进程上限两倍的 25 的倍数，范围 50～400（不超过默认 ServerLimit 16）。
_Apache_Event_Opt()
{
    local conf="${1:-$(_Apache_Prefix)/conf/extra/httpd-mpm.conf}" tmp workers

    Tune_Plan || return 0
    if [ ! -s "${conf}" ]; then
        Echo_Yellow "未找到 ${conf}，event 线程数保持 Apache 默认值。"
        return 0
    fi
    workers=$(( (Tune_FPM_Children * 2 + 24) / 25 * 25 ))
    [ "${workers}" -lt 50 ] && workers=50
    [ "${workers}" -gt 400 ] && workers=400
    tmp=$(mktemp "${conf}.XXXXXX") || return 1
    if ! awk -v workers="${workers}" '
        /^<IfModule mpm_event_module>/ { insec = 1 }
        insec && /^<\/IfModule>/ { insec = 0 }
        insec && $1 == "StartServers" { $0 = "    StartServers             2" }
        insec && $1 == "ThreadsPerChild" { $0 = "    ThreadsPerChild          25" }
        insec && $1 == "MaxRequestWorkers" { $0 = "    MaxRequestWorkers        " workers }
        insec && $1 == "MaxConnectionsPerChild" { $0 = "    MaxConnectionsPerChild   0" }
        { print }
    ' "${conf}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    chmod --reference="${conf}" "${tmp}" 2>/dev/null
    mv -f "${tmp}" "${conf}" || return 1
    grep -Eq "^[[:space:]]+MaxRequestWorkers[[:space:]]+${workers}\$" "${conf}"
}

# _Apache_Write_Conf <栈>：写入随包配置模板。上游默认 httpd.conf 保留为 httpd.conf.bak。
_Apache_Write_Conf()
{
    local stack=$1 conf

    conf="$(_Apache_Prefix)/conf"
    [ -e "${conf}/httpd.conf.bak" ] || mv "${conf}/httpd.conf" "${conf}/httpd.conf.bak" || return 1
    if [ "${stack}" = lamp ]; then
        \cp "${cur_dir}/conf/httpd24-lamp.conf" "${conf}/httpd.conf" \
            && \cp "${cur_dir}/conf/httpd-vhosts-lamp.conf" "${conf}/extra/httpd-vhosts.conf" \
            && \cp "${cur_dir}/conf/httpd24-ssl.conf" "${conf}/extra/httpd-ssl.conf" \
            && \cp "${cur_dir}/conf/example/enable-apache-ssl-vhost-example.conf" \
                "${conf}/enable-apache-ssl-vhost-example.conf" || return 1
    else
        \cp "${cur_dir}/conf/httpd24-lnmpa.conf" "${conf}/httpd.conf" \
            && \cp "${cur_dir}/conf/httpd-vhosts-lnmpa.conf" "${conf}/extra/httpd-vhosts.conf" || return 1
    fi
    \cp "${cur_dir}/conf/httpd-default.conf" "${conf}/extra/httpd-default.conf" || return 1
    \cp "${cur_dir}/conf/mod_remoteip.conf" "${conf}/extra/mod_remoteip.conf" || return 1
    \cp "${cur_dir}/conf/httpd-php-fpm.conf" "${conf}/extra/lnmp-php.conf" || return 1
    [ "${Default_Website_Dir}" = /home/wwwroot/default ] \
        || sed -i "s#/home/wwwroot/default#${Default_Website_Dir}#g" "${conf}/extra/lnmp-php.conf" || return 1
    _Apache_Event_Opt || Echo_Yellow "event 线程数未能按内存调整，保持 Apache 默认值。"

    sed -i "s/ServerAdmin you@example.com/ServerAdmin ${ServerAdmin}/g" "${conf}/httpd.conf"
    sed -i "s/webmaster@example.com/${ServerAdmin}/g" "${conf}/extra/httpd-vhosts.conf"
    # shared/ 保存站点公共配置片段，供站点的 80 与 443 两个 VirtualHost 共同 Include。
    mkdir -p "${conf}/vhost/shared" || return 1
    sed -i 's/NameVirtualHost .*//g' "${conf}/extra/httpd-vhosts.conf"
    if [ "${Default_Website_Dir}" != "/home/wwwroot/default" ]; then
        sed -i "s#/home/wwwroot/default#${Default_Website_Dir}#g" "${conf}/httpd.conf" "${conf}/extra/httpd-vhosts.conf"
    fi
    return 0
}

# _Apache_Conf_Files <栈>：随包配置清单，每行“源文件 目标文件”，目标相对于 conf/。
_Apache_Conf_Files()
{
    if [ "$1" = lamp ]; then
        printf '%s %s\n' httpd-vhosts-lamp.conf extra/httpd-vhosts.conf httpd24-ssl.conf extra/httpd-ssl.conf \
            example/enable-apache-ssl-vhost-example.conf enable-apache-ssl-vhost-example.conf
    else
        printf '%s %s\n' httpd-vhosts-lnmpa.conf extra/httpd-vhosts.conf
    fi
    printf '%s %s\n' httpd-default.conf extra/httpd-default.conf mod_remoteip.conf extra/mod_remoteip.conf
    # 主配置包含该文件时才补写；存量 mod_php 主配置没有这一行，不生成无人引用的文件。
    grep -q 'Include conf/extra/lnmp-php.conf' "$(_Apache_Prefix)/conf/httpd.conf" 2>/dev/null \
        && printf '%s %s\n' httpd-php-fpm.conf extra/lnmp-php.conf
    return 0
}

# _Apache_Fill_Conf <栈>：主配置已是模板时只补写缺失的随包配置，已有文件不改动。
_Apache_Fill_Conf()
{
    local conf src dst tmp

    conf="$(_Apache_Prefix)/conf"
    mkdir -p "${conf}/extra" "${conf}/vhost/shared" || return 1
    while IFS=" " read -r src dst; do
        [ -s "${conf}/${dst}" ] && continue
        tmp=$(mktemp "${conf}/.lnmp-fill.XXXXXX") || return 1
        if ! \cp "${cur_dir}/conf/${src}" "${tmp}"; then
            rm -f "${tmp}"
            return 1
        fi
        if [ "${dst}" = extra/httpd-vhosts.conf ]; then
            sed -i -e "s/webmaster@example.com/${ServerAdmin}/g" -e 's/NameVirtualHost .*//g' "${tmp}"
        fi
        case "${dst}" in
        extra/httpd-vhosts.conf|extra/lnmp-php.conf)
            [ "${Default_Website_Dir}" = /home/wwwroot/default ] || sed -i "s#/home/wwwroot/default#${Default_Website_Dir}#g" "${tmp}"
            ;;
        esac
        if ! chmod 644 "${tmp}" || ! mv -f "${tmp}" "${conf}/${dst}"; then
            rm -f "${tmp}"
            return 1
        fi
        Echo_Yellow "已补写缺失的 ${conf}/${dst}"
    done < <(_Apache_Conf_Files "$1")
}

# _Apache_Service_Files：init 脚本与 unit 最后写入，Check 以它们判定安装完成。
_Apache_Service_Files()
{
    local initd tmp

    initd=$(_Apache_Initd_Dir)
    tmp=$(mktemp "${initd}/.httpd.XXXXXX") || return 1
    if ! \cp "${cur_dir}/init.d/init.d.httpd" "${tmp}" || ! chmod 755 "${tmp}" \
       || ! mv -f "${tmp}" "${initd}/httpd"; then
        rm -f "${tmp}"
        Echo_Red "写入 ${initd}/httpd 失败。"
        return 1
    fi
    Svc_Install_Unit "${cur_dir}/init.d/httpd.service" "$(_Apache_Unit_Dir)/httpd.service"
}

# _Apache_Cleanup <目录>：只清理本模块在 src/ 下创建的私有目录。
_Apache_Cleanup()
{
    case "$1" in
    "${cur_dir}"/src/.apache-build.*) rm -rf -- "$1" ;;
    esac
}

Apache_Install()
{
    local ver=$1 stack=$2 rc prefix bdir logs existed=n init_existed=n

    Apache_Check "${ver}" "${stack}"
    rc=$?
    case "${rc}" in
    0) Echo_Green "Apache ${ver} 已就绪，无需安装。"; return 0 ;;
    2) Echo_Red "已安装的 Apache 版本或编译参数与期望的 ${ver}（${stack}）不符，未改动。"; return 2 ;;
    3) Echo_Red "Apache 安装参数错误：${ver} ${stack}"; return 3 ;;
    esac

    Echo_Blue "[+] 正在安装 httpd-${ver}..."
    prefix=$(_Apache_Prefix)
    [ -e "${prefix}" ] && existed=y
    [ -e "$(_Apache_Initd_Dir)/httpd" ] && init_existed=y
    if [ "${stack}" = lamp ]; then
        getent group www >/dev/null 2>&1 || groupadd www
        id -u www >/dev/null 2>&1 || useradd -s /sbin/nologin -g www www
        # 站点目录由 www 管理，日志目录仅允许 root 写入。
        logs="${LNMP_WWWLOGS_DIR:-/home/wwwlogs}"
        mkdir -p "${Default_Website_Dir}" "${logs}" || return 1
        chown root:root "${logs}" && chmod 755 "${logs}"
        chown -R www:www "${Default_Website_Dir}" && chmod 755 "${Default_Website_Dir}"
    fi
    # 程序与编译参数已符合时只补写配置与服务文件。
    if _Apache_Binary_State "${ver}" "${stack}"; then
        bdir=''
    else
        ( _Apache_Fetch "${ver}" "${stack}" ) || { Echo_Red "Apache 源码或依赖下载、校验失败。"; return 1; }
        bdir=$(mktemp -d "${cur_dir}/src/.apache-build.XXXXXXXX") || return 1
    fi
    if { [ -z "${bdir}" ] || [ "${stack}" != lamp ] || _Apache_Deps "${bdir}"; } \
       && { [ -z "${bdir}" ] || ( _Apache_Build "${ver}" "${stack}" "${bdir}" ); } \
       && { if grep -q "^${_Apache_Template_Mark}" "${prefix}/conf/httpd.conf" 2>/dev/null; then
                _Apache_Fill_Conf "${stack}"; else _Apache_Write_Conf "${stack}"; fi; } \
       && _Apache_Service_Files && Apache_Check "${ver}" "${stack}"; then
        _Apache_Cleanup "${bdir}"
        return 0
    fi
    _Apache_Cleanup "${bdir}"
    [ "${existed}" = n ] && rm -rf -- "${prefix}"
    [ "${init_existed}" = n ] && rm -f "$(_Apache_Initd_Dir)/httpd"
    Echo_Red "Apache ${ver} 安装失败。"
    return 1
}
