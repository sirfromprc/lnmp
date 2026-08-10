#!/usr/bin/env bash

Upgrade_Nginx()
{
    Cur_Nginx_Version=`/usr/local/nginx/sbin/nginx -v 2>&1 | cut -c22-`

    if [ -s /usr/local/include/jemalloc/jemalloc.h ] && /usr/local/nginx/sbin/nginx -V 2>&1|grep -Eqi 'ljemalloc'; then
        NginxMAOpt="--with-ld-opt='-ljemalloc'"
    elif [ -s /usr/local/include/gperftools/tcmalloc.h ] && grep -Eqi "google_perftools_profiles" /usr/local/nginx/conf/nginx.conf; then
        NginxMAOpt='--with-google_perftools_module'
    else
        NginxMAOpt=""
    fi

    Nginx_Version=""
    echo "Current Nginx Version:${Cur_Nginx_Version}"
    echo "You can get version number from https://nginx.org/en/download.html"
    read -p "Please enter nginx version you want, (example: 1.20.2): " Nginx_Version
    if [ "${Nginx_Version}" = "" ]; then
        echo "Error: You must enter a nginx version!!"
        exit 1
    fi
    echo "+---------------------------------------------------------+"
    echo "|    You will upgrade nginx version to ${Nginx_Version}"
    echo "+---------------------------------------------------------+"

    Press_Start

    echo "============================check files=================================="
    cd ${cur_dir}/src

    if ! Download_Verified nginx "${Nginx_Version}" \
         "https://nginx.org/download/nginx-${Nginx_Version}.tar.gz" \
         "nginx-${Nginx_Version}.tar.gz"; then
        echo "You enter Nginx Version was:"${Nginx_Version}
        Echo_Red "Error! nginx-${Nginx_Version}.tar.gz 下载或签名验证失败。"
        exit 1
    fi
    echo "============================check files=================================="

    Install_Nginx_Openssl
    Install_Nginx_Lua
    Install_Pcre
    Install_Ngx_FancyIndex
    Tar_Cd nginx-${Nginx_Version}.tar.gz nginx-${Nginx_Version}
    Get_Dist_Version
    if [[ "${DISTRO}" = "Fedora" && ${Fedora_Version} -ge 28 ]]; then
        patch -p1 < ${cur_dir}/src/patch/nginx-libxcrypt.patch
    fi
    Nginx_Ver_Com=$(Version_Compare 1.14.2 ${Nginx_Version})
    if gcc -dumpversion|grep -q "^[8]" && [ "${Nginx_Ver_Com}" == "1" ]; then
        patch -p1 < ${cur_dir}/src/patch/nginx-gcc8.patch
    fi
    Nginx_Ver_Com=$(Version_Compare 1.9.4 ${Nginx_Version})
    if [[ "${Nginx_Ver_Com}" == "0" ||  "${Nginx_Ver_Com}" == "1" ]]; then
        ./configure --user=www --group=www --prefix=/usr/local/nginx --with-http_stub_status_module --with-http_ssl_module --with-http_spdy_module --with-http_gzip_static_module --with-ipv6 --with-http_sub_module --with-http_realip_module ${Nginx_With_Openssl} ${Nginx_With_Pcre} ${Nginx_Module_Lua} ${NginxMAOpt} ${Ngx_FancyIndex} ${Nginx_Modules_Options}
    else
        ./configure --user=www --group=www --prefix=/usr/local/nginx --with-http_stub_status_module --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_gzip_static_module --with-http_sub_module --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module --with-http_realip_module ${Nginx_With_Openssl} ${Nginx_With_Pcre} ${Nginx_Module_Lua} ${NginxMAOpt} ${Ngx_FancyIndex} ${Nginx_Modules_Options}
    fi

    local nginx_bin='/usr/local/nginx/sbin/nginx'
    local nginx_bak="/usr/local/nginx/sbin/nginx.${Upgrade_Date}"
    local build_dir="${cur_dir}/src/nginx-${Nginx_Version}"

    make -j `grep 'processor' /proc/cpuinfo | wc -l`
    if [ $? -ne 0 ]; then
        Echo_Yellow "并行编译失败，退回串行重试..."
        if ! make; then
            Echo_Red "nginx ${Nginx_Version} 编译失败。线上 nginx 未做任何改动。"
            exit 1
        fi
    fi
    if [ ! -s objs/nginx ]; then
        Echo_Red "编译结束但没有产出 objs/nginx。线上 nginx 未做任何改动。"
        exit 1
    fi

    # 1) 先用新二进制测现有配置，此时线上还没被动过
    echo "用新二进制测试现有配置（尚未替换线上文件）..."
    if ! ./objs/nginx -t -p /usr/local/nginx -c /usr/local/nginx/conf/nginx.conf; then
        Echo_Red "新版 nginx 无法通过现有配置的语法检查，放弃升级。"
        Echo_Red "常见原因：新版本移除了某个指令，或本次编译少了某个模块。"
        Echo_Red "线上 nginx 未做任何改动。"
        exit 1
    fi

    # 2) 备份旧二进制并替换
    echo "备份旧二进制到 ${nginx_bak} 并替换..."
    if ! cp -p "${nginx_bin}" "${nginx_bak}"; then
        Echo_Red "备份旧 nginx 二进制失败，放弃升级。"
        exit 1
    fi
    if ! \cp objs/nginx "${nginx_bin}"; then
        Echo_Red "复制新 nginx 二进制失败，恢复旧版本。"
        \cp -p "${nginx_bak}" "${nginx_bin}"
        exit 1
    fi

    # 出了任何问题都用它把旧二进制换回去并确保服务在跑
    Rollback_Nginx()
    {
        Echo_Red "正在回滚到升级前的 nginx..."
        \cp -p "${nginx_bak}" "${nginx_bin}"
        if ! ${nginx_bin} -t; then
            Echo_Red "回滚后配置检查仍未通过，请手工处理：${nginx_bin} -t"
        fi
        if pgrep -x nginx >/dev/null 2>&1; then
            ${nginx_bin} -s reload 2>/dev/null || /etc/init.d/nginx restart
        else
            /etc/init.d/nginx start
        fi
    }

    # 3) 热升级（向 master 发 USR2/QUIT，切换到新二进制的 worker）
    echo "执行热升级..."
    if ! make upgrade; then
        Echo_Red "make upgrade 失败。"
        Rollback_Nginx
        exit 1
    fi

    # 4) 确认真的切过去了：进程在跑，且版本号是目标版本
    sleep 2
    if ! pgrep -x nginx >/dev/null 2>&1; then
        Echo_Red "热升级后没有 nginx 进程在运行。"
        Rollback_Nginx
        exit 1
    fi
    New_Ver_Out=$(${nginx_bin} -v 2>&1)
    if ! echo "${New_Ver_Out}" | grep -q "nginx/${Nginx_Version}"; then
        Echo_Red "升级后版本号不符：期望 ${Nginx_Version}，实际 '${New_Ver_Out}'。"
        Rollback_Nginx
        exit 1
    fi

    # 到这里才算成功，可以清理源码
    cd ${cur_dir} && rm -rf "${build_dir}"
    if [ "${Enable_Nginx_Lua}" = 'y' ]; then
        if ! grep -q 'lua_package_path "/usr/local/nginx/lib/lua/?.lua";' /usr/local/nginx/conf/nginx.conf; then
            sed -i "/server_tokens off;/i\        lua_package_path \"/usr/local/nginx/lib/lua/?.lua\";\n" /usr/local/nginx/conf/nginx.conf
        fi
        if ! grep -q "content_by_lua 'ngx.say(\"hello world\")';" /usr/local/nginx/conf/nginx.conf; then
            sed -i "/location \/nginx_status/i\        location /lua\n        {\n            default_type text/html;\n            content_by_lua 'ngx.say\(\"hello world\"\)';\n        }\n" /usr/local/nginx/conf/nginx.conf
        fi
        # 改完配置再测一次并 reload，测不过就把配置改动撤销的成本太高，
        # 这里只报警并保留旧配置的运行态（不 reload 就不会生效）。
        if ${nginx_bin} -t; then
            ${nginx_bin} -s reload
        else
            Echo_Red "写入 Lua 配置后 nginx -t 未通过，未 reload。"
            Echo_Red "nginx 仍以升级后的二进制和旧配置运行，请手工检查 nginx.conf。"
        fi
    fi

    echo "Program will display Nginx Version......"
    ${nginx_bin} -v
    Echo_Green "======== upgrade nginx completed ======"
    Echo_Green "旧二进制保留在 ${nginx_bak}，确认无误后可自行删除。"
    return 0
}
