#!/usr/bin/env bash
# OpenResty 升级入口：按现有安装方式选择升级路径并确认，升级由 include/mod/openresty.sh 的 OpenResty_Upgrade 完成。
#   包安装的 → 包管理器升级，保留当前站点配置；
#   源码装的 → 输入目标版本，下载验签后按记录的模块配置重新编译。

Upgrade_OpenResty()
{
    local mode ver='' cur

    mode=$(OpenResty_Mode)
    if [ "${mode}" = none ]; then
        Echo_Red "未检测到 OpenResty（/usr/local/openresty 不存在）。"
        Echo_Red "若你装的是 nginx 官方版，请用：./upgrade.sh nginx"
        return 1
    fi
    cur=$(/usr/local/openresty/nginx/sbin/nginx -v 2>&1 | sed 's/.*openresty\///;s/ .*//')
    echo "当前 OpenResty 版本：${cur:-未知}（安装方式：${mode}）"

    if [ "${mode}" = pkg ]; then
        Print_Banner "即将通过 ${PM} 升级 openresty 软件包并重启 nginx"
    else
        echo "可用版本见 https://openresty.org/en/download.html"
        Echo_Yellow "请输入要升级到的 OpenResty 版本号（例如 ${OpenResty_Ver#openresty-}）："
        read -r ver
        if [ -z "${ver}" ]; then
            Echo_Red "必须输入版本号。"
            return 1
        fi
        Check_Version_String "${ver}" "OpenResty 版本号" || return 1
        Print_Banner "即将把 OpenResty 升级到 ${ver}"
    fi
    Press_Start || return 1
    OpenResty_Upgrade "${mode}" "${ver}"
}
