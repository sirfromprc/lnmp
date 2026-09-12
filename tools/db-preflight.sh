#!/bin/sh
# mysql.service 和 mariadb.service 的启动前检查，安装流程也调用同一实现。
# MySQL 和 MariaDB 通用二进制依赖 libaio.so.1，部分发行版只提供 libaio.so.1t64。
# 兼容链接在安装后可能因升级 libaio、重装系统库或恢复根文件系统而丢失，
# 此时启动失败的报错来自动态链接器，不指向处理入口。
# 仅在动态库解析确实缺失时，为 ABI 兼容的 64 位架构补建链接。
# 用法：db-preflight <服务端二进制路径>

server_bin=$1
[ -n "${server_bin}" ] || exit 0
[ -x "${server_bin}" ] || exit 0

command -v ldd >/dev/null 2>&1 || exit 0
ldd "${server_bin}" 2>/dev/null | grep -q 'libaio\.so\.1 => not found' || exit 0

# 32 位 time_t 架构存在 ABI 差异，不能链接到 libaio.so.1t64。
arch=$(uname -m)
case "${arch}" in
    x86_64|aarch64|ppc64le|s390x|riscv64|loongarch64) ;;
    *)
        echo "错误：当前架构 ${arch} 缺少 libaio.so.1，且不能安全使用 libaio.so.1t64。" >&2
        echo "请安装提供 libaio.so.1 的软件包，或改用源码方式安装数据库。" >&2
        exit 1
        ;;
esac

t64=$(ldconfig -p 2>/dev/null | awk '$1 == "libaio.so.1t64" {print $NF; exit}')
if [ -z "${t64}" ] || [ ! -e "${t64}" ]; then
    echo "错误：${server_bin} 需要 libaio.so.1，但系统里找不到可用的 libaio。" >&2
    echo "请先安装 libaio（Debian/Ubuntu：libaio1 或 libaio1t64；RHEL 系：libaio）。" >&2
    exit 1
fi

link_dir=$(dirname "${t64}")
link="${link_dir}/libaio.so.1"

# 不覆盖发行版提供的同名实体文件，避免替换系统库。
if [ -e "${link}" ] && [ ! -L "${link}" ]; then
    echo "错误：${link} 已存在且不是符号链接，${server_bin} 仍无法加载 libaio.so.1。" >&2
    echo "请手工确认该文件后重试。" >&2
    exit 1
fi
if ! ln -sf "$(basename "${t64}")" "${link}"; then
    echo "错误：创建 ${link} -> ${t64} 失败。" >&2
    exit 1
fi
ldconfig

if ldd "${server_bin}" 2>/dev/null | grep -q 'libaio\.so\.1 => not found'; then
    echo "错误：已建立 ${link}，${server_bin} 仍然找不到 libaio.so.1。" >&2
    exit 1
fi

echo "当前发行版只提供 libaio.so.1t64，已建立 ${link} -> $(basename "${t64}")。"
exit 0
