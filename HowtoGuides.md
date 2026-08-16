# LNMP 2.3 从零搭建 WordPress 生产环境

> 主安装、建站、WordPress、Redis、HTTPS 和备份流程已在
> **Debian 12、Debian 13 / x86_64 / 6G 内存 / 4 核** 上实测，文中的“实测输出”来自
> 这些环境。1~2GB、3~4GB 和 5GB 以上的容量表依据当前配置生成逻辑与内存预算给出
> 保守起点，未对每个容量档进行同等真机压测。
> LNMP 环境组合：nginx 1.30.4 + PHP 8.3.33 + MySQL 8.4.7 或
> MariaDB 11.8.8（均为官方通用二进制）+ Redis 8.10.0 + phpMyAdmin 5.2.3 +
> WordPress 7.0.3；WordPress 主链路已分别在两种数据库上完成。
> LAMP 与 LNMPA 另用 Apache 2.4.68 + PHP 8.3.33 完整安装验证。
>
> 与其他文档的分工：本文讲**怎么做**；`README.md` 讲各组件与开关的含义；
> `changelog.md` 记录本包相对上游做过哪些改动以及为什么。

---

## 目录

1. [开始之前](#一开始之前)
2. [安装 LNMP](#二安装-lnmp)
3. [安装 Redis](#三安装-redis)
4. [创建站点](#四创建站点)
5. [部署 WordPress](#五部署-wordpress)
6. [WordPress 专项调优](#六wordpress-专项调优)
7. [配置 HTTPS](#七配置-https)
8. [日常运维命令](#八日常运维命令)
9. [故障排查](#九故障排查)
10. [安全基线](#十安全基线)
11. [依据与校准方法](#十一依据与校准方法)

---

## 一、开始之前

### 1.1 硬性要求

| 项 | 要求 | 说明 |
|---|---|---|
| 权限 | **root 用户** | `install.sh` 开头检查 `id -u`，非 root 立即退出；脚本需要写系统目录、服务和防火墙 |
| 系统 | Debian 12 / 13，Ubuntu 18.04+，EL 8+ | 主要验证目标是 Debian 系 |
| 架构 | x86_64 为主线 | 当前项目只为 x86_64 通用数据库包提供完整自动校验路径；其他架构回退源码编译，上游是否另有包不等于本项目可安全安装 |
| 内存 | **≥ 2G** | 编译 nginx（含 Lua/Brotli/OpenSSL）与 PHP 很吃内存。过小内存编译可能会失败 |
| 磁盘 | 通用二进制安装 ≥ 10G；数据库源码编译 ≥ 15G | 源码编译目录峰值已超过 7G，还要给安装目录、日志、数据和备份留空间 |
| 机器状态 | **必须是干净机器** | 安装会卸载系统自带的 nginx/php/apache/mysql 并接管防火墙 |
| 网络 | 能访问 nginx.org / php.net / cdn.mysql.com / github.com | 全部走上游官方源，不考虑国内能否访问问题 |

> 注意：**不要在已有业务的服务器上直接跑。** 脚本会移除系统包管理器装的
> Web/DB 组件，并写入 nftables 规则。
>
> 本文命令均按**直接登录 root** 编写，因此不重复使用 `sudo`。
> 开始前执行 `id -u` 应输出 `0`；普通用户运行安装入口会得到“必须使用 root 用户”
> 的错误并立即退出。

安装前应记录系统、资源、时间同步和监听端口。以下检查均为只读，结果应随部署记录保存：

```bash
cat /etc/os-release
uname -m
free -h
df -h / /usr/local /home 2>/dev/null
df -i / /usr/local /home 2>/dev/null
timedatectl status
ss -lntup
```

`uname -m` 主线应为 `x86_64`；磁盘空间和 inode 任一不足都会导致编译或解压失败；
时间未同步会影响 TLS、软件仓库和证书签发。`ss` 的结果用于确认 80、443、3306 等端口
没有被既有服务占用。云主机还需单独核对安全组，脚本只能管理本机防火墙。

### 1.2 编译耗时参考

4 核 6G 的机器上，从零完整安装约 **9 分钟**（MySQL 走二进制不编译）。
如果选择源码编译 MySQL，再加 30-60 分钟，且有可能失败。

### 1.3 获取代码

```bash
# 发布地址确定后，将占位符替换为实际的 v2.3 Release 压缩包地址
wget <v2.3-release压缩包地址>
tar zxf v2.3.tar.gz
cd lnmp2.3
chmod +x install.sh addons.sh uninstall.sh upgrade.sh
id -u
# 必须输出 0
```

tar 包通常会保留可执行位，但 ZIP、面板上传或跨文件系统复制可能丢失；显式执行一次
`chmod` 可以保证后续既能用 `bash install.sh`，也能直接运行这些入口脚本。

> 优先使用 tag 或 release，而不是 `main` 分支。`main` 的内容可能在两次安装之间
> 变化，两台机器装出来的东西就不一样了。

---

## 二、安装 LNMP

### 2.1 交互式安装

```bash
bash install.sh lnmp
```

先提醒检查 `lnmp.conf`（端口、目录等）并要求输入 `y` 才继续，然后自动探测
系统实际监听的 SSH 端口：和 `lnmp.conf` 的 `SSH_Port` 对不上会直接拒绝；
一致但仍是默认的 22 会提示改端口的步骤并要求再输入一次 `y`。
之后依次会问：数据库版本 → 是否用通用二进制 → 数据库 root 密码 →
是否启用 InnoDB → PHP 版本 → Nginx/OpenResty → 内存分配器。选完会打印一份完整摘要（版本、
编译参数、即将放行/阻断的端口），要求输入 `y` 确认后才真正开始装依赖、
编译。最终确认前可用 Ctrl+C 退出并重新选择，此时尚未开始系统变更。

安装 LAMP/LNMPA 时还会询问 Apache `ServerAdmin`，这里只接受合法邮箱；空白、斜杠、
分号和配置片段会在写 Apache 配置前被拒绝。ACME 邮箱支持最长 63 位顶级域，三种栈规则一致。

### 2.2 非交互安装（站群自动部署）

常用标量选择可以用环境变量传入；OpenResty 数组选项仍需编辑 `lnmp.conf`：

```bash
read -r -s -p '数据库 root 密码: ' DB_Root_Password; echo
export DB_Root_Password
LNMP_Auto=y \
DBSelect=2 \
Bin=y \
PHPSelect=4 \
SelectMalloc=1 \
InstallInnodb=y \
Enable_PhpMyAdmin=y \
Enable_Composer=y \
bash install.sh lnmp
unset DB_Root_Password
```

参数含义：

| 变量 | 值 | 含义 |
|---|---|---|
| `LNMP_Auto` | `y` | 跳过安装前的所有交互确认（检查 lnmp.conf、SSH 端口核对、最终摘要确认） |
| `DBSelect` | `1`~`5` | 1=MySQL8.0 **2=MySQL8.4(默认)** 3=MariaDB10.11 4=MariaDB11.4 5=MariaDB11.8 |
| `Bin` | `y`/`n` | `y`=下载官方通用二进制（快，几分钟）；`n`=源码编译（慢，30-60 分钟） |
| `PHPSelect` | `1`~`6` | 1=8.0 2=8.1 3=8.2 **4=8.3(默认)** 5=8.4 6=8.5 |
| `SelectMalloc` | `1`~`3` | 1=不装 2=Jemalloc 3=TCMalloc |
| `InstallInnodb` | `y` | WordPress 必须用 InnoDB |
| `Enable_PhpMyAdmin` | `y`/`n` | **默认 `n`**（安全考虑）。要 phpMyAdmin 必须显式开启 |
| `Enable_Composer` | `y`/`n` | 默认 `y`；不需要 Composer 时设 `n`，不会下载或执行安装器 |
| `DB_Root_Password` | 字符串 | 留空则随机生成 |

> **`Enable_PhpMyAdmin` 只控制整包安装，默认仍为 `n`。** 主栈装好后如需补装，
> 显式执行 `bash install.sh phpmyadmin`；重复执行不会覆盖现有安装，升级使用
> `bash upgrade.sh phpmyadmin`。
>
> 临时不用时执行 `lnmp phpmyadmin disable` 关闭 Web 入口；需要时执行
> `lnmp phpmyadmin enable` 恢复。关闭操作保留程序、配置和随机路径，
> `lnmp phpmyadmin status` 可查看当前访问状态。
>
> 开启后，程序装在 `/usr/local/phpmyadmin`（不在网站根目录下），
> 访问路径随机生成，形如 `49763abb_phpmyadmin`。地址在安装结束时打印，
> 之后用 `lnmp status` 可以再查。安全加固见 10.1。

### 2.3 用 OpenResty 替代 nginx（可选）

OpenResty 是 nginx 的增强发行版，自带 LuaJIT 与整套 `lua-resty-*` 库。
**它与 nginx 官方版互斥**：两者都提供 nginx 二进制并监听 80/443，
不能同时装。

```bash
# 交互式：安装过程中会问「Web Server」选 2
bash install.sh lnmp

# 预先选择 OpenResty，其余项目仍按提示输入
WebSelect=2 ORMode=1 bash install.sh lnmp    # 官方仓库预编译包（不编译）
WebSelect=2 ORMode=2 bash install.sh lnmp    # 源码编译
```

两种装法的取舍：

| | `ORMode=1` 仓库包 | `ORMode=2` 源码编译 |
|---|---|---|
| 速度 | 快（不编译） | 慢（要编 LuaJIT 和一堆模块） |
| 完整性校验 | apt/yum 的 GPG 签名 | PGP 验签（随包公钥 + 指纹白名单） |
| 发行版要求 | **上游必须提供当前发行版的包** | 不挑发行版 |
| 版本 | 仓库里的当前版本 | `version.sh` 里的 `OpenResty_Ver` |
| 自定义模块 | 不能（配了会直接报错） | 能，见 2.3.1 |

> 注意：**Debian 13 (trixie) 目前只能用源码编译。**
> 2026-08 实测，OpenResty 官方 Debian 仓库只有到 bookworm(12) 为止，
> `dists/trixie/` 返回 404。官方博客虽然把 Debian 13 列进了支持列表，
> 但仓库包尚未发布。选择 `ORMode=1` 时，脚本会先探测仓库，明确报告错误并
> 建议改用源码编译，避免在 `apt-get update` 阶段才失败。
> 等上游发布 trixie 包后，无需改代码即可自动可用（探测逻辑是动态的）。

安装后**运维方式与 nginx 一致**：安装时会建立软链接
`/usr/local/nginx → /usr/local/openresty/nginx`，所以：

```bash
lnmp nginx reload               # 照常可用
lnmp vhost add                  # 照常可用
/usr/local/nginx/conf/vhost/    # 站点配置还在这里
```

OpenResty 的 Lua 路径与源码 nginx 那套不同（用它自带的 `lualib`），
安装脚本已自动配好：

```nginx
lua_package_path  "/usr/local/openresty/lualib/?.lua;;";
lua_package_cpath "/usr/local/openresty/lualib/?.so;;";
```

升级：

```bash
bash upgrade.sh openresty
```

会**按当初的安装方式自动分流**（包装的走 apt 升级、源码装的走重新编译），
无需记录初始安装方式。升级后先执行 `nginx -t`，配置检查通过后才重载服务。

### 2.3.1 OpenResty 自定义编译模块与 Lua 库

只在 `ORMode=2`（源码编译）下有效。全部配置项在 `lnmp.conf` 的 OpenResty 段：

```bash
## 每条：名称|下载地址|SHA256|类型
OpenResty_Custom_Modules=(
    "ngx_http_geoip2|https://github.com/leev/ngx_http_geoip2_module/archive/refs/tags/3.4.tar.gz|<64位SHA256>|dynamic"
)

## 不需要下载源码的 configure 参数
OpenResty_Modules_Options="--with-http_dav_module"

## 自定义 Lua 库目录（绝对路径），会加入 lua_package_path
OpenResty_Custom_Lualib="/opt/mylua"

## opm 包（OpenResty 自带的包管理器）
OpenResty_Opm_Packages=("ledgetech/lua-resty-http")

## luarocks 包，需要系统里已经装了 luarocks
OpenResty_Luarocks_Packages=("luafilesystem")
```

**四个字段**

| 字段 | 要求 |
|---|---|
| 名称 | 只允许字母数字点下划线连字符，会用作源码目录名 |
| 下载地址 | 必须 https，指向模块仓库的归档包（`.tar.gz`） |
| SHA256 | **必填**。先手工下载再 `sha256sum <文件>` 取值 |
| 类型 | `static` 编进二进制；`dynamic` 编成 `.so` |

SHA256 强制校验不是形式：这些代码会被编译进对外服务的进程，
比普通依赖更需要确认来源。校验不过直接中止，没有跳过的开关。

**dynamic 模块的加载**

`--add-dynamic-module` 只负责把 `.so` 编出来放进 `nginx/modules/`，
nginx 不会自动加载它 —— 少了 `load_module` 指令等于没装，而且不报错。
安装流程会扫描当前构建生成的 `.so`，生成
`/usr/local/openresty/nginx/conf/load_modules.conf` 并由主配置 include。

从配置中删除动态模块并重新编译后，上一版由该文件加载、当前构建未产出的 `.so`
会被清掉，不会出现"配置里删了但旧 so 还在加载"的情况；
目录里手工放的其它 `.so` 不归本包管，既不加载也不删。

**升级时的沿用**

初装成功后，这组配置会写进 `/etc/lnmp/openresty-build.conf`（600）。
`bash upgrade.sh openresty` 会读它，用同一组模块重新编译，
不必升级时再手工传一遍参数，也就不会出现"升完发现某个 location 不工作"。

优先级：当前 `lnmp.conf` 里**显式配了**就以 `lnmp.conf` 为准（表示你想改），
什么都没配才回落到记录的那一份（表示你只是忘了传）。

**Lua 库**

`OpenResty_Custom_Lualib` 指定的目录会写进 `lua_package_path` 和
`lua_package_cpath`，单独生成 `conf/lua_paths.conf` 由主配置 include，
不用每次改模板。目录不存在会自动创建。放进去的 `.lua` 直接 `require` 即可。

opm 与 luarocks 的装包失败**只告警不中止安装**，因为该结果不影响 Web 服务启动。
安装结束后应核对告警，并补装应用所需的 Lua 库。
luarocks 需要系统里先装好（`apt-get install luarocks`），本包不负责装它。

### 2.4 验证安装结果

```bash
lnmp status
nginx -v && php -v && mysql --version
```

实测输出：

```
nginx version: nginx/1.30.4
PHP 8.3.33 (cli) (built: Aug 10 2026 08:46:50) (NTS)
mysql  Ver 8.4.7 for Linux on x86_64 (MySQL Community Server - GPL)
```

选择 MariaDB 11.8 时，最后一项会显示 MariaDB 版本；项目同时保留 `mysql` 兼容入口。
本轮 Debian 13 验证覆盖：

| 栈/数据库 | 实测结果 |
|---|---|
| LNMP + MySQL 8.4.7 | WordPress 安装、首页、固定链接、REST、PHP-FPM、数据库、Redis 通过 |
| LNMP + MariaDB 11.8.8 | 同一组 WordPress 链路通过；phpMyAdmin 和数据库管理命令通过 |
| LAMP / LNMPA | Apache 正常 PHP、PATH_INFO、`.php.bak`、符号链接、default 边界和服务失败码通过 |
| Pure-FTPd | 新安装 `TLS 2`；明文登录拒绝，显式 FTPS 列目录与上传通过 |

确认编入的模块：

```bash
nginx -V 2>&1 | tr ' ' '\n' | grep -E "lua|brotli|cache_purge|http_v2|http_v3|openssl"
```

```
--add-module=.../lua-nginx-module-0.10.31
--add-module=.../ngx_brotli-a71f9312...
--add-module=.../ngx_cache_purge-2.3
--with-http_v2_module
--with-http_v3_module
--with-openssl=.../openssl-3.5.7
```

验证 Lua 确实能在真实 worker 里跑（不是只看模块编进去了）：

```bash
curl http://127.0.0.1:1008/lua
# hello world
```

### 2.5 配置总索引

本项目有三层配置，修改时先确认自己改的是哪一层：

1. 仓库根目录 `lnmp.conf`：只在安装、补装或升级时读取。安装完成后改它，正在运行的
   服务不会自动变化。
2. 安装选择变量：`DBSelect`、`PHPSelect` 等决定这一次装什么，可在命令前传入。
3. `/usr/local`、`/etc/lnmp` 和 `/etc/my.cnf` 下的运行期配置：安装后真正生效的文件。
   改完必须先做对应语法检查，再 reload/restart；升级前要备份。

#### 2.5.1 `lnmp.conf` 的全部选项

以下清单与当前 `lnmp.conf` 一一对应。标量写成 `${变量:-默认值}`，可以编辑文件，
也可以只对一次命令用同名环境变量覆盖。数组无法可靠地通过普通环境变量传递，
必须直接编辑 `lnmp.conf`。

| 选项 | 默认 | 生效范围与建议 |
|---|---:|---|
| `Nginx_Modules_Options` | 空 | 追加 Nginx configure 参数；只加入固定版本、已校验来源的模块 |
| `PHP_Modules_Options` | 空 | 追加 PHP configure 参数；先确认目标 PHP 版本仍支持该参数 |
| `MySQL_Data_Dir` | `/usr/local/mysql/var` | MySQL 数据目录；使用本机块存储，避免 NFS/对象存储 |
| `MariaDB_Data_Dir` | `/usr/local/mariadb/var` | MariaDB 数据目录；要求同上 |
| `Default_Website_Dir` | `/home/wwwroot/default` | default 兜底站目录，不是以后所有新站点的父目录 |
| `Enable_PHPInfo_Page` | `n` | 公开 phpinfo 页面；生产保持关闭 |
| `Enable_PhpMyAdmin` | `n` | 安装并映射 phpMyAdmin；更推荐按需启用、限制来源 |
| `Enable_Memcached_Test_Page` | `n` | 无鉴权演示页；生产保持关闭 |
| `Enable_Redis_Test_Page` | `n` | 无鉴权且会写 Redis 的演示页；生产保持关闭 |
| `Enable_Nginx_Openssl` | `y` | Nginx TLS 构建；公开站点保持开启 |
| `Enable_Nginx_Lua` | `y` | LuaJIT、lua-nginx-module 和常用 resty 库；不用 Lua 可设 `n` 缩短构建、减小攻击面 |
| `Enable_Ngx_Brotli` | `y` | 编译 Brotli 模块；低 CPU VPS 仍可编译，是否对响应启用由 Nginx 配置决定 |
| `Enable_Ngx_CachePurge` | `y` | 编译缓存清除模块；不使用 Nginx/FastCGI 缓存可关闭 |
| `Enable_Ngx_FancyIndex` | `n` | 目录美化索引；公开生产站一般保持关闭 |
| `Enable_Swap` | `y` | 缺少 Swap 时创建 swapfile；它只缓冲突发内存，不是增加 FPM worker 的理由 |
| `Enable_Composer` | `y` | 安装主 PHP 时同时安装 Composer；不需要时设 `n` |
| `Enable_PHP_Default_Opcache` | `y` | WordPress 必需的主要 PHP 性能层，保持开启 |
| `Enable_PHP_Default_Igbinary` | `y` | phpredis 紧凑序列化支持；使用 Redis 时建议保留 |
| `Enable_PHP_Default_Redis` | `y` | 安装 phpredis 扩展，不等于安装 Redis 服务端 |
| `Enable_PHP_Default_Imagick` | `y` | 图片处理扩展；不用 PDF/复杂图片处理时可评估关闭，WordPress 会回退 GD |
| `Enable_PHP_Exif` | `n` | 需要读取照片 EXIF 的站点再开启 |
| `Enable_PHP_Fileinfo` | `y` | 上传 MIME 检测依赖，保持开启 |
| `Enable_PHP_Ldap` | `n` | 只在对接 LDAP 时开启 |
| `Enable_PHP_Bz2` | `n` | 只在应用明确依赖 bzip2 时开启 |
| `Enable_PHP_Sodium` | `n` | PHP 8 自带 sodium 能力因构建方式而异；应用明确要求时开启并用 `php -m` 验证 |
| `Enable_PHP_Imap` | `n` | Debian 13 已移除旧 uw-imap 开发库，非邮件应用不要开启 |
| `Download_Insecure` | `n` | 关闭 TLS 校验；除临时定位证书链问题外不得开启，更不能用于生产安装 |
| `Enable_Download_Checksum` | `y` | 项目完整性校验总开关；保持开启 |
| `SSH_Port` | `22` | 只生成防火墙放行规则，不修改 sshd；必须与真实监听端口一致 |
| `DB_Port` | `3306` | 写入 `/etc/my.cnf` 并生成防火墙规则；安全依靠回环监听和来源控制，不靠换端口 |
| `DB_X_Port` | `33060` | MySQL X Protocol 端口及阻断规则；MariaDB 不使用 |
| `Redis_Port` | `6379` | 写 Redis 配置、init 脚本、测试页及防火墙规则 |
| `Memcached_Port` | `11211` | 写 init 脚本、测试页及 TCP/UDP 阻断规则 |
| `Pureftpd_Port` | `21` | FTP 控制端口 |
| `Pureftpd_Data_Port` | `20` | FTP 主动模式数据端口 |
| `Pureftpd_Passive_Min` / `Pureftpd_Passive_Max` | `20000` / `30000` | 被动端口范围；并发传输每路占一个端口，云安全组也要同步 |
| `OpenResty_Custom_Modules` | 空数组 | `名称\|HTTPS地址\|SHA256\|static/dynamic`，仅 `ORMode=2`；必须直接编辑文件 |
| `OpenResty_Modules_Options` | 空 | OpenResty 源码 configure 参数，仅 `ORMode=2` |
| `OpenResty_Custom_Lualib` | 空 | 自定义 Lua 库绝对路径，仅源码构建路径使用 |
| `OpenResty_Opm_Packages` | 空数组 | 安装的 opm 包；失败只告警，安装后要实际 `require` 验证 |
| `OpenResty_Luarocks_Packages` | 空数组 | 安装的 luarocks 包；需预装 luarocks |
| `Disable_Selinux` | `n` | 保留 SELinux；先根据 audit 日志修标签/策略，不把关闭当性能优化 |
| `CheckMirror` | `y` | `n` 跳过联网准备、源修改和 DNS 探测，并使数据库默认走源码；组件源码仍需已在 `src/` 或能下载 |

`Pureftpd_Data_Port` 当前用于防火墙规则，FTP 被动模式主要依赖端口范围。Nginx 的
80/443 不在 `lnmp.conf`：这两个端口分布在主配置、虚拟主机和证书流程里，项目明确
不提供统一改端口开关。

Pure-FTPd 的 TLS 模式不在 `lnmp.conf` 中；新安装模板固定为
`TLS 2`，运行期值在 `/usr/local/pureftpd/etc/pure-ftpd.conf`。

`MySQL_Data_Dir` / `MariaDB_Data_Dir` 是**新安装的数据落点**，不是在线迁移开关。
安装入口发现目录已存在时，会先把整个目录（含隐藏文件和数据库子目录）移动到
`/root/<数据库>-data-dir-backup<时间戳>`，再创建空目录；移动或创建失败会返回非零并停止。
已有业务迁移仍应使用逻辑备份和恢复演练，不能靠重新执行安装脚本完成。

#### `CheckMirror` 的准确作用

这个变量沿用旧名称，但它不是简单的“选择下载镜像”，也不是总联网开关。当前代码中的
影响点只有以下几类：

| `CheckMirror` | 安装准备 | 数据库 `Bin` 未指定时 | 仍然会做的事 |
|---|---|---|---|
| `y`（默认） | 执行 `Modify_Source`、NTP 对时和下载域名 DNS 探测 | 当前架构有受支持的通用二进制时默认 `Bin=y` | 安装系统依赖、下载/校验组件 |
| `n` | 跳过上述三项 | 默认 `Bin=n`，转为源码编译 | **仍会**在 Debian 清理/安装依赖时执行 `apt-get update`，仍会下载缺少的组件并做完整性校验 |

对 Debian 12/13，`Modify_Source` 本身没有改写 Debian 软件源的分支；因此 `n` 的主要实际
变化是跳过 NTP/DNS 预检，并在没有显式给 `Bin` 时把数据库改成源码编译。它不会跳过
`Deb_RemoveAMP`、`Deb_Dependent` 中的 APT 更新和包安装，也不会让 `Check_Download` 停止
访问 nginx.org、php.net、数据库上游或 GitHub。

常规联网 VPS 保持默认：

```bash
CheckMirror=y Bin=y bash install.sh lnmp
```

只有系统时间和 APT 源已由内网/镜像管理、且明确不希望脚本做联网预检时才设 `n`。
如果仍要数据库通用二进制，必须同时明确 `Bin=y`；文件不在 `src/` 时脚本照样联网下载：

```bash
CheckMirror=n Bin=y bash install.sh lnmp
```

真正离线安装还需要可用的本地 APT 仓库/缓存、全部依赖包，以及提前放入 `src/` 的全部
组件归档和相应校验/签名材料。本项目没有一个变量能自动准备这些条件。不要用
`Download_Insecure=y` 或 `Enable_Download_Checksum=n` 冒充离线兼容，这只会移除安全校验。

#### 2.5.2 当前安装选择

| 变量 | 可用值 | 建议 |
|---|---|---|
| `LNMP_Auto` | `y` | 跳过确认；自动化必须同时固定其余选择并保存退出码 |
| `WebSelect` | `1` Nginx；`2` OpenResty | WordPress 常规站选 Nginx；确实使用 Lua/OpenResty 生态再选 2 |
| `ORMode` | `1` 官方包；`2` 源码 | Debian 13 上游仓库当前没有 trixie 包，选 2 |
| `DBSelect` | `0` 不装；`1` MySQL 8.0；`2` MySQL 8.4；`3` MariaDB 10.11；`4` 11.4；`5` 11.8 | 新部署优先 MySQL 8.4 LTS 或经过应用验证的 MariaDB LTS；不要新装已 EOL 的 MySQL 8.0 |
| `Bin` | `y` 通用二进制；`n` 源码 | x86_64 默认 `y`；只有确实需要定制构建才选 `n` |
| `DB_Root_Password` | 字符串或留空 | 自动化应从受限 secret 注入；留空会随机生成到 root-only 文件 |
| `InstallInnodb` | `y` / `n` | WordPress 必须 `y` |
| `PHPSelect` | `1`~`6` 对应 PHP 8.0~8.5 | 新站优先仍在上游安全支持期且插件已兼容的 8.3/8.4；不要仅因“版本最新”跳过兼容测试 |
| `SelectMalloc` | `1` 无；`2` Jemalloc；`3` TCMalloc | VPS 默认 1；没有分配器碎片证据就不要增加变量 |
| `ApacheSelect` | 当前仅 `1`=2.4 | 只在 LNMPA/LAMP 询问；Debian 13 已实测，其它发行版仍需复验 |

#### 2.5.3 安装后的配置位置

| 范围 | 主配置位置 | 修改后验证/生效 |
|---|---|---|
| Nginx/OpenResty | `/usr/local/nginx/conf/nginx.conf` | `nginx -t && lnmp nginx reload` |
| 单站点 | `/usr/local/nginx/conf/vhost/<域名>.conf` | 同上；站点开关优先用 `lnmp vhost`/`lnmp ssl` 生成 |
| rewrite | `/usr/local/nginx/conf/rewrite/<名称>.conf` | 同上 |
| PHP 路由 | `/usr/local/nginx/conf/enable-php*.conf` | 同上；多版本 socket 必须匹配 |
| TLS 证书 | `/usr/local/nginx/conf/ssl/<域名>/` | 由 `lnmp ssl`/acme.sh 管理，不手工覆盖自动续期文件 |
| PHP | `/usr/local/php/etc/php.ini`、`/usr/local/php/etc/php-fpm.conf`、`/usr/local/php/conf.d/*.ini` | `php --ini`、`php-fpm -t`，然后 `lnmp php-fpm reload` |
| 多版本 PHP | `/usr/local/php8.x/etc/`、`/usr/local/php8.x/conf.d/` | 用该版本二进制检查；重载对应 FPM 服务 |
| MySQL/MariaDB | `/etc/my.cnf` | `mysql -e` 回读变量；需要 restart 的参数安排维护窗口 |
| Redis | `/usr/local/redis/etc/redis.conf` | Redis 没有等价的完整 `-t`；安排维护窗口重启后用日志、`CONFIG GET` 和 `INFO` 回读 |
| Memcached | `/etc/init.d/memcached` | 重启后用 `ss` 和 `stats settings` 核对监听/内存参数 |
| Pure-FTPd | `/usr/local/pureftpd/etc/pure-ftpd.conf` | 重启后核对监听端口及被动范围 |
| phpMyAdmin | `/usr/local/phpmyadmin/config.inc.php`；Web 映射 `/usr/local/nginx/conf/phpmyadmin.enable.conf` | 优先 `lnmp phpmyadmin enable\|disable\|status`；改映射后 `nginx -t` |
| OpenResty 构建记录 | `/etc/lnmp/openresty-build.conf`，运行期 Lua 路径 `/usr/local/nginx/conf/lua_paths.conf` | 升级会沿用构建记录；改 Lua 路径后 `nginx -t` |
| 备份 | `/etc/lnmp/backup.conf`、数据库凭据 `/etc/lnmp/backup-mysql.cnf` | 权限必须 600；`lnmp backup run` 后执行 `lnmp backup test` |
| Telegram | `/etc/lnmp/notify.conf` | `lnmp tgnotice --status`、`--test`；Token 文件必须 600/400 |
| 防火墙 | Debian `/etc/nftables.d/lnmp.nft`，运行期 `inet lnmp` 表 | `nft list table inet lnmp`，并从外部主机实测端口 |
| WordPress | `<站点>/wp-config.php`、`<站点>/.user.ini` | `wp config list`（有 WP-CLI 时）和真实 HTTP 请求 |
| 日志 | `/home/wwwlogs/`、`/usr/local/php/var/log/`、数据库数据目录中的错误日志、`/var/log/lnmp/backup.log` | 结合 systemd journal；不要只看单一日志 |

备份配置支持的全部字段是 `Backup_Home`、`MySQL_Dump`、`MySQL_Option_File`、
`Backup_Site`、`Keep_Days_Db`、`Keep_Days_Web`、`Web_Interval_Days`、
`Enable_Remote_Backup`、`Remote_Protocol`、`Remote_Host`、`Remote_Port`、
`Remote_User`、`Remote_Dir`、`Remote_Password`、`Remote_Ftp_Verify`、
`Remote_Ftp_CA`、`Remote_SSH_Key`、`Remote_Known_Hosts`、`Enable_Encrypt`、
`Encrypt_Tool`、`Encrypt_Recipient`、`Encrypt_Identity`。具体取值与验证见 8.4、8.5。

通知配置支持 `TG_Enable`、`TG_Bot_Token`、`TG_Chat_Id`、`TG_Parse_Mode`、
`TG_Timeout`、`TG_Retry`、`TG_Disable_Preview`；用 `lnmp tgnotice --init` 生成，
不要把 Token 写进仓库或命令行历史。

站点级可配置项由 `lnmp vhost add` 收集：主域名、附加域名、站点目录、rewrite、
是否开启 PHP、Pathinfo、PHP 版本、访问日志、IPv6、数据库、SSL 与跳转策略。
数据库、FTP、证书和 DNS provider 凭据分别通过 `lnmp database`、`lnmp ftp`、
`lnmp ssl`/`dnsssl` 管理。不要直接复制别人的完整 vhost；保留本项目生成的 socket、
PHP 禁用分支和 phpMyAdmin 边界，再做最小修改。

#### 2.5.4 维护者配置与可选组件入口

读者如果还要修改项目本身，而不只是已安装服务，入口如下：

| 目标 | 位置/命令 | 边界 |
|---|---|---|
| Nginx/OpenResty 初装模板 | `conf/nginx.conf`、`conf/openresty.conf` | 只影响以后安装；已安装实例改 `/usr/local/nginx/conf/nginx.conf` |
| 管理命令源码 | `conf/lnmp`、`conf/lnmpa`、`conf/lamp` | 三套公共功能必须同步；运行中的命令是 `/bin/lnmp`，不能只改仓库文件就认为已生效 |
| 通用组件版本 | `include/version.sh` | 改版本后更新对应校验/签名材料并执行 URL、lint 和一致性检查 |
| 数据库/PHP/Apache 菜单与版本 | `include/profile.sh` | 编号、版本语义、安装函数和架构能力在这里统一映射，不能只改菜单文字 |
| 静态 SHA256 清单 | `src/checksums.sha256` | 只覆盖走静态 SHA256 的组件；PGP/仓库 GPG/上游动态校验各走自己的路径 |
| PHP/缓存扩展 | `bash addons.sh install {memcached\|opcache\|redis\|apcu\|imagemagick\|exif\|fileinfo\|ldap\|bz2\|sodium\|imap\|swoole}` | 按实际依赖安装；主安装已默认提供 OPcache、igbinary、phpredis、imagick |
| Pure-FTPd 服务 | `bash pureftpd.sh` | 端口来自 `lnmp.conf`；不需要传统 FTP 时不要增加该公网服务 |
| 组件升级 | `bash upgrade.sh {nginx\|openresty\|mysql\|mariadb\|m2m\|php\|phpa\|phpmyadmin\|mphp}` | 先备份和测试；数据库升级没有自动回滚 |
| 管理功能 | `lnmp vhost/database/ftp/ssl/dnsssl/onlyssl/backup/tgnotice/phpmyadmin` | 优先走命令生成配置，保留校验、权限与回滚逻辑 |

`addons.sh` 菜单虽然仍列出 ionCube，但当前版本没有接入可用安装流程；不要把菜单名当成
功能已经实现。Apache/LNMPA/LAMP 保留代码路径，但没有 Debian 13 主线同等级的真机覆盖。

---

## 三、安装 Redis

WordPress 的对象缓存要用到。**PHP 的 redis 扩展在主安装时就装好了**
（`Enable_PHP_Default_Redis='y'`），这一步装的是 **Redis 服务端**。

```bash
bash addons.sh install redis
```

关键回显：

```
注释掉 Redis 8.x 默认配置里的 loadmodule（对应模块未随 make install 安装）
检测到 igbinary，启用 phpredis 的 igbinary 序列化支持。
checking for redis igbinary support... enabled
====== Redis install completed ======
```

验证：

```bash
/etc/init.d/redis status
# Redis server is running (pid 833640).

redis-cli ping
# PONG

redis-cli config get dir
# /usr/local/redis/var
```

Redis 的安全默认值（本包已配好，不要随意放开）：

- 只监听 `127.0.0.1` 和 `::1`，不对外
- nftables 里 `tcp dport 6379 drop`
- 数据目录 `/usr/local/redis/var`，日志 `/usr/local/redis/var/redis.log`
- 以专用低权限账号 `redis` 运行（不是 root）

> **回环监听是必要条件，不是充分条件。**
>
> Redis 默认**没有密码**。绑定回环解决的只是"公网暴露"这一个问题，
> 它**不解决本机进程之间的信任隔离**。同一台机器上的所有 PHP 进程
> 都能直接连上它，读写任何键。也就是说：
>
> - **多站点共用一个 Redis 实例时，一个站点被拿下就能读写其他站点的缓存**。
>   `WP_REDIS_PREFIX` 只是命名约定，**不是授权边界** ：
>   攻击者不受前缀约束，可以直接 `KEYS *`。
> - 缓存里往往有会话、用户数据、临时令牌，不只是"可以重建的数据"。
>
> 应根据部署模型选择有效的隔离方式：
>
> | 场景 | 做法 |
> |---|---|
> | 单站点、单租户 | 回环 + Redis 低权限系统账号；可再给 default 用户设强密码 |
> | 多个互相信任的站点 | 每站前缀/ACL 可减少误操作，但要监控总内存和淘汰；Redis database 编号不是安全边界 |
> | 互不信任的租户 | 本项目共用 `www` 用户和一个 FPM 池，**不提供硬隔离**；需另建 Unix 用户/FPM 池，并配独立 Redis socket/ACL，或拆主机/容器 |
>
> Redis 6+ 的现代认证机制是 ACL；`requirepass` 只是给 default 用户设密码的兼容接口。
> 但 ACL 凭据也保存在站点配置里，共用同一 `www` 系统账号时，站点被完全攻破后仍可能
> 窃取其它站点凭据，所以它不能替代进程/文件权限隔离。

不要把本项目编译的 Redis 直接开放到公网。确需跨机访问时使用私网/VPN/SSH 隧道，限制
来源，并确认链路加密；仅设置密码不能防止明文协议上的凭据和数据被窃听。

单站点希望给回环连接再加一道认证时，可以使用兼容性较好的 `requirepass`。下面把密码
保存到 root-only 文件，不打印到终端，也不通过 `redis-cli -a` 暴露在进程参数中：

```bash
# 1. 生成并保存密码（配置文件是 root:redis 640，密码文件是 root 600）
umask 077
REDISPW=$(openssl rand -base64 24)
printf '%s\n' "${REDISPW}" > /root/.lnmp_redis_password
sed -i '/^[[:space:]]*#\?[[:space:]]*requirepass[[:space:]]/d' /usr/local/redis/etc/redis.conf
printf 'requirepass %s\n' "${REDISPW}" >> /usr/local/redis/etc/redis.conf
unset REDISPW

# 2. 重启使配置生效
/etc/init.d/redis restart

# 3. 验证：不带密码应该被拒绝，带密码才能执行命令
redis-cli ping
# (error) NOAUTH Authentication required.
REDISCLI_AUTH="$(cat /root/.lnmp_redis_password)" redis-cli ping
# PONG
```

设了密码之后，WordPress 那边的 redis-cache 插件也要同步改，
在 [5.3 生成 wp-config.php](#53-生成-wp-configphp) 的 Redis 常量块里加一行：

```php
define( 'WP_REDIS_PASSWORD', '读取 /root/.lnmp_redis_password 后填入的密码' );
```

不改这一行的话，插件仍按无密码连接，会直接报连接失败。写入后保持 `wp-config.php`
的 root 所有和 640 权限，不要让密码文件进入备份之外的日志、Git 或聊天记录。

---

## 四、创建站点

### 4.1 交互式创建

```bash
lnmp vhost add
```

**完整的交互顺序**（单 PHP 版本、未装 pure-ftpd 的情况，共 16 步）：

| # | 提示 | WordPress 场景填什么 |
|---|---|---|
| 1 | `请输入域名(示例: www.example.com):` | `wp.example.com` |
| 2 | `请输入更多域名(示例: example.com sub.example.com，直接回车跳过):` | 回车跳过，或填 `example.com` |
| 3 | `默认目录(直接回车使用): /home/wwwroot/<域名>` | 回车用默认 `/home/wwwroot/<域名>` |
| 4 | `是否开启伪静态规则? (y/N，默认 n)` | **`y`** |
| 5 | `(默认 other，直接回车使用):` | **`wordpress`** |
| 6 | `是否开启 PHP? (Y/n，默认 y)` | 回车用默认 `y`（WordPress 要跑 PHP） |
| 7 | `是否开启 PHP Pathinfo? (y/N，默认 n)` | `n`（WordPress 不需要） |
| 8 | `是否开启访问日志? (y/N，默认 n)` | `y` |
| 9 | `请输入访问日志文件名(默认: <域名>.log，直接回车使用):` | 回车用默认 |
| 10 | `是否开启 IPv6? (y/N，默认 n)` | 有 IPv6 就 `y` |
| 11 | `是否创建同名数据库和 MySQL 用户? (y/N，默认 n)` | **`y`** |
| 12 | `请输入当前数据库 root 密码（输入不回显）:` | 数据库 root 密码（不回显） |
| 13 | `请输入数据库名（只允许字母、数字和下划线）:` | `wpdemo`（库名与用户名相同） |
| 14 | `请输入数据库用户 <库名> 的密码（输入不回显）:` | 库用户密码（不回显） |
| 15 | `是否添加 SSL 证书? (y/N，默认 n)` | 先 `n`，第七章单独做 |
| 16 | `按任意键开始创建虚拟主机，或按 Ctrl+C 取消...` | 任意键 |

第 5 步之前会先列出已内置的伪静态规则名（`wordpress`、`typecho`、`discuzx` 等），
第 9 步只在第 8 步选了 `y` 时出现；第 12–14 步只在第 11 步选了 `y` 时出现。

**第 6 步选 `n` 时**（纯静态站点，或 Node、Go 等自带后端的站点）：不再问 Pathinfo，
装了多个 PHP 版本时也不再问选哪个版本；站点配置里不写任何 PHP 执行入口，
首页候选去掉 `index.php`，`.php` 与 `.php/xxx` 一律返回 404，
站点目录也不再写 `.user.ini`。详见 4.4。

> **第 5 步的 `wordpress` 是关键。** 它会引用内置的
> `/usr/local/nginx/conf/rewrite/wordpress.conf`：
> ```nginx
> location / { try_files $uri $uri/ /index.php?$args; }
> rewrite /wp-admin$ $scheme://$host$uri/ permanent;
> ```
> 这正是 WordPress 官方推荐的 nginx 伪静态写法。

成功后会打印站点信息，并且能看到 `数据库创建成功。`。

### 4.2 非交互创建

**带 PHP 的站点**（WordPress 场景，与 4.1 的问答一一对应）：

```bash
printf 'wp.example.com\n\n\ny\nwordpress\nn\ny\n\nn\ny\n数据库root密码\nwpdemo\n库用户密码\nn\n\n' \
  | lnmp vhost add
```

**不带 PHP 的站点**（纯静态，或 Node、Go 等自带后端）：用 `VHOST_PHP=n` 关掉 PHP，
输入序列不再包含 Pathinfo，也不创建数据库：

```bash
printf 'app.example.com\n\n\nn\nn\nn\nn\nn\n\n' | VHOST_PHP=n lnmp vhost add
```

> 依次是：域名 → 更多域名(空) → 目录(空) → 伪静态 `n` → 访问日志 `n` →
> IPv6 `n` → 建库 `n` → SSL `n` → 任意键。站点行为见 4.4。

> 注意：**输入项数量必须精确**。域名、数据库 root 密码、数据库名、库用户密码
> 缺少任一项时会报告 `读取<项目>时遇到 EOF：标准输入已经没有内容。` 并退出
> （这是有意的快速失败，早期版本在这里会无限刷屏）；其余选项少喂时按默认值处理，
> 不会报错，得到的站点配置与预期不符。
>
> 注意：**装了多个 PHP 版本时会多一步**（第 10 步后会问选哪个 PHP），
> 序列要相应调整。单版本时不会问。
>
> 注意：**第 6 步的 PHP 开关不占喂入序列的一行**。非交互执行时不读标准输入，
> 只读取环境变量 `VHOST_PHP`：未设置时开启 PHP，
> 上面这条命令不用改。要建不带 PHP 的站点见 4.4。

### 4.3 验证站点

```bash
lnmp vhost list
ls -la /home/wwwroot/wp.example.com/

# 用建好的账号实际登录一次，这才算真的可用
# -p 后不填写密码，使用交互提示；命令行参数对同机其他用户可见
# （ps / /proc/<pid>/cmdline），还会进 shell history 和终端录屏
mysql -u wpdemo -p -h 127.0.0.1 -e "SELECT CURRENT_USER(); SHOW DATABASES;"
```

实测输出（权限隔离正确，该账号只看得到自己的库）：

```
CURRENT_USER()
wpdemo@127.0.0.1
Database
information_schema
performance_schema
wpdemo
```

### 4.4 建不带 PHP 的站点

纯静态站点，以及 Node、Go 这类自带后端进程的站点用不到 PHP。建站时第 6 步
（`是否开启 PHP? (Y/n，默认 y)`）选 `n`，站点配置里就不会出现任何 PHP 执行入口。

```bash
# 交互：第 6 步输入 n
lnmp vhost add

# 非交互：用环境变量显式关闭，输入序列不包含 Pathinfo
# 依次是：域名、更多域名、目录、伪静态 n、访问日志 n、IPv6 n、建库 n、SSL n、任意键
printf 'app.example.com\n\n\nn\nn\nn\nn\nn\n\n' | VHOST_PHP=n lnmp vhost add
```

`VHOST_PHP` 未设置时按开启 PHP 处理。

关闭 PHP 后各栈的实际差别：

| 栈 | HTTP / HTTPS 配置的变化 |
|---|---|
| LNMP | 不写 `include enable-php*.conf;`；`.php`、`.php/xxx` 一律 404 |
| LNMPA | 不写 `include proxy-pass-php.conf;`（不再反代给 Apache）；Apache 侧同时 `php_admin_flag engine off` 并把 `.php` 挡成 404 |
| LAMP | Apache `php_admin_flag engine off` + `RedirectMatch 404 "\.php(/\|$)"`，`open_basedir` 一并注释掉 |

三栈共同点：首页候选去掉 `index.php`、`default.php`，站点目录不写 `.user.ini`，
`lnmp ssl add` 追加 443 配置时会从现有站点配置读回同一状态，不会重新打开 PHP。

Nginx 侧那条 404 规则**不能省**：站点目录里一旦出现 `.php` 文件（旧站遗留、备份、
被写入的后门），Nginx 会当成普通静态文件返回——自带的 `mime.types` 没有 `.php`，
按 `default_type application/octet-stream` 把源码整份交出去。
Apache 侧更是必需项：`.php` 的处理器挂在 `httpd.conf` 全局，站点配置什么都不写
就等于照常执行 PHP。

**Go / Node 站点的反向代理**需按后端实际监听端口配置；本开关只关闭 PHP 执行入口：

```nginx
# /usr/local/nginx/conf/vhost/app.example.com.conf
location / {
    proxy_pass http://127.0.0.1:3000;
    include proxy.conf;
}
```

整站反代时若需要把 `.php` 路径原样透传给后端，删掉配置里那段带
`# 本站点未开启 PHP` 注释的 `location` 即可（正则 location 优先级高于
`location /`，留着会先被它拦成 404）。

**站点建好后想改主意**：直接编辑 `/usr/local/nginx/conf/vhost/<域名>.conf`
（LAMP 是 `/usr/local/apache/conf/vhost/<域名>.conf`），加回或删掉上述几行，
`nginx -t` / `httpd -t` 通过后 reload 即可，不必删站重建。

---

## 五、部署 WordPress

### 5.1 下载并校验

```bash
cd /tmp
# 固定版本，不使用浮动的 latest，确保不同主机和时间使用相同内容
WP_VER=7.0.3
curl -fsSL -o wordpress.tar.gz     "https://wordpress.org/wordpress-${WP_VER}.tar.gz"
curl -fsSL -o wordpress.tar.gz.sha1 "https://wordpress.org/wordpress-${WP_VER}.tar.gz.sha1"

# 校验不通过必须立即中止，不能只打印一句提示
if [ "$(cat wordpress.tar.gz.sha1)" != "$(sha1sum wordpress.tar.gz | awk '{print $1}')" ]; then
    echo "校验失败：文件与官方发布的哈希不一致，已中止。" >&2
    rm -f wordpress.tar.gz
    exit 1
fi
echo "校验通过"
```

> 注意：**SHA-1 只能挡住传输损坏和缓存污染，不构成强完整性保证**（它已不抗碰撞）。
> 它是 wordpress.org 目前提供的校验方式，聊胜于无。真正在意供应链的话，
> 应该另行取得可信的版本清单来核对，而不是只信同一个站点给出的哈希。

### 5.2 铺文件

**代码目录不要交给 PHP 运行账号（`www`）写。** 这是 WordPress 站点被入侵后
攻击持久化的关键条件是 PHP 可以改写代码文件。任何插件、主题或站点代码漏洞，
只要 PHP 能改写自己的代码文件，攻击者就能落 webshell、改核心文件、
篡改 `wp-config.php`。

```bash
SITE=/home/wwwroot/wp.example.com
tar zxf wordpress.tar.gz
cp -a wordpress/. ${SITE}/

# 代码归 root，PHP 只读
chown -R root:www ${SITE}/
find ${SITE} -type d -exec chmod 750 {} \;
find ${SITE} -type f -exec chmod 640 {} \;

# 只有这几个目录需要 PHP 写：上传、缓存、升级临时目录
mkdir -p ${SITE}/wp-content/uploads ${SITE}/wp-content/cache ${SITE}/wp-content/upgrade
chown -R www:www ${SITE}/wp-content/uploads ${SITE}/wp-content/cache ${SITE}/wp-content/upgrade
chmod -R 750     ${SITE}/wp-content/uploads ${SITE}/wp-content/cache ${SITE}/wp-content/upgrade
```

**限制**：这样配置后，**后台的插件/主题在线安装与自动升级会失效**
（PHP 写不了 `wp-content/plugins`）。这是有意的取舍。两种做法二选一：

- **推荐**：升级走命令行（`wp-cli` 或手工替换文件），后台只用来编辑内容。
- **图省事**：把 `wp-content/plugins`、`wp-content/themes` 也给 `www` 写权限，
  但要清楚这等于把"PHP 可写自身代码"这条路重新打开了。
  `wp-config.php` 与核心目录（`wp-admin`、`wp-includes`）**无论如何都不要**给。

> **会看到这两行报错，属正常，不用管：**
> ```
> chown: changing ownership of '.../.user.ini': Operation not permitted
> chmod: changing permissions of '.../.user.ini': Operation not permitted
> ```
> `.user.ini`（存放 `open_basedir` 限制）被刻意加了 immutable 属性
> （`chattr +i`），防止站点被入侵后篡改目录限制。这是安全设计。
> 真要改它：`chattr -i .user.ini` → 改 → `chattr +i .user.ini`。

### 5.3 生成 wp-config.php

```bash
cd ${SITE}
SALT=$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/)

cat > wp-config.php <<PHPEOF
<?php
define( 'DB_NAME', 'wpdemo' );
define( 'DB_USER', 'wpdemo' );
define( 'DB_PASSWORD', '库用户密码' );
define( 'DB_HOST', '127.0.0.1' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

${SALT}

\$table_prefix = 'wp_';

/* Redis 对象缓存（redis-cache 插件读取这些常量） */
define( 'WP_REDIS_HOST', '127.0.0.1' );
define( 'WP_REDIS_PORT', 6379 );
define( 'WP_REDIS_DATABASE', 0 );
define( 'WP_REDIS_PREFIX', 'wpdemo:' );

/* 安全基线 */
define( 'DISALLOW_FILE_EDIT', true );
define( 'WP_DEBUG', false );
define( 'WP_AUTO_UPDATE_CORE', 'minor' );

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
PHPEOF

# 属主为 root，PHP 仅有读取权限；文件包含明文数据库密码，
# 而且没有任何正当理由需要被 PHP 改写
chown root:www wp-config.php && chmod 640 wp-config.php
php -l wp-config.php
```

几个要点：

- **`DB_HOST` 用 `127.0.0.1` 而不是 `localhost`**：后者会走 unix socket，
  而 PHP 的 `mysqli.default_socket` 未必指向 `/run/mysqld/mysqld.sock`。
  用 TCP 最省事；建站时创建的库用户对 `localhost` 和 `127.0.0.1` 都授了权。
- **`WP_REDIS_PREFIX` 一定要设**：多站点共用一个 Redis 实例时，
  未设置前缀时会发生键名冲突。
- **`DISALLOW_FILE_EDIT`**：关掉后台的插件/主题在线编辑器。
  这是被入侵后最常见的提权跳板。
- **`wp-config.php` 权限 640**：它含明文数据库密码，不能是 644。

### 5.4 完成安装

**推荐做法：先配好 HTTPS（第七章），再用浏览器访问安装向导。**

```
https://wp.example.com/
```

在页面里填站点标题和管理员账号。理由很直接：

- **管理员密码不应通过 HTTP 传输**：链路上的中间节点可以读取明文
- **不应出现在命令行参数中**：`ps`、`/proc/<pid>/cmdline` 对同机用户可见，
  还会进 shell history、终端录屏和自动化日志

如果站点已经能通过 HTTPS 访问，浏览器安装是最省事也最安全的方式。

<details>
<summary>确有无人值守需求时的命令行方式（点击展开，请先读风险说明）</summary>

注意：**这个方式会把管理员密码放进命令行参数**。只在下列条件都满足时才用：

- 走 **HTTPS** 地址（不要用 `http://`）
- 在受控的一次性环境里执行（如镜像构建、CI），事后销毁历史
- 密码从环境变量或 secret store 读入，不要直接写在命令里
- 装完**立即改一次密码**

```bash
# 密码从环境变量取，避免直接写进命令文本
read -r -s -p "管理员密码: " WP_ADMIN_PW; echo

curl -s -X POST \
  -d "weblog_title=站点标题" \
  -d "user_name=管理员用户名" \
  -d "admin_password=${WP_ADMIN_PW}" \
  -d "admin_password2=${WP_ADMIN_PW}" \
  -d "pw_weak=1" \
  -d "admin_email=你的邮箱@example.com" \
  -d "blog_public=0" \
  "http://wp.example.com/wp-admin/install.php?step=2" | grep -o "<h1>[^<]*</h1>"
# <h1>Success!</h1>
```

> `blog_public=0` 表示不希望搜索引擎索引。正式站点改成 `1`。

安装完成后立即修改密码，使安装阶段使用的凭据失效：

```bash
# 后台「用户 → 个人资料」改，或用 wp-cli：
# wp user update 管理员用户名 --user_pass='新密码' --path=/home/wwwroot/wp.example.com
history -c   # 清理当前 shell 历史
```

</details>

### 5.5 验证伪静态

WordPress 后台「设置 → 固定链接」选一个非默认的结构（如"文章名"），
然后验证：

```bash
curl -o /dev/null -w "文章页: %{http_code}\n"   http://wp.example.com/hello-world/
curl -o /dev/null -w "分类页: %{http_code}\n"   http://wp.example.com/category/uncategorized/
curl -o /dev/null -w "wp-admin: %{http_code}\n" http://wp.example.com/wp-admin
```

实测：

```
文章页: 200
分类页: 200
wp-admin: 301        ← wordpress.conf 的补斜杠规则，跳到 /wp-admin/
```

**如果文章页返回 404**，说明伪静态没生效，检查站点配置里有没有
`include rewrite/wordpress.conf;`。

---

## 六、WordPress 专项调优

### 6.1 启用 Redis 对象缓存

```bash
cd /home/wwwroot/wp.example.com/wp-content/plugins
# 固定版本，不用浮动的 redis-cache.zip（那个链接指向的内容随时会变）
PLUGIN_VER=2.5.4
curl -fsSL -o redis-cache.zip "https://downloads.wordpress.org/plugin/redis-cache.${PLUGIN_VER}.zip"

# 注意：wordpress.org 的插件目录不提供逐文件的哈希或签名。
# 此步骤无法取得可靠的完整性依据；官方域名不能替代文件完整性验证。
# 至少记录实际部署文件的哈希，以便后续检查文件是否变化；
# 并且只固定版本、不用浮动链接。
sha256sum redis-cache.zip | tee redis-cache.${PLUGIN_VER}.sha256
echo "↑ 记录下来。以后重新部署同一版本时，哈希必须一致。"

unzip -q redis-cache.zip && rm -f redis-cache.zip
chown -R www:www redis-cache

# 部署 drop-in（也可以在后台插件页点"Enable Object Cache"）
cp redis-cache/includes/object-cache.php ../object-cache.php
chown www:www ../object-cache.php
```

在后台「插件」里启用 Redis Object Cache，然后验证缓存**真的**在写：

```bash
redis-cli --scan --pattern "wpdemo:*" | head
redis-cli --scan --pattern "wpdemo:*" | wc -l
```

实测（访问两个页面后）：

```
wpdemo:wp:options:alloptions
wpdemo:wp:post-queries:wp_query-6506dec3102d0c0ee71b2e72debc47f6
wpdemo:wp:terms:1
...
49
```

> 键数为 0 说明没生效。依次检查：`object-cache.php` 是否在 `wp-content/` 下、
> `php -m | grep redis` 有没有 redis 扩展、`redis-cli ping` 通不通。

本包编译 phpredis 时启用了 **igbinary 序列化**，比默认的 PHP 序列化
体积更小、速度更快。验证：

```bash
php -r '$r=new Redis(); $r->connect("127.0.0.1",6379);
  $r->setOption(Redis::OPT_SERIALIZER, Redis::SERIALIZER_IGBINARY);
  $r->set("t",["a"=>1]); echo json_encode($r->get("t")),PHP_EOL; $r->del("t");'
# {"a":1}
```

### 6.2 PHP 与 OPcache

安装后的 `/usr/local/php/etc/php.ini` 来自 PHP 的 production 模板，脚本明确改动
`upload_max_filesize=50M`、`post_max_size=50M`、`max_execution_time=300`、
`cgi.fix_pathinfo=0`、`expose_php=Off`、时区和禁用函数。`memory_limit` 仍是模板的
128M，`max_input_vars` 仍是 1000。不要把所有站点一律改成 256M/3000：

| 参数 | 建议起点 | 何时调整 |
|---|---:|---|
| `memory_limit` | 普通站 128M；电商/页面构建器 256M | 先看 PHP fatal error 和插件文档；它是单请求上限，不是预留内存 |
| `upload_max_filesize` | 50M | 只按业务最大上传调，不建议用 PHP 上传大视频/备份 |
| `post_max_size` | 不小于上传上限，另留表单开销 | 必须与 Nginx `client_max_body_size` 一起改 |
| `max_input_vars` | 1000 | 菜单/复杂表单确认发生截断后再升到 2000~3000 |
| `max_execution_time` | 300 是项目值，普通页面应远低于此值 | 长任务移到队列/CLI；不要靠继续加超时掩盖慢请求 |

OPcache 已由 `Enable_PHP_Default_Opcache=y` 默认安装，配置在
`/usr/local/php/conf.d/004-opcache.ini`，项目值为 128M、10000 个脚本。容量判断必须读取
**FPM 进程池**的 `opcache_get_status(false)`；直接运行 `php -r` 看到的是独立 CLI 进程，
默认还关闭 CLI OPcache，不能代表网站。可临时建立只允许回环访问的状态端点读取
`memory_usage` 与 `opcache_statistics`，检查完立即删除，不要把 OPcache 状态公开到公网。

只有 `free_memory` 长期接近 0 或 `hash_restarts` 增长时才扩大到 192M/256M 或增加
`opcache.max_accelerated_files`。手工更新 WordPress 的环境保持
`opcache.validate_timestamps=1`；只有不可变镜像、原子发布且发布后显式 reset OPcache
的流程才适合关闭时间戳检查。

修改后先检查语法再平滑加载：

```bash
/usr/local/php/bin/php --ini
/usr/local/php/sbin/php-fpm -t && lnmp php-fpm reload
```

`disable_functions` 是降低插件误用风险的补充措施，不是安全边界。WordPress 核心不需要
`exec`/`system`/`shell_exec`，保持项目默认；某个插件确实需要时，先确认它调用的准确
函数和输入边界，尽量只解除单项，而不是直接运行脚本清空整份限制。

### 6.3 PHP-FPM 进程模型

项目先生成 `pm=dynamic`、`pm.max_children=10`，随后按机器总内存自动改为：

| 总内存 | 项目生成的 `max_children` | 同时生成的 `start/min/max_spare` |
|---:|---:|---:|
| `<=1GB` | 10 | 2 / 1 / 6 |
| `>1GB, <=2GB` | 20 | 10 / 10 / 20 |
| `>2GB, <=4GB` | 40 | 20 / 20 / 40 |
| `>4GB, <=8GB` | 60 | 30 / 30 / 60 |
| `>8GB` | 80 | 40 / 40 / 80 |

这是**程序实际行为，不是本指南的推荐值**。它只看总内存，没有扣除数据库、Redis、
OPcache、内核页缓存和备份任务；特别是 `start_servers=30/40` 会在低流量 VPS 常驻很多
空闲 worker。混部 WordPress 应按 6.6 的起点下调。

容量公式使用真实高峰数据：

```text
max_children = floor(PHP 可用内存 / 单 worker 的高峰 PSS)
```

RSS 会把共享库/OPcache 重复计入每个进程，条件允许时安装 `smem` 看 PSS；没有 `smem`
可先用 RSS 做保守上界。必须在插件、主题、缓存预热和代表性请求都到位后采样，空白首页
的 20~30MB 没有规划意义：

```bash
ps --no-headers -o pid,rss,etime,cmd -C php-fpm --sort=-rss | head -20
grep -E '^(MemAvailable|SwapFree):' /proc/meminfo
journalctl -k --since today | grep -Ei 'oom|out of memory|killed process'
```

低流量 1~4GB VPS 可用 `pm=ondemand` 降低常驻内存，并保留
`pm.process_idle_timeout=10s`；稳定高流量用 `dynamic` 减少冷启动。两种模式都保留
`pm.max_requests=500~1000` 控制长期碎片。调整后观察 502、FPM 日志中的
`server reached pm.max_children` 和系统 Swap/OOM，而不是看到 CPU 空闲就继续加 worker。

### 6.4 MySQL 8.4 / MariaDB

MySQL 与 MariaDB 安装都调用项目的 `MySQL_Opt`：按总内存把
`innodb_buffer_pool_size` 设为 128M（1~2GB）、256M（2~4GB）、512M（4~8GB），
同时固定 `max_connections=500`，并随内存放大 `sort_buffer_size`、`read_buffer_size` 等
连接级 buffer。这是程序实际生成值，不代表两种引擎在 WordPress 混部 VPS 上都应保持
500 个连接。FPM worker 才是主要数据库并发来源，连接级 buffer 会在活跃连接上叠加。

认证配置也必须按引擎区分。MySQL 8.x 模板不再开启已废弃的
`mysql_native_password`，新用户使用 MySQL 上游默认认证；不要为了兼容单个旧客户端在服务端
全局降级，优先升级客户端。MariaDB 使用自己的认证插件和账号语义，不读取 MySQL 8.4 的
旧插件开关。两种引擎的 socket 均为 `/run/mysqld/mysqld.sock`，首次 root 密码在禁网的
私有 socket 上设置，之后才启动正式服务。

建议从下面关系开始：

```text
max_connections = 所有 PHP-FPM 池的 max_children 总和 + 10~20 个管理/计划任务余量
innodb_buffer_pool_size = 留足系统、PHP、Redis 和备份峰值后的数据库预算
```

WordPress 应保持 InnoDB。不要启用 MySQL 8 已删除的 query cache，也不要照搬旧文章把
`sort_buffer_size`、`join_buffer_size`、`read_buffer_size` 调成几十 MB；它们不是全局缓存。
`tmp_table_size` 与 `max_heap_table_size` 也按连接生效，32M 起步通常足够，先用状态值确认
磁盘临时表比例。`innodb_flush_log_at_trx_commit=1` 是项目默认和最稳妥的数据持久性设置；
改成 2 是明确的数据丢失权衡，不是免费优化。

修改 `/etc/my.cnf` 前先记录当前值：

```bash
mysql -NBe "SHOW VARIABLES WHERE Variable_name IN ('max_connections','innodb_buffer_pool_size','tmp_table_size','max_heap_table_size');"
mysql -NBe "SHOW GLOBAL STATUS WHERE Variable_name IN ('Max_used_connections','Threads_connected','Created_tmp_tables','Created_tmp_disk_tables','Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests');"
```

运行一到两周或覆盖业务高峰后再判断。`Max_used_connections` 长期很低就不需要 500；
buffer pool 命中率只能说明读工作集，不能单独证明要占用更多整机内存。慢站点优先开短时
慢查询日志并用 `EXPLAIN` 修查询/索引，不用增加 buffer 掩盖插件产生的低效 SQL。

#### MySQL 8.4 与 MariaDB 的选择

WordPress 核心对两者都支持，常规文章/用户/元数据查询也很接近。真实站点的差异通常先由
插件 SQL、索引、磁盘延迟、buffer pool 是否容纳热数据和页面/对象缓存决定，不能脱离数据
与并发宣称“MariaDB 一定更快”或“MySQL 一定更稳”。本项目中的实际差异如下：

| 维度 | MySQL 8.4 LTS | MariaDB 10.11 / 11.4 / 11.8 | 对 WordPress 的意义 |
|---|---|---|---|
| 项目默认选择 | `DBSelect=2`，官方通用二进制 | `DBSelect=3/4/5`，官方通用二进制 | x86_64 都优先 `Bin=y`，不要为“优化”源码编译 |
| 查询缓存 | MySQL 8 已删除 | 仍提供；项目模板会设置并随内存放大 `query_cache_size` | 写入会使相关结果失效并产生同步开销；现代动态站默认关闭更可预测 |
| 优化器/统计信息 | MySQL 8.4 的 optimizer、histogram 与 EXPLAIN 行为 | 已与 MySQL 分叉，优化器开关、统计信息和执行计划不同 | 慢 SQL 必须在目标引擎上 `EXPLAIN`，不能复制另一引擎的 hint/变量 |
| redo 配置 | 项目将旧项换成 `innodb_redo_log_capacity` | 保留 MariaDB 自身的 InnoDB redo 参数 | 不要把 MySQL 8.4 的 redo 变量写进 MariaDB，或反向照搬 |
| 额外协议 | 有 X Protocol，项目通过 `DB_X_Port` 和回环绑定收口 | 没有 MySQL X Protocol | WordPress 不使用 X Protocol；确认无其它客户端依赖时可评估 `mysqlx=OFF` |
| 兼容与迁移 | 新项目默认、上游 LTS；MySQL 8.0 菜单项已 EOL，只为兼容保留 | 适合已有 MariaDB 运维经验/数据链路的环境 | 物理数据目录不互换；项目只提供 MySQL→MariaDB 迁移入口，没有无损反向切换 |
| 性能结论 | 读写表现取决于具体版本、查询与数据 | 同左 | 用整站 HTTP p95/p99、数据库 CPU/IO/慢查询比较，不能只跑空库 sysbench |

新建普通 WordPress、没有既有偏好时使用项目默认 MySQL 8.4 LTS 最省兼容决策；已经有
MariaDB 备份、监控和故障处理经验时选 MariaDB LTS 同样合理。不要为了传闻中的几个百分点
做生产库跨引擎迁移；迁移需要逻辑备份、字符集/排序规则/SQL mode 检查和完整回滚演练。

#### MariaDB 的起始优化

MariaDB 与 MySQL 的 buffer pool **使用同一份整机内存预算**，不因名字不同就多分内存。
但当前项目会启用并放大 MariaDB query cache；对有后台编辑、评论、电商订单或定时任务的
WordPress，建议先关闭，再通过真实对照测试决定是否恢复：

```ini
[mysqld]
query_cache_type = 0
query_cache_size = 0
```

不要只看 `Qcache_hits` 很高就认定有效：还要同时看写入延迟、CPU、锁等待和 HTTP p95。
页面缓存/CDN 与 Redis 对象缓存通常比数据库 query cache 更清楚地控制失效边界。纯只读、
重复 SQL 极高的站点可以做 A/B 测试，但那不是普通 WordPress 的默认前提。

MySQL 8.4 与 MariaDB 的共同起始项可写在 `/etc/my.cnf`，数值按 6.6 选择：

```ini
[mysqld]
innodb_buffer_pool_size = 512M
max_connections = 50
tmp_table_size = 32M
max_heap_table_size = 32M
innodb_flush_log_at_trx_commit = 1
```

这里的 512M/50 对应 3~4GB 单站混部示例。MariaDB 保留自己的 redo/binlog 参数；
MySQL 8.4 保留项目生成的 `innodb_redo_log_capacity`。不要把通用片段扩展成几十个来源不明
的变量，也不要用 `skip-name-resolve`、关闭 Performance Schema 等老式清单作为默认动作；
前者会改变账号 Host 匹配语义，后者会丢失诊断能力，只有证据充分时才改。

#### 如何做有意义的性能对比

比较 MySQL 与 MariaDB 时，使用同一份逻辑备份、同一 PHP-FPM 并发、相同 buffer pool/连接
预算和相同持久性设置。分别预热后回放匿名页、登录、搜索、后台保存、订单/评论写入等真实
链路，至少记录：HTTP p50/p95/p99、错误率、数据库 CPU、磁盘延迟/IOPS、峰值 RSS、
`Rows_examined`、磁盘临时表、锁等待和慢查询。对象缓存必须两边都清空或都预热。

如果差异只出现在一次短跑、未覆盖写入、或一边数据已热一边未热，就不能作为选型依据。
WordPress 常见的第一收益仍是删除低效插件/查询、补正确索引、页面缓存与 OPcache，而不是
替换数据库品牌。

### 6.5 Redis 对象缓存容量

项目安装的 Redis 默认没有 `maxmemory`，这意味着对象缓存可以一直增长到系统开始回收
甚至 OOM。只把该实例用于可重建的 WordPress 对象缓存时，应在
`/usr/local/redis/etc/redis.conf` 设硬上限和淘汰策略：

```conf
maxmemory 128mb
maxmemory-policy allkeys-lfu
```

`allkeys-lfu` 适合“所有 key 都是缓存”的独立实例。若同一实例还存 session、队列或任何
不能随时丢的数据，就不能套用这条策略，应拆实例或使用明确 TTL/ACL。缓存专用实例可按
恢复时间目标决定是否关闭 RDB/AOF；混用实例不得为省 I/O 关闭持久化。

修改前后用真实数据核对：

```bash
redis-cli INFO memory | grep -E 'used_memory_human|used_memory_peak_human|maxmemory_human|mem_fragmentation_ratio'
redis-cli INFO stats  | grep -E 'keyspace_hits|keyspace_misses|evicted_keys'
```

`maxmemory` 不是 Redis 进程总内存上限，复制/AOF buffer、allocator 碎片和 fork 写时复制仍
需额外空间，因此不要把所有剩余内存都给它。命中率低且 `evicted_keys` 持续增长时先检查
key 前缀、TTL 和插件行为，再决定扩容；低流量站点甚至可能不需要 Redis。

### 6.6 1~2GB、3~4GB、5GB 以上的起始方案

下表假设 **Nginx + PHP 8.3 + MySQL 8.4 或 MariaDB LTS + Redis 与 WordPress 同机**、
1 个普通站点，Redis 只做对象缓存，PHP worker 高峰按约 80~120MB 估算。两种数据库先用
相同 buffer pool 和连接预算；MariaDB 另按 6.4 关闭 query cache 后再测。它是避免 OOM 的
上线起点，不是跑分结论；WooCommerce、页面构建器、导入任务和多站点必须重新测。

| 物理内存 | MySQL/MariaDB `innodb_buffer_pool_size` | MySQL/MariaDB `max_connections` | Redis `maxmemory` | PHP-FPM 建议起点 | 系统与突发余量 |
|---:|---:|---:|---:|---|---:|
| 1GB | 128M | 20 | 32~64M | `ondemand`，`max_children=4` | 至少 350M + 1~2GB Swap |
| 2GB | 256M | 30 | 64~128M | `ondemand`，`max_children=8` | 至少 500M + 1~2GB Swap |
| 3~4GB | 512M | 40~50 | 128~256M | `ondemand` 或 `dynamic`，`max_children=12~20` | 700M~1G |
| 5~8GB | 1G~1.5G | 60~80 | 256~512M | `dynamic`，`max_children=24~40` | 1G~1.5G |
| 8GB 以上 | 先给整机 20~30%，再按工作集调 | FPM 总 worker + 20 | 先给 5~10%，按命中/淘汰调 | 用实测高峰 PSS 计算，不固定照抄 80 | 至少 15~20% |

1GB 机器只能承载轻量站点，编译阶段和插件更新阶段都容易触发内存峰值；优先用数据库
通用二进制、减少插件、开启页面缓存/CDN，并避免在流量高峰做备份压缩。5GB 以上也不是
把剩余内存全给 MySQL/MariaDB：同机 PHP 的并发内存通常更不可预测。

每次只改一组值，至少验证以下四类信号：

```bash
free -h
vmstat 1 10
mysql -NBe "SHOW GLOBAL STATUS LIKE 'Max_used_connections';"
redis-cli INFO stats | grep -E 'keyspace_hits|keyspace_misses|evicted_keys'
```

如果 `si/so` 在正常流量下持续非零、`MemAvailable` 逼近 0 或内核出现 OOM，先降低
FPM worker 和连接数；不要通过调高 swappiness、扩大 Swap 或禁用 OOM killer 掩盖超配。

### 6.7 WordPress 定时任务

WordPress 默认用访问触发 `wp-cron.php`。低流量时会延迟，高流量时又会产生重复检查。
生产环境可改系统 timer/cron，但应先确认 WP-Cron 没有长时间运行或失败的事件。

```php
// wp-config.php；确认系统任务已安装后再启用
define( 'DISABLE_WP_CRON', true );
```

已安装 WP-CLI 时优先直接运行到期事件，不经过公开 HTTP：

```cron
*/5 * * * * runuser -u www -- /usr/local/bin/wp cron event run --due-now --path=/home/wwwroot/wp.example.com --quiet
```

WP-CLI 应以站点文件所属的受限账号运行；本文示例路径需按实际 `command -v wp` 修改。
没有 WP-CLI 时使用 HTTPS 且让失败可见，不使用会吞掉 HTTP 错误的 `curl -s`：

```cron
*/5 * * * * curl -fsS --max-time 60 'https://wp.example.com/wp-cron.php?doing_wp_cron' >/dev/null
```

### 6.8 Debian 12/13 VPS 优化基线

现代 Debian 内核和 systemd 的默认值已适合大多数 VPS。不要照抄旧文章里的整页 sysctl、
禁用磁盘日志、`noatime`、巨大 TCP buffer、固定 Nginx worker 数或关闭 IPv6；这些改动
常常在超卖 VPS 上降低稳定性，并让故障难以复现。

上线前按以下顺序处理：

1. **更新与重启基线**：安装前完成 `apt update && apt full-upgrade`，有内核/libc 更新就
   在部署业务前重启。之后启用 Debian 安全更新流程；Nginx/PHP/MySQL 等源码安装组件不受
   apt 自动更新覆盖，仍需跟踪本项目 `upgrade.sh` 并先在测试机验证。
2. **时间与磁盘**：确认 `timedatectl` 同步正常、`df -h`/`df -i` 有余量；云盘支持 discard
   时启用并检查 `fstrim.timer`，不要在未知后端强制连续 discard。
3. **Swap 只做保险**：项目在缺少 Swap 时可能创建 `/var/swapfile`，并只在 swappiness=0
   时改到 10。对 1~2GB VPS 保留 Swap，但持续换页代表应用内存分配错误。
4. **按实际并发设置文件描述符**：项目已把 `nofile` 和 `fs.file-max` 写到 65535，Nginx
   `worker_connections` 也很高。实际并发未逼近限制时，改成几十万没有收益。
5. **网络只按证据调**：先用 `ss -s`、丢包/RTT 和云厂商带宽上限定位。BBR 只对特定
   高带宽高时延或丢包链路有帮助，不是 WordPress 延迟通用解法；开启前确认内核模块、
   qdisc 和对照测试，不把页面慢查询归因于拥塞算法。
6. **云防火墙与本机防火墙双检**：项目的 nftables 链策略是 accept，只显式阻断数据库
   与缓存端口；云安全组应只开放实际 SSH 端口和 80/443，数据库远程管理优先 SSH 隧道。
7. **观察而非定时清缓存**：不要建立 `drop_caches` cron，也不要为了“释放内存”重启
   MySQL/Redis/PHP。Linux page cache 是可回收内存，判断压力看 `MemAvailable`、PSI、Swap
   和 OOM 记录。
8. **虚拟化现实**：`worker_processes auto` 已按可见 CPU 工作；VPS 不要启用
   `worker_cpu_affinity auto` 绑核，超卖和 CPU quota 下可能造成负载倾斜。可在
   `/usr/local/nginx/conf/nginx.conf` 注释该行，压测确认后保留结果。

Debian 12 与 13 的主要差异不需要两套“调优参数”。Debian 13 的依赖更现代，项目已经
处理 `libaio1t64`、ncurses 兼容和 OpenResty trixie 仓库缺失；不要为兼容旧教程手工安装
来路不明的 `.deb` 或恢复已移除库。系统升级前保留快照/异地备份，并在克隆机验证源码
组件能重新链接和启动。

---

## 七、配置 HTTPS

### 7.1 有域名（推荐）

前提：域名已解析到本机，且 **80 端口从公网可达**（HTTP-01 验证要用）。

```bash
lnmp ssl add
```

`ssl add` 只给**已经存在的站点**添加证书。输入域名后会先检查对应虚拟主机配置；
不存在就提示先执行 `lnmp vhost add` 并退出，不会在证书流程中创建网站或重新询问
目录、rewrite、日志、Pathinfo、IPv6。现有站点的目录和附加域名会从配置中读取，
**站点的 PHP 开关状态也一并读回**：建站时选了不开启 PHP 的站点，追加的 443
配置同样不写 PHP 执行入口（会打印一行 `网站 <域名> 未开启 PHP，HTTPS 配置沿用同一状态。`）。

交互顺序：域名 → **证书来源(1-4)** → 是否 301 跳转。选择自有证书时会继续询问
证书和私钥路径；选择 CA 时按需询问账户邮箱。

证书来源：`1`=用自己的证书 `2`=Let's Encrypt `3`=BuyPass `4`=ZeroSSL。
选 2-4 时会要一个邮箱（**不能用 `example.com` 这类保留域名**，
Let's Encrypt 会直接拒绝并报 `invalidContact`）。

域名证书有效期 90 天，acme.sh 的 cron 会自动续期：

```
30 2,8,14,20 * * * "/usr/local/acme.sh"/acme.sh --cron --home "/usr/local/acme.sh"
```

> 注意：**有效期正在缩短。Let's Encrypt 已宣布，到 2028 年公信 TLS 证书
> 有效期将从 90 天减半至 45 天。**
>
> **对本包的影响：经核实，不需要做任何改动。** 依据（基于本包内置的
> acme.sh 3.1.5 源码）：
>
> - **默认续期阈值是 30 天**（`DEFAULT_RENEW="${DEFAULT_RENEW:-30}"`）。
>   45 天有效期下，第 30 天就会触发续期，仍留 15 天余量。
> - **acme.sh 支持 ARI**（RFC 9773 ACME Renewal Information）。
>   CA 暴露 `renewalInfo` 时，acme.sh 会**用 CA 告知的续期窗口覆盖**
>   计算续期时间，因此证书有效期变化时会自动跟随 CA 策略。
>   （可用 `NO_ARI=1` 关闭，**不要关**。）
> - cron 每 6 小时执行一次，触发频率远高于需要。
>
> **建议**：除 cron 任务外，应独立监控证书到期时间。
>
> ```bash
> echo | openssl s_client -connect wp.example.com:443 -servername wp.example.com 2>/dev/null \
>   | openssl x509 -noout -enddate
> ```
>
> 做成定时任务，剩余天数低于阈值就告警。续期链路可能因为别的原因断掉
> （80 端口被防火墙挡了、DNS 变更、磁盘满），那些和有效期长短无关。
>
> 如果外围脚本硬编码了“90 天”有效期，需要同步复查。acme.sh 自身不受影响。

### 7.2 没有域名，仅使用 IP 的 `default` 站点

在域名处输入 **`default`**，菜单只显示自有证书和 Let's Encrypt 两项；选择
Let's Encrypt 后，本包会自动转为 **IP 地址证书**流程，
并打印完整说明。该方式存在以下硬性限制，**申请前必须确认**：

| 限制 | 说明 |
|---|---|
| **有效期只有 7 天** | Let's Encrypt 的 shortlived profile；只有该 profile 支持 IP 地址 |
| **必须依赖自动续期** | 本包按 `--days 6` 申请（比有效期提前 1 天续）。**不得能关掉 acme.sh 的 cron**，否则一周内证书过期、站点不可访问 |
| **只支持 IPv4** | IPv6 地址申请不了 |
| **只能用 Let's Encrypt** | BuyPass 与 ZeroSSL 都不提供 IP 证书，因此 `default` 菜单不显示这两项 |
| **必须是公网 IP** | 私有地址（10.x / 172.16-31.x / 192.168.x / 127.x / 169.254.x）以及运营商级 NAT 的 100.64-127.x，**任何公信 CA 都不会签发** |
| **80 端口要公网可达** | HTTP-01 验证 |

实际执行的命令：

```bash
/usr/local/acme.sh/acme.sh --issue -d <你的公网IPv4> -w /home/wwwroot/default \
  --server letsencrypt --certificate-profile shortlived --days 6
```

> 注意：**NAT 环境要特别注意**：脚本探测到的公网 IP 可能是**出口地址**，
> 未必指向本机。只有将该 IP 的 80 端口转发到本机后，
> 否则验证会失败。申请前先自查：从外网访问 `http://<该IP>/` 能否打开本站。

**如果是私有 IP**，脚本会明确告知无法申请并给出三条出路，
其中自签名证书的完整命令会直接打印出来（加密有效，但浏览器会告警，
仅适合内网自用）。

> **能用域名就用域名。** 90 天有效期比 7 天省心得多，
> IP 证书有效期较短，续期异常的处置时间只有数天。
>
> 注意这个差距未来会缩小但不会消失：**Let's Encrypt 已宣布到 2028 年
> 公信 TLS 证书有效期将从 90 天减半至 45 天**（见 7.1 节）。
> 即便如此，45 天相对 7 天仍有数量级上的容错优势。

### 7.3 强制 HTTPS

`lnmp ssl add` 最后一步问 `Using 301 to Redirect HTTP to HTTPS?` 选 `y` 即可。
WordPress 侧还要把站点地址改成 https：

```bash
mysql -u wpdemo -p -h 127.0.0.1 wpdemo -e \
  "UPDATE wp_options SET option_value='https://wp.example.com'
   WHERE option_name IN ('siteurl','home');"
```

---

## 八、日常运维命令

### 8.1 服务管理

```bash
lnmp status                      # 查看 nginx / php-fpm / mysql 状态
lnmp start | stop | restart | reload
lnmp kill                        # 强制杀进程（仅在正常 stop 失败时用）

# 单独控制某个组件
lnmp nginx   {start|stop|reload|restart}
lnmp mysql   {start|stop|restart}
lnmp php-fpm {start|stop|reload|restart}
```

> `lnmp restart` **不包含 Redis**（它是 addon）。Redis 单独管：
> `/etc/init.d/redis {start|stop|restart|status}`

DenyHosts 误封时使用源码目录里的严格地址入口；参数必须是完整 IPv4 或 IPv6，非法值会在
停止服务和修改列表前退出：

```bash
bash tools/denyhosts_removeip.sh <被误封的IP>
```

### 8.2 站点管理

```bash
lnmp vhost add       # 新增站点
lnmp vhost list      # 列出所有站点
lnmp vhost del       # 删除站点（只删 nginx 配置，保留网站文件）
```

> `vhost del` 会保留网站文件并给出提示，以避免误删数据。
> 需要彻底删除时手工 `rm -rf`，`.user.ini` 的 immutable 属性
> 已由删除流程自动解除。
>
> `vhost add` 会问 `是否开启 PHP? (Y/n，默认 y)`。选 `n` 建出的站点不执行 PHP，
> `.php` 请求一律 404，适合纯静态站点和 Node、Go 等自带后端的站点；
> 非交互执行用 `VHOST_PHP=n`。详见 4.4。

### 8.3 数据库管理

```bash
lnmp database add    # 新建库 + 同名用户
lnmp database list   # 列出所有库
lnmp database edit   # 改库用户密码
lnmp database del    # 删除库

lnmp database export <库名> <文件.sql.gz>   # 导出单个库，gzip 压缩
lnmp database import <库名> <文件.sql.gz>   # 导入到已存在的库
```

导出导入的具体行为：

- 两条命令都会先要求输入数据库 root 密码，凭据写在 `~/.my.cnf`，命令结束即删除。
- 导出内容不含 `CREATE DATABASE` / `USE`，目标库由命令行参数决定，
  因此同一份备份可以恢复到另一个库名。
- 导出先写同目录临时文件再改名，中途失败不会留下半截备份；
  目标文件已存在时直接报错退出，不覆盖。
- 导入按文件内容判断是否压缩，未压缩的 `.sql` 也能直接导入；
  目标库必须已存在（先 `database add` 建库建用户），
  导入会覆盖库中的同名表，执行前有 10 秒倒计时可以 Ctrl+C 取消。
- 全部 `database` 子命令成功返回 0、失败返回非 0，可直接用于脚本判断。

MariaDB 11.8 会在直接调用旧程序名时打印弃用提示。新版安装流程内部优先调用
`mariadb`、`mariadb-dump`、`mariadb-admin` 等新名称，同时用包装器保留
`mysql`、`mysqldump`、`mysqladmin` 等旧命令，因此原有运维脚本仍可继续使用。

### 8.4 备份

推荐用内置的备份命令，它会自动导出数据库与网站程序、生成校验清单，
配置了异地之后自动上传：

```bash
lnmp backup init                     # 扫描已有站点、挑选后生成配置，并装好 systemd timer
lnmp backup run all                  # 立即完整跑一次
lnmp backup run wp.example.com       # 只备份某个站点（文件与它的库）
lnmp backup run db  wp.example.com   # 只备份某个站点的库
lnmp backup run web wp.example.com   # 只备份某个站点的文件
lnmp backup status                   # 上次结果与下次计划
lnmp backup test                     # 试恢复验证：导入临时库校验后删除
```

`init` 会扫描 nginx / apache 的 vhost 配置，反查站点目录，并从
`wp-config.php` 里读出 `DB_NAME`，生成形如
`域名|网站目录|数据库名` 的条目写进 `/etc/lnmp/backup.conf`（权限 600）。
新建站点后重跑一次 `init`，或手工往配置里加一行。

`init` 交互要点：

- **挑选站点**：扫描到站点后会列出编号，让你选哪些纳入备份 ——
  回车全选；`1 3` 或直接写域名只备份指定项；`-2` 或 `-default` 排除指定项
  （`default` 这类占位站点在这一步排掉即可）。EOF、连续三次乱输入、
  或排除到一个不剩，都会安全退回全选或重新询问。
- **备份目录**：会询问存放目录（默认 `/home/backup`），只接受绝对路径且不能是
  系统目录；磁盘不够时在这里改到大盘。
- **参数提示**：结尾会醒目列出仍是默认值、需要按实际情况修改的项，尤其是默认关闭
  的异地上传（`Enable_Remote_Backup` 及各 `Remote_*`）与加密。改完配置直接生效，
  不必重跑 `init`，只有要改执行时间才需要重跑。

只备份指定站点（`run [db|web] <域名>…`）是临时补一份用的：它不会推进网站备份周期、
也不会清理任何本地或远端旧批次；给的域名只要有一个不在配置里就整体报错并列出可用
站点，不会静默漏备。

要点：

- 数据库和网站各有各的周期与保留天数。默认库每次都备份、保留 14 天；
  网站每 7 天一次、保留 60 天，用 `Web_Interval_Days`、`Keep_Days_Db`、
  `Keep_Days_Web` 调整。
- 批次目录用秒级时间戳，同一天跑多次不会互相覆盖；保留策略删除的是
  所有早于保留期的批次，不是只删“正好第 N 天”那一批。
- 每个批次带 `SHA256SUMS`，`restore` 与 `test` 会先校验再动手，
  校验不过直接拒绝。这份清单只在批次内全部产物都成功之后才写入，
  所以它也是完整性判据：`lnmp backup list` 对缺少清单的批次标
  `[不完整：缺校验清单]`，挑批次恢复时不要只看文件个数。
- 中途失败的批次不会留下空目录：全部产物都失败时（例如目标磁盘写满）
  批次目录会被删掉；部分成功时保留已产出的文件并标为不完整，
  同时跳过旧批次清理，已有的恢复点不受影响。
- 异地上传默认关闭，开启方法和备份机侧的配置见 [8.5 异地备份（SFTP）](#85-异地备份sftp)。
  上传先传到远端 `.incoming/<批次>/`，逐个核对大小无误后才改名到正式目录，
  最后才清理远端旧批次 —— 传输中断不会损失已有的恢复点。
- 同一时刻只允许一个备份在跑（flock，没有 flock 的环境退回 mkdir 锁）。

恢复：

```bash
lnmp backup list                       # 先看有哪些批次
lnmp backup restore db  wpdemo         # 不给批次就用最新的一批
lnmp backup restore web wp.example.com 20260810-033000
```

> `tools/backup.sh` 是旧模板，已废弃，现在只会把请求转发到
> `lnmp backup run all`。老的 cron 条目请改成 `/bin/lnmp-backup run`。

如果要手工备份，WordPress 站点至少要备份两样：**数据库** 和 **`wp-content/` 目录**
（主题、插件、上传的媒体文件）。核心文件可以重新下载，这两样不能。

```bash
# 数据库：无人值守场景使用 option file，不将密码放入命令行参数
umask 077
cat > /root/.wpdemo.cnf <<'EOF'
[client]
user=wpdemo
password=换成你的库用户密码
host=127.0.0.1
EOF
chmod 600 /root/.wpdemo.cnf

mysqldump --defaults-file=/root/.wpdemo.cnf --single-transaction \
  wpdemo | gzip > /root/backup/wpdemo-$(date +%F).sql.gz

# 站点文件
tar czf /root/backup/wp-content-$(date +%F).tar.gz \
  -C /home/wwwroot/wp.example.com wp-content
```

> `--single-transaction` 让 InnoDB 表在备份期间不锁表，站点不用停。

### 8.5 异地备份（SFTP）

> 上传、大小核对、目录改名与 systemd timer 安装已在受限 `internal-sftp`
> 账号（chroot + `ForceCommand`）上实测通过。仍建议第一次配置时按 8.5.4
> 的顺序逐步确认，不要直接依赖定时任务 —— 出错多半出在备份机侧的
> 权限与主机指纹上，逐步走一遍能立刻定位。

本地备份在 `lnmp backup init` 之后就已经自动执行了。异地上传默认关闭，
需要一台**独立的备份服务器**，并在两侧各配一次。

整体结构：

```
生产机                                备份机
/home/backup/                        /srv/sftp/backupuser/   ← chroot 根
  db/<批次>/  ── SFTP ──────────────→   backup/
  www/<批次>/                            db/<批次>/
                                         www/<批次>/
                                         .incoming/          ← 上传中转
```

上传过程是：先传到 `.incoming/<批次>-<类型>/`，逐个核对文件大小，
全部对上之后把整个目录 `rename` 到正式位置，最后才清理远端过期批次。
所以传输中断不会损失已有的恢复点，也不会在正式目录里留下残缺文件。

#### 8.5.1 备份机：建账号和目录

以下命令在**备份服务器**上执行。

```bash
# 专用账号，不给 shell
useradd -m -d /home/backupuser -s /usr/sbin/nologin backupuser

# chroot 根目录：必须 root 所有，且不能被组或其他人写，
# 否则 sshd 会拒绝登录并在日志里报 "bad ownership or modes"
mkdir -p /srv/sftp/backupuser
chown root:root /srv/sftp/backupuser
chmod 755 /srv/sftp/backupuser

# chroot 内真正存备份的子目录，这个才属于备份账号
mkdir -p /srv/sftp/backupuser/backup
chown backupuser:backupuser /srv/sftp/backupuser/backup
chmod 700 /srv/sftp/backupuser/backup
```

> chroot 根本身对该账号是只读的，这是 OpenSSH 的硬性要求。
> 备份写在下面那个 `backup/` 子目录里，生产机配置中的
> `Remote_Dir="backup"` 指的就是它（相对 chroot 根）。

#### 8.5.2 备份机：限制这个账号只能做 SFTP

编辑 `/etc/ssh/sshd_config`，在**文件末尾**追加（`Match` 块必须放在最后，
它之后的配置都属于这个块）：

```
Match User backupuser
    ChrootDirectory /srv/sftp/backupuser
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
```

检查语法后重载：

```bash
# Debian/Ubuntu：
sshd -t && systemctl reload ssh

# EL（按需执行，不要和上一条同时执行）：
# sshd -t && systemctl reload sshd
```

`sshd -t` 没有输出就是通过了。**先别关掉当前的 SSH 会话**，
另开一个连接确认登录正常，再关闭旧会话。

#### 8.5.3 生产机：密钥与主机指纹

以下命令回到**生产服务器**上执行。

**第一步，生成专用密钥。** 不要复用日常登录的密钥 —— 这把钥匙就放在被备份的
这台机器上，一旦这台机器失陷，它能开的门越少越好：

```bash
ssh-keygen -t ed25519 -N '' -f /root/.ssh/lnmp_backup
```

**第二步，把公钥装到备份机。** 把 `/root/.ssh/lnmp_backup.pub` 的内容加到备份机的
`/home/backupuser/.ssh/authorized_keys`，并在前面加上限制前缀：

```
restrict,command="internal-sftp" ssh-ed25519 AAAAC3NzaC1...（你的公钥）
```

备份机上这两个权限必须对，否则公钥认证会被静默拒绝：

```bash
chown -R backupuser:backupuser /home/backupuser/.ssh
chmod 700 /home/backupuser/.ssh
chmod 600 /home/backupuser/.ssh/authorized_keys
```

> `authorized_keys` 放在 `/home/backupuser/` 而不是 chroot 里面，是因为
> sshd 读它是在切进 chroot **之前**、以 root 身份读的。

**第三步，固定并核对主机指纹。** 备份脚本用
`StrictHostKeyChecking=yes`，遇到未知主机直接失败，不会像 `accept-new`
那样在首次连接时盲信 —— 所以这一步必须做：

```bash
ssh-keyscan -p 22 备份机地址 > /root/.ssh/lnmp_backup_known_hosts
ssh-keygen -lf /root/.ssh/lnmp_backup_known_hosts
```

记下输出的指纹，然后**到备份机本机上**（不要通过刚才那条网络连接）执行：

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

两边的指纹逐字比对，对上了才算可信。对不上说明中间有人，别继续。

```bash
chmod 600 /root/.ssh/lnmp_backup /root/.ssh/lnmp_backup_known_hosts
```

#### 8.5.4 生产机：开启上传并验证

编辑 `/etc/lnmp/backup.conf`（权限 600），改这几项：

```bash
Enable_Remote_Backup=1
Remote_Host="备份机地址"
Remote_Port=22
Remote_User="backupuser"
Remote_Dir="backup"
Remote_SSH_Key="/root/.ssh/lnmp_backup"
Remote_Known_Hosts="/root/.ssh/lnmp_backup_known_hosts"
```

**按这个顺序验证，不要跳步**：

```bash
# 1. 先单独确认 SFTP 通道本身是通的
sftp -i /root/.ssh/lnmp_backup      -o IdentitiesOnly=yes      -o StrictHostKeyChecking=yes      -o UserKnownHostsFile=/root/.ssh/lnmp_backup_known_hosts      backupuser@备份机地址
# 进去之后执行 pwd 应显示 /，ls 能看到 backup 目录，然后 bye

# 2. 完整跑一次备份（包含上传）
lnmp backup run all
echo "退出码：$?"       # 必须是 0

# 3. 看本地和远端各有哪些批次
lnmp backup list

# 4. 验证备份真的能恢复
lnmp backup test
```

只有第 2 步退出码为 0、且第 3 步的「远端 db 批次」里能看到刚才的批次，
这条路才算真的通了。之后 systemd timer 会每天自动执行同样的 `run`，
库每天一份、网站按 `Web_Interval_Days` 的周期一份，都会自动上传。

```bash
systemctl list-timers lnmp-backup.timer    # 确认下次触发时间
journalctl -u lnmp-backup.service -n 50    # 看最近一次自动执行的输出
tail -f /var/log/lnmp/backup.log           # 备份任务日志
```

#### 8.5.5 出错时对照排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `HOST KEY VERIFICATION FAILED` | 备份机主机密钥与记录的指纹不符 | **先查清楚原因**。备份机重装过就重新 keyscan 并带外核对；否则按中间人处理，不要直接覆盖 known_hosts |
| `Permission denied (publickey)` | 公钥没装对，或备份机上 `.ssh`/`authorized_keys` 权限不对 | 检查 700 / 600，以及属主是不是 backupuser |
| 登录就断开，日志报 `bad ownership or modes for chroot directory` | chroot 根不是 root 所有或被组/其他人可写 | `chown root:root` + `chmod 755` |
| `远端缺少文件` 或 `远端文件大小不符` | 上传中断或备份机磁盘满 | 脚本已拒绝改名，正式目录没被污染。清理 `.incoming` 后重跑；先看备份机 `df -h` |
| 远端改名失败 | 该账号在 chroot 内没有写权限 | 确认 `backup/` 子目录属主是 backupuser 且权限 700 |
| `找不到数据库 option file` | 没在 `init` 时填数据库密码 | 重跑 `lnmp backup init`，或手工建 `/etc/lnmp/backup-mysql.cnf`（600） |
| `另一个备份任务正在运行` | 上一次还没跑完，或异常退出留下了锁 | 用 `lnmp backup status` 看上次执行时间；确认没有在跑的任务后删除 `/var/lock/lnmp-backup.lock*` |
| 备份成功但没有自动执行 | timer 没启用 | `systemctl enable --now lnmp-backup.timer` |

#### 8.5.6 只有 FTP 服务器可用时

有些机房只提供一台老 FTP 服务器，没有 SSH。备份支持这种情况，但**它不是
推荐做法**，两种方式的差别要先看清楚：

| | 凭据 | 传输 | 说明 |
|---|---|---|---|
| `sftp` | SSH 密钥 | 加密 | 默认，推荐 |
| `ftps` | 账号口令 | TLS 加密 | 需要对端支持 AUTH TLS，并校验证书 |
| `ftp` | 账号口令 | **全程明文** | 口令和整包备份数据在链路上任何一跳都可读 |

如果对端也是本项目新装的 Pure-FTPd，必须选 `ftps`：其默认配置是 `TLS 2`，普通
`ftp` 会在登录阶段被拒绝。外部旧 FTP 服务仍可显式选 `ftp`，但这不会获得任何传输加密。

改 `/etc/lnmp/backup.conf`：

```bash
Enable_Remote_Backup=1
Remote_Protocol="ftps"        # 或 "ftp"
Remote_Host="ftp.example.com"
Remote_Port=21                # 注意从 22 改成 21
Remote_User="bkuser"
Remote_Password="口令"        # sftp 不用这项，ftp/ftps 必填
Remote_Dir="backup"
Remote_Ftp_Verify=1           # ftps 校验对端证书，默认开
Remote_Ftp_CA=""              # 自签证书填 CA 路径，不要直接关校验
```

上传流程与 sftp 完全一致：先传到远端 `.incoming/<批次>-<类型>/`，逐个核对
文件大小，全部对上之后整个目录改名到正式位置，最后才清理远端旧批次。
用的是 `curl`，口令写在权限 600 的 curl 配置文件里，不进命令行参数。

选 `ftp` 时每次运行都会在日志里留下明文告警。条件允许就换 `ftps`，
再不济也可以先建 SSH 隧道再让 FTP 跑在隧道里。

#### 8.5.7 备份加密（age 或 GPG）

默认不加密。备份存放在第三方机房、对象存储或外部 FTP 时应启用加密；
本机磁盘上的加密主要降低磁盘离线泄露风险。

加密在压缩之后、上传之前做：`db-<库>.sql.gz` 变成 `db-<库>.sql.gz.enc`，
明文随即删除，`SHA256SUMS` 记的是加密后的文件。`restore` 与 `test` 会自动
解密，不需要额外参数。

**age（推荐，密钥短、命令简单）**：

```bash
apt-get install -y age            # Debian/Ubuntu；EL 系在 EPEL 里（dnf install epel-release age）

# 生成密钥对。公钥（age1... 那一行）用来加密，私钥文件用来解密
mkdir -p /root/.config/lnmp
age-keygen -o /root/.config/lnmp/backup-age.key
chmod 600 /root/.config/lnmp/backup-age.key
# 输出里的 "Public key: age1..." 就是下面要填的 Encrypt_Recipient
```

改 `/etc/lnmp/backup.conf`：

```bash
Enable_Encrypt=1
Encrypt_Tool="age"
Encrypt_Recipient="age1...（上一步的公钥）"
Encrypt_Identity="/root/.config/lnmp/backup-age.key"
```

**GPG（已有 GPG 密钥体系时用）**：

```bash
gpg --quick-generate-key "backup <bk@example.com>" default default never
gpg --list-keys --with-colons | awk -F: '/^fpr/{print $10; exit}'   # 取指纹
```

```bash
Enable_Encrypt=1
Encrypt_Tool="gpg"
Encrypt_Recipient="上一步的指纹或邮箱"
```

GPG 分支解密走本机 keyring，不读 `Encrypt_Identity`；私钥有口令时
无人值守的定时任务会卡住，要么用空口令的专用密钥，要么配 gpg-agent 缓存。

**验证一次**：

```bash
lnmp backup run db
ls /home/backup/db/*/            # 应该只有 .enc 和 SHA256SUMS，没有 .gz
file /home/backup/db/*/*.enc     # age: "age encrypted file"；gpg: "data"
lnmp backup test                 # 解密 + 校验 + 试恢复，退出码必须是 0
```

> **私钥必须存到这台机器之外。** 私钥和加密后的备份放在同一台机器上，
> 等于没加密；而一旦这台机器没了、私钥也只有这一份，备份就永远打不开了。
> 至少复制一份到离线介质，并且**在另一台机器上真的解密一次**验证它可用。

失败时的行为：`Encrypt_Recipient` 没配、收件人无效、找不到 age/gpg 命令，
都会让该批次失败退出（返回 1）并**连同未加密的明文一起删除** ——
开了加密就不会有明文留在备份目录里。解密侧私钥不对或文件缺失时
`test` / `restore` 报"解密失败。"并返回 1，不会导入半截数据。

#### 8.5.8 关于远端校验的边界

远端只做**逐个文件的大小核对**，不是内容校验。

受限的 `internal-sftp` 账号不能在备份机上执行命令，所以脚本没法让远端算
SHA-256。大小核对能发现传输截断和文件缺失，发现不了内容被改写。
内容级校验依赖每个批次里的 `SHA256SUMS`，在生产机本地做（`restore` 和
`test` 都会先校验再动手）。

要做到远端内容校验，需要备份机侧配合，两个方向：在备份机上放一个定期
`sha256sum -c SHA256SUMS` 的任务；或者改用允许执行受限命令的通道。
这部分不属于本包能单独完成的范围。

### 8.6 日志

| 日志 | 路径 |
|---|---|
| nginx 错误日志 | `/home/wwwlogs/nginx_error.log` |
| 站点访问日志 | `/home/wwwlogs/<域名>.log` |
| PHP-FPM 日志 | `/usr/local/php/var/log/php-fpm.log` |
| MySQL 错误日志 | `/usr/local/mysql/var/<主机名>.err` |
| MariaDB 错误日志 | `/usr/local/mariadb/var/mariadb.err` |
| Redis 日志 | `/usr/local/redis/var/redis.log` |
| 安装日志 | `/root/lnmp-install.log` |

日志切割：

在保存本项目源码的目录内执行：

```bash
bash tools/cut_nginx_logs.sh
```

default 站点的日志是 `/home/wwwlogs/default.log` 和
`/home/wwwlogs/default.error.log`。访问日志使用 `nginx.conf` 中的 `main` 格式：

```nginx
log_format main '$time_iso8601 $status "$request_time" $remote_addr $scheme://$http_host "$request" '
                '$body_bytes_sent "$http_referer" '
                '"$http_user_agent" "$http_x_forwarded_for" $remote_user';
```

经过 Cloudflare 或其它反向代理时，不能直接把任意请求头当成真实 IP。先限制源站
只接受可信代理地址，再取消 `nginx.conf` 中示例的注释并把站点日志格式改为
`main_proxy`。示例的取值顺序是：`X-Forwarded-For` 逗号列表第一个地址、
`X-Real-IP`、最后才是连接源 `$remote_addr`；日志末尾还保留 `peer=`，便于核对
实际连接到源站的代理地址。未限制源站时不要启用，因为直连客户端可以伪造
`X-Forwarded-For` 和 `X-Real-IP`。

---

## 九、故障排查

### 9.1 站点 502 Bad Gateway

按顺序查：

```bash
# 1. php-fpm 是否在跑
lnmp status

# 2. socket 是否存在、权限是否对
ls -la /run/php-fpm/php-cgi.sock  # 应为 www:www 0660

# 3. 看 php-fpm 日志
tail -50 /usr/local/php/var/log/php-fpm.log

# 4. 是不是进程数打满了（高并发时最常见）
grep "server reached pm.max_children" /usr/local/php/var/log/php-fpm.log
```

最后一条如果有输出，调大 `pm.max_children`（见 6.3），
但**先确认内存够**，否则只会从 502 变成 OOM。

本包自带一个快速自检脚本：

```bash
bash tools/check502.sh
```

### 9.2 WordPress 后台白屏

生产环境排错有两条铁律：**错误不得能显示给访客**，**日志不得能放在 Web 根目录下**。

```bash
SITE=/home/wwwroot/wp.example.com

# 日志目录放在站点根目录之外，Web 完全够不着
mkdir -p /var/log/wordpress && chown www:www /var/log/wordpress && chmod 750 /var/log/wordpress

# 三个常量必须一起设：
#   WP_DEBUG = true
#   WP_DEBUG_DISPLAY = false
#     这一项不能省略，否则绝对路径、SQL、插件上下文甚至请求密钥会直接显示给访客
#   WP_DEBUG_LOG = 站点目录之外的日志路径
chattr -i ${SITE}/.user.ini 2>/dev/null
cat >> ${SITE}/wp-config-debug.snippet <<'EOF'
define( 'WP_DEBUG', true );
define( 'WP_DEBUG_DISPLAY', false );   // 不得能少
@ini_set( 'display_errors', 0 );
define( 'WP_DEBUG_LOG', '/var/log/wordpress/debug.log' );
EOF
echo "把上面几行加到 wp-config.php 里 require_once 之前，复现问题后立刻删除"

# 复现后看（日志在站外，Web 下载不到）
tail -50 /var/log/wordpress/debug.log
```

> 注意：**不要使用默认的 `WP_DEBUG_LOG = true`**，否则日志会写入
> `wp-content/debug.log`，位于 **Web 根目录内**，任何人都可能直接下载。
> 已存在此类配置时应立即删除：
> ```bash
> rm -f /home/wwwroot/*/wp-content/debug.log
> ```
> 并在站点配置中增加回退规则（放在 `include enable-php.conf;` 之前）：
> ```nginx
> location ~* \.(log|sql|bak|old|swp|env)$ { deny all; }
> ```

**排查完成后立即恢复配置并清理日志**。debug 日志可能集中记录敏感信息。

最常见的原因是 `memory_limit` 不够（见 6.2）。

### 9.3 文章页 404 但首页正常

伪静态没生效。检查站点配置里有没有引用 wordpress 规则：

```bash
grep rewrite /usr/local/nginx/conf/vhost/wp.example.com.conf
# 应该有：include rewrite/wordpress.conf;
```

没有就手工加进 `server {}` 块，然后 `lnmp nginx reload`。

### 9.4 上传大文件失败

三个地方的上限要一起看，取最小值生效：

```bash
grep -E "upload_max_filesize|post_max_size" /usr/local/php/etc/php.ini
grep client_max_body_size /usr/local/nginx/conf/nginx.conf
```

### 9.5 Redis 缓存不生效

```bash
# 检查 Redis 服务
redis-cli ping

# 检查 PHP 扩展
php -m | grep redis

# 检查 drop-in 是否部署
ls -la /home/wwwroot/<域名>/wp-content/object-cache.php

# 检查对象缓存是否真的在写入
redis-cli --scan --pattern "<前缀>:*" | wc -l
```

### 9.6 数据库连接失败

```bash
# 用 wp-config.php 里的凭据手工连一次，直接看真实报错
mysql -u wpdemo -p -h 127.0.0.1 wpdemo
```

- `Access denied` → 密码错误，或账号仅授权 `localhost` 而客户端连接 `127.0.0.1`
- `Can't connect` → 数据库没启动；按实际分支执行 `lnmp mysql start` 或 `lnmp mariadb start`

### 9.7 忘记数据库 root 密码

回到保存本项目源码的目录后执行：

```bash
bash tools/reset_mysql_root_password.sh
```

该脚本重置期间会关闭网络监听、只用私有 socket，数据库不对外可见。

---

## 十、安全基线

### 10.1 本项目提供的主机基线

本包安装后已经做好的：

| 项 | 状态 | 注意 |
|---|---|---|
| 防火墙 | nftables `inet lnmp` 表，放行 22/80/443 + ICMP，**3306 / 6379 / 11211 显式 drop** | **链策略是 `policy accept`**，不是默认拒绝：它仅阻断明确列出的端口，不表示只允许这些端口 |
| MySQL / MariaDB | 无匿名用户；root 只能从 localhost 登录；无 test 库；**`bind-address = 127.0.0.1`**；socket 位于 `/run/mysqld/` | MySQL 另把 X Protocol 绑定回环且不默认启用 `mysql_native_password`；MariaDB 没有 X Protocol，使用自身认证逻辑 |
| Redis | 只监听回环；以专用低权限账号运行 | 回环是必要条件但不是充分条件；认证、跨机访问和多站点隔离见“安装 Redis”一章 |
| Memcached | 只监听回环；以专用低权限账号运行 | 协议本身不提供可靠的租户隔离，不要对公网开放；互不信任的站点应拆分实例和系统账号 |
| PHP | `disable_functions` 禁用 exec 系列（含 `pcntl_exec`）；FPM socket 位于 `/run/php-fpm/` 且为 0660；每站点 `open_basedir` 隔离 | `open_basedir` 限制文件路径访问，**不提供**操作系统级租户隔离：多站点共用 `www` 账号时没有内核层面的边界 |
| Apache（LAMP/LNMPA） | 只把末尾 `.php` 交给 mod_php；根目录默认拒绝；站点使用 `SymLinksIfOwnerMatch` | 已在 Debian 13 两种栈实测；其它发行版部署前仍需复验模块与目录边界 |
| Pure-FTPd | 新安装默认 `TLS 2`，拒绝明文登录 | 客户端选择显式 FTPS；既有部署需直接核对运行配置，不会被源码更新自动改写 |
| phpinfo / phpMyAdmin / 演示页 | **默认全部不部署** | 需在 `lnmp.conf` 显式开启 |
| default 站点的 PHP 边界 | 只放行 `phpinfo.php` / `redis.php` / `memcached.php` 三个固定文件名与 phpMyAdmin 入口，其余 `.php` 一律拒绝 | 放行的三个文件仅在对应开关打开时才会写入，未写入时访问返回 404；往 default 根目录手工放同名文件同样会被执行，该站点是系统默认创建，其他需求 php 的请自建新站点 |
| phpMyAdmin（已开启时） | 装在网站根目录之外（`/usr/local/phpmyadmin`）；访问路径随机生成 | 挡的是批量扫描与源码直接下载，**不等于**做了访问控制；对外服务仍建议加来源白名单 |
| 下载完整性 | **默认要求一种已配置的完整性机制**，按组件不同分别是：静态 SHA256 清单（`src/checksums.sha256`）、上游发布的 SHA256、**PGP 签名**（nginx / OpenResty 源码）、**包仓库 GPG 签名**（OpenResty apt/yum） | 不是"全部 SHA256"；且 `Enable_Download_Checksum` **可以被关掉**，关掉就没有这层保护 |

> **注意：上表描述的是安装脚本的目标状态，不代表当前系统的实际状态。**
> 防火墙规则可能因 nftables 缺失或写入失败而未生效。此时安装会以
> 非零退出码结束并打印告警；如果忽略该告警，
> 或者事后修改过防火墙，必须重新确认。**上线前应执行以下检查**：
>
> ```bash
> nft list table inet lnmp                    # 确认规则存在
> ss -lntp | grep -E ':3306|:6379|:11211'     # 确认端口仅监听回环地址
> ps -o user,cmd -C redis-server -C memcached # 确认进程不以 root 运行
> ```

仍需管理员完成以下配置：

1. **改 SSH 端口 / 禁用密码登录**，本包不碰 SSH 配置
2. **按需给 phpMyAdmin 追加来源限制**。

   本包已经做了两层处理，不需要再手工搬目录或改 default 站点的配置：

   - **程序装在 `/usr/local/phpmyadmin`**，不在网站根目录下。
     即使 Web 服务器配置失效（改错、被覆盖、模块没加载），
     源码和 `config.inc.php` 也不会被当作静态文件下载。
   - **访问路径每次安装随机生成**，形如 `49763abb_phpmyadmin`，
     针对固定 `/phpmyadmin/` 的批量扫描直接落空。

   路径在安装结束时打印，之后可以随时查：

   ```bash
   lnmp status          # 末尾一行回显 phpMyAdmin 的访问地址
   cat /usr/local/phpmyadmin/.access_url
   ```

   映射片段由安装脚本生成在 `/usr/local/nginx/conf/phpmyadmin.enable.conf`
   （Apache 为 `/usr/local/apache/conf/extra/phpmyadmin.enable.conf`），
   主配置用通配 `include` 引入。Nginx 片段同时带入 default 站点的 PHP 处理配置
   （LNMPA 为 Apache 反代配置）。**开关两个方向都由脚本负责**：关闭时片段会被
   移出通配符匹配范围，default 立即恢复为静态站；重新开启时原子移回。

   随机路径保留 `_phpmyadmin` 结尾，是为了在 default 站点配了严格访问控制时，
   便于识别路径用途，配置放行或封禁规则时可减少误操作。

   如果还要再收紧到指定来源，编辑上述片段，在 `location ^~` 块里加白名单：

   ```nginx
   location ^~ /49763abb_phpmyadmin/ {
       allow 你的办公IP;
       deny all;

       alias /usr/local/phpmyadmin/;
       index index.php;
       # ……以下保持片段中原有的内层 location 不变
   }
   ```

   > 这里必须用 `^~`。换成普通前缀 `location /49763abb_phpmyadmin/`，
   > 静态文件会被拦住，但 `.php` 请求会跳过它去匹配 `enable-php.conf` 里的
   > **正则** location——nginx 中正则优先于普通前缀，结果是
   > 文本路径 403、`index.php` 仍然 200，形成虚假的安全预期。
   > 片段中生成的就是 `^~`，照着改即可。

   改完两类地址都要验证，`nginx -t` 只能查语法：

   ```bash
   nginx -t && lnmp nginx reload
   # 非白名单地址访问 .php 和静态文件都应返回 403
   curl -o /dev/null -w "%{http_code}\n" http://你的域名/49763abb_phpmyadmin/index.php
   ```

   也可以干脆不装 phpMyAdmin，需要时用 SSH 隧道直连数据库。
3. **WordPress 后台加固**：为管理员启用两步验证或 passkey，并限制登录爆破
4. **及时更新**：WordPress 核心、插件和主题漏洞是主要入侵途径，停用但未删除的代码
   仍在磁盘上，同样需要更新或删除
5. **定期执行异地备份恢复测试**，确认备份文件有效、密钥可用且恢复时间可接受

### 10.2 WordPress 应用层基线

LNMP 的防火墙、`open_basedir` 和禁用函数不能弥补 WordPress 插件漏洞。生产站至少落实
以下各项，并保留变更记录：

1. **更新策略按风险分层**。核心安全/维护更新及时应用；插件、主题和 PHP 大版本先在
   克隆环境回归登录、下单、支付回调、计划任务和缓存清除。删除不用的插件/主题，不能
   只“停用”。源码安装的 Nginx/PHP/MySQL 不会随 `apt upgrade` 自动升级。
2. **账号最小权限**。日常编辑不用 Administrator；管理员启用两步验证/passkey，恢复码
   离线保存。自动化和外部客户端使用可撤销的 Application Password，不共享后台密码。
   改默认用户名本身不是安全控制，真正有效的是强随机密码、MFA 和速率限制。
3. **禁止后台编辑代码**。在 `wp-config.php` 加 `DISALLOW_FILE_EDIT`，防止已取得后台权限的
   账号直接用主题/插件编辑器落地 PHP。只有采用外部发布、能持续安装安全更新的环境才设
   `DISALLOW_FILE_MODS=true`；普通站点盲目设置会连自动更新一起阻断。
4. **文件写权限最小化**。本指南让核心、插件和主题归 `root:www` 且不可由 PHP 修改，
   只给 uploads/cache/upgrade 等必要目录写权限。这会要求管理员通过受控发布流程更新代码，
   但能显著限制 Web 进程被利用后的持久化范围。不要为解决一次更新失败递归 `chmod 777`。
5. **数据库每站独立**。`lnmp vhost add` 创建的站点用户只授权自己的库；不要把数据库
   root 写进 `wp-config.php`，不要多个互不信任站点共用同一个库用户。备份凭据与站点凭据
   分开，文件权限保持 600/640。
6. **密钥与会话**。使用 WordPress 官方 salt 服务生成唯一 Authentication Keys/Salts，
   每套环境不同；怀疑凭据泄露时轮换会使现有会话失效。`wp-config.php` 不提交 Git，
   不放在可下载备份目录，也不在工单/聊天中粘贴。
7. **不要无脑禁用 REST API 或 XML-RPC**。区块编辑器、应用密码和许多插件依赖 REST；
   XML-RPC 仍可能被移动客户端、Jetpack 或 pingback 使用。先盘点依赖：确实不用 XML-RPC
   才在 Web 层拒绝 `/xmlrpc.php`；需要时保留并对认证失败、`system.multicall` 和来源做
   速率限制。隐藏版本号、改登录 URL 都只能减少噪声，不是漏洞修复。
8. **登录防护放在正确层**。优先使用能识别真实客户端 IP 的 CDN/WAF 或维护良好的
   WordPress 限速/MFA 方案。若在 Nginx 限速，必须先正确配置可信代理地址；直接信任任何
   `X-Forwarded-For` 会让攻击者伪造 IP 绕过限制。阈值要允许密码管理器、移动网络和多人
   NAT，避免把登录可用性变成拒绝服务入口。
9. **HTTPS 与代理边界**。后台启用 `FORCE_SSL_ADMIN`；使用 CDN/反向代理时只信任固定代理
   网段传来的 scheme/IP 头，并限制源站不能被公网绕过。HSTS 只在所有子域都能长期 HTTPS
   后启用 `includeSubDomains`；CSP 需要按实际主题/插件资源逐步收紧，不能复制一条通用值。
10. **可恢复性和检测**。异地备份至少覆盖数据库、`wp-content`、Web 配置和证书恢复所需
    信息，定期执行 `lnmp backup test` 并做整站恢复演练。监控核心文件变化、管理员新增、
    插件安装、PHP-FPM/Nginx 错误和异常外连；安全插件不是替代主机日志与恢复演练的理由。

建议加入 `wp-config.php`、且不会阻断正常更新的两项：

```php
define( 'DISALLOW_FILE_EDIT', true );
define( 'FORCE_SSL_ADMIN', true );
```

WordPress 自动更新是否可写与本指南的 root-owned 发布模型存在明确取舍：保持代码不可写时，
管理员必须建立固定的更新窗口，用 root 部署官方包/经过审计的插件，然后恢复属主权限并
回归测试；不能既禁止 Web 写代码，又假设后台自动更新仍会成功。

### 10.3 禁止上传目录执行 PHP

禁止 PHP 在上传目录执行（WordPress 被上传 webshell 的常见路径）：

```nginx
location ~* ^/wp-content/uploads/.*\.(php|php5|phtml)$ {
    deny all;
}
```

> 注意：**该规则必须放在 `include enable-php.conf;` 之前。**
>
> nginx 对正则 location 是**按配置里出现的顺序**匹配，用**第一个**匹配上的。
> `enable-php.conf` 里的 `location ~ [^/]\.php(/|$)` 能匹配任何 `.php`，
> 包括 uploads 下的。因此，将上述配置追加到 server 块**末尾**时，
> 该规则不会被匹配，上传的 webshell 仍会交给 PHP-FPM 执行。
>
> `lnmp vhost add` 生成的配置里，`include enable-php.conf;` 在 server 块中部，
> 编辑 `/usr/local/nginx/conf/vhost/<域名>.conf` 时，将上述规则置于该 include 之前。
>
> 建站时选了不开启 PHP 的站点没有这一行，取而代之的是一段返回 404 的
> `location ~ [^/]\.php(/|$)`，站内任何 `.php` 都不会执行，不需要再加本规则（见 4.4）。

修改后应验证实际请求结果；`nginx -t` 通过不代表规则已经生效：

```bash
nginx -t && lnmp nginx reload

# 放一个测试文件，确认它不会被执行（应返回 403，而不是输出内容）
echo '<?php echo "EXECUTED";' > /home/wwwroot/<域名>/wp-content/uploads/t.php
curl -o /dev/null -w "%{http_code}\n" http://<域名>/wp-content/uploads/t.php   # 期望 403
rm -f /home/wwwroot/<域名>/wp-content/uploads/t.php
```

实测确认：规则插在 `include enable-php.conf;` 之前时返回 **403**；
放在末尾时返回 **200 并执行**。

---

## 十一、依据与校准方法

本指南的数值建议不是从旧版“优化参数合集”复制而来，依据分为两类：

- **项目实现事实**：版本、默认值、路径、端口、菜单和自动分档均来自当前
  `install.sh`、`lnmp.conf`、`include/*.sh`、`conf/lnmp`、`tools/*.sh`。例如项目确实会
  将 4~8GB 主机的 FPM `max_children` 设为 60、MySQL buffer pool 设为 512M；指南明确
  记录该行为，但不把它直接当作混部 VPS 推荐值。
- **容量建议**：先从整机内存预算和并发上界推导保守起点，再要求用高峰 PSS、
  `Max_used_connections`、Redis 命中/淘汰、Swap/PSI/OOM 和恢复演练校准。没有一个百分比
  能同时适用于静态博客、WooCommerce、页面构建器和多站点。

进一步核对时优先读上游文档：

- [PHP-FPM 配置指令](https://www.php.net/manual/en/install.fpm.configuration.php)与
  [OPcache 配置](https://www.php.net/manual/en/opcache.configuration.php)：进程模型、
  `pm.max_children`、空闲回收和 OPcache 容量的实际语义。
- [MySQL 8.4 InnoDB Buffer Pool](https://dev.mysql.com/doc/refman/8.4/en/innodb-buffer-pool.html)
  与[服务器系统变量](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html)：
  区分全局缓存、每线程/每连接 buffer 和动态/需重启参数。
- [MariaDB InnoDB Buffer Pool](https://mariadb.com/kb/en/innodb-buffer-pool/)与
  [Query Cache](https://mariadb.com/kb/en/query-cache/)：核对 MariaDB 自己的变量语义，
  不把已经与 MySQL 分叉的实现混用。
- [Redis key eviction](https://redis.io/docs/latest/develop/reference/eviction/)与
  [内存优化](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/memory-optimization/)：
  `maxmemory`、淘汰策略及进程额外内存的边界。
- [WordPress Hardening](https://developer.wordpress.org/advanced-administration/security/hardening/)、
  [WordPress 运行要求](https://wordpress.org/about/requirements/)、
  [更新 WordPress](https://developer.wordpress.org/advanced-administration/upgrade/upgrading/)和
  [把 WP-Cron 接入系统调度](https://developer.wordpress.org/plugins/cron/hooking-wp-cron-into-the-system-task-scheduler/)：
  文件权限、更新、密钥、账号与定时任务。
- [Debian Security](https://www.debian.org/security/)与
  [Debian stable release notes](https://www.debian.org/releases/stable/releasenotes)：系统更新、
  已知问题和升级边界；VPS 的安全组、磁盘和网络限制还要以云厂商文档为准。
- [Nginx 核心模块](https://nginx.org/en/docs/http/ngx_http_core_module.html)与
  [gzip 模块](https://nginx.org/en/docs/http/ngx_http_gzip_module.html)：连接、上传、location、
  压缩等指令的真实上下文，不以博客片段替代语法和优先级规则。

上游文档说明“参数是什么”，本机指标说明“应该设多少”。变更流程固定为：备份当前配置，
记录基线，只改一组参数，做语法检查和真实请求验证，覆盖一个业务高峰，再决定保留或回滚。

---

## 附：验证环境的完整结果

```
组件版本    nginx/1.30.4  PHP 8.3.33  MySQL 8.4.7 / MariaDB 11.8.8
            Redis 8.10.0  phpMyAdmin 5.2.3  WordPress 7.0.3
安装耗时    9 分钟（MySQL 走官方通用二进制）
nginx 模块  lua-nginx-module 0.10.31 / ngx_brotli / ngx_cache_purge 2.3
            http_v2 / http_v3 / OpenSSL 3.5.7
Lua 运行期  curl /lua → hello world
            resty.core / resty.lrucache / cjson 在真实 worker 中均可 require
PHP 扩展    mysqli pdo_mysql gd curl mbstring xml zip intl fileinfo
            opcache redis igbinary imagick  （WordPress 所需全部就位）
站点状态    首页 200 / 文章页 200 / 分类页 200 / wp-admin 301 补斜杠
Redis 缓存  49 个 wpdemo:* 键，igbinary 序列化正常
数据库      MySQL 与 MariaDB 均完成 WordPress 主链路；wpdemo 用户仅可见自身库
Apache 栈   LAMP / LNMPA 均完成源码安装与 PHP、PATH_INFO、目录边界、失败码实测
Pure-FTPd   TLS 2；明文登录拒绝，显式 FTPS 列目录与上传成功
防火墙      inet lnmp 表；22/80/443 放行，3306/6379 drop；未动系统主表
```
