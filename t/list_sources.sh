#!/usr/bin/env bash
#
# t/list_sources.sh - 汇总全部下载清单
#
# 用法：bash t/list_sources.sh [all|core]
#   core 仅含默认 lnmp 安装路径必经的组件；all（默认）含全部可选组件。
#
# 每行：组件、实例、版本、文件名、地址、校验类型、校验定位，TAB 分隔，与各模块
# *_Sources 相同。行由生产代码的 *_Sources 生成，本脚本只列举版本与选项组合：
#   PHP、MySQL、MariaDB、Apache、phpMyAdmin 版本取自 include/profile.sh 菜单表；
#   其余组件版本取自 include/version.sh、conf/lnmp 与 tools/lnmp-backup.sh。
# 同一文件有多个地址时按尝试顺序连续输出；同一文件与地址只输出一次。
# 不下载、不写文件。t/probe_urls.sh 与 t/gen_checksums.sh 由此取得地址。

cd "$(dirname "$0")/.." || exit 1
cur_dir=$(pwd)
SCOPE="${1:-all}"
case "${SCOPE}" in all|core) ;; *) echo "用法：bash t/list_sources.sh [all|core]" >&2; exit 1 ;; esac

. include/main.sh
. include/verify.sh
. include/version.sh
Echo_Red()    { printf '%s\n' "$*" >&2; }
Echo_Yellow() { printf '%s\n' "$*" >&2; }
Echo_Green()  { printf '%s\n' "$*" >&2; }
for f in include/init.sh include/imageMagick.sh include/memcached.sh include/redis.sh include/php.sh \
         include/mod/nginx.sh include/mod/openresty.sh include/mod/php.sh include/mod/php_ext.sh \
         include/mod/database.sh include/mod/apache.sh include/mod/phpmyadmin.sh \
         include/mod/pureftpd.sh include/mod/nodejs.sh; do
    . "${f}" || exit 1
done
# 运行期组件不在 include/ 加载链中，只取下载清单函数与所需变量。
eval "$(sed -n "/^Acme_Sh_Ver=/p; /^Acme_Sh_SHA256=/p" conf/lnmp)"
eval "$(awk '/^Acme_Sources\(\)/,/^}/' include/rt/cli_common.sh)"
eval "$(sed -n '/^Rclone_Ver=/p; /^Rclone_Url_Base=/p; /^Rclone_Install_Path=/p' tools/lnmp-backup.sh)"
eval "$(awk '/^Rclone_Sources\(\)/,/^}/' tools/lnmp-backup.sh)"

# 列举全部变体，不按本机环境裁剪：OpenSSL 与 PCRE 源码均列出，自定义模块不列。
_Apache_Need_Openssl() { return 0; }
_Nginx_Pcre_Src() { return 0; }
OpenResty_Custom_Modules=()

# _Run <命令…>：执行一个清单函数，失败时记录并继续，最终以非零退出。
_fail=0
_Run()
{
    "$@" && return 0
    echo "清单生成失败：$*" >&2
    _fail=1
}

# _Profile_Vers <变量名>：输出 profile.sh 菜单表中该变量的全部取值。
_Profile_Vers()
{
    sed -nE "s/.*[[:space:]]$1='([^']+)'.*/\1/p" include/profile.sh | sort -u
}

# _DB_Rows：数据库源码与二进制清单，二进制架构取自菜单表 DB_Bin_Archs。
_DB_Rows()
{
    local db archs arch
    while read -r db archs; do
        _Run Database_Sources "${db%%-*}" "${db#*-}" source
        for arch in ${archs}; do
            DB_ARCH=${arch} _Run Database_Sources "${db%%-*}" "${db#*-}" bin
        done
    done < <(awk "match(\$0, /DB_Ver='[^']+'/) {v=substr(\$0, RSTART+8, RLENGTH-9)}
        v != \"\" && match(\$0, /DB_Bin_Archs='[^']*'/) {print v, substr(\$0, RSTART+14, RLENGTH-15); v=\"\"}" \
        include/profile.sh)
}

_Core_Rows()
{
    local v b
    _Run Lib_Sources openssl
    _Run Nginx_Sources "${Nginx_Ver#nginx-}" openssl
    for v in libiconv curl freetype libzip; do _Run Lib_Sources "${v}"; done
    for v in $(_Profile_Vers Php_Ver); do _Run PHP_Sources /usr/local/php fpm "${v#php-}"; done
    _DB_Rows
    for b in "${Boost_Ver}" "${Boost_New_Ver}"; do
        b=${b#boost_}; _Run Lib_Sources boost "${b//_/.}"
    done
}

_All_Rows()
{
    local v e kind url ver
    _Run Nginx_Sources "${Nginx_Ver#nginx-}" openssl,lua,brotli,purge,fancy
    _Run OpenResty_Sources "${OpenResty_Ver#openresty-}" source
    for v in $(_Profile_Vers Apache_Ver); do _Run Apache_Sources "${v#httpd-}" lamp; done
    for v in $(_Profile_Vers PhpMyAdmin_Ver); do
        v=${v#phpMyAdmin-}; _Run PhpMyAdmin_Sources "${v%-all-languages}"
    done
    for v in jemalloc gperftools libunwind; do _Run Lib_Sources "${v}"; done
    for e in $(PHPExt_List); do
        IFS=$'\t' read -r kind _ < <(_PHPExt_Spec "${e}")
        [ "${kind}" = pecl ] && _Run PHPExt_Sources /usr/local/php "${e}"
    done
    _Run Memcached_Sources
    _Run Redis_Sources
    _Run Pureftpd_Sources "${Pureftpd_Ver#pure-ftpd-}"
    for v in ${Nodejs_Majors}; do
        for _nodejs_arch in x64 arm64; do
            _Nodejs_Arch() { printf '%s\n' "${_nodejs_arch}"; }
            _Run Nodejs_Sources "${v}"
        done
        # 安装时按此签名验证 SHASUMS256.txt，只用于可达性探测。
        url=$(Nodejs_Sources "${v}" | cut -f5)
        ver=$(Nodejs_Version "${v}")
        printf 'nodejs-sig\t-\t%s\tnode-v%s-SHASUMS256.txt.sig\t%s/SHASUMS256.txt.sig\tpgp\t-\n' \
            "${ver}" "${ver}" "${url%/*}"
    done
    _Run Rclone_Sources
    _Run Lib_Sources denyhosts
    _Run Lib_Sources fail2ban
    _Run Composer_Sources
    _Run Acme_Sources
}

rows=$(_Core_Rows; [ "${SCOPE}" = all ] && _All_Rows; exit "${_fail}") || exit 1
printf '%s\n' "${rows}" | awk -F'\t' 'NF == 7 && !seen[$4 FS $5]++'
