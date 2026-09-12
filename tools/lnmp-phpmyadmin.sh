#!/usr/bin/env bash

stack="$1"
action="$2"
pma_dir='/usr/local/phpmyadmin'
pma_url_file="${pma_dir}/.access_url"
nginx_live='/usr/local/nginx/conf/phpmyadmin.enable.conf'
nginx_saved='/usr/local/nginx/conf/.phpmyadmin.enable.conf.disabled'
apache_live='/usr/local/apache/conf/extra/phpmyadmin.enable.conf'
apache_saved='/usr/local/apache/conf/extra/.phpmyadmin.enable.conf.disabled'

web_test()
{
    case "${stack}" in
    lnmp) /usr/local/nginx/sbin/nginx -t ;;
    lnmpa) /usr/local/nginx/sbin/nginx -t && /usr/local/apache/bin/httpd -t ;;
    lamp) /usr/local/apache/bin/httpd -t ;;
    *) echo "无法识别已安装的架构：${stack}" >&2; return 1 ;;
    esac
}

web_reload()
{
    case "${stack}" in
    lnmp) reload_service nginx ;;
    lnmpa) reload_service nginx && reload_service httpd ;;
    lamp) reload_service httpd ;;
    esac
}

reload_service()
{
    local name="$1"
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 &&
       [ -s "/etc/systemd/system/${name}.service" ]; then
        systemctl reload "${name}.service"
    else
        "/etc/init.d/${name}" reload
    fi
}

# 探测本机对外 IPv4，取默认路由的源地址；取不到返回 1。
# 不查询外部服务，避免 status 因网络阻塞。
detect_ip()
{
    local addr

    addr=$(ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -n "${addr}" ] || return 1
    printf '%s' "${addr}"
}

# 私有、保留、空值或非 IPv4 地址返回 0。
is_private_ip()
{
    case "$1" in
        10.*|127.*|169.254.*|192.168.*)          return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*)   return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
        ''|*[!0-9.]*)                            return 0 ;;
    esac
    return 1
}

# default 兜底站点已配置 HTTPS 时返回 0。phpMyAdmin 挂在该站点下，
# nginx 的 443 default 块含 include phpmyadmin.*.conf，Apache 的 Alias
# 为服务器级配置，两者在 443 上都能访问。
# 同一文件里可能有其它站点的 443 配置，因此只认 default 自身的标记：
# nginx 是 default_server，Apache 是 443 块内的 ServerName _。
default_has_https()
{
    case "${stack}" in
    lnmp|lnmpa)
        grep -Eq '^[[:space:]]*listen[[:space:]][^;]*443[^;]*ssl[^;]*default_server' \
            /usr/local/nginx/conf/vhost/default.conf 2>/dev/null
        ;;
    lamp)
        awk '
            /^[[:space:]]*<VirtualHost[[:space:]]+\*:443>/ { inblock=1; next }
            inblock && /^[[:space:]]*<\/VirtualHost>/      { inblock=0; next }
            inblock && $1 == "ServerName" && $2 == "_"     { found=1 }
            END { exit !found }
        ' /usr/local/apache/conf/extra/httpd-vhosts.conf 2>/dev/null
        ;;
    *)
        return 1
        ;;
    esac
}

show_status()
{
    local enabled='y' scheme='http' detected='y' addr

    case "${stack}" in
    lnmp) [ -s "${nginx_live}" ] || enabled='n' ;;
    lnmpa) [ -s "${nginx_live}" ] && [ -s "${apache_live}" ] || enabled='n' ;;
    lamp) [ -s "${apache_live}" ] || enabled='n' ;;
    esac
    if [ "${enabled}" != 'y' ]; then
        echo "phpMyAdmin 访问已禁用；程序和配置仍保留。"
        return 0
    fi

    addr=$(detect_ip) || { detected='n'; printf -v addr '<服务器IP>'; }
    default_has_https && scheme='https'
    echo "phpMyAdmin 访问已启用：${scheme}://${addr}/$(cat "${pma_url_file}")/"

    if [ "${detected}" != 'y' ]; then
        echo "未探测到服务器 IP，请把 <服务器IP> 换成实际地址。"
        return 0
    fi
    [ "${scheme}" = 'http' ] || return 0
    if is_private_ip "${addr}"; then
        echo "这是内网地址；从公网访问请换成服务器的公网 IP。"
    else
        echo "建议改用 HTTPS：执行 lnmp ssl add，域名填 default，可为该公网 IP 申请证书。"
    fi
    return 0
}

if [ "$(id -u)" != '0' ]; then
    echo '错误：必须使用 root 用户运行。' >&2
    exit 1
fi
# 架构名决定读哪套 Web 配置，取值不对时后续判定会全部落空，先拦掉。
case "${stack}" in
lnmp|lnmpa|lamp) ;;
*)
    echo "无法识别已安装的架构：${stack}" >&2
    exit 1
    ;;
esac
if [ ! -s "${pma_dir}/index.php" ] || [ ! -s "${pma_url_file}" ]; then
    echo 'phpMyAdmin 尚未安装。' >&2
    exit 1
fi

nginx_moved='n'
apache_moved='n'
case "${action}" in
status)
    show_status
    exit $?
    ;;
disable)
    if { [ -e "${nginx_live}" ] && [ -e "${nginx_saved}" ]; } ||
       { [ -e "${apache_live}" ] && [ -e "${apache_saved}" ]; }; then
        echo '启用和禁用状态的访问配置同时存在，请手动检查。' >&2
        exit 1
    fi
    if [ "${stack}" = 'lnmp' ] || [ "${stack}" = 'lnmpa' ]; then
        [ ! -e "${nginx_live}" ] || {
            mv "${nginx_live}" "${nginx_saved}" || exit 1; nginx_moved='y'; }
    fi
    if [ "${stack}" = 'lamp' ] || [ "${stack}" = 'lnmpa' ]; then
        if [ -e "${apache_live}" ]; then
            if ! mv "${apache_live}" "${apache_saved}"; then
                [ "${nginx_moved}" = 'y' ] && mv "${nginx_saved}" "${nginx_live}"
                exit 1
            fi
            apache_moved='y'
        fi
    fi
    ;;
enable)
    if { [ -e "${nginx_live}" ] && [ -e "${nginx_saved}" ]; } ||
       { [ -e "${apache_live}" ] && [ -e "${apache_saved}" ]; }; then
        echo '启用和禁用状态的访问配置同时存在，请手动检查。' >&2
        exit 1
    fi
    if [ "${stack}" = 'lnmp' ] || [ "${stack}" = 'lnmpa' ]; then
        [ -e "${nginx_live}" ] || {
            [ -s "${nginx_saved}" ] || { echo '未找到已禁用的 Nginx 访问配置。' >&2; exit 1; }
            mv "${nginx_saved}" "${nginx_live}" || exit 1; nginx_moved='y'; }
    fi
    if [ "${stack}" = 'lamp' ] || [ "${stack}" = 'lnmpa' ]; then
        if [ ! -e "${apache_live}" ]; then
            if [ ! -s "${apache_saved}" ] || ! mv "${apache_saved}" "${apache_live}"; then
                [ "${nginx_moved}" = 'y' ] && mv "${nginx_live}" "${nginx_saved}"
                echo '未找到已禁用的 Apache 访问配置，或配置无法恢复。' >&2
                exit 1
            fi
            apache_moved='y'
        fi
    fi
    ;;
*)
    echo '用法：lnmp phpmyadmin {enable|disable|status}' >&2
    exit 1
    ;;
esac

if [ "${nginx_moved}" = 'n' ] && [ "${apache_moved}" = 'n' ]; then
    show_status
    exit 0
fi

if ! web_test || ! web_reload; then
    if [ "${action}" = 'disable' ]; then
        [ "${nginx_moved}" = 'y' ] && mv "${nginx_saved}" "${nginx_live}"
        [ "${apache_moved}" = 'y' ] && mv "${apache_saved}" "${apache_live}"
    else
        [ "${nginx_moved}" = 'y' ] && mv "${nginx_live}" "${nginx_saved}"
        [ "${apache_moved}" = 'y' ] && mv "${apache_live}" "${apache_saved}"
    fi
    web_test >/dev/null 2>&1 && web_reload >/dev/null 2>&1 || true
    echo '网站配置测试或重载失败，已恢复之前的访问状态。' >&2
    exit 1
fi

show_status
