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
    echo "====== 正在安装 ImageMagick ======"
    Press_Start || return 1

    rm -f ${PHP_Path}/conf.d/008-imagick.ini
    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}imagick.so"
    if [ -s "${zend_ext}" ]; then
        rm -f "${zend_ext}"
    fi

    # ImageMagick 库构建失败时停止，避免 imagick 配置阶段产生次生错误。
    Build_ImageMagick_Lib || return 1

    cd "${cur_dir}/src" || return 1
    Download_Files https://pecl.php.net/get/${Imagick_Ver}.tgz ${Imagick_Ver}.tgz
    Require_File "${Imagick_Ver}.tgz" "pecl imagick"
    Tar_Cd ${Imagick_Ver}.tgz ${Imagick_Ver}
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config --with-imagick=/usr/local/imagemagick
    Make_Install || return 1
    cd ../

    cat >${PHP_Path}/conf.d/008-imagick.ini<<EOF
extension = "imagick.so"
EOF

    if [ ! -s /usr/local/imagemagick/bin/convert ]; then
        rm -f ${PHP_Path}/conf.d/008-imagick.ini
        Echo_Red "ImageMagick 库未安装成功：/usr/local/imagemagick/bin/convert 不存在。"
        return 1
    fi
    if Accept_PHP_Ext imagick "${PHP_Path}/conf.d/008-imagick.ini" "${zend_ext}"; then
        Echo_Green "====== ImageMagick 安装完成 ======"
        Echo_Green "ImageMagick 安装成功。"
        return 0
    fi
    Echo_Red "imagick 扩展安装失败！"
    return 1
}

Uninstall_ImageMagick()
{
    echo "即将卸载 ImageMagick..."
    Press_Start || return 1
    rm -f ${PHP_Path}/conf.d/008-imagick.ini
    echo "正在删除 ImageMagick 目录..."
    rm -rf /usr/local/imagemagick
    Restart_PHP
    Echo_Green "ImageMagick 卸载完成。"
}
