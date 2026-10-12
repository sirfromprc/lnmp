#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ "$(id -u)" != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi

# 源码根目录按脚本自身位置确定：从其它目录以绝对路径启动时，
# pwd 指向调用者的当前目录，相对路径 source 会加载到那里的同名文件。
cur_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
if [ ! -s "${cur_dir}/lnmp.conf" ] || [ ! -d "${cur_dir}/include" ]; then
    echo "错误：${cur_dir} 不是 LNMP 源码目录，缺少 lnmp.conf 或 include/。"
    exit 1
fi
cd "${cur_dir}" || exit 1
action=$1
action2=$2

. "${cur_dir}/include/product.sh"
. "${cur_dir}/lnmp.conf"
. "${cur_dir}/include/main.sh"
. "${cur_dir}/include/tune.sh"
. "${cur_dir}/include/verify.sh"
. "${cur_dir}/include/firewall.sh"
. "${cur_dir}/include/profile.sh"
. "${cur_dir}/include/init.sh"
. "${cur_dir}/include/version.sh"
. "${cur_dir}/include/memcached.sh"
. "${cur_dir}/include/mod/php.sh"
. "${cur_dir}/include/mod/php_ext.sh"
. "${cur_dir}/include/php_default_ext.sh"
. "${cur_dir}/include/opcache.sh"
. "${cur_dir}/include/redis.sh"
. "${cur_dir}/include/imageMagick.sh"
# ionCube 未接入安装流程。以下函数用于显示状态及清理既有安装。
. "${cur_dir}/include/apcu.sh"
. "${cur_dir}/include/php_exif.sh"
. "${cur_dir}/include/php_fileinfo.sh"
. "${cur_dir}/include/php_ldap.sh"
. "${cur_dir}/include/php_bz2.sh"
. "${cur_dir}/include/php_sodium.sh"
. "${cur_dir}/include/php_imap.sh"
. "${cur_dir}/include/php_swoole.sh"
. "${cur_dir}/include/mod/nodejs.sh"
. "${cur_dir}/include/lock.sh"

# 维护任务互斥：写入类动作先持锁；用法提示不改动系统，不占锁。
case "${action}" in
    install|uninstall) Lock_Acquire "addons.sh ${action} ${action2}" || exit 2 ;;
esac

# Redis 与 Memcached 的端口会写入服务配置和防火墙规则，因此必须在系统变更前校验。
Validate_Service_Ports || exit 1

ionCube_NotWired_Notice()
{
    Echo_Yellow "ionCube Loader 当前未接入本包的安装流程。"
    Echo_Yellow "这不是安全判定 —— 官方域名发布的预编译 Loader 是可接受的，"
    Echo_Yellow "只是尚未按架构补齐 src/checksums.sha256 里的校验条目。"
    Echo_Yellow "现在需要的话，请到 https://www.ioncube.com/loaders.php 取官方包自行安装。"
}

# ionCube 卸载仅删除 ini 并重启 PHP，不下载文件。
# /usr/local/ioncube 由使用者确认内容后手工清理。
Uninstall_ionCube()
{
    echo "即将卸载 ionCube..."
    Press_Start || return 1
    rm -f ${PHP_Path}/conf.d/001-ioncube.ini
    Restart_PHP
    Echo_Green "ionCube 卸载完成。"
    Echo_Yellow "注意：/usr/local/ioncube 下的 .so 未删除，如不再需要请手工 rm -rf。"
}

Display_Addons_Menu()
{
    echo "##### 缓存 / 优化器 / 加速器 #####"
    echo "  1: Memcached"
    echo "  2: opcache"
    echo "  3: Redis"
    echo "  4: apcu"
    echo "##### 图像处理 #####"
    echo "  5: imageMagick"
    echo "##### 暂未接入 #####"
    echo "  6: ionCube Loader（暂未接入，说明见下方）"
    echo "##### PHP 模块/扩展 #####"
    echo "  7: Exif"
    echo "  8: Fileinfo"
    echo "  9: Ldap"
    echo " 10: Bz2"
    echo " 11: Sodium"
    echo " 13: Swoole"
    echo "##### 运行时（与 PHP 无关）#####"
    echo " 14: Node.js"
    echo " 15: PM2（装入已安装的 Node.js 主版本）"
    echo "#################################################"
    echo " 输入 exit：退出当前脚本"
    echo "#################################################"
    read -p "请选择 [1-15]，或输入 exit 退出：" action2
}

Restart_PHP()
{
    local service

    # 仅 mod_php 形态由 Apache 加载 PHP；PHP-FPM 形态重启 php-fpm。
    if [ -s /usr/local/apache/bin/httpd ] && [ -s /usr/local/apache/conf/httpd.conf ] && [ -s /etc/init.d/httpd ] \
        && [ "$(PHP_Detect_Sapi lamp)" = apxs ]; then
        echo "正在重启 Apache......"
        service='httpd'
    else
        echo "正在重启 php-fpm......"
        service="${PHPFPM_Initd##*/}"
        # 多版本 PHP 由模板实例管理时经 SysV 脚本重启，实例会脱离 systemd。
        case "${service}" in
        php-fpm?*)
            Svc_Use_Systemd "php-fpm@${service#php-fpm}" && service="php-fpm@${service#php-fpm}"
            ;;
        esac
    fi

    StartOrStop restart "${service}"
}

# 扩展验收：Accept_PHP_Ext <模块名> <本次写入的 ini> [产物路径]
# 产物存在不代表 PHP 能加载，因此依次确认产物、CLI 能 --ri 到该模块、
# 重启后 Web 侧 PHP 服务仍在运行。任一步失败都撤回本次 ini 并返回非零。
Accept_PHP_Ext()
{
    local module="$1" ini="$2" so="${3:-}" out

    if [ -n "${so}" ] && [ ! -s "${so}" ]; then
        Echo_Red "PHP 模块 ${module} 的产物未生成：${so}"
        rm -f "${ini}"
        return 1
    fi

    if ! out=$("${PHP_Path}/bin/php" --ri "${module}" 2>&1); then
        Echo_Red "PHP 模块 ${module} 写入 ini 后仍无法加载，已删除 ${ini}。"
        printf '%s\n' "${out}" | sed 's/^/  /' | head -n 20
        rm -f "${ini}"
        Restart_PHP
        return 1
    fi

    if ! Restart_PHP; then
        Echo_Red "PHP 模块 ${module} 可加载，但重启 PHP 服务失败，已删除 ${ini}。"
        Echo_Red "撤回配置后重新启动服务，请再执行 lnmp status 复查。"
        rm -f "${ini}"
        Restart_PHP
        return 1
    fi
    return 0
}

# Addons_Prefetch_Ext <扩展名>：取齐扩展及其依赖库的源码包，失败即退出，不动系统。
Addons_Prefetch_Ext()
{
    local ext="$1" file url

    while IFS=$'\t' read -r _ _ _ file url _; do
        ( cd "${cur_dir}/src" && Download_Files "${url}" "${file}" ) && [ -s "${cur_dir}/src/${file}" ] || {
            Echo_Red "错误：无法下载 ${file}。"
            return 1
        }
    done < <(PHPExt_Sources "${PHP_Path}" "${ext}")
    return 0
}

# Addons_Apply_Ext <扩展名> <显示名>
# 经 PHP 扩展模块构建；模块已完成加载验证，这里重启 PHP 并核对服务仍在运行，
# 重启失败则撤回 ini。扩展已可加载时不重复构建。返回 0 就绪，1 失败。
Addons_Apply_Ext()
{
    local ext="$1" title="$2" so ini module reason=''

    IFS=$'\t' read -r so ini module < <(PHPExt_Files "${ext}") || {
        Echo_Red "未知的 PHP 扩展：${ext}"
        return 1
    }
    if PHPExt_Check "${PHP_Path}" "${ext}"; then
        Echo_Green "${title} 已安装并可加载，无需重复安装。"
        return 0
    fi

    if ! PHPExt_Reinstall "${PHP_Path}" "${ext}" reason; then
        Echo_Red "${title} 安装失败！（${reason:-构建失败}）"
        return 1
    fi

    if ! Restart_PHP; then
        Echo_Red "PHP 模块 ${module} 可加载，但重启 PHP 服务失败，已删除 ${ini}。"
        Echo_Red "撤回配置后重新启动服务，请再执行 lnmp status 复查。"
        rm -f "${PHP_Path}/conf.d/${ini}"
        Restart_PHP
        return 1
    fi
    return 0
}

# Addons_Install_Ext <扩展名> <显示名>：单个 PHP 扩展的安装入口，确认后经模块安装并验收。
Addons_Install_Ext()
{
    local ext="$1" title="$2"

    echo "====== 正在安装 ${title} ======"
    Press_Start || return 1
    Addons_Apply_Ext "${ext}" "${title}" || return 1
    Echo_Green "====== ${title} 安装完成 ======"
    Echo_Green "${title} 安装成功。"
    return 0
}

# Addons_Remove_Ext <扩展名> <显示名>：删除本包写入的 ini 与产物并重启 PHP。
Addons_Remove_Ext()
{
    local ext="$1" title="$2"

    echo "即将卸载 ${title}..."
    Press_Start || return 1
    if ! PHPExt_Remove "${PHP_Path}" "${ext}"; then
        Echo_Red "${title} 的文件删除失败。"
        return 1
    fi
    Restart_PHP
    Echo_Green "${title} 卸载完成。"
}

# Redis：服务端由 include/redis.sh 的 Redis_* 接口安装，phpredis 经扩展模块安装。
Install_Redis()
{
    local srv_rc

    echo "====== 正在安装 Redis ======"
    echo "正在安装稳定版 ${Redis_Stable_Ver}..."
    Check_Redis_Mode || return 1
    Print_Redis_Install_Summary
    Press_Start || return 1

    # 扩展包先取齐再动系统，避免服务端装完后扩展下载失败，留下未启用的服务和防火墙规则。
    Addons_Prefetch_Ext redis || return 1

    Redis_Install
    srv_rc=$?
    if [ "${srv_rc}" -eq 1 ]; then
        Echo_Red "Redis 安装失败！"
        return 1
    fi

    # 扩展失败时保留已装好的服务端，由返回码与提示告知。
    if ! Addons_Apply_Ext redis "phpredis 扩展"; then
        Echo_Red "phpredis 扩展没有装成，Redis 服务端已安装。可重试：./addons.sh install redis"
        return 1
    fi

    # 测试页无鉴权、暴露 Redis 版本且会写入缓存，因此默认不部署。
    if [ "${Enable_Redis_Test_Page}" = "y" ]; then
        echo "正在复制 Redis PHP 测试文件..."
        \cp "${cur_dir}/conf/redis.php" "${Default_Website_Dir}/redis.php"
        sed -i "s/', 6379)/', ${Redis_Port})/" "${Default_Website_Dir}/redis.php"
        Warn_Demo_Page_Not_Served redis.php
    else
        echo "未部署 Redis 测试页面（Enable_Redis_Test_Page='n'）。"
        echo "如需自测：cp conf/redis.php ${Default_Website_Dir}/redis.php"
    fi

    if [ "${srv_rc}" -eq 0 ]; then
        Echo_Green "====== Redis 安装完成 ======"
        Echo_Green "Redis 安装成功。"
        return 0
    fi
    Print_Redis_Start_Failure
    return 1
}

Uninstall_Redis()
{
    local f

    echo "即将卸载 Redis..."
    Press_Start || return 1

    PHPExt_Remove "${PHP_Path}" redis
    for f in "${PHP_Path}"/conf.d/*redis.ini; do
        [ -e "${f}" ] && Echo_Yellow "发现非本包创建的 PHP 配置：${f}，未删除。"
    done
    Restart_PHP
    echo "正在删除 Redis 文件..."
    Redis_Remove
    Echo_Green "Redis 卸载完成。"
}

# Memcached：服务端由 include/memcached.sh 的 Memcached_* 接口安装，
# PHP 扩展（memcache 或 memcached）经扩展模块安装。
Install_Memcached()
{
    # ver 同时决定扩展分支和测试页文件名 conf/memcached${ver}.php，编号不可调换。
    local ver ext srv_rc ext_rc=0

    echo "请选择要安装的 Memcached PHP 扩展："
    echo "1：安装 php-memcache （上游 2023-04-30 后停更， PHP 8.5 需本地补丁）"
    echo "2：安装 php-memcached （上游活跃，安装时另需编译 libmemcached ）"
    echo "两者 API 不兼容：php-memcache 用 Memcache 类， php-memcached 用 Memcached 类。"
    echo "已有站点代码用哪个类，就选哪个。"
    read -p "请输入 1 或 2 [默认 2]：" ver

    if [ "${ver}" = "1" ]; then
        echo "已选择 php-memcache 。"
        ext=memcache
    elif [ "${ver}" = "2" ]; then
        echo "已选择 php-memcached 。"
        ext=memcached
    else
        ver="2"
        echo "未输入或输入无效，使用默认项 php-memcached 。"
        ext=memcached
    fi
    PHP_ZTS="${ext}.so"

    echo "====== 正在安装 Memcached ======"
    Print_Memcached_Install_Summary
    Press_Start || return 1

    Addons_Prefetch_Ext "${ext}" || return 1

    Memcached_Install
    srv_rc=$?
    if [ "${srv_rc}" -eq 1 ]; then
        Echo_Red "Memcached 安装失败！"
        return 1
    fi

    # 扩展失败后仍报告服务端状态，便于分别定位。
    Addons_Apply_Ext "${ext}" "PHP 扩展 ${ext}" || ext_rc=1

    # 测试页无鉴权且会读写缓存，可能暴露 Memcached 的可用状态，因此默认不部署。
    if [ "${Enable_Memcached_Test_Page}" = "y" ]; then
        echo "正在复制 Memcached PHP 测试文件..."
        \cp "${cur_dir}/conf/memcached${ver}.php" "${Default_Website_Dir}/memcached.php"
        Warn_Demo_Page_Not_Served memcached.php
    else
        echo "未部署 Memcached 测试页面（Enable_Memcached_Test_Page='n'）。"
        echo "如需自测：cp conf/memcached${ver}.php ${Default_Website_Dir}/memcached.php"
    fi

    if [ "${srv_rc}" -eq 0 ] && [ "${ext_rc}" -eq 0 ]; then
        Echo_Green "====== Memcached 安装完成 ======"
        Echo_Green "Memcached 安装成功。"
        Tune_Advise_PHP_Pools
        return 0
    fi
    [ "${srv_rc}" -eq 0 ] && Echo_Green "memcached 服务端已安装并在运行。"
    [ "${srv_rc}" -ne 0 ] && Echo_Red "memcached 服务端已安装，但服务没能启动。"
    [ "${ext_rc}" -ne 0 ] && Echo_Red "PHP 扩展 ${PHP_ZTS} 没有装成。"
    Echo_Red "Memcached 安装失败！"
    return 1
}

Uninstall_Memcached()
{
    echo "即将卸载 Memcached..."
    Press_Start || return 1
    PHPExt_Remove "${PHP_Path}" memcached
    PHPExt_Remove "${PHP_Path}" memcache
    Restart_PHP
    echo "正在删除 Memcached 文件..."
    Memcached_Remove
    Echo_Green "Memcached 卸载完成。"
}

# Node.js：官方二进制按主版本并存于 /usr/local/nodejs/<主版本>，不依赖 PHP，也不进入全局 PATH。
Print_Nodejs_Majors()
{
    local m

    for m in ${Nodejs_Majors}; do
        case "${m}" in
        22) echo "  ${m}：${Nodejs_22_Ver}（维护期 LTS，上游 2027-04 停止支持）" ;;
        24) echo "  ${m}：${Nodejs_24_Ver}（LTS，上游 2028-04 停止支持）" ;;
        *)  echo "  ${m}：$(Nodejs_Version "${m}")" ;;
        esac
    done
}

Install_Nodejs()
{
    local input="$1" major cur rc

    if [ -z "${input}" ]; then
        echo "请选择 Node.js 主版本（可并存，已安装的主版本会按固定版本补齐或升级）："
        Print_Nodejs_Majors
        read -p "请输入主版本 [默认 ${Nodejs_Default_Major}]：" input
        input="${input:-${Nodejs_Default_Major}}"
    fi
    if ! major=$(Nodejs_Resolve "${input}"); then
        Echo_Red "不支持的 Node.js 版本：${input}"
        echo "可选主版本："
        Print_Nodejs_Majors
        return 1
    fi

    echo "====== 正在安装 Node.js ${major} ======"
    cur=$(Nodejs_Installed "${major}") && echo "当前已装：${cur}，目标版本：$(Nodejs_Version "${major}")"
    echo "安装目录：/usr/local/nodejs/${major}（不创建全局 node 链接）"
    Press_Start || return 1

    Nodejs_Install "${major}"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        Echo_Red "Node.js ${major} 安装失败（返回码 ${rc}）。"
        [ "${rc}" -eq 2 ] && Echo_Red "换入后旧目录未能恢复，请检查 /usr/local/nodejs/.old.${major}.*。"
        return 1
    fi
    if ! Nodejs_Verify "${major}"; then
        Echo_Red "Node.js ${major} 已落盘，但 node 或 npm 无法运行。"
        return 1
    fi
    Echo_Green "====== Node.js $(Nodejs_Installed "${major}") 安装完成 ======"
    echo "解释器：/usr/local/nodejs/${major}/bin/node"
    echo "托管应用：lnmp app add，启动命令填写 /usr/local/nodejs/${major}/bin/node <入口脚本>"
    echo "已运行的应用不会自动切换到新补丁版本，需执行 lnmp app restart <应用名>。"
    return 0
}

Uninstall_Nodejs()
{
    local input="$1" major users m installed='' rc

    if [ -z "${input}" ]; then
        for m in ${Nodejs_Majors}; do
            [ -d "/usr/local/nodejs/${m}" ] && installed="${installed} ${m}"
        done
        if [ -z "${installed}" ]; then
            echo "未安装 Node.js。"
            return 0
        fi
        echo "已安装的 Node.js 主版本：${installed# }"
        read -p "请输入要卸载的主版本：" input
    fi
    if ! major=$(Nodejs_Resolve "${input}"); then
        Echo_Red "不支持的 Node.js 版本：${input}"
        return 1
    fi

    echo "即将卸载 Node.js ${major}（/usr/local/nodejs/${major}）..."
    Press_Start || return 1
    Nodejs_Remove "${major}"
    rc=$?
    case "${rc}" in
    0) Echo_Green "Node.js ${major} 卸载完成。" ;;
    1) echo "Node.js ${major} 未安装。" ;;
    4)
        users=$(Nodejs_Users "${major}" | tr '\n' ' ')
        Echo_Red "以下应用仍在使用 Node.js ${major}，已拒绝卸载：${users}"
        Echo_Yellow "请先执行 lnmp app del <应用名>，或改用其它版本的启动命令。"
        return 1
        ;;
    *) Echo_Red "Node.js ${major} 卸载失败（返回码 ${rc}）。"; return 1 ;;
    esac
    return 0
}

# Pm2_Pick_Major <输入>：输出 PM2 操作的 Node.js 主版本。未指定时只有一个已装版本则取该版本，
# 多个已装版本时询问，默认取 Nodejs_Default_Major（已装）或第一个。
Pm2_Pick_Major()
{
    local input="$1" m list='' def major

    for m in ${Nodejs_Majors}; do
        [ -x "/usr/local/nodejs/${m}/bin/node" ] && list="${list} ${m}"
    done
    list=${list# }
    if [ -z "${list}" ]; then
        Echo_Red "尚未安装 Node.js，请先执行 ./addons.sh install nodejs。" >&2
        return 1
    fi
    if [ -z "${input}" ]; then
        case "${list}" in
        *\ *)
            def=${Nodejs_Default_Major}
            case " ${list} " in *" ${def} "*) ;; *) def=${list%% *} ;; esac
            echo "已安装的 Node.js 主版本：${list}" >&2
            read -p "请输入主版本 [默认 ${def}]：" input
            input="${input:-${def}}"
            ;;
        *) input="${list}" ;;
        esac
    fi
    if ! major=$(Nodejs_Resolve "${input}"); then
        Echo_Red "不支持的 Node.js 版本：${input}" >&2
        return 1
    fi
    case " ${list} " in
    *" ${major} "*) printf '%s\n' "${major}" ;;
    *) Echo_Red "Node.js ${major} 尚未安装，请先执行 ./addons.sh install nodejs ${major}。" >&2; return 1 ;;
    esac
}

Install_Pm2()
{
    local major ver rc

    major=$(Pm2_Pick_Major "$1") || return 1
    if ver=$(Nodejs_Pm2_Version "${major}"); then
        echo "Node.js ${major} 已安装 PM2 ${ver}，未做更改（升级请先 uninstall 再 install）。"
        return 0
    fi
    echo "====== 正在安装 PM2 到 Node.js ${major} ======"
    echo "经 npm registry 安装最新版本，不在固定版本与校验清单范围内。"
    Press_Start || return 1
    Nodejs_Pm2_Install "${major}"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        Echo_Red "PM2 安装失败（返回码 ${rc}）。"
        return 1
    fi
    Echo_Green "====== PM2 $(Nodejs_Pm2_Version "${major}") 安装完成 ======"
    echo "托管应用：lnmp app add，启动命令填写 /usr/local/nodejs/${major}/bin/pm2-runtime start <ecosystem 文件>"
    echo "平滑重载：lnmp app reload <应用名>；进程列表：lnmp app status <应用名>"
    return 0
}

Uninstall_Pm2()
{
    local major users rc

    major=$(Pm2_Pick_Major "$1") || return 1
    echo "即将卸载 Node.js ${major} 下的 PM2..."
    Press_Start || return 1
    Nodejs_Pm2_Remove "${major}"
    rc=$?
    case "${rc}" in
    0) Echo_Green "PM2 卸载完成。" ;;
    1) echo "Node.js ${major} 未安装 PM2。" ;;
    4)
        users=$(Nodejs_Pm2_Users "${major}" | tr '\n' ' ')
        Echo_Red "以下应用仍由 PM2 托管，已拒绝卸载：${users}"
        Echo_Yellow "请先执行 lnmp app del <应用名>。"
        return 1
        ;;
    *) Echo_Red "PM2 卸载失败（返回码 ${rc}）。"; return 1 ;;
    esac
    return 0
}

clear 2>/dev/null || true
Print_Banner \
    "LNMP V${LNMP_Ver} 附加组件管理" \
    "安装缓存、优化器、加速器等附加组件" \
    "仅使用上游官方源码，并强制校验完整性"

# 可与主 PHP 并存的附加版本。编号按已安装版本动态生成，不写死在菜单里：
# 接受未安装的编号会把 PHP_Path 指向不存在的目录，后续 phpize 与 ini 写入全部失败。
Addons_PHP_Version_List="5.2 5.3 5.4 5.5 5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4 8.5"

# 二进制、Nginx include 和 init 脚本三者齐备才算这个版本可用。
Addons_PHP_Installed()
{
    local ver="$1"

    [ -s "/usr/local/php${ver}/sbin/php-fpm" ] \
        && [ -s "/usr/local/nginx/conf/enable-php${ver}.conf" ] \
        && [ -s "/etc/init.d/php-fpm${ver}" ]
}

# 输出已安装的附加 PHP 版本，供菜单和选择校验共用。
Addons_PHP_Installed_List()
{
    local ver out=''

    for ver in ${Addons_PHP_Version_List}; do
        Addons_PHP_Installed "${ver}" && out="${out:+${out} }${ver}"
    done
    printf '%s' "${out}"
}

Select_PHP()
{
    local installed ver idx choice sel_ver

    if [ "${action2}" == "exit" ]; then
        exit 1
    fi

    installed="$(Addons_PHP_Installed_List)"
    if [ -z "${installed}" ]; then
        PHP_Path='/usr/local/php'
        PHPFPM_Initd='/etc/init.d/php-fpm'
        return 0
    fi

    echo "检测到多个 PHP 版本，请选择要操作的版本。"
    Cur_PHP_Version="$(/usr/local/php/bin/php-config --version)"
    Echo_Green "1: 默认主 PHP ${Cur_PHP_Version}"
    idx=1
    for ver in ${installed}; do
        idx=$((idx + 1))
        Echo_Green "${idx}: PHP ${ver} [已安装]"
    done

    while :;do
        Echo_Yellow "请选择 [1-${idx}]（默认 1，主 PHP）："
        if ! read -r choice; then
            echo
            choice=''
        fi
        if [ -z "${choice}" ]; then
            echo "未输入，默认选择主 PHP ${Cur_PHP_Version}。"
            choice=1
        fi
        case "${choice}" in
        *[!0-9]*)
            Echo_Red "请输入 1 到 ${idx} 之间的编号。"
            continue
            ;;
        esac
        if [ "${choice}" -lt 1 ] || [ "${choice}" -gt "${idx}" ]; then
            Echo_Red "只能选择上面列出的编号 1 到 ${idx}。"
            continue
        fi
        break
    done

    php_select="${choice}"
    if [ "${choice}" = "1" ]; then
        echo "当前选择：PHP ${Cur_PHP_Version}"
        PHP_Path='/usr/local/php'
        PHPFPM_Initd='/etc/init.d/php-fpm'
        return 0
    fi
    sel_ver=$(printf '%s\n' ${installed} | sed -n "$((choice - 1))p")
    echo "当前选择：PHP $(/usr/local/php${sel_ver}/bin/php-config --version)"
    PHP_Path="/usr/local/php${sel_ver}"
    PHPFPM_Initd="/etc/init.d/php-fpm${sel_ver}"
    return 0
}

# 扩展需要当前 PHP 的编译环境。缺少 PHP 时必须在安装服务端、init 脚本和
# systemd unit 之前退出，避免留下未完成的安装。
Check_PHP_Installed()
{
    [ -x "${PHP_Path}/bin/php-config" ] && return 0

    Echo_Red "没有找到 PHP：${PHP_Path}/bin/php-config 不存在。"
    Echo_Red "addons.sh 安装的都是 PHP 扩展，必须先装好 PHP 再来装它们："
    Echo_Red "  完整安装：      ./install.sh lnmp"
    Echo_Red "  只加 PHP 版本： ./install.sh mphp"
    Echo_Red "装好 PHP 后重新执行本命令。"
    return 1
}

Addons_Get_PHP_Ext_Dir()
{
    Cur_PHP_Version="`${PHP_Path}/bin/php-config --version`"
    zend_ext_dir="`${PHP_Path}/bin/php-config --extension-dir`/"
}

if [[ "${action}" == "" || "${action2}" == "" ]]; then
    action='install'
    Display_Addons_Menu
fi
# Node.js 与 PHP 无关：不选择 PHP 实例，也不要求已安装 PHP。
case "${action}:${action2}" in
install:14|install:[nN]ode[jJ][sS])
    Install_Nodejs "$3"
    exit $?
    ;;
uninstall:14|uninstall:[nN]ode[jJ][sS])
    Uninstall_Nodejs "$3"
    exit $?
    ;;
install:15|install:[pP][mM]2)
    Install_Pm2 "$3"
    exit $?
    ;;
uninstall:15|uninstall:[pP][mM]2)
    Uninstall_Pm2 "$3"
    exit $?
    ;;
esac
Get_Dist_Name
Select_PHP

    case "${action}" in
    install)
        # 安装依赖 PHP；卸载允许在 PHP 不存在时清理残留。
        Check_PHP_Installed || exit 1
        case "${action2}" in
            1|[mM]emcached)
                Install_Memcached
                ;;
            2|opcache)
                Install_Opcache
                ;;
            3|[rR]edis)
                Install_Redis
                ;;
            4|apcu)
                Install_Apcu
                ;;
            5|image[mM]agick)
                Install_ImageMagic
                ;;
            6|ion[cC]ube)
                ionCube_NotWired_Notice
                exit 1
                ;;
            7|[eE]xif)
                Install_PHP_Exif
                ;;
            8|[fF]ileinfo)
                Install_PHP_Fileinfo
                ;;
            9|[lL]dap)
                Install_PHP_Ldap
                ;;
            10|[bB]z2)
                Install_PHP_Bz2
                ;;
            11|[sS]odium)
                Install_PHP_Sodium
                ;;
            12|[iI]map)
                Echo_Red "LNMP ${LNMP_Ver} 已移除 imap 扩展的安装。"
                Echo_Red "原因：依赖的 UW c-client 已停止维护，Debian 13 软件源不再提供；PHP 8.4 起源码不含 ext/imap。"
                Echo_Red "已安装的 imap 扩展可执行 ./addons.sh uninstall imap 移除。"
                exit 1
                ;;
            13|[sS]woole)
                Install_PHP_Swoole
                ;;
            e[aA]ccelerator|[xX]cache|[sS][gG]|[sS]ource[gG]uardian)
                Echo_Red "LNMP ${LNMP_Ver} 已移除 '${action2}'。"
                Echo_Red "原因：仅支持已经停止维护的 PHP 5.x，或属于没有官方公开下载源的闭源组件。"
                exit 1
                ;;
            [eE][xX][iI][tT])
                exit 1
                ;;
            *)
                # 非法子命令返回非零状态，便于自动化调用识别未执行安装。
                echo "用法：./addons.sh install {memcached|opcache|redis|apcu|imagemagick|ioncube|exif|fileinfo|ldap|bz2|sodium|swoole|nodejs|pm2}"
                exit 1
                ;;
        esac
        ;;
    uninstall)
        case "${action2}" in
            [mM]emcached)
                Uninstall_Memcached
                ;;
            opcache)
                Uninstall_Opcache
                ;;
            [rR]edis)
                Uninstall_Redis
                ;;
            apcu)
                Uninstall_Apcu
                ;;
            image[mM]agick)
                Uninstall_ImageMagick
                ;;
            ion[cC]ube)
                Uninstall_ionCube
                ;;
            # 扩展卸载仅移除对应配置和已安装文件。
            [eE]xif)
                Uninstall_PHP_Exif
                ;;
            [fF]ileinfo)
                Uninstall_PHP_Fileinfo
                ;;
            [lL]dap)
                Uninstall_PHP_Ldap
                ;;
            [bB]z2)
                Uninstall_PHP_Bz2
                ;;
            [sS]odium)
                Uninstall_PHP_Sodium
                ;;
            [iI]map)
                Uninstall_PHP_Imap
                ;;
            [sS]woole)
                Uninstall_PHP_Swoole
                ;;
            *)
                echo "用法：./addons.sh uninstall {memcached|opcache|redis|apcu|imagemagick|ioncube|exif|fileinfo|ldap|bz2|sodium|imap|swoole|nodejs|pm2}"
                exit 1
                ;;
        esac
        ;;
    [eE][xX][iI][tT])
        exit 1
        ;;
    *)
        echo "用法：./addons.sh {install|uninstall} {memcached|opcache|redis|apcu|imagemagick|ioncube|exif|fileinfo|ldap|bz2|sodium|swoole|nodejs|pm2}"
        exit 1
        ;;
    esac

# 显式返回安装函数的状态，确保自动化调用能够识别安装失败。
Addons_Rc=$?
exit ${Addons_Rc}
