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

. "${cur_dir}/lnmp.conf"
. "${cur_dir}/include/main.sh"
. "${cur_dir}/include/verify.sh"
. "${cur_dir}/include/firewall.sh"
. "${cur_dir}/include/profile.sh"
. "${cur_dir}/include/init.sh"
. "${cur_dir}/include/version.sh"
. "${cur_dir}/include/memcached.sh"
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
    echo " 12: Imap"
    echo " 13: Swoole"
    echo "#################################################"
    echo " 输入 exit：退出当前脚本"
    echo "#################################################"
    read -p "请选择 [1-13]，或输入 exit 退出：" action2
}

Restart_PHP()
{
    local service

    if [ -s /usr/local/apache/bin/httpd ] && [ -s /usr/local/apache/conf/httpd.conf ] && [ -s /etc/init.d/httpd ]; then
        echo "正在重启 Apache......"
        service='httpd'
    else
        echo "正在重启 php-fpm......"
        service="${PHPFPM_Initd##*/}"
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

clear 2>/dev/null || true
Print_Banner \
    "LNMP V2.3 附加组件管理" \
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

Download_PHP_Src()
{
    # Download_Files 会复用已有文件并执行 SHA256 校验，缓存文件不得绕过校验。

    Download_Files https://www.php.net/distributions/php-${Cur_PHP_Version}.tar.bz2 php-${Cur_PHP_Version}.tar.bz2
    if [ $? -eq 0 ] && [ -s php-${Cur_PHP_Version}.tar.bz2 ]; then
        echo "php-${Cur_PHP_Version}.tar.bz2 校验通过。"
    else
        Echo_Red "错误：PHP ${Cur_PHP_Version} 下载或校验失败，请检查。"
        Echo_Red "如需手工放置 php-${Cur_PHP_Version}.tar.bz2 到 src 目录，"
        Echo_Red "请确保它的 SHA256 已登记在 src/checksums.sha256 里。"
        exit 1
    fi
}

if [[ "${action}" == "" || "${action2}" == "" ]]; then
    action='install'
    Display_Addons_Menu
fi
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
                Install_PHP_Imap
                ;;
            13|[sS]woole)
                Install_PHP_Swoole
                ;;
            e[aA]ccelerator|[xX]cache|[sS][gG]|[sS]ource[gG]uardian)
                Echo_Red "LNMP 2.3 已移除 '${action2}'。"
                Echo_Red "原因：仅支持已经停止维护的 PHP 5.x，或属于没有官方公开下载源的闭源组件。"
                exit 1
                ;;
            [eE][xX][iI][tT])
                exit 1
                ;;
            *)
                # 非法子命令返回非零状态，便于自动化调用识别未执行安装。
                echo "用法：./addons.sh install {memcached|opcache|redis|apcu|imagemagick|ioncube|exif|fileinfo|ldap|bz2|sodium|imap|swoole}"
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
                echo "用法：./addons.sh uninstall {memcached|opcache|redis|apcu|imagemagick|ioncube|exif|fileinfo|ldap|bz2|sodium|imap|swoole}"
                exit 1
                ;;
        esac
        ;;
    [eE][xX][iI][tT])
        exit 1
        ;;
    *)
        echo "用法：./addons.sh {install|uninstall} {memcached|opcache|redis|apcu|imagemagick|ioncube|exif|fileinfo|ldap|bz2|sodium|imap|swoole}"
        exit 1
        ;;
    esac

# 显式返回安装函数的状态，确保自动化调用能够识别安装失败。
Addons_Rc=$?
exit ${Addons_Rc}
