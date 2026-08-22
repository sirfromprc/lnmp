# LNMP 2.3

LNMP 2.3 是一套面向 Linux 服务器的 Shell 安装与运维工具，支持：

- LNMP：Nginx、MySQL/MariaDB、PHP；
- LNMPA：Nginx 前端、Apache、MySQL/MariaDB、PHP；
- LAMP：Apache、MySQL/MariaDB、PHP。

项目同时提供站点、数据库、证书、备份、FTP、权限基线和服务健康检查等管理命令。
主线验证环境是 Debian 13、Nginx、PHP 8.3、MySQL 8.4、phpMyAdmin、Redis 和
WordPress。Apache 栈及其它发行版的支持边界见 [HowtoGuides.md](HowtoGuides.md)。

![Nginx / MySQL / PHP](conf/lnmp.gif)

## 目录

1. [项目特点](#1-项目特点)
2. [安装](#2-安装)
3. [命令与使用场景](#3-命令与使用场景)
4. [重要安全边界](#4-重要安全边界)
5. [文档索引](#5-文档索引)

## 1. 项目特点

### 1.1 组件与安装方式

- 默认使用 MySQL 8.4、PHP 8.3 和 Nginx；数据库也可选择 MariaDB。
- Nginx 可替换为 OpenResty。预编译包和源码编译的选择条件见
  `HowtoGuides.md` 第 2.3 节。
- 数据库可使用官方通用二进制，也可源码编译。普通服务器优先使用通用二进制；
  源码编译需要更多时间、内存和磁盘空间。
- phpMyAdmin、phpinfo 和缓存测试页默认不部署，需要时显式开启。

### 1.2 安全与可靠性

- 组件从上游官方来源下载，并按组件使用 SHA-256、PGP 或软件仓库 GPG 校验。
- 数据库和缓存默认只监听回环地址；防火墙规则放在独立的 `inet lnmp` 表中。
- 数据库和 PHP-FPM socket 位于 `/run` 下的专用目录，不使用共享 `/tmp`。
- 数据库 root 随机密码不会写入安装日志；需要保存时使用权限为 0600 的凭据文件。
- 安装、编译、配置测试或服务启动失败时返回非零退出码。
- Nginx、PHP 和 phpMyAdmin 的升级包含切换前检查及失败回滚；数据库升级没有自动回滚，
  操作前必须验证备份可恢复。
- `lnmp database import` 和备份恢复会检查 SQL 的跨库操作边界，降低误删其它数据库的风险。

### 1.3 支持范围

Debian 13 + WordPress 是当前主线。CentOS/RHEL、非 x86_64、容器/WSL 及低频组件组合
未获得同等程度的实测覆盖，生产部署前应在同版本测试机复验。

## 2. 安装

### 2.1 安装前提

只在无现有业务的干净系统上安装。安装程序会写入 `/usr/local`、`/etc`、`/bin`、
systemd 和防火墙配置，并可能移除系统自带的 Web、PHP 或数据库软件包。

先以 root 登录并执行只读检查：

```bash
id -u
cat /etc/os-release
uname -m
free -h
df -h / /usr/local /home 2>/dev/null
df -i / /usr/local /home 2>/dev/null
timedatectl status
ss -lntup
```

`id -u` 必须输出 `0`。同时检查云平台安全组、磁盘快照、80/443/3306 等端口占用，
并阅读 `lnmp.conf` 中的数据目录、端口和可选组件设置。

### 2.2 获取发布包

从项目 Release 页面下载固定版本并按页面公布的 SHA-256 核对。假设已将下载文件保存为
`/root/lnmp-v2.3.tar.gz`：

```bash
install -d -m 700 /root/lnmp-src
tar -xzf /root/lnmp-v2.3.tar.gz -C /root/lnmp-src --strip-components=1
cd /root/lnmp-src
chmod +x install.sh addons.sh pureftpd.sh uninstall.sh upgrade.sh
bash -n install.sh addons.sh pureftpd.sh uninstall.sh upgrade.sh
```

不要使用内容会持续变化的分支压缩包替代固定 tag/release。

### 2.3 交互安装

```bash
cd /root/lnmp-src
bash install.sh lnmp
```

安装程序会询问数据库、PHP、Nginx/OpenResty、内存分配器等选项，并在系统变更前显示摘要。
编译耗时较长，确认页在 ssh 直连且未使用 screen/tmux 时会提示先建立可保持的会话。
其它栈的入口是：

```bash
bash install.sh lnmpa
bash install.sh lamp
```

安装日志追加写入 `/root/lnmp-install.log`，重跑不会覆盖上次内容。
安装中断后重跑相关的开关：

| 变量 | 作用 |
|---|---|
| `APT_LOCK_TIMEOUT` | apt 等待 dpkg 锁的秒数，默认 300 |
| `LNMP_Move_Existing_DB_Data=yes` | 允许把已存在的非空数据目录整体搬到 `/root` 后新建空实例 |
| `LNMP_Resume_Broken_Install=yes` | 上次安装未完成但 `/bin/lnmp` 已生成时，允许在现有环境上继续重装 |

后两项默认关闭，不显式声明时安装一律中止，不会移动或删除任何数据。

### 2.4 非交互安装

自动化安装必须显式设置 `LNMP_Auto=y`，并明确给出选择和密码策略：

```bash
read -r -s -p '数据库 root 密码: ' DB_Root_Password; echo
export DB_Root_Password
LNMP_Auto=y WebSelect=1 DBSelect=2 Bin=y PHPSelect=4 \
SelectMalloc=1 InstallInnodb=y bash install.sh lnmp
unset DB_Root_Password
```

主要取值：`WebSelect=1` 为 Nginx、`2` 为 OpenResty；`DBSelect=2` 为 MySQL 8.4；
`Bin=y` 使用数据库官方通用二进制；`PHPSelect=4` 为 PHP 8.3。
完整变量与 OpenResty 选项见 `HowtoGuides.md` 第 2 章。

## 3. 命令与使用场景

以下命令均以安装后生成的 `lnmp` 管理入口为准。无参数或参数错误时，命令会打印当前用法。

### 3.1 服务管理

```bash
lnmp status
lnmp start
lnmp stop
lnmp reload
lnmp restart
```

- `status`：部署后或排障时查看各服务与 phpMyAdmin 入口状态。
- `start` / `stop`：整栈启停，适合维护窗口。
- `reload`：配置测试通过后平滑重载，优先用于 Nginx 配置变更。
- `restart`：必须重建进程状态时使用，会造成短暂中断。

单独控制服务：

```bash
lnmp nginx status
lnmp php-fpm reload        # 仅 LNMP 模式
lnmp mysql restart
lnmp mariadb restart
lnmp pureftpd status
```

数据库只会安装 MySQL 或 MariaDB 其中之一，应使用与实际安装分支一致的命令。
`php-fpm` 子命令只存在于 LNMP 管理脚本；LNMPA/LAMP 由 Apache 加载 PHP，应使用
`lnmp httpd status`、`lnmp httpd reload` 等命令管理 Web/PHP 进程。
`lnmp kill` 会终止整栈残留进程，只用于正常停止失败且已确认影响范围的场景。

### 3.2 站点与应用

```bash
lnmp vhost add
lnmp vhost list
lnmp vhost del
lnmp app add
lnmp app list
lnmp app status example-app
lnmp app logs example-app
```

- `vhost` 管理 Nginx/Apache 站点；删除站点配置时不会删除网站文件。
- `app` 用独立 systemd 服务和账号托管 Node、Go 等后端进程，适合反向代理站点。

### 3.3 数据库

```bash
lnmp database add
lnmp database list
lnmp database edit
lnmp database export example_db /root/example_db.sql.gz
lnmp database import example_db /root/example_db.sql.gz
```

- `add` 创建数据库及对应账号；`edit` 修改站点数据库账号密码。
- `export` 生成单库 gzip 备份。
- `import` 将 SQL 导入已存在的目标库，会改写数据，执行前应另做备份并核对文件来源。
- `lnmp database del` 会删除数据库，仅在已验证备份后使用。

### 3.4 备份与恢复

```bash
lnmp backup init
lnmp backup status
lnmp backup run all
lnmp backup list
lnmp backup test
```

- `init` 生成 `/etc/lnmp/backup.conf` 并安装定时任务。
- `run all` 立即执行数据库和网站备份。
- `test` 将最新数据库备份导入临时库验证，不覆盖现有站点。
- `restore` 会覆盖目标数据库或网站文件，具体语法和恢复前检查见
  `HowtoGuides.md` 第 8.5 节。

### 3.5 证书与 phpMyAdmin

```bash
lnmp ssl add
lnmp dnsssl cf
lnmp onlyssl cf
lnmp phpmyadmin status
lnmp phpmyadmin enable
lnmp phpmyadmin disable
```

- `ssl add` 为已有站点签发并配置证书。
- `dnsssl` 使用 DNS API 验证并更新站点配置；服务商参数使用 acme.sh 插件名。
- `onlyssl` 只签发证书，不修改站点配置。
- phpMyAdmin 命令控制 Web 入口，不删除程序和已有配置。

### 3.6 扩展、升级与卸载

```bash
bash addons.sh
bash pureftpd.sh
bash upgrade.sh
bash install.sh mphp
```

- `addons.sh` 安装或卸载 Redis、Memcached 和 PHP 扩展。
- `pureftpd.sh` 管理 Pure-FTPd 安装。
- `upgrade.sh` 按菜单升级组件；升级前先完成备份和恢复演练。
- `install.sh mphp` 为 LNMP 模式增加一个 PHP 版本。

卸载入口为 `bash uninstall.sh`。它要求输入完整的 `uninstall-lnmp`、
`uninstall-lnmpa` 或 `uninstall-lamp`，并会移动数据库目录。执行前必须另外备份网站、
站点配置、证书和数据库；不要把卸载脚本当作重置命令。

### 3.7 监控与权限检查

```bash
lnmp health check
lnmp health status
lnmp health init
lnmp perm check
lnmp perm status
lnmp perm init
```

- `health status` 只读探测服务并显示失败计数；`health check` 会累计失败，达到阈值后可能
  重启对应服务；`health init` 安装周期探测和有限重启策略。服务已停止（unit 仍是开机
  自启）时只告警，不自动拉起。
- 装有 Nginx 的栈会自动安装 `lnmp-cutlogs.timer`，每天切割并归档 `/home/wwwlogs`
  下的日志，保留天数等可在 `/etc/lnmp/cutlogs.conf` 覆盖。
- `perm` 核对服务所需目录和文件权限；默认只报告，不自动递归修改权限。
- 有意调整某条权限后，可用 `lnmp perm ignore <条目ID>` 单独忽略，使用
  `lnmp perm unignore <条目ID>` 恢复检查。

### 3.8 FTP 与通知

```bash
lnmp ftp add
lnmp ftp list
lnmp tgnotice --status
lnmp tgnotice --test
```

FTP 账号操作依赖已安装的 Pure-FTPd。Telegram 通知需要真实 Bot Token 和 Chat ID，
初始化及凭据保存方式见 `HowtoGuides.md` 第 8 章。

## 4. 重要安全边界

1. 不要在已有业务服务器上直接运行安装、卸载或数据库升级。
2. 不要把密码写进命令行参数、脚本、Git 或工单；使用交互输入或权限为 0600 的配置文件。
3. 不要使用空变量拼接递归 `chown`、`chmod`、`rm` 或 `find`。站点权限操作必须先将路径
   规范化，并确认它位于预期的网站根目录下。
4. 不要用 `chmod -R 777` 解决网站写入问题。它会扩大被入侵后的写入范围，也可能破坏服务配置。
5. 修改 Nginx 配置后先执行 `nginx -t`，通过后再`lnmp nginx reload`。
6. 不要用 `nft flush ruleset`、停用防火墙或递归改整个 `/usr/local` 权限来排障。
7. 数据库导入、恢复、删除和升级都有数据影响；先执行独立备份并验证可恢复。
8. phpMyAdmin 的随机路径不是访问控制。公网使用时还应限制来源并使用 HTTPS。

## 5. 文档索引

- [HowtoGuides.md](HowtoGuides.md)：主要安装、部署、日常运维、备份恢复和故障排查手册。
- [changelog.md](changelog.md)：功能修改与验证摘要。
- [SecurityCheck.md](SecurityCheck.md)：安全检查范围和结果说明。
