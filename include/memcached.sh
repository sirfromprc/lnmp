#!/usr/bin/env bash

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

# 失败出口：报告原因，并把停掉的旧服务拉起来。
Memcached_Abort()
{
    Echo_Red "$1"
    Echo_Red "未部署服务单元、开机自启和防火墙规则。"
    Restart_Old_Memcached_Service
    return 0
}

# 重装前服务是否在运行，构建失败时据此把旧实例重新拉起。
Memcached_Was_Running='n'

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
    Tune_Plan && echo "缓存大小（按内存计算，写入 CACHESIZE）：${Tune_Memcached_MB} MB"
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
    if Svc_Use_Systemd memcached; then
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

# Memcached 服务端模块接口。
Memcached_Sources()
{
    printf 'memcached\t-\t%s\t%s.tar.gz\thttps://memcached.org/files/%s.tar.gz\tsha256\tsrc/checksums.sha256\n' \
        "${Memcached_Ver}" "${Memcached_Ver}" "${Memcached_Ver}"
}

# 0 二进制与 init 脚本齐备；1 缺失或不完整。
Memcached_Check()
{
    [ -s /usr/local/memcached/bin/memcached ] && [ -s /etc/init.d/memcached ]
}

# 服务端安装在子 shell 中执行：不改变调用方工作目录，下载与解包原语的 exit 转为返回码。
# 返回 0 已安装并在运行；1 安装失败；3 已安装但服务未在运行。
Memcached_Install()
{
    ( _Memcached_Install )
}

_Memcached_Install()
{
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
    if Tune_Plan; then
        sed -i "s/^CACHESIZE=.*/CACHESIZE=${Tune_Memcached_MB}/" /etc/init.d/memcached
        grep -q "^CACHESIZE=${Tune_Memcached_MB}\$" /etc/init.d/memcached ||
            Echo_Yellow "Memcached 缓存大小未写入 /etc/init.d/memcached，保持 64MB。"
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
    Svc_Install_Unit "${cur_dir}/init.d/memcached.service" /etc/systemd/system/memcached.service || return 1
    StartUp memcached

    # Memcached 无认证，需阻止公网访问缓存内容并避免 UDP 反射风险。
    Firewall_Block tcp "${Memcached_Port}"
    Firewall_Block udp "${Memcached_Port}"
    Firewall_Save

    echo "正在启动 Memcached..."
    # 二进制与 init 脚本每次安装都会重写，必须 restart；start 对已在运行的实例不生效。
    StartOrStop restart memcached

    [ -s /usr/local/memcached/bin/memcached ] \
        && /etc/init.d/memcached status >/dev/null 2>&1 && return 0
    return 3
}

# 服务端卸载。PHP 扩展由调用方经扩展模块移除。
Memcached_Remove()
{
    Remove_StartUp memcached
    echo "正在删除 Memcached 文件..."
    rm -rf /usr/local/libmemcached
    rm -rf /usr/local/memcached
    rm -rf /etc/init.d/memcached
    rm -rf /usr/bin/memcached
    Firewall_Unblock tcp "${Memcached_Port}"
    Firewall_Unblock udp "${Memcached_Port}"
    Firewall_Save
    return 0
}
