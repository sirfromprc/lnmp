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
    *) echo "Unknown installed stack: ${stack}" >&2; return 1 ;;
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

show_status()
{
    local enabled='y'
    case "${stack}" in
    lnmp) [ -s "${nginx_live}" ] || enabled='n' ;;
    lnmpa) [ -s "${nginx_live}" ] && [ -s "${apache_live}" ] || enabled='n' ;;
    lamp) [ -s "${apache_live}" ] || enabled='n' ;;
    esac
    if [ "${enabled}" = 'y' ]; then
        echo "phpMyAdmin access is enabled: http://<server-ip>/$(cat "${pma_url_file}")/"
    else
        echo "phpMyAdmin access is disabled; program and configuration are retained."
    fi
}

if [ "$(id -u)" != '0' ]; then
    echo 'Error: root is required.' >&2
    exit 1
fi
if [ ! -s "${pma_dir}/index.php" ] || [ ! -s "${pma_url_file}" ]; then
    echo 'phpMyAdmin is not installed.' >&2
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
        echo 'Both enabled and disabled access files exist; inspect them manually.' >&2
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
        echo 'Both enabled and disabled access files exist; inspect them manually.' >&2
        exit 1
    fi
    if [ "${stack}" = 'lnmp' ] || [ "${stack}" = 'lnmpa' ]; then
        [ -e "${nginx_live}" ] || {
            [ -s "${nginx_saved}" ] || { echo 'Disabled Nginx access file not found.' >&2; exit 1; }
            mv "${nginx_saved}" "${nginx_live}" || exit 1; nginx_moved='y'; }
    fi
    if [ "${stack}" = 'lamp' ] || [ "${stack}" = 'lnmpa' ]; then
        if [ ! -e "${apache_live}" ]; then
            if [ ! -s "${apache_saved}" ] || ! mv "${apache_saved}" "${apache_live}"; then
                [ "${nginx_moved}" = 'y' ] && mv "${nginx_live}" "${nginx_saved}"
                echo 'Disabled Apache access file not found or cannot be restored.' >&2
                exit 1
            fi
            apache_moved='y'
        fi
    fi
    ;;
*)
    echo 'Usage: lnmp phpmyadmin {enable|disable|status}' >&2
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
    echo 'Web configuration test or reload failed; previous access state was restored.' >&2
    exit 1
fi

show_status
