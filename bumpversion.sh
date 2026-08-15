#!/usr/bin/env bash
# 开发用同步脚本：把当前源码树里 conf/lnmp(a)/lamp、tools/lnmp-*.sh 的改动
# 覆盖到已安装位置（/bin/lnmp 等），并修一遍 tools/*.sh 权限。
#
# 只复用 include/end.sh 里 Install_LNMP_Command 已有的安装逻辑，不重复实现
# 一遍复制/权限规则；线上安装、升级都不会走这个脚本。
#
# 用法：./bumpversion.sh [lnmp|lnmpa|lamp]
#   不带参数时，自动探测当前 /bin/lnmp 是哪个栈；探测不出来按 lnmp 处理。
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
for f in /bin/lnmp /bin/lnmp-backup /bin/lnmp-tgnotice /bin/lnmp-phpmyadmin; do
    if [ ! -x "${f}" ]; then
        Echo_Red "同步失败：${f} 缺失或不可执行。"
        Rc=1
    fi
done

if [ ${Rc} -eq 0 ]; then
    Echo_Green "同步完成：${Stack} -> /bin/lnmp，tools/*.sh 已设为 755。"
fi

exit ${Rc}
