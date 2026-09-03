#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# 修改 PHP 系统配置并重启服务需要 root 权限。
if [ "$(id -u)" != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi

cur_dir=$(cd "$(dirname "$0")/.." && pwd)
# 校验源码目录，避免在其他位置执行时因公共函数未加载而继续修改配置。
if [ ! -f "${cur_dir}/include/main.sh" ]; then
    echo "错误：找不到 ${cur_dir}/include/main.sh。"
    echo "请在 LNMP 源码目录内执行本脚本，例如 ./tools/$(basename "$0")。"
    exit 1
fi
. "${cur_dir}/include/main.sh"

Php_Ini="/usr/local/php/etc/php.ini"

Print_Banner \
    "LNMP PHP 禁用函数调整工具" \
    "修改 PHP 的 disable_functions 配置" \
    "用法：./remove_disable_function.sh"

if [ ! -s "${Php_Ini}" ]; then
    Echo_Red "找不到 ${Php_Ini}。"
    exit 1
fi

# 取当前生效的禁用函数列表：同名配置以最后一条为准。
Read_Disable_Functions()
{
    sed -n 's/^disable_functions[[:space:]]*=[[:space:]]*//p' "${Php_Ini}" \
        | tail -n 1 | tr -d '[:space:]'
}

# 整行替换 disable_functions，避免按子串删除误伤同前缀的函数名。
Write_Disable_Functions()
{
    local value="$1" tmp

    tmp=$(mktemp "${Php_Ini}.XXXXXX") || return 1
    if ! awk -v v="${value}" '
        /^disable_functions[[:space:]]*=/ && !done { print "disable_functions = " v; done=1; next }
        { print }
    ' "${Php_Ini}" >"${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    chmod --reference="${Php_Ini}" "${tmp}" 2>/dev/null || chmod 644 "${tmp}"
    mv -f "${tmp}" "${Php_Ini}" || { rm -f "${tmp}"; return 1; }
    return 0
}

current=$(Read_Disable_Functions)
if [ -z "${current}" ]; then
    Echo_Green "当前 disable_functions 为空，没有可以放行的函数。"
    exit 0
fi

# 菜单项由当前配置生成，不写死函数名，避免列出配置里根本没有的项。
IFS=',' read -r -a func_list <<<"${current}"
echo "当前禁用的函数："
echo "  ${current}"
echo
echo "1: 清空全部禁用函数"
idx=1
for fn in "${func_list[@]}"; do
    [ -n "${fn}" ] || continue
    idx=$((idx + 1))
    echo "${idx}: 仅放行 ${fn}"
done

choice=''
while :;do
    Echo_Yellow "请选择 [1-${idx}]（默认 1）: "
    if ! read -r choice; then
        echo
        Echo_Red "读取选项时遇到 EOF，未做任何修改。"
        exit 1
    fi
    [ -z "${choice}" ] && choice=1
    case "${choice}" in
    *[!0-9]*)
        Echo_Red "只接受 1 到 ${idx} 之间的编号。"
        continue
        ;;
    esac
    if [ "${choice}" -lt 1 ] || [ "${choice}" -gt "${idx}" ]; then
        Echo_Red "只接受 1 到 ${idx} 之间的编号。"
        continue
    fi
    break
done

target=''
if [ "${choice}" = "1" ]; then
    new_value=''
    echo "将清空全部禁用函数。"
else
    target="${func_list[$((choice - 2))]}"
    new_value=$(printf '%s' "${current}" | awk -v t="${target}" -F, '
        {
            out=""
            for (i=1; i<=NF; i++) {
                if ($i == t || $i == "") continue
                out = (out == "" ? $i : out "," $i)
            }
            print out
        }')
    echo "将放行 ${target}，其余保持禁用。"
fi

Echo_Yellow "确认继续? (y/N，默认 n) "
if ! read -r answer || { [ "${answer}" != "y" ] && [ "${answer}" != "Y" ]; }; then
    echo "已取消，未做任何修改。"
    exit 1
fi

backup=$(mktemp /tmp/lnmp-php-ini.XXXXXXXX) || exit 1
if ! \cp -p "${Php_Ini}" "${backup}"; then
    Echo_Red "备份 ${Php_Ini} 失败，未做任何修改。"
    rm -f "${backup}"
    exit 1
fi

if ! Write_Disable_Functions "${new_value}"; then
    Echo_Red "写入 ${Php_Ini} 失败，未做任何修改。"
    rm -f "${backup}"
    exit 1
fi

# 修改必须真正落到配置里，否则重启服务只是白跑一趟。
after=$(Read_Disable_Functions)
if [ "${after}" != "${new_value}" ]; then
    Echo_Red "修改未生效：期望 '${new_value}'，实际 '${after}'，已恢复原配置。"
    \cp -p "${backup}" "${Php_Ini}"
    rm -f "${backup}"
    exit 1
fi

rc=0
# 统一走 StartOrStop：装了 systemd unit 时必须用 systemctl 重启，直接调 SysV
# 脚本会让 unit 变成 inactive 而进程还在跑，systemd 之后再启动就会撞上
# “Another FPM instance seems to already listen”。
if [ -x /etc/init.d/httpd ] && [ -d /usr/local/apache ]; then
    echo "正在重启 Apache..."
    StartOrStop restart httpd || rc=1
else
    echo "正在重启 PHP-FPM..."
    StartOrStop restart php-fpm || rc=1
fi

if [ ${rc} -ne 0 ]; then
    Echo_Red "服务重启失败，已恢复原配置，请检查服务状态后重试。"
    \cp -p "${backup}" "${Php_Ini}"
    rm -f "${backup}"
    exit 1
fi

rm -f "${backup}"
echo "当前 disable_functions："
echo "  ${after:-（空）}"
Print_Banner "PHP 禁用函数配置调整完成"
exit 0
