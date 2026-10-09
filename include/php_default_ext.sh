#!/usr/bin/env bash
# PHP 安装完成后以非交互方式安装常用扩展，适用于自动安装流程。
# 各扩展由 lnmp.conf 的 Enable_PHP_Default_* 开关控制，默认全开。
# 单个扩展安装失败时告警但不中止整个 LNMP 安装，
# 并在结束时汇总未完成项，便于单独重试。
# 编译顺序有一处硬约束：igbinary 必须在 phpredis 之前，
# 因为 phpredis 的 --enable-redis-igbinary 需要 igbinary 的头文件。

PHP_Default_Ext_Failed=''

# 获取当前 PHP 的扩展目录。
PHP_Ext_Dir()
{
    ${PHP_Path}/bin/php-config --extension-dir 2>/dev/null
}

# Build_Pecl_Ext <包名带版本> <生成的.so名> <conf.d文件名> [额外configure参数...]
# PECL 扩展使用统一的安装流程：
#   下载 → 校验 → 解包 → phpize → configure → make install → 写 conf.d
# 最后核对 .so 真的生成了才写 ini，否则 PHP 启动会因加载不到扩展而告警。
Build_Pecl_Ext()
{
    local pkg="$1" so="$2" ini="$3"; shift 3
    local ext_dir patch_file="${cur_dir}/src/patch/${pkg}-php85.patch"

    Echo_Blue "[+] 正在安装 PHP 扩展 ${pkg}... "
    cd "${cur_dir}/src" || return 1

    Download_Files https://pecl.php.net/get/${pkg}.tgz ${pkg}.tgz
    if [ ! -s "${cur_dir}/src/${pkg}.tgz" ]; then
        Echo_Red "${pkg} 下载失败，跳过"
        printf -v PHP_Default_Ext_Failed '%s %s(下载失败)' \
            "${PHP_Default_Ext_Failed}" "${pkg}"
        return 1
    fi
    Require_File "${pkg}.tgz" "pecl ${pkg}"

    Clean_Src_Dir "${pkg}"
    Tar_Cd ${pkg}.tgz ${pkg}

    # 上游尚未发布正式版的 PHP 8.5 兼容修正，补丁按 <包名>-php85.patch 命名。
    if [ -s "${patch_file}" ] && \
       ! patch -p1 --forward --no-backup-if-mismatch < "${patch_file}"; then
        cd "${cur_dir}/src" || return 1
        Clean_Src_Dir "${pkg}"
        Echo_Red "${pkg} 打补丁失败，跳过"
        printf -v PHP_Default_Ext_Failed '%s %s(补丁失败)' \
            "${PHP_Default_Ext_Failed}" "${pkg}"
        return 1
    fi

    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config "$@"
    # 构建失败时扩展目录可能残留旧 .so，不能按产物存在判定成功。
    if ! Make_Install; then
        cd "${cur_dir}/src" || return 1
        Clean_Src_Dir "${pkg}"
        Echo_Red "${pkg} 编译失败，跳过"
        printf -v PHP_Default_Ext_Failed '%s %s(编译失败)' \
            "${PHP_Default_Ext_Failed}" "${pkg}"
        return 1
    fi

    cd "${cur_dir}/src" || return 1
    Clean_Src_Dir "${pkg}"

    ext_dir=$(PHP_Ext_Dir)
    if [ -s "${ext_dir}/${so}" ]; then
        cat >${PHP_Path}/conf.d/${ini}<<EOF
extension = "${so}"
EOF
        Echo_Green "${pkg} 安装成功"
        return 0
    else
        Echo_Red "${pkg} 编译失败：${ext_dir}/${so} 未生成"
        printf -v PHP_Default_Ext_Failed '%s %s(编译失败)' \
            "${PHP_Default_Ext_Failed}" "${pkg}"
        return 1
    fi
}

# 写入 PHP_Path 下的 OPcache 配置，主版本、多版本、升级与 addons 共用。
# 8.4 及以下为共享扩展，需 zend_extension 加载；8.5 起静态编入，无 opcache.so。
# JIT 不写入：8.0~8.3 默认 jit_buffer_size=0，8.4 起默认 jit=disable。
Enable_Opcache_Config()
{
    local ext_dir load='' opcache_mb=128 interned=32 ini="${PHP_Path}/conf.d/004-opcache.ini"
    ext_dir=$(PHP_Ext_Dir)
    Tune_Plan && opcache_mb="${Tune_Opcache_MB}"
    # interned strings 缓冲占用 memory_consumption，小内存档减半。
    [ "${opcache_mb}" -lt 128 ] && interned=16

    if [ -n "${ext_dir}" ] && [ -s "${ext_dir}/opcache.so" ]; then
        load="zend_extension = \"${ext_dir}/opcache.so\""
    elif ! "${PHP_Path}/bin/php" -n -m 2>/dev/null | grep -qx 'Zend OPcache'; then
        Echo_Red "${PHP_Path} 未包含 OPcache，跳过（opcache.so 不存在且未静态编入）"
        printf -v PHP_Default_Ext_Failed '%s opcache(未编译)' \
            "${PHP_Default_Ext_Failed}"
        return 1
    fi

    mkdir -p "${PHP_Path}/conf.d" || return 1
    if ! { echo '[Zend Opcache]'
           [ -z "${load}" ] || printf '%s\n' "${load}"
           cat <<EOF
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = ${opcache_mb}
opcache.interned_strings_buffer = ${interned}
opcache.max_accelerated_files = 20000
opcache.revalidate_freq = 60
opcache.save_comments = 1
EOF
         } >"${ini}"
    then
        Echo_Red "写入 ${ini} 失败"
        printf -v PHP_Default_Ext_Failed '%s opcache(写入失败)' \
            "${PHP_Default_Ext_Failed}"
        return 1
    fi
    Echo_Green "opcache 已启用"
    return 0
}

# 安装配置中启用的默认扩展；调用时 /usr/local/php 已完成安装。
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

    # phpredis 编译 igbinary 支持前需要先安装对应头文件。
    if [ "${Enable_PHP_Default_Igbinary}" = 'y' ]; then
        Build_Pecl_Ext "${PHPIgbinary_Ver}" igbinary.so 020-igbinary.ini
    fi

    if [ "${Enable_PHP_Default_Redis}" = 'y' ]; then
        if [ -s "$(PHP_Ext_Dir)/igbinary.so" ]; then
            # igbinary 可用时启用更紧凑的 Redis 序列化支持。
            Build_Pecl_Ext "${PHPRedis_Ver}" redis.so 021-redis.ini --enable-redis-igbinary
        else
            Build_Pecl_Ext "${PHPRedis_Ver}" redis.so 021-redis.ini
        fi
    fi

    if [ "${Enable_PHP_Default_Imagick}" = 'y' ]; then
        Echo_Blue "[+] 正在安装 ImageMagick（编译较慢，约数分钟）... "
        Build_ImageMagick_Lib
        if [ -s /usr/local/imagemagick/bin/convert ] || [ -s /usr/local/imagemagick/bin/magick ]; then
            Build_Pecl_Ext "${Imagick_Ver}" imagick.so 008-imagick.ini --with-imagick=/usr/local/imagemagick
        else
            Echo_Red "ImageMagick 库编译失败，跳过 imagick 扩展"
            printf -v PHP_Default_Ext_Failed '%s ImageMagick(库编译失败)' \
            "${PHP_Default_Ext_Failed}"
        fi
    fi

    # fileinfo 在 PHP configure 阶段决定，此处仅核对最终加载状态。
    if [ "${Enable_PHP_Fileinfo}" = 'y' ]; then
        if ! ${PHP_Path}/bin/php -m 2>/dev/null | grep -qi '^fileinfo$'; then
            Echo_Red "fileinfo 未编入 PHP（检查 lnmp.conf 的 Enable_PHP_Fileinfo 是否在编译前就是 y）"
            printf -v PHP_Default_Ext_Failed '%s fileinfo(未编入)' \
            "${PHP_Default_Ext_Failed}"
        fi
    fi

    echo
    if [ -n "${PHP_Default_Ext_Failed}" ]; then
        Echo_Red "以下默认扩展未装成功：${PHP_Default_Ext_Failed}"
        Echo_Red "LNMP 其余部分不受影响，opcache、Redis、imageMagick 可用 ./addons.sh install 重试。"
    else
        Echo_Green "PHP 默认扩展全部安装完成。"
    fi

    Echo_Blue "当前已加载的 PHP 扩展："
    ${PHP_Path}/bin/php -m 2>/dev/null | tr '\n' ' '
    echo
}
