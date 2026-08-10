# LNMP 2.3 从零搭建 WordPress 生产环境

> 本文的每一条命令都在 **Debian 12 (bookworm) / x86_64 / 6G 内存 / 4 核** 上真实执行过，
> 输出为实际回显（涉及真实地址的部分已脱敏）。
> 环境组合：nginx 1.30.4 + PHP 8.3.33 + MySQL 8.4.7（官方通用二进制）
> + Redis 8.10.0 + phpMyAdmin 5.2.3 + WordPress 7.0.3。
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

---

## 一、开始之前

### 1.1 硬性要求

| 项 | 要求 | 说明 |
|---|---|---|
| 系统 | Debian 12 / 13，Ubuntu 18.04+，EL 8+ | 主要验证目标是 Debian 系 |
| 架构 | x86_64 | 官方 MySQL 通用二进制只提供 x86_64；其他架构会回退到源码编译 |
| 内存 | **≥ 4G** | 编译 nginx（含 Lua/Brotli/OpenSSL）与 PHP 很吃内存。2G 会 OOM |
| 磁盘 | ≥ 10G 可用 | 源码包 + 编译产物；仅 MySQL 二进制包就有 912M |
| 机器状态 | **必须是干净机器** | 安装会卸载系统自带的 nginx/php/apache/mysql 并接管防火墙 |
| 网络 | 能访问 nginx.org / php.net / cdn.mysql.com / github.com | 全部走上游官方源 |

> 注意：**不要在已有业务的服务器上直接跑。** 脚本会移除系统包管理器装的
> Web/DB 组件，并写入 nftables 规则。

### 1.2 编译耗时参考

4 核 6G 的机器上，从零完整安装约 **9 分钟**（MySQL 走二进制不编译）。
如果选择源码编译 MySQL，再加 30-60 分钟。

### 1.3 获取代码

```bash
git clone https://github.com/<你的用户名>/<仓库名>.git lnmp2.3
cd lnmp2.3
chmod +x install.sh addons.sh uninstall.sh upgrade.sh
```

> 优先使用 tag 或 release，而不是 `main` 分支。`main` 的内容可能在两次安装之间
> 变化，两台机器装出来的东西就不一样了。

---

## 二、安装 LNMP

### 2.1 交互式安装

```bash
./install.sh lnmp
```

依次会问：数据库版本 → 是否用通用二进制 → 数据库 root 密码 →
是否启用 InnoDB → PHP 版本 → 内存分配器。

### 2.2 非交互安装（推荐用于自动化）

全部选项都可以用环境变量传入，一条命令跑完：

```bash
LNMP_Auto=y \
DBSelect=2 \
Bin=y \
PHPSelect=4 \
SelectMalloc=1 \
InstallInnodb=y \
Enable_PhpMyAdmin=y \
DB_Root_Password='换成你自己的强密码' \
./install.sh lnmp
```

参数含义：

| 变量 | 值 | 含义 |
|---|---|---|
| `LNMP_Auto` | `y` | 跳过"按任意键继续" |
| `DBSelect` | `1`~`5` | 1=MySQL8.0 **2=MySQL8.4(默认)** 3=MariaDB10.11 4=MariaDB11.4 5=MariaDB11.8 |
| `Bin` | `y`/`n` | `y`=下载官方通用二进制（快，几分钟）；`n`=源码编译（慢，30-60 分钟） |
| `PHPSelect` | `1`~`6` | 1=8.0 2=8.1 3=8.2 **4=8.3(默认)** 5=8.4 6=8.5 |
| `SelectMalloc` | `1`~`3` | 1=不装 2=Jemalloc 3=TCMalloc |
| `InstallInnodb` | `y` | WordPress 必须用 InnoDB |
| `Enable_PhpMyAdmin` | `y`/`n` | **默认 `n`**（安全考虑）。要 phpMyAdmin 必须显式开启 |
| `DB_Root_Password` | 字符串 | 留空则随机生成 |

> **`Enable_PhpMyAdmin` 只在整包安装时生效。** `addons.sh` 里没有单独安装
> phpMyAdmin 的入口，装完 LNMP 再想加只能重装或手工部署。**装之前想清楚。**
>
> 开启后，程序装在 `/usr/local/phpmyadmin`（不在网站根目录下），
> 访问路径随机生成，形如 `49763abb_phpmyadmin`。地址在安装结束时打印，
> 之后用 `lnmp status` 可以再查。详见 [7.x 安全加固](#仍需管理员完成以下配置)。

### 2.3 用 OpenResty 替代 nginx（可选）

OpenResty 是 nginx 的增强发行版，自带 LuaJIT 与整套 `lua-resty-*` 库。
**它与 nginx 官方版互斥**：两者都提供 nginx 二进制并监听 80/443，
不能同时装。

```bash
# 交互式：安装过程中会问「Web Server」选 2
./install.sh lnmp

# 非交互
WebSelect=2 ORMode=1 ... ./install.sh lnmp    # 官方仓库预编译包（不编译）
WebSelect=2 ORMode=2 ... ./install.sh lnmp    # 源码编译
```

两种装法的取舍：

| | `ORMode=1` 仓库包 | `ORMode=2` 源码编译 |
|---|---|---|
| 速度 | 快（不编译） | 慢（要编 LuaJIT 和一堆模块） |
| 完整性校验 | apt/yum 的 GPG 签名 | PGP 验签（随包公钥 + 指纹白名单） |
| 发行版要求 | **上游必须提供当前发行版的包** | 不挑发行版 |
| 版本 | 仓库里的当前版本 | `version.sh` 里的 `OpenResty_Ver` |
| 自定义模块 | 不能 | 能（`OpenResty_Modules_Options`） |

> 注意：**Debian 13 (trixie) 目前只能用源码编译。**
> 2026-08 实测，OpenResty 官方 Debian 仓库只有到 bookworm(12) 为止，
> `dists/trixie/` 返回 404。官方博客虽然把 Debian 13 列进了支持列表，
> 但仓库包尚未发布。选择 `ORMode=1` 时，脚本会先探测仓库，明确报告错误并
> 建议改用源码编译，避免在 `apt-get update` 阶段才失败。
> 等上游发布 trixie 包后，无需改代码即可自动可用（探测逻辑是动态的）。

安装后**运维方式与 nginx 一致**：安装时会建立软链接
`/usr/local/nginx → /usr/local/openresty/nginx`，所以：

```bash
lnmp nginx reload        # 照常可用
lnmp vhost add           # 照常可用
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
./upgrade.sh openresty
```

会**按当初的安装方式自动分流**（包装的走 apt 升级、源码装的走重新编译），
无需记录初始安装方式。升级后先执行 `nginx -t`，配置检查通过后才重载服务。

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
curl http://127.0.0.1/lua
# hello world
```

---

## 三、安装 Redis

WordPress 的对象缓存要用到。**PHP 的 redis 扩展在主安装时就装好了**
（`Enable_PHP_Default_Redis='y'`），这一步装的是 **Redis 服务端**。

```bash
./addons.sh install redis
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
> | 单站点、单租户 | 回环 + 低权限账号，可以接受 |
> | 多站点同机 | 每站一个 Redis 实例（不同端口/socket），或用 ACL 给每站独立账号 |
> | 有合规要求 | Unix socket + 文件权限，按站点区分 |
>
> 另外：**只要暴露到回环以外的任何网卡，必须先设 `requirepass`** ：
> 历史上未授权 Redis 被用来写 SSH 公钥的案例非常多。

---

## 四、创建站点

### 4.1 交互式创建

```bash
lnmp vhost add
```

**完整的交互顺序**（单 PHP 版本、未装 pure-ftpd 的情况，共 15 步）：

| # | 提示 | WordPress 场景填什么 |
|---|---|---|
| 1 | `Please enter domain` | `wp.example.com` |
| 2 | `Enter more domain name` | 回车跳过，或填 `example.com` |
| 3 | `Please enter the directory` | 回车用默认 `/home/wwwroot/<域名>` |
| 4 | `Allow Rewrite rule? (y/n)` | **`y`** |
| 5 | `Please enter the rewrite of programme` | **`wordpress`** |
| 6 | `Enable PHP Pathinfo? (y/n)` | `n`（WordPress 不需要） |
| 7 | `Allow access log? (y/n)` | `y` |
| 8 | `Enter access log filename` | 回车用默认 |
| 9 | `Enable IPv6? (y/n)` | 有 IPv6 就 `y` |
| 10 | `Create database and MySQL user` | **`y`** |
| 11 | `Enter current root password` | 数据库 root 密码（不回显） |
| 12 | `Enter database name` | `wpdemo`（库名与用户名相同） |
| 13 | `Please enter password for mysql user` | 库用户密码（不回显） |
| 14 | `Add SSL Certificate (y/n)` | 先 `n`，第七章单独做 |
| 15 | `Press any key to start` | 任意键 |

> **第 5 步的 `wordpress` 是关键。** 它会引用内置的
> `/usr/local/nginx/conf/rewrite/wordpress.conf`：
> ```nginx
> location / { try_files $uri $uri/ /index.php?$args; }
> rewrite /wp-admin$ $scheme://$host$uri/ permanent;
> ```
> 这正是 WordPress 官方推荐的 nginx 伪静态写法。

成功后会打印站点信息，并且能看到 `Add database Sucessfully.`。

### 4.2 非交互创建

```bash
printf 'wp.example.com\n\n\ny\nwordpress\nn\ny\n\nn\ny\n数据库root密码\nwpdemo\n库用户密码\nn\n\n' \
  | lnmp vhost add
```

> 注意：**输入项数量必须精确**。少喂一项会在读取时报
> "遇到 EOF：标准输入已经没有内容了" 并退出（这是有意的快速失败，
> 早期版本在这里会无限刷屏）。
>
> 注意：**装了多个 PHP 版本时会多一步**（第 9 步后会问选哪个 PHP），
> 序列要相应调整。单版本时不会问。

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

---

## 五、部署 WordPress

### 5.1 下载并校验

```bash
cd /tmp
# 固定版本，不使用浮动的 latest，确保不同主机和时间使用相同内容
WP_VER=7.0.3
curl -fsSL -o wordpress.tar.gz     "https://wordpress.org/wordpress-${WP_VER}.tar.gz"
curl -fsSL -o wordpress.tar.gz.sha1 "https://wordpress.org/wordpress-${WP_VER}.tar.gz.sha1"

# 校验不通过必须**立即中止**，不能只打印一句提示
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
  而 PHP 的 `mysqli.default_socket` 未必指向 `/tmp/mysql.sock`。
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

装完立即改密码，让上面那次输入作废：

```bash
# 后台「用户 → 个人资料」改，或用 wp-cli：
# wp user update 管理员用户名 --user_pass='新密码' --path=/home/wwwroot/wp.example.com
history -c   # 清掉本次 shell 历史
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

# 注意：wordpress.org 的插件目录**不提供**逐文件的哈希或签名。
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

### 6.2 PHP 参数

安装后的默认值（`/usr/local/php/etc/php.ini`）：

| 参数 | 默认值 | WordPress 建议 |
|---|---|---|
| `memory_limit` | 128M | **256M**（装插件多、用 Elementor 之类页面构建器时 128M 会不够） |
| `upload_max_filesize` | 50M | 够用；要传大视频再调 |
| `post_max_size` | 50M | 应 ≥ `upload_max_filesize` |
| `max_input_vars` | 1000 | **3000**（菜单项多或插件设置页字段多时会静默丢数据） |
| `max_file_uploads` | 20 | 够用 |
| `date.timezone` | PRC | 按需改 |

修改：

```bash
sed -i 's/^memory_limit = .*/memory_limit = 256M/'   /usr/local/php/etc/php.ini
sed -i 's/^max_input_vars = .*/max_input_vars = 3000/' /usr/local/php/etc/php.ini
lnmp php-fpm reload
```

> nginx 侧的 `client_max_body_size` 默认已是 `50m`（与 PHP 一致）。
> 调整 PHP 上传上限时，必须同步调整 nginx；否则大文件会在 nginx 层返回 413，
> 请求不会到达 PHP。

`disable_functions` 默认禁用了 `exec`/`system`/`shell_exec` 等一批函数。
WordPress 本身不需要它们，**建议保持禁用**。少数插件（如某些备份、
图片处理插件）会调用 `exec`，如果确实需要：

```bash
/root/lnmp2.3/tools/remove_disable_function.sh
```

### 6.3 PHP-FPM 进程数

默认配置：

```
listen = /tmp/php-cgi.sock
pm = dynamic
pm.max_children = 60
```

`pm.max_children` 的估算方法：**可用内存 ÷ 单进程峰值内存**。

先测本机实际占用：

```bash
ps --no-headers -o rss -C php-fpm | awk '{s+=$1; n++} END {printf "平均 %.1f MB，进程数 %d\n", s/n/1024, n}'
```

本次验证环境实测：**平均 23.9 MB，进程数 32**（刚装好的 WordPress，无插件）。

但**不要照这个数字去算 max_children**：空载值没有参考意义。
装上插件、跑起真实流量后，单进程 60-120M 很常见（页面构建器、
电商插件更高）。稳妥做法是按 **100M/进程** 估：

```
pm.max_children ≈ (总内存 - 系统 - MySQL - Redis 占用) ÷ 100M
```

6G 的机器给 MySQL 留 1.5G、系统留 0.5G，剩 4G → `4096/100 ≈ 40`。
默认值 60 对 6G 机器偏激进，**上线前按真实峰值复测一次**。

**内存小的机器一定要调小**，否则并发一高就 OOM，
表现是站点间歇性 502 而日志里什么也看不出来。

改完 `lnmp php-fpm reload`。

### 6.4 定时任务

WordPress 默认通过访问触发 `wp-cron.php`。低流量站点的定时任务可能延迟，
流量高时每次请求都检查一遍，浪费性能。生产环境建议改成系统 cron：

```php
// wp-config.php 里加
define( 'DISABLE_WP_CRON', true );
```

```bash
# 每 5 分钟触发一次
( crontab -l 2>/dev/null; echo "*/5 * * * * curl -s http://wp.example.com/wp-cron.php?doing_wp_cron >/dev/null 2>&1" ) | crontab -
```

---

## 七、配置 HTTPS

### 7.1 有域名（推荐）

前提：域名已解析到本机，且 **80 端口从公网可达**（HTTP-01 验证要用）。

```bash
lnmp ssl add
```

交互顺序（共 9 步）：域名 → 附加域名 → 目录 → 允许 rewrite → 访问日志 →
pathinfo → IPv6 → **证书来源(1-4)** → 是否 301 跳转。

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

在域名处输入 **`default`**，本包会自动转为 **IP 地址证书**流程，
并打印完整说明。该方式存在以下硬性限制，**申请前必须确认**：

| 限制 | 说明 |
|---|---|
| **有效期只有 7 天** | Let's Encrypt 的 shortlived profile；只有该 profile 支持 IP 地址 |
| **必须依赖自动续期** | 本包按 `--days 6` 申请（比有效期提前 1 天续）。**不得能关掉 acme.sh 的 cron**，否则一周内证书过期、站点不可访问 |
| **只支持 IPv4** | IPv6 地址申请不了 |
| **只能用 Let's Encrypt** | BuyPass 与 ZeroSSL 都不提供 IP 证书。选了会自动改用 LE |
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

### 8.2 站点管理

```bash
lnmp vhost add       # 新增站点
lnmp vhost list      # 列出所有站点
lnmp vhost del       # 删除站点（只删 nginx 配置，保留网站文件）
```

> `vhost del` 会保留网站文件并给出提示，以避免误删数据。
> 需要彻底删除时手工 `rm -rf`，`.user.ini` 的 immutable 属性
> 已由删除流程自动解除。

### 8.3 数据库管理

```bash
lnmp database add    # 新建库 + 同名用户
lnmp database list   # 列出所有库
lnmp database edit   # 改库用户密码
lnmp database del    # 删除库
```

### 8.4 备份

```bash
/root/lnmp2.3/tools/backup.sh
```

WordPress 站点至少要备份两样：**数据库** 和 **`wp-content/` 目录**
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

### 8.5 日志

| 日志 | 路径 |
|---|---|
| nginx 错误日志 | `/home/wwwlogs/nginx_error.log` |
| 站点访问日志 | `/home/wwwlogs/<域名>.log` |
| PHP-FPM 日志 | `/usr/local/php/var/log/php-fpm.log` |
| MySQL 错误日志 | `/usr/local/mysql/var/<主机名>.err` |
| Redis 日志 | `/usr/local/redis/var/redis.log` |
| 安装日志 | `/root/lnmp-install.log` |

日志切割：

```bash
/root/lnmp2.3/tools/cut_nginx_logs.sh
```

---

## 九、故障排查

### 9.1 站点 502 Bad Gateway

按顺序查：

```bash
# 1. php-fpm 是否在跑
lnmp status

# 2. socket 是否存在、权限是否对
ls -la /tmp/php-cgi.sock          # 应为 www:www 0660

# 3. 看 php-fpm 日志
tail -50 /usr/local/php/var/log/php-fpm.log

# 4. 是不是进程数打满了（高并发时最常见）
grep "server reached pm.max_children" /usr/local/php/var/log/php-fpm.log
```

最后一条如果有输出，调大 `pm.max_children`（见 6.3），
但**先确认内存够**，否则只会从 502 变成 OOM。

本包自带一个快速自检脚本：

```bash
/root/lnmp2.3/tools/check502.sh
```

### 9.2 WordPress 后台白屏

生产环境排错有两条铁律：**错误不得能显示给访客**，**日志不得能放在 Web 根目录下**。

```bash
SITE=/home/wwwroot/wp.example.com

# 日志目录放在站点根目录之外，Web 完全够不着
mkdir -p /var/log/wordpress && chown www:www /var/log/wordpress && chmod 750 /var/log/wordpress

# 三个常量必须一起设：
#   WP_DEBUG_DISPLAY = false  ← 关键，不设的话报错会直接打印给访客，
#                                里面有绝对路径、SQL、插件上下文，甚至请求里的密钥
#   WP_DEBUG_LOG 指向站外路径
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
redis-cli ping                              # 服务是否在
php -m | grep redis                         # 扩展是否加载
ls -la /home/wwwroot/<域名>/wp-content/object-cache.php   # drop-in 是否部署
redis-cli --scan --pattern "<前缀>:*" | wc -l              # 是否真的在写
```

### 9.6 数据库连接失败

```bash
# 用 wp-config.php 里的凭据手工连一次，直接看真实报错
mysql -u wpdemo -p -h 127.0.0.1 wpdemo
```

- `Access denied` → 密码错误，或账号仅授权 `localhost` 而客户端连接 `127.0.0.1`
- `Can't connect` → MySQL 没起来，`lnmp mysql start`

### 9.7 忘记数据库 root 密码

```bash
/root/lnmp2.3/tools/reset_mysql_root_password.sh
```

该脚本重置期间会关闭网络监听、只用私有 socket，数据库不对外可见。

---

## 十、安全基线

本包安装后已经做好的：

| 项 | 状态 | 注意 |
|---|---|---|
| 防火墙 | nftables `inet lnmp` 表，放行 22/80/443 + ICMP，**3306 / 6379 / 11211 显式 drop** | **链策略是 `policy accept`**，不是默认拒绝：它仅阻断明确列出的端口，不表示只允许这些端口 |
| MySQL | 无匿名用户；root 只能从 localhost 登录；无 test 库；**`bind-address = 127.0.0.1`** | |
| Redis | 只监听回环；以专用低权限账号运行 | 回环是必要条件不是充分条件，多站点隔离见 3.x |
| Memcached | 只监听回环；以专用低权限账号运行 | 协议无认证，同上 |
| PHP | `disable_functions` 禁用 exec 系列；每站点 `open_basedir` 隔离 | `open_basedir` 限制文件路径访问，**不提供**操作系统级租户隔离：多站点共用 `www` 账号时没有内核层面的边界 |
| phpinfo / phpMyAdmin / 演示页 | **默认全部不部署** | 需在 `lnmp.conf` 显式开启 |
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
   主配置用通配 `include` 引入。**开关两个方向都由脚本负责**：
   `lnmp.conf` 里 `Enable_PhpMyAdmin='n'` 时片段会被删除，
   通配符没匹配到文件不报错，因此不必回头去改主配置。

   随机路径保留 `_phpmyadmin` 结尾，是为了在 default 站点配了严格访问控制时，
   一眼能认出这条路径的用途，写放行或封禁规则时不至于误伤。

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
3. **WordPress 后台加固**：限制 `wp-login.php` 的访问频率，或改用插件加两步验证
4. **及时更新**：WordPress 核心、插件和主题漏洞是主要入侵途径，
   远多于服务器组件本身
5. **定期执行备份恢复测试**，确认备份文件有效

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

## 附：本次验证环境的完整结果

```
组件版本    nginx/1.30.4  PHP 8.3.33  MySQL 8.4.7  Redis 8.10.0
            phpMyAdmin 5.2.3  WordPress 7.0.3
安装耗时    9 分钟（MySQL 走官方通用二进制）
nginx 模块  lua-nginx-module 0.10.31 / ngx_brotli / ngx_cache_purge 2.3
            http_v2 / http_v3 / OpenSSL 3.5.7
Lua 运行期  curl /lua → hello world
            resty.core / resty.lrucache / cjson 在真实 worker 中均可 require
PHP 扩展    mysqli pdo_mysql gd curl mbstring xml zip intl fileinfo
            opcache redis igbinary imagick  （WordPress 所需全部就位）
站点状态    首页 200 / 文章页 200 / 分类页 200 / wp-admin 301 补斜杠
Redis 缓存  49 个 wpdemo:* 键，igbinary 序列化正常
数据库      wpdemo 用户仅可见自身库，权限隔离正确
防火墙      inet lnmp 表；22/80/443 放行，3306/6379 drop；未动系统主表
```
