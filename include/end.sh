#!/usr/bin/env bash

Add_Iptables_Rules()
{
    echo "正在配置防火墙..."

    if ! Firewall_Init; then
        Echo_Red "防火墙未配置成功，请自行确认 ${DB_Port} 等端口没有暴露在公网。"
        return 1
    fi

    Firewall_Allow tcp "${SSH_Port}"
    Firewall_Allow tcp 80
    Firewall_Allow tcp 443
    Firewall_Allow_ICMP
    # 数据库端口只挡外部新建连接，本机经 lo 访问不受影响
    Firewall_Block tcp "${DB_Port}"
    # 33060 是 MySQL X Protocol，功能上等价于 3306（一样能跑 SQL）。
    # 它不受 my.cnf 的 bind-address 约束，只挡 3306 会留下一个等价入口。
    # MariaDB 没有这个端口，多这条规则也无副作用。
    Firewall_Block tcp "${DB_X_Port}"

    Firewall_Save
}

# 保证两个常用绝对路径指向相同内容且权限固定为 755。
# /bin 与 /usr/bin 在 merged-/usr 系统上是同一目录，在旧布局上则不是。
Sync_LNMP_Command_Alias()
{
    local tmp

    if ! chmod 755 /bin/lnmp; then
        Echo_Red "/bin/lnmp 不可执行。"
        return 1
    fi
    if [ ! /bin/lnmp -ef /usr/bin/lnmp ] 2>/dev/null; then
        tmp=$(mktemp /usr/bin/.lnmp.XXXXXXXX) || return 1
        if ! \cp /bin/lnmp "${tmp}" || ! chmod 755 "${tmp}" || \
           ! mv -f "${tmp}" /usr/bin/lnmp; then
            rm -f "${tmp}"
            Echo_Red "同步 /usr/bin/lnmp 失败。"
            return 1
        fi
    fi
    if ! chmod 755 /usr/bin/lnmp || [ ! -x /usr/bin/lnmp ]; then
        Echo_Red "/usr/bin/lnmp 不可执行。"
        return 1
    fi
    return 0
}

Detect_Installed_LNMP_Command_Stack()
{
    local manager=${1:-/bin/lnmp}

    if [ ! -s "${manager}" ]; then
        return 1
    fi
    if grep -q '^lnmpa_start()' "${manager}"; then
        printf '%s\n' lnmpa
    elif grep -q '^lamp_start()' "${manager}"; then
        printf '%s\n' lamp
    else
        printf '%s\n' lnmp
    fi
}

Install_Current_LNMP_Command()
{
    local fallback=${1:-lnmp} installed_stack

    installed_stack=$(Detect_Installed_LNMP_Command_Stack /bin/lnmp 2>/dev/null) || \
        installed_stack=${fallback}
    Install_LNMP_Command "${installed_stack}"
}

# 管理命令和备份实现要一起安装：lnmp backup 子命令调用 /bin/lnmp-backup，
# 只更新其中一个会让新版 lnmp 调到旧版或根本不存在的备份脚本。
Install_LNMP_Command()
{
    local stack=$1 source target

    case "${stack}" in lnmp|lnmpa|lamp) ;; *)
        Echo_Red "未知管理脚本类型：${stack}"
        return 1
        ;;
    esac

    for source in \
        "${cur_dir}/conf/${stack}:/bin/lnmp" \
        "${cur_dir}/tools/lnmp-backup.sh:/bin/lnmp-backup" \
        "${cur_dir}/tools/lnmp-tgnotice.sh:/bin/lnmp-tgnotice" \
        "${cur_dir}/tools/lnmp-phpmyadmin.sh:/bin/lnmp-phpmyadmin"
    do
        target=${source#*:}
        source=${source%%:*}
        if [ ! -s "${source}" ] || ! \cp "${source}" "${target}" || \
           ! chmod 755 "${target}" || [ ! -x "${target}" ]; then
            Echo_Red "安装管理命令失败：${source} -> ${target}"
            return 1
        fi
    done

    # /bin 在主流发行版通常与 /usr/bin 合并，但不能依赖这一点。用户直接执行
    # /usr/bin/lnmp 时也必须得到同一个、权限正确的管理命令。
    Sync_LNMP_Command_Alias || return 1

    Install_Tgnotice_Profile || return 1
    # tools/ 目录下的脚本在仓库里是 644（git 不记录可执行位），README/HowtoGuides
    # 里都是 ./tools/xxx.sh 直接调用；不补权限会导致装完之后直接 Permission denied。
    if ! chmod 755 "${cur_dir}"/tools/*.sh 2>/dev/null; then
        Echo_Red "设置 tools/ 目录脚本权限失败，请手动执行: chmod 755 ${cur_dir}/tools/*.sh"
        return 1
    fi
    return 0
}

# 让 tgnotice 函数在登录 shell 里直接可用，脚本里写 tgnotice "..." 即可。
# 只在 bash 下加载：函数用到了 bash 的数组与字符串操作，dash 跑不了。
Install_Tgnotice_Profile()
{
    mkdir -p /etc/profile.d 2>/dev/null || return 0
    cat > /etc/profile.d/lnmp-tgnotice.sh <<'PROFILE_EOF'
# 由 LNMP 安装流程生成：加载 tgnotice 函数。
# 用法：tgnotice "文本"        默认 HTML
#       tgnotice "文本" md     MarkdownV2
if [ -n "${BASH_VERSION:-}" ] && [ -r /bin/lnmp-tgnotice ]; then
    . /bin/lnmp-tgnotice
fi
PROFILE_EOF
    chmod 644 /etc/profile.d/lnmp-tgnotice.sh
}

Add_LNMP_Startup()
{
    echo "正在设置开机启动并启动 LNMP..."
    Install_LNMP_Command lnmp || return 1
    StartUp nginx
    StartOrStop start nginx
    Startup_DB || return 1
    StartUp php-fpm
    StartOrStop start php-fpm
    if [ "${PHP_Branch}" = "5.2" ]; then
        sed -i 's#/usr/local/php/var/run/php-fpm.pid#/usr/local/php/logs/php-fpm.pid#' /bin/lnmp
        Sync_LNMP_Command_Alias || return 1
    fi
}

# 三个 Add_*_Startup 原本各有一份逐字相同的数据库启动块，现合并。
# 管理脚本不再固化 mysql/mariadb；每次执行时按现有 unit/init 脚本检测。
Startup_DB()
{
    if [ "${DB_Kind}" = "none" ]; then
        return 0
    fi
    StartUp "${DB_Service}"
    StartOrStop start "${DB_Service}"
}

Add_LNMPA_Startup()
{
    echo "正在设置开机启动并启动 LNMPA..."
    Install_LNMP_Command lnmpa || return 1
    StartUp nginx
    StartOrStop start nginx
    Startup_DB || return 1
    StartUp httpd
    StartOrStop start httpd
}

Add_LAMP_Startup()
{
    echo "正在设置开机启动并启动 LAMP..."
    Install_LNMP_Command lamp || return 1
    StartUp httpd
    StartOrStop start httpd
    Startup_DB || return 1
}

Check_Nginx_Files()
{
    isNginx=""
    echo "============================== 检查安装结果 =============================="
    echo "正在检查..."
    if [[ -s /usr/local/nginx/conf/nginx.conf && -s /usr/local/nginx/sbin/nginx ]]; then
        Echo_Green "Nginx：正常"
        isNginx="ok"
    else
        Echo_Red "错误：Nginx 安装失败。"
    fi
}

Check_DB_Files()
{
    local db_client db_safe

    isDB=""
    if [ "${DB_Kind}" = "none" ]; then
        Echo_Green "未安装 MySQL/MariaDB。"
        isDB="ok"
    elif [ "${DB_Kind}" = "mariadb" ]; then
        db_client=$(First_Executable "${MySQL_Dir}/bin/mariadb" "${MySQL_Dir}/bin/mysql")
        db_safe=$(First_Executable "${MySQL_Dir}/bin/mariadbd-safe" "${MySQL_Dir}/bin/mysqld_safe")
        if [ -n "${db_client}" ] && [ -n "${db_safe}" ] && [ -s /etc/my.cnf ]; then
            MySQL_Bin="${db_client}"
            Echo_Green "MariaDB：正常"
            isDB="ok"
        else
            Echo_Red "错误：MariaDB 安装失败。"
        fi
    elif [[ -s ${MySQL_Dir}/bin/mysql && -s ${MySQL_Dir}/bin/mysqld_safe && -s /etc/my.cnf ]]; then
        MySQL_Bin="${MySQL_Dir}/bin/mysql"
        Echo_Green "MySQL：正常"
        isDB="ok"
    else
        if [ "${DB_Kind}" = "mariadb" ]; then
            Echo_Red "错误：MariaDB 安装失败。"
        else
            Echo_Red "错误：MySQL 安装失败。"
        fi
    fi
}

Check_PHP_Files()
{
    isPHP=""
    if [ "${Stack}" = "lnmp" ]; then
        if [[ -s /usr/local/php/sbin/php-fpm && -s /usr/local/php/etc/php.ini && -s /usr/local/php/bin/php ]]; then
            Echo_Green "PHP：正常"
            Echo_Green "PHP-FPM：正常"
            isPHP="ok"
        else
            Echo_Red "错误：PHP 安装失败。"
        fi
    else
        if [[ -s /usr/local/php/bin/php && -s /usr/local/php/etc/php.ini ]]; then
            Echo_Green "PHP：正常"
            isPHP="ok"
        else
            Echo_Red "错误：PHP 安装失败。"
        fi
    fi
}

Check_Apache_Files()
{
    isApache=""
    if [[ -s /usr/local/apache/bin/httpd && -s /usr/local/apache/modules/${PHP_Apache_Module} && -s /usr/local/apache/conf/httpd.conf ]]; then
        Echo_Green "Apache：正常"
        isApache="ok"
    else
        Echo_Red "错误：Apache 安装失败。"
    fi
}

Clean_DB_Src_Dir()
{
    echo "正在清理数据库源码目录..."
    [ "${DB_Kind}" = "none" ] && return 0
    [ -n "${DB_Ver}" ] && rm -rf ${cur_dir}/src/${DB_Ver}

    # Boost 源码目录清理只跟安装时动态解析的 Get_Boost_Ver 走。
    # version.sh 的 Boost_Ver/Boost_New_Ver 仅供探测与校验清单使用，
    # 不参与安装目录选择。
    #
    # 必须检查非空值，避免变量为空时 rm -rf ${cur_dir}/src/ 删除整个 src 目录。
    if [ "${DB_Needs_Boost}" = "y" ]; then
        [ -n "${Get_Boost_Ver}" ] && [ -d "${cur_dir}/src/boost_${Get_Boost_Ver}" ] && rm -rf ${cur_dir}/src/boost_${Get_Boost_Ver}
    fi
    return 0
}

Clean_PHP_Src_Dir()
{
    echo "正在清理 PHP 源码目录..."
    rm -rf ${cur_dir}/src/${Php_Ver}
}

Clean_Web_Src_Dir()
{
    echo "正在清理 Web 服务器源码目录..."
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
        Print_Banner \
            "数据库 root 密码为随机生成，已写入 ${pass_file}" \
            "查看：cat ${pass_file}（请尽快记录并删除该文件）"
    else
        Print_Banner "数据库 root 密码：即你安装时输入的那个，脚本不再回显。"
    fi
    Print_Banner "密码不再打印到屏幕与安装日志，见 changelog SEC-CRED-001。"
}

Print_Sucess_Info()
{
    Clean_Web_Src_Dir
    Print_Banner \
        "LNMP V${LNMP_Ver} 安装完成" \
        "运行 lnmp {start|stop|reload|restart|kill|status} 管理服务" \
        "仅使用上游官方源码，并强制校验完整性"
    # 统一用 Print_Banner 输出安装摘要，中文与英文混排时也能保持边框对齐。
    local summary_lines=()
    if [ "${Enable_PhpMyAdmin}" = "y" ]; then
        summary_lines+=("phpMyAdmin：http://IP/$(cat ${PhpMyAdmin_Url_File} 2>/dev/null)/")
        summary_lines+=("上面这个路径是随机生成的，请自行记录；忘记可执行 lnmp status 查看。")
    fi
    [ "${Enable_PHPInfo_Page}" = "y" ] && summary_lines+=("phpinfo：http://IP/phpinfo.php")
    summary_lines+=("添加虚拟主机：lnmp vhost add")
    summary_lines+=("默认网站目录：${Default_Website_Dir}")
    Print_Banner "${summary_lines[@]}"
    if [ "${DB_Kind}" != "none" ]; then
        Print_DB_Password_Notice
    fi
    lnmp status
    if command -v ss >/dev/null 2>&1; then
        ss -ntl
    else
        netstat -ntl
    fi
    stop_time=$(date +%s)
    echo "LNMP 安装耗时 $(((stop_time-start_time)/60)) 分钟。"
    Echo_Green "LNMP V${LNMP_Ver} 安装完成。"

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
    Echo_Red "LNMP 安装失败。"
    Echo_Red "请查看安装日志了解详情：/root/lnmp-install.log"
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
    Echo_Red "这意味着 ${DB_Port}（数据库）等端口可能正暴露在公网上。"
    echo
    Echo_Yellow "请立即自行确认并处置："
    echo "  nft list table inet lnmp        # 看本包的规则表在不在"
    echo "  ss -lntp | grep -E ':${DB_Port}|:${Redis_Port}' # 看数据库/缓存监听在哪个地址"
    echo
    Echo_Yellow "数据库默认已配置 bind-address = 127.0.0.1（只监听回环），"
    Echo_Yellow "但若你改过 /etc/my.cnf，或使用了其他服务，请逐一核对。"
    Echo_Red "════════════════════════════════════════════════"
    return 1
}

# ---------------------------------------------------------------------------
# Check_DB_Init_Result — 数据库初始化 SQL 是否真的执行成功。
#
# Check_DB_Files 只看数据库客户端、safe 启动器和 /etc/my.cnf 在不在，
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
    echo "  ${MySQL_Bin} --version"
    echo "  ${MySQL_Bin} -u root -p -e \"SELECT User,Host FROM mysql.user;\""
    echo "  ${MySQL_Bin} -u root -p -e \"SHOW DATABASES;\"   # 不应有 test"
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
