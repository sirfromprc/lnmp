#!/usr/bin/env bash
#
# Node.js 模块：官方二进制归档的验签、暂存与换入。按主版本并存于 /usr/local/nodejs/<主版本>/，
# 不建立全局 node 链接；应用经 lnmp app 启动命令中的绝对路径绑定解释器。
#
#   Nodejs_Version  <主版本>     输出固定的完整版本；非支持的主版本返回 1
#   Nodejs_Resolve  <输入>       输出主版本；输入为主版本、v 前缀或固定的完整版本；不识别返回 1
#   Nodejs_Sources  <主版本>     输出下载清单，不下载、不写文件
#   Nodejs_Installed <主版本>    输出已装完整版本；0 已装；1 未装；2 无法读取版本
#   Nodejs_Check    <主版本>     0 就绪且与固定版本一致；1 缺失或不完整；2 版本不符；3 参数错误
#   Nodejs_Install  <主版本>     旧目录的 npm 全局包（含 PM2）随换入沿用；0 成功或已就绪；1 失败，线上未改动；2 换入后失败且旧目录未能恢复；3 参数错误
#   Nodejs_Verify   <主版本>     Check 通过后实际运行 node 与 npm
#   Nodejs_Users    <主版本>     输出引用该主版本的应用名；0 有引用；1 无
#   Nodejs_Remove   <主版本>     0 已删除；1 未安装；2 删除失败；3 参数错误；4 有应用引用，拒绝
#   Nodejs_Pm2_Version <主版本>  输出已装 PM2 版本；0 已装；1 未装
#   Nodejs_Pm2_Install <主版本>  经 npm 安装到该主版本目录，版本不固定；0 成功或已装；1 失败；3 主版本未安装
#   Nodejs_Pm2_Users   <主版本>  输出以该主版本 pm2-runtime 启动的应用名；0 有；1 无
#   Nodejs_Pm2_Remove  <主版本>  0 已卸载；1 未安装；2 卸载失败；3 参数错误；4 有应用引用，拒绝
#
# 约定：不交互、不 exit、不改变调用方工作目录；下载、解包与换入在子 shell 中执行。
# 安装前缀与应用元数据目录可由 LNMP_NODEJS_PREFIX、LNMP_APP_CONF_DIR 覆盖（测试用）。

_Nodejs_Prefix()
{
    printf '%s\n' "${LNMP_NODEJS_PREFIX:-/usr/local/nodejs}"
}

_Nodejs_Major_Ok()
{
    local m

    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    for m in ${Nodejs_Majors}; do
        [ "${m}" = "$1" ] && return 0
    done
    return 1
}

_Nodejs_Arch()
{
    case "$(uname -m)" in
    x86_64|amd64)  printf 'x64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) return 1 ;;
    esac
}

Nodejs_Version()
{
    local var

    _Nodejs_Major_Ok "$1" || return 1
    var="Nodejs_${1}_Ver"
    [ -n "${!var:-}" ] || return 1
    printf '%s\n' "${!var}"
}

Nodejs_Resolve()
{
    local in="${1#v}" m

    if _Nodejs_Major_Ok "${in}"; then
        printf '%s\n' "${in}"
        return 0
    fi
    for m in ${Nodejs_Majors}; do
        [ "$(Nodejs_Version "${m}")" = "${in}" ] || continue
        printf '%s\n' "${m}"
        return 0
    done
    return 1
}

Nodejs_Sources()
{
    local major=$1 ver arch file

    ver=$(Nodejs_Version "${major}") || return 1
    arch=$(_Nodejs_Arch) || return 1
    file="node-v${ver}-linux-${arch}.tar.xz"
    printf 'nodejs\t%s/%s\t%s\t%s\thttps://nodejs.org/dist/v%s/%s\tsha256\tsrc/checksums.sha256\n' \
        "$(_Nodejs_Prefix)" "${major}" "${ver}" "${file}" "${ver}" "${file}"
}

Nodejs_Installed()
{
    local bin ver

    bin="$(_Nodejs_Prefix)/$1/bin/node"
    [ -x "${bin}" ] || return 1
    ver=$("${bin}" --version 2>/dev/null) || return 2
    ver=${ver#v}
    [[ "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
    printf '%s\n' "${ver}"
}

Nodejs_Check()
{
    local major=$1 want have dir rc

    want=$(Nodejs_Version "${major}") || return 3
    dir="$(_Nodejs_Prefix)/${major}"
    [ -x "${dir}/bin/npm" ] || return 1
    have=$(Nodejs_Installed "${major}"); rc=$?
    [ "${rc}" -eq 0 ] || return 1
    [ "${have}" = "${want}" ] || return 2
    return 0
}

Nodejs_Verify()
{
    local major=$1 dir want

    Nodejs_Check "${major}" || return 1
    dir="$(_Nodejs_Prefix)/${major}"
    want=$(Nodejs_Version "${major}")
    [ "$("${dir}/bin/node" -p 'process.versions.node' 2>/dev/null)" = "${want}" ] || return 1
    # npm 的解释器行为 #!/usr/bin/env node，需要同目录的 node 在 PATH 中。
    PATH="${dir}/bin:${PATH}" "${dir}/bin/npm" --version >/dev/null 2>&1
}

# _Nodejs_Verify_Signed <版本> <归档>：取上游 SHASUMS256.txt 与分离签名，验签后核对归档哈希。
_Nodejs_Verify_Signed()
{
    local ver=$1 file=$2 base tmp want rc=1

    base="https://nodejs.org/dist/v${ver}"
    tmp=$(mktemp -d) || return 1
    if Download_Fetch "${base}/SHASUMS256.txt" "${tmp}/SHASUMS256.txt" \
       && Download_Fetch "${base}/SHASUMS256.txt.sig" "${tmp}/SHASUMS256.txt.sig" \
       && Verify_Nodejs_Shasums "${tmp}/SHASUMS256.txt" "${tmp}/SHASUMS256.txt.sig"; then
        want=$(awk -v f="${file}" '$2 == f { print $1; exit }' "${tmp}/SHASUMS256.txt")
        if [ -z "${want}" ]; then
            Echo_Red "上游已签名的校验清单中没有 ${file}。"
        elif Verify_SHA256_Value "${file}" "${want}"; then
            rc=0
        fi
    else
        Echo_Red "无法取得或验证 Node.js ${ver} 的签名校验清单。"
    fi
    rm -rf "${tmp}"
    return "${rc}"
}

# _Nodejs_Stage <归档> <顶层目录名> <暂存目录>：成员不得为绝对路径或含上级引用，
# 链接目标解析后必须仍在暂存目录内；npm、npx 等链接以 ../lib 相对目标指向包内文件。
_Nodejs_Stage()
{
    local file=$1 top=$2 stage=$3 link target resolved real

    if tar -tJf "${file}" 2>/dev/null | grep -qE '^/|(^|/)\.\.(/|$)'; then
        Echo_Red "Node.js 归档含绝对路径或上级目录成员，拒绝解包。"
        return 1
    fi
    if tar -tJf "${file}" 2>/dev/null | grep -qvE "^${top}(/|\$)"; then
        Echo_Red "Node.js 归档含顶层目录之外的成员，拒绝解包。"
        return 1
    fi
    tar -xJf "${file}" -C "${stage}" --strip-components=1 --no-same-owner || return 1
    real=$(realpath -- "${stage}") || return 1
    while IFS= read -r link; do
        target=$(readlink "${link}")
        case "${target}" in
        /*) return 1 ;;
        esac
        resolved=$(realpath -m -- "${link%/*}/${target}") || return 1
        case "${resolved}/" in
        "${real}"/*) ;;
        *) return 1 ;;
        esac
    done < <(find "${stage}" -type l)
    chown -R root:root "${stage}" && chmod -R go-w,go+rX "${stage}"
}

# _Nodejs_Carry_Globals <旧目录> <暂存目录>：把旧目录中 npm 全局安装的包（除随包的 npm、corepack）
# 及 bin 下指向这些包的相对链接、暂存目录中没有的普通文件复制到暂存目录。同一主版本的 ABI 不变，原生模块可直接沿用。
_Nodejs_Carry_Globals()
{
    local old=$1 stage=$2 pkg name link target

    [ -d "${old}/lib/node_modules" ] || return 0
    mkdir -p "${stage}/lib/node_modules" "${stage}/bin" || return 1
    for pkg in "${old}/lib/node_modules"/* "${old}/lib/node_modules"/.bin; do
        [ -e "${pkg}" ] || [ -L "${pkg}" ] || continue
        name=${pkg##*/}
        case "${name}" in npm|corepack|.bin) continue ;; esac
        [ -e "${stage}/lib/node_modules/${name}" ] && continue
        cp -a -- "${pkg}" "${stage}/lib/node_modules/" || return 1
    done
    for link in "${old}/bin"/*; do
        [ -e "${stage}/bin/${link##*/}" ] || [ -L "${stage}/bin/${link##*/}" ] && continue
        if [ -L "${link}" ]; then
            target=$(readlink "${link}")
            case "${target}" in
            ../lib/node_modules/npm/*|../lib/node_modules/corepack/*) continue ;;
            ../lib/node_modules/*) ;;
            *) continue ;;
            esac
            case "${target#../}" in *../*) continue ;; esac
            ln -s -- "${target}" "${stage}/bin/${link##*/}" || return 1
        elif [ -f "${link}" ]; then
            cp -a -- "${link}" "${stage}/bin/" || return 1
        fi
    done
    return 0
}

# _Nodejs_Install <主版本>：在子 shell 中调用。暂存目录 .stage.<主版本>.<PID> 与目标同属前缀目录，
# 经改名换入，换入后复核失败则放回旧目录；暂存目录由 Nodejs_Install 在返回前清理。
_Nodejs_Install()
{
    local major=$1 prefix dir ver file url stage old='' arch top pm2=n

    prefix=$(_Nodejs_Prefix)
    dir="${prefix}/${major}"
    IFS=$'\t' read -r _ _ ver file url _ _ < <(Nodejs_Sources "${major}") || {
        Echo_Red "当前架构 $(uname -m) 没有 Node.js 官方二进制。"
        return 1
    }
    arch=$(_Nodejs_Arch)
    top="node-v${ver}-linux-${arch}"

    cd "${cur_dir}/src" || return 1
    Download_Files "${url}" "${file}" || return 1
    Require_File "${file}" "Node.js ${ver}" || return 1
    if ! _Nodejs_Verify_Signed "${ver}" "${file}"; then
        rm -f "${file}"
        return 1
    fi

    mkdir -p "${prefix}" && chmod 755 "${prefix}" || return 1
    stage="${prefix}/.stage.${major}.$$"
    rm -rf -- "${prefix}/.stage.${major}."*
    mkdir -m 755 "${stage}" || return 1
    if ! _Nodejs_Stage "${cur_dir}/src/${file}" "${top}" "${stage}"; then
        Echo_Red "Node.js ${ver} 解包失败或归档结构异常。"
        return 1
    fi
    if [ "$("${stage}/bin/node" --version 2>/dev/null)" != "v${ver}" ] || [ ! -e "${stage}/bin/npm" ]; then
        Echo_Red "暂存的 Node.js 无法运行或缺少 npm，与当前系统不兼容。"
        return 1
    fi
    if [ -d "${dir}" ]; then
        [ -s "${dir}/lib/node_modules/pm2/package.json" ] && pm2=y
        if ! _Nodejs_Carry_Globals "${dir}" "${stage}"; then
            Echo_Red "无法复制 ${dir} 中的 npm 全局包（含 PM2），未改动线上目录。"
            return 1
        fi
    fi

    if [ -e "${dir}" ]; then
        old="${prefix}/.old.${major}.$$"
        mv -T -- "${dir}" "${old}" || return 1
    fi
    if ! mv -T -- "${stage}" "${dir}"; then
        [ -z "${old}" ] || mv -T -- "${old}" "${dir}" || return 2
        return 1
    fi
    if ! Nodejs_Check "${major}" || { [ "${pm2}" = y ] && ! Nodejs_Pm2_Version "${major}" >/dev/null; }; then
        Echo_Red "Node.js ${ver} 换入后复核失败（含 npm 全局包 PM2），恢复原目录。"
        rm -rf -- "${dir}"
        [ -z "${old}" ] || mv -T -- "${old}" "${dir}" || return 2
        return 1
    fi
    [ -z "${old}" ] || rm -rf -- "${old}"
    return 0
}

Nodejs_Install()
{
    local major=$1 rc

    Nodejs_Check "${major}"; rc=$?
    case "${rc}" in
    0) return 0 ;;
    3) return 3 ;;
    esac
    ( _Nodejs_Install "${major}" )
    rc=$?
    rm -rf -- "$(_Nodejs_Prefix)/.stage.${major}.$$"
    return "${rc}"
}

Nodejs_Users()
{
    local major=$1 conf="${LNMP_APP_CONF_DIR:-/etc/lnmp/apps}" env_file bin_dir found=1

    bin_dir="$(_Nodejs_Prefix)/${major}/bin"
    for env_file in "${conf}"/*.env; do
        [ -s "${env_file}" ] || continue
        if awk -F= -v d="${bin_dir}" '
            $1 == "APP_EXEC" { split(substr($0, 10), a, " "); if (index(a[1], d "/") == 1) hit = 1 }
            $1 == "PATH"     { if (index(":" substr($0, 6) ":", ":" d ":") > 0) hit = 1 }
            END { exit !hit }' "${env_file}"; then
            printf '%s\n' "$(basename "${env_file}" .env)"
            found=0
        fi
    done
    return "${found}"
}

Nodejs_Remove()
{
    local major=$1 dir

    _Nodejs_Major_Ok "${major}" || return 3
    dir="$(_Nodejs_Prefix)/${major}"
    [ -d "${dir}" ] || return 1
    Nodejs_Users "${major}" >/dev/null && return 4
    rm -rf -- "${dir}" || return 2
    [ ! -e "${dir}" ] || return 2
    return 0
}

Nodejs_Pm2_Version()
{
    local dir json ver

    dir="$(_Nodejs_Prefix)/$1"
    json="${dir}/lib/node_modules/pm2/package.json"
    [ -x "${dir}/bin/pm2-runtime" ] && [ -s "${json}" ] || return 1
    ver=$("${dir}/bin/node" -p "require('${json}').version" 2>/dev/null) || return 1
    [[ "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
    printf '%s\n' "${ver}"
}

Nodejs_Pm2_Install()
{
    local major=$1 dir

    _Nodejs_Major_Ok "${major}" || return 3
    dir="$(_Nodejs_Prefix)/${major}"
    Nodejs_Check "${major}" || return 3
    Nodejs_Pm2_Version "${major}" >/dev/null && return 0
    if ! PATH="${dir}/bin:${PATH}" npm install -g pm2 --no-audit --no-fund --loglevel=error; then
        PATH="${dir}/bin:${PATH}" npm uninstall -g pm2 >/dev/null 2>&1
        return 1
    fi
    chmod -R go-w "${dir}/lib/node_modules/pm2" 2>/dev/null
    Nodejs_Pm2_Version "${major}" >/dev/null
}

Nodejs_Pm2_Users()
{
    local major=$1 conf="${LNMP_APP_CONF_DIR:-/etc/lnmp/apps}" env_file found=1

    for env_file in "${conf}"/*.env; do
        [ -s "${env_file}" ] || continue
        if awk -F= -v b="$(_Nodejs_Prefix)/${major}/bin/pm2-runtime" '
            $1 == "APP_EXEC" { split(substr($0, 10), a, " "); if (a[1] == b) hit = 1 }
            END { exit !hit }' "${env_file}"; then
            printf '%s\n' "$(basename "${env_file}" .env)"
            found=0
        fi
    done
    return "${found}"
}

Nodejs_Pm2_Remove()
{
    local major=$1 dir

    _Nodejs_Major_Ok "${major}" || return 3
    dir="$(_Nodejs_Prefix)/${major}"
    Nodejs_Pm2_Version "${major}" >/dev/null || return 1
    Nodejs_Pm2_Users "${major}" >/dev/null && return 4
    PATH="${dir}/bin:${PATH}" npm uninstall -g pm2 --no-audit --no-fund --loglevel=error || return 2
    Nodejs_Pm2_Version "${major}" >/dev/null && return 2
    return 0
}
