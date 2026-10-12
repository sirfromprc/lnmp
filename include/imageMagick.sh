#!/usr/bin/env bash

# 编译 ImageMagick 库并安装到 /usr/local/imagemagick，供交互安装和 PHP
# 默认扩展安装共用。此函数不处理用户交互或 PHP 扩展配置。
Build_ImageMagick_Lib()
{
    if [ "$PM" = "yum" ]; then
        if [ "${DISTRO}" = "Oracle" ]; then
            yum -y install oracle-epel-release
        else
            yum -y install epel-release
        fi
        Get_Dist_Version
        yum install -y libwebp-devel
    elif [ "$PM" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        Apt_Get update
        Apt_Get install -y libwebp-dev
    fi
    ldconfig

    cd "${cur_dir}/src" || return 1
    if [ -s /usr/local/imagemagick/bin/convert ]; then
        echo "ImageMagick 已存在。"
    else
        # GitHub 标签归档可长期定位指定版本，避免上游 releases 清理旧文件后无法下载。
        Download_Files https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${ImageMagick_Ver#ImageMagick-}.tar.gz ${ImageMagick_Ver}.tar.gz
        Require_File "${ImageMagick_Ver}.tar.gz" "ImageMagick"
        Tar_Cd ${ImageMagick_Ver}.tar.gz ${ImageMagick_Ver}

        ./configure --prefix=/usr/local/imagemagick
        Make_Install || return 1
        cd ../
        Clean_Src_Dir "${ImageMagick_Ver}"
    fi
    Write_ImageMagick_Policy || Echo_Yellow "ImageMagick 资源策略未写入，保持上游默认（不限内存）。"
    return 0
}

# ImageMagick 库模块接口。库由 PHP 扩展 imagick 依赖，构建逻辑在 Build_ImageMagick_Lib。
ImageMagick_Sources()
{
    printf 'imagemagick\t-\t%s\t%s.tar.gz\thttps://github.com/ImageMagick/ImageMagick/archive/refs/tags/%s.tar.gz\tsha256\tsrc/checksums.sha256\n' \
        "${ImageMagick_Ver}" "${ImageMagick_Ver}" "${ImageMagick_Ver#ImageMagick-}"
}

# 0 已安装；1 缺失。
ImageMagick_Check()
{
    [ -s /usr/local/imagemagick/bin/convert ] || [ -s /usr/local/imagemagick/bin/magick ]
}

# Build_ImageMagick_Lib 内部以 exit 终止的原语在子 shell 中执行，转为返回码。
ImageMagick_Install()
{
    ( Build_ImageMagick_Lib ) || return 1
    ImageMagick_Check
}

# 按 Tune_Plan 写 ImageMagick 资源策略。默认策略不限内存与磁盘，多个 PHP worker
# 同时处理大图时可占满内存。临时文件放 /var/tmp：Debian 13 的 /tmp 为 tmpfs，map 与磁盘缓存放在
# 那里仍占内存。文件含 LNMP 标记时重写；首次写入前备份为 policy.xml.orig；
# 无标记且已有备份视为使用者自行修改，不覆盖。
Write_ImageMagick_Policy()
{
    local dir="${Magick_Etc_Dir:-/usr/local/imagemagick/etc/ImageMagick-7}" policy tmp

    policy="${dir}/policy.xml"
    Tune_Plan || return 0
    [ -d "${dir}" ] || return 0
    if [ -f "${policy}" ] && ! grep -q 'LNMP: ' "${policy}"; then
        if [ -e "${policy}.orig" ]; then
            Echo_Yellow "${policy} 已被修改，未写入资源策略。"
            return 0
        fi
        cp -p "${policy}" "${policy}.orig" || return 1
    fi
    tmp=$(mktemp "${policy}.XXXXXX") || return 1
    if ! printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        "<!-- LNMP: 按 ${Tune_Mem} MB / ${Tune_Cores} 核生成。原文件见 policy.xml.orig。 -->" \
        '<policymap>' \
        "  <policy domain=\"resource\" name=\"memory\" value=\"${Tune_Magick_Mem_MB}MiB\"/>" \
        "  <policy domain=\"resource\" name=\"map\" value=\"${Tune_Magick_Map_MB}MiB\"/>" \
        '  <policy domain="resource" name="disk" value="2GiB"/>' \
        '  <policy domain="resource" name="temporary-path" value="/var/tmp"/>' \
        "  <policy domain=\"resource\" name=\"thread\" value=\"${Tune_Magick_Threads}\"/>" \
        '  <policy domain="resource" name="width" value="16KP"/>' \
        '  <policy domain="resource" name="height" value="16KP"/>' \
        '</policymap>' > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    chmod 644 "${tmp}" && mv -f "${tmp}" "${policy}" || { rm -f "${tmp}"; return 1; }
    echo "ImageMagick 资源策略：memory ${Tune_Magick_Mem_MB}MiB，map ${Tune_Magick_Map_MB}MiB，临时目录 /var/tmp，thread ${Tune_Magick_Threads}（${policy}）"
}

Install_ImageMagic()
{
    Addons_Install_Ext imagick "ImageMagick"
}

Uninstall_ImageMagick()
{
    Addons_Remove_Ext imagick "ImageMagick" || return 1
    echo "正在删除 ImageMagick 目录..."
    rm -rf /usr/local/imagemagick
    Echo_Green "ImageMagick 库已删除。"
}
