#!/usr/bin/env bash
#
# phpMyAdmin 模块：程序目录、config.inc.php、随机访问路径、Web 访问入口片段的部署、升级与移除。
# 程序目录位于网站根目录之外（/usr/local/phpmyadmin），访问入口由 Web 服务器单独映射；
# 可写模板缓存位于 /var/lib/phpmyadmin/tmp。栈为 lnmp、lnmpa 或 lamp。
#
#   PhpMyAdmin_Sources <版本>                    输出下载清单，不下载、不写文件
#   PhpMyAdmin_Installed                         输出已装的版本；0 已装；1 未装；2 无版本标记
#   PhpMyAdmin_Check   <版本>                    0 就绪；1 缺失或不完整；2 版本不符；3 参数错误
#   PhpMyAdmin_Install <版本> <栈> <数据库端口>  部署程序目录并写入访问入口；失败时撤销本次写入
#   PhpMyAdmin_Upgrade <版本> <数据库端口>       0 成功；1 失败，线上未改动或已恢复；2 恢复失败
#   PhpMyAdmin_Verify  <版本> <栈>               Check 通过后经本机 HTTP 请求确认页面可用
#   PhpMyAdmin_Remove                            删除程序目录、模板缓存与访问入口片段
#
# 约定：不交互、不 exit、不改变调用方工作目录；解包在 src/ 下的私有目录中进行。
# 输入为参数与只读配置（cur_dir、PhpMyAdmin_Dir 缺省 /usr/local/phpmyadmin）。

_PhpMyAdmin_Dir()
{
    printf '%s\n' "${PhpMyAdmin_Dir:-/usr/local/phpmyadmin}"
}

_PhpMyAdmin_Var_Dir()
{
    printf '%s\n' "${LNMP_PMA_VAR_DIR:-/var/lib/phpmyadmin}"
}

_PhpMyAdmin_Nginx_Conf_Dir()
{
    printf '%s\n' "${LNMP_NGINX_PREFIX:-/usr/local/nginx}/conf"
}

_PhpMyAdmin_Apache_Conf_Dir()
{
    printf '%s\n' "${LNMP_APACHE_PREFIX:-/usr/local/apache}/conf"
}

_PhpMyAdmin_Ver_Ok()
{
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

PhpMyAdmin_Sources()
{
    local ver=$1 file check=sha256 loc=src/checksums.sha256

    _PhpMyAdmin_Ver_Ok "${ver}" || return 1
    file="phpMyAdmin-${ver}-all-languages.tar.xz"
    if ! awk -v f="${file}" '$1 !~ /^#/ && $2 == f {found=1} END {exit !found}' \
        "${cur_dir}/src/checksums.sha256" 2>/dev/null; then
        check=sha256-upstream
        loc="https://files.phpmyadmin.net/phpMyAdmin/${ver}/${file}.sha256"
    fi
    printf 'phpmyadmin\t/usr/local/phpmyadmin\t%s\t%s\thttps://files.phpmyadmin.net/phpMyAdmin/%s/%s\t%s\t%s\n' \
        "${ver}" "${file}" "${ver}" "${file}" "${check}" "${loc}"
}

# _PhpMyAdmin_Fetch <版本>：在子 shell 中调用。清单内的版本走 Download_Files，
# 其余版本经 Download_Verified 取上游公布的 SHA256。
_PhpMyAdmin_Fetch()
{
    local ver=$1 file url check

    cd "${cur_dir}/src" || return 1
    IFS=$'\t' read -r _ _ _ file url check _ < <(PhpMyAdmin_Sources "${ver}") || return 1
    if [ "${check}" = sha256 ]; then
        Download_Files "${url}" "${file}" || return 1
    else
        Download_Verified phpmyadmin "${ver}" "${url}" "${file}" || return 1
    fi
    [ -s "${file}" ]
}

PhpMyAdmin_Installed()
{
    local dir f ver=''

    dir=$(_PhpMyAdmin_Dir)
    [ -d "${dir}" ] || return 1
    for f in "${dir}"/RELEASE-DATE-*; do
        [ -e "${f}" ] && ver=${f##*/RELEASE-DATE-}
    done
    [ -n "${ver}" ] || return 2
    printf '%s\n' "${ver}"
}

PhpMyAdmin_Check()
{
    local ver=$1 dir

    _PhpMyAdmin_Ver_Ok "${ver}" || return 3
    dir=$(_PhpMyAdmin_Dir)
    [ -s "${dir}/index.php" ] || return 1
    [ -e "${dir}/RELEASE-DATE-${ver}" ] || return 2
    [ -s "${dir}/config.inc.php" ] && [ -s "${dir}/.access_url" ] \
        && [ -d "$(_PhpMyAdmin_Var_Dir)/tmp" ] || return 1
    return 0
}

# 收紧程序目录权限：属主 root、属组 www，目录 750、文件 640。PHP 以 www 运行，只读即可；
# config.inc.php 含 blowfish_secret，不能让本机其它账号读取。
_PhpMyAdmin_Perm()
{
    local dir="$1"

    [ -n "${dir}" ] && [ -d "${dir}" ] || return 1
    chown -R root:www "${dir}" || return 1
    find "${dir}" -type d -exec chmod 750 {} + || return 1
    find "${dir}" -type f -exec chmod 640 {} + || return 1
    [ -e "${dir}/.access_url" ] || return 0
    chown root:root "${dir}/.access_url" && chmod 600 "${dir}/.access_url"
}

# _PhpMyAdmin_Stage <版本> <数据库端口> <访问路径> <暂存目录>：解包并生成配置，
# 每次生成独立的 blowfish_secret。成功时程序位于 <暂存目录>/phpMyAdmin-<版本>-all-languages。
_PhpMyAdmin_Stage()
{
    local ver=$1 port=$2 url=$3 stage=$4 src secret

    src="phpMyAdmin-${ver}-all-languages"
    if ! Unpack_Checked "${cur_dir}/src/${src}.tar.xz" "${stage}" "${src}" \
       || [ ! -s "${stage}/${src}/index.php" ]; then
        Echo_Red "phpMyAdmin 解压失败或归档结构异常。"
        return 1
    fi
    secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    if [ -z "${secret}" ] || [ -z "${url}" ] \
       || ! sed -e "s/LNMPORG/${secret}/g" -e "s/LNMP_DB_PORT/${port}/g" \
            "${cur_dir}/conf/config.inc.php" > "${stage}/${src}/config.inc.php" \
       || grep -qE 'LNMPORG|LNMP_DB_PORT' "${stage}/${src}/config.inc.php" \
       || ! printf '%s\n' "${url}" > "${stage}/${src}/.access_url"; then
        Echo_Red "生成 phpMyAdmin 配置失败。"
        return 1
    fi
    if ! _PhpMyAdmin_Perm "${stage}/${src}"; then
        Echo_Red "设置 phpMyAdmin 目录权限失败。"
        return 1
    fi
}

# _PhpMyAdmin_Var：可写模板缓存放在网站目录之外；导入和导出目录默认关闭。
_PhpMyAdmin_Var()
{
    local var

    var=$(_PhpMyAdmin_Var_Dir)
    mkdir -p "${var}/tmp" && chown -R www:www "${var}" && chmod 700 "${var}/tmp"
}

_PhpMyAdmin_Cleanup()
{
    case "$1" in
    "${cur_dir}"/src/.pma-stage.*) rm -rf -- "$1" ;;
    esac
}

# _PhpMyAdmin_Remove_Dir <目录>：路径为空或为根目录时拒绝执行。
_PhpMyAdmin_Remove_Dir()
{
    case "$1" in ''|/) return 0 ;; esac
    rm -rf -- "$1"
}

# _PhpMyAdmin_Access <栈> <访问路径>：写入 Web 服务器的访问入口片段，并清理停用状态的旧片段。
# 主配置以通配 include 引入片段，关闭入口只需删除文件。
_PhpMyAdmin_Access()
{
    local stack=$1 url=$2 dir ngx apa obd written=0

    dir=$(_PhpMyAdmin_Dir)
    ngx=$(_PhpMyAdmin_Nginx_Conf_Dir)
    apa="$(_PhpMyAdmin_Apache_Conf_Dir)/extra"
    rm -f "${ngx}/.phpmyadmin.enable.conf.disabled" "${apa}/.phpmyadmin.enable.conf.disabled"

    if [ -d "${ngx}" ] && [ "${stack}" != lamp ]; then
        if [ "${stack}" = lnmpa ]; then
            # LNMPA 仅将 phpMyAdmin 路径反向代理到 Apache，不放开默认站点中的其他 PHP 文件。
            cat >"${ngx}/phpmyadmin.enable.conf"<<EOF || return 1
    location = /${url} {
        return 301 /${url}/;
    }

    location ^~ /${url}/ {
        proxy_pass http://127.0.0.1:88;
        include proxy.conf;
    }
EOF
        else
            # 程序目录位于网站根目录外，需单独设置 open_basedir 和 FastCGI。
            cat >"${ngx}/phpmyadmin.enable.conf"<<EOF || return 1
    location = /${url} {
        return 301 /${url}/;
    }

    location ^~ /${url}/ {
        alias ${dir}/;
        index index.php;

        location ~ ^/${url}/(.+\.php)\$ {
            alias ${dir}/\$1;
            fastcgi_pass  unix:/run/php-fpm/php-cgi.sock;
            fastcgi_index index.php;
            include fastcgi.conf;
            fastcgi_param SCRIPT_FILENAME ${dir}/\$1;
            fastcgi_param PHP_ADMIN_VALUE "open_basedir=${dir}/:/var/lib/phpmyadmin/:/tmp/:/proc/";
        }
    }
EOF
        fi
        chmod 644 "${ngx}/phpmyadmin.enable.conf" || return 1
        written=$((written + 1))
    fi
    if [ -d "${apa}" ] && [ "${stack}" != lnmp ]; then
        # 主配置经 lnmp-php.conf 交给 PHP-FPM 时用 FastCGI 参数传递，mod_php 形态用 php_admin_value。
        if grep -Eq '^[[:space:]]*Include[[:space:]]+conf/extra/lnmp-php\.conf' \
            "$(_PhpMyAdmin_Apache_Conf_Dir)/httpd.conf" 2>/dev/null; then
            obd="ProxyFCGISetEnvIf \"true\" PHP_ADMIN_VALUE \"open_basedir=${dir}/:/var/lib/phpmyadmin/:/tmp/:/proc/\""
        else
            obd="php_admin_value open_basedir \"${dir}/:/var/lib/phpmyadmin/:/tmp/:/proc/\""
        fi
        cat >"${apa}/phpmyadmin.enable.conf"<<EOF || return 1
Alias /${url} "${dir}"

<Directory "${dir}">
    Options SymLinksIfOwnerMatch
    AllowOverride None
    Require all granted
    ${obd}
</Directory>
EOF
        chmod 644 "${apa}/phpmyadmin.enable.conf" || return 1
        written=$((written + 1))
    fi
    if [ "${written}" -eq 0 ]; then
        Echo_Red "未找到 Nginx 或 Apache 的配置目录，phpMyAdmin 访问入口未写入。"
        return 1
    fi
    return 0
}

# _PhpMyAdmin_Hooks <栈> <备份目录>：旧安装的主配置缺少片段 include 时补入，改动前的文件备份到
# <备份目录>，备份文件名为 nginx 或 apache，另以 nginx.target 记录 Nginx 被改动的文件。
# Nginx 以 default_server 块中的 root 指令定位插入点，兼容修改过的网站目录。
_PhpMyAdmin_Hooks()
{
    local stack=$1 bak=$2 nginx_conf apache_conf tmp

    nginx_conf="$(_PhpMyAdmin_Nginx_Conf_Dir)/nginx.conf"
    if grep -q 'default_server' "$(_PhpMyAdmin_Nginx_Conf_Dir)/vhost/default.conf" 2>/dev/null; then
        nginx_conf="$(_PhpMyAdmin_Nginx_Conf_Dir)/vhost/default.conf"
    fi
    apache_conf="$(_PhpMyAdmin_Apache_Conf_Dir)/httpd.conf"

    if [ "${stack}" != lamp ] && [ -f "${nginx_conf}" ] \
       && ! grep -q 'include phpmyadmin\.\*\.conf;' "${nginx_conf}"; then
        \cp -p "${nginx_conf}" "${bak}/nginx" || return 1
        printf '%s\n' "${nginx_conf}" > "${bak}/nginx.target" || return 1
        tmp=$(mktemp "${nginx_conf}.XXXXXXXX") || return 1
        if ! awk '
            /^[[:space:]]*server[[:space:]]*\{/ { in_server=1; is_default=0 }
            in_server && /^[[:space:]]*listen[[:space:]].*default_server/ { is_default=1 }
            {
                print
                line=$0
                sub(/^[[:space:]]*/, "", line)
                sub(/[[:space:]]*;[[:space:]]*$/, "", line)
                if (is_default && line ~ /^root[[:space:]]/) {
                    print "        include phpmyadmin.*.conf;"
                    inserted=1
                    is_default=0
                }
            }
            END { if (!inserted) exit 1 }
        ' "${nginx_conf}" > "${tmp}"; then
            Echo_Red "未能在 Nginx 默认站点中定位 phpMyAdmin 配置入口。"
            Echo_Red "需要 ${nginx_conf} 里有一个带 default_server 的 server 块，且块内有 root 指令。"
            rm -f "${tmp}"
            return 1
        fi
        chmod --reference="${nginx_conf}" "${tmp}" 2>/dev/null || chmod 644 "${tmp}"
        mv -f "${tmp}" "${nginx_conf}" || { rm -f "${tmp}"; return 1; }
    fi

    if [ "${stack}" != lnmp ] && [ -f "${apache_conf}" ] \
       && ! grep -q 'IncludeOptional conf/extra/phpmyadmin\.\*\.conf' "${apache_conf}"; then
        \cp -p "${apache_conf}" "${bak}/apache" || return 1
        printf '\n# phpMyAdmin optional access mapping\nIncludeOptional conf/extra/phpmyadmin.*.conf\n' \
            >> "${apache_conf}" || return 1
    fi
    return 0
}

# _PhpMyAdmin_Unhook <备份目录>：恢复 _PhpMyAdmin_Hooks 改动前的主配置。
_PhpMyAdmin_Unhook()
{
    local bak=$1

    if [ -s "${bak}/nginx" ] && [ -s "${bak}/nginx.target" ]; then
        mv -f "${bak}/nginx" "$(cat "${bak}/nginx.target")"
    fi
    if [ -s "${bak}/apache" ]; then
        mv -f "${bak}/apache" "$(_PhpMyAdmin_Apache_Conf_Dir)/httpd.conf"
    fi
    return 0
}

PhpMyAdmin_Install()
{
    local ver=$1 stack=$2 port=$3 rc dir url stage var_absent=n

    PhpMyAdmin_Check "${ver}"
    rc=$?
    case "${rc}" in
    0) Echo_Green "phpMyAdmin ${ver} 已就绪，无需安装。"; return 0 ;;
    2) Echo_Red "已安装的 phpMyAdmin 版本与期望的 ${ver} 不符，未改动。更换版本请执行 ./upgrade.sh phpmyadmin。"; return 2 ;;
    3) Echo_Red "phpMyAdmin 安装参数错误：${ver}"; return 3 ;;
    esac
    case "${stack}" in lnmp|lnmpa|lamp) ;; *) Echo_Red "phpMyAdmin 安装参数错误：栈 ${stack}"; return 3 ;; esac
    case "${port}" in ''|*[!0-9]*) Echo_Red "phpMyAdmin 安装参数错误：数据库端口 ${port}"; return 3 ;; esac

    dir=$(_PhpMyAdmin_Dir)
    ( _PhpMyAdmin_Fetch "${ver}" ) || { Echo_Red "phpMyAdmin ${ver} 下载或校验失败。"; return 1; }
    # 随机访问路径减少针对固定 /phpmyadmin 的批量扫描，固定后缀便于在访问控制和日志中识别。
    url="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')_phpmyadmin"
    [ "${url}" != _phpmyadmin ] || return 1
    stage=$(mktemp -d "${cur_dir}/src/.pma-stage.XXXXXXXX") || return 1
    if ! _PhpMyAdmin_Stage "${ver}" "${port}" "${url}" "${stage}"; then
        _PhpMyAdmin_Cleanup "${stage}"
        return 1
    fi
    [ -e "$(_PhpMyAdmin_Var_Dir)" ] || var_absent=y
    # 不完整的旧目录不保留；网站根目录中的旧版副本一并清理，避免源码泄露。
    _PhpMyAdmin_Remove_Dir "${dir}"
    [ -n "${Default_Website_Dir}" ] && [ -d "${Default_Website_Dir}/phpmyadmin" ] \
        && rm -rf -- "${Default_Website_Dir}/phpmyadmin"
    mkdir -p "${stage}/hooks" || { _PhpMyAdmin_Cleanup "${stage}"; return 1; }
    if _PhpMyAdmin_Var && mv "${stage}/phpMyAdmin-${ver}-all-languages" "${dir}" \
       && _PhpMyAdmin_Hooks "${stack}" "${stage}/hooks" && _PhpMyAdmin_Access "${stack}" "${url}"; then
        _PhpMyAdmin_Cleanup "${stage}"
        return 0
    fi
    Echo_Red "部署 phpMyAdmin 失败，撤销本次写入。"
    _PhpMyAdmin_Unhook "${stage}/hooks"
    rm -f "$(_PhpMyAdmin_Nginx_Conf_Dir)/phpmyadmin.enable.conf" \
          "$(_PhpMyAdmin_Apache_Conf_Dir)/extra/phpmyadmin.enable.conf"
    _PhpMyAdmin_Remove_Dir "${dir}"
    [ "${var_absent}" = y ] && rm -rf -- "$(_PhpMyAdmin_Var_Dir)"
    _PhpMyAdmin_Cleanup "${stage}"
    return 1
}

# _PhpMyAdmin_HTTP_Port <栈>：读取现有 Web 服务的 HTTP 监听端口。
_PhpMyAdmin_HTTP_Port()
{
    local port=''

    if [ "$1" != lamp ]; then
        port=$("${LNMP_NGINX_PREFIX:-/usr/local/nginx}/sbin/nginx" -T 2>/dev/null | \
            awk '/^[[:space:]]*listen[[:space:]]+[0-9]+([[:space:];]|$)/ {
                value=$2; sub(/;.*/, "", value); print value; exit
            }')
    else
        # 读取 Apache 展开 include 后的公网虚拟主机地址。
        port=$("${LNMP_APACHE_PREFIX:-/usr/local/apache}/bin/httpd" -t -D DUMP_VHOSTS 2>/dev/null | \
            awk '/^[[:space:]]*\*:[0-9]+[[:space:]]/ {
                value=$1; sub(/^\*:/, "", value); print value; exit
            }')
    fi
    case "${port}" in
    ''|*[!0-9]*) Echo_Red "无法读取现有 Web 服务的 HTTP 监听端口。"; return 1 ;;
    esac
    printf '%s\n' "${port}"
}

PhpMyAdmin_Verify()
{
    local ver=$1 stack=$2 port url body attempt err last_err=''

    PhpMyAdmin_Check "${ver}" || return 1
    command -v curl >/dev/null 2>&1 || { Echo_Red "缺少 curl，无法验证 phpMyAdmin 页面。"; return 1; }
    port=$(_PhpMyAdmin_HTTP_Port "${stack}") || return 1
    url=$(cat "$(_PhpMyAdmin_Dir)/.access_url")
    body=$(mktemp) || return 1
    # Web 服务重载后短时间内可能仍返回旧结果；重试失败后仅显示最后一次错误。
    for attempt in 1 2 3 4 5; do
        if err=$(curl -fsS --max-time 15 "http://127.0.0.1:${port}/${url}/" -o "${body}" 2>&1) \
           && grep -qi 'phpMyAdmin' "${body}"; then
            rm -f "${body}"
            return 0
        fi
        [ -n "${err}" ] && last_err="${err}"
        [ "${attempt}" -lt 5 ] && sleep 1
    done
    rm -f "${body}"
    [ -n "${last_err}" ] && printf '%s\n' "${last_err}" >&2
    Echo_Red "phpMyAdmin 本机 HTTP 验证失败：http://127.0.0.1:${port}/${url}/"
    return 1
}

PhpMyAdmin_Remove()
{
    _PhpMyAdmin_Remove_Dir "$(_PhpMyAdmin_Dir)"
    rm -rf -- "$(_PhpMyAdmin_Var_Dir)"
    rm -f "$(_PhpMyAdmin_Nginx_Conf_Dir)/phpmyadmin.enable.conf" \
          "$(_PhpMyAdmin_Nginx_Conf_Dir)/.phpmyadmin.enable.conf.disabled" \
          "$(_PhpMyAdmin_Apache_Conf_Dir)/extra/phpmyadmin.enable.conf" \
          "$(_PhpMyAdmin_Apache_Conf_Dir)/extra/.phpmyadmin.enable.conf.disabled"
    return 0
}

PhpMyAdmin_Upgrade()
{
    local ver=$1 port=$2 dir bak url stage

    if ! _PhpMyAdmin_Ver_Ok "${ver}"; then
        Echo_Red "phpMyAdmin 升级参数错误：${ver}"
        return 1
    fi
    case "${port}" in ''|*[!0-9]*) Echo_Red "phpMyAdmin 升级参数错误：数据库端口 ${port}"; return 1 ;; esac
    dir=$(_PhpMyAdmin_Dir)
    bak="${dir}.bak.$(date +%Y%m%d%H%M%S)"
    # 沿用原随机访问路径，现有 Web 映射与 lnmp status 继续可用。
    url=$(cat "${dir}/.access_url" 2>/dev/null)
    if [ ! -s "${dir}/index.php" ] || [ -z "${url}" ]; then
        Echo_Red "${dir} 下没有完整的 phpMyAdmin（缺 index.php 或 .access_url），请先执行 ./install.sh phpmyadmin。"
        return 1
    fi
    ( _PhpMyAdmin_Fetch "${ver}" ) || { Echo_Red "phpMyAdmin ${ver} 下载或校验失败，线上未改动。"; return 1; }
    stage=$(mktemp -d "${cur_dir}/src/.pma-stage.XXXXXXXX") || return 1
    if ! _PhpMyAdmin_Stage "${ver}" "${port}" "${url}" "${stage}" || ! _PhpMyAdmin_Var; then
        Echo_Red "线上 phpMyAdmin 未做任何改动。"
        _PhpMyAdmin_Cleanup "${stage}"
        return 1
    fi
    echo "正在把旧 phpMyAdmin 备份到 ${bak}..."
    if ! mv "${dir}" "${bak}"; then
        Echo_Red "备份原 phpMyAdmin 目录失败，放弃升级（线上未改动）。"
        _PhpMyAdmin_Cleanup "${stage}"
        return 1
    fi
    if ! mv "${stage}/phpMyAdmin-${ver}-all-languages" "${dir}"; then
        Echo_Red "部署新 phpMyAdmin 失败，正在恢复原目录..."
        _PhpMyAdmin_Cleanup "${stage}"
        _PhpMyAdmin_Remove_Dir "${dir}"
        mv "${bak}" "${dir}" || { Echo_Red "恢复失败，原目录在 ${bak}。"; return 2; }
        return 1
    fi
    _PhpMyAdmin_Cleanup "${stage}"
    Echo_Green "======== phpMyAdmin 升级完成 ======"
    Echo_Green "原目录保留在 ${bak}，确认无误后可自行删除。"
    return 0
}
