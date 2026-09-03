#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# 修改站点限制配置并重启服务需要 root 权限。
if [ "$(id -u)" != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi

cur_dir=$(cd "$(dirname "$0")/.." && pwd)
# 校验源码目录，避免在其他位置执行时因公共函数未加载而继续修改配置。
if [ ! -f "${cur_dir}/include/main.sh" ]; then
    echo "错误：找不到 ${cur_dir}/include/main.sh。"
    echo "请在 LNMP 源码目录内执行本脚本，例如 ./tools/$(basename "$0")。"
    exit 1
fi
. "${cur_dir}/include/main.sh"

Nginx_Conf_Dir="/usr/local/nginx/conf"
Vhost_Dir="${Nginx_Conf_Dir}/vhost"

Print_Banner \
    "LNMP open_basedir 调整工具" \
    "解除指定网站的目录访问限制" \
    "用法：./remove_open_basedir_restriction.sh"

if [ ! -s "${Nginx_Conf_Dir}/fastcgi.conf" ] || [ ! -d "${Vhost_Dir}" ]; then
    Echo_Red "找不到 ${Nginx_Conf_Dir}/fastcgi.conf 或 ${Vhost_Dir}，本工具只适用于 Nginx + PHP-FPM。"
    Echo_Yellow "LAMP、LNMPA 的边界由 Apache 的 php_admin_value open_basedir 控制，"
    echo
    Echo_Yellow "请直接编辑该站点的 Apache 配置。"
    exit 1
fi

# 按 root 指令定位使用该目录的站点配置。同一目录可能被多个站点引用。
Find_Site_Confs()
{
    local dir="$1" f root

    for f in "${Vhost_Dir}"/*.conf; do
        [ -s "${f}" ] || continue
        root=$(awk '$1 == "root" { v=$2; sub(/;$/, "", v); print v; exit }' "${f}")
        [ "${root}" = "${dir}" ] && printf '%s\n' "${f}"
    done
}

# 生成不带 PHP_ADMIN_VALUE 的 FastCGI 参数文件。
# 全局 fastcgi.conf 保持不变，其它站点的兜底不受影响。
Ensure_Nobasedir_Fastcgi()
{
    local src="${Nginx_Conf_Dir}/fastcgi.conf"
    local dst="${Nginx_Conf_Dir}/fastcgi-nobasedir.conf"

    if ! sed '/^[[:space:]]*fastcgi_param[[:space:]]\+PHP_ADMIN_VALUE/d' "${src}" >"${dst}"; then
        Echo_Red "生成 ${dst} 失败。"
        return 1
    fi
    chmod 644 "${dst}"
    return 0
}

# 为站点当前使用的 enable-php 片段生成对应的免限制版本，输出新文件名。
Ensure_Nobasedir_Enable_Php()
{
    local name="$1" base dst

    base="${name%.conf}"
    dst="${Nginx_Conf_Dir}/${base}-nobasedir.conf"
    if [ ! -s "${Nginx_Conf_Dir}/${name}" ]; then
        Echo_Red "找不到 ${Nginx_Conf_Dir}/${name}。" >&2
        return 1
    fi
    if ! sed 's#include[[:space:]]\+fastcgi\.conf;#include fastcgi-nobasedir.conf;#' \
         "${Nginx_Conf_Dir}/${name}" >"${dst}"; then
        Echo_Red "生成 ${dst} 失败。" >&2
        return 1
    fi
    chmod 644 "${dst}"
    printf '%s' "${base}-nobasedir.conf"
    return 0
}

website_root=''
while :;do
    Echo_Yellow "请输入网站根目录: "
    if ! read -r website_root; then
        echo
        Echo_Red "读取网站根目录时遇到 EOF，未做任何修改。"
        exit 1
    fi
    if [ -z "${website_root}" ]; then
        Echo_Red "目录不能为空。"
        continue
    fi
    if [ ! -d "${website_root}" ]; then
        Echo_Red "${website_root} 不是目录或不存在。"
        continue
    fi
    # 去掉结尾斜杠，与 vhost 里的 root 写法保持一致。
    website_root="${website_root%/}"
    break
done

site_confs=$(Find_Site_Confs "${website_root}")
if [ -z "${site_confs}" ]; then
    Echo_Red "${Vhost_Dir} 下没有 root 指向 ${website_root} 的站点配置。"
    Echo_Yellow "请确认目录填写正确，或先用 lnmp vhost add 建立站点。"
    exit 1
fi

echo "将解除以下站点的 open_basedir 限制："
printf '%s\n' "${site_confs}" | sed 's/^/  /'
echo "全局 ${Nginx_Conf_Dir}/fastcgi.conf 不会改动，其它站点的兜底保持有效。"
Echo_Yellow "确认继续? (y/N，默认 n) "
if ! read -r answer || { [ "${answer}" != "y" ] && [ "${answer}" != "Y" ]; }; then
    echo "已取消，未做任何修改。"
    exit 1
fi

Ensure_Nobasedir_Fastcgi || exit 1

backup_dir=$(mktemp -d /tmp/lnmp-nobasedir.XXXXXXXX) || exit 1
changed=''
rc=0
while IFS= read -r conf; do
    [ -n "${conf}" ] || continue
    \cp -p "${conf}" "${backup_dir}/$(basename "${conf}")" || { rc=1; break; }
    changed="${changed:+${changed} }${conf}"
    # 站点可能使用主 PHP、附加版本或 pathinfo 变体，按它实际 include 的片段处理。
    while read -r inc; do
        [ -n "${inc}" ] || continue
        new_inc=$(Ensure_Nobasedir_Enable_Php "${inc}") || { rc=1; break; }
        # 文件名里的点在正则中要转义，否则会匹配到相邻的其它片段名。
        inc_re="${inc//./\\.}"
        sed -i "s#include[[:space:]]\+${inc_re};#include ${new_inc};#" "${conf}" || { rc=1; break; }
        echo "${conf}: include ${inc} -> ${new_inc}"
    done <<EOF
$(grep -o 'enable-php[A-Za-z0-9.-]*\.conf' "${conf}" | grep -v -- '-nobasedir' | sort -u)
EOF
    [ ${rc} -eq 0 ] || break
done <<EOF
${site_confs}
EOF

Restore_Confs()
{
    local f
    for f in ${changed}; do
        \cp -p "${backup_dir}/$(basename "${f}")" "${f}"
    done
}

if [ ${rc} -ne 0 ]; then
    Echo_Red "修改站点配置失败，已回滚。"
    Restore_Confs
    rm -rf "${backup_dir}"
    exit 1
fi

echo "正在检查 Nginx 配置..."
if ! /usr/local/nginx/sbin/nginx -t; then
    Echo_Red "Nginx 配置测试未通过，已回滚站点配置。"
    Restore_Confs
    rm -rf "${backup_dir}"
    exit 1
fi

# 站点级 .user.ini 与 FastCGI 兜底同时解除，限制才真正消失。
if [ -f "${website_root}/.user.ini" ]; then
    chattr -i "${website_root}/.user.ini" 2>/dev/null
    if ! rm -f "${website_root}/.user.ini"; then
        Echo_Red "删除 ${website_root}/.user.ini 失败，已回滚站点配置。"
        Restore_Confs
        rm -rf "${backup_dir}"
        exit 1
    fi
    echo "已删除 ${website_root}/.user.ini"
else
    echo "${website_root}/.user.ini 不存在，跳过。"
fi

# 统一走 StartOrStop，装了 systemd unit 时用 systemctl，保持进程与 unit 状态一致。
if ! StartOrStop reload php-fpm; then
    Echo_Red "PHP-FPM 重载失败，请手工执行 lnmp php-fpm reload 后确认。"
    rc=1
fi
if ! StartOrStop reload nginx; then
    Echo_Red "Nginx 重载失败，请手工执行 lnmp nginx reload 后确认。"
    rc=1
fi

rm -rf "${backup_dir}"
if [ ${rc} -ne 0 ]; then
    exit 1
fi
Print_Banner "已解除 ${website_root} 的 open_basedir 限制"
echo "恢复方式：把站点配置里的 enable-php*-nobasedir.conf 改回原文件名，"
echo "重新写入 .user.ini 后执行 lnmp nginx reload。"
exit 0
