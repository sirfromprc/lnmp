#!/usr/bin/env bash

Install_Multiplephp()
{
    Get_Dist_Name
    Check_DB
    Check_Stack
    Get_Dist_Version

    case "${Get_Stack}" in
    lnmp) ;;
    lnmpa|lamp)
        # 存量 mod_php 机器的 PHP 由 Apache 加载，无法并存其它 PHP-FPM 版本。
        if [ "$(PHP_Detect_Sapi "${Get_Stack}")" != fpm ]; then
            echo "当前 PHP 以 Apache 模块（mod_php）方式运行，不支持多版本 PHP！"
            exit 1
        fi
        ;;
    *)
        echo "未识别到已安装的 LNMP、LNMPA 或 LAMP，无法安装多版本 PHP！"
        exit 1
        ;;
    esac

    # 选择需要并行安装的 PHP 版本。
    echo "==========================="

    PHPSelect=""
    Print_PHP_Menu
    read -p "请选择 [1-${PHP_Count}]：" PHPSelect

    if ! Set_PHP_Profile "${PHPSelect}"; then
        echo "未输入选项，必须选择一个 PHP 版本。"
        exit 1
    fi
    echo "即将安装 ${PHP_Info[$((PHPSelect-1))]}"

    Press_Install
    if [ -d "${MPHP_Path}" ]; then
        echo "${Php_Ver} 已存在！"
        exit 1
    fi
    cat /etc/issue
    cat /etc/*-release

    # 返回安装命令的退出码，避免 tee 成功掩盖安装失败。
    Install_MPHP_Instance 2>&1 | tee /root/install-mphp${PHP_Branch}.log
    return ${PIPESTATUS[0]}
}

# 安装 MPHP_Path 下的实例，接入启动项与 Nginx 片段。
# 实例安装失败时由 PHP 模块删除本次写入的文件，重试无需手工清理。
Install_MPHP_Instance()
{
    local tune

    # 新实例尚未被站点引用，按即将投入使用计算份额。
    Tune_Assume_MPHP="${MPHP_Path}"
    tune=$(Tune_PHP_Spec mphp)
    if ! PHP_Install "${MPHP_Path}" fpm "${Php_Ver#php-}" "${tune}"; then
        Echo_Red "${Php_Ver} 安装失败，详情请查看 /root/install-mphp${PHP_Branch}.log。"
        return 1
    fi
    # 默认扩展与主版本共用同一接口；单个扩展失败只告警，不中止实例安装。
    Install_PHP_Default_Ext "${MPHP_Path}" "${tune##*:}" \
        || Echo_Yellow "默认扩展未能安装，可稍后用 ./addons.sh install 补装。"

    StartUp "php-fpm@${PHP_Branch}"
    # Nginx 直连 PHP-FPM 的 LNMP 才需要 enable-php 片段，Apache 栈在站点配置中指定 socket。
    if [ "${Get_Stack}" = lnmp ]; then
        \cp "${cur_dir}/conf/enable-php${PHP_Branch}.conf" "/usr/local/nginx/conf/enable-php${PHP_Branch}.conf" || return 1
    fi

    sleep 2

    lnmp start

    echo "==========================================="
    Echo_Green "${Php_Ver} 安装成功。"
    echo "==========================================="
    Tune_Advise_PHP_Pools
    return 0
}
