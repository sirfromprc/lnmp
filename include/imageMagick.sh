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

    if [ -s "${zend_ext}" ] && [ -s /usr/local/imagemagick/bin/convert ]; then
        Restart_PHP
        Echo_Green "====== ImageMagick 安装完成 ======"
        Echo_Green "ImageMagick 安装成功。"
        return 0
    fi
    rm -f ${PHP_Path}/conf.d/008-imagick.ini
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
