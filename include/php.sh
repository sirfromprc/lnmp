#!/usr/bin/env bash

Install_Composer()
{
    local expected actual installer signature tmpdir php_bin

    if [ "${Enable_Composer:-y}" != 'y' ]; then
        echo "已按 Enable_Composer=${Enable_Composer} 跳过 Composer 安装。"
        return 0
    fi

    # 优先用本安装的 PHP：系统包管理器装的 php-cli 与本安装的扩展、php.ini 都不同，
    # 用它跑 Composer 会按另一套环境解析平台依赖。
    if [ -x /usr/local/php/bin/php ]; then
        php_bin=/usr/local/php/bin/php
    elif command -v php >/dev/null 2>&1; then
        php_bin=$(command -v php)
    else
        Echo_Red "未找到 PHP，跳过 Composer 安装。"
        return 1
    fi

    tmpdir=$(mktemp -d "${cur_dir}/src/composer.XXXXXX") || return 1
    installer="${tmpdir}/composer-setup.php"
    signature="${tmpdir}/installer.sig"

    # 先取得官方 SHA384；缺少校验依据时不执行远程安装程序。
    echo "正在从 composer.github.io 获取 Composer 安装程序签名..."
    if ! Download_Fetch https://composer.github.io/installer.sig "${signature}"; then
        Echo_Red "Composer 安装程序签名下载失败，拒绝继续。"
        rm -rf "${tmpdir}"
        return 1
    fi
    expected=$(tr -d '[:space:]' < "${signature}")
    if ! echo "${expected}" | grep -Eq '^[0-9a-f]{96}$'; then
        Echo_Red "Composer 安装程序签名不是有效的 SHA384，拒绝继续。"
        Echo_Red "实际获取：${expected:0:120}"
        rm -rf "${tmpdir}"
        return 1
    fi

    echo "正在从 getcomposer.org 下载 Composer 安装程序..."
    if ! Download_Fetch https://getcomposer.org/installer "${installer}" \
       || [ ! -s "${installer}" ]; then
        Echo_Red "Composer 安装程序下载失败，跳过 Composer 安装。"
        rm -rf "${tmpdir}"
        return 1
    fi

    actual=$("${php_bin}" -r 'echo hash_file("sha384", $argv[1]);' "${installer}")
    if [ "${expected}" != "${actual}" ]; then
        Echo_Red "Composer 安装程序 SHA384 不匹配，拒绝执行。"
        Echo_Red "预期值=${expected}"
        Echo_Red "实际值=${actual}"
        rm -rf "${tmpdir}"
        return 1
    fi
    Echo_Green "Composer 安装程序 SHA384 校验通过。"

    "${php_bin}" "${installer}" --install-dir=/usr/local/bin --filename=composer.phar
    rm -rf "${tmpdir}"
    if [ ! -s /usr/local/bin/composer.phar ]; then
        Echo_Red "Composer 安装失败。"
        return 1
    fi
    chmod +x /usr/local/bin/composer.phar

    # CLI 与 FPM 共用同一份 php.ini，其中禁用了 proc_open、exec 等进程函数，
    # 而 Composer 执行 scripts、插件和 VCS 工具时依赖它们。包装脚本只为这一条
    # 命令放开，Web 侧的 disable_functions 基线保持不变。
    if ! cat >/usr/local/bin/composer<<EOF
#!/bin/sh
# 由 LNMP 生成：只为 Composer 放开进程类函数，不改 php.ini 的全局基线。
exec ${php_bin} -d disable_functions= -d memory_limit=-1 \
    /usr/local/bin/composer.phar "\$@"
EOF
    then
        Echo_Red "写入 /usr/local/bin/composer 失败。"
        return 1
    fi
    chmod 755 /usr/local/bin/composer
    echo "Composer 安装成功：/usr/local/bin/composer 是包装脚本，"
    echo "它只为 Composer 自身放开 disable_functions，Web 请求不受影响。"
    return 0
}

Creat_PHP_Tools()
{
    local pma_ver

    cd "${cur_dir}/src" || return 1

    \cp ${cur_dir}/conf/index.html ${Default_Website_Dir}/index.html
    # 默认站点自带 favicon，避免浏览器请求在 error_log 中反复记录 404
    \cp ${cur_dir}/conf/favicon.ico ${Default_Website_Dir}/favicon.ico ||
        Echo_Red "favicon.ico 部署失败，默认站点仍会记录 /favicon.ico 404。"

    if [ "${Enable_PHPInfo_Page}" = "y" ]; then
        echo "正在创建 PHP 信息页面..."
        cat >${Default_Website_Dir}/phpinfo.php<<eof
<?php
phpinfo();
?>
eof
        Warn_Demo_Page_Not_Served phpinfo.php
    fi

    if [ "${Enable_PhpMyAdmin}" = "y" ]; then
        echo "============================ 正在安装 phpMyAdmin ============================="
        pma_ver="${PhpMyAdmin_Ver#phpMyAdmin-}"
        PhpMyAdmin_Install "${pma_ver%-all-languages}" "${Stack}" "${DB_Port}" || return 1
        echo "============================ phpMyAdmin 安装完成 ============================="
    fi
    return 0
}

# 独立安装 phpMyAdmin 时识别现有 LNMP、LNMPA 或 LAMP 环境，以生成正确映射。
Detect_PhpMyAdmin_Stack()
{
    if [ ! -s /bin/lnmp ]; then
        Echo_Red "未检测到已安装的 LNMP/LNMPA/LAMP 环境，请先安装主栈。"
        return 1
    fi

    if grep -q '^lnmpa_start()' /bin/lnmp; then
        Stack='lnmpa'
    elif grep -q '^lamp_start()' /bin/lnmp; then
        Stack='lamp'
    elif grep -q '^lnmp_start()' /bin/lnmp; then
        Stack='lnmp'
    else
        Echo_Red "无法从 /bin/lnmp 识别现有安装类型，拒绝写入 Web 配置。"
        return 1
    fi

    case "${Stack}" in
    lnmp)
        [ -x /usr/local/nginx/sbin/nginx ] || {
            Echo_Red "现有 LNMP 环境缺少 Nginx，无法启用 phpMyAdmin。"; return 1; }
        ;;
    lnmpa)
        [ -x /usr/local/nginx/sbin/nginx ] && [ -x /usr/local/apache/bin/httpd ] || {
            Echo_Red "现有 LNMPA 环境的 Nginx 或 Apache 不完整，无法启用 phpMyAdmin。"; return 1; }
        ;;
    lamp)
        [ -x /usr/local/apache/bin/httpd ] || {
            Echo_Red "现有 LAMP 环境缺少 Apache，无法启用 phpMyAdmin。"; return 1; }
        ;;
    esac
}

Check_PhpMyAdmin_Web_Config()
{
    case "${Stack}" in
    lnmp)
        /usr/local/nginx/sbin/nginx -t
        ;;
    lnmpa)
        /usr/local/nginx/sbin/nginx -t && /usr/local/apache/bin/httpd -t
        ;;
    lamp)
        /usr/local/apache/bin/httpd -t
        ;;
    esac
}

Reload_PhpMyAdmin_Web()
{
    case "${Stack}" in
    lnmp)
        StartOrStop reload nginx
        ;;
    lnmpa)
        StartOrStop reload nginx && StartOrStop reload httpd
        ;;
    lamp)
        StartOrStop reload httpd
        ;;
    esac
}

Install_Only_phpMyAdmin()
{
    local action="${1:-}" pma_ver db_port

    Print_Banner "为现有环境安装 phpMyAdmin"

    Detect_PhpMyAdmin_Stack || return 1

    if [ -n "${action}" ]; then
        case "${action}" in enable|disable|status) ;; *)
            Echo_Red "用法：./install.sh phpmyadmin {enable|disable|status}"
            return 1
            ;;
        esac
        if [ ! -x /bin/lnmp-phpmyadmin ]; then
            Echo_Red "未找到 /bin/lnmp-phpmyadmin，请先完成 phpMyAdmin 安装。"
            return 1
        fi
        /bin/lnmp-phpmyadmin "${Stack}" "${action}"
        return $?
    fi

    if [ ! -x /usr/local/php/bin/php ]; then
        Echo_Red "未检测到 /usr/local/php/bin/php，请先安装完整主栈。"
        return 1
    fi
    if ! /usr/local/php/bin/php -r \
        'exit(version_compare(PHP_VERSION, "7.2.5", ">=") ? 0 : 1);'; then
        Echo_Red "当前 PHP 版本低于 phpMyAdmin 5.2 所需的 PHP 7.2.5。"
        return 1
    fi
    if ! /usr/local/php/bin/php -m | grep -Eqi '^mysqli$'; then
        Echo_Red "当前 PHP 未启用 mysqli 扩展，phpMyAdmin 无法连接数据库。"
        return 1
    fi
    if ! id www >/dev/null 2>&1; then
        Echo_Red "未检测到 www 运行用户，现有主栈不完整。"
        return 1
    fi

    if [ -e "${PhpMyAdmin_Dir}" ] || \
       [ -e /usr/local/nginx/conf/phpmyadmin.enable.conf ] || \
       [ -e /usr/local/nginx/conf/.phpmyadmin.enable.conf.disabled ] || \
       [ -e /usr/local/apache/conf/extra/.phpmyadmin.enable.conf.disabled ] || \
       [ -e /usr/local/apache/conf/extra/phpmyadmin.enable.conf ]; then
        Echo_Red "phpMyAdmin 已安装或已有启用配置，未覆盖现有文件。"
        Echo_Red "如需升级，请执行：./upgrade.sh phpmyadmin"
        return 1
    fi

    Set_PHP_Profile "${PHP_Default}" || return 1
    pma_ver="${PhpMyAdmin_Ver#phpMyAdmin-}"
    pma_ver="${pma_ver%-all-languages}"
    # 补装时读取数据库实际监听端口，避免 lnmp.conf 默认值覆盖安装时的自定义端口。
    db_port=$(Db_Port /etc/my.cnf "${DB_Port}") || \
        Echo_Yellow "未能从 /etc/my.cnf 读到数据库端口，按 lnmp.conf 的 ${db_port} 写入。"
    [ "${db_port}" = "${DB_Port}" ] || \
        Echo_Yellow "数据库实际端口为 ${db_port}（lnmp.conf 记的是 ${DB_Port}），按实际端口写入。"

    PhpMyAdmin_Install "${pma_ver}" "${Stack}" "${db_port}" || return 1
    if ! Check_PhpMyAdmin_Web_Config; then
        Echo_Red "Web 配置测试未通过，正在撤销本次 phpMyAdmin 安装。"
        PhpMyAdmin_Remove
        return 1
    fi
    if ! Reload_PhpMyAdmin_Web || ! PhpMyAdmin_Verify "${pma_ver}" "${Stack}"; then
        Echo_Red "Web 服务重载或本机 HTTP 验证失败，正在撤销本次 phpMyAdmin 安装。"
        PhpMyAdmin_Remove
        Check_PhpMyAdmin_Web_Config >/dev/null 2>&1 && Reload_PhpMyAdmin_Web >/dev/null 2>&1
        return 1
    fi

    Echo_Green "phpMyAdmin ${pma_ver} 安装完成。"
    # 访问地址由随管理命令部署的 lnmp-phpmyadmin 统一输出。
    if [ -x /bin/lnmp-phpmyadmin ]; then
        /bin/lnmp-phpmyadmin "${Stack}" status
    else
        Echo_Green "访问地址：http://<服务器IP>/$(cat "${PhpMyAdmin_Url_File}")/"
        Echo_Yellow "未找到 /bin/lnmp-phpmyadmin，执行 ./bumpversion.sh 部署管理命令后可用 lnmp phpmyadmin 管理入口。"
    fi
    return 0
}
