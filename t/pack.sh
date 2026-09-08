#!/usr/bin/env bash
#
# t/pack.sh - 打发布包
#
# 用法：bash t/pack.sh <源码目录> <包名> <输出目录>
#   包名不带 .tar.gz，同时用作包内顶层目录名。
#   例：bash t/pack.sh . lnmp-v2.3 dist  ->  dist/lnmp-v2.3.tar.gz
#
# 发布包排除 CI 配置、交接文档、待办清单和本地定向测试。
# t/ 保留，其中的下载探测脚本可供使用者排查安装问题。
#
# 发布要打主分支与升级分支两个包，打包规则集中在此，避免两处各写一份。

set -u

Src="${1:-}"
Pkg="${2:-}"
Out="${3:-}"

if [ -z "${Src}" ] || [ -z "${Pkg}" ] || [ -z "${Out}" ]; then
    echo "用法：bash t/pack.sh <源码目录> <包名> <输出目录>" >&2
    exit 1
fi

if [ ! -d "${Src}" ]; then
    echo "错误：源码目录 ${Src} 不存在。" >&2
    exit 1
fi

if [ ! -f "${Src}/install.sh" ]; then
    echo "错误：${Src} 不是 LNMP 源码目录（缺少 install.sh）。" >&2
    exit 1
fi

case "${Pkg}" in
    */*|'')
        echo "错误：包名 ${Pkg} 不能为空或含路径分隔符。" >&2
        exit 1
        ;;
esac

mkdir -p "${Out}" || exit 1
Out_Abs=$(cd "${Out}" && pwd) || exit 1

Stage=$(mktemp -d) || exit 1
trap 'rm -rf "${Stage}"' EXIT

mkdir -p "${Stage}/${Pkg}" || exit 1

if ! tar --exclude-vcs \
         --exclude='./.github' \
         --exclude='./.claude' \
         --exclude='./.upstream' \
         --exclude='./dist' \
         --exclude='./tests' \
         --exclude='./HANDOVER.md' \
         --exclude='./todo*.md' \
         --exclude='./src/*.tar.*' \
         --exclude='./src/*.tgz' \
         -cf - -C "${Src}" . | tar -xf - -C "${Stage}/${Pkg}"; then
    echo "错误：复制源码树失败。" >&2
    exit 1
fi

if ! tar -czf "${Out_Abs}/${Pkg}.tar.gz" -C "${Stage}" "${Pkg}"; then
    echo "错误：打包失败。" >&2
    exit 1
fi

echo "已生成 ${Out_Abs}/${Pkg}.tar.gz（$(du -h "${Out_Abs}/${Pkg}.tar.gz" | cut -f1)）"
