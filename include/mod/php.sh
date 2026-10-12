#!/usr/bin/env bash
#
# PHP 本体模块：主 PHP 与多版本实例的依赖、下载、编译、配置生成、服务文件、升级与回滚。
# 实例参数为 <前缀> <SAPI>：前缀 /usr/local/php 为主 PHP，/usr/local/php<分支> 为多版本实例；
# SAPI 为 fpm 或 apxs，apxs 只用于主 PHP。
#
#   PHP_Sources <前缀> <SAPI> <版本>          输出下载清单，不下载、不写文件
#   PHP_Installed <前缀>                      输出已装的版本；0 已装；1 未装；2 程序不可读
#   PHP_Fpm_Listen <前缀>                     输出 php-fpm.conf 的 listen 取值
#   PHP_Detect_Sapi <栈> [PHP 前缀] [Apache 前缀]  按已装形态输出主 PHP 的 SAPI；2 表示 fpm 与 php_module 并存
#   PHP_Remove  <前缀>                        停止服务，删除启动项、init 脚本与安装目录；0 已删除；1 有残留；3 前缀不合法
#   PHP_Check   <前缀> <SAPI> <版本>          0 就绪；1 缺失或不完整；2 版本或编译选项与期望不符；3 参数错误
#   PHP_Install <前缀> <SAPI> <版本> <调优>   Check 为 0 时不写文件；失败时删除本次写入的文件
#   PHP_Upgrade <前缀> <SAPI> <版本> <调优>   0 成功；1 失败，线上未改动或已回滚；2 回滚失败，保留现场
#   PHP_Verify  <前缀> <SAPI> <版本>          Check 通过后确认加载无告警与 FPM 配置测试
#   PHP_Health  <前缀> <SAPI>                 不比较版本与编译选项：0 文件完整、加载无告警且 FPM 配置测试通过；1 文件缺失；2 加载告警或配置测试未通过
#
# 调优参数为 pm:children:start:min:max:opcache_mb，由编排层经 Tune_PHP_Spec 计算；为空时使用模板值。
# 约定：不交互、不 exit、不改变调用方工作目录；编译在 src/ 下的私有目录与子 shell 中进行。
# 输入为参数与只读配置（lnmp.conf 的 Enable_PHP_* 与 PHP_Modules_Options、cur_dir、PM）。

# _PHP_Role <前缀> <SAPI>：输出 main 或 mphp；前缀或 SAPI 不合法时返回 1。
_PHP_Role()
{
    case "$1" in
    /*/php)
        case "$2" in fpm|apxs) echo main; return 0 ;; esac
        ;;
    /*/php[0-9].[0-9])
        [ "$2" = fpm ] && { echo mphp; return 0; }
        ;;
    esac
    return 1
}

# _PHP_Branch <版本>：输出主次版本号。
_PHP_Branch()
{
    local IFS=.
    local -a v
    read -r -a v <<< "$1"
    printf '%s.%s\n' "${v[0]}" "${v[1]}"
}

_PHP_Ver_Ok()
{
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

_PHP_Initd_Dir()
{
    printf '%s\n' "${LNMP_INITD_DIR:-/etc/init.d}"
}

# _PHP_Service_Names <前缀>：输出 init 脚本名、unit 名、unit 模板名，TAB 分隔。
_PHP_Service_Names()
{
    local br=${1##*/php}

    if [ -z "${br}" ]; then
        printf 'php-fpm\tphp-fpm\tphp-fpm.service\n'
    else
        printf 'php-fpm%s\tphp-fpm@%s\tphp-fpm@.service\n' "${br}" "${br}"
    fi
}

# _PHP_Sock <前缀>：FPM 监听的 socket 路径。
_PHP_Sock()
{
    printf '/run/php-fpm/php-cgi%s.sock\n' "${1##*/php}"
}

# PHP_Detect_Sapi <栈> [PHP 前缀] [Apache 前缀]：按已装形态输出主 PHP 的 SAPI（fpm 或 apxs）。
#   lnmp 恒为 fpm；lnmpa、lamp 看 Apache 主配置：无主配置（新装）为 fpm；加载 php_module 为 apxs；
#   包含 extra/lnmp-php.conf 为 fpm；其余为旧版随包配置（尚无 PHP），已有 php-fpm 为 fpm，否则 apxs。
#   0 判定；2 php_module 与 php-fpm 并存，输出 apxs，调用方应提示冲突。
PHP_Detect_Sapi()
{
    local stack=${1:-} prefix=${2:-/usr/local/php} apache=${3:-/usr/local/apache}
    local conf has_fpm=n

    case "${stack}" in
    lnmpa|lamp) ;;
    *) echo fpm; return 0 ;;
    esac
    conf="${apache}/conf/httpd.conf"
    [ -x "${prefix}/sbin/php-fpm" ] && has_fpm=y
    if [ ! -s "${conf}" ]; then
        echo fpm
    elif grep -Eq '^[[:space:]]*LoadModule[[:space:]]+php_module[[:space:]]' "${conf}"; then
        echo apxs
        [ "${has_fpm}" = y ] && return 2
    elif grep -Eq '^[[:space:]]*Include[[:space:]]+conf/extra/lnmp-php\.conf' "${conf}"; then
        echo fpm
    elif [ "${has_fpm}" = y ]; then
        echo fpm
    else
        echo apxs
    fi
    return 0
}

# _PHP_Configure_Args <前缀> <SAPI> <源码目录> <分支>：每行一个 configure 参数。
_PHP_Configure_Args()
{
    local prefix=$1 sapi=$2 src=$3 branch=$4
    local -a extra=()

    printf '%s\n' "--prefix=${prefix}" "--with-config-file-path=${prefix}/etc" \
        "--with-config-file-scan-dir=${prefix}/conf.d"
    if [ "${sapi}" = fpm ]; then
        printf '%s\n' --enable-fpm --with-fpm-user=www --with-fpm-group=www --enable-mysqlnd
    else
        printf '%s\n' --with-apxs2=/usr/local/apache/bin/apxs
    fi
    printf '%s\n' --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --with-iconv=/usr/local \
        --with-freetype=/usr/local/freetype --with-jpeg --with-zlib --enable-xml --disable-rpath \
        --enable-bcmath --enable-shmop --enable-sysvsem
    if [ "${DISTRO:-}" = "CentOS" ] && [ "${Is_ARM:-}" = "y" ]; then
        printf '%s\n' --with-curl=/usr/local/curl
    else
        printf '%s\n' --with-curl
    fi
    printf '%s\n' --enable-mbregex --enable-mbstring --enable-intl --enable-pcntl --enable-ftp \
        --enable-gd --with-openssl --with-mhash --enable-sockets --with-zip --enable-soap --with-gettext
    # n 一律禁用，y 保持 PHP 默认（编译进去）。
    [ "${Enable_PHP_Fileinfo:-}" = "n" ] && printf '%s\n' --disable-fileinfo
    # PHP 8.5 移除 --enable-opcache，OPcache 始终编入；按源码的 configure 是否支持判断。
    grep -qxF '# Check whether --enable-opcache was given.' "${src}/configure" 2>/dev/null \
        && printf '%s\n' --enable-opcache
    printf '%s\n' --with-xsl --with-pear --with-webp
    [ "${Enable_PHP_Exif:-}" = "n" ] || printf '%s\n' --enable-exif
    [ "${Enable_PHP_Ldap:-}" = "n" ] || printf '%s\n' --with-ldap --with-ldap-sasl
    [ "${Enable_PHP_Bz2:-}" = "n" ] || printf '%s\n' --with-bz2
    [ "${Enable_PHP_Sodium:-}" = "n" ] || printf '%s\n' --with-sodium
    read -r -a extra <<< "${PHP_Modules_Options:-}"
    [ "${#extra[@]}" -eq 0 ] || printf '%s\n' "${extra[@]}"
    return 0
}

# _PHP_Sys_Deps：编译 PHP 所需的系统包。
_PHP_Sys_Deps()
{
    local packages c8packages cs9packages o8packages uospackages

    echo "正在安装 PHP 依赖包..."
    if [ "$PM" = "yum" ]; then
        if [ "${DISTRO}" = "Oracle" ]; then
            yum -y install oracle-epel-release
        else
            yum -y install epel-release
        fi
        for packages in make gcc gcc-c++ gcc-g77 libjpeg libjpeg-devel libjpeg-turbo-devel libpng libpng-devel libpng10 libpng10-devel gd gd-devel libxml2 libxml2-devel zlib zlib-devel glib2-devel bzip2-devel libzip-devel libevent libevent-devel ncurses ncurses-devel curl-devel libcurl libcurl-devel e2fsprogs-devel krb5 krb5-devel libidn libidn-devel openssl-devel gettext-devel ncurses-devel gmp-devel pspell-devel libXpm-devel libtirpc-devel cyrus-sasl-devel c-ares-devel libicu-devel libxslt libxslt-devel xz expat-devel libzip-devel bzip2 bzip2-devel sqlite-devel oniguruma-devel libwebp-devel;
        do yum -y install $packages; done
    elif [ "$PM" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        Apt_Get update
        for packages in debian-keyring debian-archive-keyring build-essential gcc g++ make libzip-dev libc6-dev libbz2-dev libncurses5 libncurses5-dev libevent-dev libssl-dev libsasl2-dev libltdl3-dev libltdl-dev zlib1g zlib1g-dev libbz2-1.0 libbz2-dev libglib2.0-0 libglib2.0-dev libpng3 libjpeg-dev libpng-dev libpng12-0 libpng12-dev libkrb5-dev curl libcurl3-gnutls libcurl4-gnutls-dev libcurl4-openssl-dev libpq-dev libpq5 libpng12-dev libxml2-dev libcap-dev libaio-dev libtirpc-dev libc-ares-dev libicu-dev e2fsprogs libxslt1.1 libxslt1-dev xz-utils libexpat1-dev bzip2 libbz2-dev libsqlite3-dev libonig-dev libwebp-dev;
        do Apt_Get --no-install-recommends install -y $packages; done
    fi

    if echo "${CentOS_Version}" | grep -Eqi "^8" || echo "${RHEL_Version}" | grep -Eqi "^8" || echo "${Rocky_Version}" | grep -Eqi "^8" || echo "${Alma_Version}" | grep -Eqi "^8" || echo "${Anolis_Version}" | grep -Eqi "^8" || echo "${OpenCloudOS_Version}" | grep -Eqi "^8"; then
        Check_PowerTools
        if [ "${repo_id}" != "" ]; then
            echo "正在安装 PowerTools 仓库中的依赖包..."
            for c8packages in rpcgen re2c oniguruma-devel;
            do dnf --enablerepo=${repo_id} install ${c8packages} -y; done
        fi
        dnf install libarchive -y
    fi

    if echo "${CentOS_Version}" | grep -Eqi "^9" || echo "${Alma_Version}" | grep -Eqi "^9" || echo "${Rocky_Version}" | grep -Eqi "^9"; then
        for cs9packages in oniguruma-devel libzip-devel libtirpc-devel;
        do dnf --enablerepo=crb install ${cs9packages} -y; done
    fi

    if [ "${DISTRO}" = "Oracle" ] && echo "${Oracle_Version}" | grep -Eqi "^8"; then
        Check_Codeready
        for o8packages in rpcgen re2c oniguruma-devel;
        do dnf --enablerepo=${repo_id} install ${o8packages} -y; done
        dnf install libarchive -y
    fi

    if echo "${CentOS_Version}" | grep -Eqi "^7" || echo "${RHEL_Version}" | grep -Eqi "^7"  || echo "${Aliyun_Version}" | grep -Eqi "^2" || echo "${Alibaba_Version}" | grep -Eqi "^2" || echo "${Oracle_Version}" | grep -Eqi "^7" || echo "${Anolis_Version}" | grep -Eqi "^7"; then
        # 依赖统一通过官方 EPEL 软件源安装。
        if [ "${DISTRO}" = "Oracle" ]; then
            yum -y install oracle-epel-release
        else
            yum -y install epel-release
        fi
        yum -y install oniguruma oniguruma-devel
        yum -y install libsodium-devel
    fi

    if [ "${DISTRO}" = "UOS" ]; then
        Check_PowerTools
        if [ "${repo_id}" != "" ]; then
            echo "正在安装 PowerTools 仓库中的依赖包..."
            for uospackages in rpcgen re2c oniguruma-devel;
            do dnf --enablerepo=${repo_id} install ${uospackages} -y; done
        fi
    fi

    if [ -d /usr/include/x86_64-linux-gnu/curl ]; then
        ln -sfn /usr/include/x86_64-linux-gnu/curl /usr/include/
    elif [ -d /usr/include/i386-linux-gnu/curl ]; then
        ln -sfn /usr/include/i386-linux-gnu/curl /usr/include/
    fi

    if [ -d /usr/include/arm-linux-gnueabihf/curl ]; then
        ln -sfn /usr/include/arm-linux-gnueabihf/curl /usr/include/
    fi

    ldconfig
}

# _PHP_Opt_Deps <分支>：lnmp.conf 中开启的可选编译项所需的库与系统包。
_PHP_Opt_Deps()
{
    local branch=$1

    if [ "${DISTRO:-}" = "CentOS" ] && [ "${Is_ARM:-}" = "y" ]; then
        if [ -s /usr/local/curl/bin/curl ]; then
            Echo_Green "Curl 检查通过。"
        else
            Install_Curl
        fi
    fi
    if [ "${Enable_PHP_Ldap:-}" != "n" ]; then
        if [ "$PM" = "yum" ]; then
            yum -y install openldap-devel cyrus-sasl-devel
            if [ "${Is_64bit}" == "y" ]; then
                ln -sf /usr/lib64/libldap* /usr/lib/
                ln -sf /usr/lib64/liblber* /usr/lib/
            fi
        elif [ "$PM" = "apt" ]; then
            Apt_Get install -y libldap2-dev libsasl2-dev
            if [ -s /usr/lib/x86_64-linux-gnu/libldap.so ]; then
                ln -sf /usr/lib/x86_64-linux-gnu/libldap.so /usr/lib/
                ln -sf /usr/lib/x86_64-linux-gnu/liblber.so /usr/lib/
            fi
        fi
    fi
    [ "${Enable_PHP_Bz2:-}" = "n" ] || Install_Libzip
    if [ "${Enable_PHP_Sodium:-}" != "n" ]; then
        if [ "$PM" = "yum" ]; then
            if [ "${DISTRO}" = "Oracle" ]; then
                yum -y install oracle-epel-release
            else
                yum -y install epel-release
            fi
            yum -y install libsodium-devel
        elif [ "$PM" = "apt" ]; then
            Apt_Get install -y libsodium-dev
        fi
    fi
    return 0
}

# _PHP_Deps <分支> <opts|full>：在子 shell 中调用。
# 首次整栈安装的系统包由安装入口的依赖步骤安装，主 PHP 只补可选项；多版本实例与升级安装全部依赖。
_PHP_Deps()
{
    _PHP_Opt_Deps "$1"
    [ "$2" = full ] || return 0
    _PHP_Sys_Deps
    Check_Openssl
    return 0
}

# _PHP_Intl_Env：ICU 68 及以上移除了 TRUE/FALSE 宏，PHP 旧代码仍在使用。
_PHP_Intl_Env()
{
    if pkg-config --modversion icu-i18n 2>/dev/null | grep -Eqi '^6[89]|7[0-9]'; then
        export CXX="g++ -DTRUE=1 -DFALSE=0"
        export  CC="gcc -DTRUE=1 -DFALSE=0"
    fi
}

# _PHP_Openssl3_Patch <版本>：PHP 8.0 在 OpenSSL 3.x 环境中需要兼容补丁，在源码目录内调用。
_PHP_Openssl3_Patch()
{
    [ "$(_PHP_Branch "$1")" = "8.0" ] || return 0
    openssl version 2>/dev/null | grep -Eqi "OpenSSL 3" || return 0
    echo "检测到 OpenSSL 3.0，正在为 PHP 8.0 应用补丁..."
    patch -p1 < "${cur_dir}/src/patch/php-8.0-openssl3.0.patch"
}

PHP_Sources()
{
    local prefix=$1 sapi=$2 ver=$3 file check='upstream'

    _PHP_Role "${prefix}" "${sapi}" >/dev/null && _PHP_Ver_Ok "${ver}" || return 1
    file="php-${ver}.tar.bz2"
    awk -v f="${file}" '$1 !~ /^#/ && $2 == f {found=1} END {exit !found}' \
        "${cur_dir}/src/checksums.sha256" 2>/dev/null && check='src/checksums.sha256'
    printf 'php\t%s\t%s\t%s\thttps://www.php.net/distributions/%s\tsha256\t%s\n' \
        "${prefix}" "${ver}" "${file}" "${file}" "${check}"
}

# _PHP_Fetch <前缀> <SAPI> <版本>：在子 shell 中调用。校验清单有记录的版本走 Download_Files，
# 其余版本经 Download_Verified 取上游公布的 SHA256。
_PHP_Fetch()
{
    local file url check ver=$3

    IFS=$'\t' read -r _ _ _ file url _ check < <(PHP_Sources "$1" "$2" "${ver}") || return 1
    cd "${cur_dir}/src" || return 1
    if [ "${check}" = 'src/checksums.sha256' ]; then
        Download_Files "${url}" "${file}" || return 1
    else
        Download_Verified php "${ver}" "${url}" "${file}" || return 1
    fi
    [ -s "${file}" ]
}

# _PHP_Expected_Opts <前缀> <SAPI> <版本>：期望的编译选项，用于与产物读回值比较。
# --enable-opcache 取决于源码，比较时不计。
_PHP_Expected_Opts()
{
    _PHP_Configure_Args "$1" "$2" /nonexistent "$(_PHP_Branch "$3")" | grep -E '^--' \
        | grep -vx -- '--enable-opcache' | sort
}

# 多版本实例共用的 php-fpm@.service 模板与 Web 服务器的 enable-php 片段由调用方在全部实例删除后处理。
PHP_Remove()
{
    local prefix=$1 name svc init

    case "${prefix}" in /*/php|/*/php[0-9].[0-9]) ;; *) return 3 ;; esac
    IFS=$'\t' read -r name svc _ < <(_PHP_Service_Names "${prefix}")
    init="$(_PHP_Initd_Dir)/${name}"
    if [ "${svc}" != "${name}" ] && Svc_Systemd; then
        systemctl disable --now "${svc}.service" >/dev/null 2>&1
    fi
    [ -x "${init}" ] && "${init}" stop >/dev/null 2>&1
    Remove_StartUp "${name}" >/dev/null 2>&1
    rm -f "${init}"
    rm -rf -- "${prefix}"
    [ ! -e "${prefix}" ] && [ ! -e "${init}" ]
}

# PHP_Fpm_Listen <前缀>：输出 php-fpm.conf 中的 listen 取值，未配置时输出空。
PHP_Fpm_Listen()
{
    sed -n 's/^listen[[:space:]]*=[[:space:]]*//p' "$1/etc/php-fpm.conf" 2>/dev/null | head -n1
}

PHP_Installed()
{
    local prefix=$1 ver

    [ -d "${prefix}" ] || return 1
    [ -x "${prefix}/bin/php" ] && [ -x "${prefix}/bin/php-config" ] || return 2
    ver=$("${prefix}/bin/php-config" --version 2>/dev/null)
    [ -n "${ver}" ] || return 2
    printf '%s\n' "${ver}"
}

PHP_Check()
{
    local prefix=$1 sapi=$2 ver=$3 role have opts name

    role=$(_PHP_Role "${prefix}" "${sapi}") && _PHP_Ver_Ok "${ver}" || return 3
    [ -x "${prefix}/bin/php" ] && [ -x "${prefix}/bin/php-config" ] || return 1
    have=$("${prefix}/bin/php-config" --version 2>/dev/null)
    [ -n "${have}" ] || return 1
    [ "${have}" = "${ver}" ] || return 2
    opts=$("${prefix}/bin/php-config" --configure-options 2>/dev/null | tr -d "'" | tr ' ' '\n' \
        | grep -E '^--' | grep -vx -- '--enable-opcache' | sort)
    [ "${opts}" = "$(_PHP_Expected_Opts "${prefix}" "${sapi}" "${ver}")" ] || return 2
    [ -s "${prefix}/etc/php.ini" ] || return 1
    if [ "${sapi}" = fpm ]; then
        IFS=$'\t' read -r name _ _ < <(_PHP_Service_Names "${prefix}")
        [ -x "${prefix}/sbin/php-fpm" ] && [ -s "${prefix}/etc/php-fpm.conf" ] \
            && [ -s "$(_PHP_Initd_Dir)/${name}" ] || return 1
    else
        [ -s /usr/local/apache/modules/libphp.so ] || return 1
    fi
    [ -n "${role}" ]
}

PHP_Health()
{
    local prefix=$1 sapi=$2 name

    [ -x "${prefix}/bin/php" ] && [ -s "${prefix}/etc/php.ini" ] || return 1
    if [ "${sapi}" = fpm ]; then
        IFS=$'\t' read -r name _ _ < <(_PHP_Service_Names "${prefix}")
        [ -x "${prefix}/sbin/php-fpm" ] && [ -s "${prefix}/etc/php-fpm.conf" ] \
            && [ -s "$(_PHP_Initd_Dir)/${name}" ] || return 1
    else
        [ -s /usr/local/apache/modules/libphp.so ] || return 1
    fi
    if "${prefix}/bin/php" -m 2>&1 | grep -qiE '^(PHP )?(Warning|Fatal)'; then
        Echo_Red "${prefix}/bin/php 加载扩展时有告警，请检查 ${prefix}/conf.d。"
        return 2
    fi
    if [ "${sapi}" = fpm ] && ! "${prefix}/sbin/php-fpm" -t -y "${prefix}/etc/php-fpm.conf" >/dev/null 2>&1; then
        Echo_Red "php-fpm 配置测试未通过：${prefix}/sbin/php-fpm -t -y ${prefix}/etc/php-fpm.conf"
        return 2
    fi
    return 0
}

PHP_Verify()
{
    local prefix=$1 sapi=$2 ver=$3 out

    PHP_Check "${prefix}" "${sapi}" "${ver}" || return 1
    out=$("${prefix}/bin/php" -v 2>&1 | head -n 1)
    case "${out}" in
    "PHP ${ver} "*) ;;
    *) Echo_Red "PHP 运行版本不符：期望 ${ver}，实际 '${out}'"; return 1 ;;
    esac
    PHP_Health "${prefix}" "${sapi}" || return 1
}

# _PHP_Build <前缀> <SAPI> <版本> <构建目录> [暂存目录]：在子 shell 中调用。
# 给出暂存目录时 make install 经 INSTALL_ROOT 写入暂存目录，否则直接写入前缀。
_PHP_Build()
{
    local prefix=$1 sapi=$2 ver=$3 bdir=$4 stage=${5:-} src
    local -a args=()

    src="${bdir}/php-${ver}"
    Install_Libzip
    Echo_Blue "[+] 正在安装 PHP ${ver}"
    if ! Unpack_Checked "${cur_dir}/src/php-${ver}.tar.bz2" "${bdir}" "php-${ver}"; then
        Echo_Red "php-${ver}.tar.bz2 解压失败或归档成员不合规。"
        return 1
    fi
    cd "${src}" || return 1
    _PHP_Openssl3_Patch "${ver}" || return 1
    # configure 的 iconv 探针要能加载 /usr/local/lib 里的 libiconv.so.2。
    Ensure_Libiconv_Ldpath || return 1
    _PHP_Intl_Env
    mapfile -t args < <(_PHP_Configure_Args "${prefix}" "${sapi}" "${src}" "$(_PHP_Branch "${ver}")")
    if ! ./configure "${args[@]}"; then
        Echo_Red "PHP ${ver} 的 configure 失败。"
        return 1
    fi
    if [ -z "${stage}" ]; then
        PHP_Make_Install
        return $?
    fi
    if ! make ZEND_EXTRA_LIBS='-liconv' -j"$(Build_Jobs)"; then
        Echo_Yellow "并行编译失败，退回串行重试..."
        make ZEND_EXTRA_LIBS='-liconv' || { Echo_Red "PHP ${ver} 编译失败。"; return 1; }
    fi
    # apxs -i -a 在 INSTALL_ROOT 下写模块并改写 httpd.conf，暂存目录需有一份主配置。
    if [ "${sapi}" = apxs ]; then
        mkdir -p "${stage}/usr/local/apache/conf" &&
            cp -p /usr/local/apache/conf/httpd.conf "${stage}/usr/local/apache/conf/httpd.conf" || return 1
    fi
    make install INSTALL_ROOT="${stage}" || { Echo_Red "PHP ${ver} 安装到暂存目录失败。"; return 1; }
    if [ "${sapi}" = apxs ] && [ ! -s "${stage}/usr/local/apache/modules/libphp.so" ]; then
        Echo_Red "暂存目录中没有新的 libphp.so。"
        return 1
    fi
}

# _PHP_Cleanup <目录>：只清理本模块在 src/ 下创建的私有目录。
_PHP_Cleanup()
{
    case "$1" in
    "${cur_dir}"/src/.php-build.*|"${cur_dir}"/src/.php-stage.*) rm -rf -- "$1" ;;
    esac
}

# _PHP_Ini_Tune <php.ini>：php.ini 基线参数。
_PHP_Ini_Tune()
{
    local ini="$1"

    if [ ! -s "${ini}" ]; then
        Echo_Red "php.ini 不存在或为空：${ini}"
        return 1
    fi

    # 文件上限 50M；multipart 请求体还有 boundary 和表单字段开销，
    # post_max_size 必须高于它，Nginx 的 client_max_body_size 同为 64m。
    sed -i 's/post_max_size =.*/post_max_size = 64M/g' "${ini}"
    sed -i 's/upload_max_filesize =.*/upload_max_filesize = 50M/g' "${ini}"
    sed -i 's/;date.timezone =.*/date.timezone = PRC/g' "${ini}"
    sed -i 's/short_open_tag =.*/short_open_tag = On/g' "${ini}"
    sed -i 's/;cgi.fix_pathinfo=.*/cgi.fix_pathinfo=0/g' "${ini}"
    # 关闭 X-Powered-By 响应头，避免对外暴露 PHP 版本号。
    sed -i 's/^expose_php =.*/expose_php = Off/g' "${ini}"
    sed -i 's/max_execution_time =.*/max_execution_time = 300/g' "${ini}"
    # 禁用命令执行类函数。pcntl_exec 属执行类，pcntl_fork/signal/wait 不禁用；
    # putenv 可设置 LD_PRELOAD，使 mail() 启动的 sendmail 子进程加载任意共享库。
    sed -i 's/disable_functions =.*/disable_functions = passthru,exec,system,chroot,chgrp,chown,shell_exec,proc_open,proc_get_status,popen,ini_alter,ini_restore,dl,openlog,syslog,readlink,symlink,stream_socket_server,pcntl_exec,putenv/g' "${ini}"

    return 0
}

# _PHP_Ini_Write <源码目录> <前缀>：由 php.ini-production 生成 php.ini，调整后换入。
_PHP_Ini_Write()
{
    local ini="$2/etc/php.ini"

    echo "正在修改 php.ini..."
    if ! \cp "$1/php.ini-production" "${ini}.lnmp-new" || ! _PHP_Ini_Tune "${ini}.lnmp-new" \
       || ! mv -f "${ini}.lnmp-new" "${ini}"; then
        rm -f "${ini}.lnmp-new"
        Echo_Red "生成 ${ini} 失败。"
        return 1
    fi
    return 0
}

# _PHP_FPM_Conf <目标配置> <前缀> <socket> <调优>：PHP-FPM pool 配置。
_PHP_FPM_Conf()
{
    local conf="$1" prefix="$2" sock="$3" pm children start min max pm_block

    if [ -z "${conf}" ] || [ -z "${prefix}" ] || [ -z "${sock}" ]; then
        Echo_Red "生成 php-fpm.conf 缺少参数。"
        return 1
    fi
    IFS=: read -r pm children start min max _ <<< "$4"
    case "${pm}" in
    ondemand)
        printf -v pm_block 'pm = ondemand\npm.max_children = %s\npm.process_idle_timeout = 10s' "${children}" ;;
    dynamic)
        printf -v pm_block 'pm = dynamic\npm.max_children = %s\npm.start_servers = %s\npm.min_spare_servers = %s\npm.max_spare_servers = %s' \
            "${children}" "${start}" "${min}" "${max}" ;;
    *)
        printf -v pm_block 'pm = dynamic\npm.max_children = 10\npm.start_servers = 2\npm.min_spare_servers = 1\npm.max_spare_servers = 6' ;;
    esac
    # socket 的访问边界来自 owner/group/mode；listen.allowed_clients 只对
    # TCP 监听生效，不写入。
    if ! cat >"${conf}.lnmp-new"<<EOF
[global]
pid = ${prefix}/var/run/php-fpm.pid
error_log = ${prefix}/var/log/php-fpm.log
log_level = notice

[www]
listen = ${sock}
listen.backlog = -1
listen.owner = www
listen.group = www
listen.mode = 0660
user = www
group = www
${pm_block}
pm.max_requests = 1024
; 硬超时高于 php.ini 的 max_execution_time(300)：让脚本先按 PHP 的限制超时
; 返回，而不是在正常执行中途被 FPM 杀掉连接。
; FPM 的配置解析器只认 ; 作注释，# 会被当成配置项，导致 FPM 无法启动。
request_terminate_timeout = 310
request_slowlog_timeout = 5s
slowlog = ${prefix}/var/log/slow.log
; 状态页经独立 socket 由隐藏 pool 处理，worker 全部占满时仍可查询。
pm.status_listen = ${sock%.sock}-status.sock
pm.status_path = /fpm-status
ping.path = /fpm-ping
EOF
    then
        rm -f "${conf}.lnmp-new"
        Echo_Red "写入 ${conf} 失败。"
        return 1
    fi
    mv -f "${conf}.lnmp-new" "${conf}"
}

# _PHP_Ln_Bin <前缀> <SAPI>：主 PHP 的命令链接。
_PHP_Ln_Bin()
{
    ln -sf "$1/bin/php" /usr/bin/php
    ln -sf "$1/bin/phpize" /usr/bin/phpize
    ln -sf "$1/bin/pear" /usr/bin/pear
    ln -sf "$1/bin/pecl" /usr/bin/pecl
    [ "$2" = fpm ] && ln -sf "$1/sbin/php-fpm" /usr/bin/php-fpm
    return 0
}

_PHP_Pear_Set()
{
    "$1/bin/pear" config-set php_ini "$1/etc/php.ini"
    "$1/bin/pecl" config-set php_ini "$1/etc/php.ini"
}

# _PHP_Service_Files <前缀> <源码目录> <install|refresh>：init 脚本与 unit。
# init 脚本在同目录临时文件中完成修补后换入；install 写入 unit，refresh 只刷新已存在的 unit。
_PHP_Service_Files()
{
    local prefix=$1 src=$2 mode=$3 name unit tpl dst initd tmp

    IFS=$'\t' read -r name unit tpl < <(_PHP_Service_Names "${prefix}")
    initd=$(_PHP_Initd_Dir)
    dst="/etc/systemd/system/${tpl}"
    if [ "${mode}" = install ]; then
        # 模板 unit 由所有多版本实例共用，%i 取版本号。
        if [ "${name}" = php-fpm ] || [ -d /etc/systemd/system ]; then
            Svc_Install_Unit "${cur_dir}/init.d/${tpl}" "${dst}" || return 1
            [ "${name}" = php-fpm ] || chmod 644 "${dst}"
        fi
    elif [ -f "${dst}" ]; then
        # 已安装的 unit 随升级刷新为当前模板。
        Svc_Install_Unit "${cur_dir}/init.d/${tpl}" "${dst}" || return 1
    fi

    echo "正在复制 php-fpm init.d 服务脚本..."
    tmp=$(mktemp "${initd}/.${name}.XXXXXX") || return 1
    if ! \cp "${src}/sapi/fpm/init.d.php-fpm" "${tmp}" || ! chmod 755 "${tmp}" \
       || { [ "${name}" != php-fpm ] && ! sed -i "s@# Provides:          php-fpm@# Provides:          ${name}@g" "${tmp}"; } \
       || ! Ensure_Runtime_Directory /run/php-fpm root root \
       || ! Patch_Init_Runtime_Directory "${tmp}" /run/php-fpm root root \
       || ! Patch_Init_Systemd_Redirect "${tmp}" "${unit}" \
       || ! mv -f "${tmp}" "${initd}/${name}"; then
        rm -f "${tmp}"
        Echo_Red "写入 ${initd}/${name} 失败。"
        return 1
    fi
    return 0
}

# _PHP_Configure_Instance <前缀> <SAPI> <源码目录> <调优> <install|refresh>：
# 写入 php.ini、FPM 配置与服务文件；主 PHP 另建命令链接与 PEAR 配置。
_PHP_Configure_Instance()
{
    local prefix=$1 sapi=$2 src=$3 tune=$4 mode=$5

    echo "正在复制新的 PHP 配置文件..."
    mkdir -p "${prefix}/etc" "${prefix}/conf.d" || return 1
    [ "${prefix##*/}" = php ] && _PHP_Ln_Bin "${prefix}" "${sapi}"
    _PHP_Ini_Write "${src}" "${prefix}" || return 1
    [ "${prefix##*/}" = php ] && _PHP_Pear_Set "${prefix}"
    [ "${sapi}" = fpm ] || return 0
    echo "正在创建新的 php-fpm 配置文件..."
    _PHP_FPM_Conf "${prefix}/etc/php-fpm.conf" "${prefix}" "$(_PHP_Sock "${prefix}")" "${tune}" || return 1
    if [ ! -s "${prefix}/sbin/php-fpm" ] || [ ! -s "${prefix}/bin/php" ]; then
        Echo_Red "${prefix} 缺少 php 或 php-fpm 程序。"
        return 1
    fi
    _PHP_Service_Files "${prefix}" "${src}" "${mode}"
}

# _PHP_Install_Abort <前缀> <安装前是否存在> <init 脚本安装前是否存在>：删除本次写入的文件。
_PHP_Install_Abort()
{
    local prefix=$1 name

    IFS=$'\t' read -r name _ _ < <(_PHP_Service_Names "${prefix}")
    [ "$2" = n ] && [ -n "${prefix##*/}" ] && rm -rf -- "${prefix}"
    [ "$3" = n ] && rm -f "$(_PHP_Initd_Dir)/${name}"
    return 0
}

PHP_Install()
{
    local prefix=$1 sapi=$2 ver=$3 tune=$4 role rc existed=n init_existed=n name bdir deps=full

    PHP_Check "${prefix}" "${sapi}" "${ver}"
    rc=$?
    case "${rc}" in
    0) Echo_Green "PHP ${ver}（${prefix}）已就绪，无需安装。"; return 0 ;;
    2) Echo_Red "${prefix} 已安装的 PHP 版本或编译选项与期望的 ${ver} 不符，未改动。更换版本请执行 ./upgrade.sh。"; return 2 ;;
    3) Echo_Red "PHP 安装参数错误：${prefix} ${sapi} ${ver}"; return 3 ;;
    esac
    role=$(_PHP_Role "${prefix}" "${sapi}")
    [ "${role}" = main ] && deps=opts
    [ -e "${prefix}" ] && existed=y
    IFS=$'\t' read -r name _ _ < <(_PHP_Service_Names "${prefix}")
    [ -e "$(_PHP_Initd_Dir)/${name}" ] && init_existed=y

    ( _PHP_Deps "$(_PHP_Branch "${ver}")" "${deps}" ) || { Echo_Red "PHP 依赖安装失败。"; return 1; }
    ( _PHP_Fetch "${prefix}" "${sapi}" "${ver}" ) || { Echo_Red "php-${ver}.tar.bz2 下载或校验失败。"; return 1; }
    bdir=$(mktemp -d "${cur_dir}/src/.php-build.XXXXXXXX") || return 1

    if ! ( _PHP_Build "${prefix}" "${sapi}" "${ver}" "${bdir}" ); then
        _PHP_Cleanup "${bdir}"
        _PHP_Install_Abort "${prefix}" "${existed}" "${init_existed}"
        Echo_Red "PHP ${ver} 安装失败。"
        return 1
    fi
    # 覆盖安装时清掉旧 ini：它们指向上一次安装的扩展目录，保留会让 PHP 启动告警。
    [ "${existed}" = y ] && rm -f "${prefix}/conf.d/"*
    if ! _PHP_Configure_Instance "${prefix}" "${sapi}" "${bdir}/php-${ver}" "${tune}" install; then
        _PHP_Cleanup "${bdir}"
        _PHP_Install_Abort "${prefix}" "${existed}" "${init_existed}"
        Echo_Red "PHP ${ver} 安装失败。"
        return 1
    fi
    _PHP_Cleanup "${bdir}"
    if [ "${sapi}" = apxs ] && [ ! -s /usr/local/apache/modules/libphp.so ]; then
        _PHP_Install_Abort "${prefix}" "${existed}" "${init_existed}"
        Echo_Red "PHP ${ver} 未生成 Apache 模块 libphp.so。"
        return 1
    fi
    return 0
}

# _PHP_Ini_Ext <ini>：输出 ini 加载的第一个扩展名（去掉路径与 .so）。
_PHP_Ini_Ext()
{
    local so
    so=$(sed -n -E 's/^[[:space:]]*(zend_)?extension[[:space:]]*=[[:space:]]*"?([^"[:space:];]+)"?.*/\2/p' "$1" | head -n 1)
    so=${so##*/}
    printf '%s\n' "${so%.so}"
}

# _PHP_Prefetch_Ext <前缀>：扩展 API 将变化时，在停服前取齐扩展模块需重新构建的来源。
# PHP 源码类扩展取自新版本源码包，已随升级下载。
_PHP_Prefetch_Ext()
{
    local f ext file url

    for f in "$1/conf.d"/*.ini; do
        [ -f "${f}" ] || continue
        ext=$(_PHP_Ini_Ext "${f}")
        [ -n "${ext}" ] && PHPExt_Files "${ext}" >/dev/null 2>&1 || continue
        while IFS=$'\t' read -r _ _ _ file url _; do
            case "${file}" in php-*.tar.bz2) continue ;; esac
            ( cd "${cur_dir}/src" && Download_Files "${url}" "${file}" ) \
                || Echo_Yellow "${file} 预取失败，换入后重新构建时再次下载。"
        done < <(PHPExt_Sources "$1" "${ext}")
    done
    return 0
}

# _PHP_Ini_Decls <ini>：输出 ini 中每条 extension/zend_extension 声明的产物名（去掉路径与 .so）。
_PHP_Ini_Decls()
{
    local so

    while read -r so; do
        so=${so##*/}
        printf '%s\n' "${so%.so}"
    done < <(sed -n -E 's/^[[:space:]]*(zend_)?extension[[:space:]]*=[[:space:]]*"?([^"[:space:];]+)"?.*/\2/p' "$1")
}

# _PHP_Ini_Has_Settings <ini>：含加载声明之外的设置时返回 0。
_PHP_Ini_Has_Settings()
{
    grep -vE '^[[:space:]]*((zend_)?extension[[:space:]]*=|;|\[|$)' "$1" | grep -q .
}

# _PHP_Ini_Merge <旧 ini> <新 ini> [托管键正则]：旧文件中的普通设置覆盖新文件同名键或追加到末尾；
# 加载声明与托管键保留新文件的值。经同目录临时文件改名替换，保留新文件权限。
_PHP_Ini_Merge()
{
    local old=$1 new=$2 managed=${3:-} tmp

    tmp=$(mktemp "${new%/*}/.merge.XXXXXX") || return 1
    if awk -v managed="${managed}" '
        function key(l,  k) {
            if (!match(l, /^[ \t]*[A-Za-z0-9_.]+[ \t]*=/)) return ""
            k = substr(l, RSTART, RLENGTH); gsub(/[ \t=]/, "", k); return k
        }
        NR == FNR {
            k = key($0)
            if (k == "" || k ~ /^(zend_)?extension$/ || (managed != "" && k ~ ("^(" managed ")$"))) next
            if (!(k in val)) order[++n] = k
            val[k] = $0
            next
        }
        { k = key($0); if (k in val) { print val[k]; done[k] = 1 } else print }
        END { for (i = 1; i <= n; i++) if (!(order[i] in done)) print val[order[i]] }
        ' "${old}" "${new}" > "${tmp}" && chmod --reference="${new}" "${tmp}" && mv -f "${tmp}" "${new}"; then
        return 0
    fi
    rm -f "${tmp}"
    return 1
}

# _PHP_Carry_Ext <旧前缀> <新前缀>：把旧 PHP 的 conf.d 带到新 PHP。
# 不含扩展声明的 ini 按原内容、权限沿用；声明的扩展全部已内置时去掉声明行沿用其余设置。
# 新 conf.d 已重新生成的同名 ini（如 OPcache）合并旧文件的设置，调优负责的键取新值。
# 扩展 API 编号不变时复制 .so 与 ini，用新 PHP 确认每条声明都能加载且无启动警告。
# 无法沿用时，扩展模块管理的扩展逐个按新实例重新构建，其余扩展列出名字供重装；
# 同文件中的其它设置合并到重建的同名 ini，或去掉加载声明后沿用。
# 旧目录的 php-config 仍报告原安装路径，扩展目录按 API 编号在旧目录下重新定位。
_PHP_Carry_Ext()
{
    local old="$1" new="$2" f base name so old_api new_dir old_ext lost='' lostconf='' carried='' rebuilt='' conf='' builtin
    local ext module decls d ok reason

    [ -d "${old}/conf.d" ] || return 0
    new_dir=$("${new}/bin/php-config" --extension-dir 2>/dev/null)
    old_api=$("${old}/bin/php-config" --extension-dir 2>/dev/null)
    old_api=${old_api##*/}
    old_ext="${old}/lib/php/extensions/${old_api}"
    builtin=$("${new}/bin/php" -n -m 2>/dev/null)

    # ini 按序号排列，igbinary（020）先于依赖它的 redis（021）处理。
    for f in "${old}/conf.d"/*.ini; do
        [ -f "${f}" ] || continue
        base=${f##*/}
        # 新 conf.d 已有同名 ini（如刚重建的 opcache）时只合并设置。
        if [ -s "${new}/conf.d/${base}" ]; then
            if _PHP_Ini_Has_Settings "${f}"; then
                _PHP_Ini_Merge "${f}" "${new}/conf.d/${base}" 'opcache\.(memory_consumption|interned_strings_buffer)' \
                    && conf="${conf} ${base}" || lostconf="${lostconf} ${base}"
            fi
            continue
        fi
        decls=$(_PHP_Ini_Decls "${f}")
        if [ -z "${decls}" ]; then
            cp -p "${f}" "${new}/conf.d/${base}" && conf="${conf} ${base}" || lost="${lost} ${base}"
            continue
        fi
        ok=y
        for d in ${decls}; do
            printf '%s\n' "${builtin}" | grep -qixF "${d}" || { ok=n; break; }
        done
        if [ "${ok}" = y ]; then
            # 新版本已内置（如编译时启用的 exif），去掉加载声明，保留同文件中的其它设置。
            if _PHP_Ini_Has_Settings "${f}"; then
                cp -p "${f}" "${new}/conf.d/${base}" \
                    && sed -i -E '/^[[:space:]]*(zend_)?extension[[:space:]]*=/d' "${new}/conf.d/${base}" \
                    && conf="${conf} ${base}"
            fi
            continue
        fi
        ext=${decls%%$'\n'*}
        name=${ext}
        module=''
        IFS=$'\t' read -r _ _ module < <(PHPExt_Files "${ext}" 2>/dev/null)
        [ -n "${module}" ] || module=${name}
        if [ -n "${old_api}" ] && [ -n "${new_dir}" ] && [ "${old_api}" = "${new_dir##*/}" ] && [ -d "${old_ext}" ]; then
            # PHP 8.5 的 OPcache 静态编入，新版本可能尚无扩展目录。
            if mkdir -p "${new_dir}"; then
                for so in ${decls}; do
                    [ -f "${old_ext}/${so}.so" ] && [ ! -e "${new_dir}/${so}.so" ] && cp -p "${old_ext}/${so}.so" "${new_dir}/"
                done
                cp -p "${f}" "${new}/conf.d/${base}"
                ok=y
                for d in ${decls}; do
                    [ "${d}" = "${ext}" ] && d=${module}
                    "${new}/bin/php" --ri "${d}" >/dev/null 2>&1 || { ok=n; break; }
                done
                if [ "${ok}" = y ] && ! "${new}/bin/php" -m 2>&1 | grep -qiE '^(PHP )?(Warning|Fatal)'; then
                    carried="${carried} ${name}"
                    continue
                fi
                rm -f "${new}/conf.d/${base}"
            fi
        fi
        for d in ${decls}; do
            printf '%s\n' "${builtin}" | grep -qixF "${d}" && continue
            if PHPExt_Files "${d}" >/dev/null 2>&1 && PHPExt_Install "${new}" "${d}" reason; then
                rebuilt="${rebuilt} ${d}"
            else
                lost="${lost} ${d}"
            fi
        done
        _PHP_Ini_Has_Settings "${f}" || continue
        if [ -s "${new}/conf.d/${base}" ]; then
            _PHP_Ini_Merge "${f}" "${new}/conf.d/${base}" && conf="${conf} ${base}" || lostconf="${lostconf} ${base}"
        elif cp -p "${f}" "${new}/conf.d/${base}" \
             && sed -i -E '/^[[:space:]]*(zend_)?extension[[:space:]]*=/d' "${new}/conf.d/${base}"; then
            conf="${conf} ${base}"
        else
            rm -f "${new}/conf.d/${base}"
            lostconf="${lostconf} ${base}"
        fi
    done

    [ -z "${conf}" ] || Echo_Green "已沿用旧版本的 PHP 配置文件：${conf# }"
    [ -z "${carried}" ] || Echo_Green "已沿用旧版本的 PHP 扩展（扩展 API ${old_api} 未变）：${carried# }"
    [ -z "${rebuilt}" ] || Echo_Green "已按新版本重新构建的 PHP 扩展：${rebuilt# }"
    if [ -n "${lost}" ]; then
        Echo_Yellow "升级后以下 PHP 扩展需要重装（无法沿用且未能重新构建）："
        Echo_Yellow "  ${lost# }"
        Echo_Yellow "重装：bash addons.sh install <名字>；旧配置保留在 ${old}/conf.d"
    fi
    [ -z "${lostconf}" ] || Echo_Yellow "以下 PHP 配置文件的设置未能沿用，请对照 ${old}/conf.d 手工恢复：${lostconf# }"
    return 0
}

# _PHP_MPHP_Register_StartUp <分支>：模板 unit 已安装时注册 php-fpm@<分支>，撤销 SysV 启动项，
# 并按 cgroup 结束其残留进程：两者共用 socket 与 pid 文件，pid 文件丢失后 SysV 脚本无法停止。
# 未安装模板 unit 时保持 SysV 注册。
_PHP_MPHP_Register_StartUp()
{
    local ver="$1"

    if Svc_Use_Systemd "php-fpm@${ver}"; then
        Remove_StartUp "php-fpm${ver}"
        systemctl kill --signal=SIGQUIT "php-fpm${ver}.service" >/dev/null 2>&1
        StartUp "php-fpm@${ver}"
    else
        StartUp "php-fpm${ver}"
    fi
}

# _PHP_Running <前缀> <SAPI>：目标实例已运行时返回 0。FPM 按 pid 文件核对进程程序路径与 socket 监听，
# Apache 模块方式核对 httpd 进程。启动后最多等待 5 秒。
_PHP_Running()
{
    local prefix=$1 sapi=$2 pid exe listen i

    for i in 1 2 3 4 5; do
        if [ "${sapi}" = apxs ]; then
            pgrep -f '^/usr/local/apache/bin/httpd' >/dev/null 2>&1 && return 0
        else
            pid=$(cat "${prefix}/var/run/php-fpm.pid" 2>/dev/null)
            exe=''
            [ -n "${pid}" ] && exe=$(readlink "/proc/${pid}/exe" 2>/dev/null)
            listen=$(PHP_Fpm_Listen "${prefix}")
            if [ "${exe}" = "${prefix}/sbin/php-fpm" ]; then
                case "${listen}" in
                /*) [ -S "${listen}" ] && { ! command -v ss >/dev/null 2>&1 || ss -xlH 2>/dev/null | grep -qF " ${listen} "; } && return 0 ;;
                *) return 0 ;;
                esac
            fi
        fi
        [ "${i}" -lt 5 ] && sleep 1
    done
    return 1
}

# _PHP_Rollback <前缀> <SAPI> <旧目录> <时间戳>：恢复升级前的目录、init 脚本与 Apache 模块。
# 旧目录无法放回时返回 1。
_PHP_Rollback()
{
    local prefix=$1 sapi=$2 old=$3 stamp=$4 name rc=0

    Echo_Red "正在回滚到升级前的 PHP..."
    IFS=$'\t' read -r name _ _ < <(_PHP_Service_Names "${prefix}")
    if [ -d "${old}" ]; then
        [ -n "${prefix##*/}" ] && rm -rf -- "${prefix}"
        mv "${old}" "${prefix}" || rc=1
    fi
    if [ "${sapi}" = fpm ]; then
        if [ -s "${prefix}/init.d.php-fpm.bak.${stamp}" ]; then
            \cp "${prefix}/init.d.php-fpm.bak.${stamp}" "$(_PHP_Initd_Dir)/${name}" || rc=1
            chmod +x "$(_PHP_Initd_Dir)/${name}"
            Patch_Init_Systemd_Redirect "$(_PHP_Initd_Dir)/${name}" "$(_PHP_Service_Names "${prefix}" | cut -f2)"
        fi
    else
        [ -s "/usr/local/apache/modules/libphp.so.bak.${stamp}" ] && \
            \cp "/usr/local/apache/modules/libphp.so.bak.${stamp}" /usr/local/apache/modules/libphp.so
        [ -s "/usr/local/apache/conf/httpd.conf.bak.${stamp}" ] && \
            \cp "/usr/local/apache/conf/httpd.conf.bak.${stamp}" /usr/local/apache/conf/httpd.conf
    fi
    [ "${prefix##*/}" = php ] && _PHP_Ln_Bin "${prefix}" "${sapi}"
    lnmp start
    if [ "${rc}" -eq 0 ] && ! _PHP_Running "${prefix}" "${sapi}"; then
        Echo_Red "已放回升级前的 PHP，但服务未能启动。"
        rc=1
    fi
    if [ "${rc}" -eq 0 ]; then
        Echo_Red "已恢复升级前的 PHP。请检查站点是否正常。"
    else
        if [ -d "${old}" ]; then
            Echo_Red "回滚未完成：请手工检查 ${prefix} 与 ${old}。"
        else
            Echo_Red "回滚未完成：请手工检查 ${prefix} 与服务 ${name}。"
        fi
    fi
    return "${rc}"
}

# _PHP_Upgrade_Post_Check <前缀> <SAPI> <版本>：换入并启动后的验收。
_PHP_Upgrade_Post_Check()
{
    local prefix=$1 sapi=$2 ver=$3

    if [ "${sapi}" = apxs ]; then
        if [[ ! -s /usr/local/apache/bin/httpd || ! -s /usr/local/apache/modules/libphp.so || ! -s /usr/local/apache/conf/httpd.conf ]]; then
            Echo_Red "Apache 或 libphp.so 缺失。"
            return 1
        fi
        # 存量机器的 httpd.conf 可能仍是线程型 MPM，与 mod_php 不兼容。
        Check_Apache_MPM_For_ModPHP || return 1
    fi
    PHP_Verify "${prefix}" "${sapi}" "${ver}" || return 1
    if ! _PHP_Running "${prefix}" "${sapi}"; then
        Echo_Red "${prefix} 的服务未运行或未监听：$( [ "${sapi}" = fpm ] && PHP_Fpm_Listen "${prefix}" || echo httpd )"
        return 1
    fi
    return 0
}

# _PHP_Upgrade_Finish <前缀> <SAPI> <版本> <调优> <源码目录> <旧目录>：换入后的配置、扩展与启动。
_PHP_Upgrade_Finish()
{
    local prefix=$1 sapi=$2 ver=$3 tune=$4 src=$5 old=$6 opcache_mb

    _PHP_Configure_Instance "${prefix}" "${sapi}" "${src}" "${tune}" refresh || return 1
    if [ "${sapi}" = apxs ]; then
        # 清理旧 PHP 5/7 Apache 模块的 LoadModule 残留。
        sed -i '/^LoadModule php5_module/d' /usr/local/apache/conf/httpd.conf
        sed -i '/^LoadModule php7_module/d' /usr/local/apache/conf/httpd.conf
    fi
    IFS=: read -r _ _ _ _ _ opcache_mb <<< "${tune}"
    [ "${Enable_PHP_Default_Opcache}" = 'y' ] && Enable_Opcache_Config "${prefix}" "${opcache_mb}"
    _PHP_Carry_Ext "${old}" "${prefix}"
    return 0
}

PHP_Upgrade()
{
    local prefix=$1 sapi=$2 ver=$3 tune=$4 role br stamp stage bdir old name initd out new_api old_api

    role=$(_PHP_Role "${prefix}" "${sapi}") && _PHP_Ver_Ok "${ver}" || { Echo_Red "PHP 升级参数错误：${prefix} ${sapi} ${ver}"; return 1; }
    br=$(_PHP_Branch "${ver}")
    if [ ! -x "${prefix}/bin/php" ]; then
        Echo_Red "${prefix} 下没有已安装的 PHP。"
        return 1
    fi
    if [ "${role}" = mphp ] && [ "${prefix##*/php}" != "${br}" ]; then
        Echo_Red "错误：不能跨 PHP 分支升级！当前分支为 ${prefix##*/php}，目标版本为 ${ver}"
        return 1
    fi
    IFS=$'\t' read -r name _ _ < <(_PHP_Service_Names "${prefix}")
    initd=$(_PHP_Initd_Dir)
    stamp=$(date +%Y%m%d%H%M%S)

    if ! ( _PHP_Fetch "${prefix}" "${sapi}" "${ver}" ); then
        Echo_Red "错误！PHP ${ver} 下载或校验失败，请检查版本号。"
        return 1
    fi
    ( _PHP_Deps "${br}" full ) || { Echo_Red "PHP 依赖安装失败。**线上 PHP 未做任何改动。**"; return 1; }

    # 先构建并安装到暂存目录，冒烟测试通过后才停服切换。
    bdir=$(mktemp -d "${cur_dir}/src/.php-build.XXXXXXXX") || return 1
    stage=$(mktemp -d "${cur_dir}/src/.php-stage.XXXXXXXX") || { _PHP_Cleanup "${bdir}"; return 1; }
    if ! ( _PHP_Build "${prefix}" "${sapi}" "${ver}" "${bdir}" "${stage}" ); then
        Echo_Red "**线上 PHP 未做任何改动。**"
        _PHP_Cleanup "${stage}"; _PHP_Cleanup "${bdir}"
        return 1
    fi
    # -n 不加载 ini：暂存版本按线上路径编译，线上 conf.d 的启动警告会排在版本行之前。
    out=$("${stage}${prefix}/bin/php" -n -v 2>&1 | head -n 1)
    case "${out}" in
    "PHP ${ver} "*) Echo_Green "新 PHP 冒烟测试通过：${out}" ;;
    *)
        Echo_Red "新构建的 PHP 版本不符：期望 ${ver}，实际 '${out}'"
        Echo_Red "**线上 PHP 未做任何改动。**"
        _PHP_Cleanup "${stage}"; _PHP_Cleanup "${bdir}"
        return 1
        ;;
    esac

    new_api=$("${stage}${prefix}/bin/php-config" --extension-dir 2>/dev/null)
    old_api=$("${prefix}/bin/php-config" --extension-dir 2>/dev/null)
    if [ "${new_api##*/}" != "${old_api##*/}" ]; then
        Echo_Blue "扩展 API 由 ${old_api##*/} 变为 ${new_api##*/}，换入后重新构建扩展，先取齐来源..."
        _PHP_Prefetch_Ext "${prefix}"
    fi

    if [ "${role}" = main ]; then
        old="${prefix%/*}/oldphp${stamp}"
    else
        old="${prefix%/*}/mphp-${br}-backup${stamp}"
    fi
    echo "冒烟测试通过，开始切换（此时才停服务）..."
    lnmp stop
    [ "${role}" = mphp ] && _PHP_MPHP_Register_StartUp "${br}"
    if [ "${sapi}" = apxs ]; then
        [ -s /usr/local/apache/modules/libphp.so ] && \
            \cp /usr/local/apache/modules/libphp.so "/usr/local/apache/modules/libphp.so.bak.${stamp}"
        \cp /usr/local/apache/conf/httpd.conf "/usr/local/apache/conf/httpd.conf.bak.${stamp}"
    fi
    if ! mv "${prefix}" "${old}"; then
        Echo_Red "备份原 ${prefix} 失败，放弃升级。"
        lnmp start
        _PHP_Cleanup "${stage}"; _PHP_Cleanup "${bdir}"
        return 1
    fi
    [ "${sapi}" = fpm ] && mv "${initd}/${name}" "${old}/init.d.php-fpm.bak.${stamp}"
    if ! mv "${stage}${prefix}" "${prefix}"; then
        Echo_Red "把新 PHP 搬到 ${prefix} 失败。"
        _PHP_Cleanup "${stage}"; _PHP_Cleanup "${bdir}"
        _PHP_Rollback "${prefix}" "${sapi}" "${old}" "${stamp}" || return 2
        return 1
    fi
    # 新 Apache 模块经同目录临时文件换入；暂存的 httpd.conf 不使用，线上主配置已加载 php_module。
    if [ "${sapi}" = apxs ] && ! { \cp "${stage}/usr/local/apache/modules/libphp.so" "/usr/local/apache/modules/.libphp.so.${stamp}" &&
        mv -f "/usr/local/apache/modules/.libphp.so.${stamp}" /usr/local/apache/modules/libphp.so; }; then
        Echo_Red "换入新的 libphp.so 失败。"
        rm -f "/usr/local/apache/modules/.libphp.so.${stamp}"
        _PHP_Cleanup "${stage}"; _PHP_Cleanup "${bdir}"
        _PHP_Rollback "${prefix}" "${sapi}" "${old}" "${stamp}" || return 2
        return 1
    fi
    _PHP_Cleanup "${stage}"

    if ! _PHP_Upgrade_Finish "${prefix}" "${sapi}" "${ver}" "${tune}" "${bdir}/php-${ver}" "${old}"; then
        _PHP_Cleanup "${bdir}"
        _PHP_Rollback "${prefix}" "${sapi}" "${old}" "${stamp}" || return 2
        return 1
    fi
    _PHP_Cleanup "${bdir}"
    sleep 2
    lnmp start

    if ! _PHP_Upgrade_Post_Check "${prefix}" "${sapi}" "${ver}"; then
        Echo_Red "升级后的自检未通过。"
        _PHP_Rollback "${prefix}" "${sapi}" "${old}" "${stamp}" || return 2
        return 1
    fi
    Echo_Green "======== PHP 升级完成 ======"
    Echo_Green "$("${prefix}/bin/php" -v 2>&1 | head -n 1)"
    Echo_Green "旧版本保留在 ${old}，确认无误后可自行删除。"
    return 0
}
