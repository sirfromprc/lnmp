#!/usr/bin/env bash
# Nginx 升级入口：输入目标版本并确认，构建、换入与回滚由 include/mod/nginx.sh 的 Nginx_Upgrade 完成。

Upgrade_Nginx()
{
    local ver='' cur

    cur=$(/usr/local/nginx/sbin/nginx -v 2>&1 | sed -n 's#^nginx version: nginx/##p')
    echo "当前 Nginx 版本：${cur:-未知}"
    echo "可在 https://nginx.org/en/download.html 查看可用版本号。"
    read -r -p "请输入目标 Nginx 版本（例如 ${Nginx_Ver#nginx-}）：" ver
    if [ -z "${ver}" ]; then
        Echo_Red "错误：必须输入 Nginx 版本号！"
        return 1
    fi
    Check_Version_String "${ver}" "Nginx 版本号" || return 1
    Print_Banner "即将把 Nginx 升级到 ${ver}"
    Press_Start || return 1
    Nginx_Upgrade "${ver}"
}
