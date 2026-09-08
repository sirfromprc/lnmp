#!/usr/bin/env bash
#
# t/product_version.sh - 输出产品版本号，供工作流与发布流程取值
#
# 用法：
#   bash t/product_version.sh          输出裸版本号，如 2.3
#   bash t/product_version.sh --tag    输出带 v 前缀的形式，如 v2.3
#
# 版本号以 install.sh 的 LNMP_Ver 为准，uninstall.sh 有一份副本，两者不一致时报错。
# 工作流不得再硬编码版本号，升到 2.4 时只改这两个源文件。

set -u

cd "$(dirname "$0")/.." || exit 1

Extract() {
    local file="$1" ver
    if [ ! -f "${file}" ]; then
        echo "错误：${file} 不存在。" >&2
        return 1
    fi
    # 只取顶层赋值，避开注释与字符串内的同名引用。
    ver=$(sed -n "s/^LNMP_Ver=['\"]\([0-9][0-9.]*\)['\"].*/\1/p" "${file}" | head -1)
    if [ -z "${ver}" ]; then
        echo "错误：${file} 中找不到 LNMP_Ver 赋值。" >&2
        return 1
    fi
    printf '%s' "${ver}"
}

Install_Ver=$(Extract install.sh) || exit 1
Uninstall_Ver=$(Extract uninstall.sh) || exit 1

if [ "${Install_Ver}" != "${Uninstall_Ver}" ]; then
    echo "错误：产品版本号不一致，install.sh 为 ${Install_Ver}，uninstall.sh 为 ${Uninstall_Ver}。" >&2
    exit 1
fi

case "${1:-}" in
    --tag) printf 'v%s\n' "${Install_Ver}" ;;
    '')    printf '%s\n' "${Install_Ver}" ;;
    *)
        echo "用法：bash t/product_version.sh [--tag]" >&2
        exit 1
        ;;
esac
