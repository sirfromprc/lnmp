#!/usr/bin/env bash

Add_Iptables_Rules()
{
    echo "Configuring firewall..."

    if ! Firewall_Init; then
        Echo_Red "防火墙未配置成功，请自行确认 3306 等端口没有暴露在公网。"
        return 1
    fi

    Firewall_Allow tcp 22
    Firewall_Allow tcp 80
    Firewall_Allow tcp 443
    Firewall_Allow_ICMP
    # 数据库端口只挡外部新建连接，本机经 lo 访问不受影响
    Firewall_Block tcp 3306
    # 33060 是 MySQL X Protocol，功能上等价于 3306（一样能跑 SQL）。
    # 它不受 my.cnf 的 bind-address 约束，只挡 3306 会留下一个等价入口。
    # MariaDB 没有这个端口，多这条规则也无副作用。
    Firewall_Block tcp 33060

    Firewall_Save
}

# 管理命令和备份实现要一起安装：lnmp backup 子命令调用 /bin/lnmp-backup，
# 只更新其中一个会让新版 lnmp 调到旧版或根本不存在的备份脚本。
Install_LNMP_Command()
{
    \cp ${cur_dir}/conf/$1 /bin/lnmp
    chmod +x /bin/lnmp
    \cp ${cur_dir}/tools/lnmp-backup.sh /bin/lnmp-backup
    chmod +x /bin/lnmp-backup
}

Add_LNMP_Startup()
{
    echo "Add Startup and Starting LNMP..."
    Install_LNMP_Command lnmp
    StartUp nginx
    StartOrStop start nginx
    Startup_DB
    StartUp php-fpm
    StartOrStop start php-fpm
    if [ "${PHP_Branch}" = "5.2" ]; then
        sed -i 's#/usr/local/php/var/run/php-fpm.pid#/usr/local/php/logs/php-fpm.pid#' /bin/lnmp
    fi
}

# 三个 Add_*_Startup 原本各有一份逐字相同的数据库启动块，现合并。
# DB_Service 由 Set_DB_Profile 派生，消除了 mysql/mariadb 字面量与编号集合。
#
# 三个管理脚本（conf/lnmp、conf/lnmpa、conf/lamp）里数据库服务名收敛成了
# 一个 DB_SERVICE 变量，这里只改那一行；原先是逐条替换 /etc/init.d/mysql
# 字面量，改用 Svc 之后那种替换方式已不适用。
Startup_DB()
{
    if [ "${DB_Kind}" = "none" ]; then
        sed -i 's#^DB_SERVICE=mysql$#DB_SERVICE=#' /bin/lnmp
        return 0
    fi
    StartUp "${DB_Service}"
    StartOrStop start "${DB_Service}"
    if [ "${DB_Kind}" = "mariadb" ]; then
        sed -i 's#^DB_SERVICE=mysql$#DB_SERVICE=mariadb#' /bin/lnmp
    fi
}

Add_LNMPA_Startup()
{
    echo "Add Startup and Starting LNMPA..."
    Install_LNMP_Command lnmpa
    StartUp nginx
    StartOrStop start nginx
    Startup_DB
    StartUp httpd
    StartOrStop start httpd
}

Add_LAMP_Startup()
{
    echo "Add Startup and Starting LAMP..."
    Install_LNMP_Command lamp
    StartUp httpd
    StartOrStop start httpd
    Startup_DB
}

Check_Nginx_Files()
{
    isNginx=""
    echo "============================== Check install =============================="
    echo "Checking ..."
    if [[ -s /usr/local/nginx/conf/nginx.conf && -s /usr/local/nginx/sbin/nginx ]]; then
        Echo_Green "Nginx: OK"
        isNginx="ok"
    else
        Echo_Red "Error: Nginx install failed."
    fi
}

Check_DB_Files()
{
    isDB=""
    if [ "${DB_Kind}" = "none" ]; then
        Echo_Green "Do not install MySQL/MariaDB."
        isDB="ok"
    elif [[ -s ${MySQL_Dir}/bin/mysql && -s ${MySQL_Dir}/bin/mysqld_safe && -s /etc/my.cnf ]]; then
        if [ "${DB_Kind}" = "mariadb" ]; then
            Echo_Green "MariaDB: OK"
        else
            Echo_Green "MySQL: OK"
        fi
        isDB="ok"
    else
        if [ "${DB_Kind}" = "mariadb" ]; then
            Echo_Red "Error: MariaDB install failed."
        else
            Echo_Red "Error: MySQL install failed."
        fi
    fi
}

Check_PHP_Files()
{
    isPHP=""
    if [ "${Stack}" = "lnmp" ]; then
        if [[ -s /usr/local/php/sbin/php-fpm && -s /usr/local/php/etc/php.ini && -s /usr/local/php/bin/php ]]; then
            Echo_Green "PHP: OK"
            Echo_Green "PHP-FPM: OK"
            isPHP="ok"
        else
            Echo_Red "Error: PHP install failed."
        fi
    else
        if [[ -s /usr/local/php/bin/php && -s /usr/local/php/etc/php.ini ]]; then
            Echo_Green "PHP: OK"
            isPHP="ok"
        else
            Echo_Red "Error: PHP install failed."
        fi
    fi
}

Check_Apache_Files()
{
    isApache=""
    if [[ -s /usr/local/apache/bin/httpd && -s /usr/local/apache/modules/${PHP_Apache_Module} && -s /usr/local/apache/conf/httpd.conf ]]; then
        Echo_Green "Apache: OK"
        isApache="ok"
    else
        Echo_Red "Error: Apache install failed."
    fi
}

Clean_DB_Src_Dir()
{
    echo "Clean database src directory..."
    [ "${DB_Kind}" = "none" ] && return 0
    [ -n "${DB_Ver}" ] && rm -rf ${cur_dir}/src/${DB_Ver}

    # Boost 源码目录清理。原代码按 DBSelect=4/5 分别清理 Boost_Ver/Boost_New_Ver，
    # 这两个固定版本变量已随 MySQL 5.7 的移除一并删除（见 version.sh），
    # 现在只有一条动态路径：版本由 cmake/boost.cmake 决定，落在 Get_Boost_Ver。
    #
    # 必须检查非空值，避免变量为空时 rm -rf ${cur_dir}/src/ 删除整个 src 目录。
    if [ "${DB_Needs_Boost}" = "y" ]; then
        [ -n "${Get_Boost_Ver}" ] && [ -d "${cur_dir}/src/boost_${Get_Boost_Ver}" ] && rm -rf ${cur_dir}/src/boost_${Get_Boost_Ver}
    fi
    return 0
}

Clean_PHP_Src_Dir()
{
    echo "Clean PHP src directory..."
    rm -rf ${cur_dir}/src/${Php_Ver}
}

Clean_Web_Src_Dir()
{
    echo "Clean Web Server src directory..."
    if [ "${Stack}" = "lnmp" ]; then
        rm -rf ${cur_dir}/src/${Nginx_Ver}*
    elif [ "${Stack}" = "lnmpa" ]; then
        rm -rf ${cur_dir}/src/${Nginx_Ver}*
        rm -rf ${cur_dir}/src/${Apache_Ver}
    elif [ "${Stack}" = "lamp" ]; then
        rm -rf ${cur_dir}/src/${Apache_Ver}
    fi

    [[ -d "${cur_dir}/src/${Openssl_New_Ver}" ]] && rm -rf ${cur_dir}/src/${Openssl_New_Ver}
    [[ -d "${cur_dir}/src/${Pcre_Ver}" ]] && rm -rf ${cur_dir}/src/${Pcre_Ver}
    [[ -d "${cur_dir}/src/${LuaNginxModule}" ]] && rm -rf ${cur_dir}/src/${LuaNginxModule}
    [[ -d "${cur_dir}/src/${NgxDevelKit}" ]] && rm -rf ${cur_dir}/src/${NgxDevelKit}
    [[ -d "${cur_dir}/src/${NgxFancyIndex_Ver}" ]] && rm -rf ${cur_dir}/src/${NgxFancyIndex_Ver}
}


Print_DB_Password_Notice()
{
    local pass_file='/root/.lnmp_db_root_password'

    if [ "${DB_Root_Password_Random}" = "y" ]; then
        ( umask 077; printf '%s\n' "${DB_Root_Password}" > "${pass_file}" )
        chmod 600 "${pass_file}" 2>/dev/null
        echo "|  数据库 root 密码为随机生成，已写入 ${pass_file}"
        echo "|  查看：cat ${pass_file}   （请尽快记录并删除该文件）"
    else
        echo "|  数据库 root 密码：即你安装时输入的那个，脚本不再回显。"
    fi
    echo "|  （密码不再打印到屏幕与安装日志，见 changelog SEC-CRED-001）"
}

Print_Sucess_Info()
{
    Clean_Web_Src_Dir
    echo "+------------------------------------------------------------------------+"
    echo "|          LNMP V${LNMP_Ver} for ${DISTRO} Linux Server, Written by Licess          |"
    echo "+------------------------------------------------------------------------+"
    echo "|          Upstream-official sources only, checksums enforced             |"
    echo "+------------------------------------------------------------------------+"
    echo "|    lnmp status manage: lnmp {start|stop|reload|restart|kill|status}    |"
    echo "+------------------------------------------------------------------------+"
    # 这三项现在都是可选的（p.php 探针已彻底移除），按实际部署情况提示。
    if [ "${Enable_PhpMyAdmin}" = "y" ] || [ "${Enable_PHPInfo_Page}" = "y" ]; then
        if [ "${Enable_PhpMyAdmin}" = "y" ]; then
            # 访问路径每次安装随机生成，这里打印实际值。忘记了可以随时用
            # lnmp status 查看，或直接读 ${PhpMyAdmin_Url_File}。
            echo "|  phpMyAdmin: http://IP/$(cat ${PhpMyAdmin_Url_File} 2>/dev/null)/"
            echo "|  上面这个路径是随机生成的，请自行记录；忘记可执行 lnmp status 查看。"
        fi
        [ "${Enable_PHPInfo_Page}" = "y" ] && echo "|  phpinfo: http://IP/phpinfo.php                                        |"
        echo "+------------------------------------------------------------------------+"
    fi
    echo "|  Add VirtualHost: lnmp vhost add                                       |"
    echo "+------------------------------------------------------------------------+"
    echo "|  Default directory: ${Default_Website_Dir}                              |"
    if [ "${DB_Kind}" != "none" ]; then
        echo "+------------------------------------------------------------------------+"
        Print_DB_Password_Notice
    fi
    echo "+------------------------------------------------------------------------+"
    lnmp status
    if command -v ss >/dev/null 2>&1; then
        ss -ntl
    else
        netstat -ntl
    fi
    stop_time=$(date +%s)
    echo "Install lnmp takes $(((stop_time-start_time)/60)) minutes."
    Echo_Green "Install lnmp V${LNMP_Ver} completed! enjoy it."

    # 校验被关掉时，在最后再说一次。
    # 安装过程刷屏几千行，开头的警告早滚没了；而这句话决定了这台机器上的
    # 组件到底有没有可信来源，必须让人在流程结束时还看得见。

    if [ "${Enable_Download_Checksum}" != "y" ]; then
        echo
        Echo_Red "########################################################################"
        Echo_Red "!! 本次安装全程未做完整性校验（Enable_Download_Checksum='${Enable_Download_Checksum}'）。"
        Echo_Red "!! 所有下载的组件都没有与 src/checksums.sha256 核对过，"
        Echo_Red "!! 无法保证它们与上游一致。**这台机器不应作为生产环境使用。**"
        Echo_Red "!! 请改回 Enable_Download_Checksum='y' 后清空 src/ 重装。"
        Echo_Red "########################################################################"
    fi
}


Print_Failed_Info()
{
    if [ -s /bin/lnmp ]; then
        rm -f /bin/lnmp
    fi
    Echo_Red "Sorry, Failed to install LNMP!"
    Echo_Red "Check the install log for details: /root/lnmp-install.log"
    Echo_Red "注意：该日志可能含数据库 root 密码等敏感信息，外发前请先清理。"
    return 1
}

# ---------------------------------------------------------------------------
# Check_Firewall_Result — 防火墙是否真的配上了。
#
# 组件文件齐全 ≠ 安装成功。`Add_Iptables_Rules` 失败时会返回 1 并置
# FW_Failed='y'，但三个安装栈都是无条件往下走的，最终检查又只看组件文件 ：
# 于是「nftables 缺失 / 规则写入失败 / 持久化失败」这些情况下，
# 安装照样以 0 退出并打印"完成"，而 3306 就那么暴露着。
# 自动化只看退出码时，根本发现不了安全控制已经失效。
#
# 现在把它并入成功判定：防火墙没配上就不算安装成功。
# 组件本身仍然可用（该装的都装了），但退出码是 1，且明确告诉用户下一步做什么。
# ---------------------------------------------------------------------------
Check_Firewall_Result()
{
    [ "${FW_Failed}" != 'y' ] && return 0

    echo
    Echo_Red "════════════════ 防火墙未配置成功 ════════════════"
    Echo_Red "组件已经装好，但**防火墙规则没有成功写入**。"
    Echo_Red "这意味着 3306（数据库）等端口可能正暴露在公网上。"
    echo
    Echo_Yellow "请立即自行确认并处置："
    echo "  nft list table inet lnmp        # 看本包的规则表在不在"
    echo "  ss -lntp | grep -E ':3306|:6379' # 看数据库/缓存监听在哪个地址"
    echo
    Echo_Yellow "数据库默认已配置 bind-address = 127.0.0.1（只监听回环），"
    Echo_Yellow "但若你改过 /etc/my.cnf，或使用了其他服务，请逐一核对。"
    Echo_Red "════════════════════════════════════════════════"
    return 1
}

# ---------------------------------------------------------------------------
# Check_DB_Init_Result — 数据库初始化 SQL 是否真的执行成功。
#
# Check_DB_Files 只看 ${MySQL_Dir}/bin/mysql 和 /etc/my.cnf 在不在，
# 那只能说明「装上了」。初始化 SQL 失败时（典型是客户端缺运行库跑不起来），
# 匿名账号、test 库、远程 root 授权是否被清掉完全没有依据 ——
# 恰好干净不等于处理正确。
#
# 与 Check_Firewall_Result 同一处理方式：组件仍然可用，但退出码为 1，
# 并明确指出是哪些步骤失败、该怎么补。
# ---------------------------------------------------------------------------
Check_DB_Init_Result()
{
    [ "${DB_Init_Failed}" != 'y' ] && return 0

    echo
    Echo_Red "════════════════ 数据库初始化未全部成功 ════════════════"
    Echo_Red "以下初始化步骤失败：${DB_Init_Errors}"
    echo
    Echo_Yellow "这意味着匿名账号、test 库、远程 root 授权是否已清理无法确认。"
    Echo_Yellow "请先确认数据库客户端可用，再手工核对："
    echo "  ${MySQL_Dir}/bin/mysql --version"
    echo "  ${MySQL_Dir}/bin/mysql -u root -p -e \"SELECT User,Host FROM mysql.user;\""
    echo "  ${MySQL_Dir}/bin/mysql -u root -p -e \"SHOW DATABASES;\"   # 不应有 test"
    Echo_Red "════════════════════════════════════════════════════════"
    return 1
}

Check_LNMP_Install()
{
    Check_Nginx_Files
    Check_DB_Files
    Check_PHP_Files
    if [[ "${isNginx}" = "ok" && "${isDB}" = "ok" && "${isPHP}" = "ok" ]]; then
        Print_Sucess_Info
        # 组件齐全但防火墙或数据库初始化失败 → 仍然返回非零，
        # 不让自动化误判为成功。两项都要检查，不能因为前一项失败就跳过后一项。
        local rc=0
        Check_Firewall_Result || rc=1
        Check_DB_Init_Result || rc=1
        return ${rc}
    fi
    Print_Failed_Info
    return 1
}

Check_LNMPA_Install()
{
    Check_Nginx_Files
    Check_DB_Files
    Check_PHP_Files
    Check_Apache_Files
    if [[ "${isNginx}" = "ok" && "${isDB}" = "ok" && "${isPHP}" = "ok" && "${isApache}" = "ok" ]]; then
        Print_Sucess_Info
        local rc=0
        Check_Firewall_Result || rc=1
        Check_DB_Init_Result || rc=1
        return ${rc}
    fi
    Print_Failed_Info
    return 1
}

Check_LAMP_Install()
{
    Check_Apache_Files
    Check_DB_Files
    Check_PHP_Files
    if [[ "${isApache}" = "ok" && "${isDB}" = "ok" && "${isPHP}" = "ok" ]]; then
        Print_Sucess_Info
        local rc=0
        Check_Firewall_Result || rc=1
        Check_DB_Init_Result || rc=1
        return ${rc}
    fi
    Print_Failed_Info
    return 1
}
