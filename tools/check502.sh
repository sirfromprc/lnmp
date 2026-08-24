#!/usr/bin/env bash
# 已废弃，保留仅为兼容存量 crontab。请改用 lnmp health。
#
# 本脚本无失败阈值、无熔断，且直接调用 /etc/init.d/php-fpm 绕过 systemd，
# 与 unit 的 Restart= 及 lnmp health 的重启逻辑冲突，会形成多个重启者。
# lnmp health 已覆盖同类场景，并带连续失败阈值与熔断。
#
# 配合 crontab 定时检查站点，返回 502 时重启 PHP-FPM 以恢复请求处理。
# 目标地址必须由使用者给出：改写下面的 CheckURL，或用环境变量传入。

CheckURL="${CheckURL:-}"

if [ -z "${CheckURL}" ]; then
    echo "未设置 CheckURL，本脚本不执行。请改用 lnmp health status。" >&2
    exit 1
fi

STATUS_CODE=$(curl -o /dev/null -m 10 --connect-timeout 10 -s -w '%{http_code}' "${CheckURL}")
if [ "${STATUS_CODE}" = "502" ]; then
    /etc/init.d/php-fpm restart
fi
