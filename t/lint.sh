#!/usr/bin/env bash
#
# t/lint.sh - 静态检查
#
# 用法：bash t/lint.sh [检查ID]
#   不带参数执行全部检查；带参数仅执行指定项，如 bash t/lint.sh C1

cd "$(dirname "$0")/.." || exit 1

fail=0
only="$1"

# 优先使用 rg，不可用时使用 grep
if command -v rg >/dev/null 2>&1; then
    SEARCH="rg"
else
    SEARCH="grep"
fi

# src/ 存放安装时解压的第三方源码，不属于本项目代码，扫到会误报。
_filter()
{
    grep -v -E '^\./(t|src)/|^(t|src)/' | grep -v -E ':[0-9]+:[[:space:]]*#'
}

_search()
{
    # _search <pattern> [额外的 --glob 参数...]
    local pat="$1"; shift
    if [ "${SEARCH}" = "rg" ]; then
        rg -n --pcre2 "${pat}" "$@" 2>/dev/null | _filter
    else
        grep -rnP "${pat}" --include='*.sh' . 2>/dev/null | _filter
    fi
}

# expect_empty <ID> <说明> <pattern> [glob...]
expect_empty()
{
    local id="$1" desc="$2" pat="$3"; shift 3
    [ -n "${only}" ] && [ "${only}" != "${id}" ] && return 0

    local out
    out=$(_search "${pat}" "$@")
    if [ -z "${out}" ]; then
        printf 'ok   %-4s %s\n' "${id}" "${desc}"
    else
        printf 'FAIL %-4s %s\n' "${id}" "${desc}"
        echo "${out}" | sed 's/^/       /'
        fail=1
    fi
}

echo "=== 静态自检 ==="

# C1 收敛不变式：选择变量只允许出现在映射表和菜单读取处
#
# 允许的文件：
#   profile.sh       映射表本身
#   main.sh          主菜单读取
#   multiplephp.sh   多版本 PHP 安装菜单读取
#   upgrade_mphp.sh  多版本 PHP 升级菜单读取（MPHP_Select 是纯局部读取变量，
#                    读进来后立刻经 Set_PHP_Profile 翻译为 PHP_Branch，
#                    之后不再参与任何版本判断）
[ -z "${only}" ] || [ "${only}" = "C1" ] && {
    # tests/ 是定向测试，需要直接构造这些变量来验证菜单读取行为。
    out=$(_search 'DBSelect|PHPSelect|ApacheSelect|MPHP_Select' -g '*.sh' \
          | grep -v -E '^\.?/?include[/\\](profile|main|multiplephp|upgrade_mphp)\.sh:' \
          | grep -v -E '^\.?/?tests[/\\]')
    if [ -z "${out}" ]; then
        printf 'ok   %-4s %s\n' C1 "编号变量只出现在 profile/main/multiplephp/upgrade_mphp"
    else
        printf 'FAIL %-4s %s\n' C1 "编号变量泄漏到其它文件"
        echo "${out}" | sed 's/^/       /'
        fail=1
    fi
}

expect_empty C2  "无残留旧版本标识" \
    '(mysql-5\.|mariadb-5\.5|mariadb-10\.[4-6]\.|php-5\.|php-7\.)' -g '*.sh'

expect_empty C3a "DB_Info 下标未越界" \
    '\$\{DB_Info\[(?:[5-9]|[1-9][0-9]+)\]' -g '*.sh'

expect_empty C3b "PHP_Info 下标未越界" \
    '\$\{PHP_Info\[(?:[6-9]|[1-9][0-9]+)\]' -g '*.sh'

expect_empty C5  "无不可信组件引用" \
    'p\.tar\.gz|/p\.php|ocp\.php|SourceGuardian|XCache|eAccelerator' -g '*.sh'

expect_empty C6  "无已删除安装函数引用" \
    'Install_(MySQL_(51|55|56|57)|MariaDB_(5|103|104|105|106)|PHP_(52|53|54|55|56|7|71|72|73|74))\b' -g '*.sh'

expect_empty C7  "无站长镜像引用" \
    'Download_Mirror|soft\.vpser|soft\.lnmp\.com|Check_Mirror' -g '*.sh'

expect_empty C8  "无地理探测" \
    'Get_Country|ip\.vpszt|ip\.vpser' -g '*.sh'

# C9 仅检查可执行的下载调用，不检查展示文本。
#
# banner 里的 "For more information please visit https://lnmp.org" 属于项目出处
# 署名，不属于下载源。检查范围限于 wget、curl、Download_Files 和
# git clone 的参数。
expect_empty C9  "无禁用域名下载" \
    '(wget|curl|Download_Files|git clone)[^|;]*(lnmp\.com|lnmp\.org|vpser[0-9]*\.net|vpszt\.)'

expect_empty C11 "校验已 fail-closed" \
    'Checksum_File.*\] && return' -g '*.sh'

expect_empty C12 "无 cmake 自主下载 boost" \
    'DOWNLOAD_BOOST' -g '*.sh'

# C13 与 C9 使用相同的检查范围。
# 明文 HTTP 下载可被中间人替换成任意内容；本包所有下载源都支持 HTTPS。
expect_empty C13 "无明文 HTTP 下载" \
    '(wget|curl|Download_Files)([^|;]*[[:space:]])http://'

# C14 防火墙已全面改用 nftables，规则操作收敛在 include/firewall.sh。
# 检查 iptables 命令调用及其持久化包，避免与 nftables 规则并存。
expect_empty C14 "无 iptables 调用与持久化包" \
    '^[^#]*(iptables -[A-Z]|service iptables|iptables-services|iptables-persistent|netfilter-persistent)' -g '*.sh'

[ -z "${only}" ] || [ "${only}" = "C4" ] && {
    out=$(grep -nE 'cdn\.mysql\.com|downloads\.mariadb\.org' \
              include/only.sh include/init.sh 2>/dev/null \
          | grep -v ':[0-9]*:[[:space:]]*#')
    if [ -z "${out}" ]; then
        printf 'ok   %-4s %s\n' C4 "DB 下载未在 only.sh / init.sh 重复"
    else
        printf 'FAIL %-4s %s\n' C4 "DB 下载又出现在 only.sh / init.sh"
        echo "${out}" | sed 's/^/       /'
        fail=1
    fi
}

# C10 校验清单格式
[ -z "${only}" ] || [ "${only}" = "C10" ] && {
    if [ ! -s src/checksums.sha256 ]; then
        printf 'FAIL %-4s %s\n' C10 "src/checksums.sha256 不存在"
        fail=1
    else
        out=$(grep -vnE '^([0-9a-f]{64}  \S+|#.*|)$' src/checksums.sha256)
        if [ -z "${out}" ]; then
            n=$(grep -cE '^[0-9a-f]{64}  ' src/checksums.sha256)
            printf 'ok   %-4s %s (%s 条)\n' C10 "校验清单格式正确" "${n}"
        else
            printf 'FAIL %-4s %s\n' C10 "校验清单有格式错误行"
            echo "${out}" | sed 's/^/       /'
            fail=1
        fi
    fi
}

# C15 端口不得再硬编码
#
# 端口现在由 lnmp.conf 统一给默认值，服务配置与 nftables 规则都跟随同一个变量。
# 一旦有人又在 Firewall_Allow/Block 后面写字面数字，服务端口和防火墙规则就会
# 各说各话：改了服务端口，防火墙还按老端口放行或阻断，且不会有任何报错。
# 80/443 例外 —— 那两个端口散落在 nginx 配置与 SSL 流程里，本包不提供开关。
expect_empty C15 "防火墙端口未硬编码（80/443 除外）" 'Firewall_(Allow|Block|Unblock)[[:space:]]+(tcp|udp)[[:space:]]+(?!(80|443)$)[0-9]'

# C16 并行编译的任务数必须由 Build_Jobs 决定
#
# 只按核数并行、不看内存，小内存机器会被 OOM 杀掉编译进程：Debian 12 / 8 核
# 6GB 上 MySQL 8.4 的 sql_gis 就是这么被杀的，白跑一整轮才退到串行。
# 原先五处各写各的，改一处不改其它等于没改。
expect_empty C16 "并行编译任务数统一由 Build_Jobs 决定" 'make[^|;#]*-j(?!"\$\(Build_Jobs\)")' -g '*.sh'

# C17 随包示例的证书路径必须是项目实际产物
#
# conf/example 会被安装到 /usr/local/nginx/conf/example，用户直接照抄。
# 曾写成扁平的 <域名>.crt/.key，而 lnmp ssl add 生成的是
# <域名>/fullchain.cer（Apache 侧 <域名>/<域名>.cer），照抄必然 nginx -t 失败。
[ -z "${only}" ] || [ "${only}" = "C17" ] && {
    out=$(grep -rnE '(ssl_certificate(_key)?|SSLCertificate(Key)?File)[[:space:]]+\S*/conf/ssl/[^/]+\.(crt|key)' \
          conf/example 2>/dev/null)
    if [ -z "${out}" ]; then
        printf 'ok   %-4s %s\n' C17 "示例证书路径与 lnmp ssl 产物一致"
    else
        printf 'FAIL %-4s %s\n' C17 "示例仍引用不存在的扁平证书路径"
        echo "${out}" | sed 's/^/       /'
        fail=1
    fi
}

# T1 语法检查
[ -z "${only}" ] || [ "${only}" = "T1" ] && {
    syntax_fail=0
    for f in $(find . -name '*.sh' -not -path './t/*' -not -path './src/*') conf/lnmp conf/lnmpa conf/lamp; do
        [ -f "$f" ] || continue
        if ! bash -n "$f" 2>/dev/null; then
            echo "       SYNTAX FAIL: $f"
            bash -n "$f" 2>&1 | sed 's/^/         /'
            syntax_fail=1
        fi
    done
    if [ ${syntax_fail} -eq 0 ]; then
        printf 'ok   %-4s %s\n' T1 "全部脚本语法正确"
    else
        printf 'FAIL %-4s %s\n' T1 "存在语法错误"
        fail=1
    fi
}

# T2 shellcheck
#
# lint.sh 的自定义规则只覆盖本项目的收敛不变式，抓不到引号缺失、word splitting、
# cd 失败后继续执行这类通用 shell 缺陷，交给 shellcheck。规则裁剪与排除原因见
# t/shellcheck.sh。未安装 shellcheck 时该脚本跳过并返回 0。
[ -z "${only}" ] || [ "${only}" = "T2" ] && {
    out=$(bash t/shellcheck.sh 2>&1)
    if [ $? -eq 0 ]; then
        printf 'ok   %-4s %s\n' T2 "shellcheck 通过"
    else
        printf 'FAIL %-4s %s\n' T2 "shellcheck 有告警"
        echo "${out}" | sed 's/^/       /'
        fail=1
    fi
}

echo
if [ ${fail} -eq 0 ]; then
    echo "全部通过"
else
    echo "有检查未通过"
fi
exit ${fail}
