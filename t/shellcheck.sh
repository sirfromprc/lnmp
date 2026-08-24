#!/usr/bin/env bash
#
# t/shellcheck.sh - shellcheck 静态检查
#
# 用法：bash t/shellcheck.sh
#   SHELLCHECK=/path/to/shellcheck 可指定二进制位置。
#
# 未安装 shellcheck 时跳过并返回 0，避免 t/lint.sh 在没装的机器上整体不可用。

cd "$(dirname "$0")/.." || exit 1

SC="${SHELLCHECK:-shellcheck}"
if ! command -v "${SC}" >/dev/null 2>&1; then
    echo "跳过：未找到 shellcheck，安装后重跑（Debian/Ubuntu: apt-get install shellcheck）。"
    exit 0
fi

# 排除的规则及原因：
#   SC2154/SC2034 include/*.sh 是被 install.sh source 的片段，变量在 lnmp.conf
#                 与主流程里赋值，跨文件引用一律被判为未赋值或未使用。
#   SC1090/SC1091 source 目标由运行时变量决定，静态跟不进去。
#   SC2317        函数库被 source，定义之后没有直接调用，全部误判为不可达。
#   SC1111        中文全角引号出现在合法的双引号字符串内，本包输出全为中文。
#   SC2120        带可选参数的函数被判为"引用了参数但没人传"。
Exclude='SC2154,SC2034,SC1090,SC1091,SC2317,SC1111,SC2120'

# 检查范围与 t/lint.sh 的 T1 一致：src/ 是安装时解压的第三方源码，不属于本项目。
mapfile -t files < <(find . -name '*.sh' -not -path './src/*' | sort)
for f in conf/lnmp conf/lnmpa conf/lamp; do
    [ -f "${f}" ] && files+=("${f}")
done

echo "=== shellcheck（${#files[@]} 个文件，severity >= warning）==="
out=$("${SC}" -f gcc -s bash -S warning -e "${Exclude}" "${files[@]}" 2>&1)
if [ -z "${out}" ]; then
    echo "全部通过"
    exit 0
fi
echo "${out}"
echo
echo "共 $(printf '%s\n' "${out}" | wc -l) 条"
exit 1
