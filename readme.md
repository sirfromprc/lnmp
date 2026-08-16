# LNMP 2.3

用 Shell 编写的一键安装包，在 Linux 服务器上编译安装 **LNMP**（Nginx/MySQL/PHP）、
**LNMPA**（Nginx/MySQL/PHP/Apache）或 **LAMP**（Apache/MySQL/PHP）生产环境，
并附带虚拟主机管理、数据库管理、FTP 管理、SSL 证书签发、升级、备份等运维工具。

原始项目作者：licess。本包是 LNMP 2.3 的安全加固与精简分支，
每一处改动都逐条记录在随包的 `changelog.md`。

---

## 目录

- [一、功能与安全特性](#一功能与安全特性)
- [二、安装](#二安装)
- [三、常用功能说明](#三常用功能说明)
- [四、组件手工升级](#四组件手工升级)
- [五、常见问题](#五常见问题)
- [六、相关文档](#六相关文档)

---

## 一、功能与安全特性

### 版本与组件

- 数据库收敛为 **MySQL 8.0 / 8.4 LTS** 与 **MariaDB 10.11 / 11.4 / 11.8 LTS**，
  默认 MySQL 8.4；PHP 收敛为 **8.0 ~ 8.5**，默认 8.3。菜单仍保留 MySQL 8.0、
  PHP 8.0 等 EOL 分支用于既有环境兼容，不建议新部署选择；新站应按上游安全支持期和
  WordPress/插件兼容性选择 8.3/8.4 等受支持 PHP 分支。
  5.x / 7.x 系列的 PHP、MySQL 5.1~5.7、MariaDB 10.0~10.6 以及 Apache 2.2 已移除，
  它们都已停止安全维护。
- 组件升级到当前稳定版：Nginx 1.30、OpenSSL 3.5 LTS、Apache 2.4.68、phpMyAdmin 5.2.3。
- Web 服务器可以选 **Nginx** 或 **OpenResty 1.31**（二选一，见 3.2.1）。
- Nginx 默认编译进 **brotli、cache_purge、Lua（LuaJIT + lua-nginx-module
  + resty core/lrucache/cjson）**，并启用 HTTP/2、HTTP/3 与 stream 模块；
  fancyindex 模块可选、默认关闭（`Enable_Ngx_FancyIndex=n`）；
  PHP 默认带上常用扩展。
- 防火墙使用 **nftables**，规则只写入独立的 `inet lnmp` 表；检测到 firewalld
  运行时使用 `firewall-cmd`，避免直接覆盖其规则。

### 下载与完整性

- 所有组件一律从**该组件开发方的官方站点**下载（nginx.org、php.net、cdn.mysql.com、
  downloads.mariadb.org、archive.apache.org、files.phpmyadmin.net、pecl.php.net、
  以及上游自己维护的 GitHub 项目），全程 HTTPS。
- 下载完成后**强制执行项目为该组件配置的完整性校验**：静态或上游发布的 SHA256、
  PGP 签名、或软件仓库 GPG 签名；校验失败会删除文件并中止安装，不存在
  "校验失败但继续装"的路径。
- 运行时确定版本的组件（如 MySQL 源码编译所需的 Boost）从上游发布的机器可读
  校验值获取 SHA256；Nginx 使用 **PGP 签名验证**，公钥随包分发并固定指纹白名单。
- acme.sh 固定版本 + 校验 SHA256 后才解压执行，并关闭其自动升级。
- RHEL/CentOS 软件源使用官方 HTTPS、`gpgcheck=1` 及随包提供的 GPG 公钥。
- 安装前会**只读检查**宿主机已有的 APT/YUM 源有没有关掉签名或 TLS 校验，
  发现异常时仅提示，不阻断安装或修改现有配置。

### 安全基线

- **SELinux 默认保持启用状态**，仅在显式配置后关闭。
- `/home/wwwlogs` 权限从 777 收紧为 755；PHP-FPM socket 从 0666 收紧为 0660。
- MySQL/MariaDB socket 固定在 `/run/mysqld/`，PHP-FPM socket 固定在
  `/run/php-fpm/`；systemd 负责重建运行目录并保持 `PrivateTmp=true`，不再依赖
  共享 `/tmp`。首次数据库 root 密码只在禁网的私有 socket 上设置。
- MySQL 8.x 不再强制开启 `mysql_native_password`，新账号使用上游默认认证；
  MariaDB 保持自身认证逻辑，不套用 MySQL 专用选项。
- 数据库 root 随机密码由 `/dev/urandom` 生成，不显示在屏幕或安装日志中，
  仅写入 `/root/.lnmp_db_root_password`（0600）。
- 默认**不部署** phpinfo、phpMyAdmin、探针等页面，需要时在 `lnmp.conf` 里开启。
- default 兜底站点不执行 PHP：只放行 `phpinfo.php`、`redis.php`、
  `memcached.php` 三个固定文件名和 phpMyAdmin 入口，其余 `.php` 一律返回 404
  （Apache 系为 403），避免源码被当作静态文件下载。放行的三个文件只有对应
  开关打开时才会写进去，没写就还是 404。
- phpMyAdmin 开启后装在 `/usr/local/phpmyadmin`（网站根目录之外），
  访问路径随机生成（形如 `49763abb_phpmyadmin`），可用 `lnmp status` 查看；
  关闭时脚本会自动撤掉 Web 服务器上的映射。
- 管理脚本 `/bin/lnmp` 的域名、目录、数据库名等输入加了严格校验；
  临时文件改用 `mktemp`；SQL 参数做转义。
- Apache 安装的 `ServerAdmin`、三栈 ACME 邮箱和 DenyHosts 解封 IP 均在写配置或
  停服务前严格校验；LAMP/LNMPA 的 Apache 模板只把末尾 `.php` 交给 PHP，默认拒绝
  根目录访问并限制异属主符号链接。
- Pure-FTPd **新安装默认 `TLS 2`**，明文 FTP 登录被拒绝；账号管理和显式 FTPS
  保持可用。该默认值不迁移或覆盖既有服务器上的部署配置。
- 重置数据库 root 密码使用 `--init-file` 流程，并在临时实例上禁用网络监听。

### 可靠性

- 编译、解压或安装失败会立即停止，避免继续使用不完整产物。
- 安装和升级失败返回非零退出码，可供自动化流程判断结果。
- Nginx、PHP、多版本 PHP 和 phpMyAdmin 采用**构建验证、切换、失败回滚**流程。
  数据库升级暂未提供自动回滚，失败时会打印人工恢复步骤；升级前必须完成备份。
- 安装入口遇到已有 MySQL/MariaDB 数据目录时会整体移动到时间戳备份目录，
  包括隐藏文件和数据库子目录；移动或重建空目录失败就停止，不再非递归复制后删除原数据。
- 包管理器繁忙时等待锁释放，不终止包管理进程或删除 yum/dpkg 锁文件。

> **验证情况**：
>
> - **已在 Debian 12 实测**：`install.sh lnmp` 完整安装（Nginx + MySQL 8.4 + PHP 8.3）、
>   WordPress 主线、`install.sh db`、`pureftpd.sh`、`addons.sh` 的 Redis/Memcached、
>   OpenResty 官方包安装、自定义端口、数据库升级、phpMyAdmin 升级、备份与恢复。
> - **已在 Debian 13 实测**：LNMP 分别搭配 MySQL 8.4.7 与 MariaDB 11.8.8，
>   WordPress 7.0.3 的安装、首页、固定链接、REST、PHP-FPM、数据库和 Redis 均通过；
>   phpMyAdmin 随机入口与数据库管理命令同时覆盖两种数据库。
> - **Apache 系已在 Debian 13 实测**：LAMP 与 LNMPA 均使用本项目完整源码安装的
>   Apache 2.4.68 + PHP 8.3.33，覆盖正常 PHP、PATH_INFO、`.php.bak`、符号链接、
>   default 站点边界、phpMyAdmin 以及服务失败码传播。
> - **同批其它实测**：OpenResty 源码编译、`Enable_Nginx_Lua=n` 的编译版 Nginx、
>   Pure-FTPd `TLS 2` 下明文拒绝与显式 FTPS 上传、备份恢复、age/GPG 加密、
>   SFTP 与 FTP/FTPS 异地上传。安全定向回归 35/35，lint 18/18、一致性 14/14。
> - **未实测**：CentOS/RHEL 系、非 x86_64 架构、Telegram 通知的真实 API 链路、
>   公网环境下的 IP 证书签发。
>
> 无论哪种情况，部署到生产环境前都请先在测试机走一遍。

### 已知不支持或不完善

| 项目 | 状态 |
|---|---|
| LNMPA / LAMP（Apache 系） | 已在 Debian 13 / x86_64 完整安装并实测；其它发行版仍需自行验证 |
| CentOS / RHEL 系 | 代码保留，无额外验证轮次 |
| 非 x86_64 架构 | 本项目只对 x86_64 通用数据库包提供完整自动校验路径，其余架构回退源码编译 |
| Nginx 的 80 / 443 端口 | **不可统一配置**，分别由主配置、站点配置和证书签发流程管理 |
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

从本分支的项目页面获取代码。发布地址确定后，把下面的占位符替换为实际的 v2.3 Release
压缩包地址：

```bash
wget <v2.3-release压缩包地址>
tar zxf v2.3.tar.gz
cd lnmp2.3
chmod +x install.sh addons.sh uninstall.sh upgrade.sh
```

发布者应在 Release 页面同时提供压缩包 SHA256，下载后先核对再解压。tar 包通常会保留
可执行位，但 ZIP、面板上传或跨文件系统复制可能丢失，因此上面仍显式设置四个入口脚本。

> 建议使用固定的 **tag / release**。`main` 分支可能持续变化，无法保证不同时间安装的内容一致。
>
> 想确认拿到的代码没被动过，`git clone` 后执行 `git log -1` 核对提交哈希，
> 或用 release 页面公布的校验值核对压缩包。

### 安装

安装入口在最开始就检查 `id -u`，**不是 root 会立即退出，无法安装**。本文命令默认
已经直接登录 root；进入包目录后先确认身份，再执行安装：

```bash
id -u                    # 必须输出 0
bash install.sh {lnmp|lnmpa|lamp}
```

脚本需要连续写入 `/usr/local`、`/etc`、`/bin`、systemd 和防火墙配置；不要在普通
用户会话里尝试只给部分内部命令临时提权。

- `lnmp`：Nginx + MySQL/MariaDB + PHP
- `lnmpa`：Nginx 做前端、Apache 跑 PHP
- `lamp`：Apache + MySQL/MariaDB + PHP

安装过程会交互询问 Web 服务器（Nginx 还是 OpenResty）、数据库版本、数据库 root 密码、
PHP 版本、内存分配方式等。全程需要 **root 权限**，编译耗时从十几分钟到一小时以上不等
（取决于机器性能，以及数据库选二进制还是源码）。

常用安装选择可以用环境变量提前给定；`LNMP_Auto=y` 才会跳过确认：

```bash
# 装 LNMP：OpenResty 官方包 + MySQL 8.4 通用二进制 + PHP 8.3
read -r -s -p '数据库 root 密码: ' DB_Root_Password; echo
export DB_Root_Password
LNMP_Auto=y WebSelect=2 ORMode=1 DBSelect=2 Bin=y PHPSelect=4 \
SelectMalloc=1 InstallInnodb=y bash install.sh lnmp
unset DB_Root_Password
```

| 变量 | 取值 |
|---|---|
| `WebSelect` | `1` = Nginx（默认），`2` = OpenResty |
| `ORMode` | 选 OpenResty 时：`1` = 官方软件包（不编译，快），`2` = 源码编译 |
| `DBSelect` | `1`=MySQL 8.0 `2`=MySQL 8.4（默认） `3`=MariaDB 10.11 `4`=MariaDB 11.4 `5`=MariaDB 11.8 `0`=不装 |
| `Bin` | 数据库 `y` = 官方通用二进制（推荐），`n` = 源码编译 |
| `PHPSelect` | `1`~`6` 对应 PHP 8.0 / 8.1 / 8.2 / 8.3（默认） / 8.4 / 8.5 |
| `SelectMalloc` | `1`=不额外安装（默认），`2`=Jemalloc，`3`=TCMalloc |
| `InstallInnodb` | `y` / `n` |
| `DB_Root_Password` | 留空则随机生成并写入 `/root/.lnmp_db_root_password` |
| `LNMP_Auto` | `y`=非交互确认；必须同时明确提供其余选择与密码策略 |

> **注意：必须在无现有业务的干净系统上安装。** 安装脚本会卸载系统自带的 nginx / php /
> apache / mysql 相关包，并接管防火墙配置。

安装前至少核对以下项目，并保存输出作为部署基线：

```bash
cat /etc/os-release       # 发行版与版本
uname -m                  # 主线应为 x86_64
free -h                   # 可用内存与 Swap
df -h / /usr/local /home 2>/dev/null
df -i / /usr/local /home 2>/dev/null
timedatectl status        # 时间同步会影响 TLS 与证书签发
ss -lntup                 # 检查 80/443/3306 等端口占用
```

云主机还需核对安全组与磁盘快照。脚本管理本机防火墙，但不会修改云平台安全组。
已有网站、数据库、证书或自定义服务时，不应直接在原机安装。

其他入口：

```bash
bash install.sh nginx      # 只装 Nginx
bash install.sh db         # 只装 MySQL 或 MariaDB
bash install.sh mphp       # 额外安装一个 PHP 版本（仅 LNMP 模式）
bash uninstall.sh          # 卸载
bash upgrade.sh            # 升级
bash addons.sh             # 安装/卸载扩展插件
```

建议先 `screen -S lnmp`，SSH 断线后用 `screen -r lnmp` 接回，避免编译中断。
安装前确认已装 `wget`。

`uninstall.sh` 不会静默丢数据：数据库数据目录整体搬到
`/root/databases_backup_<时间戳>`，搬不动就中止卸载、不删任何文件；
`/etc/lnmp/` 下的备份配置搬到 `/root/lnmp_conf_backup_<时间戳>`，
其中存放数据库口令的 `backup-mysql.cnf` 直接删除——它对应的实例已经没了，
留着只会在重装后被当成新实例的凭据。网站文件与 `conf/vhost/` 下的站点配置
不在自动保留范围内，请自行备份。

**安装前必须检查 `lnmp.conf`**：网站目录、数据库目录、模块、端口和安全开关都在里面。
标量使用 `${变量:-默认值}` 的可以用环境变量覆盖；OpenResty 的数组选项必须直接编辑文件。
例如：

```bash
Default_Website_Dir=/data/wwwroot Enable_PhpMyAdmin=y bash install.sh lnmp
```

### 安装前配置索引

以下是 `lnmp.conf` 当前暴露的全部项目级安装选项。它们只在安装或升级读取；安装完成后
再改仓库里的 `lnmp.conf` 不会自动改动正在运行的服务。

| 类别 | 选项 | 推荐原则 |
|---|---|---|
| 编译参数 | `Nginx_Modules_Options`、`PHP_Modules_Options` | 默认留空；只追加已经审计来源和兼容性的参数 |
| 数据与站点目录 | `MySQL_Data_Dir`、`MariaDB_Data_Dir`、`Default_Website_Dir` | 使用本机绝对路径；数据库目录不要放 NFS，迁移前先做恢复测试 |
| Web 工具 | `Enable_PHPInfo_Page`、`Enable_PhpMyAdmin`、`Enable_Memcached_Test_Page`、`Enable_Redis_Test_Page` | 生产环境保持默认 `n`；需要 phpMyAdmin 时优先临时启用并限制来源 |
| Nginx 能力 | `Enable_Nginx_Openssl`、`Enable_Nginx_Lua`、`Enable_Ngx_Brotli`、`Enable_Ngx_CachePurge`、`Enable_Ngx_FancyIndex` | 保留 TLS；不用 Lua/缓存清除/目录索引就关闭相应模块，fancyindex 默认 `n` |
| Swap | `Enable_Swap` | 小内存 VPS 保持 `y` 作为 OOM 缓冲；Swap 不能替代降低 FPM/数据库内存 |
| PHP 工具与默认扩展 | `Enable_Composer`、`Enable_PHP_Default_Opcache`、`Enable_PHP_Default_Igbinary`、`Enable_PHP_Default_Redis`、`Enable_PHP_Default_Imagick` | Composer 与四个扩展默认 `y`；不用 Composer/Redis/Imagick 时可关闭以缩小依赖面 |
| PHP 可选扩展 | `Enable_PHP_Exif`、`Enable_PHP_Fileinfo`、`Enable_PHP_Ldap`、`Enable_PHP_Bz2`、`Enable_PHP_Sodium`、`Enable_PHP_Imap` | `fileinfo` 保持 `y`；其余只按应用依赖开启 |
| 下载策略 | `Download_Insecure`、`Enable_Download_Checksum`、`CheckMirror` | 前两项保持 `n`/`y`；`CheckMirror=n` 只跳过源修改、NTP 与 DNS 预检，并让未指定的 `Bin` 默认源码编译；APT 依赖安装和组件下载仍会联网 |
| 服务端口 | `SSH_Port`、`DB_Port`、`DB_X_Port`、`Redis_Port`、`Memcached_Port`、`Pureftpd_Port`、`Pureftpd_Data_Port`、`Pureftpd_Passive_Min`、`Pureftpd_Passive_Max` | `SSH_Port` 必须与 sshd 实际监听一致；数据库和缓存优先保持回环监听，不靠改端口防护 |
| OpenResty 源码构建 | `OpenResty_Custom_Modules`、`OpenResty_Modules_Options`、`OpenResty_Custom_Lualib`、`OpenResty_Opm_Packages`、`OpenResty_Luarocks_Packages` | 仅 `ORMode=2` 生效；模块必须 HTTPS 下载并固定 SHA256；数组直接编辑 `lnmp.conf` |
| SELinux | `Disable_Selinux` | 默认 `n`；先读审计日志并修策略，不把关闭 SELinux 当常规优化 |

安装后的配置路径、每个变量的作用域、三档内存建议以及 WordPress/Debian 优化见
`HowtoGuides.md` 的“配置总索引”和“WordPress 专项调优”。

`CheckMirror=n` **不等于离线安装**：Debian 清理旧包和安装编译依赖仍会执行
`apt-get update`，`src/` 缺少组件时仍会从上游下载。受限网络但仍想用数据库通用二进制时
要显式给 `Bin=y`；完整行为和离线前置条件见 `HowtoGuides.md` 2.5。

### 支持范围

代码层面支持 CentOS/RHEL/Debian/Ubuntu 及其常见衍生版，但验证投入并不平均：

- **Debian 系是主要目标**，当前主线优先验证 Debian 13，并保留 Debian 12 实测记录。
- **CentOS / RHEL 系不是本分支的主要关注对象**，代码支持保留但没有额外验证轮次，
  使用前请自行充分测试。
- 本项目当前只对 **x86_64** 通用数据库包提供完整的自动校验与安装路径。上游个别版本
  可能另有 aarch64 包，但没有被本项目纳入可校验清单；其他架构会自动回退源码编译，
  耗时和内存占用都显著更高。

#### 数据库：通用二进制还是源码编译

安装数据库时会问 `是否使用官方通用二进制包 [Y/n]（默认 y，推荐）`，
**没有特殊需求就选 `y`**：
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
并行任务数取 CPU 核数与「每个任务 1GB 内存」预算中的较小值。

非交互安装可以直接指定，例如：

```bash
DBSelect=2 Bin=y CheckMirror=n InstallInnodb=y bash install.sh db
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
lnmp vhost    {add|list|del}                      # 虚拟主机（含站点级 PHP 开关），见 3.2
lnmp database {add|list|edit|del|export|import}   # 数据库，见 3.3
lnmp backup   {init|run|status|list|restore|test} # 备份，见 3.10
lnmp ftp      {add|list|edit|del|show}            # FTP 账号，见 3.8
lnmp ssl add                                      # 签发证书，见 3.7
lnmp dnsssl   {cx|ali|cf|dp|he|gd|aws}            # DNS 验证签发（支持泛域名）
lnmp onlyssl  {cx|ali|cf|dp|he|gd|aws}            # 只签证书，不改 Nginx 配置
lnmp tgnotice {--init|--test|--status}            # Telegram 通知，见 3.12
```

> `reload` 是平滑重载配置，不中断连接；`restart` 会真正重启进程。
> 修改 Nginx 配置后优先使用 `reload`。`kill` 仅用于正常停止失败的情况。

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
Pureftpd_Port=2121 Redis_Port=6380 bash install.sh lnmp
```

覆写之后脚本会回读确认写进去了；模板结构变化导致没写成会直接报错停下，
不会出现"服务监听老端口、防火墙放行新端口"这种两边对不上又没有报错的情况。

> **改 `SSH_Port` 要格外小心**：本包只用它生成放行规则，不会去改
> `sshd_config`。SSH 使用非默认端口时必须同步设置，否则防火墙不会放行实际监听端口。
>
> `bash install.sh lnmp|lnmpa|lamp|nginx|db` 在装依赖前会自动探测系统实际
> 监听的 SSH 端口，和这里的 `SSH_Port` 对不上会直接拒绝安装；一致但仍是
> 默认的 22 时会提示改端口的具体步骤，并要求显式确认才继续（交互式）。
> `LNMP_Auto=y` 或无终端执行时跳过这一步，按 `SSH_Port` 的值直接放行。
>
> Nginx 的 80/443 不在其中，分别由 nginx.conf、站点配置和 SSL 签发流程管理。

### 3.2 Nginx

**配置文件**

| 路径 | 用途 |
|---|---|
| `/usr/local/nginx/conf/nginx.conf` | 主配置；内置的 `listen 127.0.0.1:1008` server 是仅本机可访问的管理端口 |
| `/usr/local/nginx/conf/vhost/` | 各站点配置，一个域名一个 `.conf` |
| `/usr/local/nginx/conf/vhost/default.conf` | 静态兜底站点：`server_name _;`，接收匹配不上其它站点的请求（含直接用 IP 访问），装 nginx 时自动生成 |
| `/usr/local/nginx/conf/rewrite/` | 伪静态规则 |
| `/usr/local/nginx/conf/enable-php.conf` | PHP 处理（默认版本） |
| `/usr/local/nginx/conf/enable-php8.4.conf` | 多版本 PHP 时按版本选用 |
| `/home/wwwlogs/` | 访问与错误日志 |

default 站点默认不加载 PHP，`.php` 请求返回 404；`/.well-known/` 使用高优先级
规则放行 ACME HTTP-01 验证。启用 phpMyAdmin 后，访问片段才会带入 PHP 处理配置；
关闭入口时两者一并撤下。默认访问与错误日志分别是
`/home/wwwlogs/default.log`、`/home/wwwlogs/default.error.log`。

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

`lnmp vhost add` 会依次问：主域名 → 附加域名 → 网站目录 → 伪静态规则 →
**是否开启 PHP** → Pathinfo → 是否写访问日志 → IPv6 → 是否建库 → 是否申请 SSL 证书。
新站点配置写入 `/usr/local/nginx/conf/vhost/<域名>.conf`。
**配置语法检查不通过会自动删除并报错退出**，不会留下一个起不来的 Nginx。

**站点级 PHP 开关**：`是否开启 PHP? (Y/n，默认 y)` 默认开启，与原有建站流程一致。
选 `n` 时跳过 Pathinfo 和 PHP 版本询问，站点配置中不写 PHP 执行入口
（LNMP 不写 `include enable-php*.conf;`，LNMPA 不写 `include proxy-pass-php.conf;`，
LAMP 关掉该站点的 PHP 引擎），首页候选去掉 `index.php`，`.php` 及 `.php/xxx`
一律返回 404，站点目录也不写 `.user.ini`。适用于纯静态站点以及 Node、Go 等
自带后端的站点；反向代理地址需按后端实际监听端口配置。
`lnmp ssl add` 会从现有站点配置读回该状态，HTTPS 不会重新打开 PHP。
非交互执行时这一问不读标准输入，只看环境变量 `VHOST_PHP`（不设即开启 PHP），
用法见 `HowtoGuides.md` 4.4。

**修改默认站点域名**：编辑 `/usr/local/nginx/conf/vhost/default.conf` 找到
`server_name _;`，改为实际域名（多个域名用空格分隔），然后执行
`/usr/local/nginx/sbin/nginx -s reload`。一般不需要改。

**default 兜底站点**：`lnmp vhost add` 输入 `default` 不会再走一遍完整问答——
装 nginx 时已经自动建好了 `vhost/default.conf`，直接提示说明并告诉你申请
IP 证书用 `lnmp ssl add`（域名填 `default`），详见 3.7。

**日志格式与切割**：主配置定义 `main` 格式，新建站点和 default 站点显式使用；
Cloudflare/反向代理取真实访客 IP 的配置示例见 `HowtoGuides.md`。日志切割使用
`tools/cut_nginx_logs.sh`，可加进 crontab 每天执行。

### 3.2.1 OpenResty（Nginx 的可选替代）

OpenResty 是带 LuaJIT 和一整套 Lua 库的 Nginx 发行版。安装时二选一：

```bash
WebSelect=2 ORMode=1 bash install.sh lnmp    # 官方软件包，不编译，一分钟左右装完
WebSelect=2 ORMode=2 bash install.sh lnmp    # 源码编译，可加自定义模块
```

装完之后 **3.2 里的路径和命令完全照用**，`lnmp` 的 vhost 管理、日志切割也一样，
不需要记两套。

选源码编译（`ORMode=2`）时，可以在 `lnmp.conf` 里加自定义编译模块、额外的
configure 参数、自定义 Lua 库目录，以及 opm / luarocks 包。模块必须给出下载地址
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
| 错误日志 | `/usr/local/mysql/var/<主机名>.err` | `/usr/local/mariadb/var/mariadb.err` |
| 服务名 | `lnmp mysql ...` | `lnmp mariadb ...` |

数据目录可在 `lnmp.conf` 里用 `MySQL_Data_Dir` / `MariaDB_Data_Dir` 改；
装完之后再改要按 5.x「如何更改网站目录和数据库数据目录」的步骤搬。
下文命令一律以 MySQL 为例，MariaDB 把路径里的 `mysql` 换成 `mariadb` 即可。
MariaDB 安装会优先使用 `mariadb`、`mariadb-dump` 等新程序名，同时保留
`mysql`、`mysqldump` 等旧入口作为兼容包装器；已有脚本无需立即改名，且
MariaDB 11.8 不会再因为旧入口打印 `Deprecated program name`。

MySQL 8.x 使用上游默认认证，不再由模板强制启用已废弃的
`mysql_native_password`。需要连接 MySQL 8.4 的旧客户端应升级客户端；本项目不为旧客户端
全局降低新账号认证强度。两种数据库的 socket 都是 `/run/mysqld/mysqld.sock`，管理脚本
显式读取 `${HOME}/.my.cnf`，MySQL 与 MariaDB 的数据库增删、导入导出和改密均已实测。

不要用重新运行安装脚本代替数据迁移。安装入口发现数据目录已经存在时，会先把整个目录
移动到 `/root/mysql-data-dir-backup<时间戳>` 或
`/root/mariadb-data-dir-backup<时间戳>`；移动失败就停止，不会继续初始化或删除原数据。

两者安装后都由同一内存分档生成 buffer pool 和 500 个最大连接，但这只是项目默认，
不等于生产推荐。MariaDB 还会生成 query cache 配置，而 MySQL 8 已删除该功能；现代
WordPress 不应照搬旧教程放大 query cache。三档内存值、MariaDB 优化及与 MySQL 8.4 的
性能对比见 `HowtoGuides.md` 6.4~6.6。

**日常命令**

```bash
lnmp mysql restart                                  # 重启
/usr/local/mysql/bin/mysql -uroot -p                # 登录
cat /root/.lnmp_db_root_password                    # 查随机生成的 root 密码
/usr/local/mysql/bin/mysqladmin -uroot -p status    # 状态
# 全库备份
/usr/local/mysql/bin/mysqldump -uroot -p --all-databases > all.sql
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
bash tools/reset_mysql_root_password.sh
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
| `/usr/local/php8.4/` | 多版本 PHP（`bash install.sh mphp` 装的） |

主 PHP 安装默认同时安装 Composer；不需要时，在安装前设置：

```bash
Enable_Composer=n bash install.sh lnmp
```

该开关只影响本次 PHP 安装，不会删除已经安装的 `/usr/local/bin/composer`。

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
bash addons.sh                                          # 交互菜单
bash addons.sh install {redis|memcached|opcache|apcu|imagemagick|exif|fileinfo|ldap|bz2|sodium|imap|swoole}
bash addons.sh uninstall <同上>
```

装完会自动写 `/usr/local/php/conf.d/` 下的 ini 并重启 FPM。
存在多个 PHP 版本时，脚本会要求选择目标版本。

**多版本 PHP**

```bash
bash install.sh mphp        # 安装额外版本（仅 LNMP 模式）
```

装好后在站点配置里把 `include enable-php.conf;` 换成
`include enable-php8.4.conf;`（版本号按实际），然后 `lnmp nginx reload`。
`lnmp vhost add` 同样会要求选择 PHP 版本；建站时选择不开启 PHP 的站点
不会问版本，也不写任何 PHP 执行入口（见 3.2）。

**进程数调优**：编辑 `/usr/local/php/etc/php-fpm.conf` 的
`pm.max_children` / `pm.start_servers` / `pm.min_spare_servers` / `pm.max_spare_servers`，
改完先执行 `/usr/local/php/sbin/php-fpm -t`，再 `lnmp php-fpm reload`。
生成文件的基础值是 10，但主栈安装会按总内存改为 20/40/60/80；这套分档没有扣除
MySQL、Redis 和系统占用，对同机 WordPress 可能偏大。不要再用空载时的 30~50MB RSS
直接外推；应在真实插件与流量下测峰值 PSS/RSS，并按剩余内存计算。三档起始值见
`HowtoGuides.md` 6.6。

### 3.5 Redis

```bash
bash addons.sh install redis        # 安装 Redis 服务端 + phpredis 扩展
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
Redis 默认无密码，因此不要直接向公网放行。Redis 6+ 应优先用 ACL 做身份与命令范围控制；
`requirepass` 只是为 default 用户设置密码的兼容方式，而且认证本身不加密传输。确需跨机访问
时，应走私网、VPN 或 SSH 隧道，限制来源并确认链路加密。完整配置与多站点隔离边界见
`HowtoGuides.md` 第三章。

### 3.6 Memcached

```bash
bash addons.sh install memcached                # 可选 php-memcache 或 php-memcached 扩展
/etc/init.d/memcached {start|stop|restart}
echo stats | nc 127.0.0.1 11211                 # 确认在跑
/usr/local/php/bin/php -m | grep -i memcache
```

同样默认只本机可用，端口（`Memcached_Port`）在防火墙里挡掉 TCP 和 UDP。

### 3.7 SSL 证书

```bash
lnmp ssl add                                  # 为已有站点签发证书（HTTP 验证）
lnmp dnsssl {cx|ali|cf|dp|he|gd|aws}          # DNS 验证，支持泛域名
lnmp onlyssl {cx|ali|cf|dp|he|gd|aws}         # 只签证书，不改 Nginx 配置
```

`lnmp ssl add` 只处理已有虚拟主机：输入域名后先检查站点配置，不存在则提示先执行
`lnmp vhost add`，不会再次进入目录、伪静态、日志、Pathinfo 或 IPv6 等建站问答。
站点目录、附加域名和 PHP 开关状态直接从现有配置读取。

底层用 acme.sh，证书放在 `/usr/local/nginx/conf/ssl/`，会自动加续期任务。
密钥类型使用 acme.sh 默认的 **EC-256**。

**没有域名时的 IP 证书**：对默认站点执行 `lnmp ssl add` 会自动转入 IP 证书流程，
为服务器公网 IPv4 签发证书。这条路有硬性限制，脚本会先把它们列出来再问你是否继续：

- 只有 Let's Encrypt 提供 IP 证书，且必须用 shortlived profile；
- **有效期只有 7 天**，必须依赖自动续期，续期一断证书立刻过期；
- 仅支持 IPv4，且必须是公网可达的地址，私有地址签不了。

`default` 的证书来源菜单只显示 `1`（自有证书）和 `2`（Let's Encrypt），不显示
不支持 IP 证书的 BuyPass 与 ZeroSSL。

有域名就用域名，IP 证书只适合临时用。完整限制清单、NAT 环境的注意事项和
私有 IP 的替代方案见 `HowtoGuides.md` 的 7.2。

### 3.8 FTP

```bash
lnmp ftp {add|list|edit|del|show}
/etc/init.d/pureftpd {start|stop|restart}
```

`bash pureftpd.sh` 的新安装配置默认 `TLS 2`：客户端必须使用**显式 FTPS**，普通 FTP
会在登录阶段被拒绝。若连接失败，先确认客户端选择的是 FTP over TLS（Explicit），而不是
明文 FTP 或隐式 FTPS。既有安装不会因更新源码自动改写
`/usr/local/pureftpd/etc/pure-ftpd.conf`；实际值用下面命令核对：

```bash
grep '^TLS' /usr/local/pureftpd/etc/pure-ftpd.conf
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
| `denyhosts_removeip.sh` | 解封被误封的 IPv4/IPv6；非法地址会在停服务和改文件前拒绝 |


### 3.10 备份：`lnmp backup`

网站文件与数据库可自动导出、自动上传并执行试恢复。

```bash
# 扫描已有站点，挑选备份对象，生成 /etc/lnmp/backup.conf 并安装 systemd timer
lnmp backup init
# 立即执行一次；timer 会自动调用，通常不必手工执行
lnmp backup run
# 只备份指定站点的文件和数据库
lnmp backup run <域名>…
# 只备份指定站点的数据库
lnmp backup run db <域名>…
# 只备份指定站点的文件
lnmp backup run web <域名>…
# 查看上次结果、下次计划和最近错误
lnmp backup status
# 列出本地与远端的备份批次
lnmp backup list
# 将最新数据库备份导入临时库，验证后删除临时库
lnmp backup test
# 恢复指定数据库或站点文件；批次省略时使用最新一批
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

`list` 会对缺少 `SHA256SUMS` 的批次标 `[不完整：缺校验清单]` —— 该清单只在批次内
全部产物都成功后才写入，挑批次恢复时以它为准，不要只看文件个数。全部产物都失败
（例如磁盘写满）时批次目录会被删掉，不会留下 0 个文件的空批次。

`init` 之后本地备份就已经由 systemd timer 自动执行。异地上传默认关闭，
开启需要一台独立的备份服务器并在两侧各配一次 ——
备份账号、chroot、专用密钥、主机指纹核对和排查表都写在
`HowtoGuides.md` 的「8.5 异地备份（SFTP）」，照着做即可。
只有 FTP 服务器可用时改 `Remote_Protocol` 为 `ftps`（或明文 `ftp`），见 8.5.6。

备份加密同样默认关闭，支持 age 与 GPG（`Enable_Encrypt`、`Encrypt_Tool`、
`Encrypt_Recipient`、`Encrypt_Identity`）。加密在压缩之后、上传之前做，
校验清单针对加密后的文件计算，`restore` 与 `test` 会自动解密。
备份存放在第三方或不受本机权限控制的服务器时应启用加密，具体步骤见
`HowtoGuides.md` 的「8.5.7 备份加密（age 或 GPG）」。

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
- 未配置或 `TG_Enable=0` 时静默跳过并返回 0，不影响调用脚本的主流程。
- 发送失败返回非 0。通知失败通常不该中断主流程，需要时写
  `tgnotice "..." || true`。

---

## 四、组件手工升级

### 4.1 优先用升级脚本

```bash
bash upgrade.sh nginx        # 升级 Nginx
bash upgrade.sh mysql        # 升级 MySQL
bash upgrade.sh mariadb      # 升级 MariaDB
bash upgrade.sh m2m          # MySQL 迁移到 MariaDB
bash upgrade.sh php          # 升级 PHP（LNMP）
bash upgrade.sh phpa         # 升级 PHP（LNMPA / LAMP）
bash upgrade.sh phpmyadmin   # 升级 phpMyAdmin
bash upgrade.sh mphp         # 升级多版本 PHP 中的某一个
```

完整安装默认不部署 phpMyAdmin。主栈装好后如需补装，可显式执行：

```bash
bash install.sh phpmyadmin
```

安装后可随时关闭或重新开启公网入口，程序、配置和随机访问路径不会删除。
关闭时 default 站点同时撤下 PHP 处理配置，恢复为静态兜底站点：

```bash
lnmp phpmyadmin disable
lnmp phpmyadmin enable
lnmp phpmyadmin status
```

在源码目录中也可使用 `bash install.sh phpmyadmin disable|enable|status`。

脚本会识别现有 LNMP/LNMPA/LAMP 环境，校验下载文件，生成随机访问路径并在
Web 配置检查通过后重载服务。重复执行不会覆盖现有安装；升级仍使用
`bash upgrade.sh phpmyadmin`。

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

**（1）更新对应的完整性材料**

使用静态 SHA256 清单的组件必须更新 `src/checksums.sha256`，清单里缺少对应条目会
**直接中止安装**。Nginx/OpenResty 源码使用 PGP 签名，OpenResty 软件包使用仓库 GPG，
运行时版本组件可读取上游 SHA256；不得为统一形式而改用本地自行计算的哈希。
静态清单组件改完版本号后：

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

PHP 升级后特别注意：**编译进去的扩展需要重新装**（`bash addons.sh`），
`conf.d/` 下的 ini 会保留但对应的 `.so` 可能已经不匹配新版本。

---

## 五、常见问题

### 数据库的 root 默认密码是什么？

该密码为安装时输入的值。直接回车选择随机生成时，密码会写入
`/root/.lnmp_db_root_password`（权限 0600），用 `cat /root/.lnmp_db_root_password` 查看，
**记下后请删除该文件**。

密码不会打印到屏幕或安装日志，避免排障时随日志泄露。
随机密码为 `/dev/urandom` 生成的 96 位随机值。

### 忘记数据库 root 密码怎么办？

```bash
bash tools/reset_mysql_root_password.sh
```

按提示输入两遍新密码即可。脚本会停掉数据库，用**禁用网络 + 私有 socket** 的方式
临时启动并修改密码，然后正常重启；重置期间数据库不对外提供服务。

### 如何添加/删除虚拟主机？

```bash
lnmp vhost add     # 添加
lnmp vhost list    # 查看
lnmp vhost del     # 删除（只删配置，网站文件保留）
```

添加时会依次询问域名、附加域名、网站目录、伪静态规则、**是否开启 PHP**、
Pathinfo、是否记日志、IPv6、是否建库、是否申请 SSL。

不需要 PHP 的站点（纯静态、Node、Go 等）在 `是否开启 PHP? (Y/n，默认 y)`
选 `n`：站点不写任何 PHP 执行入口，`.php` 与 `.php/xxx` 一律返回 404，
`lnmp ssl add` 追加的 HTTPS 配置沿用同一状态。非交互执行用 `VHOST_PHP=n`。

### 如何修改默认虚拟主机的域名？

默认（兜底）站点的配置在 `/usr/local/nginx/conf/vhost/default.conf`
（不是 `nginx.conf` 本体——那里现在是仅本机可访问的管理端口，见下一条），
找到 `server_name _;` 改为实际域名（多个域名用空格分隔），保存后执行
`/usr/local/nginx/sbin/nginx -s reload`。一般不需要改：匹配不上其它
已建站点的请求（含直接用 IP 访问）本来就该落到这里，这也是 `lnmp vhost add`
输入 `default` 时看到的那个站点。

### `/usr/local/nginx/conf/nginx.conf` 里 `listen 127.0.0.1:1008` 那个 server 是干什么的？

本机专用的管理端口，只能从 `127.0.0.1` 访问，外部连不进来：内置一个
`/lua` 示例接口（`Enable_Nginx_Lua=n` 时装的时候会自动去掉，因为编译出来
的 nginx 没有对应模块），以及 `/nginx_status`（Nginx 连接数等运行状态）。
公网站点、phpMyAdmin 都不挂在这个端口上，改错了也不会影响对外访问。

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
| LNMP 运维配置 | `/etc/lnmp/`（备份、通知等，权限 600） |
| 数据库密码 | `/root/.lnmp_db_root_password` |
| SSL 证书 | `/usr/local/nginx/conf/ssl/` |

### 如何给 PHP 安装需要的扩展？

```bash
bash addons.sh                       # 交互菜单
bash addons.sh install redis         # 或直接指定
```

支持 redis、memcached、opcache、apcu、imagemagick、exif、fileinfo、
ldap、bz2、sodium、imap、swoole。装完自动写 ini 并重启 FPM。
装完用 `/usr/local/php/bin/php -m` 确认。

### 如何开启 IMAP 模块？

```bash
bash addons.sh install imap
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
# 每个 IP 最多 10 个并发连接
limit_conn perip 10;
# 每秒 10 个请求，允许突发 20
limit_req zone=reqip burst=20 nodelay;
# 每个连接限速 512KB/s
limit_rate 512k;
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

数据库源码编译中途失败最常见的两个原因是内存不足和磁盘不足，见“数据库：通用二进制
还是源码编译”一节的实测表。

如果失败前已经存在数据库数据目录，先看安装输出中的时间戳备份路径，不要连续重跑。
当前版本会整体移动原目录并在成功后重建空目录；备份移动失败时会立即停止，原目录不删。
确认备份内容、当前 `/etc/my.cnf` 和实际服务状态后再决定恢复还是重装。

### 想换 Web 服务器（Nginx ↔ OpenResty）怎么办？

没有平滑切换的路径。两者会抢同一套目录和端口，安装脚本检测到冲突会直接拒绝。
要换就先卸载再装，站点配置（`conf/vhost/`）和网站文件请提前自行备份。

### `systemctl status` 显示服务没跑，但网站是通的？

多半是绕过 `lnmp` 直接用 `/etc/init.d/xxx start` 启的。用 `lnmp xxx restart`
重启一次即可让 systemd 重新接管。日常运维请统一用 `lnmp`。

### 反过来：`systemctl` 显示 active，但端口没监听、进程也不在？

执行 `systemctl show nginx -p ActiveEnterTimestamp`；如果时间停在上一次
开机而不是最近一次安装，那是 systemd 里留着的陈旧状态：服务被 `lnmp stop`
或 init 脚本停掉时 systemd 并不知情，unit 会一直停在 `active (exited)`，
之后的 `systemctl start` 认为已经在跑就直接跳过。手工恢复：

```bash
systemctl stop nginx && systemctl reset-failed nginx
systemctl start nginx && systemctl is-active nginx
```

卸载流程现在会先按 systemd 停一次再取消开机启动，新装环境不会再出现这种状态。

### 备份能只备数据库不备网站吗？

可以。`/etc/lnmp/backup.conf` 里站点条目的数据库名留空就只备文件，
反过来不配网站目录就只备库；两者的备份周期和保留天数也是分开配的。
改完用 `lnmp backup run` 手工跑一次确认退出码为 0。

### 安装完成后还需要做什么？

至少这几件：

1. `cat /root/.lnmp_db_root_password` 记下数据库密码后删掉该文件；
2. 确认云服务器安全组放行了 80/443；
3. `lnmp backup init` 把备份配起来，并验证一次 `lnmp backup test`；
4. 有域名就 `lnmp vhost add` 建站并签证书，别长期用默认站点；
5. 如果 SSH 不在 22 端口，**装之前**就要在 `lnmp.conf` 里改 `SSH_Port`——
   交互式安装时脚本会自动核对，对不上会直接拒绝安装。

### 性能优化从哪里入手？

按收益排序：

1. **先测瓶颈**：看慢请求、PHP-FPM 队列、MySQL 慢查询、缓存命中率和内存峰值，
   不把系统空闲内存或单次跑分当结论。
2. **校准 PHP-FPM**：`/usr/local/php/etc/php-fpm.conf` 的 `pm.max_children` 必须按
   真实插件栈的峰值进程占用和留给数据库/系统的内存计算；脚本自动分档可能偏大。
3. **保留 OPcache**：主安装默认已经启用，无需重复安装；站点代码量很大时再依据
   `opcache_get_status()` 调整内存和脚本数。
4. **对象缓存按需使用**：Redis 对重复查询和高动态站点有效，但低流量纯展示站点未必
   值得增加一个服务；必须设置内存上限并监控淘汰率。
5. **数据库按工作集调整**：同机部署时 `innodb_buffer_pool_size` 不应照搬独立数据库
   服务器的 50~70%；`max_connections` 应接近全部 FPM worker 数加管理余量，避免每连接
   buffer 把内存放大。
6. **页面缓存/CDN 优先于堆 worker**：可缓存的匿名页面在边缘或 Nginx 层命中，收益通常
   大于继续增加 PHP 并发。启用前确认登录态、购物车和个性化页面不会被缓存。

修改前应记录当前值，每次只调整一项并观察结果。

---

## 六、相关文档

本文档说明安装后的功能与管理入口，具体操作步骤和实现记录见下列文件：

- **`HowtoGuides.md`**：完整操作手册，覆盖安装、建站、部署 WordPress、
  配 HTTPS（含无域名的 IP 证书）、OpenResty 自定义模块、异地备份，到故障排查。
  需要逐步操作命令时优先查阅。
- **`lnmp.conf`**：全部可配置项，每一项的用途、取值和影响都写在注释里。
- **`changelog.md`**：全部改动的逐条记录，含每处改动的原因、取舍和验证范围。
  用于查询行为变更的原因与验证依据。
- **`todo.md`**：已确认但尚未处理的问题。
