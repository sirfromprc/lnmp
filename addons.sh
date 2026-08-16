#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi

cur_dir=$(pwd)
action=$1
action2=$2

. lnmp.conf
. include/main.sh
. include/verify.sh
. include/firewall.sh
. include/profile.sh
. include/init.sh
. include/version.sh
. include/memcached.sh
. include/opcache.sh
. include/redis.sh
. include/imageMagick.sh
# ionCube 未接入安装流程。以下函数用于显示状态及清理既有安装。
. include/apcu.sh
. include/php_exif.sh
. include/php_fileinfo.sh
. include/php_ldap.sh
. include/php_bz2.sh
. include/php_sodium.sh
. include/php_imap.sh
. include/php_swoole.sh

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
    Press_Start
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

clear
Print_Banner \
    "LNMP V2.3 附加组件管理" \
    "安装缓存、优化器、加速器等附加组件" \
    "仅使用上游官方源码，并强制校验完整性"

Select_PHP()
{
    if [ "${action2}" == "exit" ]; then
        exit 1
    fi
    if [[ ! -s /usr/local/php5.2/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php5.2.conf ]] && [[ ! -s /usr/local/php5.3/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php5.3.conf ]] && [[ ! -s /usr/local/php5.4/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php5.4.conf ]] && [[ ! -s /usr/local/php5.5/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php5.5.conf ]] && [[ ! -s /usr/local/php5.6/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php5.6.conf ]] && [[ ! -s /usr/local/php7.0/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php7.0.conf ]] && [[ ! -s /usr/local/php7.1/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php7.1.conf ]] && [[ ! -s /usr/local/php7.2/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php7.2.conf ]] && [[ ! -s /usr/local/php7.3/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php7.3.conf ]] && [[ ! -s /usr/local/php7.4/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php7.4.conf ]] && [[ ! -s /usr/local/php8.0/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php8.0.conf ]] && [[ ! -s /usr/local/php8.1/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php8.1.conf ]] && [[ ! -s /usr/local/php8.2/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php8.2.conf ]] && [[ ! -s /usr/local/php8.3/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php8.3.conf ]] && [[ ! -s /usr/local/php8.4/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php8.4.conf ]] && [[ ! -s /usr/local/php8.5/sbin/php-fpm && ! -s /usr/local/nginx/conf/enable-php8.5.conf ]]; then
        PHP_Path='/usr/local/php'
        PHPFPM_Initd='/etc/init.d/php-fpm'
    else
        echo "检测到多个 PHP 版本，请选择要操作的版本。"
        Cur_PHP_Version="`/usr/local/php/bin/php-config --version`"
        Echo_Green "1: 默认主 PHP ${Cur_PHP_Version}"
        if [[ -s /usr/local/php5.2/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php5.2.conf && -s /etc/init.d/php-fpm5.2 ]]; then
            Echo_Green "2: PHP 5.2 [已安装]"
        fi
        if [[ -s /usr/local/php5.3/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php5.3.conf && -s /etc/init.d/php-fpm5.3 ]]; then
            Echo_Green "3: PHP 5.3 [已安装]"
        fi
        if [[ -s /usr/local/php5.4/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php5.4.conf && -s /etc/init.d/php-fpm5.4 ]]; then
            Echo_Green "4: PHP 5.4 [已安装]"
        fi
        if [[ -s /usr/local/php5.5/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php5.5.conf && -s /etc/init.d/php-fpm5.5 ]]; then
            Echo_Green "5: PHP 5.5 [已安装]"
        fi
        if [[ -s /usr/local/php5.6/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php5.6.conf && -s /etc/init.d/php-fpm5.6 ]]; then
            Echo_Green "6: PHP 5.6 [已安装]"
        fi
        if [[ -s /usr/local/php7.0/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php7.0.conf && -s /etc/init.d/php-fpm7.0 ]]; then
            Echo_Green "7: PHP 7.0 [已安装]"
        fi
        if [[ -s /usr/local/php7.1/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php7.1.conf && -s /etc/init.d/php-fpm7.1 ]]; then
            Echo_Green "8: PHP 7.1 [已安装]"
        fi
        if [[ -s /usr/local/php7.2/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php7.2.conf && -s /etc/init.d/php-fpm7.2 ]]; then
            Echo_Green "9: PHP 7.2 [已安装]"
        fi
        if [[ -s /usr/local/php7.3/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php7.3.conf && -s /etc/init.d/php-fpm7.3 ]]; then
            Echo_Green "10: PHP 7.3 [已安装]"
        fi
        if [[ -s /usr/local/php7.4/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php7.4.conf && -s /etc/init.d/php-fpm7.4 ]]; then
            Echo_Green "11: PHP 7.4 [已安装]"
        fi
        if [[ -s /usr/local/php8.0/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php8.0.conf && -s /etc/init.d/php-fpm8.0 ]]; then
            Echo_Green "12: PHP 8.0 [已安装]"
        fi
        if [[ -s /usr/local/php8.1/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php8.1.conf && -s /etc/init.d/php-fpm8.1 ]]; then
            Echo_Green "13: PHP 8.1 [已安装]"
        fi
        if [[ -s /usr/local/php8.2/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php8.2.conf && -s /etc/init.d/php-fpm8.2 ]]; then
            Echo_Green "14: PHP 8.2 [已安装]"
        fi
        if [[ -s /usr/local/php8.3/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php8.3.conf && -s /etc/init.d/php-fpm8.3 ]]; then
            Echo_Green "15: PHP 8.3 [已安装]"
        fi
        if [[ -s /usr/local/php8.4/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php8.4.conf && -s /etc/init.d/php-fpm8.4 ]]; then
            Echo_Green "16: PHP 8.4 [已安装]"
        fi
        if [[ -s /usr/local/php8.5/sbin/php-fpm && -s /usr/local/nginx/conf/enable-php8.5.conf && -s /etc/init.d/php-fpm8.5 ]]; then
            Echo_Green "17: PHP 8.5 [已安装]"
        fi
        Echo_Yellow "请选择 [1-17]（默认 1，主 PHP）："
        read php_select
        case "${php_select}" in
            1)
                echo "当前选择：PHP ${Cur_PHP_Version}"
                PHP_Path='/usr/local/php'
                PHPFPM_Initd='/etc/init.d/php-fpm'
                ;;
            2)
                echo "当前选择：PHP `/usr/local/php5.2/bin/php-config --version`"
                PHP_Path='/usr/local/php5.2'
                PHPFPM_Initd='/etc/init.d/php-fpm5.2'
                ;;
            3)
                echo "当前选择：PHP `/usr/local/php5.3/bin/php-config --version`"
                PHP_Path='/usr/local/php5.3'
                PHPFPM_Initd='/etc/init.d/php-fpm5.3'
                ;;
            4)
                echo "当前选择：PHP `/usr/local/php5.4/bin/php-config --version`"
                PHP_Path='/usr/local/php5.4'
                PHPFPM_Initd='/etc/init.d/php-fpm5.4'
                ;;
            5)
                echo "当前选择：PHP `/usr/local/php5.5/bin/php-config --version`"
                PHP_Path='/usr/local/php5.5'
                PHPFPM_Initd='/etc/init.d/php-fpm5.5'
                ;;
            6)
                echo "当前选择：PHP `/usr/local/php5.6/bin/php-config --version`"
                PHP_Path='/usr/local/php5.6'
                PHPFPM_Initd='/etc/init.d/php-fpm5.6'
                ;;
            7)
                echo "当前选择：PHP `/usr/local/php7.0/bin/php-config --version`"
                PHP_Path='/usr/local/php7.0'
                PHPFPM_Initd='/etc/init.d/php-fpm7.0'
                ;;
            8)
                echo "当前选择：PHP `/usr/local/php7.1/bin/php-config --version`"
                PHP_Path='/usr/local/php7.1'
                PHPFPM_Initd='/etc/init.d/php-fpm7.1'
                ;;
            9)
                echo "当前选择：PHP `/usr/local/php7.2/bin/php-config --version`"
                PHP_Path='/usr/local/php7.2'
                PHPFPM_Initd='/etc/init.d/php-fpm7.2'
                ;;
            10)
                echo "当前选择：PHP `/usr/local/php7.3/bin/php-config --version`"
                PHP_Path='/usr/local/php7.3'
                PHPFPM_Initd='/etc/init.d/php-fpm7.3'
                ;;
            11)
                echo "当前选择：PHP `/usr/local/php7.4/bin/php-config --version`"
                PHP_Path='/usr/local/php7.4'
                PHPFPM_Initd='/etc/init.d/php-fpm7.4'
                ;;
            12)
                echo "当前选择：PHP `/usr/local/php8.0/bin/php-config --version`"
                PHP_Path='/usr/local/php8.0'
                PHPFPM_Initd='/etc/init.d/php-fpm8.0'
                ;;
            13)
                echo "当前选择：PHP `/usr/local/php8.1/bin/php-config --version`"
                PHP_Path='/usr/local/php8.1'
                PHPFPM_Initd='/etc/init.d/php-fpm8.1'
                ;;
            14)
                echo "当前选择：PHP `/usr/local/php8.2/bin/php-config --version`"
                PHP_Path='/usr/local/php8.2'
                PHPFPM_Initd='/etc/init.d/php-fpm8.2'
                ;;
            15)
                echo "当前选择：PHP `/usr/local/php8.3/bin/php-config --version`"
                PHP_Path='/usr/local/php8.3'
                PHPFPM_Initd='/etc/init.d/php-fpm8.3'
                ;;
            16)
                echo "当前选择：PHP `/usr/local/php8.4/bin/php-config --version`"
                PHP_Path='/usr/local/php8.4'
                PHPFPM_Initd='/etc/init.d/php-fpm8.4'
                ;;
            17)
                echo "当前选择：PHP `/usr/local/php8.5/bin/php-config --version`"
                PHP_Path='/usr/local/php8.5'
                PHPFPM_Initd='/etc/init.d/php-fpm8.5'
                ;;
            *)
                echo "未输入，默认选择主 PHP ${Cur_PHP_Version}。"
                php_select="1"
                PHP_Path='/usr/local/php'
                PHPFPM_Initd='/etc/init.d/php-fpm'
                ;;
        esac
    fi
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
