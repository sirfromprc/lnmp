#!/usr/bin/env bash
#
# Pure-FTPd 模块：源码构建、pure-ftpd.conf 端口写入、FTPS 证书、init 脚本与 unit 的部署和移除。
# 安装前缀 /usr/local/pureftpd、init 脚本目录与 unit 目录可由 LNMP_PUREFTPD_PREFIX、
# LNMP_INITD_DIR、LNMP_UNIT_DIR 覆盖（测试用）。
#
#   Pureftpd_Sources <版本>                                 输出下载清单，不下载、不写文件
#   Pureftpd_Check   <版本>                                 0 就绪；1 缺失或不完整；2 版本不符；3 参数错误
#   Pureftpd_Install <版本> <控制端口> <被动起> <被动止>    构建并部署；失败时删除本次新建的安装目录
#   Pureftpd_Ports   [pure-ftpd.conf]                       输出三行：控制端口、被动范围起、被动范围止
#   Pureftpd_Verify  <控制端口>                             服务在运行且监听控制端口
#   Pureftpd_Remove                                         停止服务，删除启动项、init 脚本与安装目录
#
# 约定：不交互、不 exit、不改变调用方工作目录；构建在 src/ 下的私有目录中进行。
# 防火墙放行、启动与管理命令部署由入口 pureftpd.sh 编排。

_Pureftpd_Prefix()
{
    printf '%s\n' "${LNMP_PUREFTPD_PREFIX:-/usr/local/pureftpd}"
}

_Pureftpd_Initd()
{
    printf '%s\n' "${LNMP_INITD_DIR:-/etc/init.d}/pureftpd"
}

_Pureftpd_Ver_Ok()
{
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

_Pureftpd_Port_Ok()
{
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

Pureftpd_Sources()
{
    local ver=$1 file

    _Pureftpd_Ver_Ok "${ver}" || return 1
    file="pure-ftpd-${ver}.tar.bz2"
    printf 'pureftpd\t%s\t%s\t%s\thttps://download.pureftpd.org/pub/pure-ftpd/releases/%s\tsha256\tsrc/checksums.sha256\n' \
        "$(_Pureftpd_Prefix)" "${ver}" "${file}" "${file}"
}

# 版本以 pure-ftpd -h 首行的 vX.Y.Z 为准。
_Pureftpd_Built_Ver()
{
    "$(_Pureftpd_Prefix)/sbin/pure-ftpd" -h 2>&1 | head -1 \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d v
}

Pureftpd_Check()
{
    local ver=$1 prefix

    _Pureftpd_Ver_Ok "${ver}" || return 3
    prefix=$(_Pureftpd_Prefix)
    [ -x "${prefix}/sbin/pure-ftpd" ] && [ -s "${prefix}/etc/pure-ftpd.conf" ] \
        && [ -e "${prefix}/etc/pureftpd.pdb" ] && [ -s "${prefix}/etc/pure-ftpd.pem" ] \
        && [ -x "$(_Pureftpd_Initd)" ] || return 1
    [ "$(_Pureftpd_Built_Ver)" = "${ver}" ] || return 2
    return 0
}

Pureftpd_Ports()
{
    local conf="${1:-$(_Pureftpd_Prefix)/etc/pure-ftpd.conf}" ctl='' pasv_min='' pasv_max=''

    if [ -s "${conf}" ]; then
        ctl=$(awk '/^Bind[[:space:]]/ { split($2, a, ","); print a[2]; exit }' "${conf}")
        pasv_min=$(awk '/^PassivePortRange[[:space:]]/ { print $2; exit }' "${conf}")
        pasv_max=$(awk '/^PassivePortRange[[:space:]]/ { print $3; exit }' "${conf}")
    fi
    printf '%s\n%s\n%s\n' "${ctl}" "${pasv_min}" "${pasv_max}"
}

_Pureftpd_Deps()
{
    local pkg rc=0

    if [ "$PM" = "yum" ]; then
        for pkg in make gcc gcc-c++ openssl openssl-devel bzip2; do
            yum -y install "${pkg}" || rc=1
        done
    elif [ "$PM" = "apt" ]; then
        Apt_Get update -y || Apt_Get update --allow-releaseinfo-change -y
        for pkg in build-essential gcc g++ make openssl libssl-dev bzip2; do
            Apt_Get --no-install-recommends install -y "${pkg}" || rc=1
        done
    fi
    [ "${rc}" -eq 0 ] || Echo_Yellow "部分依赖包安装失败，继续尝试编译。"
    return 0
}

_Pureftpd_Configure_Args()
{
    printf '%s\n' "--prefix=$(_Pureftpd_Prefix)" CFLAGS=-O2 \
        --with-puredb --with-quotas --with-cookie --with-virtualhosts --with-diraliases \
        --with-sysquotas --with-ratios --with-altlog --with-paranoidmsg --with-shadow \
        --with-welcomemsg --with-throttling --with-uploadscript --with-language=english \
        --with-rfc2640 --with-ftpwho --with-tls
}

# _Pureftpd_Build <版本> <构建目录>：在子 shell 中调用，下载校验、解包、configure、编译并安装。
_Pureftpd_Build()
{
    local ver=$1 bdir=$2 file url
    local -a args=()

    cd "${cur_dir}/src" || return 1
    IFS=$'\t' read -r _ _ _ file url _ _ < <(Pureftpd_Sources "${ver}") || return 1
    Download_Files "${url}" "${file}" || return 1
    Require_File "${file}" "Pure-FTPd" || return 1
    if ! Unpack_Checked "${cur_dir}/src/${file}" "${bdir}" "pure-ftpd-${ver}"; then
        Echo_Red "Pure-FTPd 解压失败或归档结构异常。"
        return 1
    fi
    cd "${bdir}/pure-ftpd-${ver}" || return 1
    mapfile -t args < <(_Pureftpd_Configure_Args)
    if ! ./configure "${args[@]}"; then
        Echo_Red "pure-ftpd-${ver} 的 configure 失败。"
        return 1
    fi
    Make_Install
}

# _Pureftpd_Write_Conf <控制端口> <被动起> <被动止>：按模板生成配置，核对端口后原子替换。
_Pureftpd_Write_Conf()
{
    local ctl=$1 pmin=$2 pmax=$3 conf tmp

    conf="$(_Pureftpd_Prefix)/etc/pure-ftpd.conf"
    mkdir -p "${conf%/*}" || return 1
    tmp=$(mktemp "${conf}.XXXXXXXX") || return 1
    if ! sed "s|^PassivePortRange .*|PassivePortRange             ${pmin} ${pmax}|" \
            "${cur_dir}/conf/pure-ftpd.conf" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    if grep -q '^Bind ' "${tmp}"; then
        sed -i "s|^Bind .*|Bind                         0.0.0.0,${ctl}|" "${tmp}"
    else
        printf '\n# 监听地址与端口，由 lnmp.conf 的 Pureftpd_Port 决定\nBind                         0.0.0.0,%s\n' \
            "${ctl}" >> "${tmp}"
    fi
    # 模板格式变化时端口可能未写入，监听端口会与防火墙规则不一致。
    if ! Check_Conf_Applied "${tmp}" "^Bind[[:space:]]+0\.0\.0\.0,${ctl}\$" "FTP 控制端口 ${ctl}" \
       || ! Check_Conf_Applied "${tmp}" \
            "^PassivePortRange[[:space:]]+${pmin}[[:space:]]+${pmax}\$" "FTP 被动端口范围 ${pmin}-${pmax}" \
       || ! chmod 644 "${tmp}" || ! mv -f "${tmp}" "${conf}"; then
        rm -f "${tmp}"
        return 1
    fi
}

# FTP 明文传输账号口令，FTPS 启动需要包含私钥和证书的 PEM 文件。
# 自签证书会触发客户端信任警告，生产环境应换成正式证书；已有 PEM 不覆盖。
_Pureftpd_Pem()
{
    local pem tmp

    pem="$(_Pureftpd_Prefix)/etc/pure-ftpd.pem"
    [ -s "${pem}" ] && return 0
    Echo_Blue "正在为 FTPS 生成自签名证书..."
    tmp=$(mktemp "${pem}.XXXXXXXX") || return 1
    if ! openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/CN=$(hostname -f 2>/dev/null || hostname)" \
            -keyout "${tmp}" -out "${tmp}" >/dev/null 2>&1 \
       || ! chmod 600 "${tmp}" || ! mv -f "${tmp}" "${pem}"; then
        rm -f "${tmp}"
        return 1
    fi
}

_Pureftpd_Service_Files()
{
    local prefix init tmp unit_dir="${LNMP_UNIT_DIR:-/etc/systemd/system}"

    prefix=$(_Pureftpd_Prefix)
    init=$(_Pureftpd_Initd)
    [ -L "${init}" ] && rm -f "${init}"
    tmp=$(mktemp "${init%/*}/.pureftpd.XXXXXXXX") || return 1
    if ! \cp "${cur_dir}/init.d/init.d.pureftpd" "${tmp}" || ! chmod 755 "${tmp}" \
       || ! mv -f "${tmp}" "${init}"; then
        rm -f "${tmp}"
        return 1
    fi
    if [ -d "${unit_dir}" ]; then
        Svc_Install_Unit "${cur_dir}/init.d/pureftpd.service" "${unit_dir}/pureftpd.service" || return 1
    fi
    touch "${prefix}/etc/pureftpd.passwd" "${prefix}/etc/pureftpd.pdb"
}

_Pureftpd_Cleanup()
{
    case "$1" in
    "${cur_dir}"/src/.pureftpd-build.*) rm -rf -- "$1" ;;
    esac
}

Pureftpd_Install()
{
    local ver=$1 ctl=$2 pmin=$3 pmax=$4 prefix bdir existed=n rc=0

    _Pureftpd_Ver_Ok "${ver}" || { Echo_Red "Pure-FTPd 版本格式不正确：${ver}"; return 1; }
    if ! _Pureftpd_Port_Ok "${ctl}" || ! _Pureftpd_Port_Ok "${pmin}" || ! _Pureftpd_Port_Ok "${pmax}" \
       || [ "${pmin}" -gt "${pmax}" ]; then
        Echo_Red "Pure-FTPd 端口参数不正确：${ctl} ${pmin}-${pmax}"
        return 1
    fi
    prefix=$(_Pureftpd_Prefix)
    [ -d "${prefix}" ] && existed=y

    Echo_Blue "安装依赖软件包..."
    _Pureftpd_Deps
    bdir=$(mktemp -d "${cur_dir}/src/.pureftpd-build.XXXXXXXX") || return 1
    Echo_Blue "正在安装 Pure-FTPd..."
    ( _Pureftpd_Build "${ver}" "${bdir}" ) || rc=1
    _Pureftpd_Cleanup "${bdir}"
    if [ "${rc}" -eq 0 ] && [ ! -x "${prefix}/sbin/pure-ftpd" ]; then
        Echo_Red "编译结束但没有产出 ${prefix}/sbin/pure-ftpd。"
        rc=1
    fi
    if [ "${rc}" -eq 0 ]; then
        Echo_Blue "正在写入配置文件..."
        { _Pureftpd_Write_Conf "${ctl}" "${pmin}" "${pmax}" && _Pureftpd_Service_Files && _Pureftpd_Pem; } || rc=1
    fi
    if [ "${rc}" -ne 0 ]; then
        Echo_Red "Pure-FTPd 安装失败。"
        if [ "${existed}" = n ]; then
            rm -rf -- "${prefix}"
            rm -f "$(_Pureftpd_Initd)"
        fi
        return 1
    fi
    return 0
}

# 监听端口核对：ss 不可用时跳过，不因缺工具判定失败。
_Pureftpd_Listening()
{
    local port=$1 i=0

    command -v ss >/dev/null 2>&1 || return 0
    while [ ${i} -lt 10 ]; do
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}\$" && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

Pureftpd_Verify()
{
    local port=$1

    if Svc_Use_Systemd pureftpd; then
        systemctl is-active --quiet pureftpd.service || return 1
    elif ! { [ -s /var/run/pure-ftpd.pid ] && kill -0 "$(cat /var/run/pure-ftpd.pid)" 2>/dev/null; }; then
        return 1
    fi
    if ! _Pureftpd_Listening "${port}"; then
        Echo_Red "Pure-FTPd 已启动，但没有监听 ${port} 端口。"
        return 1
    fi
    return 0
}

Pureftpd_Remove()
{
    local prefix init rc=0

    prefix=$(_Pureftpd_Prefix)
    init=$(_Pureftpd_Initd)
    case "${prefix}" in /|'') return 1 ;; esac
    [ -x "${init}" ] && "${init}" stop
    Remove_StartUp pureftpd
    rm -f "${init}" || rc=1
    rm -rf -- "${prefix}" || rc=1
    return ${rc}
}
