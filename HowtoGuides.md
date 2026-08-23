<a id="top"></a>

# LNMP 2.3 从零搭建 WordPress 生产环境

> 主安装、建站、WordPress、Redis、HTTPS 和备份流程已在
> **Debian 12、Debian 13 / x86_64 / 6G 内存 / 4 核** 上实测，文中的“实测输出”来自
> 这些环境。1～2GB、3～4GB 和 5GB 以上的容量表依据当前配置生成逻辑与内存预算给出
> 保守起点，未对每个容量档进行同等真机压测。
> LNMP 环境组合：nginx 1.30.4 + PHP 8.3.33 + MySQL 8.4.7 或
> MariaDB 11.8.8（均为官方通用二进制）+ Redis 8.10.0 + phpMyAdmin 5.2.3 +
> WordPress 7.0.3；WordPress 主链路已分别在两种数据库上完成。
> LAMP 与 LNMPA 另用 Apache 2.4.68 + PHP 8.3.33 完整安装验证。
>
> 本项目所提供的功能纯终端命令操作，新手建议配合 WinSCP 修改配置参数或使用`nano`命令，避免出错。
> 阅读 [readme.md](readme.md) 文件，了解LNMP项目更多使用信息。

**⚠️ 注意： 本文包含较多终端脚本操作，主要用于提供自动化场景下的脚本示例。部分脚本中的变量可能未进行赋值，或因 SSH 连接中断等原因导致变量值丢失，从而引发不可预期的问题。**

**⚠️如果对脚本内容或其作用不熟悉不理解，避免直接拷贝黏贴脚本在终端处使用。建议优先使用 WinSCP 修改相关参数或浏览器端设置，再通过终端手动执行相关命令。文中的脚本仅供参考，请根据实际环境确认参数及执行结果后再使用。**

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

4 核 6G 的机器上，从零完整安装约 **9 分钟**（MySQL 走二进制不编译，VPS 网络、CPU限制情况不同，时间会有所差异，可达20-30分钟）。
如果选择源码编译 MySQL，再加 30-60 分钟，且有可能失败。

编译期间 ssh 掉线会使安装中断在半途，用 screen 或 tmux 保持会话：

```bash
# 安装 screen（tmux 同理：apt-get install -y tmux）
apt-get install -y screen

# 在独立会话中执行安装
screen -S lnmp
bash install.sh lnmp

# 掉线后重新登录服务器，接回原会话
screen -r lnmp
```

tmux 的等价命令为 `tmux new -s lnmp` 与 `tmux attach -t lnmp`。

`install.sh lnmp|lnmpa|lamp` 在最终确认页会检测该情况：`SSH_CONNECTION` 非空且
`STY`、`TMUX` 均为空时输出上述建议，独立入口（`nginx`、`db` 等）不作此提示。

安装真的中断在半途时怎么重跑，见 [2.1.1 安装中断或重新安装](#211-安装中断或重新安装)。


安装日志追加写入 `/root/lnmp-install.log`，每次运行前插入一行
`===== <时间> <栈名> pid=<进程号> =====` 分隔，重跑不会覆盖上次内容；
超过 10MB 时滚动为 `/root/lnmp-install.log.1`，只保留一份历史。

依赖安装期间若系统自动更新占用了 dpkg 锁，apt 会等待至多 `APT_LOCK_TIMEOUT`
（默认 300）秒而不是直接失败；仍未取得锁而失败的包会在本轮结束后重试一次。
需要更长的等待时间时在命令前指定：

```bash
APT_LOCK_TIMEOUT=900 bash install.sh lnmp
```

### 1.3 获取代码

从项目 Release 页面下载固定版本，并使用同一 Release 公布的 SHA-256 核对文件。
项目尚未在源码中固定公开仓库地址，因此本文不提供可能指向错误仓库的占位下载命令。
假设已将验证通过的压缩包保存为 `/root/lnmp-v2.3.tar.gz`：

```bash
install -d -m 700 /root/lnmp-src
tar -xzf /root/lnmp-v2.3.tar.gz -C /root/lnmp-src --strip-components=1
cd /root/lnmp-src
chmod +x install.sh addons.sh pureftpd.sh uninstall.sh upgrade.sh
bash -n install.sh addons.sh pureftpd.sh uninstall.sh upgrade.sh
id -u
# 必须输出 0
```

tar 包通常会保留可执行位，但 ZIP、面板上传或跨文件系统复制可能丢失；显式执行一次
`chmod` 可以保证后续既能用 `bash install.sh`，也能直接运行这些入口脚本。

> 优先使用 tag 或 release，而不是 `main` 分支。`main` 的内容可能在两次安装之间
> 变化，两台机器装出来的东西就不一样了。

[返回顶部](#top)

---

## 二、安装 LNMP

### 2.1 交互式安装

```bash
bash install.sh lnmp
```

先提醒检查 `lnmp.conf`（端口、目录等）并要求输入 `y` 才继续，然后自动探测
系统实际监听的 SSH 端口并按此放行；监听 22 时会提示改端口的步骤并要求再输入
一次 `y`。
之后依次会问：数据库版本 → 是否用通用二进制 → 数据库 root 密码 →
是否启用 InnoDB → PHP 版本 → Nginx/OpenResty → 内存分配器。选完会打印一份完整摘要（版本、
编译参数、即将放行/阻断的端口），要求输入 `y` 确认后才真正开始装依赖、
编译。最终确认前可用 Ctrl+C 退出并重新选择，此时尚未开始系统变更。
该确认页在 ssh 直连且未使用 screen/tmux 时会提示先建立可保持的会话，详见 [1.2](#12-编译耗时参考)。

确认之后、装依赖之前会做一次集中预检，检查磁盘空间、内存与 swap、端口占用
（80、443，LNMPA 另加 88，装数据库时加 `DB_Port`）和本次要下载的地址。
没有问题不输出结论，直接开始安装；空间不够到装不下时列出全部问题并中止；
只是有风险（空间接近下限、内存偏低、端口被占、某个地址取不到）时列出清单，
输入 `y` 继续安装，输入其它任意键退出。`LNMP_Auto=y` 或无终端时带风险继续。
`CheckMirror=n` 跳过地址探测。预检阶段结束安装时退出码是 2（安装中途失败是 1），
此时系统没有被改动，也不会留下需要清理的中间状态。

安装 LAMP/LNMPA 时还会询问 Apache `ServerAdmin`，这里只接受合法邮箱；空白、斜杠、
分号和配置片段会在写 Apache 配置前被拒绝。ACME 邮箱支持最长 63 位顶级域，三种栈规则一致。

### 2.1.1 安装中断或重新安装

安装中断后直接重跑同一条命令，不需要先卸载：

```bash
bash install.sh lnmp
```

`lnmp`、`lnmpa`、`lamp` 入口在开始前检测下列本包安装物，检测到任何一项就列出清单：

| 类别 | 检测范围 |
|---|---|
| 目录 | `/usr/local` 下的 mysql、mariadb、nginx、openresty、php、php8.x、apache、zend、phpmyadmin |
| 配置 | `/etc/my.cnf`、`/etc/lnmp` |
| 服务 | `/etc/init.d` 与 `/etc/systemd/system` 下的 mysql、mariadb、nginx、httpd、php-fpm |
| 命令 | `/bin` 与 `/usr/bin` 下的 lnmp、lnmp-backup、lnmp-perm 等 |
| 进程 | 可执行文件位于 `/usr/local` 下的 mysqld、mariadbd、nginx、php-fpm、httpd |
| 其它 | `/root/.lnmp-install-progress`、`/run/mysqld/mysqld.sock` |

确认方式取决于上次安装有没有装成功。进度标记 `/root/.lnmp-install-progress`
只在安装成功收尾时删除，检测据此区分两种情况。

上次已经装成功时，这些组件是正在用的，要求输入完整的 `yes`：

```
你已成功安装过 lnmp，如需重新安装，请先备份相关数据。
本机现有以下组件：
  - 目录：/usr/local/mariadb
  ...
重新安装会停止上述服务并删除上述目录、配置和命令。
数据库数据目录不会被删除，会先移动到 /root/databases_backup_<时间戳>；
网站目录、证书和 /root 下的备份不在清理范围内。
确认重新安装请输入 yes ，其它输入一律取消：
```

上次安装没完成时，提示中断的时间点，输入 `y` 即可：

```
检测到 2026-08-21 09:00:00 开始的安装没有完成，环境里留下了以下内容：
  - 目录：/usr/local/mariadb
  ...
是否清理这些残留并重新安装？[y/N]：
```

确认后依次执行：停止上述服务与进程（先 TERM，10 秒未退出再 KILL）、
把数据库数据目录移动到 `/root/databases_backup_<时间戳>`、
删除上述目录与配置、清理定时任务与权限钩子、清除防火墙表，最后复检一次。
复检仍有残留时列出剩余项并中止，不会带着半成品环境继续装。

进程只按可执行文件路径识别，发行版自带的同名服务不在清理范围内。
数据库数据目录任何情况下都不删除；移动失败即中止，不删除任何文件。

非交互环境（标准输入不是终端）必须显式给出答复，两种情况用同一个变量：

```bash
LNMP_Purge_Residue=yes bash install.sh lnmp   # 直接清理
LNMP_Purge_Residue=no  bash install.sh lnmp   # 保留现有环境并中止
```

不想清理、要在现有环境上直接续装时跳过整个检测：

```bash
LNMP_Resume_Broken_Install=yes bash install.sh lnmp
```

菜单选择在选完后写入 `/root/.lnmp-install-answers`（0600，不含数据库口令），
安装成功后删除。重跑时先按菜单上的文字列出上次的选择，输入 `y` 才沿用，
输入其它任意键走正常的选择流程：

```
===========================
上次的安装选择（记录于 2026-08-21_10:03:22）：
  安装栈：lnmp
  数据库：MariaDB 11.8.8 LTS（官方通用二进制）
  启用 InnoDB：y
  PHP：PHP 8.3.33
  Web 服务器：Nginx
  内存分配器：不安装
  数据库 root 口令不记录，沿用时需要重新输入。
===========================
沿用以上选择请输入 y ，输入其它任意键重新选择：
```

记录属于另一个安装栈时不参与本次安装，也不提示。命令行或环境变量已经给出的
选择优先，记录只补空缺，因此可以只覆盖其中一两项：

```bash
PHPSelect=5 bash install.sh lnmp              # PHP 换 8.4，其余沿用记录
LNMP_Reuse_Answers=yes bash install.sh lnmp   # 不询问，直接沿用
LNMP_Reuse_Answers=no  bash install.sh lnmp   # 不询问，重新选择
```

下载文件不受清理影响：`src/` 下已下载的包保留，SHA256 与 `src/checksums.sha256`
不符时删除并重新下载一次，再不符才中止。

`db` 等独立入口不做残留检测。数据目录非空时仍按原有规则处理，
显式声明后旧目录整体移动到 `/root/mysql-data-dir-backup<时间戳>`：

```bash
LNMP_Move_Existing_DB_Data=yes bash install.sh db
```

### 2.1.2 补装、升级、单独安装

整栈之外的安装动作分三个脚本：`install.sh` 的单组件子命令、`addons.sh` 的 PHP 扩展、
`upgrade.sh` 的组件升级。全部在代码目录下执行，都要 root。

| 命令 | 作用 | 前置条件 |
|---|---|---|
| `bash install.sh nginx` | 只装 Nginx，不装数据库和 PHP | 无；已装 Nginx 时为重新编译 |
| `bash install.sh db` | 只装 MySQL/MariaDB | 本机没有本包安装的数据库 |
| `bash install.sh mphp` | 追加一个并行 PHP 版本到 `/usr/local/php8.x` | 已是完整 LNMP |
| `bash install.sh phpmyadmin` | 为现有环境补装 phpMyAdmin | 主栈已装，PHP ≥ 7.2.5 且有 mysqli |
| `bash install.sh phpmyadmin {enable\|disable\|status}` | 开关或查看 phpMyAdmin 的 Web 入口 | phpMyAdmin 已装 |
| `bash addons.sh install <组件>` | PHP 扩展、Redis 服务端、ImageMagick | 对应 PHP 已装 |
| `bash pureftpd.sh` | 安装 Pure-FTPd | 无；安装前打印端口摘要并要求输入 `y` |
| `bash upgrade.sh <目标>` | 升级单个组件 | 对应组件已装 |

单组件入口不做整栈入口的残留检测（[2.1.1 安装中断或重新安装](#211-安装中断或重新安装)），也不打印整栈摘要。
`nginx` 和 `db` 会改防火墙，因此仍执行 SSH 端口检查，随后打印本入口自己的摘要并要求输入
`y` 确认，摘要里只列该入口真正读取的 `lnmp.conf` 项（`bash pureftpd.sh` 同样如此，
摘要内容见 [8.2.5 Pure-FTPd 自定义](#825-pure-ftpd-自定义)）：

```
==========================================================================
单独安装模式：只安装 Nginx，不安装数据库和 PHP。
即将安装：nginx-1.30.4
OpenSSL：openssl-3.5.7（随 Nginx 一起编译）
附加模块（lnmp.conf 开关）：Lua, Brotli, Cache Purge
默认网站目录：/home/wwwroot/default
完整性校验：y
防火墙将放行：80、443；SSH 端口：22
本入口不读取 DB_Port、MySQL_Data_Dir、Enable_PhpMyAdmin 等选项。
==========================================================================

确认以上信息，开始安装请输入 y，其它输入一律取消：
```

`mphp` 和 `phpmyadmin` 不改端口，不做这两步确认。所有入口的确认都可以用 `LNMP_Auto=y`
跳过；标准输入不是终端且没有该变量时一律以非 0 退出，不会带着默认值继续。

#### 只装 Nginx

```bash
bash install.sh nginx
LNMP_Auto=y bash install.sh nginx </dev/null      # 非交互
```

用于静态站、反向代理、负载均衡这类不需要 PHP 和数据库的机器。执行内容：

- 卸载发行版包管理器装的 Apache 系列包（Debian 系为 `apache2`、`apache2-bin`、
  `apache2-data`、`apache2-utils`、`apache2-doc`、`libapache2-mod-php`，只处理确实装了的），
  再装编译依赖。
- 编译安装 PCRE 与 Nginx，版本取自 `include/version.sh`，没有版本菜单。
- 写默认站点 `index.html` 与 `favicon.ico` 到 `Default_Website_Dir`，放行 80、443，
  安装 `/bin/lnmp` 管理命令，设为开机自启并启动。

模块开关取 `lnmp.conf`：`Enable_Nginx_Lua`、`Enable_Ngx_Brotli`、`Enable_Ngx_CachePurge`、
`Enable_Ngx_FancyIndex`、`Nginx_Modules_Options`。Nginx 模块是编译期决定的，装完只能重新
编译才能增删，自定义模块见 [8.2.7 安装本项目未提供的 Nginx 模块](#827-安装本项目未提供的-nginx-模块)。

在已装 Nginx 的机器上重复执行该入口就是重新编译并覆盖二进制：

- 能识别出现有栈（LNMP/LNMPA/LAMP）时，`/usr/local/nginx/conf/nginx.conf` 会被随包模板覆盖，
  手工改过全局配置的先备份。
- 识别不出栈（例如只装过 Nginx 的机器）且已有 `nginx.conf` 时保留原文件。
- 两种情况下 `vhost` 配置、证书和网站目录都不受影响。

该入口固定装官方 Nginx。OpenResty 没有独立安装入口，只能在整栈安装时选择
（[2.3 用 OpenResty 替代 nginx](#23-用-openresty-替代-nginx可选)），已装 OpenResty 的机器用 `bash upgrade.sh openresty` 升级。

**在只装了 Nginx 的机器上建站**：`lnmp vhost add` 的 PHP 支持和创建数据库两步都要选 `n`
（[4.4 建不带 PHP 的站点](#44-建不带-php-的站点)）。选 `y` 会写出引用 php-fpm 套接字的配置，访问返回 502。

**这类机器补不了 PHP**：本项目没有单独的 PHP 安装入口。`install.sh mphp` 要求本机已是
完整 LNMP（同时存在 `/usr/local/php/sbin/php-fpm`、`/usr/local/php/etc/php-fpm.conf`、
`/etc/init.d/php-fpm`、`/usr/local/nginx/sbin/nginx`），只装了 Nginx 时会以
「多版本 PHP 仅支持 LNMP 架构」退出。需要 PHP 就执行 `bash install.sh lnmp`，
安装前的残留检测会列出现有 Nginx，确认后清理再装整套。

#### 只装数据库

```bash
bash install.sh db
read -r -s -p '数据库 root 密码: ' DB_Root_Password; echo; export DB_Root_Password
LNMP_Auto=y DBSelect=5 Bin=y InstallInnodb=y bash install.sh db </dev/null
unset DB_Root_Password
```

交互式会依次问数据库版本、是否用官方通用二进制、root 密码（不回显，留空随机生成）、
是否启用 InnoDB，然后打印摘要等待确认。密码只在安装结束时打印到终端，不写进
`/root/install_database.log`。

边界：

- 检测到 `/usr/local/<数据库目录>` 与 `/etc/my.cnf` 同时存在即中止，不会覆盖现有实例。
  要换数据库先自行停止并备份，或走整套重装。
- 会移除包管理器装的 mysql/mariadb 相关包。
- 数据目录非空时按 2.1.1 末尾的规则处理，显式 `LNMP_Move_Existing_DB_Data=yes` 才搬走旧目录。
- 只对 `DB_Port` 与 `DB_X_Port` 写阻断公网访问的规则，防火墙写失败时整个安装返回非 0。

#### 补装 phpMyAdmin

`Enable_PhpMyAdmin` 只控制整包安装，默认 `n`。主栈装好后补装：

```bash
bash install.sh phpmyadmin
```

前置检查不通过就中止：主栈未装、`/usr/local/php/bin/php` 缺失、PHP 低于 7.2.5、
没启用 mysqli 扩展、没有 `www` 用户。已经装过或已有启用配置时拒绝覆盖，
升级走 `bash upgrade.sh phpmyadmin`。

程序装在 `/usr/local/phpmyadmin`（不在网站根目录下），访问路径随机生成，形如
`49763abb_phpmyadmin`，安装结束时打印，之后用 `lnmp status` 可以再查。
临时不用时 `lnmp phpmyadmin disable` 关闭 Web 入口，`lnmp phpmyadmin enable` 恢复，
`lnmp phpmyadmin status` 查看当前访问状态并打印含真实 IP 的完整地址；
关闭会保留程序、配置和随机路径。安全加固见 [10.1 本项目提供的主机基线](#101-本项目提供的主机基线)。

#### 追加 PHP 版本

```bash
bash install.sh mphp
```

选一个版本并行装到 `/usr/local/php8.x`，主 PHP 不动。装好后 `lnmp vhost add` 会多一步
选择本站使用哪个 PHP 版本。多版本 PHP 的配置目录、扩展安装和命令边界见
[2.5.3 安装后的配置位置](#253-安装后的配置位置)、
[8.2.6 安装本项目未提供的 PHP 扩展](#826-安装本项目未提供的-php-扩展)。

#### 扩展与升级

```bash
bash addons.sh install {memcached|opcache|redis|apcu|imagemagick|exif|fileinfo|ldap|bz2|sodium|imap|swoole}
bash addons.sh uninstall <同上>
bash upgrade.sh {nginx|openresty|mysql|mariadb|m2m|php|phpa|phpmyadmin|mphp}
```

`addons.sh` 装的都是 PHP 扩展或需要 PHP 的服务，缺少 PHP 时会直接中止。
`upgrade.sh` 的 `m2m` 是 MySQL 转 MariaDB，`phpa` 是 Apache 模式的 PHP，`mphp` 是多版本 PHP；
数据库升级没有自动回滚，`upgrade.sh php` 会清空 `/usr/local/php/conf.d/`，升级后扩展要重装。
这些入口的完整说明见 [8.1.18 不属于 lnmp 命令的入口](#8118-不属于-lnmp-命令的入口)。

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
| `LNMP_Auto` | `y` | 跳过安装前的所有交互确认（检查 lnmp.conf、SSH 端口提示、最终摘要确认） |
| `DBSelect` | `1`～`5` | 1=MySQL8.0 **2=MySQL8.4(默认)** 3=MariaDB10.11 4=MariaDB11.4 5=MariaDB11.8 |
| `Bin` | `y`/`n` | `y`=下载官方通用二进制（快，几分钟）；`n`=源码编译（慢，30-60 分钟） |
| `PHPSelect` | `1`～`6` | 1=8.0 2=8.1 3=8.2 **4=8.3(默认)** 5=8.4 6=8.5 |
| `SelectMalloc` | `1`～`3` | 1=不装 2=Jemalloc 3=TCMalloc |
| `InstallInnodb` | `y` | WordPress 必须用 InnoDB |
| `Enable_PhpMyAdmin` | `y`/`n` | **默认 `n`**（安全考虑）。要 phpMyAdmin 必须显式开启 |
| `Enable_Composer` | `y`/`n` | 默认 `y`；不需要 Composer 时设 `n`，不会下载或执行安装器 |
| `DB_Root_Password` | 字符串 | 留空则随机生成 |

> **`Enable_PhpMyAdmin` 只控制整包安装，默认仍为 `n`。** 主栈装好后的补装、开关和
> 访问路径见 [2.1.2 补装、升级、单独安装](#212-补装升级单独安装)。

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

只在 `ORMode=2`（源码编译）下有效。全部配置项在 `lnmp.conf` 的 OpenResty 段。
普通 Nginx 没有等价机制，加第三方模块的做法见
[8.2.7 安装本项目未提供的 Nginx 模块](#827-安装本项目未提供的-nginx-模块)。

```text
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
| `Enable_Ngx_Brotli` | `y` | 编译 Brotli 模块；系统缺 `libbrotli-dev` / `brotli-devel` 时跳过该模块并同时不写 `nginx.conf` 的 brotli 指令 |
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
| `PHPSelect` | `1`～`6` 对应 PHP 8.0～8.5 | 新站优先仍在上游安全支持期且插件已兼容的 8.3/8.4；不要仅因“版本最新”跳过兼容测试 |
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
| PHP | `/usr/local/php/etc/php.ini`、LNMP 模式下的 `/usr/local/php/etc/php-fpm.conf`、`/usr/local/php/conf.d/*.ini` | LNMP：`php --ini`、`php-fpm -t`，然后 `lnmp php-fpm reload`；LNMPA/LAMP：`httpd -t`，然后 `lnmp httpd reload` |
| 多版本 PHP | `/usr/local/php8.x/etc/`、`/usr/local/php8.x/conf.d/` | 用该版本二进制检查；重载对应 FPM 服务 |
| MySQL/MariaDB | `/etc/my.cnf` | `mysql -e` 回读变量；需要 restart 的参数安排维护窗口 |
| Redis | `/usr/local/redis/etc/redis.conf` | Redis 没有等价的完整 `-t`；安排维护窗口重启后用日志、`CONFIG GET` 和 `INFO` 回读 |
| Memcached | `/etc/init.d/memcached` | 重启后用 `ss` 和 `stats settings` 核对监听/内存参数 |
| Pure-FTPd | `/usr/local/pureftpd/etc/pure-ftpd.conf` | 重启后核对监听端口及被动范围 |
| phpMyAdmin | `/usr/local/phpmyadmin/config.inc.php`；Web 映射 `/usr/local/nginx/conf/phpmyadmin.enable.conf` | 优先 `lnmp phpmyadmin enable\|disable\|status`；改映射后 `nginx -t` |
| OpenResty 构建记录 | `/etc/lnmp/openresty-build.conf`，运行期 Lua 路径 `/usr/local/nginx/conf/lua_paths.conf` | 升级会沿用构建记录；改 Lua 路径后 `nginx -t` |
| 备份 | `/etc/lnmp/backup.conf`、数据库凭据 `/etc/lnmp/backup-mysql.cnf` | 权限必须 600；`lnmp backup run` 后执行 `lnmp backup test` |
| Telegram | `/etc/lnmp/notify.conf` | `lnmp tgnotice --status`、`--test`；Token 文件必须 600/400 |
| 防火墙 | Debian `/etc/nftables.d/lnmp.nft`，由 `lnmp-nftables.service` 加载，不写入 `/etc/nftables.conf`；运行期 `inet lnmp` 表 | `nft list table inet lnmp`、`systemctl status lnmp-nftables`，并从外部主机实测端口 |
| WordPress | `<站点>/wp-config.php`、`<站点>/.user.ini` | `wp config list`（有 WP-CLI 时）和真实 HTTP 请求 |
| 日志 | `/home/wwwlogs/`、`/usr/local/php/var/log/`、数据库数据目录中的错误日志、`/var/log/lnmp/backup.log` | 结合 systemd journal；不要只看单一日志 |

备份配置支持的全部字段是 `Backup_Home`、`MySQL_Dump`、`MySQL_Option_File`、
`Backup_Site`、`Keep_Days_Db`、`Keep_Days_Web`、`Web_Interval_Days`、
`Enable_Remote_Backup`、`Remote_Protocol`、`Remote_Host`、`Remote_Port`、
`Remote_User`、`Remote_Dir`、`Remote_Password`、`Remote_Ftp_Verify`、
`Remote_Ftp_CA`、`Remote_SSH_Key`、`Remote_Known_Hosts`、`Enable_Encrypt`、
`Encrypt_Tool`、`Encrypt_Recipient`、`Encrypt_Identity`。具体取值与验证见 8.5、8.6。

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
| Pure-FTPd 服务 | `bash pureftpd.sh` | 端口来自 `lnmp.conf`，安装前会列出并要求确认；不需要传统 FTP 时不要增加该公网服务 |
| 组件升级 | `bash upgrade.sh {nginx\|openresty\|mysql\|mariadb\|m2m\|php\|phpa\|phpmyadmin\|mphp}` | 先备份和测试；数据库升级没有自动回滚 |
| 管理功能 | `lnmp vhost/database/ftp/ssl/dnsssl/onlyssl/backup/tgnotice/phpmyadmin` | 优先走命令生成配置，保留校验、权限与回滚逻辑 |

`addons.sh` 菜单虽然仍列出 ionCube，但当前版本没有接入可用安装流程；不要把菜单名当成
功能已经实现。Apache/LNMPA/LAMP 保留代码路径，但没有 Debian 13 主线同等级的真机覆盖。

`addons.sh install redis` 与 `addons.sh install memcached` 在按键确认前先列出端口、
监听地址、防火墙动作和自测页开关，端口取自 `lnmp.conf`，要改就先取消再重跑。

`addons.sh`、`upgrade.sh` 的“按任意键开始”、`pureftpd.sh` 与 `install.sh` 各入口的
确认（整栈与单组件摘要都是输入 `y`）只在真实终端生效。标准输入被重定向时必须显式
`LNMP_Auto=y`，否则脚本在下载和编译之前就以非 0 退出：

```bash
LNMP_Auto=y bash addons.sh install redis </dev/null
```

卸载不接受这种方式，须使用 `LNMP_Uninstall_Confirm=uninstall-<栈名>`。

[返回顶部](#top)

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
systemctl status redis --no-pager
# Active: active (running)   MainPID 就是实际的 redis-server 进程

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

单站点希望给回环连接再加一道认证时，可以使用兼容性较好的 `requirepass`。可以手工修改 `/usr/local/redis/etc/redis.conf` 里的 `requirepass` 后重启；也可以用下面的脚本。

把密码
保存到 root-only 文件，不打印到终端，也不通过 `redis-cli -a` 暴露在进程参数中：

```bash
# 1. 先备份原配置，改坏了可原样还回去
REDIS_CONF=/usr/local/redis/etc/redis.conf
REDIS_BACKUP="${REDIS_CONF}.$(date +%Y%m%d%H%M%S).bak"
cp -a "${REDIS_CONF}" "${REDIS_BACKUP}"

# 2. 生成并保存密码（配置文件是 root:redis 640，密码文件是 root 600）
umask 077
REDISPW=$(openssl rand -base64 24)
printf '%s\n' "${REDISPW}" > /root/.lnmp_redis_password
sed -i '/^[[:space:]]*#\?[[:space:]]*requirepass[[:space:]]/d' "${REDIS_CONF}"
printf 'requirepass %s\n' "${REDISPW}" >> "${REDIS_CONF}"
unset REDISPW

# 3. 重启使配置生效（无 systemd 的环境用 /etc/init.d/redis restart）
systemctl restart redis

# 4. 验证：不带密码应该被拒绝，带密码才能执行命令
redis-cli ping
# (error) NOAUTH Authentication required.
REDISCLI_AUTH="$(cat /root/.lnmp_redis_password)" redis-cli ping
# PONG
```

确认应用连接正常后再删除 `REDIS_BACKUP` 指向的旧配置；该备份可能含旧密码，权限应保持原配置值。

设了密码之后，WordPress 那边的 redis-cache 插件也要同步改，
在 [5.3 生成 wp-config.php](#53-脚本生成-wp-configphp) 的 Redis 常量块里加一行：

```php
define( 'WP_REDIS_PASSWORD', '读取 /root/.lnmp_redis_password 后填入的密码' );
```

不改这一行的话，插件仍按无密码连接，会直接报连接失败。写入后保持 `wp-config.php`
的 root 所有和 640 权限，不要让密码文件进入备份之外的日志、Git 或聊天记录。

[返回顶部](#top)

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

上表是 LNMP（Nginx）的问答顺序。**LNMPA 与 LAMP 不问伪静态规则**，改问管理员邮箱：
这两套栈的伪静态由 Apache 的 `.htaccess` 处理（站点配置为 `AllowOverride All`，
`mod_rewrite` 已加载），详见 5.5。

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

**第 8 步只控制访问日志。** 错误日志一律写入，Nginx 站点是
`error_log /home/wwwlogs/<域名>.error.log;`，Apache 站点是
`ErrorLog "/home/wwwlogs/<日志名>-error_log"`：

```bash
tail -f /home/wwwlogs/wp.example.com.error.log
```

**自己加的配置写在自定义区块里。** 站点配置末尾留有两行注释，指令写在中间：

```nginx
        # 自定义配置--开始
        client_max_body_size 64m;
        # 自定义配置--结束
```

改完执行 `/usr/local/nginx/sbin/nginx -t` 和 `/usr/local/nginx/sbin/nginx -s reload`；
Apache 用 `/etc/init.d/httpd configtest` 和 `/etc/init.d/httpd graceful`。
`conf/nginx.conf`、`conf/nginx_a.conf`、`conf/openresty.conf`、`conf/httpd24-*.conf`、
`conf/httpd-vhosts-*.conf` 中也有同样的区块，位置分别在 `http {}` 内和
默认 VirtualHost 内。

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

> 注意：**输入项数量必须精确**。任何一项（含最后的“任意键”那一行）缺失时都会报告
> `读取<项目>时遇到 EOF —— 标准输入已经没有内容了。` 并以非 0 退出，不会按默认值
> 继续创建站点。y/n 类问题只接受 `y`、`yes`、`n`、`no`（不分大小写）和空值（取默认），
> 其它输入会在原问题处重问，不会带着非法值走到创建阶段。
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
`location /`，留着会先被它拦成 404）。删掉后 `lnmp ssl add` 追加的 443
配置不会把它写回。

反代规则写在 `# 自定义配置--开始` 与 `# 自定义配置--结束` 之间，
`lnmp ssl add` 会把该区块原样复制到 443 配置里，HTTPS 不需要再写一遍。
选 HTTP 301 跳转时，若该区块已有 `location /`，跳转改用 server 级实现并放行
`/.well-known/`（同一 server 内出现两个 `location /` 会让 `nginx -t` 报
`duplicate location`）。

**站点建好后想改主意**：直接编辑 `/usr/local/nginx/conf/vhost/<域名>.conf`
（LAMP 是 `/usr/local/apache/conf/vhost/<域名>.conf`），加回或删掉上述几行，
`nginx -t` / `httpd -t` 通过后 reload 即可，不必删站重建。

### 4.5 托管 Node / Go 应用进程

反向代理只解决"请求怎么转给后端"，进程本身退出或机器重启后仍然是 502。
用 `lnmp app` 把应用交给 systemd 托管：

```bash
lnmp app add
```

依次问四项：

| 问题 | 说明 |
|---|---|
| 应用名 | 小写字母、数字、中划线，最长 23 字符；用作 unit 实例名与账号名 |
| 应用目录 | 必须位于 `/home`、`/var/www`、`/srv`、`/data`、`/www` 之一的**子目录**且已存在；进程的工作目录 |
| 启动命令 | 可执行文件写绝对路径，如 `/usr/bin/node server.js` |
| 监听端口 | 用于占用检查，留空则跳过 |

完成后应用以专属账号 `lnmp-app-<应用名>` 运行，已设为开机启动，
崩溃后由 `Restart=on-failure` 自动拉起（300 秒窗口内最多 5 次，超出标记 failed）。

```bash
lnmp app list                  # 应用名、运行状态、端口、目录
lnmp app status myapp          # systemctl status
lnmp app restart myapp
lnmp app logs myapp            # 最近 100 行 journald 日志
lnmp app del myapp             # 取消托管；询问是否删除专属账号，应用目录保留
```

非 root 账号运行是刻意的：不复用 `www`，否则应用进程能读写全部站点目录
和 `.user.ini`。`lnmp app add` 会把应用目录的属主改成该账号。

正因为要递归改属主，应用目录的边界与站点目录同一套：只放行上表那五个根下的
子目录，拒绝根目录本身、`..`、shell 元字符、路径组件中的符号链接，
以及已被其它托管应用占用的目录。想把应用放在 `/opt` 或系统目录下不被支持——
换成 `/srv/<应用名>` 这类专用目录即可。

完整的一条链是：`lnmp app add` 托管进程 → `lnmp vhost add` 建站（PHP 选 `n`）
→ 在站点的自定义配置区块写 `proxy_pass http://127.0.0.1:<端口>;`
→ `lnmp ssl add` 加证书（反代规则会自动继承到 443）。
参考配置见 `/usr/local/nginx/conf/example/nginx-reverse-proxy-example.conf`。

元数据在 `/etc/lnmp/apps/<应用名>.env`（0640），模板单元是
`/etc/systemd/system/lnmp-app@.service`。`lnmp health` 会一并检查这些实例的存活。

[返回顶部](#top)

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

将解压好的Wordpress源码放入`/home/wwwroot/wp.example.com` 里。浏览器端输入 `https://wp.example.com` 进行相关设置。也可以用脚本命令生成，详见下方。

默认按 WordPress 常规权限铺文件，网页安装向导、插件与主题安装、后台自动更新
都可用：

```bash
SITE=/home/wwwroot/wp.example.com
SITE=$(readlink -f -- "$SITE")
case "$SITE" in
    /home/wwwroot/*) ;;
    *) echo "拒绝操作预期目录以外的路径：$SITE" >&2; exit 1 ;;
esac
[ -d "$SITE" ] || { echo "站点目录不存在：$SITE" >&2; exit 1; }

tar zxf wordpress.tar.gz
cp -a wordpress/. "$SITE/"

find "$SITE" -xdev -type d -exec chown www:www {} + -exec chmod 755 {} +
find "$SITE" -xdev -type f ! -name .user.ini -exec chown www:www {} + -exec chmod 644 {} +
```

上面的 `case` 是必须保留的路径边界：空值、`/`、`/home/wwwroot` 本身及其它系统目录
都会被拒绝。`find -xdev` 不跨入站点内另行挂载的文件系统，也不跟随符号链接；
`.user.ini` 由项目设置为 immutable，示例不尝试改动它。

`wp-config.php` 含明文数据库密码，单独收紧到 600，见 5.3。

需要禁止 PHP 改写代码目录的更强隔离，等安装完成、功能验证通过后再做，
见 5.6。**不要在建站前就收紧**：那样网页安装向导无法写 `wp-config.php`，
插件安装和自动更新也会失败，问题会与配置错误、伪静态失效混在一起，难以定位。

> **为什么示例里要用 `! -name .user.ini` 排除它：**
> `.user.ini`（存放 `open_basedir` 限制）被刻意加了 immutable 属性
> （`chattr +i`），防止站点被入侵后篡改目录限制。带上这个排除条件，
> `find` 就不会对它执行 `chown` 与 `chmod`；去掉排除条件则会看到
> `Operation not permitted`，其余文件仍会正常处理。
> 真要改它：`chattr -i .user.ini` → 改 → `chattr +i .user.ini`。

### 5.3 脚本生成 wp-config.php

浏览器端安装的此步无需操作。

权限未收紧可在浏览器端配置，或使用以下脚本：

```bash
cd "$SITE"
[ ! -e wp-config.php ] || { echo "wp-config.php 已存在，拒绝覆盖" >&2; exit 1; }
SALT=$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/) || exit 1
[ -n "$SALT" ] || { echo "无法取得 WordPress salts" >&2; exit 1; }
read -r -s -p "数据库用户 wpdemo 的密码: " DB_PASSWORD; echo
[ -n "$DB_PASSWORD" ] || { echo "数据库密码不能为空" >&2; exit 1; }
DB_PASSWORD_PHP=$(printf '%s' "$DB_PASSWORD" | /usr/local/php/bin/php -r '$v=stream_get_contents(STDIN); echo var_export($v, true);') || exit 1
OLD_UMASK=$(umask)
umask 077

cat > wp-config.php <<PHPEOF
<?php
define( 'DB_NAME', 'wpdemo' );
define( 'DB_USER', 'wpdemo' );
define( 'DB_PASSWORD', ${DB_PASSWORD_PHP} );
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
[ -s wp-config.php ] || { echo "生成 wp-config.php 失败" >&2; exit 1; }

# 文件含明文数据库密码，只给属主读写；采用 5.6 的加固时改为
# chown root:www wp-config.php && chmod 640 wp-config.php
chown www:www wp-config.php && chmod 600 wp-config.php || exit 1
/usr/local/php/bin/php -l wp-config.php || exit 1
unset DB_PASSWORD DB_PASSWORD_PHP SALT
umask "$OLD_UMASK"
unset OLD_UMASK
```

几个要点：

- **`DB_HOST` 用 `127.0.0.1` 而不是 `localhost`**：后者会走 unix socket，
  而 PHP 的 `mysqli.default_socket` 未必指向 `/run/mysqld/mysqld.sock`。
  用 TCP 最省事；建站时创建的库用户对 `localhost` 和 `127.0.0.1` 都授了权。
- **`WP_REDIS_PREFIX` 一定要设**：多站点共用一个 Redis 实例时，
  未设置前缀时会发生键名冲突。
- **`DISALLOW_FILE_EDIT`**：关掉后台的插件/主题在线编辑器。
  这是被入侵后最常见的提权跳板。
- **`wp-config.php` 权限 600**：它含明文数据库密码，不能是 644。
  采用 5.6 的加固（属主 root）时用 640，让 `www` 组可读。

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
  "https://wp.example.com/wp-admin/install.php?step=2" | grep -o "<h1>[^<]*</h1>"
# <h1>Success!</h1>
```

> `blog_public=0` 表示不希望搜索引擎索引。正式站点改成 `1`。

安装完成后立即修改密码，使安装阶段使用的凭据失效：

```bash
# 后台「用户 → 个人资料」修改，然后清除当前变量
unset WP_ADMIN_PW
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

> **LNMPA 与 LAMP 的伪静态走 Apache。** 这两套栈的站点没有
> `include rewrite/...`，规则来自网站目录下的 `.htaccess`，由 WordPress 在后台
> 保存固定链接时自己写入（站点目录属 `www:www`，Apache 也以 `www` 运行，可写）。
> 直接改数据库里的 `permalink_structure` 不会生成 `.htaccess`，文章页和
> `/wp-json/` 仍会 404，须在后台「设置 → 固定链接」保存一次。
>
> **不要把 `include rewrite/wordpress.conf;` 加进 LNMPA 的 Nginx 站点配置。**
> LNMPA 的 `proxy-pass-php.conf` 已经定义了 `location /`，再引入该规则会让
> `nginx -t` 报 `duplicate location "/"`，reload 失败。

### 5.6 可选加固：禁止 PHP 改写代码目录

**执行前提**：安装向导已完成、HTTPS 可访问、伪静态验证通过（5.4、5.5），
需要的插件与主题已装好并确认可用。收紧权限会关闭后台的安装与更新能力，
在功能尚未验证的站点上执行，会把权限问题和配置问题混在一起。

PHP 能改写自身代码文件，是站点被入侵后落 webshell、篡改核心文件的前提。
接受用命令行完成后续全部更新时，把代码目录改为 PHP 只读：

```bash
SITE=/home/wwwroot/wp.example.com
SITE=$(readlink -f -- "$SITE")
case "$SITE" in
    /home/wwwroot/*) ;;
    *) echo "拒绝操作预期目录以外的路径：$SITE" >&2; exit 1 ;;
esac
[ -d "$SITE" ] || { echo "站点目录不存在：$SITE" >&2; exit 1; }

find "$SITE" -xdev -type d -exec chown root:www {} + -exec chmod 750 {} +
find "$SITE" -xdev -type f ! -name .user.ini -exec chown root:www {} + -exec chmod 640 {} +
chown root:www "$SITE/wp-config.php" && chmod 640 "$SITE/wp-config.php"

# 只有这几个目录需要 PHP 写：上传、缓存、升级临时目录
for writable_dir in uploads cache upgrade; do
    target="$SITE/wp-content/$writable_dir"
    mkdir -p -- "$target" || exit 1
    find "$target" -xdev -type d -exec chown www:www {} + -exec chmod 750 {} +
    find "$target" -xdev -type f -exec chown www:www {} + -exec chmod 640 {} +
done
```

执行后逐项确认站点仍然可用：

```bash
curl -o /dev/null -w "首页: %{http_code}\n"   https://wp.example.com/
curl -o /dev/null -w "文章页: %{http_code}\n" https://wp.example.com/hello-world/
```

再在后台确认媒体上传成功。上传失败通常是 uploads 属主没改回 `www:www`。

代价：后台的插件/主题在线安装与自动升级失效，更新须走 `wp-cli` 或手工替换
文件。装新插件时先临时把目标目录属主改回 `www:www`，装完再改回 `root:www`。
折中做法是长期只对 `wp-content/plugins`、`wp-content/themes` 保留 `www` 写权限，
等于重新打开 PHP 可写自身代码这条路；`wp-config.php` 与核心目录
（`wp-admin`、`wp-includes`）不给。

加固只改站点目录，不影响 `lnmp perm check` 的判定：用户自建站点目录不在权限
基线内（属主本就有默认与加固两种合理形态），核对不会因此报告偏差。

**回退**：加固后出现无法定位的功能异常，先恢复默认权限排除权限因素：

```bash
find "$SITE" -xdev -type d -exec chown www:www {} + -exec chmod 755 {} +
find "$SITE" -xdev -type f ! -name .user.ini -exec chown www:www {} + -exec chmod 644 {} +
chown www:www "$SITE/wp-config.php" && chmod 600 "$SITE/wp-config.php"
```

[返回顶部](#top)

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

[ ! -e redis-cache ] || { echo "redis-cache 目录已存在，请先核对现有插件" >&2; exit 1; }
unzip -q redis-cache.zip && rm -f redis-cache.zip
find redis-cache -xdev -type d -exec chown www:www {} +
find redis-cache -xdev -type f -exec chown www:www {} +

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
| `max_input_vars` | 1000 | 菜单/复杂表单确认发生截断后再升到 2000～3000 |
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

以上 PHP-FPM 命令只适用于 LNMP。LNMPA/LAMP 把 PHP 加载到 Apache 进程中，应改为
`/usr/local/apache/bin/httpd -t && lnmp httpd reload`。

`disable_functions` 是降低插件误用风险的补充措施，不是安全边界。WordPress 核心不需要
`exec`/`system`/`shell_exec`，保持项目默认；某个插件确实需要时，先确认它调用的准确
函数和输入边界，尽量只解除单项，而不是直接运行脚本清空整份限制。

### 6.3 PHP-FPM 进程模型

配置文件`/usr/local/php/etc/php-fpm.conf`，本项目安装时会自动配置，可自行修改。

项目先生成 `pm=dynamic`、`pm.max_children=10`，随后按机器总内存自动改为：

| 总内存 | 项目生成的 `max_children` | 同时生成的 `start/min/max_spare` |
|---:|---:|---:|
| `<=1GB` | 10 | 2 / 1 / 6 |
| `>1GB, <=2GB` | 20 | 10 / 10 / 20 |
| `>2GB, <=4GB` | 40 | 20 / 20 / 40 |
| `>4GB, <=8GB` | 60 | 30 / 30 / 60 |
| `>8GB` | 80 | 40 / 40 / 80 |

这是**本项目程序自动行为，但不是本指南的推荐值**。它只看总内存，没有扣除数据库、Redis、
OPcache、内核页缓存和备份任务；特别是 `start_servers=30/40` 会在低流量 VPS 常驻很多
空闲 worker。混部 WordPress 应按 6.6 的起点下调。

容量公式使用真实高峰数据：

```text
max_children = floor(PHP 可用内存 / 单 worker 的高峰 PSS)
```

RSS 会把共享库/OPcache 重复计入每个进程，条件允许时安装 `smem` 看 PSS；没有 `smem`
可先用 RSS 做保守上界。必须在插件、主题、缓存预热和代表性请求都到位后采样，空白首页
的 20～30MB 没有规划意义：

```bash
ps --no-headers -o pid,rss,etime,cmd -C php-fpm --sort=-rss | head -20
grep -E '^(MemAvailable|SwapFree):' /proc/meminfo
journalctl -k --since today | grep -Ei 'oom|out of memory|killed process'
```

低流量 1～4GB VPS 可用 `pm=ondemand` 降低常驻内存，并保留
`pm.process_idle_timeout=10s`；稳定高流量用 `dynamic` 减少冷启动。两种模式都保留
`pm.max_requests=500~1000` 控制长期碎片。调整后观察 502、FPM 日志中的
`server reached pm.max_children` 和系统 Swap/OOM，而不是看到 CPU 空闲就继续加 worker。

### 6.4 MySQL 8.4 / MariaDB

MySQL 与 MariaDB 安装都调用项目的 `MySQL_Opt`：按总内存把
`innodb_buffer_pool_size` 设为 128M（1～2GB）、256M（2～4GB）、512M（4～8GB），
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

这里的 512M/50 对应 3～4GB 单站混部示例。MariaDB 保留自己的 redo/binlog 参数；
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

### 6.6 1～2GB、3～4GB、5GB 以上的起始方案

下表假设 **Nginx + PHP 8.3 + MySQL 8.4 或 MariaDB LTS + Redis 与 WordPress 同机**、
1 个普通站点，Redis 只做对象缓存，PHP worker 高峰按约 80～120MB 估算。两种数据库先用
相同 buffer pool 和连接预算；MariaDB 另按 6.4 关闭 query cache 后再测。它是避免 OOM 的
上线起点，不是跑分结论；WooCommerce、页面构建器、导入任务和多站点必须重新测。

| 物理内存 | MySQL/MariaDB `innodb_buffer_pool_size` | MySQL/MariaDB `max_connections` | Redis `maxmemory` | PHP-FPM 建议起点 | 系统与突发余量 |
|---:|---:|---:|---:|---|---:|
| 1GB | 128M | 20 | 32～64M | `ondemand`，`max_children=4` | 至少 350M + 1～2GB Swap |
| 2GB | 256M | 30 | 64～128M | `ondemand`，`max_children=8` | 至少 500M + 1～2GB Swap |
| 3～4GB | 512M | 40～50 | 128～256M | `ondemand` 或 `dynamic`，`max_children=12~20` | 700M～1G |
| 5～8GB | 1G～1.5G | 60～80 | 256～512M | `dynamic`，`max_children=24~40` | 1G～1.5G |
| 8GB 以上 | 先给整机 20～30%，再按工作集调 | FPM 总 worker + 20 | 先给 5～10%，按命中/淘汰调 | 用实测高峰 PSS 计算，不固定照抄 80 | 至少 15～20% |

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
   时改到 10。对 1～2GB VPS 保留 Swap，但持续换页代表应用内存分配错误。
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

[返回顶部](#top)

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

证书来源：`1`=用自己的证书 `2`=Let's Encrypt `3`=ZeroSSL。
选 2-3 时会问一个邮箱，可以直接回车留空——ACME 规范里账户邮箱是可选的，
Let's Encrypt 无邮箱也能签发。填写时**不能用 `example.com` 这类保留域名**，
Let's Encrypt 会直接拒绝并报 `invalidContact`。选 ZeroSSL 时会再单独确认一次
账户邮箱：ZeroSSL 必须用邮箱换取 EAB 凭据，不能留空，acme.sh 按 CA 单独保存，
可以和 Let's Encrypt 用不同邮箱，已保存过则回车沿用。

选 ZeroSSL 还会先探测一次 `https://acme.zerossl.com/v2/DV90/newNonce`，
超时或返回非 200/204 时给出状态码并询问是否改用 Let's Encrypt。该端点故障时
acme.sh 只会反复打印 `Could not get nonce`，重试约 5 分钟后才失败。

域名证书有效期 90 天，acme.sh 的 cron 会自动续期：

```
30 2,8,14,20 * * * "/usr/local/acme.sh"/acme.sh --cron --home "/usr/local/acme.sh"
```

> 注意：**有效期正在缩短。Let's Encrypt 已宣布，到 2028 年公信 TLS 证书
> 有效期将从 90 天减半至 45 天。**
>
> **对本包的影响：经核实，不需要做任何改动。** 依据（基于本包内置的
> acme.sh 3.1.4 源码）：
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
| **只能用 Let's Encrypt** | ZeroSSL 不提供 IP 证书，因此 `default` 菜单不显示该项 |
| **必须是公网 IP** | 私有地址（10.x / 172.16-31.x / 192.168.x / 127.x / 169.254.x）以及运营商级 NAT 的 100.64-127.x，**任何公信 CA 都不会签发** |
| **80 端口要公网可达** | HTTP-01 验证 |

用户入口是 `lnmp ssl add`，站点选择 `default` 后由脚本校验公网 IPv4，并在内部调用
acme.sh 的 `shortlived` profile。不要绕过入口直接拼接 IP：入口还负责私有地址拒绝、
证书目录备份、安装和失败回滚。

> 注意：**NAT 环境要特别注意**：脚本探测到的公网 IP 可能是**出口地址**，
> 未必指向本机。只有把该 IP 的 80 端口转发到本机，HTTP-01 验证才能通过。
> 该 IP 没有绑定在本机任何接口上时，脚本会停下来要求确认（默认取消），
> 确认后才继续申请；失败的验证会计入 Let's Encrypt 的速率限制。
> 申请前先自查：从外网访问 `http://<该IP>/` 能否打开本站。

**如果是私有 IP**，脚本会明确告知无法申请并给出三条出路，
其中自签名证书的完整命令会直接打印出来（加密有效，但浏览器会告警，
仅适合内网自用）。

> **能用域名就用域名。** 90 天有效期比 7 天省心得多，
> IP 证书有效期较短，续期异常的处置时间只有数天。
>
> 注意这个差距未来会缩小但不会消失：**Let's Encrypt 已宣布到 2028 年
> 公信 TLS 证书有效期将从 90 天减半至 45 天**（见 7.1 节）。
> 即便如此，45 天相对 7 天仍有数量级上的容错优势。

### 7.3 三条签发命令怎么选

```bash
lnmp ssl add                          # HTTP 验证，为已有站点签发
lnmp dnsssl cf                        # Cloudflare DNS 验证，为已有站点签发
lnmp onlyssl cf                       # Cloudflare DNS 验证，只签证书，不动站点配置
```

其它内置服务商参数为 `ali`、`dp`、`he`、`gd`、`aws`；也可以使用已安装的
acme.sh DNS 插件名。

| | `lnmp ssl add` | `lnmp dnsssl` | `lnmp onlyssl` |
|---|---|---|---|
| 验证方式 | HTTP-01 | DNS-01 | DNS-01 |
| 要求站点已存在 | 是 | 是 | 否 |
| 修改 Nginx 配置 | 是，追加 443 server | 是，追加 443 server | 否 |
| 支持泛域名 | 否 | 是 | 是 |
| 要求 80 端口公网可达 | 是 | 否 | 否 |
| 要求 DNS API 凭据 | 否 | 是（手工 TXT 模式除外） | 是（手工 TXT 模式除外） |
| 可选 CA | Let's Encrypt / ZeroSSL | Let's Encrypt / ZeroSSL | Let's Encrypt / ZeroSSL |
| 自动续期 | 是 | 是（手工 TXT 模式不可自动续期） | 是（同左） |
| 签发与续期后重载 Nginx | 是 | 是 | 否 |
| 证书目录 | `/usr/local/nginx/conf/ssl/<域名>/` | 同左 | 同左 |

**共同点**：都用 acme.sh，都默认 EC-256 密钥，签发后都会把证书安装到
`/usr/local/nginx/conf/ssl/<域名>/`（`fullchain.cer` 与 `<域名>.key`），
续期任务由 acme.sh 的 cron 统一处理。

**HTTP 验证 (`lnmp ssl add`)**

CA 访问 `http://<域名>/.well-known/acme-challenge/...` 来验证控制权，因此域名必须
已解析到本机且 80 端口从公网可达。不需要任何 API 凭据，是最省事的一条路。
不能签泛域名——ACME 规定泛域名只接受 DNS-01，输入 `*.example.com` 会被直接拒绝
并提示改用 `lnmp dnsssl`。

站点按站点名或配置里的 `server_name` 定位：输入 `www.example.com`，会命中
`server_name` 含该域名的站点 `example.com`。**不做 `dnsssl` 那样的根域回退**——
HTTP 验证要求该域名由现有网站直接服务，输入站点没有声明的子域会被要求改正。

交互顺序：域名 → 证书来源(1-4) → 是否 301 跳转。

**DNS 验证 + 写站点配置 (`lnmp dnsssl <服务商>`)**

CA 校验 `_acme-challenge.<域名>` 的 TXT 记录，本命令通过服务商 API 自动加删该记录。
80 端口不通、站点还没上线、需要泛域名证书时用这条。

**普通域名**按根域名定位站点：输入 `test.example.com` 会匹配到同根域的现有网站
`example.com`。若同根域下有多个站点，会列出来要求输入准确域名；若一个都没有，会提示
先 `lnmp vhost add` 建站，或者改用 `lnmp onlyssl`。

**泛域名**不定位单个站点，按覆盖关系处理所有被覆盖的站点。`*.example.com` 只覆盖
**恰好一级**的子域名：

| 站点 | `*.example.com` 是否覆盖 |
|---|---|
| `www.example.com`、`a.example.com` | 是 |
| `example.com`（根域名） | 否，需单独签入 |
| `b.a.example.com`（二级子域） | 否 |
| `a.example.com.us`（其它根域） | 否 |

判定不依赖公共后缀表，`*.example.com.uk`、`*.example.gov.uk` 同样只覆盖一级子域。
泛域名不能建站，`lnmp vhost add` 会拒绝 `*.example.com` 这样的域名。

交互顺序：域名 → 被覆盖站点确认 → 上级域名是否签入 → 更多域名 → CA 选择 →
是否 301 跳转 → API 凭据。签发成功后逐个站点写 HTTPS 配置，已有 443 配置的站点跳过。

```
# lnmp dnsssl nsone
DNS 验证，请输入域名（示例：www.example.com）: *.example.com
泛域名 *.example.com 覆盖的网站：a.example.com www.example.com had.example.com
本次写入 HTTPS 配置的网站：a.example.com www.example.com
已有 HTTPS 配置、本次跳过的网站：had.example.com
检测到网站 example.com，泛域名不覆盖它本身，是否一并签入本证书 [y/N]（默认 n）: n
example.com 不参与本次证书。
证书域名：*.example.com
1: 使用 Let's Encrypt 签发 SSL 证书（DNS 验证）
2: 使用 ZeroSSL 签发 SSL 证书（DNS 验证）
请选择 [1-2]：1
是否将 HTTP 301 跳转到 HTTPS [y/N]（默认 n）: n
请输入 nsone 的 API 凭据，acme.sh 会保存供续期复用。
NS1_Key（API Key）: <粘贴 API Key>
正在使用 letsencrypt 签发 SSL 证书...
网站 a.example.com 的 HTTPS 配置已写入。
网站 had.example.com 已有 HTTPS 配置，跳过。
网站 www.example.com 的 HTTPS 配置已写入。
已配置 2 个网站，跳过 1 个。
```

上级域名（去掉 `*.` 后的域名，`*.example.com` 对应 `example.com`）不在泛域名覆盖
范围内，存在同名站点时单独确认；选 `y` 时证书域名为 `*.example.com example.com`，
该站点也一并写配置。域名输入不区分大小写，`*.EXAMPLE.com` 与 `*.example.com` 等价。
CA 不接受泛域名与被它覆盖的子域名同时出现在一张证书里，这类冗余会在提交前自动去掉。

**已有泛域名证书时**：再执行 `lnmp dnsssl <服务商>` 输入同一个泛域名，会先报出这张
证书的签发时间与到期时间，并给出三条路——把现有证书写进尚未配置 HTTPS 的网站（不重新
签发）、换具体子域名单独申请、重新签发覆盖。新建子域名站点后要让它用上已有的泛域名
证书，走第一条即可。

```
DNS 验证，请输入域名（示例：www.example.com）: *.example.com
已存在证书 *.example.com（签发于 2026-08-22T09:00:00Z，Oct 21 12:26:28 2026 GMT 到期）。
1: 把该证书写入尚未配置 HTTPS 的网站，不重新签发
2: 换一个具体子域名单独申请证书
3: 重新签发 *.example.com，覆盖现有证书
请选择 [1-3]：1
```

在 `更多域名` 里填泛域名时，若系统里已经有覆盖它的证书会被拒绝并指向上面的复用入口。
若填的泛域名覆盖了本站域名（例如站点 `www.example.com` 填 `*.example.com`），CA 不接受
两者共存，此时会当场说明并转入泛域名流程：

```
DNS 验证，请输入域名（示例：www.example.com）: www.example.com
您的域名：www.example.com
请输入更多域名（支持泛域名，示例：*.example.com sub.example.com，留空跳过）: *.example.com
*.example.com 已覆盖网站域名 www.example.com，CA 不接受两者同时出现在一张证书里。
泛域名 *.example.com 覆盖的网站：a.example.com www.example.com
本次写入 HTTPS 配置的网站：a.example.com www.example.com
1: 按 *.example.com 签发证书，并写入上面列出的网站
2: 重新输入更多域名
请选择 [1-2]：1
```

选 1 后与直接输入泛域名完全一致：上级域名单独确认，签发后写入所有被覆盖的网站；同时
填写的跨根域域名（如 `other.org`）保留在证书里。填的泛域名不覆盖本站域名时（站点
`example.com` 填 `*.example.com`）不触发转入，证书同时包含两者。

`lnmp onlyssl` 检测到已有证书时会问是否重新签发，默认保留现有证书。

`更多域名` 只接受该站点根域下的域名，或站点配置里已有的域名。输入其它根域的域名会先
列出来要求确认——它们既要求 DNS 服务商能管理对应解析，又会被写进这个站点的 HTTPS
配置，多数情况是输错了。`lnmp onlyssl` 不写站点配置，跨根域只提示不拦截。

**只要证书 (`lnmp onlyssl <服务商>`)**

不检查站点、不生成也不修改任何 Nginx 配置，只把证书签下来放到
`/usr/local/nginx/conf/ssl/`。适合证书要给别的服务用（邮件、反向代理、
另一台机器）或者站点还没建好的情况。泛域名目录名中的 `*.` 会写成 `_wildcard.`。
签发和续期都不重载 Nginx；续期由 acme.sh 的 cron 处理，新证书会自动覆盖到同一路径。
若之后把这张证书引用进某个站点或其它服务，重载动作需自行安排。

**服务商参数**

`{ali|cf|dp|he|gd|aws}` 只是常用几个，参数实际取 acme.sh 的 dnsapi 插件名，
`/usr/local/acme.sh/dnsapi/dns_<名字>.sh` 存在即可用，例如 `nsone`、`gcloud`、
`namesilo`。命令会读插件声明的变量逐项提示输入，例如：

| 服务商 | 参数 | 需要的凭据 |
|---|---|---|
| 阿里云 | `ali` | `Ali_Key`、`Ali_Secret` |
| Cloudflare | `cf` | `CF_Key`+`CF_Email`，或 `CF_Token`（`CF_Account_ID`、`CF_Zone_ID` 可留空） |
| DNSPod | `dp` | `DP_Id`、`DP_Key` |
| HE.net | `he` | `HE_Username`、`HE_Password` |
| GoDaddy | `gd` | `GD_Key`、`GD_Secret` |
| AWS Route53 | `aws` | `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY` |
| NS1 | `nsone` | `NS1_Key` |

一个服务商有两套凭据时（如 Cloudflare 的 Key/Email 与 Token/Account_ID），
会先让你选用哪一套。Cloudflare 选 Token 那一套时，只要 API 令牌具备
区域→区域→读取 和 区域→DNS→编辑 权限，`CF_Account_ID` 与 `CF_Zone_ID`
均可直接回车留空，acme.sh 会按域名自行查找 zone。
凭据由 acme.sh 保存在 `/usr/local/acme.sh/account.conf`，
续期时自动复用，再次执行命令时直接回车即可沿用已保存的值。

**不带服务商参数**（`lnmp dnsssl` / `lnmp onlyssl`）进入手工 TXT 模式：
屏幕上打印 TXT 记录，给 120 秒去 DNS 面板添加，然后继续验证。
**该模式不能自动续期**，证书到期前必须再手工执行一次。

**申请被中断**。签发前会把正在使用的证书目录改名保留（`<域名>.lnmp-bak.<PID>`）。
签发、安装或配置测试失败会自动回滚；按 Ctrl+C 或收到 TERM/HUP 信号时，退出清理
同样会把原证书放回去。进程被 KILL 或主机断电时来不及回滚，下次执行签发命令会扫描
同级目录：产生备份的进程已退出且证书目录缺失时自动恢复并提示，证书目录已经存在
时只提示备份位置，不覆盖现有证书。

```bash
ls -d /usr/local/nginx/conf/ssl/*.lnmp-bak.*   # 查看是否有遗留备份
```

### 7.4 强制 HTTPS

`lnmp ssl add`、`lnmp dnsssl` 最后一步问 `是否将 HTTP 301 跳转到 HTTPS [y/N]` 选 `y` 即可。
WordPress 侧还要把站点地址改成 https：

```bash
mysql -u wpdemo -p -h 127.0.0.1 wpdemo -e \
  "UPDATE wp_options SET option_value='https://wp.example.com'
   WHERE option_name IN ('siteurl','home');"
```

[返回顶部](#top)

---

## 八、日常运维命令

### 8.1 系统命令详解

<a id="cmd-index"></a>

`lnmp` 是本项目唯一的管理命令入口。本节按实际分发表逐条说明每个子命令的作用、
参数与使用边界。Redis、Memcached 等不受 `lnmp` 整体命令纳管的服务见
[8.2 lnmp 命令不纳管的服务与自定义](#82-lnmp-命令不纳管的服务与自定义)。

| 分组 | 子节 |
|---|---|
| 概览 | [8.1.1 命令入口与三种模式](#811-命令入口与三种模式) · [8.1.2 命令总览](#812-命令总览) |
| 服务控制 | [8.1.3 整体服务控制](#813-整体服务控制) · [8.1.4 kill 强制终止](#814-kill-强制终止) · [8.1.5 单组件控制](#815-单组件控制) |
| 站点与应用 | [8.1.6 vhost 站点管理](#816-vhost-站点管理) · [8.1.7 app 应用托管](#817-app-应用托管) |
| 数据与账号 | [8.1.8 database 数据库](#818-database-数据库) · [8.1.9 ftp 账号](#819-ftp-账号) · [8.1.10 backup 备份](#8110-backup-备份) |
| 运维与安全 | [8.1.11 崩溃自动拉起](#8111-崩溃自动拉起) · [8.1.12 health 健康检查](#8112-health-健康检查) · [8.1.13 perm 权限基线](#8113-perm-权限基线) · [8.1.14 phpmyadmin 入口开关](#8114-phpmyadmin-入口开关) · [8.1.15 tgnotice 通知](#8115-tgnotice-通知) · [8.1.16 ssl 证书签发](#8116-ssl-证书签发) |
| 参考 | [8.1.17 返回码与非交互边界](#8117-返回码与非交互边界) · [8.1.18 不属于 lnmp 命令的入口](#8118-不属于-lnmp-命令的入口) |

#### 8.1.1 命令入口与三种模式

命令实体是 `/bin/lnmp`，安装结束时同步一份到 `/usr/bin/lnmp`，两者内容一致、权限 755。
三种运行模式共用 `lnmp` 这个命令名，脚本来源不同：

| 安装模式 | 命令来源 | Web 层 | PHP 运行方式 |
|---|---|---|---|
| LNMP | `conf/lnmp` | Nginx | 独立 php-fpm |
| LNMPA | `conf/lnmpa` | Nginx 反代 Apache | Apache 内置 PHP 模块 |
| LAMP | `conf/lamp` | Apache | Apache 内置 PHP 模块 |

由此产生的差异只有两处，其余子命令三种模式完全一致：

- **LNMPA 和 LAMP 没有 `php-fpm` 子命令**，也不存在 php-fpm 服务，PHP 随 Apache 一同起停。
- **LAMP 没有 `nginx` 子命令**。

所有子命令都必须以 root 执行，非 root 直接退出并返回 1。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.2 命令总览

**服务控制** — 详见 [8.1.3](#813-整体服务控制) 至 [8.1.5](#815-单组件控制)

- `lnmp status` — 显示已纳管服务的状态与 phpMyAdmin 访问路径
- `lnmp start` — 启动已纳管的服务
- `lnmp stop` — 停止已纳管的服务
- `lnmp restart` — 先 stop 再 start
- `lnmp reload` — 重载配置，不中断服务
- `lnmp kill` — 强制终止 Web、PHP 与数据库进程，仅在 stop 失败时用
- `lnmp nginx <动作>` — 单独控制 Nginx（LAMP 无此命令）
- `lnmp httpd <动作>` — 单独控制 Apache（仅 LNMPA / LAMP）
- `lnmp php-fpm <动作>` — 单独控制 php-fpm（仅 LNMP）
- `lnmp mysql <动作>` / `lnmp mariadb <动作>` — 单独控制数据库，用实际安装的那个
- `lnmp pureftpd <动作>` — 单独控制 Pure-FTPd

**站点与应用** — 详见 [8.1.6](#816-vhost-站点管理) 至 [8.1.7](#817-app-应用托管)

- `lnmp vhost add` — 新增站点（交互）
- `lnmp vhost list` — 列出所有站点
- `lnmp vhost del` — 删除站点，保留网站文件（交互）
- `lnmp app add` — 登记一个 Node、Go 等自带后端的应用（交互）
- `lnmp app list` — 已托管应用及运行状态
- `lnmp app start|stop|restart|status <应用名>` — 控制单个应用
- `lnmp app logs <应用名>` — 查看应用日志
- `lnmp app del <应用名>` — 注销应用

**数据与账号** — 详见 [8.1.8](#818-database-数据库) 至 [8.1.10](#8110-backup-备份)

- `lnmp database add|list|edit|del` — 库与同名账号的增删改查（交互）
- `lnmp database export <库名> <文件.sql.gz>` — 导出单个库
- `lnmp database import <库名> <文件.sql.gz>` — 导入到指定库
- `lnmp ftp add|list|edit|del|show` — Pure-FTPd 账号管理（交互，需先装 Pure-FTPd）
- `lnmp backup init` — 生成备份配置、目录与定时任务（交互）
- `lnmp backup run [db|web|all] [域名...]` — 执行备份
- `lnmp backup status` — 上次结果、下次计划与配置概览
- `lnmp backup list [db|web]` — 列出本地与远端批次
- `lnmp backup restore db <库名> [批次]` — 从备份恢复数据库
- `lnmp backup restore web <域名> [批次]` — 从备份恢复网站文件
- `lnmp backup test` — 试恢复验证，导入临时库校验后删除

**运维与安全** — 详见 [8.1.11](#8111-崩溃自动拉起) 至 [8.1.16](#8116-ssl-证书签发)

- `lnmp health check|status` — 立即探测一轮 / 查看各服务探测结果与失败计数
- `lnmp health reset [服务]` — 清除失败计数与熔断标记
- `lnmp health init|uninit` — 安装 / 移除每分钟探测的 timer
- `lnmp perm check [服务名]` — 核对权限基线
- `lnmp perm status` — 钩子状态、忽略清单与上次结果
- `lnmp perm run` — 定期核对入口，结果有变化才通知
- `lnmp perm init|uninit` — 注入 / 剥离校验钩子与每日核对任务
- `lnmp perm ignore <条目ID>` / `lnmp perm unignore <条目ID>` — 忽略与取消忽略
- `lnmp phpmyadmin enable|disable|status` — phpMyAdmin 访问开关
- `lnmp tgnotice --init|--test|--status` — Telegram 通知配置、测试与查看
- `lnmp tgnotice "文本" [md]` — 发送一条消息
- `lnmp ssl add` — HTTP 验证签发证书并写入站点配置（交互）
- `lnmp dnsssl <provider>` — DNS 验证签发并写入站点配置（交互）
- `lnmp onlyssl <provider>` — DNS 验证只签发，不写入任何站点配置（交互）

单组件命令的 `<动作>` 为 `start|stop|restart|reload|status`。不带参数或参数无法识别时，
命令打印全部用法并返回 1。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.3 整体服务控制

```bash
lnmp status                      # 查看当前模式已安装的 Web、PHP 与数据库服务
lnmp start
lnmp stop
lnmp restart
lnmp reload
```

**纳管范围。** 整体命令只处理三类服务，各模式的实际清单如下：

| 模式 | 起停顺序 |
|---|---|
| LNMP | Nginx → 数据库 → php-fpm → 已安装的多版本 php-fpm |
| LNMPA | Nginx → 数据库 → Apache |
| LAMP | Apache → 数据库 |

**不在纳管范围内**：Redis、Memcached、Pure-FTPd、phpMyAdmin。前三者有各自的 unit
和 init 脚本，需要单独起停，详见 [8.2](#82-lnmp-命令不纳管的服务与自定义)；Pure-FTPd
虽然有 `lnmp pureftpd` 子命令，但 `lnmp start` / `lnmp stop` 不会带上它。

**服务名每次执行时重新探测。** 数据库取 MariaDB 优先、否则 MySQL；组件是否存在按
systemd unit 或 `/etc/init.d` 脚本判断。因此主安装之后再单独装的组件，下一次执行
`lnmp` 命令就会自动纳入，不需要改配置。未安装的组件打印“未检测到已安装服务，跳过”
并继续处理其余服务，不算失败。

**动作优先走 systemd。** 系统在 systemd 下运行且该服务有 unit 时执行
`systemctl <动作> <服务>.service`，否则回退 `/etc/init.d/<服务> <动作>`。这样进程状态
与 `systemctl` 和监控结果一致。

**`restart` 是先 `stop` 再 `start`，不是原子操作**，中间存在服务不可用的窗口；只改配置
不换二进制时优先用 `reload`。

**`start` 之后会核对 unit 状态**，并区分两种异常：

- *在运行但不受 systemd 管理*：进程存在而 unit 不是 active，说明它被 systemd 之外的
  方式启动过，`systemctl` 停不掉也重载不了。按提示执行 `lnmp kill` 后再 `lnmp start` 对齐。
- *未能启动*：进程不存在，直接给出 `systemctl status` 与 `journalctl` 的排查命令。

重启期间 unit 状态为 `activating` 时不判定为异常，避免误报。

**`lnmp status`** 除服务状态外，还会显示安装时随机生成的 phpMyAdmin 访问路径；访问被
禁用时显示“访问已禁用（程序和配置仍保留）”。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.4 kill 强制终止

`lnmp kill` 仅在正常 `stop` 失败时使用。它先按 unit 执行 `systemctl stop`，再逐个终止
残留进程：先发 TERM 并等待进程真正退出（数据库最多 30 秒，其余最多 10 秒），超时才发
KILL 并给出提示。进程本就不在时不输出内容。全部终止成功才打印“完成。”并返回 0：

```bash
lnmp kill; echo "rc=$?"
# 正在终止 Nginx、PHP-FPM 和数据库进程...
# 完成。
# rc=0
```

先按 unit 停止是必要的：unit 设了 `Restart=on-failure`，直接发信号会被 systemd 判为
异常退出并重新拉起。

该命令依赖 procps 提供的 `pgrep` 与 `pkill`。两者缺失时退回 `killall`（此路径无法
确认进程是否已退出），都没有时报错并要求安装 procps：

```bash
apt-get install -y procps      # Debian / Ubuntu
yum install -y procps-ng       # CentOS / RHEL
```

`kill` 之后请用 `lnmp start` 重新拉起服务，不要直接跑 `/etc/init.d/` 下的脚本，
否则 `systemctl is-active` 与实际进程会再次对不上。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.5 单组件控制

```bash
lnmp nginx status
lnmp mysql restart               # 或 lnmp mariadb restart，按实际安装的数据库
lnmp php-fpm reload              # 仅 LNMP
lnmp httpd status                # 仅 LNMPA / LAMP
lnmp pureftpd start
```

动作为 `start|stop|restart|reload|status`。这些动作优先走 systemd；其它动作直接交给
`/etc/init.d/<服务>` 处理，能否执行取决于该脚本本身。

边界：

- `mysql` 与 `mariadb` 只有实际安装的那个可用，另一个会提示找不到 unit 和 init 脚本并返回 1。
- **单组件命令不处理多版本 PHP。** 只有 `lnmp start` / `stop` / `reload` 会遍历
  `/etc/init.d/php-fpm<版本>`。要单独控制某个版本，用
  `systemctl restart php-fpm@8.2`（模板 unit 已安装时）或 `/etc/init.d/php-fpm8.2 restart`。
- `pureftpd` 可以单独控制，但不被整体命令纳管。
- LNMP 模式下，除 `status` 外的动作会打印明确的成功或失败结果并附退出码；数据库启动
  失败时额外输出诊断信息。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.6 vhost 站点管理

```bash
lnmp vhost add       # 新增站点
lnmp vhost list      # 列出所有站点
lnmp vhost del       # 删除站点（只删 Web 配置，保留网站文件）
```

`add` 与 `del` 是交互式命令。`add` 可用环境变量预设答案实现非交互创建，
完整字段与示例见 [4.2 非交互创建](#42-非交互创建)；行为细节与删除保护见
[8.3 站点管理](#83-站点管理)。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.7 app 应用托管

```text
lnmp app add                 # 交互式登记一个应用
lnmp app list                # 已托管应用及运行状态
lnmp app start   <应用名>
lnmp app stop    <应用名>
lnmp app restart <应用名>
lnmp app status  <应用名>
lnmp app logs    <应用名>
lnmp app del     <应用名>
```

元数据写在 `/etc/lnmp/apps/<应用名>.env`，由 `lnmp-app@.service` 模板 unit 读取，
每个应用以专属账号 `lnmp-app-<应用名>` 运行。

边界：

- 应用名同时用作 unit 实例名、系统账号名和文件名，只接受小写字母、数字和中划线，
  必须以字母或数字开头结尾，**最长 23 字符**（账号名加前缀后不得超过 Linux 用户名上限 32）。
- 登记时会检查端口是否已被其它进程占用，占用则拒绝。
- 依赖 systemd，无 systemd 的环境不可用。

配套的反向代理站点建法见 [4.5 托管 Node / Go 应用进程](#45-托管-node--go-应用进程)。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.8 database 数据库

```text
lnmp database add    # 新建库 + 同名用户
lnmp database list   # 列出所有库
lnmp database edit   # 改库用户密码
lnmp database del    # 删除库

lnmp database export <库名> <文件.sql.gz>   # 导出数据库，文件名需含路径
lnmp database import <库名> <文件.sql.gz>   # 导入数据库，文件名需含路径
```

六个动作**都会先要求输入数据库 root 密码**，凭据写入 `~/.my.cnf`，命令结束即删除。
动作名先于口令校验，因此拼错动作名不会白输一次密码，直接打印用法并返回非 0。

全部 `database` 子命令成功返回 0、失败返回非 0，可直接用于脚本判断。导入的 SQL 边界
检查、导出导入的具体行为与 `add` 的冲突保护见 [8.4 数据库管理](#84-数据库管理)。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.9 ftp 账号

```bash
lnmp ftp add     # 新增 FTP 账号
lnmp ftp list    # 列出账号
lnmp ftp edit    # 改密码
lnmp ftp del     # 删除账号
lnmp ftp show    # 显示指定账号的详细信息
```

**前置条件**：必须已安装 Pure-FTPd（`bash pureftpd.sh`）。检测不到
`/usr/local/pureftpd/sbin/pure-ftpd` 时命令直接报错退出，不进入交互。

全部为交互式命令，不适合放进脚本。服务本身用 `lnmp pureftpd <动作>` 控制，
TLS 与端口配置见 [2.5.3 安装后的配置位置](#253-安装后的配置位置)。
不需要传统 FTP 时不要安装该服务。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.10 backup 备份

```text
lnmp backup init                       # 生成配置、备份目录与定时任务
lnmp backup run [db|web|all] [域名...] # 执行备份
lnmp backup status                     # 上次执行结果、下次计划与配置概览
lnmp backup list [db|web]              # 列出批次（配了异地上传则一并列远端）
lnmp backup restore db  <库名> [批次]
lnmp backup restore web <域名> [批次]
lnmp backup test                       # 试恢复：导入临时库校验后删除
```

配置文件 `/etc/lnmp/backup.conf`（权限 600），日志 `/var/log/lnmp/backup.log`。
`run` 不带参数时按配置的周期决定是否备份网站。完整流程、异地上传与加密见
[8.5 备份](#85-备份) 和 [8.6 异地备份（SFTP）](#86-异地备份sftp)。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.11 崩溃自动拉起

Nginx、Apache、PHP-FPM（含多版本）、Redis、Memcached、Pure-FTPd 的 unit 都设了
`Restart=on-failure`，进程被 OOM killer 终止或自身崩溃时 3 秒后自动重启。
`lnmp stop`、`lnmp kill` 和 `systemctl stop` 属主动停止，不会触发自动拉起。

下面的故障注入会立即终止 Nginx 主进程并造成短暂中断，只能在测试机或已批准的维护窗口执行；
日常状态检查不要运行它：

```bash
# 验证自动拉起：杀掉主进程后等 5 秒，服务应重新 active
systemctl show nginx -p NRestarts
kill -9 "$(cat /usr/local/nginx/logs/nginx.pid)"
sleep 5
systemctl is-active nginx
systemctl show nginx -p NRestarts    # 计数比之前大 1
```

300 秒窗口内最多启动 5 次，超出后 unit 标记为 failed 并停止重试，同时推送 Telegram
告警。此时排查原因、修好后手工拉起：

```bash
journalctl -xeu nginx.service --no-pager | tail -50
systemctl reset-failed nginx.service
lnmp start
```

MySQL/MariaDB 不参与自动重启（其 SysV 脚本基于 `mysqld_safe`，已自带崩溃拉起），
无响应时由 `lnmp health` 告警。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.12 health 健康检查

`Restart=` 只处理进程退出，发现不了「进程还在但不响应」。这一层由 `lnmp health`
覆盖，`lnmp-health.timer` 每分钟探测一次（依赖 systemd，无 systemd 的环境不可用）：

```bash
lnmp health status              # 各服务当前探测结果与失败计数
lnmp health check               # 立即执行一轮探测，终端下直接打印每个服务的结果
lnmp health reset nginx         # 熔断后修好了，清计数解除熔断
lnmp health reset               # 清除全部服务的计数与熔断标记
lnmp health init                # 安装 lnmp-health.timer
lnmp health uninit              # 移除定时探测，unit 层的崩溃自动拉起不受影响
systemctl list-timers lnmp-health.timer --no-pager
tail -20 /var/log/lnmp/health.log
```

`/var/log/lnmp/health.log` 记录探测失败、熔断、恢复与服务未运行的告警，
正常运行时每 24 小时写一条摘要（正常、探测失败、未运行的服务数）。
一次异常都没有且不满一天时该文件可能尚未生成。

**探测覆盖 `nginx`、`httpd`、`php-fpm`、`mysql`、`mariadb`、`redis`、`memcached`**，
按实际安装情况选取。注意 Redis 和 Memcached 在这里被探测和重启，却**不**被
`lnmp start` / `stop` 纳管，见 [8.2](#82-lnmp-命令不纳管的服务与自定义)。Redis 探针
直接用 bash 的 `/dev/tcp` 发 inline 命令，不调 `redis-cli`，端口从
`/usr/local/redis/etc/redis.conf` 读取，改端口后无须另行配置。

Web 探针同样走 `/dev/tcp`，不依赖 `curl`。Nginx 探的是主配置内置的
`127.0.0.1:1008/nginx_status`，该 location 已关闭访问日志，每分钟一次的探测不会写进
`/home/wwwlogs/default.log`；该端点被改动时回退到站点端口。Apache 没有等价端点，探测请求带
固定 `User-Agent: lnmp-health`，LAMP 与 LNMPA 的默认站点配置按该标识跳过访问日志。
LNMPA 中 Apache 只监听 `127.0.0.1:88`，探针取的就是这个端口，探的是 Apache 自身而非前端 Nginx。

连续失败 3 次（约 3 分钟）才执行一次 `systemctl restart`；30 分钟内已重启 2 次仍
未恢复则熔断，只告警不再重启。数据库达阈值只告警，不自动重启。`lnmp stop` 之后
服务不会被健康检查重新拉起。

服务已停止（unit 仍是开机自启但不在运行）时不做探测，连续 3 轮仍未运行会写日志
并告警一次；unit 处于 `failed` 时立即告警。这类情况**不会**自动重启，需要人工确认
是维护中停机还是异常退出。已被 `systemctl disable` 的服务不告警。

`/etc/lnmp/health.conf` 由 `lnmp health init`（完整安装时自动执行）生成，内容是各项阈值的
内置默认值，直接改其中的值即可，改完不需要重启 timer。该文件已存在时 `init` 不覆盖。

```bash
# 由 init 生成，按需修改
Fail_Threshold=3          # 连续探测失败达到该次数才重启或告警
Restart_Window_Sec=1800   # 熔断窗口秒数
Restart_Max=2             # 窗口内最多重启同一服务的次数
Probe_Timeout=5           # 单次探测超时秒数，须小于 30 秒
Notify_Quiet_Sec=3600     # 同一服务的告警间隔秒数
Summary_Interval_Sec=86400  # 全部正常时写入日志摘要的间隔秒数
```

每项都必须是正整数。填了空值、`0`、负数或非数字时，该项回退到内置默认值并在运行时告警；
`Probe_Timeout` 达到或超过 30 秒同样回退：Web 探针最多探两次（状态端点与回退的站点端口），
两次之和要留在 timer 的 60 秒间隔内，否则上一轮探测会压到下一轮。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.13 perm 权限基线

服务起不来时先核对一次权限基线，多数属主类故障能在这里直接定位：

```text
lnmp perm check           # 核对全部条目
lnmp perm check mariadb   # 只核对数据库相关条目
lnmp perm status          # 校验钩子安装状态、忽略清单与上次结果
lnmp perm init            # 注入校验钩子并安装每日定期核对任务
lnmp perm uninit          # 剥离钩子并移除定期核对任务
lnmp perm run             # 定期核对入口，仅在结果与上次不同时推送通知
lnmp perm ignore <条目ID>    # 忽略有意做出的权限调整
lnmp perm unignore <条目ID>
```

`check` 可选的服务名：`mysql`、`mariadb`、`nginx`、`httpd`、`php-fpm`、`redis`、
`pureftpd`、`cmd`、`sec`。Redis 和 Pure-FTPd 在这里同样被覆盖，尽管它们不受
`lnmp start` 纳管。

返回码用于脚本判断：**0** 全部通过；**1** 存在权限告警；**2** 存在会导致服务启动失败
的问题。日志在 `/var/log/lnmp/perm.log`，忽略清单在 `/etc/lnmp/perm-ignore`（权限 600）。

`hook` 和 `diagnose` 是钩子与诊断 unit 的内部入口，不用于手工调用。

详见 [9.11 权限被改动导致服务异常](#911-权限被改动导致服务异常)。

DenyHosts 误封时使用源码目录里的严格地址入口；参数必须是完整 IPv4 或 IPv6，非法值会在
停止服务和修改列表前退出：

```bash
read -r -p "被误封的完整 IPv4 或 IPv6: " BLOCKED_IP
bash tools/denyhosts_removeip.sh "${BLOCKED_IP}"
```

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.14 phpmyadmin 入口开关

```bash
lnmp phpmyadmin status     # 当前是否可访问
lnmp phpmyadmin disable    # 关闭访问，保留程序和配置
lnmp phpmyadmin enable     # 重新开放访问
```

开关的实现是移动 Web 层的访问配置文件，改完做语法检查并 reload；任一步失败会把配置
移回原位再报错，不会留下"配置已改但服务没生效"的中间状态。LNMPA 模式下 Nginx 与
Apache 两侧都要成功才算成功。

随机访问路径由 `lnmp status` 显示。长期不用时保持 `disable`。

`status` 会打印可直接复制的完整地址，例如：

```
phpMyAdmin 访问已启用：http://1.2.3.4/0bf5a37a_phpmyadmin/
建议改用 HTTPS：执行 lnmp ssl add，域名填 default，可为该公网 IP 申请证书。
```

IP 取自本机默认路由的源地址，不查询外部服务。因此网卡上是私网地址、公网入口为弹性 IP 的
机器（常见于公有云）会显示内网地址并附带说明，此时把地址换成自己的公网 IP 即可。

default 站点配好证书后，同一条命令给出的就是 `https://` 地址，不再追加上面那行建议。
default 没有域名，只能申请 IP 证书，流程和限制见
[7.2 没有域名，仅使用 IP 的 default 站点](#72-没有域名仅使用-ip-的-default-站点)。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.15 tgnotice 通知

```bash
lnmp tgnotice --init          # 交互式写入 /etc/lnmp/notify.conf
lnmp tgnotice --test          # 发送一条测试消息
lnmp tgnotice --status        # 显示当前配置，不显示完整令牌
lnmp tgnotice "文本" [md]     # 发送一条消息，带 md 时按 Markdown 解析
```

`notice` 是 `tgnotice` 的等价别名。命令转交 `/bin/lnmp-tgnotice` 执行，该文件缺失时
给出补装命令并返回 1。崩溃自动拉起超限、`lnmp health` 熔断和 `lnmp perm run` 的结果
变化都通过这个通道推送。配置项含义见
[2.5.3 安装后的配置位置](#253-安装后的配置位置)，令牌文件权限必须保持 600 或 400。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.16 ssl 证书签发

```text
lnmp ssl add                  # HTTP 验证，签发并写入已有站点配置
lnmp dnsssl <provider>        # DNS 验证，签发并写入已有站点配置；dns 是等价别名
lnmp onlyssl <provider>       # DNS 验证，只签发证书，不写入任何站点配置
```

`ssl` 只有 `add` 一个动作，其它参数直接打印用法并返回 1，不进入交互。

`<provider>` 取 acme.sh 的插件名去掉 `dns_` 前缀，如 `ali`、`cf`、`dp`、`he`、`gd`、
`aws`、`nsone`、`gcloud`，可用清单见 `/usr/local/acme.sh/dnsapi/`。插件不存在时在进入
交互前就报错。`dnsssl` 与 `onlyssl` 都可以不带 provider，此时走手工添加 TXT 记录的模式，
**该模式无法自动续期**，证书到期前必须手动重签。

三者的选择依据、泛域名处理和续期见 [7.3 三条签发命令怎么选](#73-三条签发命令怎么选)。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.17 返回码与非交互边界

可直接用于脚本判断（返回码真实反映结果）：

- 整体与单组件服务控制、`kill`
- `database` 全部动作（但仍会交互索要 root 密码）
- `backup`、`perm`、`health`、`phpmyadmin`、`tgnotice`

必须交互、不适合放进无人值守脚本：

- `vhost add` / `vhost del`
- `ftp` 的全部动作
- `ssl add`、`dnsssl`、`onlyssl`

现有的非交互开关：

| 变量 | 作用 | 说明 |
|---|---|---|
| `VHOST_PHP=n` | 建站时关闭 PHP | 见 [4.4 建不带 PHP 的站点](#44-建不带-php-的站点) |
| `LNMP_Import_Allow_Cross_Db=yes` | 放行跨库导入 | 见 [8.4 数据库管理](#84-数据库管理) |

`install.sh` 的整套非交互变量见 [2.2 非交互安装（站群自动部署）](#22-非交互安装站群自动部署)。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

#### 8.1.18 不属于 lnmp 命令的入口

下列功能不通过 `lnmp` 调用，需在保存本项目源码的目录内执行。

**组件与扩展的增删**

```text
bash addons.sh install   {memcached|opcache|redis|apcu|imagemagick|ioncube|exif|fileinfo|ldap|bz2|sodium|imap|swoole}
bash addons.sh uninstall {memcached|opcache|redis|apcu|imagemagick|ioncube|exif|fileinfo|ldap|bz2|sodium|imap|swoole}
```

```bash
bash addons.sh install redis      # 实际执行时传一个名字
bash addons.sh uninstall swoole
bash addons.sh                    # 不带参数进菜单，编号与上面的名字一一对应
```

装了多个 PHP 版本时会先让你选版本，直接回车用主版本。安装动作要求 PHP 已存在；
卸载不要求，便于在 PHP 已移除后清理残留。各名字的作用：

- `memcached` — 编译 Memcached 服务端并装 PHP 侧扩展，参数与自定义见
  [8.2.4 Memcached 自定义](#824-memcached-自定义)
- `redis` — 编译 Redis 服务端。**PHP 的 redis 扩展主安装已默认装好**
  （`Enable_PHP_Default_Redis=y`），这一项装的是服务端，见 [三、安装 Redis](#三安装-redis)
- `opcache` — PHP 字节码缓存。**主安装已默认启用**（`Enable_PHP_Default_Opcache=y`），
  只在关闭过或需要重装时用，调优见 [6.2 PHP 与 OPcache](#62-php-与-opcache)
- `apcu` — 进程内的本地内存缓存，从 PECL 编译。适合单机小对象缓存，
  跨进程共享要用 Redis 或 Memcached
- `imagemagick` — 装 ImageMagick 与 PHP 的 imagick 扩展。
  **主安装已默认提供 imagick**（`Enable_PHP_Default_Imagick=y`）
- `ioncube` — **当前版本未接入**。执行后只打印说明并返回 1，不做任何改动。
  原因是尚未按架构补齐 `src/checksums.sha256` 的校验条目，不是安全判定。
  确需使用时到官方站点取包自行安装
- `exif` — 读取图片 EXIF 元数据，从 PHP 源码树编译
- `fileinfo` — 按内容判断文件 MIME 类型，WordPress 上传校验会用到
- `ldap` — LDAP 目录服务客户端，自动装 `libldap2-dev`、`libsasl2-dev`
- `bz2` — bzip2 压缩解压
- `sodium` — libsodium 现代加密库，自动装 `libsodium-dev`
- `imap` — IMAP/POP3/NNTP 客户端，自动装 `libc-client-dev`、`libkrb5-dev`
- `swoole` — 常驻内存的异步协程运行时，从 PECL 编译。WordPress 用不到

`eaccelerator`、`xcache`、`sourceguardian` 已在 2.3 移除：它们只支持已停止维护的
PHP 5.x，或属于没有官方公开下载源的闭源组件。传这些名字会明确报错并返回 1。
其它不在清单里的名字同样只打印用法并返回 1，不做任何系统改动；这类扩展的手工安装
步骤见 [8.2.6 安装本项目未提供的 PHP 扩展](#826-安装本项目未提供的-php-扩展)。

**服务与整体维护**

```text
bash upgrade.sh {nginx|openresty|mysql|mariadb|m2m|php|phpa|phpmyadmin|mphp}
```

```bash
bash pureftpd.sh          # 安装 Pure-FTPd 服务
bash upgrade.sh nginx     # 升级单个组件
bash uninstall.sh         # 卸载整套环境
```

`upgrade.sh` 的 `m2m` 是 MySQL 转 MariaDB，`phpa` 是 Apache 模式的 PHP，
`mphp` 是多版本 PHP。数据库升级没有自动回滚，务必先备份并在测试环境验证。
`upgrade.sh php` 会清空 `/usr/local/php/conf.d/`，升级后所有 PHP 扩展都要重装。
Nginx 模块是编译期决定的，增删模块需要重新编译，见
[8.2.7 安装本项目未提供的 Nginx 模块](#827-安装本项目未提供的-nginx-模块)。

**运维辅助脚本**

```bash
/bin/lnmp-cutlogs                                 # Nginx 日志切割，已自动定时执行，见 8.7
bash tools/denyhosts.sh                           # 安装 DenyHosts
bash tools/fail2ban.sh                            # 安装 Fail2ban
bash tools/denyhosts_removeip.sh "${BLOCKED_IP}"  # 解除 DenyHosts 误封，见 8.1.13
bash tools/reset_mysql_root_password.sh           # 重置数据库 root 密码，见 9.7
bash tools/remove_disable_function.sh             # 解除 PHP 禁用函数限制，见 9.8
bash tools/remove_open_basedir_restriction.sh     # 解除站点 open_basedir 限制，见 9.9
```

`tools/backup.sh` 与 `tools/check502.sh` 已废弃，保留仅为兼容存量 crontab，
分别改用 `lnmp backup` 和 `lnmp health`。后者会绕过 systemd 直接重启 PHP-FPM，
且没有失败阈值与熔断，与 unit 的 `Restart=` 冲突。

**安装到系统路径、可在任意目录执行的命令**

```text
lnmp-sqlguard check  <目标库名> <文件.sql 或 .sql.gz>    发现越界语句返回 1
lnmp-sqlguard report <目标库名> <文件.sql 或 .sql.gz>    只列出问题，恒返回 0
lnmp-tgnotice ...                                        与 lnmp tgnotice 等价
```

`/usr/local/redis/bin/redis-preflight` 是 `redis.service` 的启动前端口占用检查，
由 unit 自己调用，一般不手工执行。

[↑ 命令目录](#cmd-index) · [返回顶部](#top)

### 8.2 lnmp 命令不纳管的服务与自定义

#### 8.2.1 纳管边界

`lnmp start` / `stop` / `restart` / `reload` 只处理 Web 层、PHP-FPM 和数据库
（见 [8.1.3 整体服务控制](#813-整体服务控制)）。Redis、Memcached、Pure-FTPd 由
`addons.sh` 或 `pureftpd.sh` 单独安装，生命周期与主栈解耦，起停必须单独执行。
容易被误解的是，它们虽然不受整体命令纳管，却仍被 `lnmp health` 和 `lnmp perm` 覆盖：

| 服务 | `lnmp start/stop` | `lnmp <服务> <动作>` | unit 崩溃自动拉起 | `lnmp health` 探测 | `lnmp perm check` |
|---|---|---|---|---|---|
| Nginx / Apache | ✓ | ✓ | ✓ | ✓ | ✓ |
| php-fpm | ✓ | ✓ | ✓ | ✓ | ✓ |
| MySQL / MariaDB | ✓ | ✓ | — | ✓ | ✓ |
| Pure-FTPd | — | ✓ | ✓ | — | ✓ |
| Redis | — | — | ✓ | ✓ | ✓ |
| Memcached | — | — | ✓ | ✓ | — |

因此：`lnmp restart` 之后 Redis 不会被重启；`lnmp stop` 之后 Redis 仍在运行，且
`lnmp health` 会继续探测它。整机维护需要一并停掉时，显式执行 `systemctl stop redis`。

#### 8.2.2 统一的起停方式

有 systemd 时一律用 `systemctl`，只有无 systemd 的兼容环境才使用 `/etc/init.d/`：

```bash
systemctl status  redis --no-pager
systemctl restart redis
systemctl status  memcached --no-pager
systemctl restart memcached
lnmp pureftpd restart                 # Pure-FTPd 有 lnmp 子命令
```

混用两种入口会让 `systemctl is-active` 与实际进程对不上，处理办法见
[9.10 服务起不来，或状态与 systemd 对不上](#910-服务起不来或状态与-systemd-对不上)。

#### 8.2.3 Redis 自定义

配置文件 `/usr/local/redis/etc/redis.conf`，属主 `root:redis`、权限 640——服务进程
只能读不能改，防止运行期被改掉持久化路径等安全设置。改配置需要 root。

安装时已固定的值：

| 配置项 | 安装值 | 说明 |
|---|---|---|
| `bind` | `127.0.0.1 -::1` | 只监听回环，同时 nftables 阻断 `Redis_Port` |
| `port` | `lnmp.conf` 的 `Redis_Port` | 默认 6379 |
| `daemonize` | `no` | unit 用 `Type=simple` 直接跟踪主进程 |
| `dir` | `/usr/local/redis/var` | 固定数据目录 |
| `logfile` | `/usr/local/redis/var/redis.log` | Redis 自身错误写这里，不进 journal |
| `pidfile` | `/usr/local/redis/var/redis.pid` | 位于 Redis 账号可写目录 |
| `loadmodule` | 全部注释 | 对应模块未随 `make install` 安装 |

**改动前必须知道的三条约束：**

1. **`daemonize` 不要改回 `yes`。** unit 的 `ExecStart` 带 `--daemonize no`，命令行
   参数覆盖配置文件取值，改了也不生效，只会造成理解偏差。
2. **数据和日志路径不能移出 `/usr/local/redis/var`。** unit 设了
   `ProtectSystem=full` 与 `ReadWritePaths=/usr/local/redis/var`，写别处会被内核拒绝。
   确需换盘时改 unit 的 `ReadWritePaths`，改完 `systemctl daemon-reload`。
3. **改 `port` 之后要同步防火墙规则。** `lnmp health` 的 Redis 探针会自动从
   `redis.conf` 读取新端口，无须另行配置；但 nftables 里阻断的是安装时那个端口号，
   新端口需要自己补一条阻断规则。

常用的自定义项：

```bash
# 内存上限与淘汰策略，容量取值依据见 6.5
maxmemory 512mb
maxmemory-policy allkeys-lru

# 纯缓存用途可关闭持久化，减少磁盘写入；缓存丢失后由应用重建
save ""
appendonly no
```

改完重启并回读确认（Redis 没有等价于 `nginx -t` 的完整配置检查，只能重启后验证）：

```bash
systemctl restart redis
systemctl is-active redis
redis-cli config get maxmemory
redis-cli config get maxmemory-policy
redis-cli info memory | grep used_memory_human
```

`requirepass` 的设置步骤见 [三、安装 Redis](#三安装-redis)；对象缓存容量规划见
[6.5 Redis 对象缓存容量](#65-redis-对象缓存容量)；启动失败排查见
[9.5.1 Redis 服务状态与启动失败](#951-redis-服务状态与启动失败)。

改完之后自检：

```bash
lnmp health check
lnmp perm check redis
ss -lntp | grep redis-server        # 确认监听地址仍是回环
ps -o user,cmd -C redis-server      # 确认不以 root 运行
```

重跑 `addons.sh install redis` 会把 `redis.conf` 的 `port`、`/etc/init.d/redis` 的
`REDISPORT` 和防火墙规则一起对齐成 `lnmp.conf` 的 `Redis_Port`：端口不同时先停服务
再改配置，随后由安装流程重新启动，`redis.conf` 里的其它配置项不受影响。手工改端口
后要长期生效，就同步改 `lnmp.conf`。

#### 8.2.4 Memcached 自定义

Memcached 没有独立配置文件，参数写在 `/etc/init.d/memcached` 顶部，unit 通过该脚本
启动，改脚本即改运行参数：

| 变量 | 安装值 | 说明 |
|---|---|---|
| `IP` | `127.0.0.1` | 只监听回环 |
| `PORT` | `lnmp.conf` 的 `Memcached_Port`，默认 11211 | |
| `USER` | `memcached` | 专用低权限账号，不存在时启动脚本自动创建 |
| `CACHESIZE` | `64` | 缓存上限，单位 MB |
| `MAXCONN` | `1024` | 最大并发连接数 |
| `OPTIONS` | 空 | 追加的原始启动参数 |

改完重启并回读：

```bash
systemctl restart memcached
ss -lntp | grep :11211
echo -e 'stats settings\r' | nc 127.0.0.1 11211 | grep -E 'maxbytes|maxconns'
```

`lnmp health` 的 Memcached 探针同样从 `/etc/init.d/memcached` 读取 `IP` 和 `PORT`，
改端口后无须另行配置；但和 Redis 一样，nftables 里阻断的是原端口号。

重跑 `addons.sh install memcached` 会把 `PORT` 对齐成 `lnmp.conf` 的
`Memcached_Port`，同时把阻断规则迁到新端口并重启服务；`CACHESIZE`、`MAXCONN`、
`OPTIONS` 等改过的参数保留不动。手工改端口后要长期生效，就同步改 `lnmp.conf`。

Memcached 协议不提供鉴权和租户隔离，不要对公网开放；互不信任的站点应拆分实例和
系统账号。演示页开关 `Enable_Memcached_Test_Page` 生产环境保持 `n`。

#### 8.2.5 Pure-FTPd 自定义

服务由 `bash pureftpd.sh` 单独安装，配置文件
`/usr/local/pureftpd/etc/pure-ftpd.conf`。它是三者中唯一有 `lnmp` 子命令的：
用 `lnmp pureftpd <动作>` 控制服务，用 `lnmp ftp <动作>` 管理账号
（见 [8.1.9 ftp 账号](#819-ftp-账号)）。

新安装模板固定 `TLS 2`（拒绝明文登录，客户端须选显式 FTPS），该项不在 `lnmp.conf` 中，
运行期值以配置文件为准。

端口和被动模式范围来自安装时的 `lnmp.conf`。`bash pureftpd.sh` 在编译前会打印这些值
并要求输入 `y` 确认，要改端口就先取消，改 `lnmp.conf` 后重跑，或用环境变量临时覆盖：

```bash
Pureftpd_Port=2121 Pureftpd_Passive_Min=40000 Pureftpd_Passive_Max=40100 bash pureftpd.sh
```

已装过时该摘要还会指出现有配置的端口与本次将写入的值是否不同 —— 重跑会把
`pure-ftpd.conf` 恢复成模板加 `lnmp.conf` 的值，之前手工调过的端口会被改回。

装完再改端口，需要同时改 `/usr/local/pureftpd/etc/pure-ftpd.conf` 和防火墙放行规则，
改动后：

```bash
lnmp pureftpd restart
ss -lntp | grep pure-ftpd
lnmp perm check pureftpd
```

改被动端口范围时防火墙要同步放行对应区间，否则列目录会卡住。不需要传统 FTP 时不要
安装该服务；仅传文件建议改用 SFTP。

#### 8.2.6 安装本项目未提供的 PHP 扩展

`addons.sh` 传入不认识的名字时，只打印用法并返回 1，**不做任何系统改动**：

```bash
bash addons.sh install yaml; echo "rc=$?"
# 用法：./addons.sh install {memcached|opcache|redis|apcu|imagemagick|...}
# rc=1
```

清单外的扩展需要手工编译。步骤与本项目内部安装扩展的做法一致，以 PECL 上的
`yaml` 为例：

```bash
# 1. 先确认没装，重复加载会让 PHP 启动报错
/usr/local/php/bin/php -m | grep -i yaml

# 2. 取源码。PECL 不提供逐文件签名，自行核对来源与哈希后再解压
cd /usr/local/src
curl -fLO https://pecl.php.net/get/yaml-2.2.4.tgz
sha256sum yaml-2.2.4.tgz
tar zxf yaml-2.2.4.tgz && cd yaml-2.2.4

# 3. 用本项目 PHP 的 phpize 和 php-config，不要用系统自带的
/usr/local/php/bin/phpize
./configure --with-php-config=/usr/local/php/bin/php-config
make && make install

# 4. 写 ini。文件名沿用「三位编号-扩展名.ini」，普通扩展用 009
cat > /usr/local/php/conf.d/009-yaml.ini <<'EOF'
extension = "yaml.so"
EOF

# 5. 重启后验证；.so 不存在或加载失败时删掉这个 ini 再排查
lnmp php-fpm restart
/usr/local/php/bin/php -m | grep -i yaml
```

几条必须知道的约束：

- **编号决定加载顺序，有依赖关系时不能随便取。** 现有占用：`004` opcache、
  `005` memcached、`008` imagick、`009` 各普通扩展、`020` igbinary、`021` redis。
  phpredis 依赖 igbinary，所以排在它后面。新扩展无依赖时用 `009`。
- **多版本 PHP 要用绝对路径。** `/usr/bin/php`、`/usr/bin/phpize`、`/usr/bin/pecl`
  这三个软链接指向主版本 `/usr/local/php`。要装到别的版本，全程换成
  `/usr/local/php8.2/bin/phpize` 这样的完整路径，ini 也写进对应版本的 `conf.d`。
- **`bash upgrade.sh php` 会清空 `/usr/local/php/conf.d/`**，手工装的扩展和
  `addons.sh` 装的扩展都会失效，升级后需要重新安装并重建 ini。
- 手工装的扩展不进本项目的校验清单和升级流程，来源可信度、版本兼容和后续维护
  由使用者自己负责。
- Apache 模式（LNMPA / LAMP）第 5 步改用 `lnmp httpd restart`。

#### 8.2.7 安装本项目未提供的 Nginx 模块

Nginx 模块是编译期决定的，装完之后不能追加，只能改参数重新编译。

**只需 configure 参数、不用下载源码的模块**，写进 `lnmp.conf` 的
`Nginx_Modules_Options`，或在命令前传同名环境变量：

```bash
Nginx_Modules_Options="--with-http_dav_module --with-http_slice_module" bash install.sh nginx
```

该变量在安装和 `upgrade.sh nginx` 时都会读取，因此把它固定写进 `lnmp.conf`
才能在后续升级中保留；只用环境变量传一次，下次升级就没了。

**需要下载源码的第三方模块**，自行准备源码目录，用 `--add-module=` 指向它：

```bash
# 源码放在项目 src 之外的固定位置，避免被清理
mkdir -p /usr/local/src/nginx-modules
cd /usr/local/src/nginx-modules
curl -fLO https://example.com/some-nginx-module-1.0.tar.gz
sha256sum some-nginx-module-1.0.tar.gz     # 自行核对
tar zxf some-nginx-module-1.0.tar.gz

Nginx_Modules_Options="--add-module=/usr/local/src/nginx-modules/some-nginx-module-1.0" \
    bash install.sh nginx
```

编译完成后核对模块确实编进去了，并做配置语法检查：

```bash
/usr/local/nginx/sbin/nginx -V 2>&1 | tr ' ' '\n' | grep -- --add-module
/usr/local/nginx/sbin/nginx -t && lnmp nginx reload
```

边界：

- **本项目不为普通 Nginx 提供带校验的自定义模块机制。** `Nginx_Modules_Options`
  只是原样拼进 `./configure`，不下载源码、不校验 SHA256、不记录构建配置。
  源码目录必须自己维护，升级 Nginx 时目录还得在，否则编译失败。
- **动态模块要自己加载。** 用 `--add-dynamic-module=` 编出的 `.so` 不会被自动引用，
  需要手工在 `/usr/local/nginx/conf/nginx.conf` 顶部加 `load_module` 指令。
- **OpenResty 有完整机制，普通 Nginx 没有。** 走 OpenResty 时用
  `OpenResty_Custom_Modules` 数组按「名称|下载地址|SHA256|static 或 dynamic」登记，
  安装流程会下载校验、动态模块自动生成 `load_module`，配置记录到
  `/etc/lnmp/openresty-build.conf` 供升级沿用。需要长期维护第三方模块时优先选它，
  用法见 [2.3.1 OpenResty 自定义编译模块与 Lua 库](#231-openresty-自定义编译模块与-lua-库)。
- 重新编译会替换 `/usr/local/nginx/sbin/nginx` 并重启服务，站点配置和证书不受影响，
  但仍应安排在维护窗口执行。

#### 8.2.8 自定义后的统一自检

任何一项改动后都执行一遍：

```bash
systemctl is-active redis memcached pureftpd    # 只看实际安装的
lnmp health check                               # 探针是否仍能连上
lnmp perm check                                 # 权限基线是否被改动破坏
ss -lntp                                        # 监听地址与端口是否符合预期
nft list ruleset | grep -E '6379|11211'         # 对外阻断规则是否覆盖新端口
```

### 8.3 站点管理

```text
lnmp vhost add       # 新增站点
lnmp vhost list      # 列出所有站点
lnmp vhost del       # 删除站点（只删 nginx 配置，保留网站文件）
lnmp app add         # 托管 Node/Go 等应用进程，见 4.5
lnmp app list        # 已托管应用及运行状态
lnmp app logs <name> # 查看应用日志
```

> `vhost del` 会保留网站文件并给出提示，以避免误删数据。
> 删除本身是原子的：先备份待删配置，语法检查和 reload 都通过才清理备份；
> 任一步失败会把文件全部还原并返回非零，不会出现配置已删但服务仍在提供站点的状态。
> 网站文件需要彻底删除时，先把目录规范化并确认它是预期的网站子目录，再单独处理；
> 不提供通用 `rm -rf` 示例，避免空变量或错误目录造成跨站点删除。`.user.ini` 的
> immutable 属性已由删站流程自动解除。
>
> `vhost add` 会问 `是否开启 PHP? (Y/n，默认 y)`。选 `n` 建出的站点不执行 PHP，
> `.php` 请求一律 404，适合纯静态站点和 Node、Go 等自带后端的站点；
> 非交互执行用 `VHOST_PHP=n`。详见 4.4。

### 8.4 数据库管理

```bash
lnmp database add    # 新建库 + 同名用户
lnmp database list   # 列出所有库
lnmp database edit   # 改库用户密码
lnmp database del    # 删除库

lnmp database export example_db /root/example_db.sql.gz
lnmp database import example_db /root/example_db.sql.gz
```

`database import` 在执行前检查 SQL 边界：文件里出现 `DROP DATABASE`、`DROP/CREATE USER`、
`GRANT`、跨库 `USE`、`其它库`.`表` 这类语句时直接拒绝，不会因为“只是恢复一个库”而删掉别的库。
先看报告可用 `lnmp-sqlguard report example_db /root/example_db.sql.gz`；确认要执行时用
`LNMP_Import_Allow_Cross_Db=yes lnmp database import ...`。

`database add` 不接管已有对象：库名或 `<库名>@localhost`、`<库名>@127.0.0.1` 任一已存在时，
命令直接返回非 0 并列出冲突项，不会重置现有账号密码（重复执行曾会让在用站点连不上库）。
需要改密码用 `lnmp database edit`，确认旧库不再需要可 `lnmp database del` 后重建。

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

### 8.5 备份

备份数据库及网站程序，自动导出数据并生成校验清单，确保备份完整可靠。
配置了异地之后自动上传：

```bash
lnmp backup init                     # 扫描已有站点、挑选后生成配置，并装好 systemd timer
                                     # 返回 0 才表示配置写入并装好定时任务；
                                     # 取消（n / 空值 / EOF）返回非 0
lnmp backup run all                  # 立即完整跑一次
lnmp backup run wp.example.com       # 只备份某个站点（文件与它的库）
lnmp backup run db  wp.example.com   # 只备份某个站点的库
lnmp backup run web wp.example.com   # 只备份某个站点的文件
lnmp backup status                   # 上次结果与下次计划
lnmp backup test                     # 试恢复验证：导入临时库校验后删除
```

`init` 会扫描 nginx / apache 的 vhost 配置，反查站点目录。对于WordPress网站会从
`wp-config.php` 里读出 `DB_NAME`，生成形如
`域名|网站目录|数据库名` 的条目写进 `/etc/lnmp/backup.conf`（权限 600）。
新建站点后重跑一次 `init`或手工修改配置，非WordPress站点可以手工往配置里加一行。

`init` 交互要点：

- **挑选站点**：扫描到站点后会列出编号，让你选哪些纳入备份 ——
  回车全选；`1 3` 或直接写域名只备份指定项；`-2` 或 `-default` 排除指定项
  （`default` 这类占位站点在这一步排掉即可）。EOF、连续三次乱输入、
  或排除到一个不剩，都会安全退回全选或重新询问。
- **数据库凭据**：先静默尝试用 root 的 `unix_socket` 免密连接，连得通就直接写出
  `/etc/lnmp/backup-mysql.cnf`（600，不含口令），全程不问密码；只有免密不可用
  （例如 MySQL 的 `caching_sha2_password`）才索取 root 口令，口令校验失败会中止
  且不写配置、不装定时任务。留空跳过时只能备份网站文件。
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
- 异地上传默认关闭，开启方法和备份机侧的配置见 [8.6 异地备份（SFTP）](#86-异地备份sftp)。
  上传先传到远端 `.incoming/<批次>/`，逐个核对大小无误后才改名到正式目录，
  最后才清理远端旧批次 —— 传输中断不会损失已有的恢复点。
- 同一时刻只允许一个备份在跑（flock，没有 flock 的环境退回 mkdir 锁）。

恢复会覆盖目标数据库或网站文件。先执行 `lnmp backup test`、核对批次，并在维护窗口停止写入；
以下命令不是只读检查：

```bash
lnmp backup list                       # 先看有哪些批次，也会显示备份服务器批次
lnmp backup restore db <库名> [批次]    # 恢复数据库
lnmp backup restore web <域名> [批次]   # 恢复网站
lnmp backup restore db  wpdemo         # 不给批次就用最新的一批
lnmp backup restore web wp.example.com 20260810-033000
```

> `tools/backup.sh` 是旧模板，已废弃，现在只会把请求转发到
> `lnmp backup run all`。

如果要手工备份，WordPress 站点至少要备份两样：**数据库** 和 **`wp-content/` 目录**
（主题、插件、上传的媒体文件）。核心文件可以重新下载，这两样不能。手工备份可用如下脚本：

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

### 8.6 异地备份（SFTP）

[返回顶部](#top)

>建议第一次配置时按 8.6.4
> 的顺序逐步确认，不要直接依赖定时任务 —— 出错多半出在备份机侧的
> 权限与主机指纹上，逐步走一遍能立刻定位。

本地备份在 `lnmp backup init` 之后就已经自动执行了。异地上传默认关闭，
需要一台**独立的备份服务器**，并在两侧各配一次。

本示例中备份服务器保存的备份文件所在路径为 `/srv/sftp/backupuser/backup`,请根据实际情况更改。

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

#### 8.6.1 备份机：建账号和目录

以下命令在**备份服务器**上执行。

```bash
# 专用账号，不给 shell
id backupuser >/dev/null 2>&1 || useradd -m -d /home/backupuser -s /usr/sbin/nologin backupuser

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

#### 8.6.2 备份机：限制这个账号只能做 SFTP

**先备份配置**，再编辑 `/etc/ssh/sshd_config`。在**文件末尾**追加（`Match` 块必须放在最后，
它之后的配置都属于这个块）：

```
Match User backupuser
    ChrootDirectory /srv/sftp/backupuser
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
```

检查语法后重载。下面是 Debian/Ubuntu 的服务名；如果语法或 reload 失败，立即恢复备份：

```bash
# Debian/Ubuntu：
sshd -t && systemctl reload ssh

# EL（按需执行，不要和上一条同时执行）：
# sshd -t && systemctl reload sshd
```

`sshd -t` 没有输出就是通过了。**先别关掉当前的 SSH 会话**，
另开一个连接确认登录正常，再关闭旧会话。

#### 8.6.3 生产机：密钥与主机指纹

以下命令回到**生产服务器**上执行。

**第一步，生成专用密钥。** 不要复用日常登录的密钥 —— 这把钥匙就放在被备份的
这台机器上，一旦这台机器失陷，它能开的门越少越好：

```bash
ssh-keygen -t ed25519 -N '' -f /root/.ssh/lnmp_backup
```

**第二步，把公钥装到备份机。** 先创建公钥文件路径

```bash
mkdir -p /home/backupuser/.ssh/
```

用 `nano` 或其他方式把 `/root/.ssh/lnmp_backup.pub` 的内容加到备份机的
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

两边的指纹逐字比对，对上了才算可信。对不上说明有中间人篡改，别继续。然后生产机上执行：

```bash
chmod 600 /root/.ssh/lnmp_backup /root/.ssh/lnmp_backup_known_hosts
```

#### 8.6.4 生产机：开启上传并验证

编辑 `/etc/lnmp/backup.conf`（权限 600），改这几项：

```text
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
sftp -i /root/.ssh/lnmp_backup -P 22 -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/lnmp_backup_known_hosts backupuser@备份机地址
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

#### 8.6.5 出错时对照排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `HOST KEY VERIFICATION FAILED` | 备份机主机密钥与记录的指纹不符 | **先查清楚原因**。备份机重装过就重新 keyscan 并带外核对；否则按中间人处理，不要直接覆盖 known_hosts |
| `Permission denied (publickey)` | 公钥没装对，或备份机上 `.ssh`/`authorized_keys` 权限不对 | 检查 700 / 600，以及属主是不是 backupuser |
| 登录就断开，日志报 `bad ownership or modes for chroot directory` | chroot 根不是 root 所有或被组/其他人可写 | `chown root:root` + `chmod 755` |
| `远端缺少文件` 或 `远端文件大小不符` | 上传中断或备份机磁盘满 | 脚本已拒绝改名，正式目录没被污染。清理 `.incoming` 后重跑；先看备份机 `df -h` |
| 远端改名失败 | 该账号在 chroot 内没有写权限 | 确认 `backup/` 子目录属主是 backupuser 且权限 700 |
| `找不到数据库 option file` | `init` 时免密不可用且跳过了口令，或该文件被删 | 重跑 `lnmp backup init`，或手工建 `/etc/lnmp/backup-mysql.cnf`（600） |
| `另一个备份任务正在运行` | 上一次还没跑完，或异常退出留下了锁 | 用 `lnmp backup status` 看上次执行时间；确认没有在跑的任务后删除 `/var/lock/lnmp-backup.lock*` |
| 备份成功但没有自动执行 | timer 没启用 | `systemctl enable --now lnmp-backup.timer` |

#### 8.6.6 只有 FTP 服务器可用时

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

#### 8.6.7 备份加密（age 或 GPG）

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

#### 8.6.8 关于远端校验的边界

远端只做**逐个文件的大小核对**，不是内容校验。

受限的 `internal-sftp` 账号不能在备份机上执行命令，所以脚本没法让远端算
SHA-256。大小核对能发现传输截断和文件缺失，发现不了内容被改写。
内容级校验依赖每个批次里的 `SHA256SUMS`，在生产机本地做（`restore` 和
`test` 都会先校验再动手）。

要做到远端内容校验，需要备份机侧配合，两个方向：在备份机上放一个定期
`sha256sum -c SHA256SUMS` 的任务；或者改用允许执行受限命令的通道。
这部分不属于本包能单独完成的范围。

### 8.7 日志

| 日志 | 路径 |
|---|---|
| nginx 错误日志 | `/home/wwwlogs/nginx_error.log` |
| 站点访问日志 | `/home/wwwlogs/<域名>.log` |
| 站点错误日志（Nginx） | `/home/wwwlogs/<域名>.error.log` |
| 站点错误日志（Apache） | `/home/wwwlogs/<域名>-error_log` |
| PHP-FPM 日志 | `/usr/local/php/var/log/php-fpm.log` |
| MySQL 错误日志 | `/usr/local/mysql/var/<主机名>.err` |
| MariaDB 错误日志 | `/usr/local/mariadb/var/mariadb.err` |
| Redis 日志 | `/usr/local/redis/var/redis.log` |
| 安装日志 | `/root/lnmp-install.log` |

日志切割：

安装 Nginx 的栈会自动装上 `/bin/lnmp-cutlogs` 与 `lnmp-cutlogs.timer`，
每天 00:05 切割一次，无需手工配置定时任务：

```bash
systemctl list-timers lnmp-cutlogs.timer --no-pager
/bin/lnmp-cutlogs                 # 立即切割一次
```

脚本切割前一天的日志，每个日志名同时处理 `<名字>.log` 和 `<名字>.error.log`，
按年月归档到 `/home/wwwlogs/<年>/<月>/`，文件名为 `<名字>_<日期>.log` 与
`<名字>.error_<日期>.log`，最后 `nginx -s reload` 重开日志文件。
超过 `save_days`（默认 30）天的归档自动删除，清空后的年月目录一并移除。

默认处理 `/home/wwwlogs` 下的全部一级日志，`lnmp vhost add` 新建的站点无需登记。
需要改保留天数或只切割指定站点时写 `/etc/lnmp/cutlogs.conf`，该文件不会被
管理命令同步覆盖：

```bash
cat > /etc/lnmp/cutlogs.conf <<'EOF'
save_days=14
log_files_name=(default www.example.com)
EOF
```

LAMP 栈不安装该定时任务：切割后需要 `nginx -s reload` 才会重开日志句柄，
Apache 的日志不由该脚本处理。

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

[返回顶部](#top)

---

## 九、故障排查

### 9.1 站点 502 Bad Gateway

以下步骤适用于 LNMP。LNMPA/LAMP 不使用 PHP-FPM socket，应改查
`lnmp httpd status` 和 Apache 错误日志。LNMP 按顺序查：

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

需要一次汇总探测时，使用健康检查的只读状态命令：

```bash
lnmp health status
```

该命令会探测服务并报告当前状态，但不会重启服务。不要使用已废弃的
`tools/check502.sh`；它会绕过 systemd 直接重启 PHP-FPM，也没有连续失败阈值和熔断。

### 9.2 WordPress 后台白屏

生产环境排错有两条铁律：**错误不得能显示给访客**，**日志不得能放在 Web 根目录下**。

```bash
SITE=/home/wwwroot/wp.example.com
SITE=$(readlink -f -- "$SITE")
case "$SITE" in /home/wwwroot/*) ;; *) echo "拒绝危险路径：$SITE" >&2; exit 1;; esac

# 日志目录放在站点根目录之外，Web 完全够不着
WP_DEBUG_LOG_DIR=/var/log/wordpress/wp.example.com
install -d -o www -g www -m 750 "$WP_DEBUG_LOG_DIR" || exit 1

# 三个常量必须一起设：
#   WP_DEBUG = true
#   WP_DEBUG_DISPLAY = false
#     这一项不能省略，否则绝对路径、SQL、插件上下文甚至请求密钥会直接显示给访客
#   WP_DEBUG_LOG = 站点目录之外的日志路径
DEBUG_SNIPPET="$SITE/wp-config-debug.snippet"
[ ! -e "$DEBUG_SNIPPET" ] || { echo "调试片段已存在，拒绝覆盖" >&2; exit 1; }
cat > "$DEBUG_SNIPPET" <<'EOF'
define( 'WP_DEBUG', true );
define( 'WP_DEBUG_DISPLAY', false );   // 不得能少
@ini_set( 'display_errors', 0 );
define( 'WP_DEBUG_LOG', '/var/log/wordpress/wp.example.com/debug.log' );
EOF
echo "把上面几行加到 wp-config.php 里 require_once 之前，复现问题后立刻删除"

# 复现后看（日志在站外，Web 下载不到）
tail -50 "$WP_DEBUG_LOG_DIR/debug.log"
```

> 注意：**不要使用默认的 `WP_DEBUG_LOG = true`**，否则日志会写入
> `wp-content/debug.log`，位于 **Web 根目录内**，任何人都可能直接下载。
> 已存在此类配置时，应在确认具体站点目录后删除，不要使用会匹配所有站点的通配符：
> ```bash
> SITE=/home/wwwroot/wp.example.com
> SITE=$(readlink -f -- "$SITE")
> case "$SITE" in /home/wwwroot/*) ;; *) echo "拒绝危险路径：$SITE" >&2; exit 1;; esac
> rm -f -- "$SITE/wp-content/debug.log"
> ```
> 并在站点配置中增加回退规则（放在 `include enable-php.conf;` 之前）：
> ```nginx
> location ~* \.(log|sql|bak|old|swp|env)$ { deny all; }
> ```

**排查完成后立即恢复配置并清理日志**。debug 日志可能集中记录敏感信息。

最常见的原因是 `memory_limit` 不够（见 6.2）。

### 9.3 文章页 404 但首页正常

伪静态没生效，按栈检查。

**LNMP（Nginx）**：站点配置要引用 wordpress 规则：

```bash
grep rewrite /usr/local/nginx/conf/vhost/wp.example.com.conf
# 应该有：include rewrite/wordpress.conf;
```

没有就手工加进 `server {}` 块，然后先执行 `/usr/local/nginx/sbin/nginx -t`；
只有语法检查通过才执行 `lnmp nginx reload`。

**LNMPA / LAMP（Apache）**：规则来自 `.htaccess`：

```bash
ls -l /home/wwwroot/wp.example.com/.htaccess
```

文件不存在时，到后台「设置 → 固定链接」重新保存一次，由 WordPress 生成；
目录不可写则先 `chown www:www /home/wwwroot/wp.example.com`。
这两套栈不要加 `include rewrite/wordpress.conf;`，会与 `proxy-pass-php.conf`
的 `location /` 冲突。

#### 9.3.1 数据库启动命令返回 0 但服务没起来

先确认不是数据问题：数据目录（MySQL 默认 `/usr/local/mysql/var`）仍在即数据没丢。
最常见的原因是机器上用 apt/yum 装过 `mariadb-server` 或 `mysql-server`：包会覆盖
`/etc/init.d/mysql`，并把 `mysql.service` 别名到 `mariadb.service`，此后
`systemctl stop mariadb` 之类的命令会停掉本包的数据库，启动脚本也不再指向 `/usr/local/mysql`。

```bash
grep -c /usr/local/mysql /etc/init.d/mysql   # 0 表示脚本已被系统包换掉
ls -ld /usr/local/mysql/var                  # 数据目录仍在
```

恢复：

```bash
install -m 755 /usr/local/mysql/support-files/mysql.server /etc/init.d/mysql
systemctl daemon-reload
systemctl start mysql
```

MariaDB 把上面的 `/usr/local/mysql` 换成 `/usr/local/mariadb`。`lnmp health` 的数据库探针
也会报出该情况。如果确实安装过发行版数据库包，先用
`apt-get -s purge 'mariadb-server*' 'mysql-server*'` 预览将被删除的包；只有确认不会删除
其它业务依赖后，才去掉 `-s` 执行。不要把包卸载与 init 脚本恢复合并成一条命令。

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
/usr/local/php/bin/php -m | grep redis

# 检查 drop-in 是否部署
ls -la /home/wwwroot/wp.example.com/wp-content/object-cache.php

# 检查对象缓存是否真的在写入
redis-cli --scan --pattern "wpdemo:*" | wc -l
```

#### 9.5.1 Redis 服务状态与启动失败

`redis-cli ping` 返回 `PONG` 不等于本服务在跑：端口被外部 Redis 占用时，应答的是那个实例。
两项都要看：

```bash
systemctl is-active redis          # 必须是 active
redis-cli -p 6379 ping             # 必须是 PONG（端口按 lnmp.conf 的 Redis_Port）
ss -lntp | grep :6379              # 监听者的 pid 应等于下面这条给出的 MainPID
systemctl show -p MainPID --value redis
```

`systemctl start redis` 报端口被占用时，先确认占用进程再决定处理方式，LNMP 不会结束它：

```bash
journalctl -u redis.service --no-pager -n 20     # 会打印占用进程所在行
ss -lntp | grep :6379
```

连续启动失败达到 unit 限制（300 秒内 5 次）后进入 `failed`，日志显示
`Start request repeated too quickly`。修复原因后清除计数再启动：

```bash
journalctl -xeu redis.service --no-pager | tail -50
tail -20 /usr/local/redis/var/redis.log          # Redis 自身的错误写在这里，不进 journal
systemctl reset-failed redis.service
systemctl start redis
```

前台跑一次能看到最直接的报错（不写 pid、不受 unit 影响，Ctrl+C 结束）：

```bash
/usr/local/redis/bin/redis-server /usr/local/redis/etc/redis.conf --daemonize no
```

已执行过 `lnmp health init` 时，健康检查每分钟探测一次 Redis，连续 3 次失败会自动
`systemctl restart redis.service`，30 分钟内最多 2 次，之后熔断只告警：

```bash
lnmp health status
lnmp health check
lnmp health reset redis          # 修复后清除失败计数和熔断标记
```

启动日志里的 `Memory overcommit must be enabled` 表示 `vm.overcommit_memory` 不是 1。
安装 Redis 时会自动写入 `/etc/sysctl.d/60-lnmp-redis.conf` 并生效；仍出现该告警时：

```bash
cat /proc/sys/vm/overcommit_memory     # 期望 1
sysctl -w vm.overcommit_memory=1       # 值为 2 时属严格模式，安装脚本不覆盖，需自行确认
```

### 9.6 数据库连接失败

[返回顶部](#top)

```bash
# 用 wp-config.php 里的凭据手工连一次，直接看真实报错
mysql -u wpdemo -p -h 127.0.0.1 wpdemo
```

- `Access denied` → 密码错误，或账号仅授权 `localhost` 而客户端连接 `127.0.0.1`
- `Can't connect` → 数据库没启动；按实际分支执行 `lnmp mysql start` 或 `lnmp mariadb start`。
  启动命令本身失败见 9.10

### 9.7 忘记数据库 root 密码

回到保存本项目源码的目录后执行：

```bash
bash tools/reset_mysql_root_password.sh
```

该脚本重置期间会关闭网络监听、只用私有 socket，数据库不对外可见。

### 9.8 程序提示函数被禁用

本包默认在 `php.ini` 的 `disable_functions` 里禁用了 exec 系列函数。
某些程序（如需要调用外部命令的采集、缩略图或队列组件）会因此报
`Call to undefined function` 或 `has been disabled for security reasons`。

回到源码目录执行，按菜单选择解禁范围：

```bash
bash tools/remove_disable_function.sh
```

- `1` 删除全部禁用函数（默认）
- `2` 仅放行 `scandir`
- `3` 仅放行 `exec`

脚本会重启 PHP-FPM（LAMP/LNMPA 下同时重启 Apache）使配置生效。
解禁范围越大，PHP 被利用后可执行的系统操作越多；只放行程序确实需要的那个函数，
不要图省事直接选 `1`。

### 9.9 程序提示 open_basedir 限制

站点目录之外的路径读写会被 `.user.ini` 的 `open_basedir` 拦下，日志里是
`open_basedir restriction in effect`。常见于把附件、缓存或字体放在站点目录之外。

优先改程序路径，让它留在站点目录内。确需去掉限制时执行：

```bash
bash tools/remove_open_basedir_restriction.sh
# 按提示输入网站根目录，例如 /home/wwwroot/example.com
```

该限制是多站点之间的目录边界，去掉后这个站点的 PHP 可以读写 `open_basedir`
原本挡住的路径。单站点服务器影响有限，共享主机场景不建议去掉。

### 9.10 服务起不来，或状态与 systemd 对不上

`lnmp start` 会在启动后核对每个服务的 systemd 状态，并按进程是否真的在运行给出
两种不同的提示。先看清是哪一种，两者的处置方式相反。

**一、进程在跑，但不受 systemd 管理**

```
警告：以下服务在运行，但不受 systemd 管理： nginx
      它们被 systemd 之外的方式启动过，systemctl 无法停止或重载。
      执行 lnmp kill 后再 lnmp start，可让两边重新对齐。
```

多见于直接执行 `/usr/local/nginx/sbin/nginx` 或 `/etc/init.d/` 脚本拉起服务。
此时 `systemctl` 管不到这些进程，`stop`、`reload` 都不会生效。按提示处理：

```bash
lnmp kill && lnmp start
systemctl is-active nginx        # 应为 active，且 lnmp start 不再告警
```

**二、进程不在，服务确实没起来**

```
警告：以下服务未能启动： nginx
      查看失败原因：
        systemctl status nginx.service
        journalctl -xeu nginx.service
```

这种情况执行 `lnmp kill` 没有意义，只会重复同一个失败。按提示的两条命令看原因。
Nginx 与 PHP-FPM 多为配置语法错误，先做配置测试：

```bash
/usr/local/nginx/sbin/nginx -t
/usr/local/php/sbin/php-fpm -t
```

**数据库启动失败**

数据库另有一类不会写进错误日志的失败：数据目录或 `log_error` 指向的文件对
`/etc/my.cnf` 中 `[mysqld] user` 配置的账号不可写时，服务端在打开错误日志前就退出，
`journalctl` 里只有 init 脚本的 ` ERROR!`，错误日志文件本身停留在上一次运行。
`lnmp start` 与 `lnmp mariadb start` 会直接指出这种情况：

```
 /usr/local/mariadb/var 对数据库运行账号 mariadb 不可写。
 /usr/local/mariadb/var/mariadb.err 对数据库运行账号 mariadb 不可写。
 数据库进程无法写入数据目录或错误日志，修复属主后重新启动：
  chown -R mariadb:mariadb /usr/local/mariadb/var
```

按给出的命令恢复属主即可。属主被改坏通常源于递归 `chown` 时路径变量为空，
例如站点加固命令 `chown -R root:www ${SITE}/` 在 `SITE` 未赋值时作用到 `/`，
把数据目录一并改掉（见 5.2 的提示）。只修复错误信息明确指出的数据目录，不要递归修改
整个 `/usr/local/mariadb` 或 `/usr/local/mysql`。

先确认数据目录路径（`/etc/my.cnf` 的 `[mysqld] datadir`），再只对该目录恢复属主：

```bash
grep -E '^\s*datadir' /etc/my.cnf              # 确认数据目录路径
chown -R mariadb:mariadb /usr/local/mariadb/var # MySQL 分支为 mysql:mysql /usr/local/mysql/var
lnmp start
lnmp status
```

不想等到下次启动才发现这类问题，用 9.11 的权限基线核对主动查一次。

属主正常但仍启动失败时，同一条命令改为输出错误日志末尾 15 行，据此继续定位：

```bash
tail -50 /usr/local/mariadb/var/mariadb.err    # 也可直接看完整日志
```

数据库能启动但程序连不上，属于另一类问题，见 9.6。

### 9.11 权限被改动导致服务异常

递归 `chown` 打错路径是最常见的诱因：`chown -R root:www ${SITE}/` 在 `SITE`
未赋值时作用到 `/`，会把 `/usr/local/mariadb/var` 等数据目录一并改掉。

**主动核对**：

```bash
lnmp perm check           # 核对全部条目
lnmp perm check mariadb   # 只核对某个服务相关的条目
```

输出示例：

```
FAIL DB01  /usr/local/mariadb/var
     对运行账号 mariadb 不可写
     修复：chown -R mariadb:mariadb /usr/local/mariadb/var
WARN NGX01  /home/wwwlogs
     属组是 www，期望 root
     修复：chgrp root /home/wwwlogs

通过 11，告警 1，严重 1
```

`FAIL` 表示不修必然导致服务启动失败，`WARN` 表示属主或权限偏离安装值但不影响
启动。核对只报告，不改动任何文件，按给出的命令自行执行即可。

条目对应的路径定位不到时，输出的是令牌本身：

```
WARN DB02  @DB_LOGERROR
     无法定位 @DB_LOGERROR 指向的路径，请检查 /etc/my.cnf 中的相关配置
```

`log_error` 写成相对路径时按 `datadir` 解析（mysqld 的规则），未配置 `datadir`
或解析后越出数据目录就属于这种情况。它只告警、不阻止启动，改正 `/etc/my.cnf`
后重新核对即可；完全没配 `log_error` 则跳过该条，不产生告警。

返回码：`0` 全部通过；`1` 存在告警；`2` 存在会导致启动失败的问题。可用于脚本：

```bash
lnmp perm check || echo "权限存在偏差"
```

**自动感知**：本项目生成的 systemd unit 带校验钩子，全新安装即生效。已有环境
执行一次补上：

```bash
lnmp perm init
systemctl show -p ExecStartPre nginx.service   # 确认钩子已注册
```

装上之后三个时机会自动核对：

- **服务启动前**。覆盖 `systemctl start`、开机自启、systemd 自动重启和
  `lnmp start`。数据库或 Redis 命中不可写这类硬故障时直接阻止启动，
  `journalctl -u mariadb` 里就是路径与修复命令，不必再去猜。
- **服务停止后**。`lnmp stop`、`systemctl stop` 和进程崩溃退出都会跑一次，
  结果写进 journal。交互式停止时直接显示在终端上。
- **服务失败时**。`OnFailure` 实例化 `lnmp-perm-diagnose@.service`，核对结果
  写入 journal 并按已配置的 Telegram 通知推送。查看：

  ```bash
  journalctl -u "lnmp-perm-diagnose@mariadb.service.service" -n 30
  ```

**定期核对**。上面三处只在服务状态变化时触发。属主被改动而服务还在跑时，已打开
的文件描述符不受影响，进程照常工作，不做定期核对就要等到下次重启才暴露。
`lnmp perm init` 会一并装上每天 04:20 前后执行的 systemd timer（systemd 不可用时
退回 `/etc/cron.d/lnmp-perm`）：

```bash
systemctl list-timers lnmp-perm.timer   # 看下次执行时间
lnmp perm run                           # 手动跑一次定期核对
tail -20 /var/log/lnmp/perm.log         # 看历史结果
```

`run` 对失败条目集合取摘要，只在结果与上次不同时推送通知，包括由失败转为恢复的
情况；结果未变但仍有硬失败时每 24 小时再提醒一次。手动 `lnmp perm check` 不推送。

**静音有意的调整**。某条告警是你自己改的，按条目 ID 单独忽略，不必降级整个基线：

```bash
lnmp perm ignore NGX01     # 条目 ID 就是 FAIL/WARN 后面那个短标识
lnmp perm unignore NGX01
lnmp perm status           # 查看当前忽略清单
```

忽略清单在 `/etc/lnmp/perm-ignore`（600），也可直接编辑，每行一个 ID。

需要临时关掉钩子与定期核对：

```bash
lnmp perm uninit; echo "rc=$?"
```

只有全部 unit 钩子剥离、timer 与 cron 删除、诊断 unit 移除和 `daemon-reload`
都成功，才会打印“权限校验钩子与定期核对任务已移除”并返回 0。任一步失败会打印
具体路径并返回非零，此时残留项仍然生效，处理掉打印出来的路径后重跑一次。

**不纳入核对的内容**：`/run` 下的运行时目录与 socket（每次启动重建）、
用户自建站点目录（5.6 加固后属主本就不同）、已存在时项目不会改写的
`/etc/nftables.conf`。

[返回顶部](#top)

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
| default 站点的 PHP 边界 | 只放行 `phpinfo.php` / `redis.php` / `memcached.php` 三个固定文件名与 phpMyAdmin 入口，其余 `.php` 一律拒绝 | 放行的三个文件仅在对应开关打开时才会写入，未写入时访问返回 404；80 与 443 的规则一致，为 default 配 HTTPS 后行为不变；往 default 根目录手工放同名文件同样会被执行，该站点是系统默认创建，其他需求 php 的请自建新站点 |
| phpMyAdmin（已开启时） | 装在网站根目录之外（`/usr/local/phpmyadmin`）；访问路径随机生成 | 挡的是批量扫描与源码直接下载，**不等于**做了访问控制；对外服务仍建议加来源白名单 |
| 下载完整性 | **默认要求一种已配置的完整性机制**，按组件不同分别是：静态 SHA256 清单（`src/checksums.sha256`）、上游发布的 SHA256、**PGP 签名**（nginx / OpenResty 源码）、**包仓库 GPG 签名**（OpenResty apt/yum） | 不是"全部 SHA256"；且 `Enable_Download_Checksum` **可以被关掉**，关掉就没有这层保护 |

> **注意：上表描述的是安装脚本的目标状态，不代表当前系统的实际状态。**
> 防火墙规则可能因 nftables 缺失或写入失败而未生效。此时安装会以
> 非零退出码结束并打印告警；如果忽略该告警，
> 或者事后修改过防火墙，必须重新确认。**上线前应执行以下检查**：
>
> ```bash
> nft list table inet lnmp                    # 确认规则存在
> systemctl is-enabled lnmp-nftables          # 确认规则随 nftables 自动加载
> ss -lntp | grep -E ':3306|:6379|:11211'     # 确认端口仅监听回环地址
> ps -o user,cmd -C redis-server -C memcached # 确认进程不以 root 运行
> ```
>
> 本包规则由 `lnmp-nftables.service` 加载，不写入 `/etc/nftables.conf`，
> 自行维护主配置（如只保留自己的 `inet filter` 表）不会让 `inet lnmp` 表丢失。
> 手工执行 `nft flush ruleset` 不经过 systemd，需自行恢复：
>
> ```bash
> nft -f /etc/nftables.d/lnmp.nft     # 或 systemctl restart nftables
> ```

仍需管理员完成以下配置：

1. **改 SSH 端口 / 禁用密码登录**，本包不碰 SSH 配置。

   仍要保留密码登录时，可用源码目录里的两个脚本之一装 SSH 防爆破，二选一即可，
   同时装会互相重复封禁：

   ```bash
   bash tools/fail2ban.sh      # fail2ban，封禁动作走 nftables，与本包防火墙一致
   bash tools/denyhosts.sh     # DenyHosts，写 /etc/hosts.deny
   ```

   `fail2ban.sh` 会安装 python3 与 nftables 依赖、生成 `/etc/fail2ban/jail.local`
   并把 `banaction` 设为 `nftables`，默认封禁时长 7 天。装完确认服务在跑：

   ```bash
   fail2ban-client status
   fail2ban-client status sshd
   ```

   DenyHosts 误封时用严格地址入口解封（见 8.1）：`bash tools/denyhosts_removeip.sh <IP>`。

2. **按需给 phpMyAdmin 追加来源限制**。

   本包已经做了两层处理，不需要再手工搬目录或改 default 站点的配置：

   - **程序装在 `/usr/local/phpmyadmin`**，不在网站根目录下。
     即使 Web 服务器配置失效（改错、被覆盖、模块没加载），
     源码和 `config.inc.php` 也不会被当作静态文件下载。
   - **访问路径每次安装随机生成**，形如 `49763abb_phpmyadmin`，
     针对固定 `/phpmyadmin/` 的批量扫描直接落空。
   - **程序目录对 PHP 只读**：属主 `root`、属组 `www`，目录 750、文件 640。
     PHP-FPM 以 `www` 运行，被攻破后无法往该目录写入并执行 webshell。
     可写内容只有 `/var/lib/phpmyadmin/tmp`（`www:www 700`，模板缓存）。
     `config.inc.php` 含随机生成的 `blowfish_secret`（用于加密 Cookie 中的
     数据库口令），640 使本机其它账号读不到它；`.access_url` 为 600。
     `lnmp perm check` 的 PMA01、PMA04、PMA05 核对这组权限。

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
   /usr/local/nginx/sbin/nginx -t && lnmp nginx reload
   # 非白名单地址访问 .php 和静态文件都应返回 403
   curl -o /dev/null -w "%{http_code}\n" http://你的域名/49763abb_phpmyadmin/index.php
   ```

   也可以干脆不装 phpMyAdmin，需要时用 SSH 隧道直连数据库。
3. **WordPress 后台加固**：为管理员启用两步验证或 passkey，并限制登录爆破
4. **及时更新**：WordPress 核心、插件和主题漏洞是主要入侵途径，停用但未删除的代码
   仍在磁盘上，同样需要更新或删除
5. **定期执行异地备份恢复测试**，确认备份文件有效、密钥可用且恢复时间可接受

### 10.2 WordPress 应用层基线

[返回顶部](#top)

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
4. **文件写权限最小化**。默认权限（`www:www` 755/644）保留后台安装与自动更新能力。
   需要更强隔离时按 5.6 在功能验证通过后把核心、插件和主题改为 `root:www` 不可由 PHP 修改，
   只给 uploads/cache/upgrade 写权限，代码更新改走受控发布流程。任何情况下都不要为
   解决一次更新失败递归 `chmod 777`。
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
/usr/local/nginx/sbin/nginx -t && lnmp nginx reload

# 放一个测试文件，确认它不会被执行（应返回 403，而不是输出内容）
SITE=/home/wwwroot/wp.example.com
DOMAIN=wp.example.com
SITE=$(readlink -f -- "$SITE")
case "$SITE" in /home/wwwroot/*) ;; *) echo "拒绝危险路径：$SITE" >&2; exit 1;; esac
TEST_FILE="$SITE/wp-content/uploads/lnmp-php-deny-test.php"
[ ! -e "$TEST_FILE" ] || { echo "测试文件已存在，拒绝覆盖：$TEST_FILE" >&2; exit 1; }
trap 'rm -f -- "$TEST_FILE"' EXIT
printf '%s\n' '<?php echo "EXECUTED";' > "$TEST_FILE" || exit 1
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" "https://$DOMAIN/wp-content/uploads/lnmp-php-deny-test.php") || exit 1
[ "$HTTP_CODE" = 403 ] || { echo "上传目录 PHP 阻断未生效，HTTP $HTTP_CODE" >&2; exit 1; }
echo "上传目录 PHP 阻断已生效：HTTP $HTTP_CODE"
rm -f -- "$TEST_FILE"
trap - EXIT
unset SITE DOMAIN TEST_FILE HTTP_CODE
```

实测确认：规则插在 `include enable-php.conf;` 之前时返回 **403**；
放在末尾时返回 **200 并执行**。

[返回顶部](#top)

---

## 十一、依据与校准方法

本指南的数值建议不是从旧版“优化参数合集”复制而来，依据分为两类：

- **项目实现事实**：版本、默认值、路径、端口、菜单和自动分档均来自当前
  `install.sh`、`lnmp.conf`、`include/*.sh`、`conf/lnmp`、`tools/*.sh`。例如项目确实会
  将 4～8GB 主机的 FPM `max_children` 设为 60、MySQL buffer pool 设为 512M；指南明确
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

[返回顶部](#top)

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
防火墙      inet lnmp 表；实际 SSH 端口与 80/443 放行，3306/6379 drop；未动系统主表
```

[返回顶部](#top)
