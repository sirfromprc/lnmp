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

Validate_Service_Ports || exit 1
Get_Dist_Name

clear 2>/dev/null || true
Print_Banner \
    "LNMP Pure-FTPd 安装工具" \
    "为现有 LNMP 环境安装 FTP 服务" \
    "用法：./pureftpd.sh"

Pureftpd_Conf='/usr/local/pureftpd/etc/pure-ftpd.conf'

# 从现有配置读出本工具管理的三个端口值，供重装迁移和卸载撤销防火墙规则使用。
# 输出三行：控制端口、被动端口范围起、被动端口范围止；读不到时输出空行。
Read_Pureftpd_Ports()
{
    local conf="$1" ctl='' pasv_min='' pasv_max=''

    if [ -s "${conf}" ]; then
        ctl=$(awk '/^Bind[[:space:]]/ { split($2, a, ","); print a[2]; exit }' "${conf}")
        pasv_min=$(awk '/^PassivePortRange[[:space:]]/ { print $2; exit }' "${conf}")
        pasv_max=$(awk '/^PassivePortRange[[:space:]]/ { print $3; exit }' "${conf}")
    fi
    printf '%s\n%s\n%s\n' "${ctl}" "${pasv_min}" "${pasv_max}"
}

# 监听端口核对：ss 不可用时跳过，不因缺工具判定安装失败。
Check_Pureftpd_Listen()
{
    local port="$1" i=0

    command -v ss >/dev/null 2>&1 || return 0
    while [ ${i} -lt 10 ]; do
        if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}\$"; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

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
    { read -r old_ctl; read -r old_pasv_min; read -r old_pasv_max; } < <(Read_Pureftpd_Ports "${Pureftpd_Conf}")

    Echo_Blue "安装依赖软件包..."
    if [ "$PM" = "yum" ]; then
        for packages in make gcc gcc-c++ gcc-g77 openssl openssl-devel bzip2;
        do yum -y install $packages; done
    elif [ "$PM" = "apt" ]; then
        Apt_Get update -y
        [[ $? -ne 0 ]] && Apt_Get update --allow-releaseinfo-change -y
        for packages in build-essential gcc g++ make openssl libssl-dev bzip2;
        do Apt_Get --no-install-recommends install -y $packages; done
    fi
    Echo_Blue "正在下载文件..."
    cd "${cur_dir}/src" || return 1
    Download_Files https://download.pureftpd.org/pub/pure-ftpd/releases/${Pureftpd_Ver}.tar.bz2 ${Pureftpd_Ver}.tar.bz2
    Require_File "${Pureftpd_Ver}.tar.bz2" "Pure-FTPd"
    if [ $? -eq 0 ]; then
        echo "${Pureftpd_Ver}.tar.bz2 下载成功。"
    else
        Download_Files https://download.pureftpd.org/pub/pure-ftpd/releases/${Pureftpd_Ver}.tar.bz2 ${Pureftpd_Ver}.tar.bz2
    fi

    Echo_Blue "正在安装 Pure-FTPd..."
    Tar_Cd ${Pureftpd_Ver}.tar.bz2 ${Pureftpd_Ver}
    ./configure --prefix=/usr/local/pureftpd CFLAGS=-O2 --with-puredb --with-quotas --with-cookie --with-virtualhosts --with-diraliases --with-sysquotas --with-ratios --with-altlog --with-paranoidmsg --with-shadow --with-welcomemsg --with-throttling --with-uploadscript --with-language=english --with-rfc2640 --with-ftpwho --with-tls

    Make_Install || exit 1

    Echo_Blue "正在复制配置文件..."
    mkdir /usr/local/pureftpd/etc
    \cp ${cur_dir}/conf/pure-ftpd.conf /usr/local/pureftpd/etc/pure-ftpd.conf
    # 控制端口与被动端口范围同时用于服务配置和防火墙规则。
    sed -i "s|^PassivePortRange .*|PassivePortRange             ${Pureftpd_Passive_Min} ${Pureftpd_Passive_Max}|" \
        /usr/local/pureftpd/etc/pure-ftpd.conf
    if grep -q '^Bind ' /usr/local/pureftpd/etc/pure-ftpd.conf; then
        sed -i "s|^Bind .*|Bind                         0.0.0.0,${Pureftpd_Port}|" \
            /usr/local/pureftpd/etc/pure-ftpd.conf
    else
        printf '\n# 监听地址与端口，由 lnmp.conf 的 Pureftpd_Port 决定\nBind                         0.0.0.0,%s\n' \
            "${Pureftpd_Port}" >> /usr/local/pureftpd/etc/pure-ftpd.conf
    fi
    # 写入后核对配置，避免模板格式变化导致监听端口与防火墙规则不一致。
    Check_Conf_Applied /usr/local/pureftpd/etc/pure-ftpd.conf \
        "^Bind[[:space:]]+0\.0\.0\.0,${Pureftpd_Port}\$" \
        "FTP 控制端口 ${Pureftpd_Port}" || exit 1
    Check_Conf_Applied /usr/local/pureftpd/etc/pure-ftpd.conf \
        "^PassivePortRange[[:space:]]+${Pureftpd_Passive_Min}[[:space:]]+${Pureftpd_Passive_Max}\$" \
        "FTP 被动端口范围 ${Pureftpd_Passive_Min}-${Pureftpd_Passive_Max}" || exit 1
    if [ -L /etc/init.d/pureftpd ]; then
        rm -f /etc/init.d/pureftpd
    fi
    \cp ${cur_dir}/init.d/init.d.pureftpd /etc/init.d/pureftpd
    Install_Systemd_Unit "${cur_dir}/init.d/pureftpd.service" /etc/systemd/system/pureftpd.service || exit 1
    chmod +x /etc/init.d/pureftpd
    touch /usr/local/pureftpd/etc/pureftpd.passwd
    touch /usr/local/pureftpd/etc/pureftpd.pdb

    # FTP 明文传输账号口令。FTPS 启动需要包含私钥和证书的 PEM 文件。
    #
    # 自签证书会触发客户端信任警告；生产环境应使用正式证书替换。
    if [ ! -s /usr/local/pureftpd/etc/pure-ftpd.pem ]; then
        Echo_Blue "正在为 FTPS 生成自签名证书..."
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -subj "/CN=$(hostname -f 2>/dev/null || hostname)" \
            -keyout /usr/local/pureftpd/etc/pure-ftpd.pem \
            -out /usr/local/pureftpd/etc/pure-ftpd.pem >/dev/null 2>&1
        chmod 600 /usr/local/pureftpd/etc/pure-ftpd.pem
    fi

    StartUp pureftpd

    cd ..
    Clean_Src_Dir "${Pureftpd_Ver}"

    Firewall_Allow tcp "${Pureftpd_Data_Port}"
    Firewall_Allow tcp "${Pureftpd_Port}"
    Firewall_Allow tcp "${Pureftpd_Passive_Min}-${Pureftpd_Passive_Max}"
    Firewall_Save

    if [ ! -s /bin/lnmp ]; then
        Install_LNMP_Command lnmp || exit 1
    else
        Install_Current_LNMP_Command lnmp || exit 1
    fi
    id -u www
    if [ $? -ne 0 ]; then
        groupadd www
        useradd -s /sbin/nologin -g www www
    fi

    if [[ -s /usr/local/pureftpd/sbin/pure-ftpd && -s /usr/local/pureftpd/etc/pure-ftpd.conf && -s /etc/init.d/pureftpd ]]; then
        Echo_Blue "正在启动 Pure-FTPd..."
        # 配置和二进制每次安装都重写，必须 restart：对已在运行的服务执行 start
        # 直接返回成功，进程不会重读配置，监听的仍是旧端口。
        StartOrStop restart pureftpd
        Pureftpd_Start_Rc=$?
        if [ "${Pureftpd_Start_Rc}" -eq 0 ]; then
            # 使用 systemd 活动状态或 pid 对应进程判断服务是否启动。
            if Use_Systemd_Unit pureftpd; then
                systemctl is-active --quiet pureftpd.service || Pureftpd_Start_Rc=1
            elif ! { [ -s /var/run/pure-ftpd.pid ] \
                     && kill -0 "$(cat /var/run/pure-ftpd.pid)" 2>/dev/null; }; then
                Pureftpd_Start_Rc=1
            fi
        fi
        # 服务起来了也要确认监听的是本次写入的控制端口。
        if [ "${Pureftpd_Start_Rc}" -eq 0 ] && ! Check_Pureftpd_Listen "${Pureftpd_Port}"; then
            Echo_Red "Pure-FTPd 已启动，但没有监听 ${Pureftpd_Port} 端口。"
            Pureftpd_Start_Rc=1
        fi
        # 端口变了才收回旧放行；顺序放在启动之后，失败时旧规则仍在。
        if [ "${Pureftpd_Start_Rc}" -eq 0 ]; then
            Revoke_Old_Pureftpd_Ports "${old_ctl}" "${old_pasv_min}" "${old_pasv_max}"
        fi
        if [ "${Pureftpd_Start_Rc}" -eq 0 ]; then
            Print_Banner \
                "Pure-FTPd 安装完成" \
                "使用 lnmp ftp {add|list|del|show} 管理 FTP 用户" \
                "安装包来自官方站点 download.pureftpd.org"
        else
            Echo_Red "Pure-FTPd 启动失败。"
            exit 1
        fi
    else
        Echo_Red "Pure-FTPd 安装失败。"
    fi
}

Uninstall_Pureftpd()
{
    if [ ! -f /usr/local/pureftpd/sbin/pure-ftpd ]; then
        Echo_Red "未检测到已安装的 Pure-FTPd。"
        exit 1
    fi
    local ctl='' pasv_min='' pasv_max=''

    # 端口从实际配置解析，卸载后必须收回安装时添加的三组放行，
    # 否则被动端口整段范围会一直对公网开放。
    { read -r ctl; read -r pasv_min; read -r pasv_max; } < <(Read_Pureftpd_Ports "${Pureftpd_Conf}")

    echo "正在停止 Pure-FTPd..."
    /etc/init.d/pureftpd stop
    echo "正在删除服务配置..."
    Remove_StartUp pureftpd
    echo "正在删除文件..."
    rm -f /etc/init.d/pureftpd
    rm -rf /usr/local/pureftpd

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
