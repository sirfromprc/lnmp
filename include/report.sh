#!/usr/bin/env bash
#
# 已完成安装的重跑检查：逐组件调用模块的 Installed、Check、Verify，并探测服务、本机 HTTP 与 FPM 监听。
# 只读，不改动文件与服务。结果分三级：正常；提示（可用，但编译选项与当前 lnmp.conf 不同）；问题（需处理）。
#
#   Stack_Report <lnmp|lnmpa|lamp>   0 无问题；1 有问题；3 参数错误

Report_Bad=0

# _Report <ok|note|bad> <组件> <说明> [处理命令]
_Report()
{
    case "$1" in
    ok)   printf '  [正常] %s：%s\n' "$2" "$3" ;;
    note) Echo_Yellow "  [提示] $2：$3" ;;
    bad)  Echo_Red "  [问题] $2：$3"; Report_Bad=$((Report_Bad + 1)) ;;
    esac
    [ -n "${4:-}" ] && printf '         处理：%s\n' "$4"
    return 0
}

# _Report_Health <组件> <Check 返回码> <Health 返回码> <文件缺失说明> <文件缺失处理> <配置失败说明> <配置失败处理>
# Check 为 1 时即使 Health 通过也记为不完整。
_Report_Health()
{
    local h=$3

    [ "${h}" -eq 0 ] && [ "$2" -eq 1 ] && h=1
    case "${h}" in
    0) _Report ok "$1" "配置与服务文件完整，配置检查通过" ;;
    1) _Report bad "$1" "$4" "$5" ;;
    *) _Report bad "$1" "$6" "$7" ;;
    esac
}

# _Report_Service <组件> <服务名> <启动命令>：服务未运行时返回 1，调用方据此跳过后续探测。
_Report_Service()
{
    if Svc_Running "$2"; then
        _Report ok "$1" "服务 $2 运行中"
        return 0
    fi
    _Report bad "$1" "服务 $2 未运行" "$3；仍失败时查看 lnmp status 与错误日志"
    return 1
}

_Report_Web()
{
    local out ver malloc mode rc

    out=$(OpenResty_Installed); rc=$?
    if [ "${rc}" -ne 1 ]; then
        IFS=$'\t' read -r ver mode <<< "${out}"
        if [ "${rc}" -ne 0 ]; then
            _Report bad "OpenResty" "程序不可读（/usr/local/openresty/nginx/sbin/nginx）" "./upgrade.sh openresty"
            return 0
        fi
        OpenResty_Check "${ver}" "${mode}"; rc=$?
        [ "${rc}" -eq 2 ] && _Report note "OpenResty ${ver}" "安装方式或目录与模块期望不同（${mode}）"
        OpenResty_Health >/dev/null 2>&1
        _Report_Health "OpenResty ${ver}" "${rc}" $? "配置或服务文件缺失" "./upgrade.sh openresty" \
            "配置检查未通过" "/usr/local/openresty/nginx/sbin/nginx -t 查看出错的文件与行号"
    else
        out=$(Nginx_Installed); rc=$?
        if [ "${rc}" -eq 1 ]; then
            _Report bad "Nginx" "未安装" "./install.sh nginx"
            return 0
        elif [ "${rc}" -eq 2 ]; then
            _Report bad "Nginx" "程序不可读（/usr/local/nginx/sbin/nginx）" "./install.sh nginx"
            return 0
        fi
        IFS=$'\t' read -r ver malloc <<< "${out}"
        Nginx_Check "${ver}" "${malloc}"; rc=$?
        [ "${rc}" -eq 2 ] && _Report note "Nginx ${ver}" "编译模块与当前 lnmp.conf 的开关不同"
        Nginx_Health >/dev/null 2>&1
        _Report_Health "Nginx ${ver}" "${rc}" $? "nginx.conf、default 站点、init 脚本或 unit 缺失" \
            "./install.sh nginx（重新编译并按模板重写主配置，vhost 与证书保留）" \
            "配置检查未通过" "/usr/local/nginx/sbin/nginx -t 查看出错的文件与行号"
    fi
    _Report_Service "Nginx" nginx "lnmp nginx start" && _Report_Http "Nginx" 80
    return 0
}

# _Report_Http <组件> <端口>：本机收到任意 HTTP 状态码即视为可用。缺少 curl 时不探测。
_Report_Http()
{
    local code

    command -v curl >/dev/null 2>&1 || return 0
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$2/" 2>/dev/null)
    if [ -n "${code}" ] && [ "${code}" != 000 ]; then
        _Report ok "$1" "本机 $2 端口 HTTP 响应 ${code}"
    else
        _Report bad "$1" "本机 $2 端口无 HTTP 响应" "lnmp status；ss -lntp 查看 $2 端口的监听进程"
    fi
}

_Report_Apache()
{
    local stack=$1 ver rc

    ver=$(Apache_Installed); rc=$?
    if [ "${rc}" -eq 1 ]; then
        _Report bad "Apache" "未安装" "./install.sh apache ${stack}"
        return 0
    elif [ "${rc}" -eq 2 ]; then
        _Report bad "Apache" "程序不可读（/usr/local/apache/bin/httpd）" "./install.sh apache ${stack}"
        return 0
    fi
    Apache_Check "${ver}" "${stack}"; rc=$?
    [ "${rc}" -eq 2 ] && _Report note "Apache ${ver}" "编译参数与 ${stack} 的期望不同"
    Apache_Health >/dev/null 2>&1
    _Report_Health "Apache ${ver}" "${rc}" $? "apxs、随包配置、init 脚本或 unit 缺失" \
        "./install.sh apache ${stack}（程序符合时只补写缺失文件）" \
        "配置检查未通过" "/usr/local/apache/bin/httpd -t 查看详情"
    _Report_Service "Apache" httpd "lnmp httpd start" && [ "${stack}" = lamp ] && _Report_Http "Apache" 80
    return 0
}

_Report_PHP()
{
    local stack=$1 sapi ver rc listen ext

    sapi=$(PHP_Detect_Sapi "${stack}")
    ver=$(PHP_Installed /usr/local/php); rc=$?
    if [ "${rc}" -eq 1 ]; then
        _Report bad "PHP" "未安装" "./install.sh php ${stack}"
        return 0
    elif [ "${rc}" -eq 2 ]; then
        _Report bad "PHP" "程序不可读（/usr/local/php/bin）" "./install.sh php ${stack}"
        return 0
    fi
    PHP_Check /usr/local/php "${sapi}" "${ver}"; rc=$?
    [ "${rc}" -eq 2 ] && _Report note "PHP ${ver}" "编译选项与当前 lnmp.conf 不同"
    PHP_Health /usr/local/php "${sapi}" >/dev/null 2>&1
    _Report_Health "PHP ${ver}" "${rc}" $? "php.ini、php-fpm、init 脚本或 libphp.so 缺失" \
        "./install.sh php ${stack}（重新编译，php.ini 按模板重写）" \
        "加载扩展有告警或 php-fpm 配置测试未通过" "/usr/local/php/bin/php -m；/usr/local/php/sbin/php-fpm -t"

    if [ "${rc}" -ne 1 ]; then
        for ext in $(Default_Ext_List); do
            case "$(PHPExt_Check /usr/local/php "${ext}" >/dev/null 2>&1; echo $?)" in
            0) _Report ok "PHP 扩展 ${ext}" "已加载" ;;
            2) _Report note "PHP 扩展 ${ext}" "版本与随包版本不同" ;;
            *) _Report bad "PHP 扩展 ${ext}" "未装上或未加载" "./install.sh php ${stack}（PHP 就绪时只补齐默认扩展）" ;;
            esac
        done
    fi

    if [ "${sapi}" = fpm ]; then
        _Report_Service "PHP-FPM" php-fpm "lnmp php-fpm start" || return 0
        listen=$(PHP_Fpm_Listen /usr/local/php)
        case "${listen}" in
        /*)
            if [ -S "${listen}" ]; then
                _Report ok "PHP-FPM" "监听 ${listen}"
            else
                _Report bad "PHP-FPM" "监听 socket ${listen} 不存在" "lnmp php-fpm restart"
            fi
            ;;
        esac
    fi
    return 0
}

_Report_DB()
{
    local out kind ver rc

    out=$(Database_Installed); rc=$?
    IFS=$'\t' read -r kind ver <<< "${out}"
    if [ "${rc}" -eq 1 ]; then
        _Report note "数据库" "未安装（安装时未选择或已卸载）" "需要时执行 ./install.sh db"
        return 0
    elif [ "${rc}" -eq 2 ]; then
        _Report bad "${kind}" "数据库程序不可读（/usr/local/${kind}/bin）" "先备份数据目录，再执行 ./uninstall.sh 后重新安装"
        return 0
    fi
    Database_Check "${kind}" "${ver}"; rc=$?
    if [ "${rc}" -ne 0 ]; then
        _Report bad "${kind} ${ver}" "/etc/my.cnf、/etc/init.d/${kind} 或数据目录缺失" "先备份数据目录，再执行 ./uninstall.sh 后重新安装（数据目录会先移到 /root/databases_backup_<时间>）"
        return 0
    fi
    _Report ok "${kind} ${ver}" "程序、my.cnf、init 脚本与数据目录完整"
    if ! Svc_Running "${kind}"; then
        _Report bad "${kind} ${ver}" "服务 ${kind} 未运行" "lnmp ${kind} start；仍失败时查看数据库错误日志"
    elif Database_Verify "${kind}" "${ver}" >/dev/null 2>&1; then
        _Report ok "${kind} ${ver}" "服务端响应 ping"
    else
        _Report bad "${kind} ${ver}" "服务在运行但服务端未响应 ping" "lnmp ${kind} restart；查看数据库错误日志"
    fi
    return 0
}

_Report_PMA()
{
    local ver rc

    ver=$(PhpMyAdmin_Installed); rc=$?
    [ "${rc}" -eq 1 ] && return 0
    if [ "${rc}" -eq 2 ]; then
        _Report bad "phpMyAdmin" "/usr/local/phpmyadmin 缺少版本标记" "./upgrade.sh phpmyadmin（输入要部署的版本）"
        return 0
    fi
    if PhpMyAdmin_Check "${ver}"; then
        _Report ok "phpMyAdmin ${ver}" "程序与配置完整"
    else
        _Report bad "phpMyAdmin ${ver}" "config.inc.php、访问路径或模板缓存目录缺失" "./upgrade.sh phpmyadmin（输入 ${ver} 重新部署）"
    fi
}

Stack_Report()
{
    local stack=${1:-}

    case "${stack}" in lnmp|lnmpa|lamp) ;; *) return 3 ;; esac
    Report_Bad=0
    echo "=========================================================================="
    echo "已完成过 ${stack} 的安装，本次不重新安装，只检查现有组件："
    [ "${stack}" = lamp ] || _Report_Web "${stack}"
    [ "${stack}" = lnmp ] || _Report_Apache "${stack}"
    _Report_PHP "${stack}"
    _Report_DB
    _Report_PMA
    echo "=========================================================================="
    if [ "${Report_Bad}" -eq 0 ]; then
        Echo_Green "未发现问题。"
        return 0
    fi
    Echo_Red "发现 ${Report_Bad} 个问题，按各项的处理命令修复后，可再次执行 ./install.sh ${stack} 复查。"
    echo "整体重装需先执行 ./uninstall.sh（数据库数据目录会先移到 /root/databases_backup_<时间>）。"
    return 1
}
