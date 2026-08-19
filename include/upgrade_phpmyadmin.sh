#!/usr/bin/env bash

Upgrade_phpMyAdmin()
{
    phpMyAdmin_Version=""
    echo "可在 https://www.phpmyadmin.net/downloads/ 查看可用版本号。"
    read -p "请输入目标 phpMyAdmin 版本（例如 5.2.2）：" phpMyAdmin_Version
    if [ "${phpMyAdmin_Version}" = "" ]; then
        echo "错误：必须输入 phpMyAdmin 版本号！"
        exit 1
    fi
    Check_Version_String "${phpMyAdmin_Version}" "phpMyAdmin 版本号" || exit 1
    Print_Banner "即将把 phpMyAdmin 升级到 ${phpMyAdmin_Version}"

    Press_Start || exit 1

    echo "============================ 检查文件 ============================"
    cd ${cur_dir}/src

    if ! Download_Verified phpmyadmin "${phpMyAdmin_Version}" \
         "https://files.phpmyadmin.net/phpMyAdmin/${phpMyAdmin_Version}/phpMyAdmin-${phpMyAdmin_Version}-all-languages.tar.xz" \
         "phpMyAdmin-${phpMyAdmin_Version}-all-languages.tar.xz"; then
        echo "输入的 phpMyAdmin 版本为：${phpMyAdmin_Version}"
        Echo_Red "错误！下载或校验失败，请检查版本号。"
        exit 1
    fi
    echo "============================ 文件检查结束 ========================"

    local pma_src="phpMyAdmin-${phpMyAdmin_Version}-all-languages"
    # 程序目录和备份均位于网站根目录之外，防止旧版源码被直接下载。
    local pma_live="${PhpMyAdmin_Dir}"
    local pma_bak="${PhpMyAdmin_Dir}.bak.${Upgrade_Date}"
    local stage="${cur_dir}/src/.pma-stage.$$"

    rm -rf "${stage}"
    mkdir -p "${stage}" || exit 1

    echo "正在解压 ${pma_src}.tar.xz..."
    if ! tar Jxf "${pma_src}.tar.xz" -C "${stage}"; then
        Echo_Red "解压失败，线上 phpMyAdmin 未做任何改动。"
        rm -rf "${stage}"
        exit 1
    fi
    # 归档顶层目录和入口文件必须符合目标版本结构。
    if [ ! -s "${stage}/${pma_src}/index.php" ]; then
        Echo_Red "归档结构异常：未找到 ${pma_src}/index.php"
        Echo_Red "线上 phpMyAdmin 未做任何改动。"
        rm -rf "${stage}"
        exit 1
    fi

    # 在暂存目录完成配置后再切换当前版本。
    \cp "${cur_dir}/conf/config.inc.php" "${stage}/${pma_src}/config.inc.php" || {
        Echo_Red "写入 config.inc.php 失败，线上未改动。"; rm -rf "${stage}"; exit 1; }

    sed -i "s/LNMPORG/$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')/g" "${stage}/${pma_src}/config.inc.php"
    # 使用数据库实际监听端口，避免 lnmp.conf 默认值覆盖安装时的自定义端口。
    local db_port
    db_port=$(Get_Actual_DB_Port) || \
        Echo_Yellow "未能从 /etc/my.cnf 读到数据库端口，按 lnmp.conf 的 ${db_port} 写入。"
    [ "${db_port}" = "${DB_Port}" ] || \
        Echo_Yellow "数据库实际端口为 ${db_port}（lnmp.conf 记的是 ${DB_Port}），按实际端口写入。"
    sed -i "s/LNMP_DB_PORT/${db_port}/g" "${stage}/${pma_src}/config.inc.php"
    if grep -qE 'LNMPORG|LNMP_DB_PORT' "${stage}/${pma_src}/config.inc.php"; then
        Echo_Red "config.inc.php 中的占位符未全部替换，线上未改动。"
        rm -rf "${stage}"
        exit 1
    fi
    # 模板缓存位于网站根目录之外，且不创建公开的 upload/save 数据目录。
    mkdir -p /var/lib/phpmyadmin/tmp
    chown -R www:www /var/lib/phpmyadmin
    chmod 700 /var/lib/phpmyadmin/tmp
    chmod 755 -R "${stage}/${pma_src}/"
    chown www:www -R "${stage}/${pma_src}/"

    echo "正在把旧 phpMyAdmin 备份到 ${pma_bak}..."
    if [ -d "${pma_live}" ]; then
        if ! mv "${pma_live}" "${pma_bak}"; then
            Echo_Red "备份原 phpMyAdmin 目录失败，放弃升级（线上未改动）。"
            rm -rf "${stage}"
            exit 1
        fi
    fi

    if ! mv "${stage}/${pma_src}" "${pma_live}"; then
        Echo_Red "部署新 phpMyAdmin 失败，正在恢复原目录..."
        [ -d "${pma_bak}" ] && mv "${pma_bak}" "${pma_live}"
        rm -rf "${stage}"
        exit 1
    fi
    rm -rf "${stage}"

    # 保留原随机访问路径及权限，使现有 Web 映射和 lnmp status 继续可用。
    if [ -s "${pma_bak}/.access_url" ]; then
        \cp "${pma_bak}/.access_url" "${pma_live}/.access_url"
        chown www:www "${pma_live}/.access_url"
        chmod 600 "${pma_live}/.access_url"
    fi

    Echo_Green "======== phpMyAdmin 升级完成 ======"
    Echo_Green "原目录保留在 ${pma_bak}，确认无误后可自行删除。"
    [ -s "${pma_live}/.access_url" ] && \
        Echo_Green "访问路径不变：http://<服务器IP>/$(cat ${pma_live}/.access_url)/"
    return 0
}
