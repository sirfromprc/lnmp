#!/usr/bin/env bash
#
# t/product_version.sh - 输出产品版本号，供工作流与发布流程取值
#
# 用法：
#   bash t/product_version.sh          输出裸版本号，如 3.0.5
#   bash t/product_version.sh --tag    输出带 v 前缀的形式，如 v3.0.5
#
# 版本号唯一来源是 include/product.sh 的 LNMP_Ver，格式 MAJOR.MINOR.PATCH。
# 工作流不得硬编码版本号。

set -u

cd "$(dirname "$0")/.." || exit 1

file=include/product.sh
if [ ! -f "${file}" ]; then
    echo "错误：${file} 不存在。" >&2
    exit 1
fi
# 只取顶层赋值，避开注释与字符串内的同名引用。
ver=$(sed -n "s/^LNMP_Ver=['\"]\([^'\"]*\)['\"].*/\1/p" "${file}" | head -1)
if [ -z "${ver}" ]; then
    echo "错误：${file} 中找不到 LNMP_Ver 赋值。" >&2
    exit 1
fi
if ! printf '%s' "${ver}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "错误：版本号 ${ver} 不符合 MAJOR.MINOR.PATCH。" >&2
    exit 1
fi

case "${1:-}" in
    --tag) printf 'v%s\n' "${ver}" ;;
    '')    printf '%s\n' "${ver}" ;;
    *)
        echo "用法：bash t/product_version.sh [--tag]" >&2
        exit 1
        ;;
esac
