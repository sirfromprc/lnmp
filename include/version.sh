#!/usr/bin/env bash

# 版本号维护说明
# 所有版本号都必须对应上游官方当前实际可下载的文件，不能凭命名规律推导。
# 多个上游只保留当前点版本（nginx.org、cdn.mysql.com/Downloads、
# downloads.apache.org），版本一过期就是 404。
#
# 修改本文件后必须执行：bash t/probe_urls.sh
# 该脚本只发 HEAD 请求，会逐条报出 404。同时记得同步 src/checksums.sha256，
# 否则 fail-closed 校验会中止安装。

# --- 少数兼容路径使用的编译依赖 ---
Autoconf_Ver='autoconf-2.13'
Libiconv_Ver='libiconv-1.17'

Freetype_New_Ver='freetype-2.13.0'
Curl_Ver='curl-7.62.0'
Pcre_Ver='pcre-8.45'

Libzip_Ver='libzip-1.3.2'

Openssl_New_Ver='openssl-3.5.7'

# --- MySQL 源码编译依赖的 Boost 校验版本 ---
# 这两个变量仅供下载探测和校验清单维护脚本使用。
# MySQL 8.x 安装仍从已下载源码的 cmake/boost.cmake 读取实际所需版本，
# 不使用此处固定值选择安装依赖。
Boost_Ver='boost_1_77_0'
Boost_New_Ver='boost_1_84_0'

# --- 内存分配器（可选）---
Jemalloc_Ver='jemalloc-5.3.1'
TCMalloc_Ver='gperftools-2.18.1'
Libunwind_Ver='libunwind-1.8.3'

# --- nginx 本体 ---
# nginx.org 只保留每个分支的近期点版本。
# 1.30 是 stable 分支（次版本号为偶数），1.31 是 mainline，此处跟 stable。
Nginx_Ver='nginx-1.30.4'
Nghttp2_Ver='nghttp2-1.70.0'

# --- OpenResty（与 nginx 官方版互斥，见 include/openresty.sh）---
#
# 此版本号仅用于源码编译；apt/yum 安装使用上游仓库当前版本。
#
# OpenResty 不提供 sha256 校验文件，只提供 PGP 签名（.tar.gz.asc），
# 所以它不进 src/checksums.sha256，改由 Verify_OpenResty_Signature 验签。
# 升级版本号时无需更新校验清单，但要确认新版本的 .asc 仍由同一密钥签名。
#
# OpenResty 1.31.1.1 为稳定版，内置 Nginx 1.31.1。
OpenResty_Ver='openresty-1.31.1.1'
# 源码编译时追加给 ./configure 的额外参数（如 --add-module=...）
OpenResty_Modules_Options="${OpenResty_Modules_Options:-}"

# --- nginx 第三方模块 ---
# Lua 组件版本互相耦合：lua-nginx-module 与 lua-resty-core 必须配套，
# 对应关系见 lua-nginx-module 各 release 的 README。
Luajit_Ver='luajit2-2.1-20260701'
LuaNginxModule='lua-nginx-module-0.10.31'
LuaRestyCore='lua-resty-core-0.1.34rc3'
LuaRestyLrucache='lua-resty-lrucache-0.15'
LuaRestyLock='lua-resty-lock-0.09'
LuaCjson='lua-cjson-2.1.0.19'
# 以下纯 Lua 库随 Enable_Nginx_Lua 安装。
# 它们全都只有 .lua 文件，make install PREFIX=/usr/local/nginx 即可，
# 不作为 Nginx 编译模块加入。
LuaRestyString='lua-resty-string-0.19'
LuaRestyRedis='lua-resty-redis-0.33'
LuaRestyMysql='lua-resty-mysql-0.31'
LuaRestyUpload='lua-resty-upload-0.11'
LuaRestyWebsocket='lua-resty-websocket-0.14'
LuaRestyDns='lua-resty-dns-0.23'
LuaRestyMemcached='lua-resty-memcached-0.18'
LuaRestyLimitTraffic='lua-resty-limit-traffic-0.09'
NgxDevelKit='ngx_devel_kit-0.3.4'
NgxFancyIndex_Ver='ngx-fancyindex-0.6.0'
# ngx_brotli 固定到具体提交，避免 master 归档变化导致 SHA256 漂移。
# GitHub 归档不包含 deps/brotli 子模块，构建时由 Link_System_Brotli 映射
# 系统 Brotli 头文件和库，因此需要 libbrotli-dev 或 brotli-devel。

NgxBrotli_Commit='a71f9312c2deb28875acc7bacfdd5695a111aa53'
NgxBrotli_Ver="ngx_brotli-${NgxBrotli_Commit}"
# ngx_cache_purge 使用 FRiCKLE 仓库的 2.3 版本。
NgxCachePurge_Ver='ngx_cache_purge-2.3'

# --- Apache（仅 lnmpa / lamp 用）---
# downloads.apache.org 只留当前版，故下载改走 archive.apache.org。
APR_Ver='apr-1.7.6'
APR_Util_Ver='apr-util-1.6.4'

Pureftpd_Ver='pure-ftpd-1.0.54'

# 数据库 / PHP / Apache / phpMyAdmin 的版本映射已移至 include/profile.sh。
# 那里是编号到版本语义的唯一映射表，由 Set_DB_Profile / Set_PHP_Profile /
# Set_Apache_Profile 在菜单选择完成后填充以下变量：
#   Mysql_Ver / Mariadb_Ver / Php_Ver / Apache_Ver / PhpMyAdmin_Ver

# --- 图像处理 ---
ImageMagick_Ver='ImageMagick-7.1.2-29'
Imagick_Ver='imagick-3.8.1'

# --- 缓存 ---
ZendOpcache_Ver='zendopcache-7.0.5'
Redis_Stable_Ver='redis-8.10.0'
PHPRedis_Ver='redis-6.3.0'
Memcached_Ver='memcached-1.6.39'
Libmemcached_Ver='libmemcached-1.0.18'
PHPMemcached_Ver='memcached-2.2.0'
PHP7Memcached_Ver='memcached-3.1.5'
PHP8Memcached_Ver='memcached-3.4.0'
PHPMemcache_Ver='memcache-3.0.8'
PHP7Memcache_Ver='memcache-4.0.5.2'
PHP8Memcache_Ver='memcache-8.2'

# --- PHP 扩展 ---
PHPOldApcu_Ver='apcu-4.0.11'
PHPNewApcu_Ver='apcu-5.1.28'
PHPApcu_Bc_Ver='apcu_bc-1.0.5'
PHPSodium_Ver='libsodium-2.0.23'
PHPSwoole_Ver='swoole-6.2.2'
# igbinary：phpredis 的序列化后端，必须先于 phpredis 编译。
# 3.2.17 目前只有 RC，故取最后一个正式版。
PHPIgbinary_Ver='igbinary-3.2.16'
