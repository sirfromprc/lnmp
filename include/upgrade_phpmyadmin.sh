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
    Print_Banner "即将把 phpMyAdmin 升级到 ${phpMyAdmin_Version}"

    Press_Start

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
    # 线上目录与备份都在网站根目录之外：备份若落在根目录下，
    # 旧版本的整套源码就成了可直接下载的存档。
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
    # 归档顶层目录必须精确等于预期，否则说明拿到的不是预期内容
    if [ ! -s "${stage}/${pma_src}/index.php" ]; then
        Echo_Red "归档结构异常：未找到 ${pma_src}/index.php"
        Echo_Red "线上 phpMyAdmin 未做任何改动。"
        rm -rf "${stage}"
        exit 1
    fi

    # 配置与目录都在暂存区里准备好，确认无误后再一次性切换
    \cp "${cur_dir}/conf/config.inc.php" "${stage}/${pma_src}/config.inc.php" || {
        Echo_Red "写入 config.inc.php 失败，线上未改动。"; rm -rf "${stage}"; exit 1; }

    sed -i "s/LNMPORG/$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')/g" "${stage}/${pma_src}/config.inc.php"
    # 端口取本机实际值。升级时 lnmp.conf 的 DB_Port 往往只是默认值 3306，
    # 主栈当初若用环境变量指定过别的端口，照抄 lnmp.conf 会把能用的配置改坏。
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
    # 模板缓存目录在网站根目录之外，与 php.sh 的首装路径保持一致。
    # 网站目录下不再建 upload/save：导出的库转储落在那里就是公网可下载的。
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

    # 访问路径记录跟着搬过来，否则升级后 lnmp status 就查不到入口了。
    # Web 服务器上的映射片段用的还是同一个路径，无需重新生成。
    # 属主跟着程序目录一起给 www：首装时该文件就是 www:www 600，
    # 升级后若变成 root:root 会与首装结果不一致。
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
