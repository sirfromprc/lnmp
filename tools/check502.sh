#!/usr/bin/env bash
# 配合 crontab 定时检查站点，返回 502 时重启 PHP-FPM 以恢复请求处理。

CheckURL="http://www.xxx.com"

STATUS_CODE=`curl -o /dev/null -m 10 --connect-timeout 10 -s -w %{http_code} $CheckURL`
#echo "$CheckURL Status Code:\t$STATUS_CODE"
if [ "$STATUS_CODE" = "502" ]; then
    /etc/init.d/php-fpm restart
fi
