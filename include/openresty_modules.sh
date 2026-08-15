#!/usr/bin/env bash
#
# OpenResty 自定义编译模块与 Lua 库管理
#
# ---------------------------------------------------------------------------
# 原先只有 include/version.sh 里一个 OpenResty_Modules_Options 变量，
# 是个裸的 configure 参数入口，缺的东西都在这里补：
#
#   * lnmp.conf 里没有配置项，用户不知道有这个入口 → 配置项与说明进 lnmp.conf；
#   * 模块源码要用户自己下载好、自己保证没被动过 → 这里负责下载 + 强制 SHA256；
#   * 初装时临时 export 的参数不落盘，升级时忘记再传就会编译出不含模块的版本
#     → 初装成功后持久化到 /etc/lnmp/openresty-build.conf，升级自动沿用；
#   * 官方软件包安装方式（ORMode=1）根本没法加编译期模块，原先静默忽略
#     → 配了模块却选包安装时直接报错并给出两条出路；
#   * 动态模块编译出 .so 之后没人写 load_module，模块等于没启用
#     → 编译后扫描 modules 目录自动生成 conf/load_modules.conf；
#   * 自定义 Lua 库没有入口 → 支持自定义 lualib 目录，以及 opm / luarocks 包。
# ---------------------------------------------------------------------------

# 编译期配置的持久化位置。这里不含凭据，但与其它 lnmp 配置同处 /etc/lnmp。
OR_Build_Conf="/etc/lnmp/openresty-build.conf"
OR_Prefix="/usr/local/openresty"
OR_Built_Modules_File="${cur_dir}/src/or-modules/.built-modules"

# 由 OR_Modules_Prepare 产出，追加给 ./configure
OR_Modules_Add_Options=""

OR_Field() { printf '%s' "$1" | awk -F'|' -v i="$2" '{gsub(/^[ \t]+|[ \t]+$/,"",$i); print $i}'; }

# 模块名会进路径和文件名，字符集必须先卡住
OR_Check_Module_Name()
{
    case "$1" in
        ''|*[!A-Za-z0-9._-]*)
            Echo_Red "模块名 '$1' 不合法：只允许字母、数字、点、下划线和连字符。"
            return 1 ;;
    esac
    case "$1" in
        .*|*..*) Echo_Red "模块名 '$1' 不合法：不能以点开头或包含 '..'。"; return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# OR_Modules_Configured — 是否配置了任何编译期模块
# ---------------------------------------------------------------------------
OR_Modules_Configured()
{
    [ "${#OpenResty_Custom_Modules[@]}" -gt 0 ] && return 0
    [ -n "${OpenResty_Modules_Options}" ] && return 0
    [ -n "${OpenResty_Custom_Lualib}" ] && return 0
    [ "${#OpenResty_Opm_Packages[@]}" -gt 0 ] && return 0
    [ "${#OpenResty_Luarocks_Packages[@]}" -gt 0 ] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# OR_Check_Pkg_Mode_Conflict — 包安装方式装不了编译期模块
#
# 预编译包里的模块集合是上游定死的。原先这种组合会静默忽略用户配的模块，
# 装完发现模块不在，很难往配置上想。
# ---------------------------------------------------------------------------
OR_Check_Pkg_Mode_Conflict()
{
    OR_Modules_Configured || return 0
    Echo_Red "配置了 OpenResty 自定义编译模块，但安装方式选的是官方软件包（ORMode=1）。"
    Echo_Red "预编译包无法加入编译期模块。二选一："
    Echo_Red "  1) 改用源码编译：ORMode=2 ./install.sh lnmp"
    Echo_Red "  2) 清空 lnmp.conf 里的 OpenResty_Custom_Modules 和 OpenResty_Modules_Options"
    return 1
}

# ---------------------------------------------------------------------------
# OR_Modules_Prepare — 下载、校验、解压模块源码，构造 configure 参数
#
# 每条配置的格式：名称|下载地址|SHA256|类型(static|dynamic)
# 校验强制执行：这些源码会被编译进对外服务的进程，比普通依赖更需要确认来源。
# ---------------------------------------------------------------------------
OR_Modules_Prepare()
{
    local entry name url sha kind dir tarball
    OR_Modules_Add_Options=""
    rm -f "${OR_Built_Modules_File}"

    [ "${#OpenResty_Custom_Modules[@]}" -gt 0 ] || return 0

    mkdir -p "${cur_dir}/src/or-modules" || return 1

    for entry in "${OpenResty_Custom_Modules[@]}"; do
        # 允许在配置里用 # 注释掉某一行
        case "${entry}" in ''|\#*) continue ;; esac

        name=$(OR_Field "${entry}" 1)
        url=$(OR_Field "${entry}" 2)
        sha=$(OR_Field "${entry}" 3)
        kind=$(OR_Field "${entry}" 4)
        [ -n "${kind}" ] || kind="static"

        OR_Check_Module_Name "${name}" || return 1
        if [ -z "${url}" ]; then
            Echo_Red "模块 ${name} 缺少下载地址。格式：名称|下载地址|SHA256|static或dynamic"
            return 1
        fi
        case "${url}" in
            https://*) : ;;
            *) Echo_Red "模块 ${name} 的下载地址必须是 https://：${url}"; return 1 ;;
        esac
        if [ -z "${sha}" ]; then
            Echo_Red "模块 ${name} 缺少 SHA256。编译进 nginx 的代码必须校验来源。"
            Echo_Red "先下载再算：sha256sum <文件>，把结果填进配置的第三段。"
            return 1
        fi
        case "${kind}" in
            static|dynamic) : ;;
            *) Echo_Red "模块 ${name} 的类型只能是 static 或 dynamic，当前是 '${kind}'"; return 1 ;;
        esac

        tarball="${cur_dir}/src/or-modules/or-mod-${name}.tar.gz"
        dir="${cur_dir}/src/or-modules/${name}"

        if [ ! -s "${tarball}" ]; then
            echo "下载 OpenResty 模块 ${name} ..."
            if ! Download_Fetch "${url}" "${tarball}"; then
                Echo_Red "下载模块 ${name} 失败：${url}"
                rm -f "${tarball}"
                return 1
            fi
        else
            echo "模块 ${name} 源码包 [已找到]"
        fi

        if ! Verify_SHA256_Value "${tarball}" "${sha}"; then
            Echo_Red "模块 ${name} 校验未通过，已删除下载的文件。"
            rm -f "${tarball}"
            return 1
        fi

        # 解压到确定的目录名：上游 tarball 顶层目录名不可预测（常带版本号），
        # --strip-components=1 之后 configure 参数才能写死
        rm -rf "${dir}"
        mkdir -p "${dir}" || return 1
        if ! tar zxf "${tarball}" -C "${dir}" --strip-components=1; then
            Echo_Red "解压模块 ${name} 失败。"
            rm -rf "${dir}"
            return 1
        fi
        if [ ! -s "${dir}/config" ]; then
            Echo_Red "模块 ${name} 解压后没有 config 文件，不像是 nginx 模块源码。"
            Echo_Red "确认下载地址指向的是模块仓库的归档包。"
            return 1
        fi

        if [ "${kind}" = "dynamic" ]; then
            OR_Modules_Add_Options="${OR_Modules_Add_Options} --add-dynamic-module=${dir}"
            echo "  模块 ${name}：动态模块"
        else
            OR_Modules_Add_Options="${OR_Modules_Add_Options} --add-module=${dir}"
            echo "  模块 ${name}：静态编入"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# OR_Modules_Capture_Built — make 成功后记录本次真实生成的动态模块
#
# 模块配置名与 .so 文件名没有可靠映射，只能从 nginx 的 objs 目录取实际产物。
# 记录必须发生在源码目录被删除之前，Post_Build 再用这份清单生成 load_module。
# ---------------------------------------------------------------------------
OR_Modules_Capture_Built()
{
    local tmp so
    mkdir -p "${OR_Built_Modules_File%/*}" || return 1
    tmp=$(mktemp "${OR_Built_Modules_File}.XXXXXXXX") || return 1
    for so in build/nginx-*/objs/*.so; do
        [ -f "${so}" ] || continue
        printf '%s\n' "${so##*/}"
    done | LC_ALL=C sort -u > "${tmp}"
    mv -f "${tmp}" "${OR_Built_Modules_File}" || { rm -f "${tmp}"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# OR_Write_Load_Modules_Conf — 生成动态模块的 load_module 指令
#
# --add-dynamic-module 只是把 .so 编译出来放进 modules/，nginx 不会自动加载。
# 少了这一步，动态模块等于没装，而且不会有任何报错。
# 直接扫描 modules 目录而不是照配置推断文件名：.so 的名字由模块自己的 config
# 决定，未必等于配置里写的名称。
# ---------------------------------------------------------------------------
OR_Write_Load_Modules_Conf()
{
    local conf="${OR_Prefix}/nginx/conf/load_modules.conf"
    local moddir="${OR_Prefix}/nginx/modules" so name old n=0 tmp

    mkdir -p "${conf%/*}" || return 1
    tmp=$(mktemp "${conf}.XXXXXXXX") || return 1

    # 只删除上一版由本文件加载、而本次构建已不再产出的模块。目录中其它手工
    # 放置的 .so 不归 LNMP 管，既不加载也不删除。
    if [ -f "${OR_Built_Modules_File}" ] && [ -f "${conf}" ]; then
        old=$(sed -n 's#^[[:space:]]*load_module[[:space:]]\+modules/\([^;]*\.so\);#\1#p' "${conf}")
        for name in ${old}; do
            if ! grep -Fxq -- "${name}" "${OR_Built_Modules_File}"; then
                rm -f -- "${moddir}/${name}" || { rm -f "${tmp}"; return 1; }
            fi
        done
    fi
    {
        echo "# 由 lnmp 自动生成：OpenResty 动态模块的加载指令。"
        echo "# 重新编译（安装或 ./upgrade.sh openresty）时会重写本文件，手工修改会丢失。"
        if [ -f "${OR_Built_Modules_File}" ]; then
            while IFS= read -r name; do
                [ -n "${name}" ] || continue
                so="${moddir}/${name}"
                if [ ! -f "${so}" ]; then
                    Echo_Red "本次构建记录了 ${name}，但 make install 后未找到 ${so}。"
                    rm -f "${tmp}"
                    return 1
                fi
                printf 'load_module modules/%s;\n' "${name}"
                n=$((n + 1))
            done < "${OR_Built_Modules_File}"
        fi
        [ "${n}" -eq 0 ] && echo "# （当前没有动态模块）"
    } > "${tmp}"
    mv -f "${tmp}" "${conf}" || { rm -f "${tmp}"; return 1; }
    chmod 644 "${conf}"
    if [ "${n}" -gt 0 ]; then
        echo "已生成 ${n} 条 load_module 指令：${conf}"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# OR_Write_Lua_Paths_Conf — 生成 Lua 搜索路径
#
# 自定义 lualib 目录要进 lua_package_path，否则 require 找不到。
# 单独成文件由 nginx.conf include，避免每次都去改模板。
# ---------------------------------------------------------------------------
OR_Write_Lua_Paths_Conf()
{
    local conf="${OR_Prefix}/nginx/conf/lua_paths.conf" tmp extra_lua='' extra_c=''

    if [ -n "${OpenResty_Custom_Lualib}" ]; then
        case "${OpenResty_Custom_Lualib}" in
            /*) : ;;
            *) Echo_Red "OpenResty_Custom_Lualib 必须是绝对路径：${OpenResty_Custom_Lualib}"; return 1 ;;
        esac
        if [ ! -d "${OpenResty_Custom_Lualib}" ]; then
            echo "自定义 Lua 库目录不存在，创建：${OpenResty_Custom_Lualib}"
            mkdir -p "${OpenResty_Custom_Lualib}" || return 1
        fi
        extra_lua="${OpenResty_Custom_Lualib}/?.lua;${OpenResty_Custom_Lualib}/?/init.lua;"
        extra_c="${OpenResty_Custom_Lualib}/?.so;"
    fi

    mkdir -p "${conf%/*}" || return 1
    tmp=$(mktemp "${conf}.XXXXXXXX") || return 1
    {
        echo "# 由 lnmp 自动生成：OpenResty 的 Lua 搜索路径。"
        echo "# 自定义目录来自 lnmp.conf 的 OpenResty_Custom_Lualib，重新编译时会重写。"
        echo "# 结尾的 \";;\" 表示保留 Lua 的默认搜索路径。"
        printf 'lua_package_path "%s/lualib/?.lua;%s/lualib/?/init.lua;%s;;";\n' \
            "${OR_Prefix}" "${OR_Prefix}" "${extra_lua%;}"
        printf 'lua_package_cpath "%s/lualib/?.so;%s;;";\n' "${OR_Prefix}" "${extra_c%;}"
    } > "${tmp}"
    mv -f "${tmp}" "${conf}" || { rm -f "${tmp}"; return 1; }
    chmod 644 "${conf}"
    return 0
}

# ---------------------------------------------------------------------------
# OR_Install_Lua_Packages — opm / luarocks 包
#
# opm 是 OpenResty 自带的包管理器，装的是 lua-resty-* 这类纯 Lua 库；
# luarocks 不随 OpenResty 分发，只有系统里已经有才用。
# 装包失败不中止安装：Web 服务本身是好的，缺库属于可以事后补的问题。
# ---------------------------------------------------------------------------
OR_Install_Lua_Packages()
{
    local pkg failed=0 opm="${OR_Prefix}/bin/opm" rocks

    if [ "${#OpenResty_Opm_Packages[@]}" -gt 0 ]; then
        if [ ! -x "${opm}" ]; then
            Echo_Red "配置了 OpenResty_Opm_Packages，但没有 ${opm}（包安装方式可能不带 opm）。"
            failed=1
        else
            for pkg in "${OpenResty_Opm_Packages[@]}"; do
                case "${pkg}" in ''|\#*) continue ;; esac
                echo "opm get ${pkg}"
                "${opm}" get "${pkg}" || { Echo_Red "opm 安装失败：${pkg}"; failed=1; }
            done
        fi
    fi

    if [ "${#OpenResty_Luarocks_Packages[@]}" -gt 0 ]; then
        rocks=$(command -v luarocks 2>/dev/null)
        if [ -z "${rocks}" ]; then
            Echo_Red "配置了 OpenResty_Luarocks_Packages，但系统里没有 luarocks。"
            Echo_Red "先安装 luarocks（apt-get install luarocks / yum install luarocks），再重跑。"
            failed=1
        else
            for pkg in "${OpenResty_Luarocks_Packages[@]}"; do
                case "${pkg}" in ''|\#*) continue ;; esac
                echo "luarocks install ${pkg}"
                "${rocks}" install ${pkg} || { Echo_Red "luarocks 安装失败：${pkg}"; failed=1; }
            done
        fi
    fi

    [ "${failed}" -eq 0 ] || Echo_Red "部分 Lua 包未安装成功，Web 服务不受影响，可稍后手工补装。"
    return 0
}

# ---------------------------------------------------------------------------
# OR_Modules_Persist — 把这次用到的编译期配置落盘
#
# 初装时用环境变量临时传入的参数不会自己留下来。升级走的是另一个入口，
# 忘记再传一遍就会编译出一个不含这些模块的 OpenResty，
# 而且同样不会有任何报错 —— 直到某天发现某个 location 不工作。
# ---------------------------------------------------------------------------
OR_Modules_Persist()
{
    local tmp m
    mkdir -p "${OR_Build_Conf%/*}" 2>/dev/null && chmod 700 "${OR_Build_Conf%/*}" 2>/dev/null
    tmp=$(mktemp "${OR_Build_Conf}.XXXXXXXX") || return 1
    {
        echo "# OpenResty 编译期配置 —— 由安装流程自动生成。"
        echo "# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
        echo "#"
        echo "# ./upgrade.sh openresty 会读取本文件，用同一组模块重新编译，"
        echo "# 所以升级时不必再手工传一遍参数。"
        echo "# lnmp.conf 里显式配置了模块时以 lnmp.conf 为准，本文件作为后备。"
        echo ""
        printf 'OpenResty_Modules_Options=%s\n' "$(printf '%q' "${OpenResty_Modules_Options}")"
        printf 'OpenResty_Custom_Lualib=%s\n' "$(printf '%q' "${OpenResty_Custom_Lualib}")"
        echo "OpenResty_Custom_Modules=("
        for m in "${OpenResty_Custom_Modules[@]}"; do
            printf '    %s\n' "$(printf '%q' "${m}")"
        done
        echo ")"
        echo "OpenResty_Opm_Packages=("
        for m in "${OpenResty_Opm_Packages[@]}"; do
            printf '    %s\n' "$(printf '%q' "${m}")"
        done
        echo ")"
        echo "OpenResty_Luarocks_Packages=("
        for m in "${OpenResty_Luarocks_Packages[@]}"; do
            printf '    %s\n' "$(printf '%q' "${m}")"
        done
        echo ")"
    } > "${tmp}"
    mv -f "${tmp}" "${OR_Build_Conf}" || { rm -f "${tmp}"; return 1; }
    chmod 600 "${OR_Build_Conf}"
    echo "编译期配置已记录到 ${OR_Build_Conf}，升级时会自动沿用。"
    return 0
}

# ---------------------------------------------------------------------------
# OR_Modules_Load_Persisted — 升级入口读取初装时的配置
#
# 显式配置优先：lnmp.conf 里配了就用 lnmp.conf 的，什么都没配才回落到
# 初装时记录的那一份。这样"想改"和"忘了传"能区分开。
# ---------------------------------------------------------------------------
OR_Modules_Load_Persisted()
{
    [ -f "${OR_Build_Conf}" ] || return 0
    if OR_Modules_Configured; then
        echo "使用当前配置中的 OpenResty 模块设置（未沿用 ${OR_Build_Conf}）。"
        return 0
    fi
    # shellcheck disable=SC1090
    . "${OR_Build_Conf}" || { Echo_Red "读取 ${OR_Build_Conf} 失败。"; return 1; }
    if OR_Modules_Configured; then
        echo "沿用初装时记录的 OpenResty 模块配置（${OR_Build_Conf}）。"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# OR_Modules_Post_Build — 编译安装之后统一收尾
# ---------------------------------------------------------------------------
OR_Modules_Post_Build()
{
    OR_Write_Load_Modules_Conf || return 1
    rm -f "${OR_Built_Modules_File}"
    OR_Write_Lua_Paths_Conf || return 1
    OR_Install_Lua_Packages
    return 0
}
