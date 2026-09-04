#!/usr/bin/env bash
#
# t/consistency.sh - 跨文件一致性检查

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
pass=0

ok()   { printf 'ok   %-5s %s\n' "$1" "$2"; pass=$((pass+1)); }
bad()  { printf 'FAIL %-5s %s\n' "$1" "$2"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# V1 profile.sh 内部：菜单文本数组 与 case 分支必须指向同一版本
#
# DB_Info=('MySQL 8.0.46' ...) 和 case 里的 DB_Ver='mysql-8.0.46'
# 是两处独立维护的字符串，必须保持一致。
# ---------------------------------------------------------------------------
check_v1()
{
    local drift=''
    local v
    for v in $(grep -oE "DB_Ver='(mysql|mariadb)-[0-9.]+'" include/profile.sh \
               | sed -e "s/.*-\([0-9.]*\)'/\1/"); do
        grep -qE "(MySQL|MariaDB) ${v//./\\.}('|\W)" include/profile.sh \
            || drift="${drift} DB:${v}"
    done
    for v in $(grep -oE "Php_Ver='php-[0-9.]+'" include/profile.sh \
               | sed -e "s/.*php-\([0-9.]*\)'/\1/"); do
        grep -qE "PHP ${v//./\\.}'" include/profile.sh || drift="${drift} PHP:${v}"
    done
    for v in $(grep -oE "Apache_Ver='httpd-[0-9.]+'" include/profile.sh \
               | sed -e "s/.*httpd-\([0-9.]*\)'/\1/"); do
        grep -qE "Apache ${v//./\\.}'" include/profile.sh || drift="${drift} Apache:${v}"
    done

    if [ -z "${drift}" ]; then
        ok V1 "profile.sh 菜单文本与 case 分支版本一致"
    else
        bad V1 "菜单文本里找不到对应版本：${drift}"
    fi
}

# ---------------------------------------------------------------------------
# V2 t/probe_urls.sh 的硬编码版本列表 必须与 profile.sh 一致
# 防止探测版本与实际安装版本不一致。
# ---------------------------------------------------------------------------
check_v2()
{
    local drift='' v
    for v in $(grep -oE "Php_Ver='php-[0-9.]+'" include/profile.sh | sed -e "s/.*php-\([0-9.]*\)'/\1/"); do
        grep -qE "PHP_VERS=.*${v//./\\.}" t/probe_urls.sh || drift="${drift} PHP:${v}"
    done
    for v in $(grep -oE "DB_Ver='mysql-[0-9.]+'" include/profile.sh | sed -e "s/.*mysql-\([0-9.]*\)'/\1/"); do
        grep -qE "MYSQL_VERS=.*${v//./\\.}" t/probe_urls.sh || drift="${drift} MySQL:${v}"
    done
    for v in $(grep -oE "DB_Ver='mariadb-[0-9.]+'" include/profile.sh | sed -e "s/.*mariadb-\([0-9.]*\)'/\1/"); do
        grep -qE "MARIADB_VERS=.*${v//./\\.}" t/probe_urls.sh || drift="${drift} MariaDB:${v}"
    done

    if [ -z "${drift}" ]; then
        ok V2 "probe_urls.sh 版本列表与 profile.sh 一致"
    else
        bad V2 "probe_urls.sh 缺少：${drift}"
    fi
}

# ---------------------------------------------------------------------------
# V3 t/gen_checksums.sh 的采集列表 必须与 profile.sh 一致
# 缺少对应版本时，安装会因无校验值而中止。
# ---------------------------------------------------------------------------
check_v3()
{
    local drift='' v
    for v in $(grep -oE "Php_Ver='php-[0-9.]+'" include/profile.sh | sed -e "s/.*php-\([0-9.]*\)'/\1/"); do
        grep -qE "${v//./\\.}" t/gen_checksums.sh || drift="${drift} PHP:${v}"
    done
    for v in $(grep -oE "DB_Ver='(mysql|mariadb)-[0-9.]+'" include/profile.sh | sed -e "s/.*-\([0-9.]*\)'/\1/"); do
        grep -qE "${v//./\\.}" t/gen_checksums.sh || drift="${drift} DB:${v}"
    done

    if [ -z "${drift}" ]; then
        ok V3 "gen_checksums.sh 采集列表与 profile.sh 一致"
    else
        bad V3 "gen_checksums.sh 缺少：${drift}"
    fi
}

# ---------------------------------------------------------------------------
# V4 校验清单覆盖率：version.sh 里每个版本号都要在 checksums.sha256 里出现
#
# 校验清单完整性是 fail-closed 校验生效的前提。
#
# 例外：OpenResty 只有 PGP 签名没有 sha256（见 version.sh 注释），
# 以及少数纯 Lua 库、被 PINNED 的老依赖走别的路径。
# ---------------------------------------------------------------------------
check_v4()
{
    local missing='' key val ver
    local skip='OpenResty_Ver|OpenResty_Modules_Options|NgxBrotli_Commit|Curl_Ver|Libiconv_Ver|Pcre_Ver|Libzip_Ver|Freetype_New_Ver|ZendOpcache_Ver|PHPMemcached_Ver|PHP7Memcached_Ver|PHPMemcache_Ver|PHP7Memcache_Ver|PHPOldApcu_Ver|PHPApcu_Bc_Ver|PHPSodium_Ver|Libmemcached_Ver'

    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"; val="${val%\'}"; val="${val#\'}"
        echo "${key}" | grep -qE "^(${skip})$" && continue
        # 版本号形式的值才查（跳过 NgxBrotli_Ver 这种拼接出来的）
        echo "${val}" | grep -qE '[0-9]' || continue
        grep -qF "${val}" src/checksums.sha256 || missing="${missing} ${key}=${val}"
    done < <(grep -E "^[A-Za-z_]+='[^']+'$" include/version.sh)

    if [ -z "${missing}" ]; then
        ok V4 "version.sh 各组件在校验清单中均有条目"
    else
        bad V4 "校验清单缺少：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V5 Lua 组件版本耦合：lua-resty-core 声明需要的 lua-nginx-module 版本
#     必须与 version.sh 里配的那个一致
#
# 此项为离线校验，仅比较版本号编码。lua-resty-core 的 base.lua 断言形如：
#     ngx.config.ngx_lua_version ~= 10031
# 10031 = 0*1000000 + 10*1000 + 31 = lua-nginx-module 0.10.31。
# 版本不匹配会在 nginx 首次执行 Lua 时返回 500。
#
# .github/workflows/build-test.yml 通过实际编译、启动和请求执行严格校验。
# ---------------------------------------------------------------------------
check_v5()
{
    . include/version.sh 2>/dev/null || { bad V5 "无法加载 version.sh"; return; }

    local mod="${LuaNginxModule#lua-nginx-module-}"
    local core="${LuaRestyCore#lua-resty-core-}"
    local code
    code=$(echo "${mod}" | awk -F. '{printf "%d", $1*1000000 + $2*1000 + $3}')

    # 本地存在源码时读取断言，否则由 build-test 工作流执行严格校验
    local base_lua="src/${LuaRestyCore}/lib/resty/core/base.lua"
    if [ -f "${base_lua}" ]; then
        local want
        want=$(grep -oE 'ngx\.config\.ngx_lua_version[[:space:]]*~=[[:space:]]*[0-9]+' "${base_lua}" \
               | head -1 | grep -oE '[0-9]+$')
        if [ "${want}" = "${code}" ]; then
            ok V5 "lua-resty-core ${core} 与 lua-nginx-module ${mod} 配套（断言 ${code}）"
        else
            bad V5 "lua 版本不配套：resty-core ${core} 要求 ngx_lua_version=${want}，但配的是 ${mod}(=${code})"
        fi
    else
        ok V5 "lua 版本对 ${mod} / ${core}（本地无源码，严格校验由 build-test 工作流执行）"
    fi
}

# ---------------------------------------------------------------------------
# V6 数组长度断言与实际菜单项数一致
# ---------------------------------------------------------------------------
check_v6()
{
    if bash -c '. include/profile.sh' >/dev/null 2>&1; then
        ok V6 "profile.sh 可加载，数组长度断言通过"
    else
        bad V6 "profile.sh 加载失败（多半是 *_Count 与 *_Info 长度对不上）"
    fi
}

# ---------------------------------------------------------------------------
# V7 不允许出现 CRLF 换行
#
# 本项目在 Windows 上开发、在 Linux 上运行。shell 脚本只要混进 CRLF，
# 在 Linux 上会出现 `/bin/bash^M: bad interpreter` 或
# `command not found`（行尾的 \r 被当成命令的一部分）。
#
# .gitattributes 里的 `* text=auto eol=lf` 负责在提交/检出时统一，
# CI 再次检查工作区中的实际换行格式。
#
# 排除 .gif 等二进制（它们在 .gitattributes 里标了 binary），以及 src/：
# 安装时会在其中解压第三方源码，二进制文件里的 \r 字节不是换行问题。
# ---------------------------------------------------------------------------
check_v7()
{
    local bad_files='' f
    while IFS= read -r f; do
        case "${f}" in
            *.gif|*.png|*.jpg|*.jpeg|*.ico|*.pdf|*.tar.*|*.tgz|*.zip) continue ;;
            # python 编译产物是二进制，字节序列里出现 \r 属正常。git 环境走
            # git ls-files 不会遇到（未跟踪），但本地非 git 环境的 find 分支
            # 会扫到，跑过一次 py_compile 就误报 CRLF。
            *.pyc|*/__pycache__/*) continue ;;
        esac
        # grep 可直接检查短文件中的 \r
        if LC_ALL=C grep -qU $'\r' "${f}" 2>/dev/null; then
            bad_files="${bad_files} ${f}"
        fi
    done < <(
        if git rev-parse --git-dir >/dev/null 2>&1; then
            git ls-files
        else
            find . -path ./.git -prune -o -path ./.claude -prune -o \
                   -path ./.upstream -prune -o -path ./src -prune -o \
                   -type f -print
            # src/ 整体跳过后，把其中项目自带的文件单独加回来检查。
            find src/patch src/checksums.sha256 -type f -print 2>/dev/null
        fi
    )

    if [ -z "${bad_files}" ]; then
        ok V7 "无 CRLF 换行"
    else
        bad V7 "以下文件含 CRLF，在 Linux 上会出问题：${bad_files}"
    fi
}

# ---------------------------------------------------------------------------
# V8 端口变量：脚本里引用的每个 *_Port 都必须在 lnmp.conf 里有默认值
#
# 端口是"lnmp.conf 定义 → 服务配置与 nftables 规则各自跟随"的模式。
# 少了默认值，未设该变量时展开成空串：nft 规则写不成、sed 覆写把端口写没，
# 而且两处都不会报错。
# ---------------------------------------------------------------------------
check_v8()
{
    local v missing=""
    for v in DB_Port DB_X_Port Redis_Port Memcached_Port              Pureftpd_Port Pureftpd_Data_Port Pureftpd_Passive_Min Pureftpd_Passive_Max; do
        grep -q "^${v}=" lnmp.conf || missing="${missing} ${v}"
    done
    if [ -z "${missing}" ]; then
        ok V8 "端口变量在 lnmp.conf 均有默认值"
    else
        bad V8 "lnmp.conf 缺少端口变量：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V9 端口覆写：改了服务端口就必须同时写进该服务自己的配置
#
# 只改 nftables 规则不改服务配置，服务仍监听老端口，防火墙却按新端口放行，
# 结果是服务连不上而且没有任何报错。这里确认覆写动作还在。
# ---------------------------------------------------------------------------
check_v9()
{
    local missing=""
    grep -q 'sed -i "s/\^port .\*/port \${Redis_Port}/"' include/redis.sh         || missing="${missing} redis.conf"
    grep -q 'REDISPORT=\${Redis_Port}' include/redis.sh || missing="${missing} init.d.redis"
    grep -q 'PORT=\${Memcached_Port}' include/memcached.sh || missing="${missing} init.d.memcached"
    grep -q 'port        = \${DB_Port}' include/mysql.sh || missing="${missing} mysql-my.cnf"
    grep -q 'port        = \${DB_Port}' include/mariadb.sh || missing="${missing} mariadb-my.cnf"
    grep -q 'loose-mysqlx-port = \${DB_X_Port}' include/mysql.sh || missing="${missing} mysqlx-port"
    grep -q 'port        = \${DB_Port}' include/upgrade_mysql.sh || missing="${missing} upgrade-mysql-port"
    grep -q 'port.*= \${DB_Port}' include/upgrade_mariadb.sh || missing="${missing} upgrade-mariadb-port"
    grep -q 'port.*= \${DB_Port}' include/upgrade_mysql2mariadb.sh || missing="${missing} mysql2mariadb-port"
    grep -q 'PassivePortRange .*\${Pureftpd_Passive_Min}' pureftpd.sh || missing="${missing} pure-ftpd.conf"
    grep -q 'Bind .*\${Pureftpd_Port}' pureftpd.sh || missing="${missing} pure-ftpd-Bind"
    if [ -z "${missing}" ]; then
        ok V9 "端口已覆写到各服务自己的配置"
    else
        bad V9 "以下服务配置没有跟随端口变量：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V10 端口校验必须在安装/升级入口执行，并拒绝格式、范围和关系错误
# ---------------------------------------------------------------------------
check_v10()
{
    local missing="" failed=""
    grep -q '^Validate_Service_Ports || exit 1' install.sh || missing="${missing} install.sh"
    grep -q '^Validate_Service_Ports || exit 1' upgrade.sh || missing="${missing} upgrade.sh"
    grep -q '^Validate_Service_Ports || exit 1' pureftpd.sh || missing="${missing} pureftpd.sh"
    grep -q '^Validate_Service_Ports || exit 1' addons.sh || missing="${missing} addons.sh"
    if [ -n "${missing}" ]; then
        bad V10 "以下入口未执行端口校验：${missing}"
        return
    fi

    port_case()
    {
        bash -c '
            . include/main.sh
            DB_Port=3306 DB_X_Port=33060 Redis_Port=6379
            Memcached_Port=11211 Pureftpd_Port=21 Pureftpd_Data_Port=20
            Pureftpd_Passive_Min=20000 Pureftpd_Passive_Max=30000
            eval "$1"
            Validate_Service_Ports
        ' _ "$1" >/dev/null 2>&1
    }

    port_case ':' || failed="${failed} valid"
    port_case 'DB_Port=abc' && failed="${failed} nonnumeric"
    port_case 'DB_Port=0' && failed="${failed} zero"
    port_case 'DB_Port=65536' && failed="${failed} overflow"
    port_case 'DB_Port=6379' && failed="${failed} duplicate"
    port_case 'Pureftpd_Passive_Min=30001; Pureftpd_Passive_Max=30000' && failed="${failed} reversed-range"
    port_case 'Redis_Port=25000' && failed="${failed} passive-overlap"

    if [ -z "${failed}" ]; then
        ok V10 "端口格式、范围、冲突和被动区间校验有效"
    else
        bad V10 "端口校验用例失败：${failed}"
    fi
}

# ---------------------------------------------------------------------------
# V11 安装收尾必须通过 systemd 启动服务，不能绕开
#
# 直接调 /etc/init.d/<服务> start，进程确实起来了，systemd 却不知道，
# systemctl is-active 报 inactive，后续运维命令判断不了服务状态。
# 前提是该服务得有自己的 unit，否则 StartOrStop 只能退回 SysV 脚本。
# ---------------------------------------------------------------------------
check_v11()
{
    local missing=""
    [ -s init.d/memcached.service ] || missing="${missing} memcached.service"
    grep -q 'Install_Systemd_Unit "${cur_dir}/init.d/memcached.service" /etc/systemd/system/' include/memcached.sh \
        || missing="${missing} memcached-unit-未部署"
    grep -q '^[[:space:]]*/etc/init.d/memcached start' include/memcached.sh \
        && missing="${missing} memcached-仍直调SysV"
    grep -qE 'StartOrStop (start|restart) memcached' include/memcached.sh \
        || missing="${missing} memcached-未走StartOrStop"
    # 重装会重写配置和二进制，必须 restart 才会重读；start 对已在运行的服务无效。
    grep -qE 'StartOrStop (start|restart) pureftpd' pureftpd.sh \
        || missing="${missing} pureftpd-未走StartOrStop"
    grep -q 'StartOrStop restart pureftpd' pureftpd.sh \
        || missing="${missing} pureftpd-重装未restart"
    # 自造 systemctl 判断会漏掉 WSL/容器，必须复用 Use_Systemd_Unit
    grep -q 'Use_Systemd_Unit pureftpd' pureftpd.sh \
        || missing="${missing} pureftpd-未复用Use_Systemd_Unit"
    # inet lnmp 表靠该单元跟随 nftables 重新加载，单元丢失或未部署即等于只剩
    # /etc/nftables.conf 的 include 一条路径
    [ -s init.d/lnmp-nftables.service ] || missing="${missing} lnmp-nftables.service"
    grep -q 'PartOf=nftables.service' init.d/lnmp-nftables.service 2>/dev/null \
        || missing="${missing} lnmp-nftables-未跟随nftables"
    grep -q 'if Firewall_Install_Unit; then' include/firewall.sh \
        || missing="${missing} lnmp-nftables-未在Firewall_Save部署"
    if [ -z "${missing}" ]; then
        ok V11 "服务启动统一走 systemd 判断"
    else
        bad V11 "以下启动路径绕开了 systemd：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V12 init 脚本的 status 必须有真实返回码，addons 安装前必须先确认有 PHP
#
# status 只打印文字、把最后一条 echo 的退出码当返回值，调用方（lnmp 管理命令、
# service ... status）判断服务状态必然被误导。
# addons 装的都是 PHP 扩展，没有 PHP 时若不提前拦住，会先把服务端装好一半
# 再在扩展编译处 exit 1。
# ---------------------------------------------------------------------------
check_v12()
{
    local missing=""
    grep -q 'return 3' init.d/init.d.pureftpd || missing="${missing} pureftpd-status返回码"
    grep -q '^exit \$?' init.d/init.d.pureftpd || missing="${missing} pureftpd-返回码未传出"
    grep -q 'return 3' init.d/init.d.memcached || missing="${missing} memcached-status返回码"
    # nginx、httpd、redis 的 status 用 exit 而不是 return（分支直接写在 case 里）
    grep -q 'exit 3' init.d/init.d.nginx || missing="${missing} nginx-status返回码"
    grep -q 'exit 3' init.d/init.d.httpd || missing="${missing} httpd-status返回码"
    grep -q 'exit 3' init.d/init.d.redis || missing="${missing} redis-status返回码"
    grep -q 'Check_PHP_Installed || exit 1' addons.sh || missing="${missing} addons-PHP前置检查"
    # 未知子命令什么都没装，不能返回 0
    [ "$(grep -c 'Usage: ./addons.sh' addons.sh)" -eq \
      "$(grep -A1 'Usage: ./addons.sh' addons.sh | grep -c 'exit 1')" ] \
        || missing="${missing} addons-未知子命令返回0"
    if [ -z "${missing}" ]; then
        ok V12 "init 脚本返回码真实，addons 先检查 PHP"
    else
        bad V12 "以下返回码/前置检查缺失：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V13 addons 的扩展安装函数只能 return，不能 exit
#
# 用 exit 会让整个 addons.sh 当场退出：服务端已经装好、自启也加了，
# 启动、防火墙和安装验收却全被跳过，机器停在半装状态，命令还只报一句失败。
# 这些文件里的函数全部只被 addons.sh 调用，返回码由 addons.sh 末尾统一交出去。
# ---------------------------------------------------------------------------
check_v13()
{
    local f bad_files=""
    for f in include/opcache.sh include/apcu.sh include/imageMagick.sh \
             include/memcached.sh include/redis.sh include/php_exif.sh \
             include/php_fileinfo.sh include/php_ldap.sh include/php_bz2.sh \
             include/php_sodium.sh include/php_imap.sh include/php_swoole.sh; do
        [ -f "${f}" ] || { bad_files="${bad_files} ${f}(缺失)"; continue; }
        # 去掉整行注释再找独立的 exit 词：既要抓 `    exit 1`，
        # 也要抓 `Make_Install || exit 1` 和 `f() { exit 1; }`
        grep -vE '^[[:space:]]*#' "${f}" \
            | grep -qE '(^|[[:space:]{(;&|])exit([[:space:]]|$)' \
            && bad_files="${bad_files} ${f}"
    done
    grep -q '^exit \${Addons_Rc}$' addons.sh || bad_files="${bad_files} addons.sh(未传出返回码)"
    if [ -z "${bad_files}" ]; then
        ok V13 "addons 扩展安装函数只用 return，退出码由入口传出"
    else
        bad V13 "以下文件仍用 exit 终止或未传出返回码：${bad_files}"
    fi
}

# ---------------------------------------------------------------------------
# V14 校验清单的每一行都必须是合法条目
#
# V4 只查"某个版本号有没有出现在清单里"，用的是子串匹配，因此清单被写坏
# （两行被拼成一行、缺列、混入 CRLF）时它照样通过。而安装侧
# Verify_Download_File 取值用的是 awk '$2 == 文件名' 精确匹配：
# 一旦某行被拼接，涉及的两个条目会同时查不到，安装在下载完成后才 fail-closed
# 中止，并把刚下好的文件删掉。t/refresh_checksums.sh 曾因正则用 \s 吃掉行尾
# 换行而产生这种清单，全部既有检查都没能发现。
# ---------------------------------------------------------------------------
check_v14()
{
    local sums='src/checksums.sha256' bad_lines dup
    if [ ! -s "${sums}" ]; then
        bad V14 "${sums} 缺失或为空"
        return
    fi
    # 合法行：64 位小写十六进制 + 两个空格 + 不含空白的文件名；注释行与空行放行
    bad_lines=$(grep -nvE '^([0-9a-f]{64}  [^[:space:]]+|[[:space:]]*#.*|[[:space:]]*)$' "${sums}" | head -5)
    if [ -n "${bad_lines}" ]; then
        bad V14 "校验清单存在格式非法的行：$(printf '%s' "${bad_lines}" | tr '\n' ' ')"
        return
    fi
    # 同一个落地文件名出现两条不同哈希时，awk 只取第一条，另一条形同虚设
    dup=$(awk '$1 !~ /^#/ && NF == 2 {print $2}' "${sums}" | sort | uniq -d | head -5)
    if [ -n "${dup}" ]; then
        bad V14 "校验清单有重复文件名：$(printf '%s' "${dup}" | tr '\n' ' ')"
        return
    fi
    ok V14 "校验清单每行格式合法且文件名不重复"
}

# ---------------------------------------------------------------------------
# V15 崩溃自动重启与健康检查的关键配置不能缺失
#
# Restart= 缺失时进程崩溃后不会拉起；StartLimit* 写进 [Service] 段会被
# systemd 忽略且不报错，退避形同虚设。数据库不参与自动重启，须保持
# Restart=no，避免与 mysqld_safe 形成双重启动者。
# ---------------------------------------------------------------------------
check_v15()
{
    local missing="" unit

    for unit in nginx httpd php-fpm redis memcached pureftpd php-fpm@; do
        [ -s "init.d/${unit}.service" ] || { missing="${missing} ${unit}.service缺失"; continue; }
        grep -q '^Restart=on-failure$' "init.d/${unit}.service" \
            || missing="${missing} ${unit}-无Restart"
        grep -q '^RestartSec=' "init.d/${unit}.service" \
            || missing="${missing} ${unit}-无RestartSec"
        # StartLimit* 必须落在 [Service] 之前，即 [Unit] 段内
        awk '/^\[Service\]/ { exit } /^StartLimitIntervalSec=/ { found = 1 } END { exit !found }' \
            "init.d/${unit}.service" || missing="${missing} ${unit}-StartLimit不在[Unit]段"
        grep -q '^StartLimitBurst=' "init.d/${unit}.service" \
            || missing="${missing} ${unit}-无StartLimitBurst"
        # 熔断后只标记 failed，不得触发整机重启
        grep -q '^StartLimitAction=' "init.d/${unit}.service" \
            && missing="${missing} ${unit}-配了StartLimitAction"
    done

    # Type=forking 无 PIDFile 时 systemd 靠 cgroup 猜主进程，Restart 判定不可靠
    for unit in nginx httpd php-fpm redis memcached pureftpd php-fpm@; do
        [ -s "init.d/${unit}.service" ] || continue
        grep -q '^Type=forking' "init.d/${unit}.service" || continue
        grep -q '^PIDFile=' "init.d/${unit}.service" \
            || missing="${missing} ${unit}-forking无PIDFile"
    done

    for unit in mysql mariadb; do
        grep -q '^Restart=no$' "init.d/${unit}.service" 2>/dev/null \
            || missing="${missing} ${unit}-应保持Restart=no"
    done

    [ -s tools/lnmp-health.sh ] || missing="${missing} lnmp-health.sh缺失"
    # 探针的墙钟超时优先用 timeout（coreutils），装机时必须带上该包
    grep -q 'gnupg gpgv coreutils' include/init.sh \
        || missing="${missing} apt依赖未含coreutils"
    grep -q 'nftables gnupg2 coreutils' include/init.sh \
        || missing="${missing} yum依赖未含coreutils"
    # redis 探针不能调 redis-cli：其 -t 只管连接超时，服务端卡住时不会中断。
    # 只看实际调用，注释里提到该命令不算。
    grep -vE '^[[:space:]]*#' tools/lnmp-health.sh | grep -q 'redis-cli' \
        && missing="${missing} redis探针仍调用redis-cli"
    grep -q 'tools/lnmp-health.sh:/bin/lnmp-health' include/end.sh \
        || missing="${missing} lnmp-health未随管理命令安装"
    grep -q 'Install_Systemd_Unit "${cur_dir}/init.d/php-fpm@.service" /etc/systemd/system/' include/multiplephp.sh \
        || missing="${missing} php-fpm@模板未部署"
    # lnmp kill 直接发信号会被 Restart=on-failure 判为崩溃并立即拉起
    grep -q 'Kill_By_Unit' conf/lnmp \
        || missing="${missing} lnmp-kill未先停unit"
    grep -q 'Kill_By_Unit' conf/lnmpa \
        || missing="${missing} lnmpa-kill未先停unit"
    grep -q 'Kill_By_Unit' conf/lamp \
        || missing="${missing} lamp-kill未先停unit"

    if [ -z "${missing}" ]; then
        ok V15 "自动重启与健康检查配置完整"
    else
        bad V15 "自动重启配置存在问题：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V16 php.ini 基线只允许由 PHP_Ini_Tune 写入
#
# 安装与升级各写一份 disable_functions 时，升级侧漏项会让安全基线在升级后回退
# （pcntl_exec 曾因此丢失）。tools/remove_disable_function.sh 是用户主动解除
# 限制的运维工具，不在此约束内。
# ---------------------------------------------------------------------------
check_v16()
{
    local f bad_files="" missing=""

    for f in include/php.sh include/multiplephp.sh \
             include/upgrade_php.sh include/upgrade_mphp.sh; do
        [ -f "${f}" ] || { missing="${missing} ${f}(缺失)"; continue; }
        grep -q 'PHP_Ini_Tune ' "${f}" || missing="${missing} ${f}"
    done

    for f in include/multiplephp.sh include/upgrade_php.sh include/upgrade_mphp.sh; do
        [ -f "${f}" ] || continue
        grep -q 'disable_functions =' "${f}" && bad_files="${bad_files} ${f}"
    done

    grep -q 'disable_functions =.*pcntl_exec' include/php.sh 2>/dev/null \
        || bad_files="${bad_files} include/php.sh(PHP_Ini_Tune 缺 pcntl_exec)"

    if [ -z "${bad_files}" ] && [ -z "${missing}" ]; then
        ok V16 "PHP 安装与升级路径共用 PHP_Ini_Tune 写 php.ini 基线"
    else
        bad V16 "未调用 PHP_Ini_Tune：${missing:-无}；自带 disable_functions：${bad_files:-无}"
    fi
}

# ---------------------------------------------------------------------------
# V17 lnmp fw 与安装期防火墙实现必须指向同一张表
#
# tools/lnmp-fw.sh 自带 nft 操作，不 source include/firewall.sh（管理命令是独立
# 单文件，运行期也不保证源码目录还在）。两处的表名、链名、规则文件和单元名一旦
# 分叉，安装期与运行期就各写各的表，用户看到的规则永远对不上。
# 另外三份管理命令必须都能进入 lnmp fw，回写的端口变量必须在 lnmp.conf 里存在。
check_v17()
{
    local missing='' v f

    for v in FW_TABLE FW_CHAIN FW_UNIT_NAME; do
        local a b
        a=$(grep -E "^${v}=" include/firewall.sh | head -1 | cut -d= -f2-)
        b=$(grep -E "^${v}=" tools/lnmp-fw.sh | head -1 | cut -d= -f2-)
        [ -n "${a}" ] && [ "${a}" = "${b}" ] || missing="${missing} ${v}不一致"
    done
    # lnmp-fw 的规则文件路径带测试注入默认值，只比对默认值本身
    grep -q "FW_INCLUDE_FILE:-/etc/nftables.d/lnmp.nft" tools/lnmp-fw.sh 2>/dev/null \
        || grep -q "LNMP_FW_NFT_FILE:-/etc/nftables.d/lnmp.nft" tools/lnmp-fw.sh \
        || missing="${missing} FW_INCLUDE_FILE不一致"

    for f in conf/lnmp conf/lnmpa conf/lamp; do
        grep -q '^Function_Fw()' "${f}" || missing="${missing} ${f}缺Function_Fw"
        grep -q '^    fw|firewall)' "${f}" || missing="${missing} ${f}缺fw分支"
    done

    grep -q 'tools/lnmp-fw.sh:/bin/lnmp-fw' include/end.sh \
        || missing="${missing} end.sh未安装lnmp-fw"
    grep -q '/etc/lnmp/source-dir' include/end.sh \
        || missing="${missing} end.sh未记录源码目录"

    # 回写目标改名后 sed 会静默失配，端口只在防火墙上生效、重装时倒退
    for v in $(grep -oE 'echo "[A-Za-z_]+_Port(_Min|_Max)? ' tools/lnmp-fw.sh \
               | sed -E 's/echo "//; s/ $//' | sort -u); do
        grep -q "^${v}=" lnmp.conf || missing="${missing} lnmp.conf缺${v}"
    done

    if [ -z "${missing}" ]; then
        ok V17 "lnmp fw 与安装期防火墙实现一致，三份管理命令均已接入"
    else
        bad V17 "lnmp fw 接入存在缺口：${missing}"
    fi
}

# V18 addons 端口探测两份实现必须对齐
#
# include/firewall.sh 的 Block_Addons_Ports 与 tools/lnmp-fw.sh 的 Resolve_Ports
# 读同一批配置文件、用同一套解析表达式。lnmp-fw 是独立单文件命令，运行期不保证
# 源码目录还在，无法 source firewall.sh，只能各存一份。一旦分叉，安装期阻断的
# 端口和 lnmp fw sync 重建出来的端口就不是同一个，且不会有任何报错。
check_v18()
{
    local missing='' v

    # 配置路径与测试注入点必须同名同默认值
    for v in LNMP_FW_REDIS_CONF:/usr/local/redis/etc/redis.conf \
             LNMP_FW_REDIS_DIR:/usr/local/redis \
             LNMP_FW_MEMCACHED_INIT:/etc/init.d/memcached \
             LNMP_FW_MEMCACHED_DIR:/usr/local/memcached; do
        local name="${v%%:*}" path="${v#*:}"
        grep -q "\${${name}:-${path}}" include/firewall.sh \
            || missing="${missing} firewall.sh缺${name}"
        grep -q "\${${name}:-${path}}" tools/lnmp-fw.sh \
            || missing="${missing} lnmp-fw.sh缺${name}"
    done

    # 端口解析表达式必须一致
    local redis_awk='$1 == "port" { print $2; exit }'
    local memcached_awk='$1 == "PORT" { gsub(/"/, "", $2); print $2; exit }'
    grep -qF "${redis_awk}" include/firewall.sh && grep -qF "${redis_awk}" tools/lnmp-fw.sh \
        || missing="${missing} redis端口解析不一致"
    grep -qF "${memcached_awk}" include/firewall.sh && grep -qF "${memcached_awk}" tools/lnmp-fw.sh \
        || missing="${missing} memcached端口解析不一致"

    # 安装判定必须都同时看程序目录与配置文件
    grep -q 'Redis_Dir}" \] || \[ -s "${Redis_Conf}"' tools/lnmp-fw.sh \
        || missing="${missing} lnmp-fw未按目录判定redis"
    grep -q 'Memcached_Init}" \] || \[ -d "${Memcached_Dir}"' tools/lnmp-fw.sh \
        || missing="${missing} lnmp-fw未按目录判定memcached"

    # uninstall.sh 的 Notice_Addons_Residue 判定的是同两个程序目录，必须同名同默认值，
    # 否则测试注入到临时目录后仍会读真实路径，判定结果随机器状态漂移。
    grep -q '${LNMP_FW_REDIS_DIR:-/usr/local/redis}' uninstall.sh \
        || missing="${missing} uninstall.sh未复用LNMP_FW_REDIS_DIR"
    grep -q '${LNMP_FW_MEMCACHED_DIR:-/usr/local/memcached}' uninstall.sh \
        || missing="${missing} uninstall.sh未复用LNMP_FW_MEMCACHED_DIR"

    # Stop_Addons_Services 会真的执行 init 脚本，路径必须可注入
    grep -q '${LNMP_UNINST_INITD_DIR:-/etc/init.d}' uninstall.sh \
        || missing="${missing} Stop_Addons_Services的init.d路径不可注入"
    grep -q '${LNMP_UNINST_SYSTEMD_DIR:-/etc/systemd/system}' uninstall.sh \
        || missing="${missing} Stop_Addons_Services的systemd路径不可注入"

    # Block_Addons_Ports 只应有一份定义，且在 firewall.sh
    local n
    n=$(grep -rl '^Block_Addons_Ports()' --include='*.sh' . 2>/dev/null \
        | grep -v '^\./src/' | wc -l)
    [ "${n}" = 1 ] || missing="${missing} Block_Addons_Ports定义了${n}份"
    grep -q '^Block_Addons_Ports()' include/firewall.sh \
        || missing="${missing} Block_Addons_Ports不在firewall.sh"

    if [ -z "${missing}" ]; then
        ok V18 "addons 端口与目录探测各实现一致，卸载路径可注入"
    else
        bad V18 "addons 探测已分叉或路径不可注入：${missing}"
    fi
}

echo "=== 跨文件一致性检查 ==="
check_v1
check_v2
check_v3
check_v4
check_v5
check_v6
check_v7
check_v8
check_v9
check_v10
check_v11
check_v12
check_v13
check_v14
check_v15
check_v16
check_v17
check_v18

echo
echo "通过 ${pass} 项，失败 ${fail} 项。"
[ ${fail} -eq 0 ]
