#!/usr/bin/env bash

Install_PHPMemcache()
{
    echo "正在安装 PHP memcache 扩展..."
    cd "${cur_dir}/src" || return 1
    # PHP 8.x 使用 PHP8Memcache_Ver 指定的 PECL 官方版本。
    Download_Files https://pecl.php.net/get/${PHP8Memcache_Ver}.tgz ${PHP8Memcache_Ver}.tgz
    Require_File "${PHP8Memcache_Ver}.tgz" "pecl memcache"
    Tar_Cd ${PHP8Memcache_Ver}.tgz ${PHP8Memcache_Ver}
    Patch_PHPMemcache_Smart_String || return 1
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config
    Make_Install || return 1
    cd ../
}

# memcache 8.2 引用的 ext/standard/php_smart_string*.h 在 PHP 8.5 已删除，
# 这两个头在 8.0-8.4 只是转发到 Zend 的同名头，改为直接引用 Zend 版本对各分支通用。
# 上游 2023-04-30 后未再发版，只能在本地打补丁。
Patch_PHPMemcache_Smart_String()
{
    local patch_file="${cur_dir}/src/patch/memcache-8.2-php85.patch"

    # 已改过就不重复打；解包目录可能是上一次安装留下的。
    if ! grep -q 'ext/standard/php_smart_string' src/memcache_pool.h 2>/dev/null; then
        return 0
    fi
    if [ ! -s "${patch_file}" ]; then
        Echo_Red "缺少补丁文件：${patch_file}"
        return 1
    fi
    # addons 是独立入口，不能假定主安装的依赖已装齐。
    if ! command -v patch >/dev/null 2>&1; then
        Echo_Red "缺少 patch 命令，无法修正 memcache 源码。"
        Echo_Yellow "请先安装：apt install patch（Debian 系）或 yum install patch（RHEL 系）。"
        return 1
    fi
    # 行号有偏移时 GNU patch 默认会留 .orig 备份，编译目录里不需要。
    if ! patch -p1 --forward --no-backup-if-mismatch < "${patch_file}"; then
        Echo_Red "memcache 源码打补丁失败，无法在当前 PHP 分支编译。"
        return 1
    fi
    return 0
}

Install_PHPMemcached()
{
    echo "正在安装 PHP memcached 扩展..."
    cd "${cur_dir}/src" || return 1
    Get_Dist_Name
    if [ "$PM" = "yum" ]; then
        yum install cyrus-sasl-devel -y
        Get_Dist_Version
    elif [ "$PM" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        Apt_Get install libsasl2-2 sasl2-bin libsasl2-2 libsasl2-dev libsasl2-modules -y
    fi
    Download_Files https://launchpad.net/libmemcached/1.0/${Libmemcached_Ver#libmemcached-}/+download/${Libmemcached_Ver}.tar.gz ${Libmemcached_Ver}.tar.gz
    Require_File "${Libmemcached_Ver}.tar.gz" "libmemcached"
    Tar_Cd ${Libmemcached_Ver}.tar.gz ${Libmemcached_Ver}
    # GCC 7 及以上需要兼容补丁，版本判断覆盖后续两位数版本。
    if gcc -dumpversion | grep -Eq "^([7-9]|[1-9][0-9])"; then
        patch -p1 < ${cur_dir}/src/patch/libmemcached-1.0.18-gcc7.patch
    fi
    ./configure --prefix=/usr/local/libmemcached --with-memcached
    Make_Install || return 1
    cd ../

    cd "${cur_dir}/src" || return 1
    [[ -d "${PHP8Memcached_Ver}" ]] && rm -rf "${PHP8Memcached_Ver}"
    Download_Files https://pecl.php.net/get/${PHP8Memcached_Ver}.tgz ${PHP8Memcached_Ver}.tgz
    Require_File "${PHP8Memcached_Ver}.tgz" "pecl memcached"
    Tar_Cd ${PHP8Memcached_Ver}.tgz ${PHP8Memcached_Ver}
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config --enable-memcached --with-libmemcached-dir=/usr/local/libmemcached
    Make_Install || return 1
    cd ../
}

# memcached 依赖 libevent 开发头文件；addons 是独立入口，不能假定主安装的依赖已装齐。
Install_Memcached_Deps()
{
    [ -s /usr/include/event2/event.h ] && return 0
    Get_Dist_Name
    if [ "${PM}" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        Apt_Get install -y libevent-dev >/dev/null 2>&1
    elif [ "${PM}" = "yum" ]; then
        yum install -y libevent-devel >/dev/null 2>&1
    fi
    [ -s /usr/include/event2/event.h ]
}

# 服务端未装成时的统一出口：撤掉本次写入的 PHP ini，不部署 unit、开机自启和防火墙规则。
# 重装会先删掉现有 ini 与扩展产物，失败时要放回去，否则站点会丢掉本来可用的扩展。
Memcached_Ext_Backup_Dir=''
Memcached_Was_Running='n'

Backup_Existing_PHPMemcached()
{
    Memcached_Ext_Backup_Dir=$(mktemp -d /tmp/lnmp-phpmemcached-bak.XXXXXXXX) || return 1
    if [ -s "${PHP_Path}/conf.d/005-memcached.ini" ]; then
        \cp -p "${PHP_Path}/conf.d/005-memcached.ini" "${Memcached_Ext_Backup_Dir}/005-memcached.ini" || return 1
    fi
    if [ -s "${zend_ext}" ]; then
        \cp -p "${zend_ext}" "${Memcached_Ext_Backup_Dir}/${PHP_ZTS}" || return 1
    fi
    return 0
}

Restore_Existing_PHPMemcached()
{
    local restored='n'

    [ -n "${Memcached_Ext_Backup_Dir}" ] || return 0
    if [ -s "${Memcached_Ext_Backup_Dir}/${PHP_ZTS}" ]; then
        \cp -p "${Memcached_Ext_Backup_Dir}/${PHP_ZTS}" "${zend_ext}" && restored='y'
    fi
    if [ -s "${Memcached_Ext_Backup_Dir}/005-memcached.ini" ]; then
        \cp -p "${Memcached_Ext_Backup_Dir}/005-memcached.ini" "${PHP_Path}/conf.d/005-memcached.ini" && restored='y'
    fi
    if [ "${restored}" = 'y' ]; then
        Echo_Yellow "已恢复安装前的 PHP Memcached 扩展并重载 PHP。"
        Restart_PHP
    fi
    rm -rf "${Memcached_Ext_Backup_Dir}"
    Memcached_Ext_Backup_Dir=''
    return 0
}

Clear_PHPMemcached_Backup()
{
    [ -n "${Memcached_Ext_Backup_Dir}" ] && rm -rf "${Memcached_Ext_Backup_Dir}"
    Memcached_Ext_Backup_Dir=''
    return 0
}

# 构建失败时旧二进制和旧 init 脚本仍在原位，重新启动即可恢复重装前的服务。
Restart_Old_Memcached_Service()
{
    [ "${Memcached_Was_Running}" = 'y' ] || return 0
    if [ ! -s /usr/local/memcached/bin/memcached ]; then
        Echo_Red "旧 memcached 二进制已不在 /usr/local/memcached/bin/memcached，无法自动恢复服务。"
        return 1
    fi
    echo "正在把重装前的 Memcached 服务重新启动..."
    if StartOrStop start memcached && Memcached_Service_Active; then
        Echo_Yellow "已恢复重装前的 Memcached 服务，版本与配置均未改变。"
        return 0
    fi
    Echo_Red "重装前的 Memcached 服务未能自动恢复，请手工执行：lnmp memcached start"
    return 1
}

# 失败出口：撤回本次 ini，放回备份的扩展，并把停掉的旧服务拉起来。
Memcached_Abort()
{
    rm -f ${PHP_Path}/conf.d/005-memcached.ini
    Echo_Red "$1"
    Echo_Red "已移除 005-memcached.ini，未部署服务单元、开机自启和防火墙规则。"
    Restore_Existing_PHPMemcached
    Restart_Old_Memcached_Service
    return 0
}

# 端口在安装时写入 init 脚本和防火墙规则，因此在动系统前先列出生效值。
Print_Memcached_Install_Summary()
{
    Echo_Yellow "=========================================================================="
    echo "服务端：${Memcached_Ver}"
    echo "PHP 扩展：${PHP_ZTS%.so}"
    if [ "${PHP_ZTS}" = "memcached.so" ]; then
        Echo_Yellow "php-memcached 另需安装 SASL 开发包并编译 ${Libmemcached_Ver} ，耗时长于 php-memcache 。"
    fi
    echo "监听端口（写入 /etc/init.d/memcached 的 PORT）：${Memcached_Port}"
    echo "监听地址：127.0.0.1，防火墙同时阻断该端口的 TCP 与 UDP 公网访问"
    echo "自测页（Enable_Memcached_Test_Page）：${Enable_Memcached_Test_Page}"
    if [ -s /usr/local/memcached/bin/memcached ]; then
        Echo_Yellow "已装过 Memcached，本次重新编译安装：先停服务，/etc/init.d/memcached 备份为"
        Echo_Yellow "memcached.bak.<时间戳> 后按模板重建，CACHESIZE、MAXCONN 等会回到默认值。"
    fi
    Echo_Yellow "改端口：改 lnmp.conf 后重跑，或 Memcached_Port=11212 bash addons.sh install memcached"
    Echo_Yellow "装后改端口：改 /etc/init.d/memcached 并重启服务，再执行 lnmp fw sync"
    Echo_Yellow "=========================================================================="
}

# PORT 是 Memcached 的唯一端口来源，unit 通过 init 脚本启动。重复安装时不重写该
# 脚本，而防火墙按 lnmp.conf 写规则，因此这里只对齐 PORT 一行，保留 CACHESIZE、
# MAXCONN 等使用者改过的参数，并迁移阻断规则。改动结果由 Memcached_Port_Changed 传出。
Sync_Memcached_Init_Port()
{
    # 脚本路径可传入，便于定向测试；安装流程使用默认值。
    local init="${1:-/etc/init.d/memcached}" old_port=''

    Memcached_Port_Changed='n'
    [ -s "${init}" ] || return 0

    old_port=$(grep -E '^PORT=' "${init}" | head -1 | cut -d= -f2 | tr -d '"')
    [ "${old_port}" = "${Memcached_Port}" ] && return 0

    echo "/etc/init.d/memcached 当前端口为 ${old_port:-未设置}，按 lnmp.conf 改为 ${Memcached_Port}。"
    sed -i "s/^PORT=.*/PORT=${Memcached_Port}/" "${init}" || return 1
    Check_Conf_Applied "${init}" "^PORT=${Memcached_Port}\$" "Memcached 端口 ${Memcached_Port}" || return 1
    if [ -n "${old_port}" ]; then
        Firewall_Unblock tcp "${old_port}"
        Firewall_Unblock udp "${old_port}"
    fi
    Memcached_Port_Changed='y'
    return 0
}

# 服务是否由本机管理入口托管；systemd 可用时以 unit 状态为准。
Memcached_Service_Active()
{
    if Use_Systemd_Unit memcached; then
        systemctl is-active --quiet memcached.service
    else
        [ -x /etc/init.d/memcached ] && /etc/init.d/memcached status >/dev/null 2>&1
    fi
}

# 重装前的准备：init 脚本按模板重建会覆盖现有参数，因此先停服务再备份，
# 并撤销旧端口的阻断规则。停不掉服务就不动任何文件。
Prepare_Memcached_Rebuild()
{
    local init='/etc/init.d/memcached' old_port='' backup

    [ -s "${init}" ] && old_port=$(grep -E '^PORT=' "${init}" | head -1 | cut -d= -f2 | tr -d '"')

    if Memcached_Service_Active; then
        Memcached_Was_Running='y'
        echo "重新编译前先停止现有 Memcached 服务..."
        StartOrStop stop memcached
        if Memcached_Service_Active; then
            Echo_Red "无法停止现有 Memcached 服务，未改动任何文件。"
            Echo_Red "请手工停止后重试：lnmp memcached stop"
            return 1
        fi
    fi

    if [ -s "${init}" ]; then
        backup="${init}.bak.$(date +%Y%m%d%H%M%S)"
        if ! \cp -p "${init}" "${backup}"; then
            Echo_Red "备份 ${init} 失败，未改动任何文件。"
            return 1
        fi
        echo "现有 init 脚本已备份为 ${backup}，本次按模板重建。"
    fi

    # 旧端口的阻断规则不再对应本服务，重建后按新端口重新阻断。
    if [ -n "${old_port}" ] && [ "${old_port}" != "${Memcached_Port}" ]; then
        Firewall_Unblock tcp "${old_port}"
        Firewall_Unblock udp "${old_port}"
    fi
    return 0
}

Install_Memcached()
{
    # ver 同时决定扩展分支和测试页文件名 conf/memcached${ver}.php，编号不可调换。
    local ver
    echo "请选择要安装的 Memcached PHP 扩展："
    echo "1：安装 php-memcache （上游 2023-04-30 后停更， PHP 8.5 需本地补丁）"
    echo "2：安装 php-memcached （上游活跃，安装时另需编译 libmemcached ）"
    echo "两者 API 不兼容：php-memcache 用 Memcache 类， php-memcached 用 Memcached 类。"
    echo "已有站点代码用哪个类，就选哪个。"
    read -p "请输入 1 或 2 [默认 2]：" ver

    if [ "${ver}" = "1" ]; then
        echo "已选择 php-memcache 。"
        PHP_ZTS="memcache.so"
    elif [ "${ver}" = "2" ]; then
        echo "已选择 php-memcached 。"
        PHP_ZTS="memcached.so"
    else
        ver="2"
        echo "未输入或输入无效，使用默认项 php-memcached 。"
        PHP_ZTS="memcached.so"
    fi

    echo "====== 正在安装 Memcached ======"
    Print_Memcached_Install_Summary
    Press_Start || return 1

    Addons_Get_PHP_Ext_Dir
    zend_ext=${zend_ext_dir}${PHP_ZTS}
    # 现有 ini 与产物在编译前就被清掉，先备份，编译失败时放回原位。
    Backup_Existing_PHPMemcached || {
        Echo_Red "备份现有 PHP Memcached 扩展失败，已中止，未改动任何文件。"
        return 1
    }
    rm -f ${PHP_Path}/conf.d/005-memcached.ini
    if [ -s "${zend_ext}" ]; then
        rm -f "${zend_ext}"
    fi
    cat >${PHP_Path}/conf.d/005-memcached.ini<<EOF
extension = ${PHP_ZTS}
EOF

    echo "正在安装 Memcached..."
    cd "${cur_dir}/src" || return 1
    # 重装一律重新编译：误删过二进制、init 脚本或依赖文件时，只重写配置起不来。
    # 源码包与依赖先取齐再停服务，避免服务停下后卡在下载或依赖安装失败。
    Download_Files https://memcached.org/files/${Memcached_Ver}.tar.gz ${Memcached_Ver}.tar.gz
    Require_File "${Memcached_Ver}.tar.gz" "memcached"
    Install_Memcached_Deps || { Memcached_Abort "缺少 libevent 开发包，无法编译 memcached。"; return 1; }
    if ! Prepare_Memcached_Rebuild; then
        Memcached_Abort "重装前的停服务或备份失败。"
        return 1
    fi
    Tar_Cd ${Memcached_Ver}.tar.gz ${Memcached_Ver}
    # configure 失败时不能继续往下部署服务，否则失败点被推迟到启动阶段。
    if ! ./configure --prefix=/usr/local/memcached; then
        cd ../
        Memcached_Abort "memcached 的 configure 失败，请按上面的输出补齐依赖后重试。"
        return 1
    fi
    if ! Make_Install; then
        cd ../
        Memcached_Abort "memcached 编译或安装失败。"
        return 1
    fi
    cd ../
    Clean_Src_Dir "${Memcached_Ver}"

    ln -sf /usr/local/memcached/bin/memcached /usr/bin/memcached

    \cp ${cur_dir}/init.d/init.d.memcached /etc/init.d/memcached
    # 服务监听端口与 lnmp.conf 及防火墙规则保持一致。
    sed -i "s/^PORT=.*/PORT=${Memcached_Port}/" /etc/init.d/memcached
    if ! Check_Conf_Applied /etc/init.d/memcached "^PORT=${Memcached_Port}\$"             "Memcached 端口 ${Memcached_Port}"; then
        Memcached_Abort "Memcached init 脚本端口未写入。"
        return 1
    fi
    chmod +x /etc/init.d/memcached

    if ! id -u memcached >/dev/null 2>&1; then
        useradd -r -M -s /sbin/nologin memcached 2>/dev/null || \
            useradd -r -M -s /usr/sbin/nologin memcached 2>/dev/null
    fi

    # 防火墙按 lnmp.conf 写规则，init 脚本的 PORT 必须先对齐到同一值。
    if ! Sync_Memcached_Init_Port; then
        Memcached_Abort "Memcached init 脚本端口对齐失败。"
        return 1
    fi

    if [ ! -d /var/lock/subsys ]; then
      mkdir -p /var/lock/subsys
    fi

    # 重复安装时也部署 systemd 单元，确保服务通过统一入口管理。
    Install_Systemd_Unit "${cur_dir}/init.d/memcached.service" /etc/systemd/system/memcached.service || return 1
    StartUp memcached

    # PHP 扩展失败后仍完成服务启动、防火墙和验收，以分别报告服务端与扩展状态。
    local ext_rc=0
    if [ "${ver}" = "1" ]; then
        Install_PHPMemcache || ext_rc=1
    elif [ "${ver}" = "2" ]; then
        Install_PHPMemcached || ext_rc=1
    fi

    # 测试页无鉴权且会读写缓存，可能暴露 Memcached 的可用状态，因此默认不部署。
    if [ "${Enable_Memcached_Test_Page}" = "y" ]; then
        echo "正在复制 Memcached PHP 测试文件..."
        \cp ${cur_dir}/conf/memcached${ver}.php ${Default_Website_Dir}/memcached.php
        Warn_Demo_Page_Not_Served memcached.php
    else
        echo "未部署 Memcached 测试页面（Enable_Memcached_Test_Page='n'）。"
        echo "如需自测：cp conf/memcached${ver}.php ${Default_Website_Dir}/memcached.php"
    fi

    # 扩展验收含 PHP 重启；未通过时撤回 ini 并按扩展失败汇总。
    if [ "${ext_rc}" -eq 0 ]; then
        Accept_PHP_Ext "${PHP_ZTS%.so}" "${PHP_Path}/conf.d/005-memcached.ini" "${zend_ext}" || ext_rc=1
    else
        Restart_PHP
    fi

    # Memcached 无认证，需阻止公网访问缓存内容并避免 UDP 反射风险。
    Firewall_Block tcp "${Memcached_Port}"
    Firewall_Block udp "${Memcached_Port}"
    Firewall_Save

    echo "正在启动 Memcached..."
    # 二进制与 init 脚本每次安装都会重写，必须 restart；start 对已在运行的实例不生效。
    StartOrStop restart memcached

    # 分别检查服务端和 PHP 扩展，便于定位未完成的安装部分。
    local svc_ok=0 ext_ok=0
    [ -s /usr/local/memcached/bin/memcached ] \
        && /etc/init.d/memcached status >/dev/null 2>&1 && svc_ok=1
    [ -s "${zend_ext}" ] && [ "${ext_rc}" -eq 0 ] && ext_ok=1

    if [ "${svc_ok}" -eq 1 ] && [ "${ext_ok}" -eq 1 ]; then
        Clear_PHPMemcached_Backup
        Echo_Green "====== Memcached 安装完成 ======"
        Echo_Green "Memcached 安装成功。"
        return 0
    fi
    [ "${svc_ok}" -eq 1 ] && Echo_Green "memcached 服务端已安装并在运行。"
    [ "${svc_ok}" -eq 0 ] && Echo_Red "memcached 服务端没有装成或没能启动。"
    if [ "${ext_ok}" -eq 0 ]; then
        rm -f ${PHP_Path}/conf.d/005-memcached.ini
        Echo_Red "PHP 扩展 ${PHP_ZTS} 没有装成，已移除对应的 ini，避免 PHP 启动报警告。"
        Restore_Existing_PHPMemcached
    else
        Clear_PHPMemcached_Backup
    fi
    Echo_Red "Memcached 安装失败！"
    return 1
}

Uninstall_Memcached()
{
    echo "即将卸载 Memcached..."
    Press_Start || return 1
    rm -f ${PHP_Path}/conf.d/005-memcached.ini
    Restart_PHP
    Remove_StartUp memcached
    echo "正在删除 Memcached 文件..."
    rm -rf /usr/local/libmemcached
    rm -rf /usr/local/memcached
    rm -rf /etc/init.d/memcached
    rm -rf /usr/bin/memcached
    Firewall_Unblock tcp "${Memcached_Port}"
    Firewall_Unblock udp "${Memcached_Port}"
    Firewall_Save
    Echo_Green "Memcached 卸载完成。"
}
