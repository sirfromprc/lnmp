#!/usr/bin/env bash

Upgrade_phpMyAdmin()
{
    phpMyAdmin_Version=""
    echo "You can get version number from https://www.phpmyadmin.net/downloads/"
    read -p "Please enter phpMyAdmin version you want, (example: 4.8.0 ): " phpMyAdmin_Version
    if [ "${phpMyAdmin_Version}" = "" ]; then
        echo "Error: You must enter a phpMyAdmin version!!"
        exit 1
    fi
    echo "+---------------------------------------------------------+"
    echo "|   You will upgrade phpMyAdmin version to ${phpMyAdmin_Version}"
    echo "+---------------------------------------------------------+"

    Press_Start

    echo "============================check files=================================="
    cd ${cur_dir}/src

    if ! Download_Verified phpmyadmin "${phpMyAdmin_Version}" \
         "https://files.phpmyadmin.net/phpMyAdmin/${phpMyAdmin_Version}/phpMyAdmin-${phpMyAdmin_Version}-all-languages.tar.xz" \
         "phpMyAdmin-${phpMyAdmin_Version}-all-languages.tar.xz"; then
        echo "You enter phpMyAdmin Version was:"${phpMyAdmin_Version}
        Echo_Red "Error! 下载或校验失败，请检查版本号。"
        exit 1
    fi
    echo "============================check files=================================="

    local pma_src="phpMyAdmin-${phpMyAdmin_Version}-all-languages"
    # 线上目录与备份都在网站根目录之外：备份若落在根目录下，
    # 旧版本的整套源码就成了可直接下载的存档。
    local pma_live="${PhpMyAdmin_Dir}"
    local pma_bak="${PhpMyAdmin_Dir}.bak.${Upgrade_Date}"
    local stage="${cur_dir}/src/.pma-stage.$$"

    rm -rf "${stage}"
    mkdir -p "${stage}" || exit 1

    echo "Uncompress ${pma_src}.tar.xz ..."
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
    # 模板缓存目录在网站根目录之外，与 php.sh 的首装路径保持一致。
    # 网站目录下不再建 upload/save：导出的库转储落在那里就是公网可下载的。
    mkdir -p /var/lib/phpmyadmin/tmp
    chown -R www:www /var/lib/phpmyadmin
    chmod 700 /var/lib/phpmyadmin/tmp
    chmod 755 -R "${stage}/${pma_src}/"
    chown www:www -R "${stage}/${pma_src}/"

    echo "Backup old phpMyAdmin to ${pma_bak} ..."
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
    if [ -s "${pma_bak}/.access_url" ]; then
        \cp "${pma_bak}/.access_url" "${pma_live}/.access_url"
        chmod 600 "${pma_live}/.access_url"
    fi

    Echo_Green "======== upgrade phpMyAdmin completed ======"
    Echo_Green "原目录保留在 ${pma_bak}，确认无误后可自行删除。"
    [ -s "${pma_live}/.access_url" ] && \
        Echo_Green "访问路径不变：http://<服务器IP>/$(cat ${pma_live}/.access_url)/"
    return 0
}
