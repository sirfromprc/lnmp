#!/usr/bin/env bash
#
# upgrade_openresty.sh — 升级 OpenResty
#
# 升级方式取决于当初是怎么装的，自动判定，不问用户：
#
#   包安装的   → 走包管理器升级（apt-get install --only-upgrade / dnf update）
#               配置文件由包管理器按 conffile 规则处理，本包铺的
#               nginx.conf 属于"被本地修改过的配置"，apt 会询问或保留，
#               这里统一用 --force-confold 保留本地版本（站点配置不能被覆盖）。
#
#   源码装的   → 下载新版源码、验签、重新编译安装到同一前缀。
#               conf/ 目录不动（OpenResty 的 make install 不覆盖已存在的
#               nginx.conf），vhost 配置自然保留。
#
# 判定依据：包管理器里有没有 openresty 这个包。

# ---------------------------------------------------------------------------
# OpenResty_Installed_By — 返回 pkg / source / none
# ---------------------------------------------------------------------------
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

    if ! /usr/local/nginx/sbin/nginx -t; then
        Echo_Red "升级后配置检查未通过 —— 服务**没有**重载，站点仍在用旧进程。"
        Echo_Red "请先修正配置，再执行：/etc/init.d/nginx restart"
        return 1
    fi

    /etc/init.d/nginx restart
    Echo_Green "OpenResty 升级完成：${cur_ver:-未知} -> ${new_ver:-未知}"
    return 0
}

# ---------------------------------------------------------------------------
# Upgrade_OpenResty_Pkg — 包方式升级
# ---------------------------------------------------------------------------
Upgrade_OpenResty_Pkg()
{
    if [ "${PM}" = "apt" ]; then
        apt-get update -y

        if ! DEBIAN_FRONTEND=noninteractive apt-get -y \
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

# ---------------------------------------------------------------------------
# Upgrade_OpenResty_Source — 源码方式升级
# ---------------------------------------------------------------------------
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
    case "${ver}" in
        *[!0-9.]*) Echo_Red "版本号只允许数字和点：'${ver}'"; return 1 ;;
    esac

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

    # 备份现有配置目录。make install 通常不会覆盖已有 conf，
    # 但升级是不可逆操作，先留一份再说。
    local bak="/usr/local/openresty/nginx/conf.bak.${Upgrade_Date}"
    cp -a /usr/local/openresty/nginx/conf "${bak}" && \
        echo "已备份配置到 ${bak}"

    # 初装时配的模块要一并带过来，否则升级会编译出一个不含模块的版本
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
    if ! make -j"$(nproc 2>/dev/null || echo 2)"; then
        Echo_Red "编译失败，升级中止。现有安装未被替换。"
        return 1
    fi
    if ! make install; then
        Echo_Red "make install 失败 —— 安装可能处于半完成状态。"
        Echo_Red "配置备份在 ${bak}"
        return 1
    fi

    cd "${cur_dir}/src/"
    rm -rf "${cur_dir}/src/openresty-${ver}"

    # 动态模块的 .so 换了新版本，load_module 列表要重写；
    # 这一步在 nginx -t 之前完成，否则重载会因缺文件失败。
    if ! OR_Modules_Post_Build; then
        Echo_Red "生成模块与 Lua 路径配置失败。"
        return 1
    fi
    OR_Modules_Persist
    return 0
}
