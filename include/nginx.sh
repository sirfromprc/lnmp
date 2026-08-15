#!/usr/bin/env bash

Install_Nginx_Openssl()
{
    if [ "${Enable_Nginx_Openssl}" = 'y' ]; then
        if [ ! -n "${Nginx_Version}" ]; then
            Nginx_Version=$(echo ${Nginx_Ver} | sed "s/nginx-//")
        fi
        # 保留的 nginx 版本均 >= 1.13，统一使用现代 OpenSSL。
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
        cd ${cur_dir}/src
        # Lua 组件从上游官方 GitHub 仓库获取
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
        # 这两个只解压不编译，nginx configure 时用 --add-module 指过去；
        # 解压失败就没有模块目录，configure 一定挂，所以这里直接停。
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
        cd ${cur_dir}/src
        rm -rf ${cur_dir}/src/${Luajit_Ver}
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

        # 两个纯 Lua 库，make install 只是拷 .lua 文件，失败通常意味着
        # 解压目录结构不符合预期时立即中止，避免在 nginx 启动阶段才失败。
        Tar_Cd ${LuaRestyCore}.tar.gz ${LuaRestyCore}
        make install PREFIX=/usr/local/nginx || { Echo_Red "安装 ${LuaRestyCore} 失败"; exit 1; }
        cd -
        Tar_Cd ${LuaRestyLrucache}.tar.gz ${LuaRestyLrucache}
        make install PREFIX=/usr/local/nginx || { Echo_Red "安装 ${LuaRestyLrucache} 失败"; exit 1; }
        cd -

        Install_Lua_Cjson
        Install_Lua_Resty_Libs

        #
        # 按模块能不能脱离 nginx 运行，分两类检查：
        #
        #   全部 lua-resty-*（.lua）  只做语法编译（loadfile 编译但不执行 chunk）
        #   cjson（.so）              纯 C 模块，不碰 ngx，可以真正 require
        #
        # 注意：不要以为「只有 resty.core 依赖 ngx」： resty.lrucache 也在模块顶层
        #   就访问它（lrucache.lua:9）。这一族库的惯例就是在 main chunk 里
        #   `local ngx = ngx` 之类，所以没有一个能在裸 luajit 里 require。
        #
        # .lua 的运行期验证只能在 nginx 起来之后做，
        # nginx.conf 里的 location /lua 就是为此准备的。
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
                cd ${cur_dir}/src
                Download_Files https://downloads.sourceforge.net/pcre/${Pcre_Ver}.tar.bz2 ${Pcre_Ver}.tar.bz2
                Require_File "${Pcre_Ver}.tar.bz2" "PCRE"
                Tar_Cd ${Pcre_Ver}.tar.bz2
            else
                Nginx_Module_Lua="--with-ld-opt=-Wl,-rpath,/usr/local/luajit/lib --add-module=${cur_dir}/src/${LuaNginxModule} --add-module=${cur_dir}/src/${NgxDevelKit}"
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# Install_Lua_Cjson — 编译 lua-cjson（C 扩展，产出 cjson.so）
#
# 与其他 lua-resty-* 不同，cjson 有 C 代码，必须针对 LuaJIT 的头文件编译，
# 装进 LuaJIT 自己的 cmodule 目录，再由 nginx.conf 的 lua_package_cpath 引用。
# 用 openresty 的 fork 而非 mpx/lua-cjson：前者才跟 LuaJIT 与 resty 生态配套。
# ---------------------------------------------------------------------------
Install_Lua_Cjson()
{
    cd ${cur_dir}/src
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
    cd ${cur_dir}/src
    rm -rf ${cur_dir}/src/${LuaCjson}
}

# ---------------------------------------------------------------------------
# Install_Lua_Resty_Libs — 安装纯 Lua 的 resty 库
#
# 这些库没有 C 代码，装法完全一致（make install PREFIX=/usr/local/nginx），
# 故用一张表驱动，加库只需往 version.sh 和这张表里各加一行。
# 它们不参与 nginx 编译，单个装失败不影响 nginx 可用性，因此这里不用
# Require_File 硬失败，只在下载不到时给出警告并继续。
# ---------------------------------------------------------------------------
Install_Lua_Resty_Libs()
{
    local lib repo
    cd ${cur_dir}/src

    for lib in "${LuaRestyLock}" "${LuaRestyString}" "${LuaRestyRedis}" \
               "${LuaRestyMysql}" "${LuaRestyUpload}" "${LuaRestyWebsocket}" \
               "${LuaRestyDns}" "${LuaRestyMemcached}" "${LuaRestyLimitTraffic}"; do
        # lua-resty-redis-0.33 → 仓库名 lua-resty-redis，tag v0.33
        # 正则要能吃掉预发布后缀：lua-resty-core-0.1.34rc3 的版本段是
        # "0.1.34rc3" 而不是 "0.1.34"，只匹配数字和点会漏掉 rc3，
        # 否则会将整个字符串错误识别为仓库名。
        repo=$(echo "${lib}" | sed -E 's/-[0-9][0-9.]*([a-zA-Z]+[0-9]*)?$//')
        Echo_Blue "[+] 正在安装 ${lib}... "
        Download_Files https://github.com/openresty/${repo}/archive/refs/tags/v${lib##${repo}-}.tar.gz ${lib}.tar.gz
        if [ ! -s "${cur_dir}/src/${lib}.tar.gz" ]; then
            Echo_Red "${lib} 下载失败，跳过（不影响 nginx 本体）"
            continue
        fi
        Tar_Cd ${lib}.tar.gz ${lib}
        make install PREFIX=/usr/local/nginx
        cd ${cur_dir}/src
        rm -rf ${cur_dir}/src/${lib}
    done
}

# ---------------------------------------------------------------------------
# Install_Ngx_Brotli — Brotli 压缩模块
#
# 上游只有一个 v1.0.0rc tag，实践中一律用 master。
# 关键点：GitHub 的 archive 包不含 git 子模块，而 ngx_brotli 的
# deps/brotli 正是子模块。所幸其 config 会先找系统的 libbrotlienc/dec，
# 使用系统库时不需要子模块，因此依赖清单包含 libbrotli-dev / brotli-devel。
# ---------------------------------------------------------------------------
Install_Ngx_Brotli()
{
    if [ "${Enable_Ngx_Brotli}" = 'y' ]; then
        Echo_Blue "[+] 正在安装 ngx_brotli... "
        cd ${cur_dir}/src
        Download_Files https://github.com/google/ngx_brotli/archive/${NgxBrotli_Commit}.tar.gz ${NgxBrotli_Ver}.tar.gz
        Require_File "${NgxBrotli_Ver}.tar.gz" "ngx_brotli"
        rm -rf ${cur_dir}/src/${NgxBrotli_Ver}
        tar zxf ${NgxBrotli_Ver}.tar.gz

        # ngx_brotli 需要 brotli 库，且只认自己 deps/ 下的固定路径。
        #
        # 它的 filter/config 写死了：
        #     brotli="$ngx_addon_dir/deps/brotli/c"
        #     [ ! -f "$brotli/include/brotli/encode.h" ] && exit 1
        # 既没有 pkg-config 检测，也没有 USE_SYSTEM_BROTLI 之类的开关 ：
        # 上游 master 至今（2026-08 复核）都是如此。而 GitHub 的 archive 包
        # 不含 git 子模块，解压出来的 deps/brotli 是个空目录，
        # 于是 nginx 的 configure 将以
        #     error: Brotli library is missing from .../deps/brotli/c directory
        # 中止。原注释说「系统装了 libbrotli-dev 就用系统库」是错的，
        # 装了也不会被看见。
        #
        # 这里把系统 brotli 的头文件与库目录软链成它期望的结构：
        #   deps/brotli/c/include/brotli → /usr/include/brotli
        #   deps/brotli/out              → 系统库目录
        # config 里的 ngx_module_libs 是 "-L<out> -lbrotlienc -lbrotlicommon"，
        # 链接器在系统库目录里会优先选到 .so，于是 nginx 动态链接系统库，
        # 发行版推 brotli 安全更新时不必重编 nginx。
        Link_System_Brotli || return 1

        Ngx_Brotli="--add-module=${cur_dir}/src/${NgxBrotli_Ver}"
    fi
}

# ---------------------------------------------------------------------------
# Link_System_Brotli — 把系统 brotli 伪装成 ngx_brotli 的 deps 子模块
#
# 用 `gcc -print-file-name=` 定位库目录，而不是硬编码
# /usr/lib/x86_64-linux-gnu（Debian）或 /usr/lib64（RHEL）：
# 前者会问编译器自己的搜索路径，跨发行版、跨架构都不用改。
# 找不到时明确报错并给出可执行的两条出路，不静默降级。
# ---------------------------------------------------------------------------
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

    # 优先共享库（能跟随发行版更新），退而求其次用静态库
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

# ---------------------------------------------------------------------------
# Install_Ngx_CachePurge — 缓存清除模块（proxy_cache_purge 等指令）
# ---------------------------------------------------------------------------
Install_Ngx_CachePurge()
{
    if [ "${Enable_Ngx_CachePurge}" = 'y' ]; then
        Echo_Blue "[+] 正在安装 ${NgxCachePurge_Ver}... "
        cd ${cur_dir}/src
        Download_Files https://github.com/FRiCKLE/ngx_cache_purge/archive/${NgxCachePurge_Ver#ngx_cache_purge-}.tar.gz ${NgxCachePurge_Ver}.tar.gz
        Require_File "${NgxCachePurge_Ver}.tar.gz" "ngx_cache_purge"
        rm -rf ${cur_dir}/src/${NgxCachePurge_Ver}
        tar zxf ${NgxCachePurge_Ver}.tar.gz
        Ngx_CachePurge="--add-module=${cur_dir}/src/${NgxCachePurge_Ver}"
    fi
}

Install_Ngx_FancyIndex()
{
    if [ "${Enable_Ngx_FancyIndex}" = 'y' ]; then
        echo "正在为 Nginx 安装 FancyIndex 模块..."
        cd ${cur_dir}/src
        Download_Files https://github.com/aperezdc/ngx-fancyindex/releases/download/v${NgxFancyIndex_Ver#ngx-fancyindex-}/${NgxFancyIndex_Ver}.tar.xz ${NgxFancyIndex_Ver}.tar.xz
        Require_File "${NgxFancyIndex_Ver}.tar.xz" "ngx-fancyindex"

        Tar_Cd ${NgxFancyIndex_Ver}.tar.xz
        Ngx_FancyIndex="--add-module=${cur_dir}/src/${NgxFancyIndex_Ver}"
    fi
}

# ---------------------------------------------------------------------------
# Write_Nginx_Default_VHost — 生成 Nginx/OpenResty 共用的公网静态兜底站点
# ---------------------------------------------------------------------------
Write_Nginx_Default_VHost()
{
    local conf_dir="${1:-/usr/local/nginx/conf}"
    local listen_extra=''
    local uname_r demo_php_block

    uname_r=$(uname -r)
    if echo "${uname_r}" | grep -Eq '^3\.(9|1[0-9])|^[4-9]\.'; then
        listen_extra=' reuseport'
    fi

    # LNMPA 下 default 的 PHP 由 Apache 执行，nginx 只做反代；其余栈直连 php-fpm。
    if [ "${Stack}" = 'lnmpa' ]; then
        demo_php_block='            proxy_pass http://127.0.0.1:88;
            include proxy.conf;'
    else
        demo_php_block='            try_files $uri =404;
            fastcgi_pass  unix:/tmp/php-cgi.sock;
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

        # phpMyAdmin 的访问入口。该片段由安装脚本按开关生成或删除，
        # 开启时片段会同时带入 PHP/反代配置；关闭时 default 保持静态。
        include phpmyadmin.*.conf;

        # phpinfo / redis / memcached 三个演示页由 Enable_PHPInfo_Page、
        # Enable_Redis_Test_Page、Enable_Memcached_Test_Page 决定是否写入本目录，
        # 默认都不写。正则 location 按出现顺序匹配，本条在下面拒绝 PHP 的规则
        # 之前，因此这三个固定文件名可执行；开关关闭时文件不存在，请求按 404
        # 处理，不需要按开关改配置。
        location ~ ^/(phpinfo|redis|memcached)\.php\$ {
${demo_php_block}
        }

        # default 是静态兜底站点，除上面三个演示页外一律不执行 PHP，
        # 避免源码被当作静态文件下载。phpMyAdmin 片段用 ^~ 前缀 location
        # 自带 PHP 处理，前缀匹配优先于本正则，因此启用 phpMyAdmin 不会让
        # 根目录下的其它 .php 变得可执行。
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

        access_log  /home/wwwlogs/default.log main;
        error_log   /home/wwwlogs/default.error.log;
    }
EOF
    return 0
}

Install_Nginx()
{
    Echo_Blue "[+] 正在安装 ${Nginx_Ver}... "
    groupadd www
    useradd -s /sbin/nologin -g www www

    cd ${cur_dir}/src
    Install_Nginx_Openssl
    Install_Nginx_Lua
    Install_Ngx_Brotli
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

    rm -f /usr/local/nginx/conf/nginx.conf
    cd ${cur_dir}
    if [ "${Stack}" = "lnmpa" ]; then
        \cp conf/nginx_a.conf /usr/local/nginx/conf/nginx.conf
        \cp conf/proxy.conf /usr/local/nginx/conf/proxy.conf
        \cp conf/proxy-pass-php.conf /usr/local/nginx/conf/proxy-pass-php.conf
    else
        \cp conf/nginx.conf /usr/local/nginx/conf/nginx.conf
    fi
    \cp -ra conf/rewrite /usr/local/nginx/conf/
    \cp conf/pathinfo.conf /usr/local/nginx/conf/pathinfo.conf
    \cp conf/enable-php.conf /usr/local/nginx/conf/enable-php.conf
    \cp conf/enable-php-pathinfo.conf /usr/local/nginx/conf/enable-php-pathinfo.conf
    \cp -ra conf/example /usr/local/nginx/conf/example
    if [ "${Enable_Nginx_Lua}" = 'y' ]; then
        if ! grep -q 'lua_package_path "/usr/local/nginx/lib/lua/?.lua";' /usr/local/nginx/conf/nginx.conf; then
            sed -i "/server_tokens off;/i\        lua_package_path \"/usr/local/nginx/lib/lua/?.lua\";\n" /usr/local/nginx/conf/nginx.conf
        fi
        # cjson 是 C 模块（cjson.so），走 cpath 而不是 path；装在 LuaJIT 目录下。
        # 末尾的 ";;" 表示保留 LuaJIT 的默认搜索路径。
        if ! grep -q 'lua_package_cpath' /usr/local/nginx/conf/nginx.conf; then
            sed -i "/server_tokens off;/i\        lua_package_cpath \"/usr/local/luajit/lib/lua/5.1/?.so;;\";\n" /usr/local/nginx/conf/nginx.conf
        fi
        # Lua 运行库已经在编译阶段检查；不再把 /lua 自检接口注入 LNMPA 的
        # 公网 default_server，避免破坏默认静态站点的边界。
    elif grep -q 'location /lua' /usr/local/nginx/conf/nginx.conf; then
        # 关了 Lua，nginx 就没编 ngx_lua 模块；LNMP/LNMPA 的管理端口里
        # 自带的 /lua 示例都会让 nginx -t 直接报未知指令。
        # 只删这一个 location 块，同一 server 里的 nginx_status 和
        # access_log 不受影响。
        sed -i '/location \/lua/,/^[[:space:]]*}[[:space:]]*$/d' /usr/local/nginx/conf/nginx.conf
    fi
    # Brotli：编进去了就同时在配置里开启，否则模块装了却没生效。
    # brotli_static on 会优先送同名 .br 文件；对已 gzip 的响应两者互不冲突，
    # 浏览器按 Accept-Encoding 协商。
    if [ "${Enable_Ngx_Brotli}" = 'y' ] && ! grep -q '^\s*brotli on;' /usr/local/nginx/conf/nginx.conf; then
        sed -i "/gzip on;/i\        brotli on;\n        brotli_static on;\n        brotli_comp_level 6;\n        brotli_min_length 1k;\n        brotli_types text/plain text/css application/json application/javascript application/x-javascript text/javascript application/xml application/xml+rss image/svg+xml;\n" /usr/local/nginx/conf/nginx.conf
    fi

    mkdir -p ${Default_Website_Dir}
    mkdir -p /home/wwwlogs
    chown root:root /home/wwwlogs
    chmod 755 /home/wwwlogs

    chown -R www:www ${Default_Website_Dir}
    chmod 755 ${Default_Website_Dir}

    Write_Nginx_Default_VHost /usr/local/nginx/conf || exit 1

    if [ "${Stack}" = "lnmp" ]; then
        cat >${Default_Website_Dir}/.user.ini<<EOF
open_basedir=${Default_Website_Dir}:/tmp/:/proc/
EOF
        chmod 644 ${Default_Website_Dir}/.user.ini
        chattr +i ${Default_Website_Dir}/.user.ini
        cat >>/usr/local/nginx/conf/fastcgi.conf<<EOF
fastcgi_param PHP_ADMIN_VALUE "open_basedir=\$document_root/:/tmp/:/proc/";
EOF
    fi

    \cp init.d/init.d.nginx /etc/init.d/nginx
    \cp init.d/nginx.service /etc/systemd/system/nginx.service
    chmod +x /etc/init.d/nginx

    if [ "${SelectMalloc}" = "3" ]; then
        mkdir /tmp/tcmalloc
        chown -R www:www /tmp/tcmalloc
        sed -i '/nginx.pid/a\
google_perftools_profiles /tmp/tcmalloc;' /usr/local/nginx/conf/nginx.conf
    fi

}
