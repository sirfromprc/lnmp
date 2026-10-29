#!/usr/bin/env bash
#
# t/consistency.sh - 跨文件一致性检查

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
pass=0

# 管理命令由公共层与栈入口组装而成，内容检查针对组装后的产物。
cli_tmp=$(mktemp -d) || exit 1
trap 'rm -rf "${cli_tmp}"' EXIT
cli_product()
{
    [ -s "${cli_tmp}/$1" ] || bash include/rt/cli_assemble.sh . "$1" > "${cli_tmp}/$1" 2>/dev/null
    printf '%s' "${cli_tmp}/$1"
}

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

    # 加载时的数组长度断言（*_Count 与 *_Info）
    bash -c '. include/profile.sh' >/dev/null 2>&1 \
        || drift="${drift} profile.sh加载失败(多半是*_Count与*_Info长度不符)"
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
# V2 t/list_sources.sh 覆盖 profile.sh 菜单表的全部 PHP、数据库、Apache、phpMyAdmin 版本
# t/probe_urls.sh 与 t/gen_checksums.sh 由它取得地址；缺少条目时新版本不会被探测和采集，
# 安装会因无校验值而中止。
# ---------------------------------------------------------------------------
check_v2()
{
    local rows drift='' v
    if ! rows=$(bash t/list_sources.sh all 2>&1); then
        bad V2 "t/list_sources.sh 执行失败：$(echo "${rows}" | tail -n 3 | tr '\n' ' ')"
        return
    fi
    for v in $(sed -nE "s/.*[[:space:]]Php_Ver='([^']+)'.*/\1/p" include/profile.sh); do
        printf '%s\n' "${rows}" | cut -f4 | grep -qxF "${v}.tar.bz2" || drift="${drift} ${v}"
    done
    for v in $(sed -nE "s/.*[[:space:]]DB_Ver='([^']+)'.*/\1/p" include/profile.sh); do
        printf '%s\n' "${rows}" | cut -f4 | grep -qxF "${v}.tar.gz" || drift="${drift} ${v}"
    done
    for v in $(sed -nE "s/.*[[:space:]]Apache_Ver='([^']+)'.*/\1/p" include/profile.sh); do
        printf '%s\n' "${rows}" | cut -f4 | grep -qxF "${v}.tar.bz2" || drift="${drift} ${v}"
    done
    for v in $(sed -nE "s/.*[[:space:]]PhpMyAdmin_Ver='([^']+)'.*/\1/p" include/profile.sh); do
        printf '%s\n' "${rows}" | cut -f4 | grep -qxF "${v}.tar.xz" || drift="${drift} ${v}"
    done

    if [ -z "${drift}" ]; then
        ok V2 "t/list_sources.sh 覆盖 profile.sh 的全部版本"
    else
        bad V2 "t/list_sources.sh 缺少：${drift}"
    fi
}

# ---------------------------------------------------------------------------
# V3 校验清单覆盖率：version.sh 里每个版本号都要在 checksums.sha256 里出现
#
# 校验清单完整性是 fail-closed 校验生效的前提。
#
# 例外：OpenResty 只有 PGP 签名没有 sha256（见 version.sh 注释），
# 以及少数纯 Lua 库、被 PINNED 的老依赖走别的路径。
# ---------------------------------------------------------------------------
check_v3()
{
    local missing='' key val ver
    local skip='Nodejs_Majors|OpenResty_Ver|OpenResty_Modules_Options|NgxBrotli_Commit|Curl_Ver|Libiconv_Ver|Pcre_Ver|Libzip_Ver|Freetype_New_Ver|ZendOpcache_Ver|PHPMemcached_Ver|PHP7Memcached_Ver|PHPMemcache_Ver|PHP7Memcache_Ver|PHPOldApcu_Ver|PHPApcu_Bc_Ver|PHPSodium_Ver|Libmemcached_Ver'

    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"; val="${val%\'}"; val="${val#\'}"
        echo "${key}" | grep -qE "^(${skip})$" && continue
        # 版本号形式的值才查（跳过 NgxBrotli_Ver 这种拼接出来的）
        echo "${val}" | grep -qE '[0-9]' || continue
        grep -qF "${val}" src/checksums.sha256 || missing="${missing} ${key}=${val}"
    done < <(grep -E "^[A-Za-z_]+='[^']+'$" include/version.sh)

    # 子串匹配查不出清单被写坏（两行拼成一行、缺列、混入 CRLF）。
    # 安装侧按 awk '$2 == 文件名' 精确取值，被拼接的两个条目会同时查不到。
    local sums='src/checksums.sha256' bad_lines dup
    if [ ! -s "${sums}" ]; then
        missing="${missing} ${sums}缺失或为空"
    else
        bad_lines=$(grep -nvE '^([0-9a-f]{64}  [^[:space:]]+|[[:space:]]*#.*|[[:space:]]*)$' "${sums}" | head -5)
        [ -z "${bad_lines}" ] || missing="${missing} 格式非法行:$(printf '%s' "${bad_lines}" | tr '\n' ' ')"
        # 同名文件出现两条哈希时，awk 只取第一条，另一条形同虚设。
        dup=$(awk '$1 !~ /^#/ && NF == 2 {print $2}' "${sums}" | sort | uniq -d | head -5)
        [ -z "${dup}" ] || missing="${missing} 重复文件名:$(printf '%s' "${dup}" | tr '\n' ' ')"
    fi

    if [ -z "${missing}" ]; then
        ok V3 "校验清单格式合法、文件名唯一，version.sh 各组件均有条目"
    else
        bad V3 "校验清单有问题：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V4 不允许出现 CRLF 换行
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
check_v4()
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
        ok V4 "无 CRLF 换行"
    else
        bad V4 "以下文件含 CRLF，在 Linux 上会出问题：${bad_files}"
    fi
}

# ---------------------------------------------------------------------------
# V5 端口覆写：改了服务端口就必须同时写进该服务自己的配置
#
# 只改 nftables 规则不改服务配置，服务仍监听老端口，防火墙却按新端口放行，
# 结果是服务连不上而且没有任何报错。这里确认覆写动作还在。
# ---------------------------------------------------------------------------
# 函数体整体读入后匹配，避免 pipefail 下 grep -q 提前退出造成 SIGPIPE 误判。
db_fn_has()
{
    local text
    text=$(sed -n "/^$1()/,/^}/p" include/mod/database.sh)
    grep -q -- "$2" <<< "${text}"
}

check_v5()
{
    local missing=""
    grep -q 'sed -i "s/\^port .\*/port \${Redis_Port}/"' include/redis.sh         || missing="${missing} redis.conf"
    grep -q 'REDISPORT=\${Redis_Port}' include/redis.sh || missing="${missing} init.d.redis"
    grep -q 'PORT=\${Memcached_Port}' include/memcached.sh || missing="${missing} init.d.memcached"
    db_fn_has _Database_Install_MySQL 'port        = \${DB_Port}' || missing="${missing} mysql-my.cnf"
    db_fn_has _Database_Install_MariaDB 'port        = \${DB_Port}' || missing="${missing} mariadb-my.cnf"
    db_fn_has _Database_Install_MySQL 'loose-mysqlx-port = \${DB_X_Port}' || missing="${missing} mysqlx-port"
    db_fn_has _Database_Build_MySQL 'port        = \${DB_Port}' || missing="${missing} upgrade-mysql-port"
    db_fn_has _Database_Upgrade_MariaDB 'port.*= \${DB_Port}' || missing="${missing} upgrade-mariadb-port"
    db_fn_has _Database_Migrate_Run 'port.*= \${DB_Port}' || missing="${missing} mysql2mariadb-port"
    grep -q 'PassivePortRange .*\${pmin} \${pmax}' include/mod/pureftpd.sh || missing="${missing} pure-ftpd.conf"
    grep -q 'Bind .*0\.0\.0\.0,\${ctl}' include/mod/pureftpd.sh || missing="${missing} pure-ftpd-Bind"
    grep -q 'Pureftpd_Install "${Pureftpd_Ver#pure-ftpd-}" "${Pureftpd_Port}"' pureftpd.sh \
        && grep -q '"${Pureftpd_Passive_Min}" "${Pureftpd_Passive_Max}"' pureftpd.sh \
        || missing="${missing} pureftpd.sh未传入端口变量"
    if [ -z "${missing}" ]; then
        ok V5 "端口已覆写到各服务自己的配置"
    else
        bad V5 "以下服务配置没有跟随端口变量：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V6 端口变量必须在 lnmp.conf 有默认值，端口校验必须在安装/升级入口执行，
#     并拒绝格式、范围和关系错误
#
# 缺少默认值时变量展开成空串：nft 规则写不成、sed 覆写把端口写没，且都不报错。
# ---------------------------------------------------------------------------
check_v6()
{
    local missing="" failed="" v
    for v in DB_Port DB_X_Port Redis_Port Memcached_Port Pureftpd_Port \
             Pureftpd_Data_Port Pureftpd_Passive_Min Pureftpd_Passive_Max; do
        grep -q "^${v}=" lnmp.conf || missing="${missing} lnmp.conf缺${v}"
    done
    grep -q '^Validate_Service_Ports || exit 1' install.sh || missing="${missing} install.sh"
    grep -q '^Validate_Service_Ports || exit 1' upgrade.sh || missing="${missing} upgrade.sh"
    grep -q '^Validate_Service_Ports || exit 1' pureftpd.sh || missing="${missing} pureftpd.sh"
    grep -q '^Validate_Service_Ports || exit 1' addons.sh || missing="${missing} addons.sh"
    if [ -n "${missing}" ]; then
        bad V6 "以下入口未执行端口校验：${missing}"
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
        ok V6 "端口格式、范围、冲突和被动区间校验有效"
    else
        bad V6 "端口校验用例失败：${failed}"
    fi
}

# ---------------------------------------------------------------------------
# V7 安装收尾必须通过 systemd 启动服务，不能绕开
#
# 直接调 /etc/init.d/<服务> start，进程确实起来了，systemd 却不知道，
# systemctl is-active 报 inactive，后续运维命令判断不了服务状态。
# 前提是该服务得有自己的 unit，否则 StartOrStop 只能退回 SysV 脚本。
# ---------------------------------------------------------------------------
check_v7()
{
    local missing=""
    [ -s init.d/memcached.service ] || missing="${missing} memcached.service"
    grep -q 'Svc_Install_Unit "${cur_dir}/init.d/memcached.service" /etc/systemd/system/' include/memcached.sh \
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
    # 自造 systemctl 判断会漏掉 WSL/容器，必须复用 Svc_Use_Systemd
    grep -q 'Svc_Use_Systemd pureftpd' include/mod/pureftpd.sh \
        || missing="${missing} pureftpd-未复用Use_Systemd_Unit"
    # inet lnmp 表靠该单元跟随 nftables 重新加载，单元丢失或未部署即等于只剩
    # /etc/nftables.conf 的 include 一条路径
    [ -s init.d/lnmp-nftables.service ] || missing="${missing} lnmp-nftables.service"
    grep -q 'PartOf=nftables.service' init.d/lnmp-nftables.service 2>/dev/null \
        || missing="${missing} lnmp-nftables-未跟随nftables"
    grep -q 'if Fw_Install_Unit "${cur_dir}/init.d/${FW_UNIT_NAME}.service"; then' include/firewall.sh \
        || missing="${missing} lnmp-nftables-未在Firewall_Save部署"
    if [ -z "${missing}" ]; then
        ok V7 "服务启动统一走 systemd 判断"
    else
        bad V7 "以下启动路径绕开了 systemd：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V8 init 脚本的 status 必须有真实返回码，addons 安装前必须先确认有 PHP
#
# status 只打印文字、把最后一条 echo 的退出码当返回值，调用方（lnmp 管理命令、
# service ... status）判断服务状态必然被误导。
# addons 装的都是 PHP 扩展，没有 PHP 时若不提前拦住，会先把服务端装好一半
# 再在扩展编译处 exit 1。
# ---------------------------------------------------------------------------
check_v8()
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
        ok V8 "init 脚本返回码真实，addons 先检查 PHP"
    else
        bad V8 "以下返回码/前置检查缺失：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V9 addons 的扩展安装函数只能 return，不能 exit
#
# 用 exit 会让整个 addons.sh 当场退出：服务端已经装好、自启也加了，
# 启动、防火墙和安装验收却全被跳过，机器停在半装状态，命令还只报一句失败。
# 这些文件里的函数全部只被 addons.sh 调用，返回码由 addons.sh 末尾统一交出去。
# ---------------------------------------------------------------------------
check_v9()
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
        ok V9 "addons 扩展安装函数只用 return，退出码由入口传出"
    else
        bad V9 "以下文件仍用 exit 终止或未传出返回码：${bad_files}"
    fi
}

# ---------------------------------------------------------------------------
# V10 崩溃自动重启与健康检查的关键配置不能缺失
#
# Restart= 缺失时进程崩溃后不会拉起；StartLimit* 写进 [Service] 段会被
# systemd 忽略且不报错，退避形同虚设。数据库不参与自动重启，须保持
# Restart=no，避免与 mysqld_safe 形成双重启动者。
# ---------------------------------------------------------------------------
check_v10()
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

    # /run/php-fpm 由主版本与多版本共用，任一单元停止不得删除该目录
    for unit in php-fpm php-fpm@; do
        grep -q '^RuntimeDirectoryPreserve=yes$' "init.d/${unit}.service" 2>/dev/null \
            || missing="${missing} ${unit}-无RuntimeDirectoryPreserve"
    done
    # PHP 安装写入 unit，升级刷新已存在的 unit；主版本与多版本模板由同一函数选取
    grep -qF 'php-fpm\tphp-fpm\tphp-fpm.service' include/mod/php.sh \
        && grep -qF 'php-fpm@.service' include/mod/php.sh \
        || missing="${missing} PHP模块缺少php-fpm单元模板"
    [ "$(grep -c 'Svc_Install_Unit "${cur_dir}/init.d/${tpl}"' include/mod/php.sh)" -ge 2 ] \
        || missing="${missing} PHP模块未在安装与升级时写入unit"

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
    grep -q 'tools/lnmp-health.sh' include/end.sh \
        || missing="${missing} lnmp-health未随管理命令安装"
    # lnmp kill 直接发信号会被 Restart=on-failure 判为崩溃并立即拉起
    for f in lnmp lnmpa lamp; do
        grep -q 'Kill_By_Unit' "$(cli_product "${f}")" \
            || missing="${missing} ${f}-kill未先停unit"
    done

    if [ -z "${missing}" ]; then
        ok V10 "自动重启与健康检查配置完整"
    else
        bad V10 "自动重启配置存在问题：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V11 php.ini 基线只允许由 PHP 模块的 _PHP_Ini_Tune 写入
#
# 安装与升级各写一份 disable_functions 时，升级侧漏项会让安全基线在升级后回退
# （pcntl_exec 曾因此丢失）。tools/remove_disable_function.sh 是用户主动解除
# 限制的运维工具，不在此约束内。
# ---------------------------------------------------------------------------
check_v11()
{
    local bad_files="" missing=""

    [ -f include/mod/php.sh ] || missing="include/mod/php.sh(缺失)"
    grep -q '_PHP_Ini_Tune "${ini}.lnmp-new"' include/mod/php.sh 2>/dev/null \
        || missing="${missing} _PHP_Ini_Write未调用_PHP_Ini_Tune"
    grep -q 'disable_functions =.*pcntl_exec' include/mod/php.sh 2>/dev/null \
        || bad_files="${bad_files} include/mod/php.sh(_PHP_Ini_Tune 缺 pcntl_exec)"
    bad_files="${bad_files} $(grep -rlF 'disable_functions =' --include='*.sh' install.sh upgrade.sh addons.sh include 2>/dev/null \
        | grep -vx 'include/mod/php.sh' | tr '\n' ' ')"
    bad_files="${bad_files%% }"
    bad_files="${bad_files## }"

    if [ -z "${bad_files}" ] && [ -z "${missing}" ]; then
        ok V11 "php.ini 基线只由 PHP 模块写入"
    else
        bad V11 "缺失：${missing:-无}；模块之外写 disable_functions：${bad_files:-无}"
    fi
}

# ---------------------------------------------------------------------------
# V12 lnmp fw 与安装期防火墙共用一份运行部分
#
# 规则表、链、规则文件与单元名以及后端判定、链重建、持久化、清除只在 include/rt/fw.sh
# 定义：安装器经 include/main.sh 加载，tools/lnmp-fw.sh 以 "# @RT_FW@" 加载行在部署时并入。
# 两处各存一份时，取值一旦分叉，安装期与运行期就各写各的表。
# 另外三份管理命令必须都能进入 lnmp fw，回写的端口变量必须在 lnmp.conf 里存在。
check_v12()
{
    local missing='' v f names out

    out=$(grep -rnE --include='*.sh' -e '^[[:space:]]*FW_(TABLE|CHAIN|INCLUDE_FILE|UNIT_NAME|UNIT_FILE)=' \
              . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null \
          | grep -v -E '^\./(t|src|tests)/|^\./include/rt/fw\.sh:')
    [ -z "${out}" ] || missing="${missing} 常量在fw.sh之外定义"
    names=$(grep -oE '^[A-Za-z_]+\(\)' include/rt/fw.sh 2>/dev/null | tr -d '()' | paste -sd '|')
    if [ -z "${names}" ]; then
        missing="${missing} 缺include/rt/fw.sh"
    else
        out=$(grep -rnE --include='*.sh' -e "^[[:space:]]*(${names})\\(\\)" . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null \
              | grep -v -E '^\./(t|src|tests)/|^\./include/rt/fw\.sh:')
        [ -z "${out}" ] || missing="${missing} 函数在fw.sh之外重复定义:$(echo "${out}" | sed -E 's/^[^:]*:[0-9]+:[[:space:]]*//; s/\(\).*//' | paste -sd ',')"
    fi
    grep -q '/rt/fw\.sh"$' include/main.sh || missing="${missing} main.sh未加载fw.sh"
    grep -q '# @RT_FW@$' tools/lnmp-fw.sh || missing="${missing} lnmp-fw缺fw.sh加载行"
    grep -q '# @RT_SVC@$' tools/lnmp-fw.sh || missing="${missing} lnmp-fw缺svc.sh加载行"

    for f in lnmp lnmpa lamp; do
        grep -q '^Function_Fw()' "$(cli_product "${f}")" || missing="${missing} ${f}缺Function_Fw"
        grep -q '^    fw|firewall)' "$(cli_product "${f}")" || missing="${missing} ${f}缺fw分支"
    done

    grep -q 'tools/lnmp-fw.sh' include/end.sh \
        || missing="${missing} end.sh未安装lnmp-fw"
    grep -q '/etc/lnmp/source-dir' include/end.sh \
        || missing="${missing} end.sh未记录源码目录"

    # 回写目标改名后 sed 会静默失配，端口只在防火墙上生效、重装时倒退
    for v in $(grep -oE 'echo "[A-Za-z_]+_Port(_Min|_Max)? ' tools/lnmp-fw.sh \
               | sed -E 's/echo "//; s/ $//' | sort -u); do
        grep -q "^${v}=" lnmp.conf || missing="${missing} lnmp.conf缺${v}"
    done

    if [ -z "${missing}" ]; then
        ok V12 "lnmp fw 与安装期防火墙共用 include/rt/fw.sh，三份管理命令均已接入"
    else
        bad V12 "lnmp fw 接入存在缺口：${missing}"
    fi
}

# V13 addons 端口探测只有一份解析
#
# include/firewall.sh 的 Block_Addons_Ports 与 tools/lnmp-fw.sh 的 Resolve_Ports 读同一批
# 配置文件，解析统一走 include/rt/fw.sh 的 Fw_Redis_Port、Fw_Memcached_Port。
# 一旦分叉，安装期阻断的端口和 lnmp fw sync 重建出来的端口就不是同一个，且不会有任何报错。
check_v13()
{
    local missing='' v out

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

    # 防火墙两侧不自带端口解析表达式，都经 fw.sh 的共用函数取端口
    out=$(grep -rnF --include='*.sh' -e '$1 == "port" { print $2; exit }' -e '$1 == "PORT" { gsub(/"/, "", $2)' \
              include/firewall.sh tools/lnmp-fw.sh 2>/dev/null)
    [ -z "${out}" ] || missing="${missing} 防火墙自带端口解析:$(echo "${out}" | cut -d: -f1 | sort -u | paste -sd ',')"
    for v in Fw_Redis_Port Fw_Memcached_Port; do
        grep -q "${v} " include/firewall.sh || missing="${missing} firewall.sh未调用${v}"
        grep -q "${v} " tools/lnmp-fw.sh || missing="${missing} lnmp-fw未调用${v}"
    done

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
        ok V13 "addons 端口解析只有一份，目录探测一致，卸载路径可注入"
    else
        bad V13 "addons 探测已分叉或路径不可注入：${missing}"
    fi
}

# ---------------------------------------------------------------------------
# V14 OPcache 参数只允许由 Enable_Opcache_Config 写入
#
# 主版本安装、多版本安装、两条升级路径与 addons 各写一份时，参数与加载方式
# 会分叉（8.5 起无 opcache.so，旧实现按 .so 判定后静默跳过）。
# ---------------------------------------------------------------------------
check_v14()
{
    local f missing='' extra

    for f in include/php_default_ext.sh include/multiplephp.sh include/mod/php.sh include/opcache.sh; do
        [ -f "${f}" ] || { missing="${missing} ${f}(缺失)"; continue; }
        grep -qE 'Enable_Opcache_Config|Install_PHP_Default_Ext' "${f}" || missing="${missing} ${f}"
    done
    extra=$(grep -rl 'opcache\.memory_consumption' --include='*.sh' include 2>/dev/null \
        | grep -v '^include/php_default_ext\.sh$' | tr '\n' ' ')

    if [ -z "${missing}" ] && [ -z "${extra}" ]; then
        ok V14 "OPcache 配置由 Enable_Opcache_Config 统一写入"
    else
        bad V14 "未调用 Enable_Opcache_Config：${missing:-无}；自写 OPcache 参数：${extra:-无}"
    fi
}

# ---------------------------------------------------------------------------
# V15 同一加载单元内函数只能定义一次
#
# source 顺序决定哪份生效，重名定义不报错，后加载者静默覆盖前者。
# 加载单元：安装器侧（入口脚本、include/、tools/lnmp-tgnotice.sh）、
# 每份管理命令与其公共层、每个独立的 tools/*.sh。
# 判定跳过 heredoc 与注释，生成脚本中的函数文本不计。
# ---------------------------------------------------------------------------
list_func_defs()
{
    awk '
    heredoc {
        if ($0 == delim || (dash && $0 ~ ("^\t*" delim "$"))) heredoc = 0
        next
    }
    /^[[:space:]]*#/ { next }
    {
        if (match($0, /^[A-Za-z_][A-Za-z0-9_.:-]*\(\)/)) print substr($0, 1, RLENGTH - 2)
        if (match($0, /(^|[^<])<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
            w = substr($0, RSTART, RLENGTH)
            dash = (w ~ /<<-/)
            sub(/^[^<]*<<-?[ \t]*/, "", w)
            gsub(/["'"'"']/, "", w)
            delim = w
            heredoc = 1
        }
    }' "$@"
}

check_v15()
{
    local unit dup='' d f
    local -a files

    # 每个单元一行：文件列表以空格分隔
    local units=()
    units+=("install.sh upgrade.sh addons.sh uninstall.sh tools/lnmp-tgnotice.sh $(find include -name '*.sh' -not -path 'include/rt/cli_*' | sort | tr '\n' ' ')")
    for f in lnmp lnmpa lamp; do
        units+=("conf/${f} include/rt/svc.sh include/rt/cli_common.sh $(grep -qxF '# @CLI_NGINX@' "conf/${f}" && echo include/rt/cli_nginx.sh)")
    done
    for f in tools/*.sh; do
        [ "${f}" = tools/lnmp-tgnotice.sh ] || units+=("${f}")
    done

    for unit in "${units[@]}"; do
        read -r -a files <<< "${unit}"
        d=$(list_func_defs "${files[@]}" | sort | uniq -d | tr '\n' ' ')
        [ -z "${d}" ] || dup="${dup} [${files[0]}…:${d}]"
    done

    if [ -z "${dup}" ]; then
        ok V15 "各加载单元内函数定义唯一"
    else
        bad V15 "存在重复定义：${dup}"
    fi
}

# ---------------------------------------------------------------------------
# V16 已部署的管理命令不得被原地改写
#
# /bin/lnmp 与 /bin/lnmp-* 只能由部署函数整体写入。原地 sed 在重新部署后
# 被覆盖，且依赖目标文件中存在特定文本，目标变化时静默失效。
# ---------------------------------------------------------------------------
check_v16()
{
    local out
    out=$(grep -rnE 'sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-i[^|;&]*/bin/lnmp' \
            --include='*.sh' . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null \
          | grep -v -E '^\./(t|src)/|:[0-9]+:[[:space:]]*#')
    if [ -z "${out}" ]; then
        ok V16 "无对 /bin/lnmp 与 /bin/lnmp-* 的原地改写"
    else
        bad V16 "存在原地改写：$(echo "${out}" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# V17 PHP 扩展的构建只在扩展模块实现
#
# phpize 调用与 pecl.php.net 的下载地址只允许出现在 include/mod/php_ext.sh。
# 其它位置自行编译扩展会绕过加载验证、旧产物恢复和归档成员检查。
# t/ 下的探测与校验采集脚本不属于安装路径，不在范围内。
# ---------------------------------------------------------------------------
check_v17()
{
    local out
    out=$(grep -rnE 'phpize|pecl\.php\.net/get' --include='*.sh' . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null \
          | grep -v -E '^\./(t|src|tests)/|^\./include/mod/php_ext\.sh:' \
          | grep -v -E ':[0-9]+:[[:space:]]*#' \
          | grep -v -E 'ln -sf [^ ]*phpize' )
    if [ -z "${out}" ]; then
        ok V17 "phpize 与 PECL 下载地址只出现在扩展模块"
    else
        bad V17 "扩展构建出现在模块之外：$(echo "${out}" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# V18 PHP 本体的构建只在 PHP 模块实现
#
# PHP 的 SAPI 参数（--enable-fpm、--with-apxs2）、php.ini-production 与 INSTALL_ROOT
# 暂存只允许出现在 include/mod/php.sh。安装、多版本、升级各写一份 configure 时，
# 增删编译项会漏改其中一处。t/ 下的 CI 构建脚本不属于安装路径。
# ---------------------------------------------------------------------------
check_v18()
{
    local out
    out=$(grep -rnE --include='*.sh' -e '--enable-fpm|--with-apxs2|php\.ini-production|INSTALL_ROOT=' \
            . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null \
          | grep -v -E '^\./(t|src|tests)/|^\./include/mod/php\.sh:' \
          | grep -v -E ':[0-9]+:[[:space:]]*#')
    if [ -z "${out}" ]; then
        ok V18 "PHP 本体的构建参数只出现在 PHP 模块"
    else
        bad V18 "PHP 构建出现在模块之外：$(echo "${out}" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# V19 Nginx 与 OpenResty 的构建只在各自模块实现
#
# --prefix=/usr/local/nginx 只允许出现在 include/mod/nginx.sh，--prefix=/usr/local/openresty
# 只允许出现在 include/mod/openresty.sh；--with-http_spdy_module 已无对应版本，不得重新出现。
# t/ 下的 CI 构建脚本不属于安装路径。
# ---------------------------------------------------------------------------
check_v19()
{
    local out
    out=$( { grep -rnE --include='*.sh' -e '--prefix=/usr/local/nginx' . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null \
               | grep -v -E '^\./include/mod/nginx\.sh:'
             grep -rnE --include='*.sh' -e '--prefix=/usr/local/openresty' . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null \
               | grep -v -E '^\./include/mod/openresty\.sh:'
             grep -rnE --include='*.sh' -e '--with-http_spdy_module' . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null
           } | grep -v -E '^\./(t|src|tests)/' | grep -v -E ':[0-9]+:[[:space:]]*#')
    if [ -z "${out}" ] && [ -f include/mod/nginx.sh ] && [ -f include/mod/openresty.sh ]; then
        ok V19 "Nginx 与 OpenResty 的构建参数只出现在各自模块"
    else
        bad V19 "Nginx 或 OpenResty 构建出现在模块之外或模块缺失：$(echo "${out}" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# V20 phpMyAdmin 的部署只在 phpMyAdmin 模块实现
#
# 下载地址 files.phpmyadmin.net 与配置模板 conf/config.inc.php 只允许出现在
# include/mod/phpmyadmin.sh。完整安装、独立安装、升级各写一份解包与配置时，占位符与权限会漏改其中一处。
# include/verify.sh 的 Upstream_SHA256 按项目取上游校验值，属于校验原语，不在范围内。
# ---------------------------------------------------------------------------
check_v20()
{
    local out
    out=$(grep -rnE --include='*.sh' -e 'files\.phpmyadmin\.net|conf/config\.inc\.php' \
            . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null \
          | grep -v -E '^\./(t|src|tests)/|^\./include/mod/phpmyadmin\.sh:|^\./include/verify\.sh:' \
          | grep -v -E ':[0-9]+:[[:space:]]*#')
    if [ -z "${out}" ] && [ -f include/mod/phpmyadmin.sh ]; then
        ok V20 "phpMyAdmin 的下载与配置模板只出现在 phpMyAdmin 模块"
    else
        bad V20 "phpMyAdmin 部署出现在模块之外或模块缺失：$(echo "${out}" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# V21 服务单元的写入与重载只在服务运行部分实现
#
# include/rt/svc.sh 定义的函数不得在别处重复定义；systemctl daemon-reload 只允许在该文件执行。
# tools/lnmp-*.sh 调用这些函数时必须有以 "# @RT_SVC@" 结尾的加载行，部署时由 cli_assemble.sh 展开。
# tools/lnmp-backup-vault.sh 在未安装 LNMP 的备份机上以单文件运行，自带 unit 写入与重载，
# 不受上述限制，但不得含 @RT_*@ 加载行。
# ---------------------------------------------------------------------------
check_v21()
{
    local out f names standalone='tools/lnmp-backup-vault.sh'
    names=$(grep -oE '^Svc_[A-Za-z_]+\(\)' include/rt/svc.sh 2>/dev/null | tr -d '()' | paste -sd '|')
    out=$( { [ -z "${names}" ] || grep -rnE --include='*.sh' -e "^[[:space:]]*(${names})\\(\\)" \
                 . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null
             grep -rnE --include='*.sh' -e '(^|[;&|{(]|then|do|else)[[:space:]]*systemctl daemon-reload' \
                 . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null
           } | grep -v -E "^\./(t|src|tests)/|^\./include/rt/svc\.sh:|^\./${standalone}:")
    grep -qE '# @RT_[A-Z]+@$' "${standalone}" 2>/dev/null && out="${out} ${standalone}:单文件运行脚本不得含加载行"
    for f in tools/lnmp-*.sh; do
        [ -n "${names}" ] && grep -qE "(^|[^_[:alnum:]])(${names})([^_[:alnum:]]|$)" "${f}" || continue
        grep -q '# @RT_SVC@$' "${f}" || out="${out} ${f}:缺加载行"
    done
    if [ -z "${out}" ] && [ -f include/rt/svc.sh ]; then
        ok V21 "服务单元判定、写入与重载只在服务运行部分实现"
    else
        bad V21 "服务运行部分之外出现定义或重载：$(echo "${out}" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# V22 数据库识别、my.cnf 取值、socket 与端口只在数据库运行部分实现
#
# include/rt/db.sh 定义的函数及其替换前的旧名不得在别处定义；
# tools/lnmp-*.sh 调用这些函数时必须有以 "# @RT_DB@" 结尾的加载行。
# ---------------------------------------------------------------------------
check_v22()
{
    local out f names
    names=$(grep -oE '^Db_[A-Za-z_]+\(\)' include/rt/db.sh 2>/dev/null | tr -d '()' | paste -sd '|')
    out=$( { [ -z "${names}" ] || grep -rnE --include='*.sh' -e "^[[:space:]]*(${names})\\(\\)" \
                 . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null
             grep -rnE --include='*.sh' \
                 -e '^[[:space:]]*(Get_Actual_DB_Socket|Get_Actual_DB_Port|Get_Mysqld_Conf_Value|Db_Socket_Path)\(\)' \
                 . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null
           } | grep -v -E '^\./(t|src|tests)/|^\./include/rt/db\.sh:')
    for f in tools/lnmp-*.sh; do
        [ -n "${names}" ] && grep -qE "(^|[^_[:alnum:]])(${names})([^_[:alnum:]]|$)" "${f}" || continue
        grep -q '# @RT_DB@$' "${f}" || out="${out} ${f}:缺加载行"
    done
    if [ -z "${out}" ] && [ -n "${names}" ]; then
        ok V22 "数据库识别、配置取值、socket 与端口只在数据库运行部分实现"
    else
        bad V22 "数据库运行部分之外出现定义：$(echo "${out}" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# V23 数据库的下载地址与数据目录初始化只在数据库模块实现
#
# include/verify.sh 为上游校验原语，include/version.sh 只记版本号；升级与迁移入口经 Database_Sources 取下载地址。
# MariaDB 只匹配下载接口路径，入口提示中的版本查询网址不计。
# ---------------------------------------------------------------------------
check_v23()
{
    local out
    out=$(grep -rlE --include='*.sh' \
              -e '--initialize-insecure|mariadb-install-db|mysql_install_db|cdn\.mysql\.com|downloads\.mariadb\.org/rest-api' \
              . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null \
          | grep -v -E '^\./(t|src|tests)/|^\./include/(mod/database|verify|version)\.sh$')
    if [ -z "${out}" ] && [ -f include/mod/database.sh ]; then
        ok V23 "数据库的下载地址与数据目录初始化只出现在数据库模块"
    else
        bad V23 "数据库安装出现在模块之外或模块缺失：$(echo "${out}" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# V24 Apache 的下载地址与构建参数只在 Apache 模块实现
#
# t/ 下的探测与校验清单生成脚本除外。
# ---------------------------------------------------------------------------
check_v24()
{
    local out
    out=$(grep -rlE --include='*.sh' \
              -e 'archive\.apache\.org/dist|nghttp2/releases|--prefix=/usr/local/apache|--prefix=/usr/local/nghttp2' \
              . conf/lnmp conf/lnmpa conf/lamp 2>/dev/null \
          | grep -v -E '^\./(t|src|tests)/|^\./include/mod/apache\.sh$')
    if [ -z "${out}" ] && [ -f include/mod/apache.sh ] && [ ! -e include/apache.sh ]; then
        ok V24 "Apache 的下载地址与构建参数只出现在 Apache 模块"
    else
        bad V24 "Apache 构建出现在模块之外或模块缺失：$(echo "${out}" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# V25 源码包下载地址只写在 *_Sources 函数内
# 探测、采集与安装共用 *_Sources 输出；函数外的地址字面量不会被 t/probe_urls.sh
# 探测，也不会被 t/gen_checksums.sh 采集。注释行、t/、tests/、src/ 与 docs/ 不检查。
# ---------------------------------------------------------------------------
check_v25()
{
    local out
    out=$(find . \( -path ./t -o -path ./tests -o -path ./src -o -path ./docs -o -path ./.git \) -prune -o \
              -type f \( -name '*.sh' -o -path ./conf/lnmp -o -path ./conf/lnmpa -o -path ./conf/lamp \) -print \
          | sort | xargs awk '
              FNR == 1 { fn = "" }
              /^[A-Za-z_][A-Za-z_0-9]*\(\)/ { fn = $0; sub(/\(\).*/, "", fn) }
              /^}/ { fn = ""; next }
              /^[[:space:]]*#/ { next }
              /https:\/\/[^[:space:]"]*\.(tar\.gz|tar\.bz2|tar\.xz|tgz|zip)([^A-Za-z0-9]|$)|getcomposer\.org\/installer/ {
                  if (fn !~ /_Sources$/) print FILENAME ":" FNR
              }
              # 单行函数在本行结束，后续行不再归入该函数。
              /^[A-Za-z_][A-Za-z_0-9]*\(\).*}[[:space:]]*$/ { fn = "" }')
    if [ -z "${out}" ]; then
        ok V25 "源码包下载地址只出现在 *_Sources 函数内"
    else
        bad V25 "*_Sources 之外的下载地址：$(echo "${out}" | tr '\n' ' ')"
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
check_v19
check_v20
check_v21
check_v22
check_v23
check_v24
check_v25

echo
echo "通过 ${pass} 项，失败 ${fail} 项。"
[ ${fail} -eq 0 ]
