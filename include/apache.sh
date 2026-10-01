#!/usr/bin/env bash

# 按 Tune_Plan 改写 httpd-mpm.conf 的 prefork 段。mod_php 每个子进程都含 PHP，
# 上游默认 MaxRequestWorkers 250 远超小内存机器的承载量。
# MaxConnectionsPerChild 与 PHP-FPM 的 pm.max_requests 一致，定期回收子进程内存。
Apache_Prefork_Opt()
{
    local conf="${1:-/usr/local/apache/conf/extra/httpd-mpm.conf}" tmp

    Tune_Plan || return 0
    if [ ! -s "${conf}" ]; then
        Echo_Yellow "未找到 ${conf}，prefork 进程数保持 Apache 默认值。"
        return 0
    fi
    tmp=$(mktemp "${conf}.XXXXXX") || return 1
    if ! awk -v start="${Tune_Apache_Start}" -v mins="${Tune_Apache_Min_Spare}" \
            -v maxs="${Tune_Apache_Max_Spare}" -v workers="${Tune_Apache_Workers}" '
        /^<IfModule mpm_prefork_module>/ { insec = 1 }
        insec && /^<\/IfModule>/ { insec = 0 }
        insec && $1 == "StartServers" { $0 = "    StartServers             " start }
        insec && $1 == "MinSpareServers" { $0 = "    MinSpareServers          " mins }
        insec && $1 == "MaxSpareServers" { $0 = "    MaxSpareServers          " maxs }
        insec && $1 == "MaxRequestWorkers" { $0 = "    MaxRequestWorkers        " workers }
        insec && $1 == "MaxConnectionsPerChild" { $0 = "    MaxConnectionsPerChild   1024" }
        { print }
    ' "${conf}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    chmod --reference="${conf}" "${tmp}" 2>/dev/null
    mv -f "${tmp}" "${conf}" || return 1
    grep -Eq "^[[:space:]]+MaxRequestWorkers[[:space:]]+${Tune_Apache_Workers}\$" "${conf}"
}

Install_Apache_24()
{
    Echo_Blue "[+] 正在安装 ${Apache_Ver}..."
    if [ "${Stack}" = "lamp" ]; then
        groupadd www
        useradd -s /sbin/nologin -g www www
        # 站点目录由 www 管理，日志目录仅允许 root 写入。
        mkdir -p ${Default_Website_Dir}
        mkdir -p /home/wwwlogs
        chown root:root /home/wwwlogs
        chmod 755 /home/wwwlogs
        chown -R www:www ${Default_Website_Dir}
        chmod 755 ${Default_Website_Dir}
        Install_Openssl_New
        Install_Nghttp2
    fi
    Tar_Cd ${Apache_Ver}.tar.bz2 ${Apache_Ver}
    cd srclib || return 1
    # APR 和 APR-util 经下载校验后复制到 httpd 的 srclib 目录参与编译。

    local apache_srclib="${PWD}"
    cd "${cur_dir}/src" || exit 1
    Download_Files https://archive.apache.org/dist/apr/${APR_Ver}.tar.bz2 ${APR_Ver}.tar.bz2
    Require_File "${APR_Ver}.tar.bz2" "APR"
    Download_Files https://archive.apache.org/dist/apr/${APR_Util_Ver}.tar.bz2 ${APR_Util_Ver}.tar.bz2
    Require_File "${APR_Util_Ver}.tar.bz2" "APR-util"
    cd "${apache_srclib}" || exit 1
    cp "${cur_dir}/src/${APR_Ver}.tar.bz2" . || exit 1
    cp "${cur_dir}/src/${APR_Util_Ver}.tar.bz2" . || exit 1
    tar jxf ${APR_Ver}.tar.bz2
    tar jxf ${APR_Util_Ver}.tar.bz2
    mv ${APR_Ver} apr
    mv ${APR_Util_Ver} apr-util
    cd ..
    if [ "${Stack}" = "lamp" ]; then
        ./configure --prefix=/usr/local/apache --enable-mods-shared=most --enable-headers --enable-mime-magic --enable-proxy --enable-so --enable-rewrite --enable-ssl ${apache_with_ssl} --enable-deflate --with-pcre --with-included-apr --with-apr-util --enable-mpms-shared=all --enable-remoteip --enable-http2 --with-nghttp2=/usr/local/nghttp2
    else
        ./configure --prefix=/usr/local/apache --enable-mods-shared=most --enable-headers --enable-mime-magic --enable-proxy --enable-so --enable-rewrite --enable-ssl --with-ssl --enable-deflate --with-pcre --with-included-apr --with-apr-util --enable-mpms-shared=all --enable-remoteip
    fi
    Make_Install || exit 1
    cd "${cur_dir}/src" || return 1
    Clean_Src_Dir "${Apache_Ver}"

    mv /usr/local/apache/conf/httpd.conf /usr/local/apache/conf/httpd.conf.bak
    if [ "${Stack}" = "lamp" ]; then
        \cp ${cur_dir}/conf/httpd24-lamp.conf /usr/local/apache/conf/httpd.conf
        \cp ${cur_dir}/conf/httpd-vhosts-lamp.conf /usr/local/apache/conf/extra/httpd-vhosts.conf
        \cp ${cur_dir}/conf/httpd24-ssl.conf /usr/local/apache/conf/extra/httpd-ssl.conf
        \cp ${cur_dir}/conf/example/enable-apache-ssl-vhost-example.conf /usr/local/apache/conf/enable-apache-ssl-vhost-example.conf
    elif [ "${Stack}" = "lnmpa" ]; then
        \cp ${cur_dir}/conf/httpd24-lnmpa.conf /usr/local/apache/conf/httpd.conf
        \cp ${cur_dir}/conf/httpd-vhosts-lnmpa.conf /usr/local/apache/conf/extra/httpd-vhosts.conf
    fi
    \cp ${cur_dir}/conf/httpd-default.conf /usr/local/apache/conf/extra/httpd-default.conf
    \cp ${cur_dir}/conf/mod_remoteip.conf /usr/local/apache/conf/extra/mod_remoteip.conf
    Apache_Prefork_Opt || Echo_Yellow "prefork 进程数未能按内存调整，保持 Apache 默认值。"

    sed -i "s/ServerAdmin you@example.com/ServerAdmin ${ServerAdmin}/g" /usr/local/apache/conf/httpd.conf
    sed -i "s/webmaster@example.com/${ServerAdmin}/g" /usr/local/apache/conf/extra/httpd-vhosts.conf
    # shared/ 保存站点公共配置片段，供站点的 80 与 443 两个 VirtualHost 共同 Include。
    mkdir -p /usr/local/apache/conf/vhost/shared

    sed -i 's/NameVirtualHost .*//g' /usr/local/apache/conf/extra/httpd-vhosts.conf
    if [ "${Default_Website_Dir}" != "/home/wwwroot/default" ]; then
        sed -i "s#/home/wwwroot/default#${Default_Website_Dir}#g" /usr/local/apache/conf/httpd.conf
        sed -i "s#/home/wwwroot/default#${Default_Website_Dir}#g" /usr/local/apache/conf/extra/httpd-vhosts.conf
    fi

    # PHP 7 及以上不加载 php5_module。
    if [ "${PHP_Apache_Module}" != "libphp5.so" ]; then
        sed -i '/^LoadModule php5_module/d' /usr/local/apache/conf/httpd.conf
    fi

    \cp ${cur_dir}/init.d/init.d.httpd /etc/init.d/httpd
    Install_Systemd_Unit "${cur_dir}/init.d/httpd.service" /etc/systemd/system/httpd.service || return 1
    chmod +x /etc/init.d/httpd
}
