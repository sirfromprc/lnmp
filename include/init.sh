#!/usr/bin/env bash

Set_Timezone()
{
    Echo_Blue "正在设置时区..."
    rm -rf /etc/localtime
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
}

CentOS_InstallNTP()
{
    if [ "${CheckMirror}" != "n" ]; then
        if command -v ntpdate >/dev/null 2>&1; then
            Run_Ntpdate
        elif command -v chronyd >/dev/null 2>&1; then
            chronyd -d -q "server pool.ntp.org iburst"
        else
            yum info ntpdate && check_ntp="y"
            if [ "${check_ntp}" = "y" ]; then
                Echo_Blue "[+] 正在安装 ntp..."
                yum install -y ntpdate
                Run_Ntpdate
            else
                Echo_Blue "[+] 正在安装 chrony..."
                yum install chrony -y
                chronyd -d -q "server pool.ntp.org iburst"
            fi
        fi
    fi
    date
    start_time=$(date +%s)
}

# 执行一次时间校准。ntpdate 校准失败不阻断安装，但提示与实际结果一致。
Run_Ntpdate()
{
    if ntpdate -u pool.ntp.org; then
        Echo_Green "系统时间已校准。"
    else
        Echo_Yellow "时间校准失败，请自行确认系统时间。"
    fi
}

# Debian 12 起 ntpdate 无候选包，同名命令改由 ntpsec-ntpdate 提供。
# 已有 ntpdate 或 systemd-timesyncd 时不再安装，无可用工具时明确提示跳过。
Deb_SyncTime()
{
    local pkg

    if command -v ntpdate >/dev/null 2>&1; then
        Run_Ntpdate
        return 0
    fi
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        Echo_Green "systemd-timesyncd 正在运行，跳过时间校准。"
        return 0
    fi
    for pkg in ntpsec-ntpdate ntpdate; do
        # 先模拟安装，避免在无候选包的发行版上执行必然失败的安装。
        apt-get install -s -y "${pkg}" >/dev/null 2>&1 || continue
        Echo_Blue "[+] 正在安装 ${pkg}..."
        apt-get install -y "${pkg}" || continue
        command -v ntpdate >/dev/null 2>&1 || continue
        Run_Ntpdate
        return 0
    done
    Echo_Yellow "未找到可用的时间同步工具，跳过时间校准，请自行确认系统时间。"
    return 0
}

Deb_InstallNTP()
{
    if [ "${CheckMirror}" != "n" ]; then
        apt-get update -y
        [[ $? -ne 0 ]] && apt-get update --allow-releaseinfo-change -y
        Deb_SyncTime
    fi
    date
    start_time=$(date +%s)
}

CentOS_RemoveAMP()
{
    Echo_Blue "[-] 正在使用 Yum 删除旧软件包..."
    rpm -qa|grep httpd
    rpm -e httpd httpd-tools --nodeps
    if [ "${DB_Kind}" != "none" ]; then
        yum -y remove mysql-server mysql mysql-libs mariadb-server mariadb mariadb-libs
        rpm -qa|grep mysql
        if [ $? -ne 0 ]; then
            rpm -e mysql mysql-libs --nodeps
            rpm -e mariadb mariadb-libs --nodeps
        fi
    fi
    rpm -qa|grep php
    rpm -e php-mysql php-cli php-gd php-common php --nodeps

    Remove_Error_Libcurl

    yum -y remove httpd*
    yum -y remove php*
    yum clean all
}

# 仅清理实际已安装的旧包，避免无关的“包未安装”信息掩盖卸载错误。
Deb_Purge_Installed()
{
    local p installed=''

    for p in "$@"; do
        if dpkg-query -W -f='${Status}' "${p}" 2>/dev/null | grep -q 'ok installed'; then
            installed="${installed} ${p}"
        fi
    done

    if [ -z "${installed}" ]; then
        echo "无需卸载：${*} 均未安装。"
        return 0
    fi
    echo "卸载已安装的旧包：${installed}"
    apt-get purge -y ${installed}
}

Deb_RemoveAMP()
{
    Echo_Blue "[-] 正在使用 apt-get 删除旧软件包..."
    apt-get update -y
    [[ $? -ne 0 ]] && apt-get update --allow-releaseinfo-change -y

    # 清理受支持发行版中仍可能存在的旧组件包。
    pkill -x apache2 >/dev/null 2>&1
    Deb_Purge_Installed apache2 apache2-bin apache2-data apache2-utils apache2-doc \
                        libapache2-mod-php

    if [ "${DB_Kind}" != "none" ]; then
        Deb_Purge_Installed mysql-server mysql-client mysql-common \
                            mariadb-server mariadb-client mariadb-common libmariadbd-dev
        # 保留发行版数据库配置目录，由后续安装流程改名备份，避免被源码版误用。
        [ -d /etc/mysql ] && echo "注意：/etc/mysql 仍存在，安装数据库时会自动改名备份。"
    fi

    apt-get autoremove -y && apt-get clean
}

# 默认保留 SELinux 状态，并为安装目录设置必要的安全上下文。
# 仅当 Disable_Selinux='y' 时关闭 SELinux。
# 源码安装路径可能缺少发行版预置策略；相关拒绝记录位于 /var/log/audit/audit.log。
Setup_Selinux()
{
    [ -s /etc/selinux/config ] || return 0

    if [ "${Disable_Selinux}" = "y" ]; then
        Echo_Yellow "Disable_Selinux='y'：按配置关闭 SELinux。"
        setenforce 0 2>/dev/null
        sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
        return 0
    fi

    command -v getenforce >/dev/null 2>&1 || return 0
    [ "$(getenforce 2>/dev/null)" = "Disabled" ] && return 0

    echo "保留 SELinux（Disable_Selinux='n'），标注本包目录的上下文..."
    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t httpd_sys_rw_content_t "${Default_Website_Dir}(/.*)?" 2>/dev/null
        semanage fcontext -a -t httpd_log_t '/home/wwwlogs(/.*)?' 2>/dev/null
    fi
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R "${Default_Website_Dir}" /home/wwwlogs 2>/dev/null
    fi
    if command -v setsebool >/dev/null 2>&1; then
        # Web 服务需要访问数据库及建立发送邮件所需的网络连接。
        setsebool -P httpd_can_network_connect_db 1 2>/dev/null
        setsebool -P httpd_can_network_connect 1 2>/dev/null
    fi
    Echo_Yellow "若安装/启动出现权限问题，请查 /var/log/audit/audit.log 确认是否 SELinux 拒绝，"
    Echo_Yellow "必要时在 lnmp.conf 设 Disable_Selinux='y' 后重试。"
}

# 保留 install.sh 和 only.sh 使用的函数入口。
Disable_Selinux()
{
    Setup_Selinux
}

Xen_Hwcap_Setting()
{
    if [ -s /etc/ld.so.conf.d/libc6-xen.conf ]; then
        sed -i 's/hwcap 1 nosegneg/hwcap 0 nosegneg/g' /etc/ld.so.conf.d/libc6-xen.conf
    fi
}

Check_Hosts()
{
    if grep -Eqi '^127.0.0.1[[:space:]]*localhost' /etc/hosts; then
        echo "Hosts 配置正常。"
    else
        echo "127.0.0.1 localhost.localdomain localhost" >> /etc/hosts
    fi
    if [ "${CheckMirror}" != "n" ]; then
        # 仅检测实际下载域名；探测失败时保留系统 DNS 配置。
        if ping -c1 -W3 www.php.net >/dev/null 2>&1; then
            echo "DNS 解析正常。"
        else
            echo "DNS 解析失败。"
            Echo_Red "无法解析 www.php.net。"
            Echo_Red "请检查 /etc/resolv.conf 和网络连通性后再继续。"
            Echo_Red "本脚本不会自动覆盖 /etc/resolv.conf。"
        fi
    fi
}

# CentOS 官方签名公钥指纹；EL8/9/10 配置仓库前核对随附公钥。
#
# 值来自 https://www.centos.org/keys/ 公布的 CentOS Official Signing Key
# （rsa4096，2019-05-03 创建，security@centos.org）。
CentOS_GPG_Key_FP='99DB70FAE1D7CE227FB6488205B555B38483C65D'

# 安装并核验 LNMP 随附的 CentOS 官方公钥。
# 公钥与软件包必须来自独立的信任路径，避免仓库内容和验证密钥同时被替换。
Install_CentOS_GPG_Key()
{
    local src="${cur_dir}/conf/RPM-GPG-KEY-CentOS-Official"
    local dst='/etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-Official'
    local fp

    if [ ! -s "${src}" ]; then
        Echo_Red "致命错误：缺少 ${src}，无法配置带签名校验的软件源。"
        exit 1
    fi

    # 最小化安装可能没有 gpg，此时明确提示无法执行指纹核对。
    if command -v gpg >/dev/null 2>&1; then
        fp=$(gpg --show-keys --with-colons "${src}" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')
        if [ "${fp}" != "${CentOS_GPG_Key_FP}" ]; then
            Echo_Red "致命错误：conf/RPM-GPG-KEY-CentOS-Official 指纹不符，拒绝导入。"
            Echo_Red "  期望值：${CentOS_GPG_Key_FP}"
            Echo_Red "  实际值：${fp:-<无法解析>}"
            exit 1
        fi
        echo "CentOS GPG 公钥指纹校验通过：${fp}"
    else
        Echo_Yellow "未找到 gpg 命令，跳过公钥指纹核对（公钥仍取自本包，不联网获取）。"
    fi

    mkdir -p /etc/pki/rpm-gpg
    \cp "${src}" "${dst}"
    chmod 644 "${dst}"
    rpm --import "${dst}"
}

RHEL_Modify_Source()
{
    Get_RHEL_Version
    if [ "${RHELRepo}" = "local" ]; then
        echo "保留当前 RHEL 软件源配置，不做修改。"
        sed -i "s/^enabled[ ]*=[ ]*1/enabled=0/" /etc/yum/pluginconf.d/subscription-manager.conf 2>/dev/null
        return 0
    fi

    # 使用随附仓库配置、官方 HTTPS 源、签名校验和固定公钥。
    # 未提供模板的发行版版本不自动生成仓库配置。
    Install_CentOS_GPG_Key

    case "${RHEL_Version}" in
    8*)
        echo "RHEL/CentOS 8 已 EOL，使用官方归档源 vault.centos.org。"
        \cp ${cur_dir}/conf/CentOS8-vault.repo /etc/yum.repos.d/CentOS8-vault.repo
        ;;
    9*)
        [ -s /etc/yum.repos.d/Centos-9.repo ] && rm -f /etc/yum.repos.d/Centos-9.repo
        \cp ${cur_dir}/conf/rhel-9.repo /etc/yum.repos.d/Centos-9.repo
        ;;
    10*)
        [ -s /etc/yum.repos.d/Centos-10.repo ] && rm -f /etc/yum.repos.d/Centos-10.repo
        \cp ${cur_dir}/conf/rhel-10.repo /etc/yum.repos.d/Centos-10.repo
        ;;
    *)
        Echo_Red "不支持在 RHEL ${RHEL_Version} 上自动配置软件源。"
        Echo_Red "本包只保留 EL8 / EL9 / EL10 的官方源配置（见 conf/*.repo）。"
        Echo_Red "如果这台机器已有可用的软件源，请设 RHELRepo='local' 后重试。"
        exit 1
        ;;
    esac

    yum clean all
    yum makecache
    sed -i "s/^enabled[ ]*=[ ]*1/enabled=0/" /etc/yum/pluginconf.d/subscription-manager.conf 2>/dev/null
}

Ubuntu_Modify_Source()
{

    OldReleasesURL='https://old-releases.ubuntu.com/ubuntu/'
    CodeName=''
    if grep -Eqi "10.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^10.10'; then
        CodeName='maverick'
    elif grep -Eqi "11.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^11.04'; then
        CodeName='natty'
    elif  grep -Eqi "11.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^11.10'; then
        CodeName='oneiric'
    elif grep -Eqi "12.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^12.10'; then
        CodeName='quantal'
    elif grep -Eqi "13.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^13.04'; then
        CodeName='raring'
    elif grep -Eqi "13.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^13.10'; then
        CodeName='saucy'
    elif grep -Eqi "10.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^10.04'; then
        CodeName='lucid'
    elif grep -Eqi "14.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^14.10'; then
        CodeName='utopic'
    elif grep -Eqi "15.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^15.04'; then
        CodeName='vivid'
    elif grep -Eqi "12.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^12.04'; then
        CodeName='precise'
    elif grep -Eqi "15.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^15.10'; then
        CodeName='wily'
    elif grep -Eqi "16.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^16.10'; then
        CodeName='yakkety'
    elif grep -Eqi "14.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^14.04'; then
        Ubuntu_Deadline trusty
    elif grep -Eqi "17.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^17.04'; then
        CodeName='zesty'
    elif grep -Eqi "17.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^17.10'; then
        CodeName='artful'
    elif grep -Eqi "16.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^16.04'; then
        Ubuntu_Deadline xenial
    elif grep -Eqi "16.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^16.10'; then
        CodeName='yakkety'
    elif grep -Eqi "18.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^18.04'; then
        Ubuntu_Deadline bionic
    elif grep -Eqi "18.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^18.10'; then
        CodeName='cosmic'
    elif grep -Eqi "19.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^19.04'; then
        CodeName='disco'
    elif grep -Eqi "19.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^19.10'; then
        CodeName='eoan'
    elif grep -Eqi "20.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^20.10'; then
        CodeName='groovy'
    elif grep -Eqi "21.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^21.04'; then
        CodeName='hirsute'
    elif grep -Eqi "21.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^21.10'; then
        CodeName='impish'
    elif grep -Eqi "22.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^22.10'; then
        CodeName='kinetic'
    elif grep -Eqi "23.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^23.04'; then
        CodeName='lunar'
    elif grep -Eqi "23.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^23.10'; then
        Ubuntu_Deadline mantic
    elif grep -Eqi "24.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^24.10'; then
        Ubuntu_Deadline oracular
    elif grep -Eqi "25.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^25.04'; then
        Ubuntu_Deadline plucky
    fi
    if [ "${CodeName}" != "" ]; then
        \cp /etc/apt/sources.list /etc/apt/sources.list.$(date +"%Y%m%d")
        cat > /etc/apt/sources.list<<EOF
deb ${OldReleasesURL} ${CodeName} main restricted universe multiverse
deb ${OldReleasesURL} ${CodeName}-security main restricted universe multiverse
deb ${OldReleasesURL} ${CodeName}-updates main restricted universe multiverse
deb ${OldReleasesURL} ${CodeName}-proposed main restricted universe multiverse
deb ${OldReleasesURL} ${CodeName}-backports main restricted universe multiverse
deb-src ${OldReleasesURL} ${CodeName} main restricted universe multiverse
deb-src ${OldReleasesURL} ${CodeName}-security main restricted universe multiverse
deb-src ${OldReleasesURL} ${CodeName}-updates main restricted universe multiverse
deb-src ${OldReleasesURL} ${CodeName}-proposed main restricted universe multiverse
deb-src ${OldReleasesURL} ${CodeName}-backports main restricted universe multiverse
EOF
    fi
}

Check_Old_Releases_URL()
{
    OR_Status=`wget --spider --server-response ${OldReleasesURL}/dists/$1/Release 2>&1 | awk '/^  HTTP/{print $2}'`
    if [ "${OR_Status}" = "200" ]; then
        echo "Ubuntu old-releases 状态：${OR_Status}";
        CodeName="$1"
    fi
}

Ubuntu_Deadline()
{
    trusty_deadline=`date -d "2024-4-30 00:00:00" +%s`
    xenial_deadline=`date -d "2026-4-30 00:00:00" +%s`
    bionic_deadline=`date -d "2028-7-30 00:00:00" +%s`
    mantic_deadline=`date -d "2024-7-30 00:00:00" +%s`
    oracular_deadline=`date -d "2025-7-10 00:00:00" +%s`
    plucky_deadline=`date -d "2026-1-15 00:00:00" +%s`
    cur_time=`date  +%s`
    case "$1" in
        trusty)
            if [ ${cur_time} -gt ${trusty_deadline} ]; then
                echo "${cur_time} > ${trusty_deadline}"
                Check_Old_Releases_URL trusty
            fi
            ;;
        xenial)
            if [ ${cur_time} -gt ${xenial_deadline} ]; then
                echo "${cur_time} > ${xenial_deadline}"
                Check_Old_Releases_URL xenial
            fi
            ;;
        bionic)
            if [ ${cur_time} -gt ${bionic_deadline} ]; then
                echo "${cur_time} > ${bionic_deadline}"
                Check_Old_Releases_URL bionic
            fi
            ;;
        mantic)
            if [ ${cur_time} -gt ${mantic_deadline} ]; then
                echo "${cur_time} > ${mantic_deadline}"
                Check_Old_Releases_URL mantic
            fi
            ;;
        oracular)
            if [ ${cur_time} -gt ${oracular_deadline} ]; then
                echo "${cur_time} > ${oracular_deadline}"
                Check_Old_Releases_URL oracular
            fi
            ;;
        plucky)
            if [ ${cur_time} -gt ${plucky_deadline} ]; then
                echo "${cur_time} > ${plucky_deadline}"
                Check_Old_Releases_URL plucky
            fi
            ;;
    esac
}

CentOS8_Modify_Source()
{
    if echo "${CentOS_Version}" | grep -Eqi "^8" && [ "${isCentosStream}" != "y" ]; then
        Echo_Yellow "CentOS 8 已停止维护，改用官方归档软件源。"
        if [ ! -s /etc/yum.repos.d/CentOS8-vault.repo ]; then
            Install_CentOS_GPG_Key
            mkdir -p /etc/yum.repos.d/backup
            mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null
            \cp ${cur_dir}/conf/CentOS8-vault.repo /etc/yum.repos.d/CentOS8-vault.repo
        fi
    fi
}

Modify_Source()
{
    if [ "${DISTRO}" = "RHEL" ]; then
        if subscription-manager status; then
            Echo_Blue "系统存在有效的 RHEL 订阅，跳过第三方软件源配置。"
            Get_RHEL_Version
            if echo "${RHEL_Version}" | grep -Eqi "^(8|9|10)"; then
                subscription-manager repos --enable codeready-builder-for-rhel-${RHEL_Ver}-${DB_ARCH}-rpms
            fi
        else
            RHEL_Modify_Source
        fi
    elif [ "${DISTRO}" = "Ubuntu" ]; then
        Ubuntu_Modify_Source
    elif [ "${DISTRO}" = "CentOS" ]; then
        CentOS8_Modify_Source
    fi
}

# 只读检查宿主机软件源配置。
# 编译依赖由宿主机软件源提供，不受 src/checksums.sha256 覆盖。
# 检查只输出警告，不修改配置或阻断安装，以兼容内网镜像和离线源。
# 关闭签名校验或 TLS 记为问题；启用签名校验的 HTTP 源仅作提示。
Check_Host_Repo_Trust()
{
    local problems=0 notes=0 f line _repo_tmp _sec _key _ln _raw

    Echo_Blue "[+] 检查宿主机软件源的信任配置（只读，不会修改任何东西）..."

    # 通过临时文件读取结果，确保计数器在当前 shell 中更新。
    _repo_tmp=$(mktemp) || return 0
    trap 'rm -f "${_repo_tmp}"' RETURN 2>/dev/null

    if [ "${PM}" = "apt" ]; then
        # 输出包含文件、行号和原文，并排除配置中的注释行。

        # trusted=yes、allow-insecure 和 Trusted: yes 会关闭签名校验。
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
                 /etc/apt/sources.list.d/*.sources; do
            [ -f "${f}" ] && [ -s "${f}" ] || continue
            grep -nEi '^[[:space:]]*(deb|deb-src|URIs:|Trusted:)' "${f}" 2>/dev/null |
            grep -Ei 'trusted[[:space:]]*=[[:space:]]*yes|allow-insecure[[:space:]]*=[[:space:]]*yes|Trusted:[[:space:]]*yes' > "${_repo_tmp}"
            while IFS= read -r line; do
                [ -n "${line}" ] || continue
                [ ${problems} -eq 0 ] && Echo_Red "!! 关闭了签名校验的 APT 源（能改中间路径的人就能往里塞包）："
                Echo_Red "   ${f}:${line}"
                problems=$((problems+1))
            done < "${_repo_tmp}"
        done

        # apt.conf 全局允许未签名包时，所有相关软件源都会失去签名保护。
        for f in /etc/apt/apt.conf /etc/apt/apt.conf.d/*; do
            [ -f "${f}" ] && [ -s "${f}" ] || continue
            grep -nEi 'AllowUnauthenticated[^;]*"?true|AllowInsecureRepositories[^;]*"?true' "${f}" 2>/dev/null > "${_repo_tmp}"
            while IFS= read -r line; do
                [ -n "${line}" ] || continue
                Echo_Red "!! APT 全局允许未签名包："
                Echo_Red "   ${f}:${line}"
                problems=$((problems+1))
            done < "${_repo_tmp}"
        done

        # 启用签名校验的 HTTP 源仅作提示，不计入问题数。
        # 包签名仍可验证完整性，但传输内容不具备保密性。
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
                 /etc/apt/sources.list.d/*.sources; do
            [ -f "${f}" ] && [ -s "${f}" ] || continue
            grep -nEi '^[[:space:]]*(deb|deb-src)[[:space:]].*http://|^[[:space:]]*URIs:.*http://' "${f}" 2>/dev/null > "${_repo_tmp}"
            while IFS= read -r line; do
                [ -n "${line}" ] || continue
                if [ ${notes} -eq 0 ]; then
                    Echo_Yellow "   提示：以下 APT 源走明文 http://"
                    Echo_Yellow "   （APT 的 Release 有 GPG 签名，这不等于能被塞包，"
                    Echo_Yellow "     但会泄露你在装什么，也更晚才发现被动手脚）："
                fi
                Echo_Yellow "     ${f}:${line}"
                notes=$((notes+1))
            done < "${_repo_tmp}"
        done

        # 提示用户第三方软件源也会参与编译依赖安装。
        for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [ -f "${f}" ] && [ -s "${f}" ] || continue
            Echo_Yellow "   提示：第三方源 ${f} 也会用于安装编译依赖"
        done

    elif [ "${PM}" = "yum" ]; then
        # 检查已启用仓库的 gpgcheck 和 sslverify。
        # 按 section 解析，避免未启用的备用仓库产生误报。
        for f in /etc/yum.repos.d/*.repo; do
            [ -s "${f}" ] || continue
            for line in $(awk -F= '
                function flush(){
                    if(sec!="" && en==1){
                        if(gc=="0") print sec"|gpgcheck|"gcn"|"gcl
                        if(sv=="0") print sec"|sslverify|"svn"|"svl
                    }
                }
                /^[[:space:]]*[#;]/ {next}
                /^[[:space:]]*\[/ {flush(); sec=$0; gsub(/[][[:space:]]/,"",sec)
                                   en=1; gc=""; sv=""; gcn=""; svn=""; gcl=""; svl=""; next}
                {k=$1; v=$2; gsub(/[[:space:]]/,"",k); gsub(/[[:space:]]/,"",v)
                 if(k=="enabled")   en=(v=="0"?0:1)
                 if(k=="gpgcheck")  {gc=v; gcn=NR; gcl=$0; gsub(/ /,"\002",gcl)}
                 if(k=="sslverify") {sv=v; svn=NR; svl=$0; gsub(/ /,"\002",svl)}}
                END{flush()}
            ' "${f}"); do
                # 字段依次为仓库段、配置键、行号和原文；用 \002 保留原文空格。
                _sec=$(echo "${line}" | cut -d'|' -f1)
                _key=$(echo "${line}" | cut -d'|' -f2)
                _ln=$(echo  "${line}" | cut -d'|' -f3)
                _raw=$(echo "${line}" | cut -d'|' -f4 | tr '\002' ' ')
                case "${_key}" in
                gpgcheck)
                    Echo_Red "!! [${_sec}] 已启用但关闭了包签名校验："
                    Echo_Red "   ${f}:${_ln}:${_raw}"
                    problems=$((problems+1)) ;;
                sslverify)
                    Echo_Red "!! [${_sec}] 已启用但关闭了 TLS 证书校验："
                    Echo_Red "   ${f}:${_ln}:${_raw}"
                    problems=$((problems+1)) ;;
                esac
            done
        done

        # 全局关闭 gpgcheck 会影响所有继承该配置的软件源。
        for f in /etc/yum.conf /etc/dnf/dnf.conf; do
            [ -f "${f}" ] && [ -s "${f}" ] || continue
            grep -nE '^[[:space:]]*gpgcheck[[:space:]]*=[[:space:]]*0' "${f}" 2>/dev/null > "${_repo_tmp}"
            while IFS= read -r line; do
                [ -n "${line}" ] || continue
                Echo_Red "!! 全局关闭了 GPG 校验："
                Echo_Red "   ${f}:${line}"
                problems=$((problems+1))
            done < "${_repo_tmp}"
        done

        # 明文 HTTP 源仅作提示；gpgcheck=1 时仍会验证软件包签名。
        for f in /etc/yum.repos.d/*.repo; do
            [ -f "${f}" ] && [ -s "${f}" ] || continue
            grep -nEi '^[[:space:]]*(baseurl|mirrorlist|metalink)[[:space:]]*=[[:space:]]*http://' "${f}" 2>/dev/null > "${_repo_tmp}"
            while IFS= read -r line; do
                [ -n "${line}" ] || continue
                if [ ${notes} -eq 0 ]; then
                    Echo_Yellow "   提示：以下 yum/dnf 源走明文 http://"
                    Echo_Yellow "   （gpgcheck=1 时包签名仍有效，这不等于能被塞包）："
                fi
                Echo_Yellow "     ${f}:${line}"
                notes=$((notes+1))
            done < "${_repo_tmp}"
        done
    fi

    if [ ${problems} -gt 0 ]; then
        echo
        Echo_Red "########################################################################"
        Echo_Red "!! 上面 ${problems} 处配置意味着：本机安装编译依赖时**不验证包的来源**。"
        Echo_Red "!! 本包对自己下载的组件做了强制 SHA256/PGP 校验，但编译依赖走的是"
        Echo_Red "!! 宿主机的源 —— 那一段的可信度完全取决于上面这些配置。"
        Echo_Red "!!"
        Echo_Red "!! 如果这些是你自己的内网镜像/私有源，属正常配置，可以忽略本提示。"
        Echo_Red "!! 如果不是你配的，请先查清楚再继续安装。"
        Echo_Red "########################################################################"
        Echo_Yellow "（这是提示，不是阻断。10 秒后继续。）"
        sleep 10
    else
        Echo_Green "   未发现关闭签名或 TLS 校验的软件源配置。"
    fi
    # 显式清理临时文件，兼容不支持 RETURN trap 的 shell。
    rm -f "${_repo_tmp}"
    return 0
}

Check_PowerTools()
{
    if ! yum -v repolist all|grep "PowerTools"; then
        Echo_Red "未找到 PowerTools 软件源。"
    fi
    repo_id=$(yum repolist all|grep -Ei "PowerTools"|head -n 1|awk '{print $1}')
}

Check_Codeready()
{
    repo_id=$(yum repolist all|grep -E "CodeReady"|head -n 1|awk '{print $1}')
    [ -z "${repo_id}" ] && repo_id="ol8_codeready_builder"
}

CentOS_Dependent()
{
    if [ -s /etc/yum.conf ]; then
        \cp /etc/yum.conf /etc/yum.conf.lnmp
        sed -i 's:exclude=.*:exclude=:g' /etc/yum.conf
    fi

    Echo_Blue "[+] 正在使用 Yum 安装依赖软件包..."
    for packages in make cmake gcc gcc-c++ gcc-g77 kernel-headers glibc-headers flex bison file libtool libtool-libs autoconf patch wget crontabs libjpeg libjpeg-devel libjpeg-turbo-devel libpng libpng-devel libpng10 libpng10-devel gd gd-devel libxml2 libxml2-devel zlib zlib-devel glib2 glib2-devel unzip tar bzip2 bzip2-devel libzip-devel libevent libevent-devel ncurses ncurses-devel curl curl-devel libcurl libcurl-devel e2fsprogs e2fsprogs-devel krb5 krb5-devel libidn libidn-devel openssl openssl-devel pcre-devel gettext gettext-devel ncurses-devel gmp-devel pspell-devel unzip libcap diffutils ca-certificates net-tools libc-client-devel psmisc libXpm-devel git-core c-ares-devel libicu-devel libxslt libxslt-devel xz expat-devel libaio-devel rpcgen libtirpc-devel perl cyrus-sasl-devel sqlite-devel oniguruma-devel lsof re2c pkg-config libarchive hostname ncurses-libs numactl-devel libxcrypt libwebp-devel gnutls-devel brotli-devel initscripts iproute libxcrypt-compat nftables gnupg2 coreutils;
    do yum -y install $packages; done

    yum -y update nss

    if echo "${CentOS_Version}" | grep -Eqi "^8" || echo "${RHEL_Version}" | grep -Eqi "^8" || echo "${Rocky_Version}" | grep -Eqi "^8" || echo "${Alma_Version}" | grep -Eqi "^8" || echo "${Anolis_Version}" | grep -Eqi "^8" || echo "${OpenCloudOS_Version}" | grep -Eqi "^8"; then
        Check_PowerTools
        if [ "${repo_id}" != "" ]; then
            echo "正在安装 PowerTools 软件源中的依赖包..."
            for c8packages in rpcgen re2c oniguruma-devel;
            do dnf --enablerepo=${repo_id} install ${c8packages} -y; done
        fi
        dnf install libarchive -y

        dnf install gcc-toolset-10 -y
    fi

    if echo "${CentOS_Version}" | grep -Eqi "^(9|10)"; then
        crb_source_check=$(yum repolist all | grep -E '^crb' | awk '{print $1}')

        if [[ ! -n "$crb_source_check" ]]; then
            # 使用官方 mirror.stream.centos.org 和本地固定公钥。
            echo "正在添加 CRB 官方软件源（mirror.stream.centos.org）..."
            Install_CentOS_GPG_Key
            local crb_stream
            crb_stream=$(echo "${CentOS_Version}" | cut -d. -f1)
            cat > /etc/yum.repos.d/centos-crb.repo << EOF
[crb]
name=CentOS Stream ${crb_stream} - CRB
baseurl=https://mirror.stream.centos.org/${crb_stream}-stream/CRB/\$basearch/os/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-Official
gpgcheck=1
enabled=1
EOF
        fi
    fi
    if echo "${CentOS_Version}" | grep -Eqi "^(9|10)" || echo "${RHEL_Version}" | grep -Eqi "^10" || echo "${Alma_Version}" | grep -Eqi "^(9|10)" || echo "${Rocky_Version}" | grep -Eqi "^(9|10)"; then
        for cs9packages in oniguruma-devel libzip-devel libtirpc-devel libxcrypt-compat;
        do dnf --enablerepo=crb install ${cs9packages} -y; done
        DB_Toolchain_EL9
    fi

    if [ "${DISTRO}" = "Oracle" ] && echo "${Oracle_Version}" | grep -Eqi "^8"; then
        Check_Codeready
        for o8packages in rpcgen re2c oniguruma-devel;
        do dnf --enablerepo=${repo_id} install ${o8packages} -y; done
        dnf install libarchive -y
    fi

    if [ "${DISTRO}" = "Oracle" ] && echo "${Oracle_Version}" | grep -Eqi "^9"; then
        Check_Codeready
        dnf --enablerepo=${repo_id} install libtirpc-devel -y
        DB_Toolchain_EL9
    fi

    if echo "${CentOS_Version}" | grep -Eqi "^7" || echo "${RHEL_Version}" | grep -Eqi "^7"  || echo "${Aliyun_Version}" | grep -Eqi "^2" || echo "${Alibaba_Version}" | grep -Eqi "^2" || echo "${Oracle_Version}" | grep -Eqi "^7" || echo "${Anolis_Version}" | grep -Eqi "^7"; then
        if [ "${DISTRO}" = "Oracle" ]; then
            yum -y install oracle-epel-release
            yum -y --enablerepo=*EPEL* install oniguruma-devel
        else
            yum -y install epel-release
            # EPEL 统一使用官方 metalink。
        fi
        yum -y install oniguruma oniguruma-devel
    fi

    if [ "${DISTRO}" = "Fedora" ] || echo "${CentOS_Version}" | grep -Eqi "^(9|10)" || echo "${RHEL_Version}" | grep -Eqi "^10" || echo "${Alma_Version}" | grep -Eqi "^(9|10)" || echo "${Rocky_Version}" | grep -Eqi "^(9|10)" || echo "${Amazon_Version}" | grep -Eqi "^202[3-9]" || echo "${OpenCloudOS_Version}" | grep -Eqi "^(9|10)"; then
        dnf install chkconfig -y
    fi

    if [ "${DISTRO}" = "UOS" ]; then
        Check_PowerTools
        if [ "${repo_id}" != "" ]; then
            echo "正在安装 PowerTools 软件源中的依赖包..."
            for uospackages in rpcgen re2c oniguruma-devel;
            do dnf --enablerepo=${repo_id} install ${uospackages} -y; done
        fi
    fi

    if [ -s /etc/yum.conf.lnmp ]; then
        mv -f /etc/yum.conf.lnmp /etc/yum.conf
    fi
}

# MySQL 8.4 通用二进制客户端依赖 libncurses.so.5 和 libtinfo.so.5；数据库
# 安全初始化及 lnmp database 命令均需要该客户端。优先安装兼容运行库，
# Debian 13 无对应软件包时按 MySQL 兼容要求链接系统提供的 .so.6。
Deb_Ncurses5_Compat()
{
    local so path

    apt-get --no-install-recommends install -y libncurses5 libtinfo5 2>/dev/null

    for so in libtinfo libncurses; do
        ldconfig -p 2>/dev/null | grep -q "${so}\.so\.5" && continue
        path=$(ldconfig -p 2>/dev/null | awk -v s="${so}.so.6" '$1 == s {print $NF; exit}')
        if [ -n "${path}" ] && [ -e "${path}" ]; then
            ln -sf "${path}" "${path%.6}.5"
            echo "已建立兼容软链：${path%.6}.5 -> ${path}"
        fi
    done
    ldconfig
}

# 软件源中存在可安装候选时返回 0。逐包判断可以避开发行版之间的包名差异，
# 不必为每个版本维护一份依赖清单。
Deb_Pkg_Available()
{
    local cand

    cand=$(apt-cache policy "$1" 2>/dev/null | awk -F': ' '/Candidate:/{print $2; exit}')
    [ -n "${cand}" ] && [ "${cand}" != "(none)" ]
}

# 新发行版移除旧包后的等价替代，无替代时输出空。
Deb_Pkg_Alternative()
{
    case "$1" in
    libpcre3-dev)                 printf 'libpcre2-dev' ;;
    libncurses5-dev|libtinfo-dev) printf 'libncurses-dev' ;;
    gnutls-dev)                   printf 'libgnutls28-dev' ;;
    *)                            printf '' ;;
    esac
}

Deb_Dependent()
{
    local pkg alt failed="" skipped=""

    Echo_Blue "[+] 正在使用 apt-get 安装依赖软件包..."
    apt-get update -y
    [[ $? -ne 0 ]] && apt-get update --allow-releaseinfo-change -y
    apt-get autoremove -y
    apt-get -fy install
    export DEBIAN_FRONTEND=noninteractive
    apt-get --no-install-recommends install -y build-essential gcc g++ make

    for pkg in debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf automake re2c wget cron bzip2 libzip-dev libc6-dev bison file flex m4 gawk less cpp binutils diffutils unzip tar libbz2-dev libncurses-dev libncurses5-dev libtool libevent-dev openssl libssl-dev libsasl2-dev libltdl-dev zlib1g-dev libglib2.0-dev libjpeg-dev libpng-dev libkrb5-dev curl libcurl4-gnutls-dev libcurl4-openssl-dev libpcre2-dev libpcre3-dev libpq-dev gettext libxml2-dev libcap-dev ca-certificates psmisc patch git libc-ares-dev libicu-dev e2fsprogs libxslt1-dev xz-utils libexpat1-dev libaio-dev libtirpc-dev libsqlite3-dev libonig-dev lsof pkg-config libtinfo-dev libnuma-dev libwebp-dev gnutls-dev libbrotli-dev iproute2 gzip nftables gnupg gpgv coreutils; do
        if ! Deb_Pkg_Available "${pkg}"; then
            alt=$(Deb_Pkg_Alternative "${pkg}")
            if [ -n "${alt}" ] && Deb_Pkg_Available "${alt}"; then
                pkg="${alt}"
            else
                skipped="${skipped} ${pkg}"
                continue
            fi
        fi
        apt-get --no-install-recommends install -y "${pkg}" || failed="${failed} ${pkg}"
    done

    if [ -n "${skipped}" ]; then
        Echo_Yellow "软件源无下列包，已跳过：${skipped# }"
        echo
    fi
    if [ -n "${failed}" ]; then
        Echo_Red "下列依赖包安装失败：${failed# }"
        return 1
    fi

    Deb_Ncurses5_Compat

    # PHP imap 扩展依赖已从 Debian 13 移除的 uw-imap libc-client；单独安装
    # 该依赖，以便缺失时明确提示扩展无法编译。
    if [ "${Enable_PHP_Imap}" = 'y' ]; then
        apt-get --no-install-recommends install -y libc-client-dev libc-client2007e-dev 2>/dev/null
        if ! ls /usr/include/c-client >/dev/null 2>&1 && ! ls /usr/include/imap >/dev/null 2>&1; then
            Echo_Yellow "未能安装 libc-client（uw-imap）开发包 —— Debian 13 已移除该库。"
            Echo_Yellow "PHP imap 扩展将无法编译。若不需要它，请设 Enable_PHP_Imap='n'。"
        fi
    fi
    return 0
}

Check_Download()
{
    Echo_Blue "[+] 正在下载文件..."
    cd ${cur_dir}/src

    # 组件下载统一使用上游官方源。
    Download_Files https://ftp.gnu.org/gnu/libiconv/${Libiconv_Ver}.tar.gz ${Libiconv_Ver}.tar.gz
    Require_File "${Libiconv_Ver}.tar.gz" "libiconv"

    if [ "${SelectMalloc}" = "2" ]; then
        Download_Files https://github.com/jemalloc/jemalloc/releases/download/${Jemalloc_Ver#jemalloc-}/${Jemalloc_Ver}.tar.bz2 ${Jemalloc_Ver}.tar.bz2
        Require_File "${Jemalloc_Ver}.tar.bz2" "jemalloc"
    elif [ "${SelectMalloc}" = "3" ]; then
        Download_Files https://github.com/gperftools/gperftools/releases/download/${TCMalloc_Ver}/${TCMalloc_Ver}.tar.gz ${TCMalloc_Ver}.tar.gz
        Require_File "${TCMalloc_Ver}.tar.gz" "gperftools"
        Download_Files https://github.com/libunwind/libunwind/releases/download/v${Libunwind_Ver#libunwind-}/${Libunwind_Ver}.tar.gz ${Libunwind_Ver}.tar.gz
        Require_File "${Libunwind_Ver}.tar.gz" "libunwind"
    fi

    if [ "${Stack}" != "lamp" ]; then
        Download_Files https://nginx.org/download/${Nginx_Ver}.tar.gz ${Nginx_Ver}.tar.gz
        Require_File "${Nginx_Ver}.tar.gz" "nginx"
    fi

    DB_Download_Files

    Download_Files https://www.php.net/distributions/${Php_Ver}.tar.bz2 ${Php_Ver}.tar.bz2
    Require_File "${Php_Ver}.tar.bz2" "PHP ${PHP_Branch}"

    if [ "${Enable_PhpMyAdmin}" = "y" ]; then

        local pma_ver="${PhpMyAdmin_Ver#phpMyAdmin-}"
        pma_ver="${pma_ver%-all-languages}"
        Download_Files https://files.phpmyadmin.net/phpMyAdmin/${pma_ver}/${PhpMyAdmin_Ver}.tar.xz ${PhpMyAdmin_Ver}.tar.xz
        Require_File "${PhpMyAdmin_Ver}.tar.xz" "phpMyAdmin"
    fi
    # PHP 探针缺少可验证的上游来源，因此不随安装包分发。

    if [ "${Stack}" != "lnmp" ]; then
        Download_Files https://archive.apache.org/dist/httpd/${Apache_Ver}.tar.bz2 ${Apache_Ver}.tar.bz2
        Require_File "${Apache_Ver}.tar.bz2" "Apache httpd"
        Download_Files https://archive.apache.org/dist/apr/${APR_Ver}.tar.bz2 ${APR_Ver}.tar.bz2
        Require_File "${APR_Ver}.tar.bz2" "APR"
        Download_Files https://archive.apache.org/dist/apr/${APR_Util_Ver}.tar.bz2 ${APR_Util_Ver}.tar.bz2
        Require_File "${APR_Util_Ver}.tar.bz2" "APR-util"
    fi
}

# 编译默认使用并行任务，失败后串行重试一次；任一步失败均返回非零。
# configure 或 cmake 成功后必须生成 Makefile，否则终止编译。
Check_Makefile_Ready()
{
    if [ ! -s Makefile ] && [ ! -s makefile ] && [ ! -s GNUmakefile ]; then
        Echo_Red "错误：$(pwd) 下没有 Makefile，configure 或 cmake 应该已经失败。"
        Echo_Red "请往上翻日志找 configure 的报错（通常是缺某个 -devel 依赖）。"
        return 1
    fi
    return 0
}

# 并行任务数同时受 CPU 核数和可用内存约束。按每个任务约 1GB 内存估算，
# 可降低 MySQL 等大型 C++ 项目编译时触发 OOM 的概率。
Build_Jobs()
{
    local cpus mem_mb jobs
    cpus=$(nproc 2>/dev/null)
    [ -n "${cpus}" ] || cpus=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    case "${cpus}" in ''|*[!0-9]*) cpus=2 ;; esac
    [ "${cpus}" -lt 1 ] && cpus=1

    mem_mb=$(awk '/MemTotal/ {printf "%d", $2 / 1024; exit}' /proc/meminfo 2>/dev/null)
    case "${mem_mb}" in ''|*[!0-9]*) mem_mb=1024 ;; esac

    jobs=$((mem_mb / 1024))
    [ "${jobs}" -lt 1 ] && jobs=1
    [ "${jobs}" -gt "${cpus}" ] && jobs="${cpus}"
    printf '%s' "${jobs}"
}

Make_Install()
{
    Check_Makefile_Ready || return 1
    make -j"$(Build_Jobs)"
    if [ $? -ne 0 ]; then
        Echo_Yellow "并行编译失败，退回串行重试..."
        if ! make; then
            Echo_Red "错误：在 $(pwd) 执行 make 失败。"
            return 1
        fi
    fi
    if ! make install; then
        Echo_Red "错误：在 $(pwd) 执行 make install 失败。"
        return 1
    fi
    return 0
}

PHP_Make_Install()
{
    Check_Makefile_Ready || return 1
    make ZEND_EXTRA_LIBS='-liconv' -j"$(Build_Jobs)"
    if [ $? -ne 0 ]; then
        Echo_Yellow "并行编译失败，退回串行重试..."
        if ! make ZEND_EXTRA_LIBS='-liconv'; then
            Echo_Red "错误：在 $(pwd) 执行 make 失败。"
            return 1
        fi
    fi
    if ! make install; then
        Echo_Red "错误：在 $(pwd) 执行 make install 失败。"
        return 1
    fi
    return 0
}


# libiconv 的动态库装在 /usr/local/lib。链接器缓存未刷新时，PHP configure 的
# iconv errno 探针找不到 libiconv.so.2，以 127 失败并中止 configure。
Ensure_Libiconv_Ldpath()
{
    [ -e /usr/local/lib/libiconv.so.2 ] || return 0
    ldconfig 2>/dev/null
    ldconfig -p 2>/dev/null | grep -q 'libiconv\.so\.2' && return 0
    if [ -d /etc/ld.so.conf.d ] &&
       ! grep -rqx '/usr/local/lib' /etc/ld.so.conf /etc/ld.so.conf.d/ 2>/dev/null; then
        echo '/usr/local/lib' > /etc/ld.so.conf.d/lnmp-usr-local.conf
        ldconfig 2>/dev/null
    fi
    ldconfig -p 2>/dev/null | grep -q 'libiconv\.so\.2' && return 0
    Echo_Red "libiconv 动态库未进入链接器缓存，PHP 的 iconv 探针会失败。"
    Echo_Red "请检查 /usr/local/lib 是否在动态链接器搜索路径中。"
    return 1
}

Install_Libiconv()
{
    Echo_Blue "[+] 正在安装 ${Libiconv_Ver}"
    Tar_Cd ${Libiconv_Ver}.tar.gz ${Libiconv_Ver}
    ./configure --enable-static
    Make_Install || exit 1
    Ensure_Libiconv_Ldpath || exit 1
    cd ${cur_dir}/src/
    rm -rf ${cur_dir}/src/${Libiconv_Ver}
}

# PHP 8 使用内置的 mhash 兼容 API，不依赖外部 libmhash 或 mcrypt。

Install_Freetype()
{
    if echo "${Ubuntu_Version}" | grep -Eqi "^1[89]\.|2[0-9]\." || echo "${Mint_Version}" | grep -Eqi "^19|2[0-9]" || echo "${Deepin_Version}" | grep -Eqi "^15\.[7-9]|15.1[0-9]|1[6-9]|2[0-9]" || echo "${Debian_Version}" | grep -Eqi "^9|1[0-9]" || echo "${Raspbian_Version}" | grep -Eqi "^9|1[0-9]" || echo "${Kali_Version}" | grep -Eqi "^202[0-9]" || echo "${UOS_Version}" | grep -Eqi "^2[0-9]" || echo "${CentOS_Version}" | grep -Eqi "^(8|9|10)" || echo "${RHEL_Version}" | grep -Eqi "^(8|9|10)" || echo "${Oracle_Version}" | grep -Eqi "^(8|9|10)" || echo "${Fedora_Version}" | grep -Eqi "^3[0-9]|29" || echo "${Rocky_Version}" | grep -Eqi "^(8|9|10)" || echo "${Alma_Version}" | grep -Eqi "^(8|9|10)" || echo "${openEuler_Version}" | grep -Eqi "^2[0-9]" || echo "${Anolis_Version}" | grep -Eqi "^(8|9|10)" || echo "${Kylin_Version}" | grep -Eqi "^V1[0-9]" || echo "${Amazon_Version}" | grep -Eqi "^202[3-9]" || echo "${OpenCloudOS_Version}" | grep -Eqi "^(8|9|10|23)" || echo "${HCE_Version}" | grep -Eqi "^2\.[0-9]"; then
        Download_Files https://downloads.sourceforge.net/freetype/${Freetype_New_Ver}.tar.xz ${Freetype_New_Ver}.tar.xz
        Require_File "${Freetype_New_Ver}.tar.xz" "freetype"
        Echo_Blue "[+] 正在安装 ${Freetype_New_Ver}"
        Tar_Cd ${Freetype_New_Ver}.tar.xz ${Freetype_New_Ver}
        ./configure --prefix=/usr/local/freetype --enable-freetype-config
    else
        # 发行版低于支持下限时明确终止，避免进入缺少校验文件的兼容路径。
        Echo_Red "当前发行版不在支持范围内，无法安装 freetype。"
        Echo_Red "支持范围见 Check_Supported_Distro（EL8+ / Debian 10+ / Ubuntu 18.04+ 等）。"
        exit 1
    fi
    Make_Install || exit 1

    [[ -d /usr/lib/pkgconfig ]] && \cp /usr/local/freetype/lib/pkgconfig/freetype2.pc /usr/lib/pkgconfig/
    cat > /etc/ld.so.conf.d/freetype.conf<<EOF
/usr/local/freetype/lib
EOF
    ldconfig
    ln -sfn /usr/local/freetype/include/freetype2/* /usr/include/
    cd ${cur_dir}/src/
    rm -rf ${cur_dir}/src/${Freetype_New_Ver}
}

Install_Curl()
{
    if [[ ! -s /usr/local/curl/bin/curl || ! -s /usr/local/curl/lib/libcurl.so || ! -s /usr/local/curl/include/curl/curl.h ]]; then
        Echo_Blue "[+] 正在安装 ${Curl_Ver}"
        cd ${cur_dir}/src
        Download_Files https://curl.se/download/${Curl_Ver}.tar.bz2 ${Curl_Ver}.tar.bz2
        Require_File "${Curl_Ver}.tar.bz2" "curl"
        Tar_Cd ${Curl_Ver}.tar.bz2 ${Curl_Ver}
        if [ -s /usr/local/openssl/bin/openssl ] || /usr/local/openssl/bin/openssl version | grep -Eqi 'OpenSSL 1.0.2'; then
            ./configure --prefix=/usr/local/curl --enable-ares --without-nss --with-zlib --with-ssl=/usr/local/openssl
        else
            ./configure --prefix=/usr/local/curl --enable-ares --without-nss --with-zlib --with-ssl
        fi
        Make_Install || exit 1
        cd ${cur_dir}/src/
        rm -rf ${cur_dir}/src/${Curl_Ver}
        ldconfig
    fi
    Remove_Error_Libcurl
}

Install_Pcre()
{
    if ! command -v pcre-config >/dev/null 2>&1 || pcre-config --version | grep -vEqi '^8.'; then
        Echo_Blue "[+] 正在安装 ${Pcre_Ver}"
        cd ${cur_dir}/src
        Download_Files https://downloads.sourceforge.net/pcre/${Pcre_Ver}.tar.bz2 ${Pcre_Ver}.tar.bz2
        Require_File "${Pcre_Ver}.tar.bz2" "PCRE"
        Tar_Cd ${Pcre_Ver}.tar.bz2
        Nginx_With_Pcre="--with-pcre=${cur_dir}/src/${Pcre_Ver} --with-pcre-jit"
    fi
}

Install_Jemalloc()
{
    Echo_Blue "[+] 正在安装 ${Jemalloc_Ver}"
    cd ${cur_dir}/src
    Tar_Cd ${Jemalloc_Ver}.tar.bz2 ${Jemalloc_Ver}
    ./configure
    Make_Install || exit 1
    ldconfig
    cd ${cur_dir}/src/
    rm -rf ${cur_dir}/src/${Jemalloc_Ver}
    ln -sf /usr/local/lib/libjemalloc* /usr/lib/
}

Install_TCMalloc()
{
    Echo_Blue "[+] 正在安装 ${TCMalloc_Ver}"
    if [ "${Is_64bit}" = "y" ]; then
        Tar_Cd ${Libunwind_Ver}.tar.gz ${Libunwind_Ver}
        CFLAGS=-fPIC ./configure
        make CFLAGS=-fPIC
        make CFLAGS=-fPIC install
        rm -rf ${cur_dir}/src/${Libunwind_Ver}
    fi
    Tar_Cd ${TCMalloc_Ver}.tar.gz ${TCMalloc_Ver}
    if [ "${Is_64bit}" = "y" ]; then
        ./configure
    else
        ./configure --enable-frame-pointers
    fi
    Make_Install || exit 1
    ldconfig
    cd ${cur_dir}/src/
    rm -rf ${cur_dir}/src/${TCMalloc_Ver}
    ln -sf /usr/local/lib/libtcmalloc* /usr/lib/
}

# Boost 处理
# 安装路径使用 DB_Boost_Mode；升级路径根据 mysql_version 推导。
# Boost 必须通过统一下载校验，不允许 cmake 自行联网下载。

# Boost_Mode：返回 auto 或 none。
Boost_Mode()
{
    if [ -n "${DB_Boost_Mode}" ]; then
        echo "${DB_Boost_Mode}"
    elif echo "${mysql_version}" | grep -Eqi '^8\.'; then
        echo "auto"
    else
        echo "none"
    fi
}

Download_Boost()
{
    local mode boost_dot
    mode=$(Boost_Mode)
    Echo_Blue "[+] 正在下载或使用已有的 Boost..."

    case "${mode}" in
    auto)
        # MySQL 8.x 所需的 Boost 版本由源码树指定，解析结果必须符合版本格式。
        Get_Boost_Ver=$(grep 'SET(BOOST_PACKAGE_NAME' cmake/boost.cmake | grep -oE '[0-9]+(_[0-9]+){2}' | head -n1)
        if ! echo "${Get_Boost_Ver}" | grep -Eq '^[0-9]+_[0-9]+_[0-9]+$'; then
            Echo_Red "错误：无法确定 ${DB_Ver:-mysql-${mysql_version}} 所需的 Boost 版本。"
            Echo_Red "预期能在 cmake/boost.cmake 中找到 SET(BOOST_PACKAGE_NAME ...)。"
            exit 1
        fi
        cd ${cur_dir}/src/
        boost_dot=$(echo "${Get_Boost_Ver}" | tr '_' '.')
        # 不同 MySQL 点版本可能要求不同的 Boost。通过上游 JSON 中的 SHA256
        # 校验动态解析的版本，并同时验证本地缓存，避免使用未核验的源码包。
        Download_Verified boost "${boost_dot}" \
            "https://archives.boost.io/release/${boost_dot}/source/boost_${Get_Boost_Ver}.tar.bz2" \
            "boost_${Get_Boost_Ver}.tar.bz2"
        Require_File "boost_${Get_Boost_Ver}.tar.bz2" "Boost ${boost_dot}"
        [ -d "${cur_dir}/src/boost_${Get_Boost_Ver}" ] && rm -rf "${cur_dir}/src/boost_${Get_Boost_Ver}"
        tar jxf ${cur_dir}/src/boost_${Get_Boost_Ver}.tar.bz2 -C ${cur_dir}/src
        MySQL_WITH_BOOST="-DWITH_BOOST=${cur_dir}/src/boost_${Get_Boost_Ver}"
        ;;
    esac
}

Install_Boost()
{
    local srcdir
    [ "$(Boost_Mode)" = "none" ] && return 0

    # mysql-boost 源码包已包含 Boost 时直接使用包内目录。
    if [ -n "${Mysql_Ver}" ]; then
        srcdir="${cur_dir}/src/${Mysql_Ver}/boost"
    else
        srcdir="${cur_dir}/src/mysql-${mysql_version}/boost"
    fi
    if [ -d "${srcdir}" ]; then
        Echo_Blue "[+] 使用源码包内置的 Boost..."
        MySQL_WITH_BOOST="-DWITH_BOOST=${srcdir}"
        return 0
    fi

    Download_Boost

    if [ -z "${MySQL_WITH_BOOST}" ]; then
        Echo_Red "错误：源码编译 MySQL 需要 Boost，但 Boost 未准备完成。"
        exit 1
    fi
}

Install_Openssl_New()
{
    if openssl version | grep -Eqi "OpenSSL 3."; then
        apache_with_ssl='--with-ssl'
    else
        if [ ! -s /usr/local/openssl3/bin/openssl ] || /usr/local/openssl3/bin/openssl version | grep -v 'OpenSSL 3'; then
            Echo_Blue "[+] 正在安装 ${Openssl_New_Ver}"
            cd ${cur_dir}/src
            Download_Files https://github.com/openssl/openssl/releases/download/${Openssl_New_Ver}/${Openssl_New_Ver}.tar.gz ${Openssl_New_Ver}.tar.gz
            [ $? -ne 0 ] && Download_Files https://www.openssl.org/source/${Openssl_New_Ver}.tar.gz ${Openssl_New_Ver}.tar.gz
            Require_File "${Openssl_New_Ver}.tar.gz" "OpenSSL 3"
            if [ $? -ne 0 ]; then
                Download_Files https://www.openssl.org/source/${Openssl_New_Ver}.tar.gz ${Openssl_New_Ver}.tar.gz
                if [ $? -ne 0 ]; then
                    Echo_Red "错误：无法下载 ${Openssl_New_Ver}。"
                    exit 1
                fi
            fi
            [[ -d "${Openssl_New_Ver}" ]] && rm -rf ${Openssl_New_Ver}
            Tar_Cd ${Openssl_New_Ver}.tar.gz ${Openssl_New_Ver}
            ./config -fPIC --prefix=/usr/local/openssl3 --openssldir=/usr/local/openssl3
            make depend
            Make_Install || exit 1
            cd ${cur_dir}/src/
            rm -rf ${cur_dir}/src/${Openssl_New_Ver}
        fi
        ldconfig
        apache_with_ssl='--with-ssl=/usr/local/openssl3'
    fi
}

Install_Nghttp2()
{
    if [[ ! -s /usr/local/nghttp2/lib/libnghttp2.so || ! -s /usr/local/nghttp2/include/nghttp2/nghttp2.h ]]; then
        Echo_Blue "[+] 正在安装 ${Nghttp2_Ver}"
        cd ${cur_dir}/src
        Download_Files https://github.com/nghttp2/nghttp2/releases/download/v${Nghttp2_Ver#nghttp2-}/${Nghttp2_Ver}.tar.xz ${Nghttp2_Ver}.tar.xz
        Require_File "${Nghttp2_Ver}.tar.xz" "nghttp2"
        [[ -d "${Nghttp2_Ver}" ]] && rm -rf ${Nghttp2_Ver}
        Tar_Cd ${Nghttp2_Ver}.tar.xz ${Nghttp2_Ver}
        ./configure --prefix=/usr/local/nghttp2
        Make_Install || exit 1
        cd ${cur_dir}/src/
        rm -rf ${cur_dir}/src/${Nghttp2_Ver}
    fi
}

Install_Libzip()
{
    if echo "${CentOS_Version}" | grep -Eqi "^7"  || echo "${RHEL_Version}" | grep -Eqi "^7"  || echo "${Aliyun_Version}" | grep -Eqi "^2" || echo "${Alibaba_Version}" | grep -Eqi "^2" || echo "${Oracle_Version}" | grep -Eqi "^7" || echo "${Anolis_Version}" | grep -Eqi "^7"; then
        if [ ! -s /usr/local/lib/libzip.so ]; then
            Echo_Blue "[+] 正在安装 ${Libzip_Ver}"
            cd ${cur_dir}/src
            Download_Files https://libzip.org/download/${Libzip_Ver}.tar.xz ${Libzip_Ver}.tar.xz
            Require_File "${Libzip_Ver}.tar.xz" "libzip"
            Tar_Cd ${Libzip_Ver}.tar.xz ${Libzip_Ver}
            ./configure
            Make_Install || exit 1
            cd ${cur_dir}/src/
            rm -rf ${cur_dir}/src/${Libzip_Ver}
        fi
        export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH
        ldconfig
    fi
}

CentOS_Lib_Opt()
{
    if [ "${Is_64bit}" = "y" ] ; then
        ln -sf /usr/lib64/libpng.* /usr/lib/
        ln -sf /usr/lib64/libjpeg.* /usr/lib/
    fi

    ulimit -v unlimited

    if [ `grep -L "/lib"    '/etc/ld.so.conf'` ]; then
        echo "/lib" >> /etc/ld.so.conf
    fi

    if [ `grep -L '/usr/lib'    '/etc/ld.so.conf'` ]; then
        echo "/usr/lib" >> /etc/ld.so.conf
        #echo "/usr/lib/openssl/engines" >> /etc/ld.so.conf
    fi

    if [ -d "/usr/lib64" ] && [ `grep -L '/usr/lib64'    '/etc/ld.so.conf'` ]; then
        echo "/usr/lib64" >> /etc/ld.so.conf
        #echo "/usr/lib64/openssl/engines" >> /etc/ld.so.conf
    fi

    if [ `grep -L '/usr/local/lib'    '/etc/ld.so.conf'` ]; then
        echo "/usr/local/lib" >> /etc/ld.so.conf
    fi

    ldconfig

    if command -v systemd-detect-virt >/dev/null 2>&1 && [[ "$(systemd-detect-virt)" = "lxc" ]]; then
        cat >>/etc/security/limits.conf<<eof
* soft nofile 65535
* hard nofile 65535
eof
    else
        cat >>/etc/security/limits.conf<<eof
* soft nproc 65535
* hard nproc 65535
* soft nofile 65535
* hard nofile 65535
eof
    fi

    echo "fs.file-max=65535" >> /etc/sysctl.conf

    if echo "${Fedora_Version}" | grep -Eqi "3[0-9]" && [ ! -d "/etc/init.d" ]; then
        ln -sfn /etc/rc.d/init.d /etc/init.d
    fi

    if [ -s /usr/lib64/libtinfo.so.6 ]; then
        ln -sf /usr/lib64/libtinfo.so.6 /usr/lib64/libtinfo.so.5
    elif [ -s /usr/lib/libtinfo.so.6 ]; then
        ln -sf /usr/lib/libtinfo.so.6 /usr/lib/libtinfo.so.5
    fi

    if [ -s /usr/lib64/libncurses.so.6 ]; then
        ln -sf /usr/lib64/libncurses.so.6 /usr/lib64/libncurses.so.5
    elif [ -s /usr/lib/libncurses.so.6 ]; then
        ln -sf /usr/lib/libncurses.so.6 /usr/lib/libncurses.so.5
    fi
}

Deb_Lib_Opt()
{
    if [ "${Is_64bit}" = "y" ]; then
        ln -sf /usr/lib/x86_64-linux-gnu/libpng* /usr/lib/
        ln -sf /usr/lib/x86_64-linux-gnu/libjpeg* /usr/lib/
    else
        ln -sf /usr/lib/i386-linux-gnu/libpng* /usr/lib/
        ln -sf /usr/lib/i386-linux-gnu/libjpeg* /usr/lib/
        ln -sfn /usr/include/i386-linux-gnu/asm /usr/include/asm
    fi

    if [ -d "/usr/lib/arm-linux-gnueabihf" ]; then
        ln -sf /usr/lib/arm-linux-gnueabihf/libpng* /usr/lib/
        ln -sf /usr/lib/arm-linux-gnueabihf/libjpeg* /usr/lib/
        ln -sfn /usr/include/arm-linux-gnueabihf/curl /usr/include/
    fi

    ulimit -v unlimited

    if [ `grep -L "/lib"    '/etc/ld.so.conf'` ]; then
        echo "/lib" >> /etc/ld.so.conf
    fi

    if [ `grep -L '/usr/lib'    '/etc/ld.so.conf'` ]; then
        echo "/usr/lib" >> /etc/ld.so.conf
    fi

    if [ -d "/usr/lib64" ] && [ `grep -L '/usr/lib64'    '/etc/ld.so.conf'` ]; then
        echo "/usr/lib64" >> /etc/ld.so.conf
    fi

    if [ `grep -L '/usr/local/lib'    '/etc/ld.so.conf'` ]; then
        echo "/usr/local/lib" >> /etc/ld.so.conf
    fi

    if [ -d /usr/include/x86_64-linux-gnu/curl ]; then
        ln -sfn /usr/include/x86_64-linux-gnu/curl /usr/include/
    elif [ -d /usr/include/i386-linux-gnu/curl ]; then
        ln -sfn /usr/include/i386-linux-gnu/curl /usr/include/
    fi

    if [ -d /usr/include/arm-linux-gnueabihf/curl ]; then
        ln -sfn /usr/include/arm-linux-gnueabihf/curl /usr/include/
    fi

    if [ -d /usr/include/aarch64-linux-gnu/curl ]; then
        ln -sfn /usr/include/aarch64-linux-gnu/curl /usr/include/
    fi

    ldconfig

    cat >>/etc/security/limits.conf<<eof
* soft nproc 65535
* hard nproc 65535
* soft nofile 65535
* hard nofile 65535
eof

    echo "fs.file-max=65535" >> /etc/sysctl.conf
}

Remove_Error_Libcurl()
{
    if [ -s /usr/local/lib/libcurl.so ]; then
        rm -f /usr/local/lib/libcurl*
    fi
}

Add_Swap()
{

    Disk_Avail=$(($(df -mP /var | tail -1 | awk '{print $4}' | sed s/[[:space:]]//g)/1024))

    DD_Count='1024'
    if [[ "${MemTotal}" -lt 1024 ]]; then
        DD_Count='1024'
        if [[ "${Disk_Avail}" -lt 5 ]]; then
            Enable_Swap='n'
        fi
    elif [[ "${MemTotal}" -ge 1024 && "${MemTotal}" -le 2048 ]]; then
        DD_Count='2048'
        if [[ "${Disk_Avail}" -lt 13 ]]; then
            Enable_Swap='n'
        fi
    elif [[ "${MemTotal}" -ge 2048 && "${MemTotal}" -le 4096 ]]; then
        DD_Count='4096'
        if [[ "${Disk_Avail}" -lt 17 ]]; then
            Enable_Swap='n'
        fi
    elif [[ "${MemTotal}" -ge 4096 && "${MemTotal}" -le 16384 ]]; then
        DD_Count='8192'
        if [[ "${Disk_Avail}" -lt 19 ]]; then
            Enable_Swap='n'
        fi
    elif [[ "${MemTotal}" -ge 16384 ]]; then
        DD_Count='8192'
        if [[ "${Disk_Avail}" -lt 27 ]]; then
            Enable_Swap='n'
        fi
    fi
    Swap_Total=$(awk '/SwapTotal/ {printf( "%d\n", $2 / 1024 )}' /proc/meminfo)
    if [[ "${Enable_Swap}" = "y" && "${Swap_Total}" -le 512 && ! -s /var/swapfile ]]; then
        echo "正在创建 Swap 文件..."
        [ $(cat /proc/sys/vm/swappiness) -eq 0 ] && sysctl vm.swappiness=10
        dd if=/dev/zero of=/var/swapfile bs=1M count=${DD_Count}
        chmod 0600 /var/swapfile
        echo "正在启用 Swap..."
        /sbin/mkswap /var/swapfile
        /sbin/swapon /var/swapfile
        if [ $? -eq 0 ]; then
            [ `grep -L '/var/swapfile'    '/etc/fstab'` ] && echo "/var/swapfile swap swap defaults 0 0" >>/etc/fstab
            /sbin/swapon -s
        else
            rm -f /var/swapfile
            echo "创建 Swap 失败。"
        fi
    fi
}
