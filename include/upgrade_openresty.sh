#!/usr/bin/env bash
# 根据现有 OpenResty 的安装方式自动选择升级路径：
#   包安装的   → 走包管理器升级（apt-get install --only-upgrade / dnf update）
#               使用 --force-confold 保留当前站点配置。
#   源码装的   → 下载新版源码、验签、重新编译安装到同一前缀。
#               保留现有 conf 和虚拟主机配置。
# 判定依据：包管理器里有没有 openresty 这个包。

# 返回 OpenResty 安装类型：pkg、source 或 none。
OpenResty_Installed_By()
{
    if [ ! -d /usr/local/openresty ]; then
        echo 'none'; return
    fi
    if [ "${PM}" = "apt" ] && dpkg -l openresty 2>/dev/null | grep -q '^ii'; then
        echo 'pkg'; return
    fi
    if [ "${PM}" = "yum" ] && rpm -q openresty >/dev/null 2>&1; then
        echo 'pkg'; return
    fi
    echo 'source'
}

Upgrade_OpenResty()
{
    local mode cur_ver new_ver

    mode=$(OpenResty_Installed_By)
    if [ "${mode}" = "none" ]; then
        Echo_Red "未检测到 OpenResty（/usr/local/openresty 不存在）。"
        Echo_Red "若你装的是 nginx 官方版，请用：./upgrade.sh nginx"
        return 1
    fi

    cur_ver=$(/usr/local/openresty/nginx/sbin/nginx -v 2>&1 | sed 's/.*openresty\///;s/ .*//')
    echo "当前 OpenResty 版本：${cur_ver:-未知}（安装方式：${mode}）"

    if [ "${mode}" = "pkg" ]; then
        Upgrade_OpenResty_Pkg || return 1
    else
        Upgrade_OpenResty_Source || return 1
    fi

    new_ver=$(/usr/local/openresty/nginx/sbin/nginx -v 2>&1 | sed 's/.*openresty\///;s/ .*//')
    echo "升级后版本：${new_ver:-未知}"

    # 早期版本只给 LNMPA 装 proxy.conf，其它栈的自定义反代站点 include 它会让
    # nginx -t 失败。补齐缺失的包含文件，已存在的保留站点自己的修改。
    Check_Stack
    if [ "${Get_Stack:-}" = 'lnmpa' ]; then
        Write_Nginx_Proxy_Conf /usr/local/openresty/nginx/conf y y ||
            Echo_Red "补齐反代包含文件失败，可手工 cp conf/proxy.conf 到 /usr/local/openresty/nginx/conf/。"
    else
        Write_Nginx_Proxy_Conf /usr/local/openresty/nginx/conf n y ||
            Echo_Red "补齐反代包含文件失败，可手工 cp conf/proxy.conf 到 /usr/local/openresty/nginx/conf/。"
    fi

    if ! /usr/local/nginx/sbin/nginx -t; then
        Echo_Red "升级后配置检查未通过 —— 服务**没有**重载，站点仍在用旧进程。"
        Echo_Red "请先修正配置，再执行：/etc/init.d/nginx restart"
        return 1
    fi

    /etc/init.d/nginx restart
    Echo_Green "OpenResty 升级完成：${cur_ver:-未知} -> ${new_ver:-未知}"
    return 0
}

# 通过系统包管理器升级 OpenResty。
Upgrade_OpenResty_Pkg()
{
    if [ "${PM}" = "apt" ]; then
        Apt_Get update -y

        if ! DEBIAN_FRONTEND=noninteractive Apt_Get -y \
             -o Dpkg::Options::="--force-confold" \
             install --only-upgrade openresty; then
            Echo_Red "apt 升级 openresty 失败。"
            return 1
        fi
    elif [ "${PM}" = "yum" ]; then
        if ! ${PM} update -y openresty; then
            Echo_Red "${PM} 升级 openresty 失败。"
            return 1
        fi
    else
        Echo_Red "未知的包管理器（PM=${PM}），无法升级。"
        return 1
    fi
    return 0
}

# 通过官方源码升级 OpenResty。
Upgrade_OpenResty_Source()
{
    local ver tarball url

    ver=""
    echo "可用版本见 https://openresty.org/en/download.html"
    Echo_Yellow "请输入要升级到的 OpenResty 版本号（例如 ${OpenResty_Ver#openresty-}）："
    read -r ver
    if [ -z "${ver}" ]; then
        Echo_Red "必须输入版本号。"
        return 1
    fi
    Check_Version_String "${ver}" "OpenResty 版本号" || return 1

    tarball="openresty-${ver}.tar.gz"
    url="https://openresty.org/download/${tarball}"

    cd "${cur_dir}/src" || return 1
    if [ ! -s "${tarball}" ]; then
        if ! Download_Fetch "${url}" "${cur_dir}/src/${tarball}"; then
            Echo_Red "下载失败：${url}"
            Echo_Red "请确认该版本号存在。"
            return 1
        fi
    fi

    if ! Verify_OpenResty_Signature "${cur_dir}/src/${tarball}" "${url}"; then
        Echo_Red "验签未通过，中止升级。**现有 OpenResty 未做任何改动。**"
        rm -f "${cur_dir}/src/${tarball}"
        return 1
    fi

    # 升级前备份现有配置目录，供安装异常时恢复。
    local bak="/usr/local/openresty/nginx/conf.bak.${Upgrade_Date}"
    cp -a /usr/local/openresty/nginx/conf "${bak}" && \
        echo "已备份配置到 ${bak}"

    # 沿用安装时的模块配置，避免升级后缺少现有功能。
    if ! OR_Modules_Load_Persisted; then
        Echo_Red "读取已记录的模块配置失败，升级中止。"
        return 1
    fi
    if ! OR_Modules_Prepare; then
        Echo_Red "自定义模块准备失败，升级中止。现有安装未被替换。"
        return 1
    fi

    Tar_Cd "${tarball}" "openresty-${ver}"
    ./configure -j"$(nproc 2>/dev/null || echo 2)" \
        --prefix=/usr/local/openresty \
        --with-pcre-jit \
        --with-ipv6 \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_realip_module \
        --with-http_stub_status_module \
        --with-http_gzip_static_module \
        ${OpenResty_Modules_Options} \
        ${OR_Modules_Add_Options}
    if ! Check_Makefile_Ready; then
        Echo_Red "configure 失败，升级中止。现有安装未被替换。"
        return 1
    fi
    if ! make -j"$(Build_Jobs)"; then
        Echo_Red "编译失败，升级中止。现有安装未被替换。"
        return 1
    fi
    if ! OR_Modules_Capture_Built; then
        Echo_Red "无法记录本次动态模块产物，升级中止。"
        return 1
    fi
    if ! make install; then
        Echo_Red "make install 失败 —— 安装可能处于半完成状态。"
        Echo_Red "配置备份在 ${bak}"
        return 1
    fi

    cd "${cur_dir}/src/" || return 1
    rm -rf "${cur_dir}/src/openresty-${ver}"

    # 重写新版本动态模块的加载清单，并在配置检查前确保引用文件存在。
    if ! OR_Modules_Post_Build; then
        Echo_Red "生成模块与 Lua 路径配置失败。"
        return 1
    fi
    if ! OR_Modules_Persist; then
        Echo_Red "OpenResty 已升级，但编译期配置持久化失败。"
        return 1
    fi
    return 0
}
