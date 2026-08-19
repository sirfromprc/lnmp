#!/usr/bin/env bash

Upgrade_Nginx()
{
    Cur_Nginx_Version=`/usr/local/nginx/sbin/nginx -v 2>&1 | cut -c22-`

    # 现有二进制已编译的第三方模块在升级后必须保留，否则 nginx.conf 里的
    # brotli、proxy_cache_purge、fancyindex 指令会变成未知指令。
    local nginx_configure
    nginx_configure=$(/usr/local/nginx/sbin/nginx -V 2>&1)
    echo "${nginx_configure}" | grep -q 'ngx_brotli' && Enable_Ngx_Brotli='y'
    echo "${nginx_configure}" | grep -q 'ngx_cache_purge' && Enable_Ngx_CachePurge='y'
    echo "${nginx_configure}" | grep -q 'fancyindex' && Enable_Ngx_FancyIndex='y'

    if [ -s /usr/local/include/jemalloc/jemalloc.h ] && /usr/local/nginx/sbin/nginx -V 2>&1|grep -Eqi 'ljemalloc'; then
        NginxMAOpt="--with-ld-opt='-ljemalloc'"
    elif [ -s /usr/local/include/gperftools/tcmalloc.h ] && grep -Eqi "google_perftools_profiles" /usr/local/nginx/conf/nginx.conf; then
        NginxMAOpt='--with-google_perftools_module'
    else
        NginxMAOpt=""
    fi

    Nginx_Version=""
    echo "当前 Nginx 版本：${Cur_Nginx_Version}"
    echo "可在 https://nginx.org/en/download.html 查看可用版本号。"
    read -p "请输入目标 Nginx 版本（例如 1.20.2）：" Nginx_Version
    if [ "${Nginx_Version}" = "" ]; then
        echo "错误：必须输入 Nginx 版本号！"
        exit 1
    fi
    Check_Version_String "${Nginx_Version}" "Nginx 版本号" || exit 1
    Print_Banner "即将把 Nginx 升级到 ${Nginx_Version}"

    Press_Start || exit 1

    echo "============================ 检查文件 ============================"
    cd ${cur_dir}/src

    if ! Download_Verified nginx "${Nginx_Version}" \
         "https://nginx.org/download/nginx-${Nginx_Version}.tar.gz" \
         "nginx-${Nginx_Version}.tar.gz"; then
        echo "输入的 Nginx 版本为：${Nginx_Version}"
        Echo_Red "错误！nginx-${Nginx_Version}.tar.gz 下载或签名验证失败。"
        exit 1
    fi
    echo "============================ 文件检查结束 ========================"

    Install_Nginx_Openssl
    Install_Nginx_Lua
    Install_Pcre
    if ! Install_Ngx_Brotli; then
        Echo_Red "ngx_brotli 依赖不满足，升级后的 nginx 将不含 Brotli 模块。"
        Ngx_Brotli=""
    fi
    Install_Ngx_CachePurge
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
        ./configure --user=www --group=www --prefix=/usr/local/nginx --with-http_stub_status_module --with-http_ssl_module --with-http_spdy_module --with-http_gzip_static_module --with-ipv6 --with-http_sub_module --with-http_realip_module ${Nginx_With_Openssl} ${Nginx_With_Pcre} ${Nginx_Module_Lua} ${NginxMAOpt} ${Ngx_Brotli} ${Ngx_CachePurge} ${Ngx_FancyIndex} ${Nginx_Modules_Options}
    else
        ./configure --user=www --group=www --prefix=/usr/local/nginx --with-http_stub_status_module --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_gzip_static_module --with-http_sub_module --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module --with-http_realip_module ${Nginx_With_Openssl} ${Nginx_With_Pcre} ${Nginx_Module_Lua} ${NginxMAOpt} ${Ngx_Brotli} ${Ngx_CachePurge} ${Ngx_FancyIndex} ${Nginx_Modules_Options}
    fi

    local nginx_bin='/usr/local/nginx/sbin/nginx'
    local nginx_bak="/usr/local/nginx/sbin/nginx.${Upgrade_Date}"
    local build_dir="${cur_dir}/src/nginx-${Nginx_Version}"

    make -j"$(Build_Jobs)"
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

    # 替换前用新二进制检查现有配置，失败不会影响当前服务。
    echo "用新二进制测试现有配置（尚未替换线上文件）..."
    if ! ./objs/nginx -t -p /usr/local/nginx -c /usr/local/nginx/conf/nginx.conf; then
        Echo_Red "新版 nginx 无法通过现有配置的语法检查，放弃升级。"
        Echo_Red "常见原因：新版本移除了某个指令，或本次编译少了某个模块。"
        Echo_Red "线上 nginx 未做任何改动。"
        exit 1
    fi

    # 运行中的二进制不能被覆盖写（ETXTBSY），改为同目录写新文件后原子换名，
    # 旧 inode 仍被运行中的进程持有，路径上也不存在没有二进制的空窗。
    echo "备份旧二进制到 ${nginx_bak} 并替换..."
    if ! cp -p "${nginx_bin}" "${nginx_bak}"; then
        Echo_Red "备份旧 nginx 二进制失败，放弃升级。"
        exit 1
    fi
    if ! \cp objs/nginx "${nginx_bin}.new" || ! chmod 755 "${nginx_bin}.new"; then
        Echo_Red "写入新 nginx 二进制失败，线上 nginx 未做任何改动。"
        rm -f "${nginx_bin}.new"
        exit 1
    fi
    if ! mv -f "${nginx_bin}.new" "${nginx_bin}"; then
        Echo_Red "替换 nginx 二进制失败，线上 nginx 未做任何改动。"
        rm -f "${nginx_bin}.new"
        exit 1
    fi

    # 升级失败时恢复旧二进制并确认服务继续运行。
    Rollback_Nginx()
    {
        Echo_Red "正在回滚到升级前的 nginx..."
        # 新二进制此时可能已在运行，同样用换名方式写回备份。
        \cp -p "${nginx_bak}" "${nginx_bin}.rollback" &&
        mv -f "${nginx_bin}.rollback" "${nginx_bin}" ||
        Echo_Red "写回旧 nginx 二进制失败：${nginx_bin}"
        if ! ${nginx_bin} -t; then
            Echo_Red "回滚后配置检查仍未通过，请手工处理：${nginx_bin} -t"
        fi
        if pgrep -x nginx >/dev/null 2>&1; then
            ${nginx_bin} -s reload 2>/dev/null || /etc/init.d/nginx restart
        else
            /etc/init.d/nginx start
        fi
    }

    # 通过 USR2/QUIT 热升级到新二进制和工作进程。
    echo "执行热升级..."
    if ! make upgrade; then
        Echo_Red "make upgrade 失败。"
        Rollback_Nginx
        exit 1
    fi

    # 确认进程仍在运行且版本号与目标一致。
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

    # 通过运行状态和版本检查后再清理构建目录。
    cd ${cur_dir} && rm -rf "${build_dir}"
    if [ "${Enable_Nginx_Lua}" = 'y' ]; then
        if ! grep -q 'lua_package_path "/usr/local/nginx/lib/lua/?.lua";' /usr/local/nginx/conf/nginx.conf; then
            sed -i "/server_tokens off;/i\    lua_package_path \"/usr/local/nginx/lib/lua/?.lua\";\n" /usr/local/nginx/conf/nginx.conf
        fi
        if ! grep -q "content_by_lua 'ngx.say(\"hello world\")';" /usr/local/nginx/conf/nginx.conf; then
            sed -i "/location \/nginx_status/i\        location /lua\n        {\n            default_type text/html;\n            content_by_lua 'ngx.say\(\"hello world\"\)';\n        }\n" /usr/local/nginx/conf/nginx.conf
        fi
        # Lua 配置通过语法检查后才重载；失败时保留当前运行配置并提示处理。
        if ${nginx_bin} -t; then
            ${nginx_bin} -s reload
        else
            Echo_Red "写入 Lua 配置后 nginx -t 未通过，未 reload。"
            Echo_Red "nginx 仍以升级后的二进制和旧配置运行，请手工检查 nginx.conf。"
        fi
    fi

    echo "下面显示升级后的 Nginx 版本："
    ${nginx_bin} -v
    Echo_Green "======== Nginx 升级完成 ======"
    Echo_Green "旧二进制保留在 ${nginx_bak}，确认无误后可自行删除。"
    return 0
}
