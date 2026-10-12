#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ "$(id -u)" != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi
# 源码根目录按脚本自身位置确定：从其它目录以绝对路径启动时，
# pwd 指向调用者的当前目录，相对路径 source 会加载到那里的同名文件。
cur_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
if [ ! -s "${cur_dir}/lnmp.conf" ] || [ ! -d "${cur_dir}/include" ]; then
    echo "错误：${cur_dir} 不是 LNMP 源码目录，缺少 lnmp.conf 或 include/。"
    exit 1
fi
cd "${cur_dir}" || exit 1
action=$1
# 供 Press_Install 选择本入口的确认摘要。
Stack='pureftpd'

# 不带参数即安装；未识别的参数不能落入安装分支。
case "${action}" in
''|install|uninstall) ;;
*)
    echo "用法：./pureftpd.sh [install|uninstall]"
    echo "      不带参数等同于 install。"
    exit 1
    ;;
esac

. "${cur_dir}/lnmp.conf"
. "${cur_dir}/include/main.sh"
. "${cur_dir}/include/verify.sh"
. "${cur_dir}/include/firewall.sh"
. "${cur_dir}/include/init.sh"
. "${cur_dir}/include/end.sh"
. "${cur_dir}/include/mod/pureftpd.sh"

Validate_Service_Ports || exit 1
Get_Dist_Name

clear 2>/dev/null || true
Print_Banner \
    "LNMP Pure-FTPd 安装工具" \
    "为现有 LNMP 环境安装 FTP 服务" \
    "用法：./pureftpd.sh"

# 重装改端口后，旧端口的放行不再对应本服务，必须收回。
Revoke_Old_Pureftpd_Ports()
{
    local old_ctl="$1" old_min="$2" old_max="$3" changed='n'

    if [ -n "${old_ctl}" ] && [ "${old_ctl}" != "${Pureftpd_Port}" ]; then
        Firewall_Revoke tcp "${old_ctl}"
        changed='y'
    fi
    if [ -n "${old_min}" ] && [ -n "${old_max}" ] \
       && { [ "${old_min}" != "${Pureftpd_Passive_Min}" ] || [ "${old_max}" != "${Pureftpd_Passive_Max}" ]; }; then
        Firewall_Revoke tcp "${old_min}-${old_max}"
        changed='y'
    fi
    if [ "${changed}" = 'y' ]; then
        echo "已收回旧 FTP 端口的防火墙放行。"
        Firewall_Save
    fi
    return 0
}

Install_Pureftpd()
{
    local old_ctl='' old_pasv_min='' old_pasv_max=''

    Press_Install

    # 端口在重装时按 lnmp.conf 重写，旧值先记下来，装完把旧放行规则收回。
    { read -r old_ctl; read -r old_pasv_min; read -r old_pasv_max; } < <(Pureftpd_Ports)

    Pureftpd_Install "${Pureftpd_Ver#pure-ftpd-}" "${Pureftpd_Port}" \
        "${Pureftpd_Passive_Min}" "${Pureftpd_Passive_Max}" || return 1
    StartUp pureftpd

    Firewall_Allow tcp "${Pureftpd_Data_Port}"
    Firewall_Allow tcp "${Pureftpd_Port}"
    Firewall_Allow tcp "${Pureftpd_Passive_Min}-${Pureftpd_Passive_Max}"
    Firewall_Save

    if [ ! -s /bin/lnmp ]; then
        Install_LNMP_Command lnmp || return 1
    else
        Install_Current_LNMP_Command lnmp || return 1
    fi
    if ! id -u www >/dev/null 2>&1; then
        groupadd www
        useradd -s /sbin/nologin -g www www
    fi

    Echo_Blue "正在启动 Pure-FTPd..."
    # 配置和二进制每次安装都重写，必须 restart：对已在运行的服务执行 start
    # 直接返回成功，进程不会重读配置，监听的仍是旧端口。
    if ! StartOrStop restart pureftpd || ! Pureftpd_Verify "${Pureftpd_Port}"; then
        Echo_Red "Pure-FTPd 启动失败。"
        return 1
    fi
    # 端口变了才收回旧放行；顺序放在启动之后，失败时旧规则仍在。
    Revoke_Old_Pureftpd_Ports "${old_ctl}" "${old_pasv_min}" "${old_pasv_max}"
    Print_Banner \
        "Pure-FTPd 安装完成" \
        "使用 lnmp ftp {add|list|del|show} 管理 FTP 用户" \
        "安装包来自官方站点 download.pureftpd.org"
}

Uninstall_Pureftpd()
{
    local ctl='' pasv_min='' pasv_max=''

    if [ ! -f /usr/local/pureftpd/sbin/pure-ftpd ]; then
        Echo_Red "未检测到已安装的 Pure-FTPd。"
        return 1
    fi

    # 端口从实际配置解析，卸载后必须收回安装时添加的三组放行，
    # 否则被动端口整段范围会一直对公网开放。
    { read -r ctl; read -r pasv_min; read -r pasv_max; } < <(Pureftpd_Ports)

    echo "正在停止 Pure-FTPd 并删除文件..."
    Pureftpd_Remove || Echo_Red "删除 Pure-FTPd 文件时有步骤失败，请检查 /usr/local/pureftpd 与 /etc/init.d/pureftpd。"

    echo "正在收回 FTP 端口的防火墙放行..."
    Firewall_Revoke tcp "${Pureftpd_Data_Port}"
    Firewall_Revoke tcp "${ctl:-${Pureftpd_Port}}"
    if [ -n "${pasv_min}" ] && [ -n "${pasv_max}" ]; then
        Firewall_Revoke tcp "${pasv_min}-${pasv_max}"
    fi
    # 配置里的值与 lnmp.conf 不一致时，两套都收回，避免遗留。
    [ "${ctl}" != "${Pureftpd_Port}" ] && Firewall_Revoke tcp "${Pureftpd_Port}"
    if [ "${pasv_min}" != "${Pureftpd_Passive_Min}" ] || [ "${pasv_max}" != "${Pureftpd_Passive_Max}" ]; then
        Firewall_Revoke tcp "${Pureftpd_Passive_Min}-${Pureftpd_Passive_Max}"
    fi
    Firewall_Save || Echo_Red "防火墙规则保存失败，请执行 lnmp fw sync 复核。"

    echo "Pure-FTPd 卸载完成。"
}

Pureftpd_Rc=0
if [ "${action}" = "uninstall" ]; then
    Uninstall_Pureftpd
    Pureftpd_Rc=$?
else
    # 使用安装函数的管道状态，避免 tee 的成功状态掩盖安装失败。
    Install_Pureftpd 2>&1 | tee /root/pureftpd-install.log
    Pureftpd_Rc=${PIPESTATUS[0]}
fi
exit ${Pureftpd_Rc}
