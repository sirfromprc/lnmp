#!/usr/bin/env bash
# OpenResty 安装、卸载与升级。
# 与 nginx 官方版互斥：两者都提供 nginx 二进制、都要占 80/443，
# 同时安装会覆盖配置并产生端口冲突，因此在选择和安装阶段均执行检查。
# OpenResty_Install_Mode 支持两种安装方式：
#   pkg     官方 apt/yum 仓库装预编译包。不编译，快。
#           完整性由包管理器的 GPG 签名保证，
#           不写入 src/checksums.sha256；该清单仅用于下载的 tarball。
#           限制：仓库必须有当前发行版代号对应的目录。
#   source  下载官方源码 tarball 自行编译。慢，但不挑发行版。
#           用 Yichun Zhang 的 PGP 公钥验签（见 Verify_OpenResty_Signature）。
# 目录约定：OpenResty 官方包/源码默认前缀都是 /usr/local/openresty，
# Nginx 位于其 nginx 子目录。安装后通过 /usr/local/nginx 软链接兼容现有
# 虚拟主机、服务脚本和 rewrite 管理路径。


# 安装前检查 Nginx 与 OpenResty 是否冲突；参数为 nginx 或 openresty。
Check_WebServer_Conflict()
{
    local want="$1"

    if [ "${want}" = "openresty" ]; then
        # 真实的 /usr/local/nginx 目录表示已安装源码版 Nginx。
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

# 获取当前发行版在 OpenResty 仓库中的代号，无法确定时返回非零。
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

# 从 OpenResty 官方仓库安装预编译包。
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

        # 写入 APT 源前确认发行版目录存在，避免无效源影响后续 apt 操作。
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

        Apt_Get -y install --no-install-recommends wget gnupg ca-certificates lsb-release >/dev/null 2>&1

        # 通过 signed-by 将公钥限定到 OpenResty 软件源，避免扩大系统信任范围。
        # 公钥下载使用权限受限的随机临时目录，防止固定临时路径被链接替换。
        mkdir -p /usr/share/keyrings

        local or_tmp or_key
        or_tmp=$(umask 077; mktemp -d) || {
            Echo_Red "无法创建临时目录。"; return 1; }
        # 正常返回或收到中断信号时均清理临时目录。
        trap 'rm -rf "${or_tmp}"' RETURN INT TERM
        or_key="${or_tmp}/pubkey.gpg"

        if ! Download_Fetch "https://openresty.org/package/pubkey.gpg" "${or_key}"; then
            Echo_Red "下载 OpenResty 仓库公钥失败。"
            return 1
        fi
        if ! gpg --dearmor < "${or_key}" > /usr/share/keyrings/openresty.gpg 2>/dev/null; then
            # 公钥已经是二进制格式时直接安装。
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

        Apt_Get update -y
        if ! Apt_Get -y install --no-install-recommends openresty; then
            Echo_Red "安装 openresty 包失败。"
            Echo_Red "排查：apt-get install openresty 看具体报错；"
            Echo_Red "或改用源码编译方式。"
            return 1
        fi

    elif [ "${PM}" = "yum" ]; then
        # EL9 及以上使用 openresty2.repo，EL8 及更早使用 openresty.repo。
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

# 下载官方源码并编译安装。
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
        echo "${tarball} [已找到]"
    fi

    # OpenResty 源码使用上游 PGP 签名验证，不使用 src/checksums.sha256。
    if ! Verify_OpenResty_Signature "${cur_dir}/src/${tarball}" "${url}"; then
        Echo_Red "OpenResty 源码包验签未通过，中止安装。"
        rm -f "${cur_dir}/src/${tarball}"
        return 1
    fi

    # configure 前完成自定义模块的下载、校验和解压。
    if ! OR_Modules_Prepare; then
        Echo_Red "自定义模块准备失败，中止安装。"
        return 1
    fi

    Tar_Cd "${tarball}" "${OpenResty_Ver}"

    # 启用 PCRE JIT、IPv6 和 SSL；OpenResty 自带 LuaJIT 及 lua-resty 组件。
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

# OpenResty 安装入口。
Install_OpenResty()
{
    Echo_Blue "[+] 正在安装 OpenResty（${OpenResty_Install_Mode}）..."

    Check_WebServer_Conflict openresty || exit 1

    # 预编译包不能加入自定义编译模块，冲突时停止安装。
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

# 安装配置、建立兼容软链接并接入 LNMP 服务管理。
OpenResty_Post_Install()
{
    local ordir=/usr/local/openresty/nginx

    echo "配置 OpenResty ..."

    # 配置模板以 www 用户和用户组运行工作进程。
    id -u www >/dev/null 2>&1 || useradd -M -U -s /sbin/nologin www 2>/dev/null

    mkdir -p "${ordir}/conf/vhost" /home/wwwlogs "${Default_Website_Dir}"

    # 备份 OpenResty 默认配置后安装 LNMP 模板。
    [ -s "${ordir}/conf/nginx.conf" ] && [ ! -s "${ordir}/conf/nginx.conf.orig" ] && \
        cp -a "${ordir}/conf/nginx.conf" "${ordir}/conf/nginx.conf.orig"

    # OpenResty 使用独立模板，避免与源码版 Nginx 的 Lua 搜索路径混用。
    # 两者的 Lua 搜索路径不同：OpenResty 指向自带的 /usr/local/openresty/lualib，
    # 源码版 nginx 指向 /usr/local/nginx/lib/lua，混用会导致 require 失败。
    \cp "${cur_dir}/conf/openresty.conf" "${ordir}/conf/nginx.conf"
    \cp -ra "${cur_dir}/conf/rewrite" "${ordir}/conf/"
    \cp "${cur_dir}/conf/pathinfo.conf" "${ordir}/conf/pathinfo.conf"
    \cp "${cur_dir}/conf/enable-php.conf" "${ordir}/conf/enable-php.conf"
    \cp "${cur_dir}/conf/enable-php-pathinfo.conf" "${ordir}/conf/enable-php-pathinfo.conf"
    # 单独安装时 Stack 是子命令名，需按机器上已装的栈补齐 LNMPA 的反代包含文件。
    if [ "${Stack}" != 'lnmp' ] && [ "${Stack}" != 'lamp' ] && [ "${Stack}" != 'lnmpa' ]; then
        Check_Stack
    fi
    if [ "${Stack}" = 'lnmpa' ] || [ "${Get_Stack:-}" = 'lnmpa' ]; then
        \cp "${cur_dir}/conf/proxy.conf" "${ordir}/conf/proxy.conf"
        \cp "${cur_dir}/conf/proxy-pass-php.conf" "${ordir}/conf/proxy-pass-php.conf"
    fi
    \cp -ra "${cur_dir}/conf/example" "${ordir}/conf/example" 2>/dev/null

    Write_Nginx_Default_VHost "${ordir}/conf" || exit 1

    # 软链接用于兼容所有引用 /usr/local/nginx 的管理入口。
    if [ -e /usr/local/nginx ] && [ ! -L /usr/local/nginx ]; then
        Echo_Red "/usr/local/nginx 已存在且不是软链，无法建立到 OpenResty 的链接。"
        exit 1
    fi
    ln -sfn /usr/local/openresty/nginx /usr/local/nginx
    echo "已建立软链 /usr/local/nginx -> /usr/local/openresty/nginx"

    # 服务脚本通过兼容路径调用 OpenResty 的 Nginx 二进制。
    \cp "${cur_dir}/init.d/init.d.nginx" /etc/init.d/nginx
    chmod +x /etc/init.d/nginx

    # 禁用软件包自带的服务单元，避免与 LNMP 同时管理同一进程和 pid 文件。
    if systemctl list-unit-files 2>/dev/null | grep -q '^openresty\.service'; then
        systemctl stop openresty >/dev/null 2>&1
        systemctl disable openresty >/dev/null 2>&1
        echo "已停用随包的 openresty.service，服务改由 lnmp / /etc/init.d/nginx 管理。"
    fi

    chown -R www:www "${Default_Website_Dir}" 2>/dev/null
    # 安装进程可能继承 umask 077，mkdir 出来的目录会是 700，需显式校正。
    chmod 755 "${Default_Website_Dir}"
    chown root:root /home/wwwlogs
    chmod 755 /home/wwwlogs

    # 在 nginx -t 前生成动态模块和 Lua 搜索路径配置，确保 include 文件存在。
    if ! OR_Modules_Post_Build; then
        Echo_Red "生成模块与 Lua 路径配置失败。"
        exit 1
    fi

    if ! /usr/local/nginx/sbin/nginx -t; then
        Echo_Red "OpenResty 配置检查未通过，请查看上面的报错。"
        exit 1
    fi

    StartUp nginx
    # 保存编译配置供后续升级沿用。
    if ! OR_Modules_Persist; then
        Echo_Red "OpenResty 已安装，但编译期配置持久化失败，不能报告安装完成。"
        exit 1
    fi
    Echo_Green "OpenResty 安装完成：$(/usr/local/openresty/nginx/sbin/nginx -v 2>&1)"
}

# OpenResty 卸载入口。
Uninstall_OpenResty()
{
    echo "移除 OpenResty ..."
    [ -x /etc/init.d/nginx ] && /etc/init.d/nginx stop 2>/dev/null
    systemctl stop openresty 2>/dev/null
    systemctl disable openresty 2>/dev/null

    if [ "${PM}" = "apt" ] && dpkg -l openresty 2>/dev/null | grep -q '^ii'; then
        Apt_Get -y remove --purge openresty 2>/dev/null
        rm -f /etc/apt/sources.list.d/openresty.list /usr/share/keyrings/openresty.gpg
    elif [ "${PM}" = "yum" ] && rpm -q openresty >/dev/null 2>&1; then
        ${PM} remove -y openresty 2>/dev/null
        rm -f /etc/yum.repos.d/openresty.repo
    fi

    # 先删除兼容软链接，再清理 OpenResty 实际目录。
    [ -L /usr/local/nginx ] && rm -f /usr/local/nginx
    rm -rf /usr/local/openresty
    Echo_Green "OpenResty 已移除。"
}
