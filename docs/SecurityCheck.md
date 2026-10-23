# LNMP 3.0.4 安全复查审计报告

审计日期：2026-10-23  
目标环境：Debian 13.6 x86_64 全新系统，LNMP 主线，非交互安装  
重点组件：Nginx 1.30.5（OpenSSL 3.5.9、PCRE 8.45，含 lua、brotli、cache_purge 模块）、
PHP 8.5.12、MySQL 8.4.11 官方通用二进制、Redis 8.10.2、phpMyAdmin、`lnmp` 运维工具  
上一版报告：LNMP 2.3（2026-08-16），归档于 `temp/history/2026-10-23-security-check/`

## 1. 结论

在本次约定的威胁模型和实际检查范围内，**未发现 LNMP 3.0.4 含有隐藏后门、隐藏上传、
静默下载执行、特定 HTTP Header/URL/User-Agent 触发的异常响应，或把 Nginx/PHP 响应
替换为恶意内容的证据**。

固定版本组件从项目声明的官方 HTTPS 来源下载，使用前经过固定 SHA-256、固定指纹 PGP
或上游签名清单验证，校验缺失或不匹配时拒绝继续。对外通信仍只有备份远传、Telegram
通知、ACME 证书和管理员触发的公网 IP 查询，均为显式功能。

Nginx、PHP-FPM、PHP CLI、Redis Server 按已安装程序记录的参数在原构建路径独立重编，
`.text`、`.data`、`.init_array` 与已安装文件逐字节一致；MySQL 官方归档 378 个文件与
已安装文件逐字节一致，安装目录内归档外的 ELF 为 0。数据库未做源码编译。

本轮确认一项权限缺陷并已修复（第 7.4 节）：数据库程序目录整体归数据库运行账号，
而 `mysqld_safe`、`db-preflight` 与 root 执行的客户端工具从该目录加载，数据库进程被
攻破后可借服务重启取得 root。该问题不是隐藏后门，属于本地提权面。另记录四项低风险
加固项（第 10 节）。

本结论不包含“操作系统、官方上游、GitHub Actions 仓库、维护者账号、标签或 TLS 已经
被攻破”的假设。

## 2. 威胁模型

### 2.1 纳入检查

- 项目源码中主动植入或隐藏的后门、下载执行、上传和数据外传。
- 安装、升级、卸载、运维、备份、通知、证书和服务持久化路径。
- 项目下载的源码包、预编译包和安装器是否来自明确来源，使用前是否验证。
- 项目生成或安装的 Nginx、PHP、MySQL、Redis 文件是否出现额外代码。
- 特定 URL、参数、HTTP 方法、User-Agent、Authorization、Cookie 和代理 Header
  是否触发 shell、敏感信息泄露或响应替换。
- 安装产物的属主与权限是否让服务账号具备改写 root 执行文件的能力。
- 干净服务器上无需先攻破系统即可现实触发的问题。

### 2.2 明确排除

- 假设 Debian/Linux 本身、系统动态库、官方软件仓库或 CA 体系已经恶意。
- 假设上游项目、GitHub Action 仓库、维护者账号、发布标签或 TLS 已经失陷。
- 假设服务器已被入侵后，攻击者替换 root 可写文件、编译器、Shell 或系统服务。
- 与隐藏下载、上传、后门、响应篡改和提权无直接关系的普通功能缺陷。

工作流中 `actions/checkout@v5` 等以版本标签引用，按上述排除不登记为漏洞，作为加固项
记录于第 10 节。

## 3. 审阅范围与方法

### 3.1 Shell 文件

`lnmpsrc/` 共 97 个 `.sh`，另有 `conf/lnmp`、`conf/lnmpa`、`conf/lamp` 三份管理入口，
合计约 4.4 万行：

| 目录 | 文件数 | 主要内容 |
|---|---:|---|
| 仓库根目录 | 6 | 安装、升级、卸载、附加组件和版本维护入口 |
| `include/`（含 `mod/`、`rt/`） | 54 | 下载、校验、编译、组件模块、运行期公共层 |
| `tools/` | 20 | 备份、备份机守护、通知、权限基线、健康检查、防火墙、phpMyAdmin 等工具 |
| `t/` | 17 | GitHub Actions 使用的检查、构建与上游跟进脚本 |

按控制流逐文件阅读的范围：全部入口脚本；`include/main.sh`、`init.sh`、`verify.sh`、
`lock.sh`、`profile.sh` 及各升级入口；组件模块中的下载、校验、解包、编译参数、数据库
初始化与目录属主、phpMyAdmin 部署；运行期公共层的 ACME、DNS 凭据、应用托管、站点探测；
`tools/` 中备份与备份机守护、Telegram 通知、权限基线钩子、启动前检查；systemd 与 init
单元、Nginx/PHP/phpMyAdmin 配置模板。其余文件先按网络调用、`source`/执行边界、后台
进程、定时任务、权限与属主修改、临时文件逐处定位，再阅读命中处的上下文。

97 个 `.sh` 与三份管理入口 `bash -n` 全部通过。

### 3.2 其它静态范围

- `init.d/*` 单元、Nginx/FastCGI/PHP/phpMyAdmin 配置与示例、项目补丁。
- `.github/workflows/*` 的权限声明、密钥使用、产物上传、自动分支与 release 数据流。
- `src/checksums.sha256` 76 个条目的格式、文件名唯一性和调用闭环。
- 安装后实际写入 systemd、init、cron、profile 和 `/bin` 的内容（第 6 节）。

`t/lint.sh` 20/20 通过（T2 ShellCheck 0.10.0 在验证机执行），包含“无不可信组件引用”
“无明文 HTTP 下载”“校验 fail-closed”“校验清单格式正确（76 条）”等检查；
`t/consistency.sh` 24/24 通过。

## 4. 下载与执行审计

### 4.1 固定组件下载

统一入口 `Download_Fetch` 只接受 `https://`，curl 限制初始协议与重定向协议为 HTTPS，
重定向最多 5 次。本地缓存命中时重新验证。以下任一条件成立时默认中止，哈希不一致的文件
被删除：

- 清单不存在或为空；
- 下载文件没有清单条目；
- 系统没有 SHA-256 工具；
- 实际哈希与固定值不同。

`src/checksums.sha256` 当前 76 条，覆盖 PHP、Nginx、OpenSSL、PCRE、Nginx/Lua 模块、
LuaJIT、MySQL/MariaDB 源码与通用二进制包、Apache、APR、phpMyAdmin、Redis、PHP 扩展、
编译期基础库、Node.js 与 rclone 归档。

### 4.2 PGP 和安装器

- Nginx 动态升级使用随项目分发的密钥材料和固定指纹白名单验证 `.asc`。
- OpenResty 源码包使用固定签名者指纹验证。
- Node.js 归档先核对静态清单，再以随包公钥和指纹白名单验证上游 `SHASUMS256.txt` 签名，
  并用签名清单交叉核对归档哈希。
- Composer 安装器先取得官方 SHA-384，校验通过后才交给 PHP 执行。
- acme.sh 初次安装固定版本并校验固定 SHA-256，安装后关闭自动升级。
- rclone 仅在 `lnmp backup remote-setup s3` 中经确认后下载固定版本，核对 SHA-256 与版本后
  经同目录临时文件改名安装。

### 4.3 显式例外，不属于隐藏下载

- `Enable_Download_Checksum!='y'`：显式关闭固定组件校验，终端持续红字警告。
- `Download_Insecure='y'`：显式关闭 TLS 证书检查，之后仍执行内容哈希校验。
- `/usr/local/acme.sh/upgrade.sh`：管理员手工执行并输入完整的 `yes`，脚本提示该次升级
  没有固定完整性校验，并再次关闭自动升级。
- `addons.sh install pm2`：经 npm registry 安装 PM2 当前最新版，按已决定的设计不纳入固定
  版本与校验清单，安装前有提示。

以上入口默认不启用、不会静默触发。生产环境不应使用前两项。

### 4.4 未发现的危险模式

- `curl | sh`、`wget | bash` 或进程替换后直接 `source`；
- Base64/十六进制解码后执行远程载荷；
- 从随机域名、短链接、用户不可见镜像下载可执行代码；
- 安装完成后由 cron/systemd 静默拉取代码；
- 根据服务器身份、时间、HTTP 请求或特殊环境变量切换下载地址。

`eval` 仅出现在 `t/consistency.sh` 的静态检查内；`/dev/tcp` 仅用于本机健康探针。

## 5. 上传与外传审计

### 5.1 服务器运行时

| 功能 | 默认 | 发送内容与触发条件 |
|---|---|---|
| 异地备份 | 关闭 | `Enable_Remote_Backup=1` 后，向管理员配置的 SFTP/FTPS/FTP 目标或 S3 兼容对象存储上传备份 |
| Telegram | 关闭 | `TG_Enable=1` 且配置 Token/Chat ID 后，发送调用者明确传入的消息文本 |
| ACME | 按命令触发 | 申请/续期证书时与所选 CA 或 DNS API 通信；签发前探测 ZeroSSL 接口连通性 |
| 公网 IP 查询 | 按命令触发 | 仅 `lnmp ssl` 为 default 站点申请 IP 证书且本机为私网地址时，请求 `https://api.ipify.org` 取公网 IP，结果显示给管理员确认 |
| 包管理器/源码下载 | 按安装触发 | 只接收软件包、元数据、签名或校验值 |

备份默认 SFTP，`StrictHostKeyChecking=yes` 并使用专用 known_hosts；FTPS 默认验证证书；
FTP 为明确标注的明文兼容选项。ftp/ftps 的地址与账号写入 0600 临时 curl 配置，命令行只有
`--config`；S3 访问密钥只在 0600 的 rclone 配置中。备份机守护 `lnmp-backup-vault`
使用 `internal-sftp`、`restrict` 公钥选项与 chroot，生效配置复核后才替换 sshd 配置。

Telegram 配置要求 0600/0400 权限，默认 `TG_Enable=0`；`/etc/profile.d/lnmp-tgnotice.sh`
只在 Bash 中加载函数定义，不发送消息。

DNS API 凭据按域名保存在 0700 目录下的 0600 文件，值按 shell 单引号规则转义，不输出到终端。

本轮验证机为 NAT 环境，未用真实 Telegram API、外部 SFTP 与公网证书签发复测；2026-08-16
报告中的 Telegram 真实 API 结果为历史结论，相关代码本轮未改动。

### 5.2 GitHub Actions

- 无 `pull_request_target` 触发，外部 PR 不接触仓库密钥。
- GPG 私钥只在 `release.yml` 的签名步骤使用；`contents: write` 只授予 release、
  上游跟进与版本同步作业。
- `upstream-check.yml` 每月把 AUTO 类版本更新推到 `auto-<日期>` 分支，重算哈希后经 URL
  探测与编译验证，不合并主分支；主分支版本由维护者手工确认。

上述动作只发生在 GitHub Actions 环境，不在已安装服务器上运行。

## 6. 运行时激活与持久化检查

安装后实际生成内容：

| 类型 | 内容 |
|---|---|
| systemd 服务 | `nginx`、`php-fpm`、`mysql`、`redis`、`lnmp-nftables`、`lnmp-cutlogs`、`lnmp-health`、`lnmp-app@`、`lnmp-perm-diagnose@` |
| 定时器 | `lnmp-health.timer`（每分钟，执行 `/bin/lnmp-health check`）、`lnmp-cutlogs.timer`（每日 00:05） |
| cron | 无新增；root 无 crontab |
| profile | `lnmp-tgnotice.sh`（只定义函数）、`luajit.sh`（导出 `LUAJIT_LIB`/`LUAJIT_INC`） |
| `/bin` | `lnmp`、`lnmp-backup`、`lnmp-cutlogs`、`lnmp-fw`、`lnmp-health`、`lnmp-perm`、`lnmp-phpmyadmin`、`lnmp-sqlguard`、`lnmp-tgnotice`，均为 root:root 755 |
| 状态与日志 | `/etc/lnmp`、`/var/log/lnmp` 均为 root 700，文件 600 |

监听端口：80、443（Nginx）；127.0.0.1:1008（Nginx 本机状态与 `/lua` 测试）；
127.0.0.1:3306、127.0.0.1:33060（MySQL）；127.0.0.1:6379 与 [::1]:6379（Redis）。

- 服务单元的 `ExecStartPre` 调用 `/bin/lnmp-perm hook pre <服务>`：服务名经白名单映射，
  只核对不修改，硬条件失败时阻止启动并通知；数据库单元以 `+` 前缀运行 `db-preflight`
  检查 libaio。`lnmp-perm-diagnose@` 只接受已知 unit 名。
- 安装器持锁期间的监视进程随持锁进程退出，不常驻。
- 未发现延时启动、日期触发、主机名触发、特定用户触发或下载后二阶段激活逻辑。
- 未发现反向 shell、监听式 shell、webshell、隐藏管理口令或调试口令。
- `lnmp perm check` 27/27 通过。

`/lua` 只在 127.0.0.1:1008 的本机 server 中定义，内容为 `ngx.say("hello world")`；
公网 80 端口请求 `/lua` 为 404。

## 7. 二进制全量扫描

审计脚本：`tests/audit_binary_runtime.sh`、`tests/audit_binary_deep.sh`，扫描根 `/usr/local`。

| 项目 | 结果 |
|---|---:|
| ELF 文件 | 215（MySQL 192、PHP 8、ImageMagick 4、Redis 3、LuaJIT 3、libiconv 2、Nginx 1、FreeType 1、iconv 1） |
| `strings -a -n 4` 输出 | 14,545,508 行 |
| 符号输出 | 2,361,428 行 |
| 动态段、程序头与 `ldd` 输出 | 38,909 行 |
| 扫描工具错误 | 0 |
| 组/其他用户可写文件 | 0 |
| SUID/SGID 文件 | 0 |
| `ldd` 未解析依赖 | 0 |
| NX 缺失 / RELRO 缺失 | 0 / 0 |
| 异常可执行映射 | 0 |

进程映射中 36 条 `(deleted)` 均无执行权限：26 条为 `/dev/zero (deleted) rw-s`（Nginx、
PHP-FPM 共享内存），10 条为 `[aio] rw-s`（MySQL Linux 原生 AIO）。

### 7.1 strings 结果

高风险模式命中 12 个文件，均查看了上下文：

- `SET @cmd=`：`mysqld`、`mysqld-debug` 内置的系统表升级 SQL。
- `cmd=%s`、`cmd=0x%02x`、`CMD=`：OpenSSL 配置命令、libfido2 调试输出与组复制插件的格式字符串。
- `-----BEGIN OPENSSH PRIVATE KEY-----`、`-----BEGIN PRIVATE KEY-----`：PHP 四个 SAPI 的
  fileinfo 魔数表，紧随其后为 `OpenSSH private key`、`application/x-pem-file` 等类型名，
  不含密钥内容。
- `cat /etc/passwd | redis-cli -x set mypasswd`：redis-cli 帮助示例。
- `id=%U addr=%s ...`：Redis `CLIENT LIST` 输出格式。

`User-Agent`、`Proxy-Authorization`、`X-Forwarded-For` 等为 Nginx 的 HTTP 协议字段处理。
未命中反向 shell、Meterpreter、C99/R57 webshell、`/dev/tcp`、`nc -e`、`/bin/sh -i`、
`/shell` 或 `/cmd` 后门载荷。

### 7.2 符号表

`system`、`exec*`、`popen`、`dlopen`、`dlsym`、`fork`、`setuid` 等敏感符号命中集中在
Nginx 进程管理、PHP 标准能力、MySQL 客户端与插件框架、Redis 工具、ImageMagick delegate、
FreeType 与 LuaJIT 标准库。没有未知导出入口或隐藏构造器。

### 7.3 动态链接

- ImageMagick 4 个文件 RUNPATH 为 `/usr/local/imagemagick/lib`，Nginx RUNPATH 为
  `/usr/local/luajit/lib`，两目录均为 root 755。
- MySQL 官方二进制使用 `$ORIGIN/../lib/private`、`$ORIGIN/../private` 等相对路径；
  `mysqld-debug` 另含上游构建机路径 `/var/lib/pb2/...`，本机不存在且 `/var/lib` 仅 root 可写，
  该程序不被服务使用。

### 7.4 确认缺陷：数据库程序目录属主

安装后 `/usr/local/mysql` 下 464 个程序文件与目录（数据目录除外）属主为 `mysql:mysql`，
包括 root 执行的 `bin/mysqld_safe`（`ExecStart=/etc/init.d/mysql start` 经 `mysql.server`
以 root 启动）、以 `+` 前缀 root 执行的 `bin/db-preflight`，以及 root 执行的 `mysql`、
`mysqldump` 等客户端经 `$ORIGIN/../lib/private` 加载的私有库目录。`mysqld` 以 `mysql`
运行，数据库进程被攻破后可改写这些文件，在下次服务启动或管理员执行客户端时以 root 执行。
MariaDB 路径同样对 `/usr/local/mariadb` 整体改为 `mariadb` 所有。

成因为 `include/mod/database.sh` 在 MySQL/MariaDB 安装、升级与迁移共 5 处执行
`chown -R <运行账号> /usr/local/<数据库>`，MySQL 升级另有 `chgrp -R mysql`。修复后程序目录归 root，仅数据目录归运行账号；
MariaDB `auth_pam_tool_dir` 由官方初始化程序设为运行账号所有，`auth_pam_tool` 为 root 4755；
权限基线 `DB04`、`DB05` 改为期望 root。修复与验证见第 8.3 节与 `changelogs.md`。

## 8. 关键二进制独立重编

重编脚本从已安装程序读取版本、configure 参数与构建目录，在原构建路径
（`<源码目录>/src/.nginx-build.XXXXXXXX`、`src/.php-build.XXXXXXXX`、`src/redis-<版本>`）
临时创建目录，归档按 `src/checksums.sha256` 核对，不执行安装，退出时删除构建目录。
ELF 段在副本上提取；报告记录的已安装文件 SHA-256 与 HTTP 测试前的快照一致，重编未改动已安装文件。

### 8.1 Nginx

`tests/audit_nginx_rebuild.sh`：Nginx 1.30.5、OpenSSL 3.5.9、PCRE 8.45、lua-nginx-module 0.10.31、
ngx_devel_kit 0.3.4、ngx_brotli 固定提交、ngx_cache_purge 2.3。

| ELF 段 | 比较结果 |
|---|---|
| `.text` | 5,432,478 字节，差异 0 |
| `.data` | 146,388 字节，差异 0 |
| `.init_array` | 8 字节，差异 0 |
| `.rodata` | 786,314 字节，4 字节不同 |

strings 差异仅 OpenSSL `built on:` 构建时间与 build-id 相邻字节；符号差异 0。

### 8.2 PHP 8.5 与 Redis

`tests/audit_critical_rebuild.sh`：PHP 8.5.12 按 `php-config --configure-options` 重编，
Redis 8.10.2 只构建项目实际安装的 `redis-server` 目标。

| 二进制 | `.text` | `.data` | `.init_array` | `.rodata` 差异 |
|---|---|---|---|---:|
| PHP-FPM | 一致，7,872,391 字节 | 一致 | 一致 | 3 字节 |
| PHP CLI | 一致，7,820,397 字节 | 一致 | 一致 | 3 字节 |
| Redis Server | 一致，3,088,300 字节 | 一致 | 一致 | 5 字节 |

PHP 差异为构建日期时间；Redis 差异为版本串中的构建时间值；三者符号差异 0。

#### PHP SAPI 标识、进程标题和硬编码路径

按 `cli|fpm|fastcgi`、`php.ini`、`php-fpm.conf`、`/usr/local/php`、进程标题等模式做聚焦
字符串比较：CLI 230 行、FPM 600 行、共有 49 行。CLI 独有内容为 `cli_server`、
`cli_set_process_title`、`cli.h` 等标准 CLI SAPI 标识；FPM 独有内容为 `fpm_*`、
`fastcgi_*`、`Another FPM instance seems to already listen on %s` 等标准 FPM 实现。
没有额外 SAPI 名称、伪装进程标题或第二套配置名。

- PHP CLI 的 `PHP_SAPI` 为 `cli`；PHP-FPM 的 Server API 为 `FPM/FastCGI`。
- 配置目录 `/usr/local/php/etc`，实际加载 `/usr/local/php/etc/php.ini`，扫描目录 `/usr/local/php/conf.d`。
- master 标题 `php-fpm: master process (/usr/local/php/etc/php-fpm.conf)`，worker 标题 `php-fpm: pool www`。

二进制中的 `<源码目录>/src/.php-build.XXXXXXXX/php-8.5.12/sapi/{cli,fpm}` 是编译器写入的
源码路径，不参与运行时配置查找，也不是下载或执行地址。

### 8.3 数据库

不做源码编译。`tests/audit_db_archive.sh` 先按清单核对归档 SHA-256，再逐成员计算哈希与
已安装文件比较：

| 项目 | 结果 |
|---|---:|
| 归档 | `mysql-8.4.11-linux-glibc2.28-x86_64.tar.xz`，SHA-256 与清单一致 |
| 归档文件 | 378 |
| 逐字节一致 | 378 |
| 不同 / 缺失 | 0 / 0 |
| `bin/mysqld` | 一致 |
| 归档外 ELF | 0 |

安装目录内归档外的文件仅有项目随包的 `bin/db-preflight`（Shell 脚本）。

第 7.4 节修复在验证机实测：

- 全新安装：MySQL 8.4.11、MariaDB 12.3.3 返回 0，数据目录外全部 `root:root`（MariaDB 仅
  `auth_pam_tool_dir` 为 mariadb 700，`auth_pam_tool` 为 root 4755），错误日志无 ERROR，读写正常。
- 故障注入：属主设置失败时 `install.sh db` 返回 1，输出“设置 /usr/local/mysql 属主失败。”，不初始化、不启动服务；
  `upgrade.sh mysql` 返回 1 并自动回滚到升级前版本，数据与服务恢复。
- 升级链路：模拟旧属主的 MySQL 8.0.46 经 `upgrade.sh mysql` 升级到 8.4.11，再经 `upgrade.sh m2m` 迁移到
  MariaDB 11.4.13、`upgrade.sh mariadb` 升级到 11.8.9，各步返回 0，测试数据完整，属主与权限基线符合；
  最终 MariaDB 11.8.9 与官方归档 22614/22614 文件一致。
- 存量迁移：HowtoGuides 10.6 的 MySQL、MariaDB 命令实跑后重启正常，`DB04`/`DB05` 告警消失。

MySQL 8.4 默认 O_DIRECT，InnoDB 启动时在 `innodb_data_home_dir` 最后一个 `/` 之前的目录创建
`check_sector_size` 探测扇区大小。原模板该值不带结尾 `/`，探测落在安装目录，安装目录归 root 后
每次启动记录 `[ERROR] [MY-012655]`（errno 13）。模板改为带结尾 `/`，探测在数据目录内完成。

## 9. HTTP 后门触发与压力测试

审计脚本：`tests/audit_http_triggers.sh`。临时 PHP 探针只监听 `127.0.0.1:18080`，退出时删除
站点和配置并 reload Nginx。

### 9.1 覆盖输入

- 路径：`/shell`、`/cmd?cmd=id`、`/lua`、`/.git/config`、`/../../etc/passwd`、
  单/双重编码穿越、NUL、PHP 命令参数。
- Header：Shellshock 风格和标记型 User-Agent、`X-Original-URL`、`X-Rewrite-URL`、
  `X-Forwarded-For`、`Authorization`、Cookie、方法覆盖、Range、重复 Host、12KB 长头。
- 方法：GET、HEAD、POST、OPTIONS、TRACE、CONNECT。
- 原始协议：重复 Content-Length、Content-Length/Transfer-Encoding 冲突。
- PHP-FPM：基线、Shellshock、改写 URL、Authorization+Cookie 四组。
- 压力：200 请求，并发 20。

### 9.2 结果

- 30/30 curl 用例完成，curl 错误 0，响应异常内容命中 0。
- 路径类：`/shell`、`/cmd`、`/lua`、双重编码与 PHP 命令参数 404，`/.git/config` 403，
  穿越、编码穿越与 NUL 400；POST/OPTIONS/TRACE 与方法覆盖 405，CONNECT 400。
- 四组 PHP 响应均为 13 字节 `AUDIT_PHP_OK`，SHA-256 相同。
- 可疑 Header 与长头对首页响应与基线一致（1,525 字节）。
- 重复 Content-Length 和 CL/TE 冲突均返回 `400 Bad Request`。
- 压力测试 200/200 返回 2xx，错误 0。
- 测试前后 Nginx、PHP-FPM、MySQL、Redis 二进制哈希与已建立外连快照差异 0 行；
  `nginx -t` 前后均成功。

未观察到 shell 输出、UID/GID、`/etc/passwd`、环境变量、phpinfo、私钥内容或异常响应 Header。

## 10. 加固项与剩余边界

以下为记录项，不属于后门或外传：

1. OpenResty 包管理模式从 `https://openresty.org/package/pubkey.gpg` 取得仓库公钥后直接导入，
   未核对 `include/verify.sh` 注释所列指纹；yum 路径另下载 `.repo` 文件。源码模式使用固定
   签名者指纹，不受影响；Debian 13 无官方包，只能使用源码模式。
2. GitHub Actions 以版本标签引用 action，未固定提交 SHA。
3. `lnmp ssl` 的公网 IP 查询使用第三方 `api.ipify.org`（第 5.1 节），仅在管理员申请 default
   站点 IP 证书且本机为私网地址时触发。
4. PM2 取 npm 最新版（第 4.3 节）。

其余边界：

- MySQL 官方归档含未启用的插件与 `mysqld-debug`，符号与 RUNPATH 命中来自官方构建。
- ImageMagick、PHP、LuaJIT、MySQL 正常包含命令执行或动态加载符号，已结合用途、字符串、
  进程映射和 HTTP 实测复核。
- 验证机为 NAT 环境：Telegram 真实 API、外部 SFTP/FTP 与 S3 服务、公网证书签发未在本轮复测。
- 数据库源码编译安装（`Bin=n`）与 MariaDB 10.11 未实测属主修改，由离线用例覆盖。
- Apache/LNMPA/LAMP 只做静态对照；运行时测试针对 Debian 13 LNMP 主线。

## 11. 可复查命令

在 Debian 13、已安装 LNMP 主线的验证机上，从仓库根目录执行（`<lnmp 源码目录>` 为安装所用
源码目录）：

```bash
find lnmpsrc -type f -name '*.sh' -print0 | while IFS= read -r -d '' f; do
    bash -n "$f" || exit 1
done
(cd lnmpsrc && bash t/lint.sh && bash t/consistency.sh)

bash tests/audit_binary_runtime.sh /var/tmp/lnmp-runtime-audit
bash tests/audit_binary_deep.sh /var/tmp/lnmp-runtime-audit
bash tests/audit_http_triggers.sh /var/tmp/lnmp-http-trigger-audit
bash tests/audit_nginx_rebuild.sh
bash tests/audit_critical_rebuild.sh
bash tests/audit_db_archive.sh <lnmp 源码目录>/src
lnmp perm check
```

重编脚本在原构建路径已存在时拒绝执行；HTTP 脚本使用本机监听并通过 trap 清理临时配置。
大体积 `strings`、符号和动态链接输出不提交到仓库，结论与统计保存在本报告。
