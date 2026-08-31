#!/usr/bin/env bash

Install_Nginx_Openssl()
{
    if [ "${Enable_Nginx_Openssl}" = 'y' ]; then
        if [ ! -n "${Nginx_Version}" ]; then
            Nginx_Version=$(echo ${Nginx_Ver} | sed "s/nginx-//")
        fi
        # 当前 Nginx 版本统一使用受支持的现代 OpenSSL。
        Download_Files https://github.com/openssl/openssl/releases/download/${Openssl_New_Ver}/${Openssl_New_Ver}.tar.gz ${Openssl_New_Ver}.tar.gz
        if [ $? -ne 0 ]; then
            Download_Files https://www.openssl.org/source/${Openssl_New_Ver}.tar.gz ${Openssl_New_Ver}.tar.gz
        fi
        Require_File "${Openssl_New_Ver}.tar.gz" "OpenSSL"
        [[ -d "${Openssl_New_Ver}" ]] && rm -rf ${Openssl_New_Ver}
        tar zxf ${Openssl_New_Ver}.tar.gz
        Nginx_With_Openssl="--with-openssl=${cur_dir}/src/${Openssl_New_Ver}"
    fi
}

Install_Nginx_Lua()
{
    if [ "${Enable_Nginx_Lua}" = 'y' ]; then
        echo "正在为 Nginx 安装 Lua 支持..."
        cd "${cur_dir}/src" || return 1
        # Lua 组件从各项目的上游 GitHub 仓库获取。
        Download_Files https://github.com/openresty/luajit2/archive/refs/tags/v${Luajit_Ver#luajit2-}.tar.gz ${Luajit_Ver}.tar.gz
        Download_Files https://github.com/openresty/lua-nginx-module/archive/refs/tags/v${LuaNginxModule#lua-nginx-module-}.tar.gz ${LuaNginxModule}.tar.gz
        Download_Files https://github.com/vision5/ngx_devel_kit/archive/refs/tags/v${NgxDevelKit#ngx_devel_kit-}.tar.gz ${NgxDevelKit}.tar.gz
        Download_Files https://github.com/openresty/lua-resty-core/archive/refs/tags/v${LuaRestyCore#lua-resty-core-}.tar.gz ${LuaRestyCore}.tar.gz
        Download_Files https://github.com/openresty/lua-resty-lrucache/archive/refs/tags/v${LuaRestyLrucache#lua-resty-lrucache-}.tar.gz ${LuaRestyLrucache}.tar.gz

        Require_File "${Luajit_Ver}.tar.gz" "LuaJIT"
        Require_File "${LuaNginxModule}.tar.gz" "lua-nginx-module"
        Require_File "${NgxDevelKit}.tar.gz" "ngx_devel_kit"
        Require_File "${LuaRestyCore}.tar.gz" "lua-resty-core"
        Require_File "${LuaRestyLrucache}.tar.gz" "lua-resty-lrucache"

        Echo_Blue "[+] 正在安装 ${Luajit_Ver}... "
        # Nginx configure 直接引用模块源码目录，解压失败时立即停止。
        tar zxf ${LuaNginxModule}.tar.gz || { Echo_Red "解压 ${LuaNginxModule} 失败"; exit 1; }
        tar zxf ${NgxDevelKit}.tar.gz    || { Echo_Red "解压 ${NgxDevelKit} 失败"; exit 1; }
        Tar_Cd ${Luajit_Ver}.tar.gz ${Luajit_Ver}
        if ! make; then
            Echo_Red "LuaJIT 编译失败。"
            exit 1
        fi
        if ! make install PREFIX=/usr/local/luajit; then
            Echo_Red "LuaJIT 安装失败。"
            exit 1
        fi
        cd "${cur_dir}/src" || return 1
        Clean_Src_Dir "${Luajit_Ver}"
        cat > /etc/ld.so.conf.d/luajit.conf<<EOF
/usr/local/luajit/lib
EOF
        if [ "${Is_64bit}" = "y" ]; then
            ln -sf /usr/local/luajit/lib/libluajit-5.1.so.2 /lib64/libluajit-5.1.so.2
        else
            ln -sf /usr/local/luajit/lib/libluajit-5.1.so.2 /usr/lib/libluajit-5.1.so.2
        fi
        ldconfig
        cat >/etc/profile.d/luajit.sh<<EOF
export LUAJIT_LIB=/usr/local/luajit/lib
export LUAJIT_INC=/usr/local/luajit/include/luajit-2.1
EOF

        source /etc/profile.d/luajit.sh

        # 纯 Lua 库安装失败时立即停止，避免 Nginx 启动后才暴露缺失文件。
        Tar_Cd ${LuaRestyCore}.tar.gz ${LuaRestyCore}
        make install PREFIX=/usr/local/nginx || { Echo_Red "安装 ${LuaRestyCore} 失败"; exit 1; }
        cd - || exit 1
        Tar_Cd ${LuaRestyLrucache}.tar.gz ${LuaRestyLrucache}
        make install PREFIX=/usr/local/nginx || { Echo_Red "安装 ${LuaRestyLrucache} 失败"; exit 1; }
        cd - || exit 1

        Install_Lua_Cjson
        Install_Lua_Resty_Libs

        # lua-resty 库依赖 Nginx 的 ngx 运行环境，此处仅做语法检查；独立的
        # cjson C 模块可直接加载。lua-resty 运行期行为需在 Nginx 启动后验证。
        if [ -x /usr/local/luajit/bin/luajit ]; then
            Lua_Smoke_Ok='y'

            for luafile in /usr/local/nginx/lib/lua/resty/core.lua \
                           /usr/local/nginx/lib/lua/resty/lrucache.lua \
                           /usr/local/luajit/lib/lua/5.1/cjson.so; do
                if [ ! -s "${luafile}" ]; then
                    Echo_Red "Lua 运行库缺失：${luafile}"
                    Lua_Smoke_Ok='n'
                fi
            done

            for luafile in /usr/local/nginx/lib/lua/resty/core.lua \
                           /usr/local/nginx/lib/lua/resty/lrucache.lua; do
                if ! /usr/local/luajit/bin/luajit -e \
                     "assert(loadfile('${luafile}'))"; then
                    Echo_Red "${luafile} 语法检查失败（文件损坏或与 LuaJIT 版本不匹配）。"
                    Lua_Smoke_Ok='n'
                fi
            done

            if ! LUA_CPATH='/usr/local/luajit/lib/lua/5.1/?.so;;' \
                 /usr/local/luajit/bin/luajit -e 'require("cjson")'; then
                Echo_Red "cjson 无法 require（C 模块未正确编译或路径不对）。"
                Lua_Smoke_Ok='n'
            fi

            if [ "${Lua_Smoke_Ok}" != 'y' ]; then
                Echo_Red "Lua 运行库冒烟测试失败。"
                Echo_Red "继续编译只会把问题推迟到 nginx 启动时才暴露，这里中止。"
                exit 1
            fi
            Echo_Green "Lua 运行库冒烟测试通过。"
        fi

        Nginx_Ver_Com=$(Version_Compare 1.21.5 ${Nginx_Version})
        Nginx_Ver_Com=$(Version_Compare 1.21.5 ${Nginx_Version})
        if [[  "${Nginx_Ver_Com}" == "1" ]]; then
            Nginx_Module_Lua="--with-ld-opt=-Wl,-rpath,/usr/local/luajit/lib --add-module=${cur_dir}/src/${LuaNginxModule} --add-module=${cur_dir}/src/${NgxDevelKit}"
        else
            if [ "${Nginx_With_Pcre}" = "" ]; then
                Nginx_Module_Lua="--with-ld-opt=-Wl,-rpath,/usr/local/luajit/lib --add-module=${cur_dir}/src/${LuaNginxModule} --add-module=${cur_dir}/src/${NgxDevelKit} --with-pcre=${cur_dir}/src/${Pcre_Ver} --with-pcre-jit"
                cd "${cur_dir}/src" || return 1
                Download_Files https://downloads.sourceforge.net/pcre/${Pcre_Ver}.tar.bz2 ${Pcre_Ver}.tar.bz2
                Require_File "${Pcre_Ver}.tar.bz2" "PCRE"
                Tar_Cd ${Pcre_Ver}.tar.bz2
            else
                Nginx_Module_Lua="--with-ld-opt=-Wl,-rpath,/usr/local/luajit/lib --add-module=${cur_dir}/src/${LuaNginxModule} --add-module=${cur_dir}/src/${NgxDevelKit}"
            fi
        fi
    fi
}

# 编译生成 cjson.so。
# 与其他 lua-resty-* 不同，cjson 有 C 代码，必须针对 LuaJIT 的头文件编译，
# 安装到 LuaJIT cmodule 目录，并由 nginx.conf 的 lua_package_cpath 引用。
# OpenResty 维护的分支与 LuaJIT 及 lua-resty 组件保持兼容。
Install_Lua_Cjson()
{
    cd "${cur_dir}/src" || return 1
    Download_Files https://github.com/openresty/lua-cjson/archive/refs/tags/${LuaCjson#lua-cjson-}.tar.gz ${LuaCjson}.tar.gz
    Require_File "${LuaCjson}.tar.gz" "lua-cjson"
    Tar_Cd ${LuaCjson}.tar.gz ${LuaCjson}

    make LUA_INCLUDE_DIR=/usr/local/luajit/include/luajit-2.1 \
         LUA_CMODULE_DIR=/usr/local/luajit/lib/lua/5.1 \
         LUA_MODULE_DIR=/usr/local/luajit/share/lua/5.1
    make install LUA_INCLUDE_DIR=/usr/local/luajit/include/luajit-2.1 \
                 LUA_CMODULE_DIR=/usr/local/luajit/lib/lua/5.1 \
                 LUA_MODULE_DIR=/usr/local/luajit/share/lua/5.1

    if [ ! -s /usr/local/luajit/lib/lua/5.1/cjson.so ]; then
        Echo_Red "lua-cjson 编译失败：未生成 cjson.so"
        Echo_Red "依赖 lua-cjson 的 Lua 代码会在运行时报 module 'cjson' not found。"
    fi
    cd "${cur_dir}/src" || return 1
    Clean_Src_Dir "${LuaCjson}"
}

# 安装纯 Lua 的 lua-resty 库。单个库不参与 Nginx 编译，下载失败时提示并继续。
Install_Lua_Resty_Libs()
{
    local lib repo
    cd "${cur_dir}/src" || return 1

    for lib in "${LuaRestyLock}" "${LuaRestyString}" "${LuaRestyRedis}" \
               "${LuaRestyMysql}" "${LuaRestyUpload}" "${LuaRestyWebsocket}" \
               "${LuaRestyDns}" "${LuaRestyMemcached}" "${LuaRestyLimitTraffic}"; do
        # 从组件名中分离仓库名和标签，并保留 rc 等预发布版本后缀。
        repo=$(echo "${lib}" | sed -E 's/-[0-9][0-9.]*([a-zA-Z]+[0-9]*)?$//')
        Echo_Blue "[+] 正在安装 ${lib}... "
        Download_Files https://github.com/openresty/${repo}/archive/refs/tags/v${lib##${repo}-}.tar.gz ${lib}.tar.gz
        if [ ! -s "${cur_dir}/src/${lib}.tar.gz" ]; then
            Echo_Red "${lib} 下载失败，跳过（不影响 nginx 本体）"
            continue
        fi
        Tar_Cd ${lib}.tar.gz ${lib}
        make install PREFIX=/usr/local/nginx
        cd "${cur_dir}/src" || return 1
        Clean_Src_Dir "${lib}"
    done
}

# 安装 Brotli 压缩模块。GitHub 归档不包含 deps/brotli 子模块，因此构建前
# 将系统提供的 Brotli 头文件和库映射到模块预期目录。
Install_Ngx_Brotli()
{
    if [ "${Enable_Ngx_Brotli}" = 'y' ]; then
        Echo_Blue "[+] 正在安装 ngx_brotli... "
        cd "${cur_dir}/src" || return 1
        Download_Files https://github.com/google/ngx_brotli/archive/${NgxBrotli_Commit}.tar.gz ${NgxBrotli_Ver}.tar.gz
        Require_File "${NgxBrotli_Ver}.tar.gz" "ngx_brotli"
        Clean_Src_Dir "${NgxBrotli_Ver}"
        tar zxf ${NgxBrotli_Ver}.tar.gz

        # ngx_brotli 只从 deps/brotli 固定结构查找依赖。映射系统头文件和库
        # 可满足 configure 检查，并使共享库继续接收发行版安全更新。
        Link_System_Brotli || return 1

        Ngx_Brotli="--add-module=${cur_dir}/src/${NgxBrotli_Ver}"
    fi
}

# 将系统 Brotli 映射为 ngx_brotli 的 deps 目录。通过编译器搜索路径定位库，
# 兼容不同发行版和架构；依赖缺失时明确提示安装软件包或关闭模块。
Link_System_Brotli()
{
    local deps="${cur_dir}/src/${NgxBrotli_Ver}/deps/brotli"
    local enc_lib libdir

    if [ ! -f /usr/include/brotli/encode.h ]; then
        Echo_Red "缺少 brotli 头文件 /usr/include/brotli/encode.h。"
        Echo_Red "请先安装：Debian/Ubuntu 'apt-get install libbrotli-dev'，"
        Echo_Red "           RHEL/CentOS 'dnf install brotli-devel'。"
        Echo_Red "或在 lnmp.conf 里设 Enable_Ngx_Brotli='n' 跳过 Brotli 压缩。"
        return 1
    fi

    # 优先使用可随发行版更新的共享库，缺失时使用静态库。
    enc_lib=$(gcc -print-file-name=libbrotlienc.so 2>/dev/null)
    if [ ! -f "${enc_lib}" ]; then
        enc_lib=$(gcc -print-file-name=libbrotlienc.a 2>/dev/null)
    fi
    if [ ! -f "${enc_lib}" ]; then
        Echo_Red "找不到 brotli 编码库（libbrotlienc.so / .a）。"
        Echo_Red "请安装 libbrotli-dev / brotli-devel，"
        Echo_Red "或在 lnmp.conf 里设 Enable_Ngx_Brotli='n' 跳过 Brotli 压缩。"
        return 1
    fi
    libdir=$(cd "$(dirname "${enc_lib}")" && pwd)

    rm -rf "${deps}"
    mkdir -p "${deps}/c/include" || return 1
    ln -sfn /usr/include/brotli "${deps}/c/include/brotli" || return 1
    ln -sfn "${libdir}" "${deps}/out" || return 1

    echo "ngx_brotli: 使用系统 brotli 库（头文件 /usr/include/brotli，库目录 ${libdir}）"
    return 0
}

# 安装提供 proxy_cache_purge 等指令的缓存清除模块。
Install_Ngx_CachePurge()
{
    if [ "${Enable_Ngx_CachePurge}" = 'y' ]; then
        Echo_Blue "[+] 正在安装 ${NgxCachePurge_Ver}... "
        cd "${cur_dir}/src" || return 1
        Download_Files https://github.com/FRiCKLE/ngx_cache_purge/archive/${NgxCachePurge_Ver#ngx_cache_purge-}.tar.gz ${NgxCachePurge_Ver}.tar.gz
        Require_File "${NgxCachePurge_Ver}.tar.gz" "ngx_cache_purge"
        Clean_Src_Dir "${NgxCachePurge_Ver}"
        tar zxf ${NgxCachePurge_Ver}.tar.gz
        Ngx_CachePurge="--add-module=${cur_dir}/src/${NgxCachePurge_Ver}"
    fi
}

Install_Ngx_FancyIndex()
{
    if [ "${Enable_Ngx_FancyIndex}" = 'y' ]; then
        echo "正在为 Nginx 安装 FancyIndex 模块..."
        cd "${cur_dir}/src" || return 1
        Download_Files https://github.com/aperezdc/ngx-fancyindex/releases/download/v${NgxFancyIndex_Ver#ngx-fancyindex-}/${NgxFancyIndex_Ver}.tar.xz ${NgxFancyIndex_Ver}.tar.xz
        Require_File "${NgxFancyIndex_Ver}.tar.xz" "ngx-fancyindex"

        Tar_Cd ${NgxFancyIndex_Ver}.tar.xz
        Ngx_FancyIndex="--add-module=${cur_dir}/src/${NgxFancyIndex_Ver}"
    fi
}

# 分发 Nginx 和 OpenResty 共用的反代包含文件。
# proxy.conf 是三栈通用的反代参数，LNMPA 转发 PHP 与其它栈的自定义反代站点都 include 它；
# proxy-pass-php.conf 只把 PHP 转给本机 Apache，仅 LNMPA 需要。
# keep_existing 为 y 时只补缺失文件，不覆盖站点已有的修改。
Write_Nginx_Proxy_Conf()
{
    local conf_dir="${1:-/usr/local/nginx/conf}"
    local is_lnmpa="${2:-n}"
    local keep_existing="${3:-n}"
    local name

    if [ ! -d "${conf_dir}" ]; then
        Echo_Red "Nginx 配置目录不存在：${conf_dir}"
        return 1
    fi
    for name in proxy.conf proxy-pass-php.conf; do
        if [ "${name}" = 'proxy-pass-php.conf' ] && [ "${is_lnmpa}" != 'y' ]; then
            continue
        fi
        if [ "${keep_existing}" = 'y' ] && [ -s "${conf_dir}/${name}" ]; then
            continue
        fi
        if ! \cp "${cur_dir}/conf/${name}" "${conf_dir}/${name}"; then
            Echo_Red "写入 ${conf_dir}/${name} 失败。"
            return 1
        fi
    done
    return 0
}

# 生成 Nginx 和 OpenResty 共用的静态默认站点。
Write_Nginx_Default_VHost()
{
    local conf_dir="${1:-/usr/local/nginx/conf}"
    local listen_extra=''
    local uname_r demo_php_block

    uname_r=$(uname -r)
    if echo "${uname_r}" | grep -Eq '^3\.(9|1[0-9])|^[4-9]\.'; then
        listen_extra=' reuseport'
    fi

    # LNMPA 将 PHP 请求反向代理到 Apache，其余安装栈连接 PHP-FPM。
    if [ "${Stack}" = 'lnmpa' ]; then
        demo_php_block='        proxy_pass http://127.0.0.1:88;
        include proxy.conf;'
    else
        demo_php_block='        try_files $uri =404;
        fastcgi_pass  unix:/run/php-fpm/php-cgi.sock;
        fastcgi_index index.php;
        include fastcgi.conf;'
    fi

    if ! mkdir -p "${conf_dir}/vhost"; then
        Echo_Red "创建 Nginx vhost 配置目录失败：${conf_dir}/vhost"
        return 1
    fi

    cat >"${conf_dir}/vhost/default.conf"<<EOF || { Echo_Red "生成 Nginx default 站点失败。"; return 1; }
server {
    listen 80 default_server${listen_extra};
    #listen [::]:80 default_server ipv6only=on;
    server_name _;
    index index.html index.htm;
    root  ${Default_Website_Dir};

    #error_page   404   /404.html;

    # phpMyAdmin 片段按安装开关生成，关闭时默认站点保持静态。
    include phpmyadmin.*.conf;

    # 仅允许按开关部署的 phpinfo、redis 和 memcached 固定测试页执行 PHP；
    # 文件未部署时返回 404。
    location ~ ^/(phpinfo|redis|memcached)\.php\$ {
${demo_php_block}
    }

    # 默认站点除指定测试页外不执行 PHP，避免源码泄露；phpMyAdmin 使用
    # 独立的 ^~ 前缀规则，不会放开网站根目录中的其他 PHP 文件。
    location ~ [^/]\.php(/|\$) {
        return 404;
    }

    location ~ .*\.(gif|jpg|jpeg|png|bmp|swf)\$ {
        expires      30d;
    }

    location ~ .*\.(js|css)\$ {
        expires      12h;
    }

    location ^~ /.well-known/ {
        allow all;
    }

    location ~ /\. {
        deny all;
    }

    # 自定义配置--开始

    # 自定义配置--结束

    access_log  /home/wwwlogs/default.log main;
    error_log   /home/wwwlogs/default.error.log;
}
EOF
    return 0
}

Install_Nginx()
{
    Nginx_Version="${Nginx_Ver#nginx-}"
    local nginx_conf_stack nginx_conf_kept='n'

    Echo_Blue "[+] 正在安装 ${Nginx_Ver}... "
    # 安装前的配置状态决定是否保留用户现有 nginx.conf：
    # make install 不会覆盖已存在的配置，安装后再判断已区分不出新旧。
    Nginx_Conf_Preexisting='n'
    [ -s /usr/local/nginx/conf/nginx.conf ] && Nginx_Conf_Preexisting='y'
    groupadd www
    useradd -s /sbin/nologin -g www www

    cd "${cur_dir}/src" || return 1
    Install_Nginx_Openssl
    Install_Nginx_Lua
    # 依赖缺失时模块不参与编译，Ngx_Brotli 置空使后续配置写入保持一致。
    if ! Install_Ngx_Brotli; then
        Echo_Red "ngx_brotli 依赖不满足，本次安装跳过 Brotli 模块。"
        Ngx_Brotli=""
    fi
    Install_Ngx_CachePurge
    Install_Ngx_FancyIndex
    Tar_Cd ${Nginx_Ver}.tar.gz ${Nginx_Ver}
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
    Make_Install || exit 1
    cd ../

    ln -sf /usr/local/nginx/sbin/nginx /usr/bin/nginx

    cd "${cur_dir}" || return 1
    # 单独安装 Nginx 时 Stack 是子命令名而不是栈名，必须按机器上已装的栈选模板，
    # 否则会用 LNMP 模板覆盖 LNMPA 的配置，并且不再提供反代包含文件。
    nginx_conf_stack="${Stack}"
    case "${nginx_conf_stack}" in
    lnmp|lnmpa|lamp) ;;
    *)
        Check_Stack
        case "${Get_Stack}" in
        lnmpa) nginx_conf_stack='lnmpa' ;;
        lnmp)  nginx_conf_stack='lnmp' ;;
        esac
        # 已有配置且识别不出栈时保留原文件，不用模板覆盖用户配置。
        if [ "${Get_Stack:-}" = "unknow" ] && [ "${Nginx_Conf_Preexisting:-n}" = "y" ]; then
            nginx_conf_kept='y'
            Echo_Yellow "识别不出当前安装的栈，已保留现有 /usr/local/nginx/conf/nginx.conf。"
            Echo_Yellow "如需改用随包模板，请对照 conf/nginx.conf 或 conf/nginx_a.conf 手工调整。"
        fi
        ;;
    esac

    if [ "${nginx_conf_kept}" != "y" ]; then
        rm -f /usr/local/nginx/conf/nginx.conf
        if [ "${nginx_conf_stack}" = "lnmpa" ]; then
            \cp conf/nginx_a.conf /usr/local/nginx/conf/nginx.conf
        else
            \cp conf/nginx.conf /usr/local/nginx/conf/nginx.conf
        fi
    fi
    # 站点配置引用这两个文件，缺失会让 nginx -t 直接失败。
    if [ "${nginx_conf_stack}" = "lnmpa" ] || [ "${Get_Stack:-}" = "lnmpa" ]; then
        Write_Nginx_Proxy_Conf /usr/local/nginx/conf y || exit 1
    else
        Write_Nginx_Proxy_Conf /usr/local/nginx/conf n || exit 1
    fi
    \cp -ra conf/rewrite /usr/local/nginx/conf/
    \cp conf/pathinfo.conf /usr/local/nginx/conf/pathinfo.conf
    \cp conf/enable-php.conf /usr/local/nginx/conf/enable-php.conf
    \cp conf/enable-php-pathinfo.conf /usr/local/nginx/conf/enable-php-pathinfo.conf
    \cp -ra conf/example /usr/local/nginx/conf/example
    if [ "${Enable_Nginx_Lua}" = 'y' ]; then
        if ! grep -q 'lua_package_path "/usr/local/nginx/lib/lua/?.lua";' /usr/local/nginx/conf/nginx.conf; then
            sed -i "/server_tokens off;/i\    lua_package_path \"/usr/local/nginx/lib/lua/?.lua\";\n" /usr/local/nginx/conf/nginx.conf
        fi
        # cjson.so 通过 cpath 加载，末尾的 ";;" 保留 LuaJIT 默认搜索路径。
        if ! grep -q 'lua_package_cpath' /usr/local/nginx/conf/nginx.conf; then
            sed -i "/server_tokens off;/i\    lua_package_cpath \"/usr/local/luajit/lib/lua/5.1/?.so;;\";\n" /usr/local/nginx/conf/nginx.conf
        fi
        # 编译阶段已检查 Lua 运行库，无需在公网默认站点暴露 /lua 自检接口。
    elif grep -q 'location /lua' /usr/local/nginx/conf/nginx.conf; then
        # 未编译 ngx_lua 时删除 /lua 示例，避免 nginx -t 报未知指令；
        # 同一 server 中的状态接口和日志配置不受影响。
        sed -i '/location \/lua/,/^[[:space:]]*}[[:space:]]*$/d' /usr/local/nginx/conf/nginx.conf
    fi
    # 启用已编译的 Brotli 模块；静态 Brotli 与 gzip 由浏览器协商选择。
    # 条件取实际参与编译的 Ngx_Brotli，避免模块缺失时写入未知指令。
    if [ -n "${Ngx_Brotli}" ] && ! grep -q '^\s*brotli on;' /usr/local/nginx/conf/nginx.conf; then
        sed -i "/gzip on;/i\    brotli on;\n    brotli_static on;\n    brotli_comp_level 6;\n    brotli_min_length 1k;\n    brotli_types text/plain text/css application/json application/javascript application/x-javascript text/javascript application/xml application/xml+rss image/svg+xml;\n" /usr/local/nginx/conf/nginx.conf
    fi

    mkdir -p ${Default_Website_Dir}
    mkdir -p /home/wwwlogs
    chown root:root /home/wwwlogs
    chmod 755 /home/wwwlogs

    chown -R www:www ${Default_Website_Dir}
    chmod 755 ${Default_Website_Dir}

    Write_Nginx_Default_VHost /usr/local/nginx/conf || exit 1

    if [ "${Stack}" = "lnmp" ]; then
        # 重复安装时旧文件可能仍带 immutable，不先解除就写不进新的 open_basedir。
        [ -f "${Default_Website_Dir}/.user.ini" ] && \
            chattr -i "${Default_Website_Dir}/.user.ini" 2>/dev/null
        if ! cat >"${Default_Website_Dir}/.user.ini"<<EOF
open_basedir=${Default_Website_Dir}:/tmp/:/proc/
EOF
        then
            Echo_Red "错误：写入 ${Default_Website_Dir}/.user.ini 失败，默认站点缺少 open_basedir 限制。"
            exit 1
        fi
        chmod 644 "${Default_Website_Dir}/.user.ini"
        # immutable 是加固项，置不上不中断安装，但必须让用户看到。
        if ! chattr +i "${Default_Website_Dir}/.user.ini" 2>/dev/null; then
            Echo_Yellow "警告：无法为 ${Default_Website_Dir}/.user.ini 设置 immutable 属性。"
            Echo_Yellow "该文件可被站点内的写入覆盖，可稍后手工执行："
            Echo_Yellow "  chattr +i ${Default_Website_Dir}/.user.ini"
        fi
        cat >>/usr/local/nginx/conf/fastcgi.conf<<EOF
fastcgi_param PHP_ADMIN_VALUE "open_basedir=\$document_root/:/tmp/:/proc/";
EOF
    fi

    \cp init.d/init.d.nginx /etc/init.d/nginx
    \cp init.d/nginx.service /etc/systemd/system/nginx.service
    chmod +x /etc/init.d/nginx

    if [ "${SelectMalloc}" = "3" ]; then
        if [ -L /usr/local/nginx/var/tcmalloc ] ||
           ! mkdir -p /usr/local/nginx/var/tcmalloc ||
           ! chown www:www /usr/local/nginx/var/tcmalloc ||
           ! chmod 0750 /usr/local/nginx/var/tcmalloc; then
            Echo_Red "无法安全创建 TCMalloc profile 目录。"
            return 1
        fi
        sed -i '/nginx.pid/a\
google_perftools_profiles /usr/local/nginx/var/tcmalloc;' /usr/local/nginx/conf/nginx.conf
    fi

}
