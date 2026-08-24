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

Print_Banner \
    "LNMP open_basedir 调整工具" \
    "删除指定网站的目录访问限制" \
    "用法：./remove_open_basedir_restriction.sh"

website_root=''

while :;do
    read -p "请输入网站根目录: " website_root
    if [ -d "${website_root}" ]; then
        if [ -f ${website_root}/.user.ini ];then
            chattr -i ${website_root}/.user.ini
            rm -f ${website_root}/.user.ini
            sed -i 's/^fastcgi_param PHP_ADMIN_VALUE/#fastcgi_param PHP_ADMIN_VALUE/g' /usr/local/nginx/conf/fastcgi.conf
            /etc/init.d/php-fpm restart
            /etc/init.d/nginx reload
            echo "处理完成。"
        else
            echo "${website_root}/.user.ini 不存在。"
        fi
        break
    else
        echo "${website_root} 不是目录或不存在。"
    fi
done
