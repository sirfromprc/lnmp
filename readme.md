# LNMP 2.3

用 Shell 编写的一键安装包，在 Linux 服务器上编译安装 **LNMP**（Nginx/MySQL/PHP）、
**LNMPA**（Nginx/MySQL/PHP/Apache）或 **LAMP**（Apache/MySQL/PHP）生产环境，
并附带虚拟主机管理、数据库管理、FTP 管理、SSL 证书签发、升级、备份等运维工具。

原始项目作者：licess。本包是 LNMP 2.3 的安全加固与精简分支，
每一处改动都逐条记录在随包的 `changelog.md`。

---

## 目录

- [一、这个分支改了什么](#一这个分支改了什么)
- [二、安装](#二安装)
- [三、常用功能说明](#三常用功能说明)
- [四、组件手工升级](#四组件手工升级)
- [五、常见问题](#五常见问题)
- [六、相关文档](#六相关文档)

---

## 一、这个分支改了什么

### 版本与组件

- 数据库收敛为 **MySQL 8.0 / 8.4 LTS** 与 **MariaDB 10.11 / 11.4 / 11.8 LTS**，
  默认 MySQL 8.4；PHP 收敛为 **8.0 ~ 8.5**，默认 8.3。
  5.x / 7.x 系列的 PHP、MySQL 5.1~5.7、MariaDB 10.0~10.6 以及 Apache 2.2 已移除，
  它们都已停止安全维护。
- 组件升级到当前稳定版：Nginx 1.30、OpenSSL 3.5 LTS、Apache 2.4.68、phpMyAdmin 5.2.3。
- Web 服务器可以选 **Nginx** 或 **OpenResty 1.31**（二选一，见 3.2.1）。
- Nginx 默认编译进 **brotli、cache_purge、fancyindex、Lua（LuaJIT + lua-nginx-module
  + resty core/lrucache/cjson）**，并启用 HTTP/2、HTTP/3 与 stream 模块；
  PHP 默认带上常用扩展。
- 防火墙由 iptables 改为 **nftables**，规则只落在独立的 `inet lnmp` 表里，
  不动系统已有的防火墙配置；检测到 firewalld 在运行时改用 `firewall-cmd` 与之共存。

### 下载与完整性

- 所有组件一律从**该组件开发方的官方站点**下载（nginx.org、php.net、cdn.mysql.com、
  downloads.mariadb.org、archive.apache.org、files.phpmyadmin.net、pecl.php.net、
  以及上游自己维护的 GitHub 项目），全程 HTTPS。
- 下载完成后**强制校验 SHA256**（`src/checksums.sha256`），不匹配时删除文件并中止安装，
  不存在"校验失败但继续装"的路径。
- 版本在运行时才确定的组件（如 MySQL 源码编译所需的 Boost）改为从上游发布的
  机器可读校验值取 SHA256；Nginx 走 **PGP 签名验证**，公钥随包分发并固定指纹白名单。
- acme.sh 固定版本 + 校验 SHA256 后才解压执行，并关闭其自动升级。
- RHEL/CentOS 系的软件源改为官方 HTTPS + `gpgcheck=1`，GPG 公钥随包提供。
- 安装前会**只读检查**宿主机已有的 APT/YUM 源有没有关掉签名或 TLS 校验，
  发现异常时仅提示，不阻断安装或修改现有配置。

### 安全基线

- **SELinux 默认保持启用状态**，仅在显式配置后关闭。
- `/home/wwwlogs` 权限从 777 收紧为 755；PHP-FPM socket 从 0666 收紧为 0660。
- 数据库 root 随机密码改用 `/dev/urandom` 生成，**不再打印到屏幕和安装日志**，
  写入 `/root/.lnmp_db_root_password`（0600）。
- 默认**不部署** phpinfo、phpMyAdmin、探针等页面，需要时在 `lnmp.conf` 里开启。
- phpMyAdmin 开启后装在 `/usr/local/phpmyadmin`（网站根目录之外），
  访问路径随机生成（形如 `49763abb_phpmyadmin`），可用 `lnmp status` 查看；
  关闭时脚本会自动撤掉 Web 服务器上的映射。
- 管理脚本 `/bin/lnmp` 的域名、目录、数据库名等输入加了严格校验；
  临时文件改用 `mktemp`；SQL 参数做转义。
- 重置数据库 root 密码的工具改用官方推荐的 `--init-file` 流程，
  不再存在"临时开一个免鉴权数据库"的窗口。

### 可靠性

- 编译、解压、安装的每一步失败都**就地停止**，不再带着半成品继续往下走。
- 安装/升级失败**返回非零退出码**（原先无论成败都返回 0）。
- Nginx / PHP / 多版本 PHP / phpMyAdmin 的升级改为**先构建验证、再切换、失败自动回滚**。
  数据库升级暂未提供自动回滚，失败时会打印人工恢复步骤；升级前必须完成备份。
- 不再强杀包管理进程、不再删除 yum/dpkg 锁文件，改为等待锁释放。

> **验证情况**：
>
> - **已在 Debian 12 实测**：`install.sh lnmp` 完整安装（Nginx + MySQL 8.4 + PHP 8.3）、
>   WordPress 主线、`install.sh db`、`pureftpd.sh`、`addons.sh` 的 Redis/Memcached、
>   OpenResty 官方包安装、自定义端口、数据库升级、phpMyAdmin 升级、备份与恢复。
> - **未实测**：LNMPA / LAMP（Apache 系）、CentOS/RHEL 系、非 x86_64 架构。
>
> 无论哪种情况，部署到生产环境前都请先在测试机走一遍。

### 已知不支持或不完善

| 项目 | 状态 |
|---|---|
| LNMPA / LAMP（Apache 系） | 代码保留，但**未做真机验证**，请自行充分测试 |
| CentOS / RHEL 系 | 代码保留，无额外验证轮次 |
| 非 x86_64 架构 | 数据库官方通用二进制只有 x86_64，其余架构会回退到源码编译 |
| Nginx 的 80 / 443 端口 | **不可配置**，散落在主配置、每个站点配置和证书签发流程里 |
| SSH 端口 | 只用于生成放行规则，**不会改 `sshd_config`** |
| 数据库升级 | 无自动回滚 |
| IP 证书 | 仅 IPv4 公网地址，有效期 7 天，依赖自动续期 |
| ionCube Loader | 未接入安装流程，需要请自行从官方获取 |
| 容器 / WSL | 有无 systemd 环境的降级路径，但未做验证 |
| 数据库主从、读写分离 | 不支持 |
| 站点级别的资源隔离（每站独立 PHP-FPM 池） | 不提供，需要自行配置 |

---

## 二、安装

### 获取

从本项目的 GitHub 仓库获取代码。两种方式都行：

```bash
# 方式一：clone（方便后续 git pull 更新）
yum install -y git || apt-get install -y git
git clone https://github.com/sirfromprc/lnmp.git lnmp
cd lnmp

# 方式二：下载 release 压缩包
wget https://github.com/sirfromprc/lnmp/archive/refs/tags/v2.3.tar.gz
tar zxf v2.3.tar.gz
cd lnmp-2.3
```

> 建议使用固定的 **tag / release**。`main` 分支可能持续变化，无法保证不同时间安装的内容一致。
>
> 想确认拿到的代码没被动过，`git clone` 后执行 `git log -1` 核对提交哈希，
> 或用 release 页面公布的校验值核对压缩包。

### 安装

在包目录内执行：

```bash
./install.sh {lnmp|lnmpa|lamp}
```

- `lnmp`：Nginx + MySQL/MariaDB + PHP
- `lnmpa`：Nginx 做前端、Apache 跑 PHP
- `lamp`：Apache + MySQL/MariaDB + PHP

安装过程会交互询问 Web 服务器（Nginx 还是 OpenResty）、数据库版本、数据库 root 密码、
PHP 版本、内存分配方式等。全程需要 **root 权限**，编译耗时从十几分钟到一小时以上不等
（取决于机器性能，以及数据库选二进制还是源码）。

全部选项都能用环境变量提前给定，跳过交互：

```bash
# 装 LNMP：OpenResty 官方包 + MySQL 8.4 通用二进制 + PHP 8.3
WebSelect=2 ORMode=1 DBSelect=2 Bin=y PHPSelect=4 InstallInnodb=y \
DB_Root_Password='改成你的密码' ./install.sh lnmp
```

| 变量 | 取值 |
|---|---|
| `WebSelect` | `1` = Nginx（默认），`2` = OpenResty |
| `ORMode` | 选 OpenResty 时：`1` = 官方软件包（不编译，快），`2` = 源码编译 |
| `DBSelect` | `1`=MySQL 8.0 `2`=MySQL 8.4（默认） `3`=MariaDB 10.11 `4`=MariaDB 11.4 `5`=MariaDB 11.8 `0`=不装 |
| `Bin` | 数据库 `y` = 官方通用二进制（推荐），`n` = 源码编译 |
| `PHPSelect` | `1`~`6` 对应 PHP 8.0 / 8.1 / 8.2 / 8.3（默认） / 8.4 / 8.5 |
| `InstallInnodb` | `y` / `n` |
| `DB_Root_Password` | 留空则随机生成并写入 `/root/.lnmp_db_root_password` |

> **注意：必须在无现有业务的干净系统上安装。** 安装脚本会卸载系统自带的 nginx / php /
> apache / mysql 相关包，并接管防火墙配置。

其他入口：

```bash
./install.sh nginx      # 只装 Nginx
./install.sh db         # 只装 MySQL 或 MariaDB
./install.sh mphp       # 额外安装一个 PHP 版本（仅 LNMP 模式）
./uninstall.sh          # 卸载
./upgrade.sh            # 升级
./addons.sh             # 安装/卸载扩展插件
```

建议先 `screen -S lnmp`，SSH 断线后用 `screen -r lnmp` 接回，避免编译中断。
安装前确认已装 `wget`。

**安装前可先编辑 `lnmp.conf`**：网站目录、数据库目录、Nginx 模块、PHP 编译参数、
各种开关都在里面，每一项都写了用途。文件里所有变量都可以用环境变量覆盖，例如：

```bash
Default_Website_Dir=/data/wwwroot Enable_PhpMyAdmin=y ./install.sh lnmp
```

### 支持范围

代码层面支持 CentOS/RHEL/Debian/Ubuntu 及其常见衍生版，但验证投入并不平均：

- **Debian / Ubuntu 系是主要目标**，开发与验证都以 Debian 12 为准。
- **CentOS / RHEL 系不是本分支的主要关注对象**，代码支持保留但没有额外验证轮次，
  使用前请自行充分测试。
- 数据库的官方通用二进制包**只有 x86_64**。其他架构（如 aarch64）会自动回退到
  源码编译，耗时和内存占用都显著更高。

#### 数据库：通用二进制还是源码编译

安装数据库时会问一次 `Using Generic Binaries [y/n]`，**没有特殊需求就选 `y`**：
通用二进制由上游构建，SHA256 同样强制核对，几分钟装完，功能与源码编译一致。

选 `n`（源码编译）前先看硬件条件。以 MySQL 8.4 在 Debian 12 实测为例：

| 项目 | 实测值 |
| --- | --- |
| 编译目录峰值 | 约 7.8GB |
| 安装目录 | 约 1.5GB |
| 单个编译进程内存峰值 | 约 800MB |
| 8 核并行编译 | 6GB 内存的机器会被 OOM 杀掉 |

安装脚本会在开始下载和改动系统之前检查：内存低于 2GB 或项目所在分区可用空间
低于 15GB 直接拒绝并提示改用 `Bin=y`；内存低于 4GB 会说明代价并要求确认。
并行任务数按「每个任务 1GB 内存」和 CPU 核数取小值，不再只看核数。

非交互安装可以直接指定，例如：

```bash
DBSelect=2 Bin=y CheckMirror=n InstallInnodb=y ./install.sh db
```

---

## 三、常用功能说明

### 3.1 服务管理（运维最常用）

```bash
lnmp start | stop | restart | reload | kill | status
```

单独控制某个服务：

```bash
lnmp nginx    {start|stop|restart|reload|status}
lnmp mysql    {start|stop|restart|reload|status}
lnmp mariadb  {start|stop|restart|reload|status}
lnmp php-fpm  {start|stop|restart|reload|status}
lnmp pureftpd {start|stop|restart|reload|status}
```

其余管理子命令：

```bash
lnmp vhost    {add|list|del}                      # 虚拟主机，见 3.2
lnmp database {add|list|edit|del|export|import}   # 数据库，见 3.3
lnmp backup   {init|run|status|list|restore|test} # 备份，见 3.3
lnmp ftp      {add|list|edit|del|show}            # FTP 账号，见 3.8
lnmp ssl add                                      # 签发证书，见 3.7
lnmp dnsssl   {cx|ali|cf|dp|he|gd|aws}            # DNS 验证签发（支持泛域名）
lnmp onlyssl  {cx|ali|cf|dp|he|gd|aws}            # 只签证书，不改 Nginx 配置
lnmp tgnotice {--init|--test|--status}            # Telegram 通知，见 3.3.1
```

> `reload` 是平滑重载配置，不中断连接；`restart` 会真正重启进程。
> 改完 Nginx 配置优先用 `reload`。`kill` 是强制杀进程，只在卡死时用。

**优先用 `lnmp`，不要直接调 `/etc/init.d/`**。有 systemd 的机器上，`lnmp` 会走
`systemctl`；绕过它直接跑 init 脚本，进程确实起来了，`systemctl is-active` 却报
inactive，后续运维命令判断不了服务状态。init 脚本仍然保留，供没有 systemd 的
环境（容器、WSL）使用。

### 3.1.1 自定义服务端口

端口统一在 `lnmp.conf` 里配置，安装时会**同时**写进服务自己的配置文件和nftables 规则：

```bash
SSH_Port=22                  # 仅用于放行；本包不改 sshd_config
DB_Port=3306                 # 写进 /etc/my.cnf，并按此端口阻断
DB_X_Port=33060              # MySQL X Protocol，同样写进配置并阻断
Redis_Port=6379              # 写进 redis.conf、init 脚本与自测页
Memcached_Port=11211         # 写进 init 脚本
Pureftpd_Port=21             # 写进 pure-ftpd.conf 的 Bind
Pureftpd_Data_Port=20
Pureftpd_Passive_Min=20000   # 写进 PassivePortRange
Pureftpd_Passive_Max=30000
```

安装时用环境变量覆盖也可以：

```bash
Pureftpd_Port=2121 Redis_Port=6380 ./install.sh lnmp
```

覆写之后脚本会回读确认写进去了；模板结构变化导致没写成会直接报错停下，
不会出现"服务监听老端口、防火墙放行新端口"这种两边对不上又没有报错的情况。

> **改 `SSH_Port` 要格外小心**：本包只用它生成放行规则，不会去改
> `sshd_config`。如果你已经把 SSH 换到别的端口，这里必须跟着改，
> 否则装完防火墙只放行 22，你会被关在门外。
>
> nginx 的 80/443 不在其中 —— 那两个端口散落在 nginx.conf、每个站点配置和
> SSL 签发流程里，不是一个变量能覆盖的。

### 3.2 Nginx

**配置文件**

| 路径 | 用途 |
|---|---|
| `/usr/local/nginx/conf/nginx.conf` | 主配置 |
| `/usr/local/nginx/conf/vhost/` | 各站点配置，一个域名一个 `.conf` |
| `/usr/local/nginx/conf/rewrite/` | 伪静态规则 |
| `/usr/local/nginx/conf/enable-php.conf` | PHP 处理（默认版本） |
| `/usr/local/nginx/conf/enable-php8.4.conf` | 多版本 PHP 时按版本选用 |
| `/home/wwwlogs/` | 访问与错误日志 |

**日常命令**

```bash
/usr/local/nginx/sbin/nginx -t                      # 修改配置后必须先检查语法
/usr/local/nginx/sbin/nginx -s reload               # 平滑重载
/usr/local/nginx/sbin/nginx -V                      # 查看版本与编译参数
lnmp nginx restart                                  # 重启
tail -f /home/wwwlogs/nginx_error.log               # 看错误日志
```

**虚拟主机管理**

```bash
lnmp vhost add     # 添加站点（可选建目录、伪静态、日志、SSL）
lnmp vhost list    # 列出所有站点
lnmp vhost del     # 删除站点（只删配置，不删网站文件）
```

`lnmp vhost add` 会依次问：主域名 → 附加域名 → 网站目录 → 是否加防跨目录（`.user.ini`）
→ 是否写访问日志 → 伪静态规则 → 是否申请 SSL 证书。新站点配置写入
`/usr/local/nginx/conf/vhost/<域名>.conf`。**配置语法检查不通过会自动删除并报错退出**，
不会留下一个起不来的 Nginx。

**修改默认站点域名**：编辑 `/usr/local/nginx/conf/nginx.conf` 找到 `server_name`，
改为实际域名（多个域名用空格分隔），然后执行 `/usr/local/nginx/sbin/nginx -s reload`。

**日志切割**：`tools/cut_nginx_logs.sh`，可加进 crontab 每天执行。

### 3.2.1 OpenResty（Nginx 的可选替代）

OpenResty 是带 LuaJIT 和一整套 Lua 库的 Nginx 发行版。安装时二选一：

```bash
WebSelect=2 ORMode=1 ./install.sh lnmp    # 官方软件包，不编译，一分钟左右装完
WebSelect=2 ORMode=2 ./install.sh lnmp    # 源码编译，可加自定义模块
```

装完之后 **3.2 里的路径和命令完全照用**，`lnmp` 的 vhost 管理、日志切割也一样，
不需要记两套。

选源码编译（`ORMode=2`）时，可以在 `lnmp.conf` 里加自定义编译模块、额外的
configure 参数、自己的 Lua 库目录，以及 opm / luarocks 包。模块必须给出下载地址
和 SHA256。升级时这些配置会自动沿用，不会升出一个不含模块的版本。
配置项的格式和示例见 `lnmp.conf` 里对应的注释。

选官方软件包（`ORMode=1`）时加不了编译期模块，配了会直接报错而不是静默忽略。

> 两种装法的取舍、发行版限制、自定义模块的完整配置方式见
> `HowtoGuides.md` 的 2.3 与 2.3.1。

### 3.3 MySQL / MariaDB

**目录与配置**

两者的配置文件都是 `/etc/my.cnf`（由安装流程生成），程序目录和数据目录按所选数据库不同：

| 内容 | MySQL | MariaDB |
|---|---|---|
| 程序目录 | `/usr/local/mysql/` | `/usr/local/mariadb/` |
| 数据目录（默认） | `/usr/local/mysql/var/` | `/usr/local/mariadb/var/` |
| 配置文件 | `/etc/my.cnf` | `/etc/my.cnf` |
| 错误日志 | `/usr/local/mysql/var/<主机名>.err` | `/usr/local/mariadb/var/<主机名>.err` |
| 服务名 | `lnmp mysql ...` | `lnmp mariadb ...` |

数据目录可在 `lnmp.conf` 里用 `MySQL_Data_Dir` / `MariaDB_Data_Dir` 改；
装完之后再改要按 5.x「如何更改网站目录和数据库数据目录」的步骤搬。
下文命令一律以 MySQL 为例，MariaDB 把路径里的 `mysql` 换成 `mariadb` 即可。

**日常命令**

```bash
lnmp mysql restart                                  # 重启
/usr/local/mysql/bin/mysql -uroot -p                # 登录
cat /root/.lnmp_db_root_password                    # 查随机生成的 root 密码
/usr/local/mysql/bin/mysqladmin -uroot -p status    # 状态
/usr/local/mysql/bin/mysqldump -uroot -p --all-databases > all.sql   # 全库备份
```

**数据库管理**

```bash
lnmp database add    # 新建数据库和对应用户
lnmp database list   # 列出数据库
lnmp database edit   # 修改数据库用户密码
lnmp database del    # 删除数据库

lnmp database export <库名> <文件.sql.gz>   # 导出单个库，gzip 压缩
lnmp database import <库名> <文件.sql.gz>   # 导入到已存在的库
```

导出不会覆盖已存在的文件；导入前目标库必须已经存在（先 `database add`），
导入会覆盖库中的同名表，执行前有 10 秒倒计时可以 Ctrl+C 取消。
所有 `database` 子命令成功返回 0、失败返回非 0，可以直接用在脚本里。

**重置 root 密码**

```bash
./tools/reset_mysql_root_password.sh
```

会停掉数据库，用私有 socket + 禁用网络的方式临时启动、改密码、再正常启动。
全程不开放网络端口，密码输入不回显。

### 3.4 PHP

**目录与配置**

| 路径 | 用途 |
|---|---|
| `/usr/local/php/` | 程序目录 |
| `/usr/local/php/etc/php.ini` | PHP 主配置 |
| `/usr/local/php/etc/php-fpm.conf` | FPM 进程配置 |
| `/usr/local/php/conf.d/` | 扩展的 ini 片段 |
| `/usr/local/php/var/log/` | FPM 日志、慢日志 |
| `/usr/local/php8.4/` | 多版本 PHP（`./install.sh mphp` 装的） |

**日常命令**

```bash
lnmp php-fpm restart                    # 重启（改 php.ini / php-fpm.conf 后必须）
/usr/local/php/bin/php -v               # 版本
/usr/local/php/bin/php -m               # 已加载的扩展
/usr/local/php/bin/php -i | grep xxx    # 查配置项
/usr/local/php/bin/php --ini            # 查配置文件加载路径
/usr/local/php/sbin/php-fpm -t          # FPM 配置语法检查
```

**安装扩展**

```bash
./addons.sh                                          # 交互菜单
./addons.sh install {redis|memcached|opcache|apcu|imagemagick|exif|fileinfo|ldap|bz2|sodium|imap|swoole}
./addons.sh uninstall <同上>
```

装完会自动写 `/usr/local/php/conf.d/` 下的 ini 并重启 FPM。
存在多个 PHP 版本时，脚本会要求选择目标版本。

**多版本 PHP**

```bash
./install.sh mphp        # 安装额外版本（仅 LNMP 模式）
```

装好后在站点配置里把 `include enable-php.conf;` 换成
`include enable-php8.4.conf;`（版本号按实际），然后 `lnmp nginx reload`。
`lnmp vhost add` 同样会要求选择 PHP 版本。

**进程数调优**：编辑 `/usr/local/php/etc/php-fpm.conf` 的
`pm.max_children` / `pm.start_servers` / `pm.min_spare_servers` / `pm.max_spare_servers`，
改完 `lnmp php-fpm restart`。默认值偏保守（`max_children = 10`），
内存充裕的机器可以按 **每进程约 30~50MB** 估算后上调。

### 3.5 Redis

```bash
./addons.sh install redis        # 安装 Redis 服务端 + phpredis 扩展
```

| 路径 | 用途 |
|---|---|
| `/usr/local/redis/` | 程序目录 |
| `/usr/local/redis/etc/redis.conf` | 配置文件 |
| `/etc/init.d/redis` | 启停脚本 |

```bash
/etc/init.d/redis {start|stop|restart}
/usr/local/redis/bin/redis-cli ping          # 应返回 PONG
/usr/local/redis/bin/redis-cli info          # 运行状态
/usr/local/redis/bin/redis-cli monitor       # 实时命令流（排查用，别长开）
/usr/local/php/bin/php -m | grep redis       # 确认 PHP 扩展已加载
```

**默认只监听 127.0.0.1，且防火墙阻止外部访问**（端口跟随 `lnmp.conf` 的 `Redis_Port`）。
Redis 默认无密码，暴露到公网等同于把服务器交出去。
确需远程访问，请先在 `redis.conf` 里设 `requirepass`，再考虑放行端口。

### 3.6 Memcached

```bash
./addons.sh install memcached                # 可选 php-memcache 或 php-memcached 扩展
/etc/init.d/memcached {start|stop|restart}
echo stats | nc 127.0.0.1 11211              # 确认在跑
/usr/local/php/bin/php -m | grep -i memcache
```

同样默认只本机可用，端口（`Memcached_Port`）在防火墙里挡掉 TCP 和 UDP。

### 3.7 SSL 证书

```bash
lnmp ssl add                                  # 为已有站点签发证书（HTTP 验证）
lnmp dnsssl {cx|ali|cf|dp|he|gd|aws}          # DNS 验证，支持泛域名
lnmp onlyssl {cx|ali|cf|dp|he|gd|aws}         # 只签证书，不改 Nginx 配置
```

底层用 acme.sh，证书放在 `/usr/local/nginx/conf/ssl/`，会自动加续期任务。
密钥类型使用 acme.sh 默认的 **EC-256**。

**没有域名时的 IP 证书**：对默认站点执行 `lnmp ssl add` 会自动转入 IP 证书流程，
为服务器公网 IPv4 签发证书。这条路有硬性限制，脚本会先把它们列出来再问你是否继续：

- 只有 Let's Encrypt 提供 IP 证书，且必须用 shortlived profile；
- **有效期只有 7 天**，必须依赖自动续期，续期一断证书立刻过期；
- 仅支持 IPv4，且必须是公网可达的地址，私有地址签不了。

有域名就用域名，IP 证书只适合临时用。完整限制清单、NAT 环境的注意事项和
私有 IP 的替代方案见 `HowtoGuides.md` 的 7.2。

### 3.8 FTP

```bash
lnmp ftp {add|list|edit|del|show}
/etc/init.d/pureftpd {start|stop|restart}
```

### 3.9 其他运维脚本（`tools/` 目录）

| 脚本 | 用途 |
|---|---|
| `lnmp-backup.sh` | `lnmp backup` 的实现，安装为 /bin/lnmp-backup |
| `lnmp-tgnotice.sh` | Telegram 通知，安装为 /bin/lnmp-tgnotice，并提供全局 `tgnotice` 函数 |
| `backup.sh` | 已废弃，转发到 `lnmp backup run all` |
| `cut_nginx_logs.sh` | Nginx 日志切割 |
| `check502.sh` | 检测 502 并自动重启 PHP-FPM |
| `reset_mysql_root_password.sh` | 重置数据库 root 密码 |
| `remove_open_basedir_restriction.sh` | 去掉防跨目录限制 |
| `remove_disable_function.sh` | 解除 PHP 禁用函数 |
| `denyhosts.sh` / `fail2ban.sh` | SSH 防爆破 |
| `denyhosts_removeip.sh` | 解封被误封的 IP |


### 3.10备份：`lnmp backup`（网站文件与数据库，自动导出、自动上传、可试恢复）。

```bash
lnmp backup init         # 扫描已有站点，挑选要备份的站点后生成 /etc/lnmp/backup.conf，并装好 systemd timer
lnmp backup run          # 立即执行一次（timer 会自动调用，通常不必手工跑）
lnmp backup run <域名>…  # 只备份指定站点（该站点的文件与库）
lnmp backup run db  <域名>…  # 只备份指定站点的库
lnmp backup run web <域名>…  # 只备份指定站点的文件
lnmp backup status    # 上次结果、下次计划、最近错误
lnmp backup list      # 列出本地与远端的备份批次
lnmp backup test      # 试恢复：把最新库备份导入临时库校验后删除
lnmp backup restore db  <库名> [批次]
lnmp backup restore web <域名> [批次]
```

配置在 `/etc/lnmp/backup.conf`（权限 600），站点按
`域名|网站目录|数据库名` 一行一条，数据库和网站可以有各自的备份周期与保留天数
（例如库每天一份留 14 天，网站每周一份留 60 天）。

`init` 扫描到站点后会让你挑选要纳入备份的站点：回车全选，`1 3` 或直接写域名只选
指定项，`-default` 或 `-2` 排除指定项 —— `default` 这类占位站点可以在这一步排除。
`init` 还会询问备份存放目录（默认 `/home/backup`，磁盘不够时改到大盘），并在结尾
醒目列出仍是默认值、需要按实际情况修改的参数，尤其是默认关闭的异地上传与加密。
配置改完直接生效，不必重跑 `init`（只有要改执行时间才需要重跑）。

`run` 不带站点参数时按配置整体执行；带域名时只备份指定站点，此类部分备份不会推进
网站备份周期、也不会清理任何旧批次，适合临时给某个站点补一份。

`init` 之后本地备份就已经由 systemd timer 自动执行。异地上传默认关闭，
开启需要一台独立的备份服务器并在两侧各配一次 ——
备份账号、chroot、专用密钥、主机指纹核对和排查表都写在
`HowtoGuides.md` 的「8.5 异地备份（SFTP）」，照着做即可。

### 3.11 防火墙

本包用 nftables，规则在独立的 `inet lnmp` 表里：

```bash
nft list table inet lnmp        # 查看本包加的规则
nft list ruleset                # 查看全部规则
```

默认放行 `SSH_Port`（默认 22）、80、443 和 ping，挡掉数据库、Redis、Memcached
端口的外部访问；具体端口跟随 `lnmp.conf` 里的变量（见 3.1.1），不是写死的。
链的默认策略为 `accept`，避免安装过程阻断现有管理连接。
持久化文件：Debian 系 `/etc/nftables.d/lnmp.nft`，由 `nftables.service` 加载。

### 3.12 Telegram 通知

```bash
lnmp tgnotice --init      # 交互写入 /etc/lnmp/notify.conf（600）
lnmp tgnotice --test      # 发一条测试消息
lnmp tgnotice --status    # 看当前配置（token 只显示前段）
```

配好之后，`tgnotice` 是一个**全局可用的 shell 函数**，在任何脚本或交互
shell 里都能直接写：

```bash
tgnotice "备份失败：wpdemo"          # 默认 HTML 格式
tgnotice "*备份完成*" md             # MarkdownV2 格式
tgnotice "原样文本 < & >" text       # 不做格式解析
```

函数由 `/etc/profile.d/lnmp-tgnotice.sh` 自动加载。非交互脚本里如果取不到，
显式加载一次：`. /bin/lnmp-tgnotice`。

几个行为要点：

- bot token 和消息正文都不进命令行参数（走 curl 的 600 配置文件），
  同机其他用户 `ps` 看不到。
- 文本原样发送，不替你转义 —— HTML 模式下 `<b>粗体</b>` 是有效的。
  代价是纯文本里的 `<` `&` 会让 Telegram 报 400，此时会**自动降级成纯文本
  重发一次**并打印告警，通知不会因为格式问题丢掉。
- 未配置或 `TG_Enable=0` 时静默跳过并返回 0，所以在脚本里随手加调用是安全的。
- 发送失败返回非 0。通知失败通常不该中断主流程，需要时写
  `tgnotice "..." || true`。

---

## 四、组件手工升级

### 4.1 优先用升级脚本

```bash
./upgrade.sh nginx        # 升级 Nginx
./upgrade.sh mysql        # 升级 MySQL
./upgrade.sh mariadb      # 升级 MariaDB
./upgrade.sh m2m          # MySQL 迁移到 MariaDB
./upgrade.sh php          # 升级 PHP（LNMP）
./upgrade.sh phpa         # 升级 PHP（LNMPA / LAMP）
./upgrade.sh phpmyadmin   # 升级 phpMyAdmin
./upgrade.sh mphp         # 升级多版本 PHP 中的某一个
```

完整安装默认不部署 phpMyAdmin。主栈装好后如需补装，可显式执行：

```bash
./install.sh phpmyadmin
```

安装后可随时关闭或重新开启公网入口，程序、配置和随机访问路径不会删除：

```bash
lnmp phpmyadmin disable
lnmp phpmyadmin enable
lnmp phpmyadmin status
```

在源码目录中也可使用 `./install.sh phpmyadmin disable|enable|status`。

脚本会识别现有 LNMP/LNMPA/LAMP 环境，校验下载文件，生成随机访问路径并在
Web 配置检查通过后重载服务。重复执行不会覆盖现有安装；升级仍使用
`./upgrade.sh phpmyadmin`。

脚本会要求输入目标版本号。Nginx 和 PHP 的升级采用**事务式**流程：
先在临时目录构建、跑冒烟测试、通过后才切换，失败自动回滚。
**数据库升级没有自动回滚，执行前必须完成备份。**

### 4.2 改默认版本号：`include/version.sh`

想让新安装默认用别的版本，改这个文件里对应的变量，例如：

```bash
Nginx_Ver='nginx-1.30.4'
Openssl_New_Ver='openssl-3.5.7'
Redis_Stable_Ver='redis-8.10.0'
Pcre_Ver='pcre-8.45'
```

数据库和 PHP 的版本不在这里，而在 **`include/profile.sh`** 的映射表里
（因为它们同时决定菜单项、安装函数、二进制包架构等一整组信息）：

```bash
1)  DB_Kind='mysql'   DB_Branch='8.0'  DB_Ver='mysql-8.0.46' ...
2)  DB_Kind='mysql'   DB_Branch='8.4'  DB_Ver='mysql-8.4.7'  ...
```

### 4.3 版本号变更要求

**（1）更新 `src/checksums.sha256`**

本包对每个下载文件强制校验 SHA256，清单里没有对应条目会**直接中止安装**。
改完版本号后：

```bash
# 从官方获取新版本校验值（或自行下载后计算）
sha256sum nginx-1.31.0.tar.gz
# 按格式写进 src/checksums.sha256：<64位小写hex><两个空格><落地文件名>
```

**文件名必须是「落地文件名」，不是 URL 的 basename。**
校验按 `Download_Files` 的第二个参数查表，两者可能不同。
GitHub 的 tag 归档尤其明显：URL 是 `v0.33.tar.gz`，落地名是 `lua-resty-redis-0.33.tar.gz`。
写错的话清单看着是满的，装的时候照样中止。

**校验值从哪里取**（按可信度排序）：

1. 上游发布的校验文件或 API。PHP 使用 php.net releases 接口，
   MariaDB 用官方 REST API、phpMyAdmin 用同目录的 `.sha256`、
   Boost 用 archives.boost.io 的 `.json`。这几类本包已经能自动获取，
   通常不用手工登记。
2. 上游发布页面上公布的校验值，手工抄录后核对。
3. 自行下载后执行 `sha256sum`。**该方法只能保证后续安装内容与本次下载一致，
   不能证明文件来源可信**。仅在前两种方式不可用时采用，并确保采集环境可信。

**（2）确认下载 URL 仍然有效**

Nginx 官方**只保留每个分支的最新点版本**，旧点版本可能下线，
所以 Nginx 一旦发新版，本包就必须跟进，否则下载 404。
其他项目多数有归档站，本包已尽量使用不会下线的归档地址。

改完后可以手工验证一下：

```bash
curl -fsIL https://nginx.org/download/nginx-1.31.0.tar.gz | head -1
```

### 4.4 新增一个下载组件时

1. URL 必须指向**该组件开发方的官方站点**或其官方 GitHub 项目，必须是 HTTPS；
2. 下载后紧跟 `Require_File "<落地文件名>" "<组件名>"` 做存在性守卫；
3. 在 `src/checksums.sha256` 里加上对应条目；
4. 编译安装使用 `Make_Install || exit 1`，不得直接调用 `make`。

### 4.5 升级后的检查

```bash
/usr/local/nginx/sbin/nginx -V          # 确认版本与模块
/usr/local/php/bin/php -v && php -m     # 确认版本与扩展没丢
/usr/local/mysql/bin/mysql --version
lnmp status                             # 确认服务都在跑
```

PHP 升级后特别注意：**编译进去的扩展需要重新装**（`./addons.sh`），
`conf.d/` 下的 ini 会保留但对应的 `.so` 可能已经不匹配新版本。

---

## 五、常见问题

### 数据库的 root 默认密码是什么？

该密码为安装时输入的值。直接回车选择随机生成时，密码会写入
`/root/.lnmp_db_root_password`（权限 0600），用 `cat /root/.lnmp_db_root_password` 查看，
**记下后请删除该文件**。

密码不会打印到屏幕或安装日志，避免排障时随日志泄露。
随机密码也不再是"固定前缀 + 随机数字"的形式，改为 `/dev/urandom` 生成的 96 位随机值。

### 忘记数据库 root 密码怎么办？

```bash
./tools/reset_mysql_root_password.sh
```

按提示输入两遍新密码即可。脚本会停掉数据库，用**禁用网络 + 私有 socket** 的方式
临时启动并修改密码，然后正常重启；重置期间数据库不对外提供服务。

### 如何添加/删除虚拟主机？

```bash
lnmp vhost add     # 添加
lnmp vhost list    # 查看
lnmp vhost del     # 删除（只删配置，网站文件保留）
```

添加时会依次询问域名、附加域名、网站目录、是否防跨目录、是否记日志、
伪静态规则、是否申请 SSL。

### 如何修改默认虚拟主机的域名？

编辑 `/usr/local/nginx/conf/nginx.conf`，找到 `server_name`，
改为实际域名（多个域名用空格分隔），保存后执行
`/usr/local/nginx/sbin/nginx -s reload`。

### 如何启动/停止 Nginx、PHP-FPM、MySQL？

```bash
lnmp {start|stop|restart|reload|status}                 # 全部
lnmp nginx restart                                      # 单个
lnmp mysql stop
lnmp php-fpm reload
```

### 网站目录和各种文件都在哪？

| 内容 | 路径 |
|---|---|
| 默认网站目录 | `/home/wwwroot/default`（可在 `lnmp.conf` 改） |
| 网站日志 | `/home/wwwlogs/` |
| Nginx | `/usr/local/nginx/`，配置 `conf/nginx.conf`，站点 `conf/vhost/` |
| OpenResty | 同上（`/usr/local/nginx` 指向它，路径通用） |
| Apache | `/usr/local/apache/` |
| MySQL | 程序 `/usr/local/mysql/`，数据 `/usr/local/mysql/var/`，配置 `/etc/my.cnf` |
| MariaDB | 程序 `/usr/local/mariadb/`，数据 `/usr/local/mariadb/var/`，配置 `/etc/my.cnf` |
| PHP | `/usr/local/php/`，配置 `etc/php.ini`、`etc/php-fpm.conf` |
| 多版本 PHP | `/usr/local/php8.4/` 之类 |
| Redis / Memcached | `/usr/local/redis/`、`/usr/local/memcached/` |
| Pure-FTPd | `/usr/local/pureftpd/` |
| 本包自己的配置 | `/etc/lnmp/`（备份、通知等，权限 600） |
| 数据库密码 | `/root/.lnmp_db_root_password` |
| SSL 证书 | `/usr/local/nginx/conf/ssl/` |

### 如何给 PHP 安装需要的扩展？

```bash
./addons.sh                       # 交互菜单
./addons.sh install redis         # 或直接指定
```

支持 redis、memcached、opcache、apcu、imagemagick、exif、fileinfo、
ldap、bz2、sodium、imap、swoole。装完自动写 ini 并重启 FPM。
装完用 `/usr/local/php/bin/php -m` 确认。

### 如何开启 IMAP 模块？

```bash
./addons.sh install imap
```

### 数据库无法远程连接，如何开启？

默认禁止远程连接是有意的。确需开启，三步都要做：

1. **授权**：`GRANT ALL ON 库名.* TO '用户'@'你的IP' IDENTIFIED BY '密码';` 然后 `FLUSH PRIVILEGES;`
   （禁止使用 `'%'`，应限定到具体 IP）
2. **监听**：检查 `/etc/my.cnf` 里有没有 `bind-address = 127.0.0.1`，有则注释掉或改为具体 IP，重启数据库
3. **放行端口**：本包用 nftables 把数据库端口挡掉了，需要放行：
   ```bash
   nft -a list table inet lnmp                          # 查 handle
   nft delete rule inet lnmp input handle <对应的 handle>
   ```
   **强烈建议只对固定来源 IP 放行**，而不是对整个公网开放数据库端口。

云服务器还要检查安全组。

### 提示 `open_basedir restriction in effect`，如何解除防跨目录？

ThinkPHP、Laravel、CI 这类框架的入口在 `public/` 下，但要调用上级目录的文件，
就会撞上防跨目录限制（有时表现为 500 错误）。

限制写在**网站目录下的 `.user.ini`** 里，该文件带 `chattr +i` 保护，需要先解锁：

```bash
chattr -i /home/wwwroot/你的站点/.user.ini
vi /home/wwwroot/你的站点/.user.ini     # 修改 open_basedir 的路径列表
chattr +i /home/wwwroot/你的站点/.user.ini
lnmp php-fpm restart
```

`.user.ini` 改动**需要等约 5 分钟或重启 php-fpm 才生效**。
也可以直接用 `tools/remove_open_basedir_restriction.sh` 一键去掉。

### 访问网站提示 500 错误，怎么排查？

先开 PHP 错误日志。**LNMP 模式**编辑 `/usr/local/php/etc/php-fpm.conf`，
在 `[www]` 段里加上：

```
php_admin_value[error_log] = /usr/local/php/var/log/php_errors.log
php_admin_flag[log_errors] = on
```

或者加 `catch_workers_output = yes`，错误会记到 `error_log` 指定的文件。
改完 `lnmp php-fpm restart`。日志文件没自动创建就手工建：

```bash
touch /usr/local/php/var/log/php_errors.log
chown www:www /usr/local/php/var/log/php_errors.log
```

要在页面上显示错误，同样在 `php-fpm.conf` 里加 `php_flag[display_errors] = On`
（`php.ini` 里改无效，会被 FPM 覆盖）。**排查完记得关掉，别在生产环境显示错误。**

**LNMPA / LAMP 模式**则是编辑 `/usr/local/php/etc/php.ini`，
找到 `;error_log` 加上 `error_log = /usr/local/php/var/log/php_errors.log`，
重启 Apache 生效。记不下来可以试 `error_log = syslog`，会写到系统日志。

同时别忘了看 Nginx 错误日志：`tail -f /home/wwwlogs/nginx_error.log`。

### php-fpm 慢日志怎么开？

编辑 `/usr/local/php/etc/php-fpm.conf`：

```
request_slowlog_timeout = 5
slowlog = /usr/local/php/var/log/slow.log
```

超过 5 秒的请求会被记录（含调用栈）。改完 `lnmp php-fpm restart`。
默认 `request_slowlog_timeout = 0` 表示不记录。

### 如何添加伪静态？

规则文件放在 `/usr/local/nginx/conf/rewrite/`，`lnmp vhost add` 时可以直接选，
也可以事后在站点配置 `/usr/local/nginx/conf/vhost/<域名>.conf` 的 `server` 段里加：

```nginx
include rewrite/你的规则.conf;
```

然后 `/usr/local/nginx/sbin/nginx -t && /usr/local/nginx/sbin/nginx -s reload`。

### 如何添加自定义 404 页面？

在站点配置 `/usr/local/nginx/conf/vhost/<域名>.conf` 的 `server` 段里加：

```nginx
error_page 404 /404.html;
```

把 `404.html` 放到网站根目录，然后 reload。
注意：由应用程序处理 404 时不得添加该配置，否则会覆盖应用程序的响应。

### 如何限制 Nginx 每个 IP 的连接数和速度？

在 `/usr/local/nginx/conf/nginx.conf` 的 `http` 段里定义：

```nginx
limit_conn_zone $binary_remote_addr zone=perip:10m;
limit_req_zone  $binary_remote_addr zone=reqip:10m rate=10r/s;
```

在需要限制的 `server` 或 `location` 段里使用：

```nginx
limit_conn perip 10;          # 每 IP 最多 10 个并发连接
limit_req  zone=reqip burst=20 nodelay;   # 每秒 10 个请求，允许突发 20
limit_rate 512k;              # 每连接限速 512KB/s
```

改完 `nginx -t` 通过后 reload。

### 安装好后端口通、Ping 通，但网站访问不了？

按顺序查：

1. `lnmp status` 确认 Nginx 在跑
2. `ss -ntl | grep -E ':80|:443'` 确认在监听
3. `nft list table inet lnmp` 确认 80/443 是放行的
   （本包使用 nftables，不应通过停用 iptables 排查）
4. 检查云服务器**安全组**是否放行 80/443
5. 国内服务器直接用 IP 访问经常不通，属正常现象（备案/白名单限制）

### 如何更改网站目录和数据库数据目录？

**安装前**：直接改 `lnmp.conf` 里的 `Default_Website_Dir` 和 `MySQL_Data_Dir`。

**安装后改网站目录**：改站点配置里 `root` 后面的路径，然后

```bash
cp -a /老目录 /新目录
chown -R www:www /新目录
```

如果站点有 `.user.ini`，里面的 `open_basedir` 路径也要一起改
（先 `chattr -i` 解锁）。

**安装后改数据库目录**（以 `/data/mysql/` 为例）：

```bash
lnmp mysql stop
mkdir -p /data/mysql
cp -a /usr/local/mysql/var/* /data/mysql/
chown -R mysql:mysql /data/mysql
```

然后编辑 `/etc/my.cnf`，在 `[mysqld]` 段里把 `datadir` 改成 `/data/mysql/`；
如果配置里有 `innodb_data_home_dir` / `innodb_log_group_home_dir`，一并改。
最后 `lnmp mysql start`。**确认新库起得来之后再删旧目录。**

### 数据库启动不了，一直卡在 `Starting MySQL...`？

先看错误日志：

```bash
tail -50 /usr/local/mysql/var/$(hostname).err
```

优先检查以下两项：

1. **磁盘空间不足**：使用 `df -h` 确认。清理时优先删除旧的二进制日志，
   用 `PURGE BINARY LOGS BEFORE '2026-01-01';` 而不是直接 `rm`，
   直接删文件会让索引文件和实际文件对不上。
2. **数据目录权限错误**：执行 `chown -R mysql:mysql /usr/local/mysql/var`。

### 如何确认 Memcached / Redis 装好了？

```bash
# Memcached
/etc/init.d/memcached status
echo stats | nc 127.0.0.1 11211
/usr/local/php/bin/php -m | grep -i memcache

# Redis
/etc/init.d/redis status
/usr/local/redis/bin/redis-cli ping        # 返回 PONG
/usr/local/php/bin/php -m | grep redis
```

两者默认都只监听本机、端口在防火墙里挡掉，这是有意的安全设置。

### IPv6 环境需要注意什么？

站点配置里的 `listen` 需要同时监听 v6：

```nginx
listen 80;
listen [::]:80;
```

SSL 站点同理加 `listen [::]:443 ssl;`。
防火墙方面本包用的是 nftables 的 `inet` 表，v4/v6 规则是统一的，不需要额外配置。

### 如何安装 pear？

PHP 编译时已带 `--with-pear`，直接用：

```bash
/usr/local/php/bin/pear version
/usr/local/php/bin/pear install <包名>
```

如果提示找不到，说明该版本 PHP 未成功装上 pear，可以用
`/usr/local/php/bin/php -r "..."` 从官方安装器手工装。

### MySQL 提示 `--skip-locking is deprecated`？

本包生成的 `/etc/my.cnf` 用的已经是 `skip-external-locking`，不会有这个警告。
如果是从旧版本迁移过来的配置文件，把 `skip-locking` 改成 `skip-external-locking` 即可。

### 如何修改 Pure-FTPd 的用户密码？

```bash
lnmp ftp edit      # 修改指定 FTP 用户的密码
lnmp ftp list      # 查看已有用户
lnmp ftp show      # 查看用户详情
```

### 装到一半失败了，能重跑吗？

可以，脚本设计成可重复执行。但**先看清楚失败在哪一步**：安装日志在
`/root/lnmp-install.log`（单独装数据库是 `/root/install_database.log`）。
失败会返回非零退出码并就地停止，不会带着半成品继续往下装。

数据库源码编译中途失败最常见的两个原因是内存不足和磁盘不足，见 2.x 那张表。

### 想换 Web 服务器（Nginx ↔ OpenResty）怎么办？

没有平滑切换的路径。两者会抢同一套目录和端口，安装脚本检测到冲突会直接拒绝。
要换就先卸载再装，站点配置（`conf/vhost/`）和网站文件请提前自行备份。

### `systemctl status` 显示服务没跑，但网站是通的？

多半是绕过 `lnmp` 直接用 `/etc/init.d/xxx start` 启的。用 `lnmp xxx restart`
重启一次即可让 systemd 重新接管。日常运维请统一用 `lnmp`。

### 备份能只备数据库不备网站吗？

可以。`/etc/lnmp/backup.conf` 里站点条目的数据库名留空就只备文件，
反过来不配网站目录就只备库；两者的备份周期和保留天数也是分开配的。
改完用 `lnmp backup run` 手工跑一次确认退出码为 0。

### 装完之后还需要自己做什么？

至少这几件：

1. `cat /root/.lnmp_db_root_password` 记下数据库密码后删掉该文件；
2. 确认云服务器安全组放行了 80/443；
3. `lnmp backup init` 把备份配起来，并验证一次 `lnmp backup test`；
4. 有域名就 `lnmp vhost add` 建站并签证书，别长期用默认站点；
5. 如果 SSH 不在 22 端口，**装之前**就要在 `lnmp.conf` 里改 `SSH_Port`。

### 性能优化从哪里入手？

按收益排序：

1. **PHP-FPM 进程数**：`/usr/local/php/etc/php-fpm.conf` 的 `pm.max_children`，
   按每进程 30~50MB 估算内存后上调（默认 10 偏保守）。
2. **开启 opcache**：`./addons.sh install opcache`，对 PHP 性能提升最明显。
3. **加缓存层**：`./addons.sh install redis`，把会话和热数据放进去。
4. **数据库缓冲池**：`/etc/my.cnf` 的 `innodb_buffer_pool_size`，
   独立数据库服务器可给到物理内存的 50~70%。
5. **Nginx 静态资源**：开启 gzip / brotli（本包已编译进 brotli 模块）、
   给静态文件设 `expires`。

修改前应记录当前值，每次只调整一项并观察结果。

---

## 六、相关文档

本文档只讲「装完之后怎么用」，具体步骤和实现细节在下面几处：

- **`HowtoGuides.md`**：手把手的操作手册 —— 从安装、建站、部署 WordPress、
  配 HTTPS（含无域名的 IP 证书）、OpenResty 自定义模块、异地备份，到故障排查。
  遇到「具体该敲哪几条命令」的问题先看它。
- **`lnmp.conf`**：全部可配置项，每一项的用途、取值和影响都写在注释里。
- **`changelog.md`**：全部改动的逐条记录，含每处改动的原因、取舍和验证范围。
  想知道某个行为「为什么是这样」，答案在这里。
- **`todo.md`**：已确认但尚未处理的问题。
