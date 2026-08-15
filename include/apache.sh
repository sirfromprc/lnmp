#!/usr/bin/env bash

Install_Apache_24()
{
    Echo_Blue "[+] 正在安装 ${Apache_Ver}..."
    if [ "${Stack}" = "lamp" ]; then
        groupadd www
        useradd -s /sbin/nologin -g www www
        # 权限基线，口径同 include/nginx.sh：
        # 站点根目录 755 www:www，日志目录 755 root:root（原为 777）。
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
    cd srclib
    # APR / APR-util 要放进 httpd 源码树的 srclib/ 下一起编译。
    # 原写法是「src/ 下已有就直接 cp 进来」，跳过了 Download_Files 的校验 ：
    # 缓存文件走的是免检通道。现改为先在 src/ 里下载+校验，再 cp 进 srclib/。

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
    cd ${cur_dir}/src
    rm -rf ${cur_dir}/src/${Apache_Ver}

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

    sed -i 's/ServerAdmin you@example.com/ServerAdmin '${ServerAdmin}'/g' /usr/local/apache/conf/httpd.conf
    sed -i 's/webmaster@example.com/'${ServerAdmin}'/g' /usr/local/apache/conf/extra/httpd-vhosts.conf
    mkdir /usr/local/apache/conf/vhost

    sed -i 's/NameVirtualHost .*//g' /usr/local/apache/conf/extra/httpd-vhosts.conf
    if [ "${Default_Website_Dir}" != "/home/wwwroot/default" ]; then
        sed -i "s#/home/wwwroot/default#${Default_Website_Dir}#g" /usr/local/apache/conf/httpd.conf
        sed -i "s#/home/wwwroot/default#${Default_Website_Dir}#g" /usr/local/apache/conf/extra/httpd-vhosts.conf
    fi

    # PHP 7 起模块名不再是 php5_module，模板里的旧行要去掉
    if [ "${PHP_Apache_Module}" != "libphp5.so" ]; then
        sed -i '/^LoadModule php5_module/d' /usr/local/apache/conf/httpd.conf
    fi

    \cp ${cur_dir}/init.d/init.d.httpd /etc/init.d/httpd
    \cp ${cur_dir}/init.d/httpd.service /etc/systemd/system/httpd.service
    chmod +x /etc/init.d/httpd
}
