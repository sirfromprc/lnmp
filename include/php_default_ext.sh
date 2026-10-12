#!/usr/bin/env bash
# PHP 安装完成后以非交互方式安装常用扩展，适用于自动安装流程。
# 各扩展由 lnmp.conf 的 Enable_PHP_Default_* 开关控制，默认全开。
# 单个扩展安装失败时告警但不中止整个 LNMP 安装，
# 并在结束时汇总未完成项，便于单独重试。
# 编译与安装由 include/mod/php_ext.sh 完成，本文件只负责选择与汇总。

PHP_Default_Ext_Failed=''

# Enable_Opcache_Config <PHP 前缀> [内存 MB]：写入 OPcache 配置，主版本、多版本、升级与 addons 共用。
# 内存值由调用方按调优结果传入，为空时取 128。
# 8.4 及以下为共享扩展，需 zend_extension 加载；8.5 起静态编入，无 opcache.so。
# JIT 不写入：8.0~8.3 默认 jit_buffer_size=0，8.4 起默认 jit=disable。
Enable_Opcache_Config()
{
    local prefix="$1" opcache_mb="${2:-128}" ext_dir load='' interned=32 ini
    ini="${prefix}/conf.d/004-opcache.ini"
    ext_dir=$("${prefix}/bin/php-config" --extension-dir 2>/dev/null)
    # interned strings 缓冲占用 memory_consumption，小内存档减半。
    [ "${opcache_mb}" -lt 128 ] && interned=16

    if [ -n "${ext_dir}" ] && [ -s "${ext_dir}/opcache.so" ]; then
        load="zend_extension = \"${ext_dir}/opcache.so\""
    elif ! "${prefix}/bin/php" -n -m 2>/dev/null | grep -qx 'Zend OPcache'; then
        Echo_Red "${prefix} 未包含 OPcache，跳过（opcache.so 不存在且未静态编入）"
        printf -v PHP_Default_Ext_Failed '%s opcache(未编译)' \
            "${PHP_Default_Ext_Failed}"
        return 1
    fi

    mkdir -p "${prefix}/conf.d" || return 1
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

# 输出配置中启用的默认编译扩展，顺序即安装顺序：
# igbinary 必须在 phpredis 之前，phpredis 的 --enable-redis-igbinary 需要它的头文件。
Default_Ext_List()
{
    [ "${Enable_PHP_Default_Igbinary}" = 'y' ] && echo igbinary
    [ "${Enable_PHP_Default_Redis}" = 'y' ] && echo redis
    [ "${Enable_PHP_Default_Imagick}" = 'y' ] && echo imagick
    [ "${Enable_PHP_Default_Zstd}" = 'y' ] && echo zstd
    return 0
}

# Install_PHP_Default_Ext <PHP 前缀> [OPcache 内存 MB]：安装配置中启用的默认扩展。
# 单个扩展失败只告警并记入 PHP_Default_Ext_Failed，不中止安装。
Install_PHP_Default_Ext()
{
    local prefix="${1:-/usr/local/php}" opcache_mb="${2:-}" ext reason

    if [ ! -s "${prefix}/bin/php-config" ]; then
        Echo_Red "未找到 ${prefix}/bin/php-config，跳过默认扩展安装。"
        return 1
    fi

    mkdir -p "${prefix}/conf.d"

    if [ "${Enable_PHP_Default_Opcache}" = 'y' ]; then
        Enable_Opcache_Config "${prefix}" "${opcache_mb}"
    fi

    for ext in $(Default_Ext_List); do
        reason=''
        if ! PHPExt_Install "${prefix}" "${ext}" reason; then
            printf -v PHP_Default_Ext_Failed '%s %s(%s)' \
                "${PHP_Default_Ext_Failed}" "${ext}" "${reason:-安装失败}"
        fi
    done

    # fileinfo 在 PHP configure 阶段决定，此处仅核对最终加载状态。
    if [ "${Enable_PHP_Fileinfo}" = 'y' ]; then
        if ! "${prefix}/bin/php" -m 2>/dev/null | grep -qi '^fileinfo$'; then
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
    "${prefix}/bin/php" -m 2>/dev/null | tr '\n' ' '
    echo
}
