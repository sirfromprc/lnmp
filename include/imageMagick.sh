#!/usr/bin/env bash

# ---------------------------------------------------------------------------
# Build_ImageMagick_Lib — 编译安装 ImageMagick 本体到 /usr/local/imagemagick
#
# 抽出来是因为有两条调用路径：addons.sh 的交互式安装，和 install.sh 里
# 「PHP 默认扩展」的自动安装（include/php_default_ext.sh）。
# 两边各写一份将随版本升级而漂移，故共用此函数。
# 本函数不含任何交互（Press_Start）与 PHP 侧动作，只负责库本身。
# ---------------------------------------------------------------------------
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
        apt-get update
        apt-get install -y libwebp-dev
    fi
    ldconfig

    cd ${cur_dir}/src
    if [ -s /usr/local/imagemagick/bin/convert ]; then
        echo "ImageMagick already exists."
    else
        # imagemagick.org/archive/releases 只保留近期几个版本，旧版本会下线
        # （7.1.1-8 实测已 404）。GitHub 的 tag 归档是稳定可回溯的来源。
        Download_Files https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${ImageMagick_Ver#ImageMagick-}.tar.gz ${ImageMagick_Ver}.tar.gz
        Require_File "${ImageMagick_Ver}.tar.gz" "ImageMagick"
        Tar_Cd ${ImageMagick_Ver}.tar.gz ${ImageMagick_Ver}

        ./configure --prefix=/usr/local/imagemagick
        Make_Install || exit 1
        cd ../
        rm -rf ${cur_dir}/src/${ImageMagick_Ver}
    fi
}

Install_ImageMagic()
{
    echo "====== Installing ImageMagic ======"
    Press_Start

    rm -f ${PHP_Path}/conf.d/008-imagick.ini
    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}imagick.so"
    if [ -s "${zend_ext}" ]; then
        rm -f "${zend_ext}"
    fi

    Build_ImageMagick_Lib

    cd ${cur_dir}/src
    Download_Files https://pecl.php.net/get/${Imagick_Ver}.tgz ${Imagick_Ver}.tgz
    Require_File "${Imagick_Ver}.tgz" "pecl imagick"
    Tar_Cd ${Imagick_Ver}.tgz ${Imagick_Ver}
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config --with-imagick=/usr/local/imagemagick
    Make_Install || exit 1
    cd ../

    cat >${PHP_Path}/conf.d/008-imagick.ini<<EOF
extension = "imagick.so"
EOF

    if [ -s "${zend_ext}" ] && [ -s /usr/local/imagemagick/bin/convert ]; then
        Restart_PHP
        Echo_Green "====== ImageMagick install completed ======"
        Echo_Green "ImageMagick installed successfully, enjoy it!"
    else
        rm -f ${PHP_Path}/conf.d/008-imagick.ini
        Echo_Red "imagick install failed!"
    fi
}

Uninstall_ImageMagick()
{
    echo "You will uninstall ImageMagick..."
    Press_Start
    rm -f ${PHP_Path}/conf.d/008-imagick.ini
    echo "Delete ImageMagick directory..."
    rm -rf /usr/local/imagemagick
    Restart_PHP
    Echo_Green "Uninstall ImageMagick completed."
}
