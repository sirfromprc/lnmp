#!/usr/bin/env bash
# 多版本 PHP 升级入口：选择已安装的实例与同分支目标版本，构建、换入与回滚由 PHP_Upgrade 完成。

Upgrade_Multiplephp()
{
    Get_Dist_Name
    Check_DB
    Check_Stack

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

    local i found_any=0 tune rc
    declare -a MPHP_Found_Branch

    echo "以下为已安装的多版本 PHP，请选择要升级的版本。"
    i=1
    while [ ${i} -le ${PHP_Count} ]; do
        Set_PHP_Profile "${i}"
        if [[ -s "${MPHP_Path}/sbin/php-fpm" && -s "/etc/init.d/php-fpm${PHP_Branch}" ]] \
           && { [ "${Get_Stack}" != lnmp ] || [ -s "/usr/local/nginx/conf/${Enable_PHP_Config}" ]; }; then
            Echo_Green "${i}：PHP ${PHP_Branch} [已找到]"
            MPHP_Found_Branch[${i}]="${PHP_Branch}"
            found_any=1
        fi
        i=$((i+1))
    done

    if [ ${found_any} -eq 0 ]; then
        echo "未找到多版本 PHP！"
        exit 1
    fi

    while :; do
        MPHP_Select=""
        if ! read -r -p "请选择要升级的多版本 PHP 序号：" MPHP_Select; then
            echo
            Echo_Red "读取多版本 PHP 序号时遇到 EOF —— 标准输入已经没有内容了，已中止。"
            exit 1
        fi
        if [ "${MPHP_Select}" = "" ]; then
            Echo_Red "错误：请输入数字！"
            continue
        fi
        if ! Set_PHP_Profile "${MPHP_Select}"; then
            Echo_Red "错误：选择无效。"
            continue
        fi
        if [ -z "${MPHP_Found_Branch[${MPHP_Select}]}" ]; then
            Echo_Red "错误：PHP ${PHP_Branch} 尚未安装。"
            continue
        fi
        break
    done

    # 后续步骤使用所选分支及对应安装路径。
    Cur_MPHP_Big_Ver="${PHP_Branch}"
    Cur_MPHP_Path="${MPHP_Path}"

    Echo_Yellow "注意：不能跨 PHP 分支升级！"

    php_version=""
    Cur_MPHP_Version=$("${Cur_MPHP_Path}/bin/php-config" --version)
    echo "当前 PHP 版本：${Cur_MPHP_Version}"
    echo "可在 https://www.php.net/downloads 查看可用版本号。"
    read -p "请输入目标 PHP 版本：" php_version
    if [ "${php_version}" = "" ]; then
        Echo_Red "错误：必须输入正确的 PHP 版本号！"
        exit 1
    fi
    Check_Version_String "${php_version}" "PHP 版本号" || exit 1

    # 仅接受与当前主次版本一致的 PHP 8.x 完整版本号。
    if ! echo "${php_version}" | grep -Eq '^8\.[0-9]+\.[0-9]+$'; then
        Echo_Red "仅支持 PHP 8.x，输入值：${php_version}"
        exit 1
    fi
    # 精确比较主次版本，避免相似字符串被识别为同一分支。
    if [ "$(echo "${php_version}" | cut -d. -f1-2)" != "${Cur_MPHP_Big_Ver}" ]; then
        Echo_Red "错误：不能跨 PHP 分支升级！"
        Echo_Red "当前分支为 ${Cur_MPHP_Big_Ver}，输入的目标版本为 ${php_version}"
        exit 1
    fi
    Echo_Blue "即将把 PHP ${Cur_MPHP_Version} 升级到 ${php_version}。"
    PHP_Unpatched_Warn "${Cur_MPHP_Big_Ver}"

    Press_Start || exit 1

    # Nginx 片段随升级刷新为当前模板，换入后的启动会加载它。
    if [ "${Get_Stack}" = lnmp ]; then
        \cp "${cur_dir}/conf/enable-php${Cur_MPHP_Big_Ver}.conf" "/usr/local/nginx/conf/enable-php${Cur_MPHP_Big_Ver}.conf"
    fi
    tune=$(Tune_PHP_Spec mphp)
    PHP_Upgrade "${Cur_MPHP_Path}" fpm "${php_version}" "${tune}"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        Echo_Red "PHP ${php_version} 升级失败，详情请查看 /root/upgrade_mphp${Upgrade_Date}.log。"
        return "${rc}"
    fi
    return 0
}
