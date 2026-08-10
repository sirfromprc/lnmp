#!/usr/bin/env bash
#
# php_default_ext.sh — PHP 安装完成后自动装上的常用扩展
#
# 原因单独一个文件：addons.sh 里那套 Install_* 函数是交互式的
# （Press_Start 等人按回车、Restart_PHP 依赖 addons.sh 自己的上下文），
# 直接在 install.sh 无人值守流程里调用会卡住。这里重写成非交互版本，
# 只共用真正重的部分（ImageMagick 库编译，见 Build_ImageMagick_Lib）。
#
# 各扩展由 lnmp.conf 的 Enable_PHP_Default_* 开关控制，默认全开。
# 单个扩展安装失败时告警但不中止整个 LNMP 安装，
# 但会在最后汇总打印，避免"装完了才发现少东西"。
#
# 编译顺序有一处硬约束：igbinary 必须在 phpredis 之前，
# 因为 phpredis 的 --enable-redis-igbinary 需要 igbinary 的头文件。

PHP_Default_Ext_Failed=''

# ---------------------------------------------------------------------------
# PHP_Ext_Dir — 取当前 PHP 的扩展目录（.so 落在哪）
# ---------------------------------------------------------------------------
PHP_Ext_Dir()
{
    ${PHP_Path}/bin/php-config --extension-dir 2>/dev/null
}

# ---------------------------------------------------------------------------
# Build_Pecl_Ext <包名带版本> <生成的.so名> <conf.d文件名> [额外configure参数...]
#
# pecl 扩展的编译步骤完全一致，故用一个函数收口：
#   下载 → 校验 → 解包 → phpize → configure → make install → 写 conf.d
# 最后核对 .so 真的生成了才写 ini，否则 PHP 启动会因加载不到扩展而告警。
# ---------------------------------------------------------------------------
Build_Pecl_Ext()
{
    local pkg="$1" so="$2" ini="$3"; shift 3
    local ext_dir

    Echo_Blue "[+] Installing PHP extension ${pkg}... "
    cd ${cur_dir}/src

    Download_Files https://pecl.php.net/get/${pkg}.tgz ${pkg}.tgz
    if [ ! -s "${cur_dir}/src/${pkg}.tgz" ]; then
        Echo_Red "${pkg} 下载失败，跳过"
        PHP_Default_Ext_Failed="${PHP_Default_Ext_Failed} ${pkg}(下载失败)"
        return 1
    fi
    Require_File "${pkg}.tgz" "pecl ${pkg}"

    rm -rf ${cur_dir}/src/${pkg}
    Tar_Cd ${pkg}.tgz ${pkg}

    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config "$@"
    make && make install

    cd ${cur_dir}/src
    rm -rf ${cur_dir}/src/${pkg}

    ext_dir=$(PHP_Ext_Dir)
    if [ -s "${ext_dir}/${so}" ]; then
        cat >${PHP_Path}/conf.d/${ini}<<EOF
extension = "${so}"
EOF
        Echo_Green "${pkg} 安装成功"
        return 0
    else
        Echo_Red "${pkg} 编译失败：${ext_dir}/${so} 未生成"
        PHP_Default_Ext_Failed="${PHP_Default_Ext_Failed} ${pkg}(编译失败)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Enable_Opcache_Config — 启用 opcache
#
# opcache 在 PHP 8.x 是编译进去的（configure 已带 --enable-opcache），
# 但默认不加载，必须在 conf.d 写 zend_extension 才生效。
# 注意它是 zend_extension，不是 extension，写错了不会加载。
# ---------------------------------------------------------------------------
Enable_Opcache_Config()
{
    local ext_dir
    ext_dir=$(PHP_Ext_Dir)

    if [ ! -s "${ext_dir}/opcache.so" ]; then
        Echo_Red "opcache.so 不存在，跳过（PHP 编译时未带 --enable-opcache？）"
        PHP_Default_Ext_Failed="${PHP_Default_Ext_Failed} opcache(未编译)"
        return 1
    fi

    cat >${PHP_Path}/conf.d/004-opcache.ini<<EOF
[Zend Opcache]
zend_extension = "${ext_dir}/opcache.so"
opcache.enable = 1
opcache.enable_cli = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 60
opcache.save_comments = 1
opcache.fast_shutdown = 0
EOF
    Echo_Green "opcache 已启用"
    return 0
}

# ---------------------------------------------------------------------------
# Install_PHP_Default_Ext — 装配置里开启的全部默认扩展
#
# 在 install.sh 的 Install_PHP 之后调用。此时 /usr/local/php 已就位。
# ---------------------------------------------------------------------------
Install_PHP_Default_Ext()
{
    PHP_Path='/usr/local/php'

    if [ ! -s "${PHP_Path}/bin/php-config" ]; then
        Echo_Red "未找到 ${PHP_Path}/bin/php-config，跳过默认扩展安装。"
        return 1
    fi

    mkdir -p ${PHP_Path}/conf.d

    if [ "${Enable_PHP_Default_Opcache}" = 'y' ]; then
        Enable_Opcache_Config
    fi

    # igbinary 必须排在 phpredis 前面（phpredis 编译时要用它的头文件）
    if [ "${Enable_PHP_Default_Igbinary}" = 'y' ]; then
        Build_Pecl_Ext "${PHPIgbinary_Ver}" igbinary.so 020-igbinary.ini
    fi

    if [ "${Enable_PHP_Default_Redis}" = 'y' ]; then
        if [ -s "$(PHP_Ext_Dir)/igbinary.so" ]; then
            # 有 igbinary 就打开 igbinary 序列化支持，序列化体积和速度都更好
            Build_Pecl_Ext "${PHPRedis_Ver}" redis.so 021-redis.ini --enable-redis-igbinary
        else
            Build_Pecl_Ext "${PHPRedis_Ver}" redis.so 021-redis.ini
        fi
    fi

    if [ "${Enable_PHP_Default_Imagick}" = 'y' ]; then
        Echo_Blue "[+] Installing ImageMagick (编译较慢，约数分钟)... "
        Build_ImageMagick_Lib
        if [ -s /usr/local/imagemagick/bin/convert ] || [ -s /usr/local/imagemagick/bin/magick ]; then
            Build_Pecl_Ext "${Imagick_Ver}" imagick.so 008-imagick.ini --with-imagick=/usr/local/imagemagick
        else
            Echo_Red "ImageMagick 库编译失败，跳过 imagick 扩展"
            PHP_Default_Ext_Failed="${PHP_Default_Ext_Failed} ImageMagick(库编译失败)"
        fi
    fi

    # fileinfo 是 configure 阶段决定的（--disable-fileinfo / 不传），
    # 这里只做结果核对，装没装成在编译时就定了。
    if [ "${Enable_PHP_Fileinfo}" = 'y' ]; then
        if ! ${PHP_Path}/bin/php -m 2>/dev/null | grep -qi '^fileinfo$'; then
            Echo_Red "fileinfo 未编入 PHP（检查 lnmp.conf 的 Enable_PHP_Fileinfo 是否在编译前就是 y）"
            PHP_Default_Ext_Failed="${PHP_Default_Ext_Failed} fileinfo(未编入)"
        fi
    fi

    echo
    if [ -n "${PHP_Default_Ext_Failed}" ]; then
        Echo_Red "以下默认扩展未装成功：${PHP_Default_Ext_Failed}"
        Echo_Red "LNMP 其余部分不受影响，可稍后用 ./addons.sh install 单独重试。"
    else
        Echo_Green "PHP 默认扩展全部安装完成。"
    fi

    Echo_Blue "当前已加载的 PHP 扩展："
    ${PHP_Path}/bin/php -m 2>/dev/null | tr '\n' ' '
    echo
}
