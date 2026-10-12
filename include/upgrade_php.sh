#!/usr/bin/env bash
# PHP 升级入口：选择目标版本并确认，构建、换入与回滚由 include/mod/php.sh 的 PHP_Upgrade 完成。

Check_Stack_Choose()
{
    Check_Stack
    if [[ "${Get_Stack}" = "lnmp" && "${Stack}" = "" ]]; then
        echo "当前架构：${Get_Stack}，请执行：./upgrade.sh php"
        exit 1
    elif [[ "${Get_Stack}" = "lnmpa" || "${Get_Stack}" = "lamp" ]] && [[ "${Stack}" = "lnmp" ]]; then
        echo "当前架构：${Get_Stack}，请执行：./upgrade.sh phpa"
        exit 1
    elif [[ "${Stack}" = "" && "${Get_Stack}" != "lnmpa" && "${Get_Stack}" != "lamp" ]]; then
        echo "未识别到 LNMPA 或 LAMP 架构（当前：${Get_Stack}），不执行 PHP 升级。"
        exit 1
    fi
    [ "${Stack}" != "" ] || Stack="${Get_Stack}"
}

Upgrade_PHP()
{
    local sapi log=lnmp tune rc

    Check_Stack_Choose
    Check_DB
    php_version=""
    Get_PHP_Ext_Dir
    echo "当前 PHP 版本：${Cur_PHP_Version}"
    echo "可在 https://www.php.net/downloads 查看可用版本号。"
    read -p "请输入目标 PHP 版本：" php_version
    if [ "${php_version}" = "" ]; then
        echo "错误：必须输入正确的 PHP 版本号！"
        exit 1
    fi
    Check_Version_String "${php_version}" "PHP 版本号" || exit 1

    if ! echo "${php_version}" | grep -Eq '^8\.[0-9]+\.[0-9]+$'; then
        Echo_Red "仅支持 PHP 8.0.0 及以上版本，输入值：${php_version}"
        Echo_Red "支持范围：8.0.x、8.1.x、8.2.x、8.3.x、8.4.x、8.5.x"
        exit 1
    fi
    if ! Version_GE "${php_version}" 8.0; then
        Echo_Red "PHP ${php_version} 已停止生命周期支持，本项目不再支持。"
        exit 1
    fi

    Press_Start || exit 1

    [ "${Stack}" = "lnmp" ] || log=a
    sapi=$(PHP_Detect_Sapi "${Stack}")
    if [ $? -eq 2 ]; then
        Echo_Red "Apache 已加载 php_module，同时存在 php-fpm，无法确定网站使用的 PHP 形态，请先清理其一。"
        return 1
    fi
    tune=$(Tune_PHP_Spec main)
    PHP_Upgrade /usr/local/php "${sapi}" "${php_version}" "${tune}"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        Echo_Red "======== PHP 升级失败 ======"
        Echo_Red "PHP 升级日志：/root/upgrade_${log}_php${Upgrade_Date}.log"
        return "${rc}"
    fi
    Install_Composer
    return 0
}
