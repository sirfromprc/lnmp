#!/usr/bin/env bash
#
# t/release_notes.sh - 生成 Release 说明，输出 markdown 到标准输出
#
# 环境变量：
#   PRODUCT      产品版本，如 v2.3
#   STAMP        发布日期标识，如 20260908
#   REPO         owner/repo，用于给出构建证明的验证命令
#   LEVEL        主分支包的编译验证深度，full 或 quick
#   AUTO_LEVEL   升级包的编译验证深度，默认 full；该验证在上游版本检查里完成
#   BASE_DIR     主分支源码目录，BASE_PKG 为其包名
#   AUTO_DIR     升级分支源码目录，AUTO_PKG 为其包名，AUTO_BRANCH 为分支名
#                三者留空表示本次没有升级分支，只发主分支的包
#
# 两个包的验证深度可以不同：升级包的组件版本是新的，必须过 full；主分支包的组件版本
# 上次发布已验过，自动发布时只做 Lua 冒烟。说明里按包分别写清楚。
#
# 说明的首要职责是让使用者分清两个包：不带日期的是非自动升级包。

set -u

Product="${PRODUCT:-}"
Stamp="${STAMP:-}"
Repo="${REPO:-}"
Level="${LEVEL:-full}"
Auto_Level="${AUTO_LEVEL:-full}"
Base_Dir="${BASE_DIR:-.}"
Base_Pkg="${BASE_PKG:-}"
Auto_Dir="${AUTO_DIR:-}"
Auto_Pkg="${AUTO_PKG:-}"
Auto_Branch="${AUTO_BRANCH:-}"

if [ -z "${Product}" ] || [ -z "${Stamp}" ] || [ -z "${Base_Pkg}" ]; then
    echo "错误：PRODUCT、STAMP、BASE_PKG 必须设置。" >&2
    exit 1
fi

Has_Auto=0
if [ -n "${Auto_Dir}" ] && [ -n "${Auto_Pkg}" ]; then
    if [ ! -f "${Auto_Dir}/include/version.sh" ]; then
        echo "错误：${Auto_Dir} 不是源码目录。" >&2
        exit 1
    fi
    Has_Auto=1
fi

# 在子 shell 里取值，避免两个分支的版本常量互相覆盖。
Get() {
    (
        # shellcheck disable=SC1091
        . "$1/include/version.sh" 2>/dev/null || exit 1
        local name="$2"
        printf '%s' "${!name-}"
    )
}

# 组件展示名与 version.sh 中的变量名、需要剥掉的前缀。
Components='nginx|Nginx_Ver|nginx-
OpenSSL|Openssl_New_Ver|openssl-
OpenResty（可选）|OpenResty_Ver|openresty-
Redis|Redis_Stable_Ver|redis-
Memcached|Memcached_Ver|memcached-
pure-ftpd|Pureftpd_Ver|pure-ftpd-
lua-nginx-module|LuaNginxModule|lua-nginx-module-
lua-resty-core|LuaRestyCore|lua-resty-core-'

echo "本次发布的产品版本是 **${Product}**，\`${Stamp}\` 只是这一次发布的日期标识。"
echo

if [ "${Has_Auto}" -eq 1 ]; then
    cat <<EOF
## 下载哪个包

本次发布包含两个包，**组件版本不同，请按需选择**：

| 包 | 组件版本 | 说明 |
| --- | --- | --- |
| \`${Base_Pkg}.tar.gz\` | 维护者手工确认 | **不含自动升级**。组件版本经过人工核对，变动少。 |
| \`${Auto_Pkg}.tar.gz\` | 每月自动跟进上游 | 含自动升级。由 \`${Auto_Branch}\` 分支打出，组件版本较新。 |

两个包的脚本源码相同，差别只在 \`include/version.sh\`、\`include/profile.sh\`
和 \`src/checksums.sha256\` 里的组件版本号。

不确定选哪个就用 \`${Base_Pkg}.tar.gz\`。它的固定下载地址是：

\`\`\`
https://github.com/${Repo}/releases/latest/download/${Base_Pkg}.tar.gz
\`\`\`

## 组件版本对照

| 组件 | ${Base_Pkg} | ${Auto_Pkg} |
| --- | --- | --- |
EOF
    while IFS='|' read -r label var prefix; do
        [ -n "${label}" ] || continue
        b=$(Get "${Base_Dir}" "${var}")
        a=$(Get "${Auto_Dir}" "${var}")
        b="${b#"${prefix}"}"
        a="${a#"${prefix}"}"
        # 只有版本不同的行才标记，避免整表都是提示符号。
        if [ "${b}" != "${a}" ]; then
            echo "| ${label} | ${b} | **${a}** |"
        else
            echo "| ${label} | ${b} | ${a} |"
        fi
    done <<< "${Components}"
else
    cat <<EOF
## 关于这个包

本次没有待发布的自动升级分支，只提供 \`${Base_Pkg}.tar.gz\`。
该包**不含自动升级**，组件版本由维护者手工确认。

固定下载地址：

\`\`\`
https://github.com/${Repo}/releases/latest/download/${Base_Pkg}.tar.gz
\`\`\`

## 组件版本

| 组件 | 版本 |
| --- | --- |
EOF
    while IFS='|' read -r label var prefix; do
        [ -n "${label}" ] || continue
        b=$(Get "${Base_Dir}" "${var}")
        echo "| ${label} | ${b#"${prefix}"} |"
    done <<< "${Components}"
fi

echo
echo "PHP / MySQL / MariaDB / Apache / phpMyAdmin 为菜单可选，"
echo "具体版本见包内 \`include/profile.sh\`。"
echo
echo "## 发布前已通过"
echo
echo "两个包共同的静态检查："
echo
echo "- \`t/lint.sh\`、\`t/consistency.sh\`、编号映射与派发自测"
echo "- 升版跨文件同步自测：\`t/test_bump.sh\`"
echo
echo "\`${Base_Pkg}.tar.gz\` 的编译验证："
echo
echo "- Lua 全家桶（编译 + 启动 + 真发请求）"
if [ "${Level}" = 'full' ]; then
    echo "- nginx 全模块（含自建 OpenSSL 与 brotli）、PHP 默认分支"
else
    echo "- 组件版本与上一次发布相同，nginx 与 PHP 的完整编译在当时已经通过"
fi

if [ "${Has_Auto}" -eq 1 ]; then
    echo
    echo "\`${Auto_Pkg}.tar.gz\` 的编译验证（在上游版本检查流程中完成）："
    echo
    echo "- Lua 全家桶（编译 + 启动 + 真发请求）"
    if [ "${Auto_Level}" = 'full' ]; then
        echo "- nginx 全模块（含自建 OpenSSL 与 brotli）、PHP 默认分支"
    fi
    echo "- 新版本下载地址可达性探测"
    echo "- 发布前再次回检跨文件一致性与编号映射"
fi
echo
echo "## 校验"
echo
echo '```bash'
echo "sha256sum -c SHA256SUMS"
echo "# 构建证明（无需导入任何公钥）："
echo "gh attestation verify ${Base_Pkg}.tar.gz --repo ${Repo}"
if [ "${Has_Auto}" -eq 1 ]; then
    echo "gh attestation verify ${Auto_Pkg}.tar.gz --repo ${Repo}"
fi
echo '```'
