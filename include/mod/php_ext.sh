#!/usr/bin/env bash
#
# PHP 扩展模块：PECL 包与 PHP 源码 ext/ 子目录两类扩展的下载、编译、安装、核验与移除。
# 实例参数为 <PHP 前缀> <扩展名>，前缀如 /usr/local/php 或 /usr/local/php8.4。
#
#   PHPExt_Sources   <前缀> <扩展名>             输出下载清单，不下载、不写文件
#   PHPExt_Check     <前缀> <扩展名>             0 就绪；1 缺失或不完整；2 版本与期望不符；3 参数或环境错误
#   PHPExt_Install   <前缀> <扩展名> [结果变量]  Check 为 0 时不写任何文件
#   PHPExt_Reinstall <前缀> <扩展名> [结果变量]  不论现状重新编译，失败时恢复原产物
#   PHPExt_Verify    <前缀> <扩展名>             Check 通过后再确认加载无告警
#   PHPExt_Remove    <前缀> <扩展名>             删除本包写入的 ini 与产物
#
# 约定：不交互、不 exit、不改变调用方工作目录；编译在私有目录的子 shell 中进行，
# 失败原因经结果变量名传回；产物生成并通过加载验证之后才写入 ini。
# 输入为参数与只读配置（include/version.sh 的版本常量、cur_dir、PM）；PHP 源码包地址取自 include/mod/php.sh 的 PHP_Sources。

# _PHPExt_Spec <扩展名>：输出 类型、包名、产物、ini、模块名，TAB 分隔。
# 类型 pecl 取自 pecl.php.net；phpsrc 取自 PHP 源码包的 ext/<扩展名>。
_PHPExt_Spec()
{
    case "$1" in
    igbinary) printf 'pecl\t%s\tigbinary.so\t020-igbinary.ini\tigbinary\n' "${PHPIgbinary_Ver:--}" ;;
    redis)    printf 'pecl\t%s\tredis.so\t021-redis.ini\tredis\n' "${PHPRedis_Ver:--}" ;;
    imagick)  printf 'pecl\t%s\timagick.so\t008-imagick.ini\timagick\n' "${Imagick_Ver:--}" ;;
    apcu)     printf 'pecl\t%s\tapcu.so\t009-apcu.ini\tapcu\n' "${PHPNewApcu_Ver:--}" ;;
    swoole)   printf 'pecl\t%s\tswoole.so\t009-swoole.ini\tswoole\n' "${PHPSwoole_Ver:--}" ;;
    memcache) printf 'pecl\t%s\tmemcache.so\t005-memcached.ini\tmemcache\n' "${PHP8Memcache_Ver:--}" ;;
    memcached) printf 'pecl\t%s\tmemcached.so\t005-memcached.ini\tmemcached\n' "${PHP8Memcached_Ver:--}" ;;
    zstd)     printf 'pecl\t%s\tzstd.so\t009-zstd.ini\tzstd\n' "${PHPZstd_Ver:--}" ;;
    # imap 已不提供安装，保留元数据供卸载既有安装。
    bz2|exif|fileinfo|imap|ldap|sodium)
        printf 'phpsrc\t-\t%s.so\t009-%s.ini\t%s\n' "$1" "$1" "$1" ;;
    *) return 1 ;;
    esac
}

# _PHPExt_Ini_Body <扩展名> <产物>
_PHPExt_Ini_Body()
{
    case "$1" in
    apcu)
        printf '[apcu]\nextension=%s\napc.enabled=1\napc.shm_size=32M\napc.enable_cli=1\n' "$2"
        ;;
    *)
        printf 'extension = "%s"\n' "$2"
        ;;
    esac
}

# _PHPExt_Configure_Args <前缀> <扩展名>：每行一个 configure 参数。
_PHPExt_Configure_Args()
{
    local prefix=$1 extdir

    case "$2" in
    redis)
        extdir=$("${prefix}/bin/php-config" --extension-dir 2>/dev/null)
        [ -s "${extdir}/igbinary.so" ] && printf '%s\n' --enable-redis-igbinary
        printf '%s\n' --enable-redis-zstd
        ;;
    imagick)
        printf '%s\n' --with-imagick=/usr/local/imagemagick
        ;;
    memcached)
        printf '%s\n' --enable-memcached --with-libmemcached-dir=/usr/local/libmemcached
        ;;
    swoole)
        printf '%s\n' --enable-openssl --enable-http2 --enable-swoole-json
        ;;
    ldap)
        printf '%s\n' --with-ldap --with-ldap-sasl
        ;;
    zstd)
        # 不探测 APCu，产物不随 apcu 是否已装而变化。
        printf '%s\n' --enable-zstd --disable-apcu
        ;;
    esac
    return 0
}

# _PHPExt_Cleanup <构建目录>：只清理本模块在 src/ 下创建的私有目录。
_PHPExt_Cleanup()
{
    case "$1" in
    "${cur_dir}"/src/.phpext.*|"${cur_dir}"/src/.libmemcached.*) rm -rf -- "$1" ;;
    esac
}

# _PHPExt_Reason <原因文件> <文本>：记录失败原因并返回 1。
_PHPExt_Reason()
{
    [ -n "$1" ] && printf '%s\n' "$2" > "$1"
    return 1
}

# _PHPExt_Patch <源码目录> <补丁文件>
# 补丁适用则应用；已应用过视为通过；既不适用也未应用则失败。
_PHPExt_Patch()
{
    local dir=$1 patch_file=$2

    [ -s "${patch_file}" ] || return 0
    # 补丁路径在 cd 之前取绝对路径。
    case "${patch_file}" in
    /*) ;;
    *) patch_file="$(pwd)/${patch_file}" ;;
    esac
    command -v patch >/dev/null 2>&1 || return 1
    if ( cd "${dir}" && patch -p1 -s --dry-run --forward < "${patch_file}" ) >/dev/null 2>&1; then
        ( cd "${dir}" && patch -p1 -s --forward --no-backup-if-mismatch < "${patch_file}" ) >/dev/null
        return $?
    fi
    ( cd "${dir}" && patch -p1 -s --dry-run --reverse < "${patch_file}" ) >/dev/null 2>&1
}

# _PHPExt_Apt <包名...>：以非交互方式经 apt 安装依赖。
_PHPExt_Apt()
{
    export DEBIAN_FRONTEND=noninteractive
    Apt_Get install -y "$@"
}

# _PHPExt_Libmemcached：编译 php-memcached 依赖的 libmemcached。
_PHPExt_Libmemcached()
{
    local bdir file url

    [ -s /usr/local/libmemcached/lib/libmemcached.so ] && return 0
    IFS=$'\t' read -r _ _ _ file url _ < <(Libmemcached_Sources) || return 1
    bdir=$(mktemp -d "${cur_dir}/src/.libmemcached.XXXXXXXX") || return 1
    (
        # 路径在此刻展开：trap 触发时局部变量已不在作用域内。
        # shellcheck disable=SC2064
        trap "_PHPExt_Cleanup '${bdir}'" EXIT
        cd "${cur_dir}/src" || exit 1
        Download_Files "${url}" "${file}" || exit 1
        [ -s "${file}" ] || exit 1
        Unpack_Checked "${cur_dir}/src/${file}" "${bdir}" "${Libmemcached_Ver}" || exit 1
        cd "${bdir}/${Libmemcached_Ver}" || exit 1
        # GCC 7 及以上需要兼容补丁。
        if gcc -dumpversion | grep -Eq '^([7-9]|[1-9][0-9])'; then
            _PHPExt_Patch . "${cur_dir}/src/patch/libmemcached-1.0.18-gcc7.patch" || exit 1
        fi
        ./configure --prefix=/usr/local/libmemcached --with-memcached || exit 1
        Make_Install || exit 1
    )
}

# _PHPExt_Deps <前缀> <扩展名>：安装系统包与库依赖，失败返回非零。
_PHPExt_Deps()
{
    local prefix=$1 ext=$2 branch

    [ -n "${PM:-}" ] || Get_Dist_Name
    case "${ext}" in
    imagick)
        ImageMagick_Check || ImageMagick_Install || return 1
        ;;
    redis)
        # --enable-redis-zstd 只查找系统 libzstd。
        if [ "${PM}" = "yum" ]; then
            yum install -y libzstd-devel || return 1
        elif [ "${PM}" = "apt" ]; then
            _PHPExt_Apt libzstd-dev || return 1
        fi
        ;;
    memcached)
        if [ "${PM}" = "yum" ]; then
            yum install -y cyrus-sasl-devel || return 1
        elif [ "${PM}" = "apt" ]; then
            _PHPExt_Apt libsasl2-2 sasl2-bin libsasl2-dev libsasl2-modules || return 1
        fi
        _PHPExt_Libmemcached || return 1
        ;;
    imap)
        Echo_Red "imap 扩展已不提供安装：UW c-client 已停止维护，PHP 8.4 起源码不含 ext/imap。"
        return 1
        ;;
    ldap)
        if [ "${PM}" = "yum" ]; then
            yum -y install openldap-devel cyrus-sasl-devel || return 1
            if [ "${Is_64bit:-}" = "y" ]; then
                ln -sf /usr/lib64/libldap* /usr/lib/
                ln -sf /usr/lib64/liblber* /usr/lib/
            fi
        elif [ "${PM}" = "apt" ]; then
            _PHPExt_Apt libldap2-dev libsasl2-dev || return 1
            if [ -s /usr/lib/x86_64-linux-gnu/libldap.so ]; then
                ln -sf /usr/lib/x86_64-linux-gnu/libldap.so /usr/lib/
                ln -sf /usr/lib/x86_64-linux-gnu/liblber.so /usr/lib/
            fi
        fi
        ;;
    sodium)
        if [ "${PM}" = "yum" ]; then
            if [ "${DISTRO}" = "Oracle" ]; then
                yum -y install oracle-epel-release || return 1
            else
                yum -y install epel-release || return 1
            fi
            yum -y install libsodium-devel || return 1
        elif [ "${PM}" = "apt" ]; then
            _PHPExt_Apt libsodium-dev || return 1
        fi
        ;;
    esac
    return 0
}

# PHPExt_List：输出本模块支持的扩展名，每行一个。
PHPExt_List()
{
    printf '%s\n' igbinary redis imagick apcu swoole memcache memcached zstd bz2 exif fileinfo imap ldap sodium
}

# PHPExt_Files <扩展名>：输出 产物、ini、模块名，TAB 分隔，供调用方重启后验收与撤回。
PHPExt_Files()
{
    local kind pkg so ini module

    IFS=$'\t' read -r kind pkg so ini module < <(_PHPExt_Spec "$1") || return 1
    printf '%s\t%s\t%s\n' "${so}" "${ini}" "${module}"
}

# Libmemcached_Sources：php-memcached 依赖的 libmemcached 下载清单。
Libmemcached_Sources()
{
    printf 'libmemcached\t-\t%s\t%s.tar.gz\thttps://launchpad.net/libmemcached/1.0/%s/+download/%s.tar.gz\tsha256\tsrc/checksums.sha256\n' \
        "${Libmemcached_Ver}" "${Libmemcached_Ver}" "${Libmemcached_Ver#libmemcached-}" "${Libmemcached_Ver}"
}

PHPExt_Sources()
{
    local prefix=$1 ext=$2 kind pkg so ini module ver file url

    IFS=$'\t' read -r kind pkg so ini module < <(_PHPExt_Spec "${ext}") || return 1
    case "${kind}" in
    pecl)
        printf 'php-ext\t%s:%s\t%s\t%s.tgz\thttps://pecl.php.net/get/%s.tgz\tsha256\tsrc/checksums.sha256\n' \
            "${prefix}" "${ext}" "${pkg}" "${pkg}" "${pkg}"
        case "${ext}" in
        imagick) ImageMagick_Sources ;;
        memcached) Libmemcached_Sources ;;
        esac
        ;;
    phpsrc)
        ver=$("${prefix}/bin/php-config" --version 2>/dev/null)
        [ -n "${ver}" ] || return 1
        # 源码包地址取自 PHP 模块；扩展安装经 Download_Files 按静态清单校验。
        IFS=$'\t' read -r _ _ _ file url _ < <(PHP_Sources "${prefix}" fpm "${ver}") || return 1
        printf 'php-ext\t%s:%s\t%s\t%s\t%s\tsha256\tsrc/checksums.sha256\n' \
            "${prefix}" "${ext}" "${ver}" "${file}" "${url}"
        ;;
    *) return 1 ;;
    esac
    return 0
}

# _PHPExt_Builtin <前缀> <扩展名>：模块已编入 PHP 时返回 0。
_PHPExt_Builtin()
{
    local kind pkg so ini module

    IFS=$'\t' read -r kind pkg so ini module < <(_PHPExt_Spec "$2") || return 1
    "$1/bin/php" -n -m 2>/dev/null | grep -qix "${module}"
}

PHPExt_Check()
{
    local prefix=$1 ext=$2 kind pkg so ini module extdir want have

    IFS=$'\t' read -r kind pkg so ini module < <(_PHPExt_Spec "${ext}") || return 3
    [ -x "${prefix}/bin/php" ] && [ -x "${prefix}/bin/php-config" ] || return 3

    # 编入 PHP 的模块不依赖产物与 ini。
    _PHPExt_Builtin "${prefix}" "${ext}" && return 0
    extdir=$("${prefix}/bin/php-config" --extension-dir 2>/dev/null)
    [ -n "${extdir}" ] || return 3
    [ -s "${extdir}/${so}" ] && [ -s "${prefix}/conf.d/${ini}" ] || return 1
    "${prefix}/bin/php" --ri "${module}" >/dev/null 2>&1 || return 1

    if [ "${kind}" = pecl ]; then
        want=${pkg#*-}
        have=$("${prefix}/bin/php" -r 'echo phpversion($argv[1]);' "${module}" 2>/dev/null)
        [ -n "${have}" ] && [ "${have}" != "${want}" ] && return 2
    fi
    return 0
}

PHPExt_Verify()
{
    local prefix=$1 ext=$2 kind pkg so ini module out

    PHPExt_Check "${prefix}" "${ext}" || return 1
    IFS=$'\t' read -r kind pkg so ini module < <(_PHPExt_Spec "${ext}") || return 1
    out=$("${prefix}/bin/php" -m 2>&1)
    printf '%s\n' "${out}" | grep -qiE '^(PHP )?(Warning|Fatal)' && return 1
    printf '%s\n' "${out}" | grep -qix "${module}"
}

# _PHPExt_Build <前缀> <扩展名> <原因文件>：在子 shell 中调用。
_PHPExt_Build()
{
    local prefix=$1 ext=$2 reason=$3
    local kind pkg so ini module extdir bdir url file member srcdir patch_file out
    local -a cfg=()

    IFS=$'\t' read -r kind pkg so ini module < <(_PHPExt_Spec "${ext}") \
        || { _PHPExt_Reason "${reason}" "未知扩展"; return 1; }
    if [ ! -x "${prefix}/bin/phpize" ] || [ ! -x "${prefix}/bin/php-config" ]; then
        _PHPExt_Reason "${reason}" "缺少 phpize 或 php-config"
        return 1
    fi
    extdir=$("${prefix}/bin/php-config" --extension-dir 2>/dev/null)
    [ -n "${extdir}" ] || { _PHPExt_Reason "${reason}" "无法取得扩展目录"; return 1; }

    bdir=$(mktemp -d "${cur_dir}/src/.phpext.XXXXXXXX") \
        || { _PHPExt_Reason "${reason}" "无法创建构建目录"; return 1; }
    # 路径在此刻展开：trap 触发时局部变量已不在作用域内。
    # shellcheck disable=SC2064
    trap "_PHPExt_Cleanup '${bdir}'" EXIT

    _PHPExt_Deps "${prefix}" "${ext}" || { _PHPExt_Reason "${reason}" "依赖安装失败"; return 1; }

    IFS=$'\t' read -r _ _ _ file url _ < <(PHPExt_Sources "${prefix}" "${ext}" | head -n 1) \
        || { _PHPExt_Reason "${reason}" "无法确定下载地址"; return 1; }
    ( cd "${cur_dir}/src" && Download_Files "${url}" "${file}" ) \
        || { _PHPExt_Reason "${reason}" "下载或校验失败"; return 1; }
    [ -s "${cur_dir}/src/${file}" ] || { _PHPExt_Reason "${reason}" "下载或校验失败"; return 1; }

    if [ "${kind}" = pecl ]; then
        member=${pkg}
        srcdir="${bdir}/${pkg}"
    else
        member="php-$("${prefix}/bin/php-config" --version)/ext/${ext}"
        srcdir="${bdir}/${member}"
    fi
    Unpack_Checked "${cur_dir}/src/${file}" "${bdir}" "${member}" \
        || { _PHPExt_Reason "${reason}" "解包失败或归档成员不合规"; return 1; }

    # 补丁按 <包名>-php85.patch 命名，用于上游尚未发布的 PHP 8.5 兼容修正。
    patch_file="${cur_dir}/src/patch/${pkg}-php85.patch"
    _PHPExt_Patch "${srcdir}" "${patch_file}" \
        || { _PHPExt_Reason "${reason}" "补丁失败"; return 1; }

    mapfile -t cfg < <(_PHPExt_Configure_Args "${prefix}" "${ext}")

    # 旧产物与 ini 先移走：构建失败时不会被当作本次产物，也不会让 PHP 加载到残缺文件。
    mkdir -p "${bdir}/bak" || { _PHPExt_Reason "${reason}" "无法创建备份目录"; return 1; }
    [ -e "${extdir}/${so}" ] && { mv -f "${extdir}/${so}" "${bdir}/bak/${so}" \
        || { _PHPExt_Reason "${reason}" "无法移走旧产物"; return 1; }; }
    [ -e "${prefix}/conf.d/${ini}" ] && { mv -f "${prefix}/conf.d/${ini}" "${bdir}/bak/${ini}" \
        || { _PHPExt_Reason "${reason}" "无法移走旧 ini"; return 1; }; }

    if ! (
        cd "${srcdir}" || exit 1
        "${prefix}/bin/phpize" >/dev/null || exit 11
        ./configure --with-php-config="${prefix}/bin/php-config" "${cfg[@]}" || exit 12
        Make_Install || exit 13
    ); then
        out="编译失败"
        _PHPExt_Restore "${bdir}/bak" "${extdir}" "${so}" "${prefix}/conf.d" "${ini}"
        _PHPExt_Reason "${reason}" "${out}"
        return 1
    fi

    if [ ! -s "${extdir}/${so}" ]; then
        _PHPExt_Restore "${bdir}/bak" "${extdir}" "${so}" "${prefix}/conf.d" "${ini}"
        _PHPExt_Reason "${reason}" "编译后未生成 ${so}"
        return 1
    fi

    # ini 最后写入；先写同目录临时文件，再 rename。
    mkdir -p "${prefix}/conf.d" || { _PHPExt_Restore "${bdir}/bak" "${extdir}" "${so}" "${prefix}/conf.d" "${ini}"; _PHPExt_Reason "${reason}" "无法创建 conf.d"; return 1; }
    if ! _PHPExt_Ini_Body "${ext}" "${so}" > "${prefix}/conf.d/.${ini}.new" \
       || ! mv -f "${prefix}/conf.d/.${ini}.new" "${prefix}/conf.d/${ini}"; then
        rm -f "${prefix}/conf.d/.${ini}.new"
        _PHPExt_Restore "${bdir}/bak" "${extdir}" "${so}" "${prefix}/conf.d" "${ini}"
        _PHPExt_Reason "${reason}" "写入 ${ini} 失败"
        return 1
    fi

    out=$("${prefix}/bin/php" --ri "${module}" 2>&1) \
        && ! "${prefix}/bin/php" -m 2>&1 | grep -qiE '^(PHP )?(Warning|Fatal)'
    if [ $? -ne 0 ]; then
        _PHPExt_Restore "${bdir}/bak" "${extdir}" "${so}" "${prefix}/conf.d" "${ini}"
        _PHPExt_Reason "${reason}" "安装后 PHP 无法加载 ${module}"
        return 1
    fi
    return 0
}

# _PHPExt_Restore <备份目录> <扩展目录> <产物> <conf.d> <ini>：放回构建前的产物与 ini。
_PHPExt_Restore()
{
    rm -f "$2/$3" "$4/$5"
    [ -e "$1/$3" ] && mv -f "$1/$3" "$2/$3"
    [ -e "$1/$5" ] && mv -f "$1/$5" "$4/$5"
    return 0
}

# _PHPExt_Run <前缀> <扩展名> <结果变量> <force|keep>
_PHPExt_Run()
{
    local _pe_prefix=$1 _pe_ext=$2 _pe_var=$3 _pe_mode=$4 _pe_rc _pe_file _pe_msg=''

    PHPExt_Check "${_pe_prefix}" "${_pe_ext}"
    _pe_rc=$?
    # 已编入 PHP 的模块没有共享产物可重装。
    if [ "${_pe_rc}" -eq 0 ] && _PHPExt_Builtin "${_pe_prefix}" "${_pe_ext}"; then
        Echo_Green "PHP 扩展 ${_pe_ext} 已编入 PHP，无需安装。"
        return 0
    fi
    case "${_pe_rc}" in
    3)
        [ -n "${_pe_var}" ] && printf -v "${_pe_var}" '%s' "参数或环境错误"
        Echo_Red "PHP 扩展 ${_pe_ext}：${_pe_prefix} 不是可用的 PHP 安装或扩展名未知。"
        return 1
        ;;
    0)
        if [ "${_pe_mode}" = keep ]; then
            Echo_Green "PHP 扩展 ${_pe_ext} 已就绪，无需安装。"
            return 0
        fi
        ;;
    2)
        if [ "${_pe_mode}" = keep ]; then
            [ -n "${_pe_var}" ] && printf -v "${_pe_var}" '%s' "已安装版本与期望不符"
            Echo_Red "PHP 扩展 ${_pe_ext} 的已安装版本与期望不符，未改动。需要更换版本时请显式重装。"
            return 2
        fi
        ;;
    esac

    Echo_Blue "[+] 正在安装 PHP 扩展 ${_pe_ext}... "
    _pe_file=$(mktemp) || return 1
    ( _PHPExt_Build "${_pe_prefix}" "${_pe_ext}" "${_pe_file}" )
    _pe_rc=$?
    [ -s "${_pe_file}" ] && _pe_msg=$(cat "${_pe_file}")
    rm -f "${_pe_file}"
    if [ "${_pe_rc}" -ne 0 ]; then
        [ -n "${_pe_msg}" ] || _pe_msg="构建失败"
        [ -n "${_pe_var}" ] && printf -v "${_pe_var}" '%s' "${_pe_msg}"
        Echo_Red "PHP 扩展 ${_pe_ext} 安装失败：${_pe_msg}"
        return 1
    fi
    Echo_Green "PHP 扩展 ${_pe_ext} 安装成功"
    return 0
}

PHPExt_Install()
{
    _PHPExt_Run "$1" "$2" "${3:-}" keep
}

PHPExt_Reinstall()
{
    _PHPExt_Run "$1" "$2" "${3:-}" force
}

PHPExt_Remove()
{
    local prefix=$1 ext=$2 kind pkg so ini module extdir

    IFS=$'\t' read -r kind pkg so ini module < <(_PHPExt_Spec "${ext}") || return 1
    extdir=$("${prefix}/bin/php-config" --extension-dir 2>/dev/null)
    rm -f "${prefix}/conf.d/${ini}" || return 1
    [ -n "${extdir}" ] && { rm -f "${extdir}/${so}" || return 1; }
    return 0
}
