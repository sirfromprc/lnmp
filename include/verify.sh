#!/usr/bin/env bash
#
# verify.sh：下载与完整性校验的统一入口。
# 安装侧固定版本使用静态清单；升级侧动态版本使用上游校验值或签名。
#
# ---------------------------------------------------------------------------
# 上游提供的校验方式（2026-08）
#
#   PHP        releases API                                      SHA256
#   MariaDB    downloads REST API                                SHA256
#   phpMyAdmin <文件URL>.sha256                                  SHA256
#   nginx      <文件URL>.asc                                     PGP
#   MySQL      下载页人工核对，动态升级需预先写入静态清单
#
# MySQL 动态升级必须预先将哈希写入 src/checksums.sha256。
# ---------------------------------------------------------------------------

# 限制重定向次数，并禁止 HTTPS 降级。官方 CDN 主机可能动态变化，
# 因此不维护最终主机白名单，下载内容最终由 SHA256 或 PGP 验证。
DL_MAX_REDIRECT=5

# ---------------------------------------------------------------------------
# Download_Fetch <url> <目标文件>
#
# 统一下载入口具有两项约束：
#   1. 仅允许 HTTPS，重定向不得降级；
#   2. 重定向次数有上限。
#
# curl 可同时约束初始协议和重定向协议；wget 仅作为兼容回退。
# ---------------------------------------------------------------------------
Download_Fetch()
{
    local url="$1" out="$2"

    case "${url}" in
    https://*) : ;;
    *)
        Echo_Red "拒绝非 HTTPS 下载：${url}"
        return 1
        ;;
    esac

    if command -v curl >/dev/null 2>&1; then
        curl -fSL --proto '=https' --proto-redir '=https' \
             --max-redirs ${DL_MAX_REDIRECT} \
             -o "${out}" "${url}"
        return $?
    fi

    Echo_Yellow "未找到 curl，退回 wget —— wget 无法强制「重定向必须保持 HTTPS」，"
    Echo_Yellow "本次下载的降级防护弱于预期，最终仍以校验值/签名为准。"
    wget -c --progress=dot -e dotbytes=20M --prefer-family=IPv4 \
         --max-redirect=${DL_MAX_REDIRECT} -O "${out}" "${url}"
}

# ---------------------------------------------------------------------------
# Download_Head_OK <url> — 只发 HEAD 请求探测 URL 是否可达（2xx 才算可达）
#
# 在修改本地配置前检查上游资源是否存在，例如 OpenResty 发行版仓库。
# 仅允许 HTTPS。
# ---------------------------------------------------------------------------
Download_Head_OK()
{
    local url="$1" code

    case "${url}" in
    https://*) : ;;
    *) Echo_Red "拒绝非 HTTPS 探测：${url}"; return 1 ;;
    esac

    if command -v curl >/dev/null 2>&1; then
        code=$(curl -sS -o /dev/null -w '%{http_code}' -I \
               --proto '=https' --proto-redir '=https' \
               --max-redirs ${DL_MAX_REDIRECT} --max-time 30 "${url}" 2>/dev/null)
        case "${code}" in
        2*) return 0 ;;
        *)  return 1 ;;
        esac
    fi

    # 没有 curl 时退回 wget 的 --spider
    wget -q --spider --max-redirect=${DL_MAX_REDIRECT} --timeout=30 "${url}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Verify_SHA256_Value <文件> <期望值>
# ---------------------------------------------------------------------------
Verify_SHA256_Value()
{
    local file="$1" expected="$2" actual

    if ! echo "${expected}" | grep -Eq '^[0-9a-f]{64}$'; then
        Echo_Red "期望的 SHA256 不是合法的 64 位十六进制：'${expected}'"
        return 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "${file}" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "${file}" | awk '{print $1}')
    else
        Echo_Red "系统缺少 sha256sum / shasum，无法校验。"
        return 1
    fi
    if [ "${actual}" != "${expected}" ]; then
        Echo_Red "SHA256 不匹配：${file}"
        Echo_Red "  expected: ${expected}"
        Echo_Red "  actual:   ${actual}"
        return 1
    fi
    Echo_Green "${file} SHA256 与上游公布值一致。"
    return 0
}

# ---------------------------------------------------------------------------
# Upstream_SHA256 <project> <version> <落地文件名>
#
# 返回上游公布的 SHA256；获取失败时返回空串。
# 校验值与软件包同源，可检测传输或镜像差异，不覆盖上游自身失陷风险。
# ---------------------------------------------------------------------------
#
# _Json_Sha256_After <json文件> <锚点键> <锚点值> <目标键>
#
# 极小的 JSON 取值：把内容按逗号拆行，找到 "<锚点键>":"<锚点值>" 那一行，
# 然后向后找第一个 "<目标键>":"<64位十六进制>"。
#
# 使用 Shell 解析固定字段，避免引入 python 或 jq 依赖。
# 获取失败时返回空串，由调用方拒绝继续。
_Json_Sha256_After()
{
    # 去除 JSON 结构字符，使记录首个键可以正常匹配。
    tr ',' '\n' < "$1" | tr -d ' "[]{}' | awk -F: -v k="$2" -v v="$3" -v t="$4" '
        $1 == k && $2 == v { found = 1; next }
        found && $1 == t && $2 ~ /^[0-9a-f]{64}$/ { print $2; exit }
    '
}

Upstream_SHA256()
{
    local project="$1" ver="$2" fname="$3" tmp out=''

    tmp=$(mktemp) || return 1
    case "${project}" in
    php)
        # {"source":[{"filename":"php-8.3.33.tar.bz2", ..., "sha256":"xxx"}, ...]}
        if Download_Fetch "https://www.php.net/releases/?json&version=${ver}" "${tmp}" >/dev/null 2>&1; then
            out=$(_Json_Sha256_After "${tmp}" filename "${fname}" sha256)
        fi
        ;;
    mariadb)
        # {"release_data":{"<ver>":{"files":[{"file_name":"x", ...,
        #   "checksum":{"md5sum":..,"sha1sum":..,"sha256sum":"xxx", ...}}, ...]}}}
        if Download_Fetch "https://downloads.mariadb.org/rest-api/mariadb/${ver}/" "${tmp}" >/dev/null 2>&1; then
            out=$(_Json_Sha256_After "${tmp}" file_name "${fname}" sha256sum)
        fi
        ;;
    phpmyadmin)
        # 官方在每个包旁边放 <file>.sha256
        if Download_Fetch "https://files.phpmyadmin.net/phpMyAdmin/${ver}/${fname}.sha256" "${tmp}" >/dev/null 2>&1; then
            out=$(grep -oE '^[0-9a-f]{64}' "${tmp}" | head -n1)
        fi
        ;;
    boost)
        # archives.boost.io 在每个包旁边放 <file>.json，里面有 sha256。
        #
        # Boost 版本由 MySQL 源码中的 cmake/boost.cmake 决定，
        # 因此通过上游 JSON 动态获取对应版本的 SHA256。
        if Download_Fetch "https://archives.boost.io/release/${ver}/source/${fname}.json" "${tmp}" >/dev/null 2>&1; then
            out=$(grep -oE '"sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' "${tmp}" \
                  | head -n1 | grep -oE '[0-9a-f]{64}')
        fi
        ;;
    esac
    rm -f "${tmp}"
    printf '%s' "${out}"
}

# ---------------------------------------------------------------------------
# Verify_Nginx_Signature <文件> <文件URL>
#
# nginx.org 不公布 sha256，只公布 PGP 签名（<file>.asc）。
# 公钥随包分发，避免签名与验证密钥来自同一下载路径。
#
# gpg 用于生成钥匙串，gpgv 使用指定钥匙串验签，不修改 ~/.gnupg。
# 钥匙串中的主密钥和实际签名者均须匹配固定指纹白名单。
#
# 指纹取自 nginx.org 公布的签名密钥（2026-08）。
# 更新随包公钥时必须同步更新指纹清单。
# ---------------------------------------------------------------------------
Nginx_Key_Fingerprints='
8540A6F18833A80E9C1653A42FD21310B49F6B46
573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62
9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3
7338973069ED3F443F4D37DFA64FD5B17ADB39A8
41DB92713D3BF4BFF3EE91069C5E7FA2F54977D4
13C82A63B603576156E30A4EA0EA981B66B0D967
D6786CE303D9A9022998DC6CC8464D549AF75C0A
43387825DDB1BB97EC36BA5D007C8D7C15D87369
'

# Nginx_Key_Allowed <指纹>：检查指纹是否在随包白名单内。
Nginx_Key_Allowed()
{
    case "$(echo "${Nginx_Key_Fingerprints}" | tr -d ' \t')" in
    *"$1"*) return 0 ;;
    *)      return 1 ;;
    esac
}

Verify_Nginx_Signature()
{
    local file="$1" url="$2" tmpdir keyring sig out fpr sigfpr bad=0 good=0

    # gpg 与 gpgv 都要有：gpg 负责 --dearmor，gpgv 负责验签。
    if ! command -v gpg >/dev/null 2>&1; then
        Echo_Red "系统缺少 gpg（--dearmor 需要它），无法验证 nginx 的 PGP 签名。"
        Echo_Red "请安装后重试（Debian/Ubuntu: apt install gnupg；RHEL 系: yum install gnupg2）。"
        return 1
    fi
    if ! command -v gpgv >/dev/null 2>&1; then
        Echo_Red "系统缺少 gpgv，无法验证 nginx 的 PGP 签名。"
        Echo_Red "请安装后重试（Debian/Ubuntu: apt install gpgv；RHEL 系: yum install gnupg2）。"
        return 1
    fi
    if [ ! -s "${cur_dir}/conf/nginx-signing-keys.asc" ]; then
        Echo_Red "缺少 conf/nginx-signing-keys.asc，无法验证 nginx 签名。"
        return 1
    fi

    # gpgv 将相对钥匙串路径解释为相对 ~/.gnupg，因此必须使用绝对路径。
    tmpdir=$(mktemp -d) || return 1
    keyring="${tmpdir}/nginx.gpg"
    sig="${tmpdir}/$(basename "${file}").asc"

    if ! gpg --dearmor < "${cur_dir}/conf/nginx-signing-keys.asc" > "${keyring}" 2>/dev/null; then
        Echo_Red "无法解析 conf/nginx-signing-keys.asc（文件损坏或不是 PGP 公钥）。"
        rm -rf "${tmpdir}"
        return 1
    fi

    # 逐个核对钥匙串中的主密钥指纹，拒绝白名单外的密钥。
    for fpr in $(gpg --show-keys --with-colons "${keyring}" 2>/dev/null |
                 awk -F: '/^pub:/{p=1} /^fpr:/{if(p){print $10; p=0}}'); do
        if Nginx_Key_Allowed "${fpr}"; then
            good=$((good+1))
        else
            Echo_Red "conf/nginx-signing-keys.asc 含有白名单之外的公钥：${fpr}"
            bad=$((bad+1))
        fi
    done
    if [ ${bad} -gt 0 ] || [ ${good} -eq 0 ]; then
        Echo_Red "随包 nginx 公钥文件与预期不符（白名单内 ${good} 个、之外 ${bad} 个），拒绝验签。"
        Echo_Red "若确为上游轮换了签名密钥，请同步更新 include/verify.sh 的 Nginx_Key_Fingerprints。"
        rm -rf "${tmpdir}"
        return 1
    fi

    if ! Download_Fetch "${url}.asc" "${sig}"; then
        Echo_Red "下载 nginx 签名文件失败：${url}.asc"
        rm -rf "${tmpdir}"
        return 1
    fi

    # 实际验签：不只看退出码，还要在输出里确认 "Good signature"，
    # 并把签名者的主密钥指纹再对一次白名单。
    out=$(gpgv --status-fd 1 --keyring "${keyring}" "${sig}" "${file}" 2>/dev/null)
    if ! echo "${out}" | grep -q '^\[GNUPG:\] GOODSIG'; then
        Echo_Red "nginx 源码包 PGP 签名验证失败，拒绝使用该文件。"
        gpgv --keyring "${keyring}" "${sig}" "${file}" 2>&1 | head -5
        rm -rf "${tmpdir}"
        return 1
    fi

    # VALIDSIG 同时包含签名子密钥和主密钥指纹，任一匹配白名单即可。
    fpr=$(echo "${out}" | awk '/^\[GNUPG:\] VALIDSIG/{print $NF; exit}')
    sigfpr=$(echo "${out}" | awk '/^\[GNUPG:\] VALIDSIG/{print $3; exit}')
    if ! Nginx_Key_Allowed "${fpr}" && ! Nginx_Key_Allowed "${sigfpr}"; then
        Echo_Red "签名本身有效，但签名者密钥不在随包白名单内。"
        Echo_Red "  主密钥指纹：${fpr:-未知}"
        Echo_Red "  签名密钥指纹：${sigfpr:-未知}"
        Echo_Red "拒绝使用该文件。若确为上游轮换了签名密钥，"
        Echo_Red "请同步更新 conf/nginx-signing-keys.asc 与 verify.sh 的 Nginx_Key_Fingerprints。"
        rm -rf "${tmpdir}"
        return 1
    fi

    Echo_Green "nginx 源码包 PGP 签名验证通过（签名者主密钥 ${fpr}）。"
    rm -rf "${tmpdir}"
    return 0
}

# ---------------------------------------------------------------------------
# OpenResty 源码包的 PGP 验签
#
# 指纹取自 openresty.org/en/download.html 的公布："All the releases are signed
# by the public PGP key A0E98066 of Yichun Zhang."
# 固定完整指纹以验证从 keyserver 获取的公钥实体。
#
# 源码包与 apt/yum 仓库使用不同密钥：
#   仓库包  E52218E7087897DC6DEA6D6D97DB7443D5EDEB74  OpenResty Admin
#   源码包  25451EB088460026195BD62CB550E09EA0E98066  Yichun Zhang (agentzh)
# 仓库包由 apt/yum 的 GPG 校验处理。
#
# OpenResty 与 nginx 使用独立密钥和验证流程，保持函数边界独立。
# ---------------------------------------------------------------------------
OpenResty_Key_Fingerprints='
25451EB088460026195BD62CB550E09EA0E98066
'

OpenResty_Key_Allowed()
{
    case "$(echo "${OpenResty_Key_Fingerprints}" | tr -d ' \t')" in
    *"$1"*) return 0 ;;
    *)      return 1 ;;
    esac
}

Verify_OpenResty_Signature()
{
    local file="$1" url="$2" tmpdir keyring sig out fpr sigfpr bad=0 good=0

    if ! command -v gpg >/dev/null 2>&1; then
        Echo_Red "系统缺少 gpg（--dearmor 需要它），无法验证 OpenResty 的 PGP 签名。"
        Echo_Red "请安装后重试（Debian/Ubuntu: apt install gnupg；RHEL 系: yum install gnupg2）。"
        return 1
    fi
    if ! command -v gpgv >/dev/null 2>&1; then
        Echo_Red "系统缺少 gpgv，无法验证 OpenResty 的 PGP 签名。"
        Echo_Red "请安装后重试（Debian/Ubuntu: apt install gpgv；RHEL 系: yum install gnupg2）。"
        return 1
    fi
    if [ ! -s "${cur_dir}/conf/openresty-signing-key.asc" ]; then
        Echo_Red "缺少 conf/openresty-signing-key.asc，无法验证 OpenResty 签名。"
        return 1
    fi

    tmpdir=$(mktemp -d) || return 1
    keyring="${tmpdir}/openresty.gpg"
    sig="${tmpdir}/$(basename "${file}").asc"

    if ! gpg --dearmor < "${cur_dir}/conf/openresty-signing-key.asc" > "${keyring}" 2>/dev/null; then
        Echo_Red "无法解析 conf/openresty-signing-key.asc（文件损坏或不是 PGP 公钥）。"
        rm -rf "${tmpdir}"
        return 1
    fi

    for fpr in $(gpg --show-keys --with-colons "${keyring}" 2>/dev/null |
                 awk -F: '/^pub:/{p=1} /^fpr:/{if(p){print $10; p=0}}'); do
        if OpenResty_Key_Allowed "${fpr}"; then
            good=$((good+1))
        else
            Echo_Red "conf/openresty-signing-key.asc 含有白名单之外的公钥：${fpr}"
            bad=$((bad+1))
        fi
    done
    if [ ${bad} -gt 0 ] || [ ${good} -eq 0 ]; then
        Echo_Red "随包 OpenResty 公钥与预期不符（白名单内 ${good} 个、之外 ${bad} 个），拒绝验签。"
        Echo_Red "若确为上游轮换了签名密钥，请同步更新 OpenResty_Key_Fingerprints。"
        rm -rf "${tmpdir}"
        return 1
    fi

    if ! Download_Fetch "${url}.asc" "${sig}"; then
        Echo_Red "下载 OpenResty 签名文件失败：${url}.asc"
        rm -rf "${tmpdir}"
        return 1
    fi

    out=$(gpgv --status-fd 1 --keyring "${keyring}" "${sig}" "${file}" 2>/dev/null)
    if ! echo "${out}" | grep -q '^\[GNUPG:\] GOODSIG'; then
        Echo_Red "OpenResty 源码包 PGP 签名验证失败，拒绝使用该文件。"
        gpgv --keyring "${keyring}" "${sig}" "${file}" 2>&1 | head -5
        rm -rf "${tmpdir}"
        return 1
    fi

    fpr=$(echo "${out}" | awk '/^\[GNUPG:\] VALIDSIG/{print $NF; exit}')
    sigfpr=$(echo "${out}" | awk '/^\[GNUPG:\] VALIDSIG/{print $3; exit}')
    if ! OpenResty_Key_Allowed "${fpr}" && ! OpenResty_Key_Allowed "${sigfpr}"; then
        Echo_Red "签名本身有效，但签名者密钥不在随包白名单内。"
        Echo_Red "  主密钥指纹：${fpr:-未知}"
        Echo_Red "  签名密钥指纹：${sigfpr:-未知}"
        rm -rf "${tmpdir}"
        return 1
    fi

    Echo_Green "OpenResty 源码包 PGP 签名验证通过（签名者主密钥 ${fpr}）。"
    rm -rf "${tmpdir}"
    return 0
}

# ---------------------------------------------------------------------------
# Download_Verified <project> <version> <url> <落地文件名>
#
# 升级侧统一入口，按以下顺序选择验证方式：
#
#   1) src/checksums.sha256 中的静态值；
#   2) 上游发布的 SHA256；
#   3) 上游发布的 PGP 签名；
#   4) 无机器可读校验依据时终止。
# ---------------------------------------------------------------------------
Download_Verified()
{
    local project="$1" ver="$2" url="$3" fname="$4"
    local manifest="${cur_dir}/src/checksums.sha256" expected=''

    if [ "${Enable_Download_Checksum}" != "y" ]; then
        Echo_Red "警告：Enable_Download_Checksum='n'，本次下载不做完整性校验。"
        Echo_Red "这只应用于排查问题，不可用于上线。"
        [ -s "${fname}" ] && return 0
        Download_Fetch "${url}" "${fname}"
        return $?
    fi

    # 1) 静态清单优先
    if [ -s "${manifest}" ]; then
        expected=$(awk -v f="${fname}" '$1 !~ /^#/ && $2 == f {print $1; exit}' "${manifest}")
    fi

    if [ ! -s "${fname}" ]; then
        echo "Notice: ${fname} not found!!!download now..."
        if ! Download_Fetch "${url}" "${fname}"; then
            Echo_Red "下载失败：${url}"
            rm -f "${fname}"
            return 1
        fi
    else
        echo "${fname} [found]"
    fi

    if [ -n "${expected}" ]; then
        Verify_SHA256_Value "${fname}" "${expected}" || { rm -f "${fname}"; return 1; }
        return 0
    fi

    # 2) 上游官方 sha256
    case "${project}" in
    php|mariadb|phpmyadmin|boost)
        echo "向上游获取 ${fname} 的官方 SHA256..."
        expected=$(Upstream_SHA256 "${project}" "${ver}" "${fname}")
        if [ -z "${expected}" ]; then
            Echo_Red "无法从上游取得 ${fname} 的官方 SHA256，拒绝使用该文件。"
            Echo_Red "（可能是版本号写错，或上游接口有变动。）"
            rm -f "${fname}"
            return 1
        fi
        Verify_SHA256_Value "${fname}" "${expected}" || { rm -f "${fname}"; return 1; }
        return 0
        ;;
    # 3) 只有 PGP 签名
    nginx)
        Verify_Nginx_Signature "${fname}" "${url}" || { rm -f "${fname}"; return 1; }
        return 0
        ;;
    esac

    # 4) 上游没有任何机器可读的校验依据
    Echo_Red "FATAL: ${fname} 既不在 src/checksums.sha256 里，${project} 上游也不提供"
    Echo_Red "可自动核对的校验文件（MySQL 只把校验值印在 dev.mysql.com 的下载页上）。"
    Echo_Red ""
    Echo_Red "请到官方下载页核对该版本的校验值，确认无误后写入清单再重试："
    Echo_Red "  echo '<sha256>  ${fname}' >> src/checksums.sha256"
    Echo_Red ""
    Echo_Red "本脚本不会在无法校验的情况下继续 —— 那正是供应链投毒的入口。"
    rm -f "${fname}"
    return 1
}
