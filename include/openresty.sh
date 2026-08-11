#!/usr/bin/env bash
#
# openresty.sh — OpenResty 安装 / 卸载 / 升级
#
# 与 nginx 官方版互斥：两者都提供 nginx 二进制、都要占 80/443，
# 装在一起只会互相覆盖配置、抢端口。选择在菜单阶段做（Web_Selection），
# 这里再做一次落地前的实际检查（Check_WebServer_Conflict）。
#
# 两条安装路径，由 OpenResty_Install_Mode 决定：
#
#   pkg     官方 apt/yum 仓库装预编译包。不编译，快。
#           完整性由包管理器的 GPG 签名保证（apt/dnf 自己校验），
#           不写入 src/checksums.sha256；该清单仅用于下载的 tarball。
#           限制：仓库必须有当前发行版代号对应的目录。
#           2026-08 实测 Debian 侧只有 jessie/stretch/buster/bullseye/bookworm，
#           没有 trixie(13)（官网博客把 13 列进了支持列表，但包尚未发布）。
#
#   source  下载官方源码 tarball 自行编译。慢，但不挑发行版。
#           用 Yichun Zhang 的 PGP 公钥验签（见 Verify_OpenResty_Signature）。
#
# 目录约定：OpenResty 官方包/源码默认前缀都是 /usr/local/openresty，
# 其中 nginx 部分在 /usr/local/openresty/nginx。安装完成后建一个软链
#   /usr/local/nginx -> /usr/local/openresty/nginx
# 于是 conf/lnmp 的 vhost 管理、init.d/nginx、rewrite 目录等现有逻辑
# 可直接复用，因为这些脚本均引用 /usr/local/nginx/ 路径。


# ---------------------------------------------------------------------------
# Check_WebServer_Conflict — 落地前的互斥检查
#
# $1 = 即将安装的一方：nginx | openresty
# ---------------------------------------------------------------------------
Check_WebServer_Conflict()
{
    local want="$1"

    if [ "${want}" = "openresty" ]; then
        # /usr/local/nginx 若是真实目录（不是指向 openresty 的软链），
        # 说明已经装过源码编译的 nginx
        if [ -d /usr/local/nginx ] && [ ! -L /usr/local/nginx ]; then
            Echo_Red "检测到已安装 nginx（/usr/local/nginx 是真实目录）。"
            Echo_Red "OpenResty 与 nginx 官方版互斥，不能同时安装 ——"
            Echo_Red "两者都提供 nginx 二进制、都要监听 80/443。"
            Echo_Red "如需改用 OpenResty，请先卸载现有环境：./uninstall.sh lnmp"
            return 1
        fi
    else
        if [ -d /usr/local/openresty ]; then
            Echo_Red "检测到已安装 OpenResty（/usr/local/openresty 存在）。"
            Echo_Red "nginx 官方版与 OpenResty 互斥，不能同时安装。"
            Echo_Red "如需改用 nginx，请先卸载现有环境：./uninstall.sh lnmp"
            return 1
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# OpenResty_Repo_Codename — 取当前发行版在 OpenResty 仓库里的代号
# 取不到返回非零
# ---------------------------------------------------------------------------
OpenResty_Repo_Codename()
{
    local cn=''
    if command -v lsb_release >/dev/null 2>&1; then
        cn=$(lsb_release -sc 2>/dev/null)
    fi
    if [ -z "${cn}" ] && [ -s /etc/os-release ]; then
        cn=$(awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
    fi
    [ -z "${cn}" ] && return 1
    printf '%s' "${cn}"
    return 0
}

# ---------------------------------------------------------------------------
# Install_OpenResty_Pkg — 走官方仓库装预编译包（不编译）
# ---------------------------------------------------------------------------
Install_OpenResty_Pkg()
{
    local codename repo_url

    if [ "${PM}" = "apt" ]; then
        codename=$(OpenResty_Repo_Codename)
        if [ -z "${codename}" ]; then
            Echo_Red "无法确定当前发行版代号（lsb_release 与 /etc/os-release 都没给出）。"
            Echo_Red "请改用源码编译方式安装 OpenResty。"
            return 1
        fi

        # 先探仓库里有没有这个代号，再动 apt 源。
        # 不探的话，等到 apt-get update 才报 404，那时源文件已经写进
        # /etc/apt/sources.list.d/，会连累后续所有 apt 操作报错。
        repo_url="https://openresty.org/package/debian/dists/${codename}/Release"
        case "${DISTRO}" in
            Ubuntu) repo_url="https://openresty.org/package/ubuntu/dists/${codename}/Release" ;;
        esac

        echo "检查 OpenResty 官方仓库是否提供 ${DISTRO} ${codename} 的包..."
        if ! Download_Head_OK "${repo_url}"; then
            Echo_Red "OpenResty 官方仓库没有 ${codename} 的软件包。"
            Echo_Red "已探测：${repo_url} 不可用。"
            echo
            Echo_Yellow "这不是本包的限制，是上游尚未发布该发行版的包。"
            Echo_Yellow "两个可行的做法："
            Echo_Yellow "  1) 改用**源码编译**方式安装 OpenResty（不挑发行版）"
            Echo_Yellow "  2) 改用 nginx 官方版"
            echo
            Echo_Yellow "参考：2026-08 时 Debian 侧仓库只有 bookworm(12) 及更早，"
            Echo_Yellow "尚无 trixie(13) 的包。"
            return 1
        fi
        Echo_Green "仓库中存在 ${codename} 的包，继续。"

        apt-get -y install --no-install-recommends wget gnupg ca-certificates lsb-release >/dev/null 2>&1

        # 公钥装进 keyring 目录并用 signed-by 绑定到这一个源上，
        # 不用早已废弃的 apt-key（它把密钥加进全局信任集，
        # 等于让 openresty 的密钥能给任何仓库的包背书）。
        #
        # 注意：临时文件必须放在 mktemp -d 建的私有目录里，不能用
        # /tmp 下的固定名字。root 执行时，本机任何低权限用户都可以预先创建
        #     /tmp/openresty-pubkey.gpg -> /etc/shadow
        # 这样的符号链接，curl -o / wget -O 会跟随链接去写目标文件，
        # 造成任意文件截断/覆盖。mktemp -d 产生不可预测的目录名且是 0700，
        # 其他用户无法预测或访问。
        mkdir -p /usr/share/keyrings

        local or_tmp or_key
        or_tmp=$(umask 077; mktemp -d) || {
            Echo_Red "无法创建临时目录。"; return 1; }
        # trap 覆盖正常返回与被信号打断两种情况，避免留下残留
        trap 'rm -rf "${or_tmp}"' RETURN INT TERM
        or_key="${or_tmp}/pubkey.gpg"

        if ! Download_Fetch "https://openresty.org/package/pubkey.gpg" "${or_key}"; then
            Echo_Red "下载 OpenResty 仓库公钥失败。"
            return 1
        fi
        if ! gpg --dearmor < "${or_key}" > /usr/share/keyrings/openresty.gpg 2>/dev/null; then
            # 已经是二进制格式时 --dearmor 会失败，直接用
            cp -f "${or_key}" /usr/share/keyrings/openresty.gpg
        fi
        chmod 644 /usr/share/keyrings/openresty.gpg

        case "${DISTRO}" in
            Ubuntu)
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openresty.gpg] https://openresty.org/package/ubuntu ${codename} main" \
                    > /etc/apt/sources.list.d/openresty.list
                ;;
            *)
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openresty.gpg] https://openresty.org/package/debian ${codename} openresty" \
                    > /etc/apt/sources.list.d/openresty.list
                ;;
        esac

        apt-get update -y
        if ! apt-get -y install --no-install-recommends openresty; then
            Echo_Red "安装 openresty 包失败。"
            Echo_Red "排查：apt-get install openresty 看具体报错；"
            Echo_Red "或改用源码编译方式。"
            return 1
        fi

    elif [ "${PM}" = "yum" ]; then
        # EL9+ 用 openresty2.repo，EL8 及更早用 openresty.repo
        local rf='openresty.repo'
        case "${DISTRO_Version}" in
            9*|10*) rf='openresty2.repo' ;;
        esac
        echo "使用 https://openresty.org/package/centos/${rf}"
        if ! Download_Fetch "https://openresty.org/package/centos/${rf}" /etc/yum.repos.d/openresty.repo; then
            Echo_Red "下载 OpenResty 仓库定义失败。"
            Echo_Red "若当前发行版不受支持，请改用源码编译方式。"
            return 1
        fi
        if ! ${PM} install -y openresty; then
            Echo_Red "安装 openresty 包失败。请改用源码编译方式，或检查 ${rf} 是否适配本系统。"
            return 1
        fi
    else
        Echo_Red "未知的包管理器（PM=${PM}），无法用仓库方式安装 OpenResty。"
        Echo_Red "请改用源码编译方式。"
        return 1
    fi

    if [ ! -s /usr/local/openresty/nginx/sbin/nginx ]; then
        Echo_Red "包装好了，但没找到 /usr/local/openresty/nginx/sbin/nginx。"
        Echo_Red "上游可能改了安装前缀，请检查后反馈。"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Install_OpenResty_Source — 下载官方源码自行编译
# ---------------------------------------------------------------------------
Install_OpenResty_Source()
{
    local tarball="${OpenResty_Ver}.tar.gz"
    local url="https://openresty.org/download/${tarball}"

    cd ${cur_dir}/src || return 1

    if [ ! -s "${tarball}" ]; then
        echo "下载 ${tarball} ..."
        if ! Download_Fetch "${url}" "${cur_dir}/src/${tarball}"; then
            Echo_Red "下载 OpenResty 源码失败：${url}"
            return 1
        fi
    else
        echo "${tarball} [found]"
    fi

    # OpenResty 不提供 sha256 校验文件，只提供 PGP 签名，
    # 所以这里走验签而不是 src/checksums.sha256。
    if ! Verify_OpenResty_Signature "${cur_dir}/src/${tarball}" "${url}"; then
        Echo_Red "OpenResty 源码包验签未通过，中止安装。"
        rm -f "${cur_dir}/src/${tarball}"
        return 1
    fi

    # 自定义模块的下载、校验、解压要在 configure 之前完成
    if ! OR_Modules_Prepare; then
        Echo_Red "自定义模块准备失败，中止安装。"
        return 1
    fi

    Tar_Cd "${tarball}" "${OpenResty_Ver}"

    # 编译参数与本包 nginx 的口径保持一致：PCRE JIT、IPv6、SSL。
    # OpenResty 自带 LuaJIT 与全套 lua-resty-*，不需要本包再单独装那些 ：
    # 这正是选它的意义。
    ./configure -j"$(nproc 2>/dev/null || echo 2)" \
        --prefix=/usr/local/openresty \
        --with-pcre-jit \
        --with-ipv6 \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_realip_module \
        --with-http_stub_status_module \
        --with-http_gzip_static_module \
        ${OpenResty_Modules_Options} \
        ${OR_Modules_Add_Options}
    if ! Check_Makefile_Ready; then
        Echo_Red "OpenResty configure 失败。常见原因是缺少 libpcre2-dev / libssl-dev。"
        return 1
    fi
    make -j"$(Build_Jobs)" || { Echo_Red "OpenResty 编译失败。"; return 1; }
    OR_Modules_Capture_Built || { Echo_Red "无法记录本次动态模块产物。"; return 1; }
    make install || { Echo_Red "OpenResty 安装失败。"; return 1; }

    cd ${cur_dir}/src/
    rm -rf "${cur_dir}/src/${OpenResty_Ver}"

    if [ ! -s /usr/local/openresty/nginx/sbin/nginx ]; then
        Echo_Red "编译完成但未生成 /usr/local/openresty/nginx/sbin/nginx。"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Install_OpenResty — 对外入口
# ---------------------------------------------------------------------------
Install_OpenResty()
{
    Echo_Blue "[+] Installing OpenResty (${OpenResty_Install_Mode}) ..."

    Check_WebServer_Conflict openresty || exit 1

    # 包安装方式加不了编译期模块，配了就直接停下来说清楚
    if [ "${OpenResty_Install_Mode}" = "pkg" ]; then
        OR_Check_Pkg_Mode_Conflict || exit 1
    fi

    case "${OpenResty_Install_Mode}" in
        pkg)    Install_OpenResty_Pkg    || exit 1 ;;
        source) Install_OpenResty_Source || exit 1 ;;
        *)      Echo_Red "未知的 OpenResty 安装方式：'${OpenResty_Install_Mode}'（应为 pkg 或 source）"
                exit 1 ;;
    esac

    OpenResty_Post_Install
}

# ---------------------------------------------------------------------------
# OpenResty_Post_Install — 铺配置、建软链、接管服务
#
# 这里是"让 OpenResty 长得跟本包的 nginx 一样"的关键：
# 建立 /usr/local/nginx -> /usr/local/openresty/nginx 软链之后，
# conf/lnmp 的全部 vhost 逻辑、init.d/nginx、tools/ 下的脚本都无需改动。
# ---------------------------------------------------------------------------
OpenResty_Post_Install()
{
    local ordir=/usr/local/openresty/nginx

    echo "配置 OpenResty ..."

    # www 用户：本包的 nginx.conf 里写死了 user www www
    id -u www >/dev/null 2>&1 || useradd -M -U -s /sbin/nologin www 2>/dev/null

    mkdir -p "${ordir}/conf/vhost" /home/wwwlogs "${Default_Website_Dir}"

    # 备份 OpenResty 自带的默认配置，再铺本包的模板
    [ -s "${ordir}/conf/nginx.conf" ] && [ ! -s "${ordir}/conf/nginx.conf.orig" ] && \
        cp -a "${ordir}/conf/nginx.conf" "${ordir}/conf/nginx.conf.orig"

    # OpenResty 使用独立模板 conf/openresty.conf，不与源码版 nginx 共用 conf/nginx.conf。
    # 两者的 Lua 搜索路径不同：OpenResty 指向自带的 /usr/local/openresty/lualib，
    # 源码版 nginx 指向 /usr/local/nginx/lib/lua，混用会导致 require 失败。
    \cp "${cur_dir}/conf/openresty.conf" "${ordir}/conf/nginx.conf"
    \cp -ra "${cur_dir}/conf/rewrite" "${ordir}/conf/"
    \cp "${cur_dir}/conf/pathinfo.conf" "${ordir}/conf/pathinfo.conf"
    \cp "${cur_dir}/conf/enable-php.conf" "${ordir}/conf/enable-php.conf"
    \cp "${cur_dir}/conf/enable-php-pathinfo.conf" "${ordir}/conf/enable-php-pathinfo.conf"
    \cp -ra "${cur_dir}/conf/example" "${ordir}/conf/example" 2>/dev/null

    # 关键软链：让所有引用 /usr/local/nginx 的既有代码继续工作
    if [ -e /usr/local/nginx ] && [ ! -L /usr/local/nginx ]; then
        Echo_Red "/usr/local/nginx 已存在且不是软链，无法建立到 OpenResty 的链接。"
        exit 1
    fi
    ln -sfn /usr/local/openresty/nginx /usr/local/nginx
    echo "已建立软链 /usr/local/nginx -> /usr/local/openresty/nginx"

    # 复用本包的 init 脚本（它调用 /usr/local/nginx/sbin/nginx，经软链落到 OpenResty）
    \cp "${cur_dir}/init.d/init.d.nginx" /etc/init.d/nginx
    chmod +x /etc/init.d/nginx

    # 包安装方式会带一个自己的 openresty.service，与本包的 init 脚本抢同一个
    # 二进制和 pid 文件。禁用它，统一由 lnmp 管理，避免"两个管理者"的混乱。
    if systemctl list-unit-files 2>/dev/null | grep -q '^openresty\.service'; then
        systemctl stop openresty >/dev/null 2>&1
        systemctl disable openresty >/dev/null 2>&1
        echo "已停用随包的 openresty.service，服务改由 lnmp / /etc/init.d/nginx 管理。"
    fi

    chown -R www:www "${Default_Website_Dir}" 2>/dev/null
    chmod 755 /home/wwwlogs

    # 动态模块的 load_module 与 Lua 搜索路径由 lnmp 生成，nginx.conf 会 include 它们。
    # 必须在 nginx -t 之前完成，否则 include 的文件不存在会直接检查失败。
    if ! OR_Modules_Post_Build; then
        Echo_Red "生成模块与 Lua 路径配置失败。"
        exit 1
    fi

    if ! /usr/local/nginx/sbin/nginx -t; then
        Echo_Red "OpenResty 配置检查未通过，请查看上面的报错。"
        exit 1
    fi

    StartUp nginx
    # 记录本次的编译期配置，升级时沿用
    if ! OR_Modules_Persist; then
        Echo_Red "OpenResty 已安装，但编译期配置持久化失败，不能报告安装完成。"
        exit 1
    fi
    Echo_Green "OpenResty 安装完成：$(/usr/local/openresty/nginx/sbin/nginx -v 2>&1)"
}

# ---------------------------------------------------------------------------
# Uninstall_OpenResty — 由 uninstall.sh 调用
# ---------------------------------------------------------------------------
Uninstall_OpenResty()
{
    echo "移除 OpenResty ..."
    [ -x /etc/init.d/nginx ] && /etc/init.d/nginx stop 2>/dev/null
    systemctl stop openresty 2>/dev/null
    systemctl disable openresty 2>/dev/null

    if [ "${PM}" = "apt" ] && dpkg -l openresty 2>/dev/null | grep -q '^ii'; then
        apt-get -y remove --purge openresty 2>/dev/null
        rm -f /etc/apt/sources.list.d/openresty.list /usr/share/keyrings/openresty.gpg
    elif [ "${PM}" = "yum" ] && rpm -q openresty >/dev/null 2>&1; then
        ${PM} remove -y openresty 2>/dev/null
        rm -f /etc/yum.repos.d/openresty.repo
    fi

    # 软链先删，避免后面的 rm -rf /usr/local/nginx 顺着它删到真实目录
    [ -L /usr/local/nginx ] && rm -f /usr/local/nginx
    rm -rf /usr/local/openresty
    Echo_Green "OpenResty 已移除。"
}
