#!/usr/bin/env bash
# 维护用同步脚本：将源码树中的管理命令覆盖到已安装位置，并设置执行权限。
# 该脚本仅同步 conf/lnmp、conf/lnmpa、conf/lamp 与 tools/lnmp-*.sh，
# 不执行组件安装或升级，不应替代 install.sh 或 upgrade.sh。
#
# 用法：./bumpversion.sh [lnmp|lnmpa|lamp]
#   不带参数时自动识别 /bin/lnmp 的栈类型，无法识别时使用 lnmp。
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

if [ "$(id -u)" != "0" ]; then
    echo "错误：需要 root 权限运行，因为要写入 /bin 下的文件。" >&2
    exit 1
fi

cur_dir=$(cd "$(dirname "$0")" && pwd)

if [ ! -d "${cur_dir}/conf" ] || [ ! -d "${cur_dir}/tools" ] || [ ! -f "${cur_dir}/include/end.sh" ]; then
    echo "错误：${cur_dir} 不是完整的 LNMP 源码目录（缺少 conf/、tools/ 或 include/end.sh）。" >&2
    exit 1
fi

if [ ! -s /bin/lnmp ]; then
    echo "错误：未检测到 /bin/lnmp，请先执行完整安装：${cur_dir}/install.sh" >&2
    exit 1
fi

Stack=$1
if [ -n "${Stack}" ]; then
    case "${Stack}" in
        lnmp|lnmpa|lamp) ;;
        *)
            echo "错误：未知安装栈 \"${Stack}\"，只支持 lnmp / lnmpa / lamp。" >&2
            exit 1
            ;;
    esac
else
    if grep -q '^lnmpa_start()' /bin/lnmp 2>/dev/null; then
        Stack=lnmpa
    elif grep -q '^lamp_start()' /bin/lnmp 2>/dev/null; then
        Stack=lamp
    else
        Stack=lnmp
    fi
fi

if [ ! -s "${cur_dir}/conf/${Stack}" ]; then
    echo "错误：${cur_dir}/conf/${Stack} 不存在。" >&2
    exit 1
fi

. "${cur_dir}/include/main.sh"
. "${cur_dir}/include/end.sh"

echo "同步 ${Stack} 管理命令与 tools/ 脚本权限（源码目录：${cur_dir}）..."
Install_LNMP_Command "${Stack}" || exit 1

Rc=0
for f in /bin/lnmp /bin/lnmp-backup /bin/lnmp-tgnotice /bin/lnmp-phpmyadmin /bin/lnmp-perm; do
    if [ ! -x "${f}" ]; then
        Echo_Red "同步失败：${f} 缺失或不可执行。"
        Rc=1
    fi
done

if [ ${Rc} -eq 0 ]; then
    Echo_Green "同步完成：${Stack} -> /bin/lnmp，tools/*.sh 已设为 755。"
fi

exit ${Rc}
