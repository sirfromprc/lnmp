# LNMP 2.3 安全复查审计报告

审计日期：2026-08-16  
目标环境：Debian 13 x86_64，LNMP 主线  
重点组件：Nginx、PHP 8.3、MariaDB、Redis、phpMyAdmin、`lnmp` 运维工具

## 1. 结论

在本次约定的现实威胁模型和实际检查范围内，**未发现 LNMP 2.3 含有隐藏后门、
隐藏上传、静默下载执行、特定 HTTP Header/URL/User-Agent 触发的异常响应，或把
Nginx/PHP 响应替换为恶意内容的证据**。

安装和升级主路径没有从未知随机地址取代码执行。固定版本组件默认从项目声明的官方
HTTPS 来源下载，并在使用前经过固定 SHA-256、固定指纹 PGP，或对应上游发布校验值
验证；校验缺失和不匹配时默认拒绝继续。备份远传、Telegram 通知、ACME 证书申请等
对外通信均是可见、可配置、由管理员显式启用的功能，不是隐藏外传。

安装后的关键运行文件也未显示“源码审阅时干净、编译或运行时另行激活”的迹象：
Nginx、PHP-FPM、PHP CLI、Redis Server 的独立重编 `.text` 与已安装文件逐字节一致；
MariaDB 使用官方预编译包，关键文件与已校验归档内文件逐字节一致。未对数据库做源码
编译。

本结论是对当前代码和当前 Debian 13 安装产物的实证结论，不包含“操作系统、官方上游、
GitHub Actions 仓库、维护者账号、标签或 TLS 已经被攻破”的假设。

## 2. 威胁模型

### 2.1 纳入检查

- 项目源码中主动植入或隐藏的后门、下载执行、上传和数据外传。
- 安装、升级、卸载、运维、备份、通知、证书和服务持久化路径。
- 项目下载的源码包、预编译包和安装器是否来自明确来源，使用前是否验证。
- 项目生成或安装的 Nginx、PHP、MariaDB、Redis 文件是否出现额外代码。
- 特定 URL、参数、HTTP 方法、User-Agent、Authorization、Cookie 和代理 Header
  是否触发 shell、敏感信息泄露或响应替换。
- 干净服务器上无需先攻破系统即可现实触发的问题。

### 2.2 明确排除

- 假设 Debian/Linux 本身、系统动态库、官方软件仓库或 CA 体系已经恶意。
- 假设上游项目、GitHub Action 仓库、维护者账号、发布标签或 TLS 已经失陷。
- 假设服务器已被入侵后，攻击者替换 root 可写文件、编译器、Shell 或系统服务。
- 与隐藏下载、上传、后门和响应篡改无直接关系的普通功能缺陷。

因此，工作流中 `actions/checkout@v4`、`actions/upload-artifact@v4` 等使用版本标签，
不因“标签维护者可能被攻破”登记为本项目漏洞；这正是本次约定排除的前置失陷场景。

## 3. 审阅范围与方法

### 3.1 Shell 文件逐个检查

本轮不是用关键词命中代替人工审阅。当前 87 个 `.sh` 均逐个打开并按控制流阅读：

| 目录 | 文件数 | 主要内容 |
|---|---:|---|
| 仓库根目录 | 6 | 安装、升级、卸载、附加组件和版本维护入口 |
| `include/` | 38 | 下载、编译、数据库、Nginx、PHP、Redis、OpenResty 等实现 |
| `tools/` | 12 | 备份、通知、日志、封禁、phpMyAdmin 和密码维护工具 |
| `t/` | 12 | GitHub Actions 直接使用的检查与构建脚本 |
| `tests/` | 19 | 定向回归、真机验证和本轮只读审计脚本 |

每个文件检查了正常分支、失败分支、参数来源、局部/全局变量、临时文件、后台进程、
`source`/执行边界、网络调用、定时任务、清理和退出码。最后对 87 个文件逐个执行
`bash -n`，结果 87/87 通过。

### 3.2 其它静态范围

- `conf/lnmp`、`conf/lnmpa`、`conf/lamp` 三份管理脚本逐项对照公共功能。
- `init.d/*`、Nginx/FastCGI/PHP/phpMyAdmin 配置与示例、项目补丁。
- `.github/workflows/*` 的 checkout、构建、产物上传、PR 和 release 数据流。
- `src/checksums.sha256` 的格式、文件名唯一性和调用闭环。
- 安装、升级后会写入 systemd、init、cron、profile 和 `/bin` 的生成内容。

`t/lint.sh` 全部通过，包含“无不可信组件引用”“无明文 HTTP 下载”“校验
fail-closed”“校验清单格式正确（66 条）”等检查；`t/consistency.sh` 14/14 通过。

## 4. 下载与执行审计

### 4.1 固定组件下载

统一入口 `Download_Fetch` 只接受 `https://`，curl 路径限制初始协议和重定向协议均为
HTTPS，并把重定向限制为 5 次。`Download_Files` 在本地缓存命中时也重新验证，避免
把旧的或被替换的缓存直接用于编译。

`src/checksums.sha256` 当前有 66 个固定文件条目，覆盖 PHP、Nginx、OpenSSL、PCRE、
nghttp2、Nginx/Lua 模块、MySQL/MariaDB 源码和通用二进制包、Boost、Apache、APR、
phpMyAdmin、Redis、PHP 扩展及编译期基础库。以下任一条件成立时默认中止：

- 清单不存在或为空；
- 下载文件没有清单条目；
- 系统没有 SHA-256 工具；
- 实际哈希与固定值不同。

哈希不一致的文件会被删除，不能继续解压或编译。

### 4.2 PGP 和安装器

- Nginx 动态升级使用随项目分发的密钥材料和固定指纹白名单验证 `.asc`。
- OpenResty 源码包使用固定签名者指纹验证，不因只下载到签名文件就直接信任。
- OpenResty 包管理器安装依赖发行版包签名；在本次威胁模型中官方仓库可信。
- Composer 安装器先取得官方 SHA-384，校验安装器后才交给 PHP 执行；校验值格式
  非法、下载失败或哈希不一致都会拒绝执行。
- acme.sh 初次安装固定版本并校验固定 SHA-256，安装后关闭自动升级。

### 4.3 显式例外，不属于隐藏下载

项目保留了三个管理员主动降级入口：

- `Enable_Download_Checksum!='y'`：显式关闭固定组件校验，终端会持续红字警告。
- `Download_Insecure='y'`：显式关闭 TLS 证书检查，但之后仍执行内容哈希校验。
- `/usr/local/acme.sh/upgrade.sh`：管理员手工执行后，还必须输入完整的 `yes`；脚本明确
  提示该次 GitHub 升级没有固定完整性校验，并再次关闭自动升级。

这些入口默认不启用、不会静默触发，也不是运行时后门。按本次威胁模型，管理员主动
关闭保护或主动执行有明确警告的手工升级不登记为隐藏下载漏洞。生产环境不应使用前两项，
手工升级 acme.sh 后应重新核对版本和文件完整性。

### 4.4 未发现的危险模式

逐文件控制流审阅未发现以下产品路径：

- `curl | sh`、`wget | bash` 或进程替换后直接 `source`；
- Base64/十六进制解码后执行远程载荷；
- 从随机域名、短链接、用户不可见镜像下载可执行代码；
- 安装完成后由 cron/systemd 静默拉取代码；
- 根据服务器身份、时间、HTTP 请求或特殊环境变量切换到另一份恶意下载地址。

## 5. 上传与外传审计

### 5.1 服务器运行时

没有发现默认开启或隐藏的数据上传。已确认的对外发送只有明确功能：

| 功能 | 默认 | 发送内容与触发条件 |
|---|---|---|
| 异地备份 | 关闭 | `Enable_Remote_Backup=1` 后，向管理员配置的 SFTP/FTPS/FTP 目标上传备份 |
| Telegram | 关闭 | `TG_Enable=1` 且配置 Token/Chat ID 后，发送调用者明确传入的消息文本 |
| ACME | 按命令触发 | 管理员申请/续期证书时与所选 CA 或 DNS API 通信 |
| 包管理器/源码下载 | 按安装触发 | 只接收软件包、元数据、签名或校验值，不上传站点和数据库内容 |

备份默认协议为 SFTP，要求专用密钥和固定 known_hosts；FTPS 默认验证证书。FTP 是明确
标注的明文兼容选项，只有管理员主动选择并提供远端配置后才会使用。上传先进入
`.incoming`，核对大小后改名。以上属于用户请求的备份行为，不是隐蔽外传。

Telegram 配置要求 0600/0400 权限，默认 `TG_Enable=0`。发送目标固定为 Telegram API，
消息来自显式调用参数；没有收集站点文件、数据库、环境变量或系统命令输出的隐藏分支。

2026-08-16 使用真实 Bot Token/Chat ID 验证：基础 HTML 消息被 API 接受并实际到达；
非闭合 HTML 和未转义 MarkdownV2 均触发真实 400，现有错误匹配
随后以纯文本重发成功。合法 MarkdownV2 首次向量因测试脚本少保留一个反引号转义而
降级为纯文本；修正测试向量后第二轮自动检查和目视检查均为 4/4 通过。粗体标题正确，
全部 MarkdownV2 保留字符按原字符显示且没有反斜杠。因此真实 API 基础链路、两类 400
降级、合法 MarkdownV2 和保留字符显示均已验证。

### 5.2 GitHub Actions

工作流会把构建产物上传为 GitHub Artifact、构建证明或 Release，也可能创建版本更新 PR。
这些动作只发生在 GitHub Actions 环境，步骤名称和数据范围均明确，不在已安装服务器上
运行，不构成服务器数据外传。

## 6. 运行时激活与持久化检查

- 审阅了安装后生成的 systemd、init、cron、profile 和 `/bin/lnmp*` 内容。
- 未发现延时启动、日期触发、主机名触发、特定用户触发或下载后二阶段激活逻辑。
- 未发现反向 shell、监听式 shell、webshell、隐藏管理口令或调试口令。
- 对 Nginx、PHP-FPM、MariaDB、Redis 的实际进程映射检查，没有 `/tmp`、`/var/tmp`、
  用户目录或已删除文件的异常可执行映射。
- HTTP 特殊输入测试前后，四个服务没有新增已建立的外部 TCP 连接。
- 关键二进制测试前后 SHA-256 快照完全一致，没有在收到触发请求后自修改。

`/lua` 需要单独说明：仓库中存在本机管理/构建测试模板，但当前非 Lua Nginx 构建没有
对应 location；公网 80 端口实测 `/lua` 为 404。管理模板仅监听本机地址，不是公网隐藏
触发器。

## 7. 二进制全量扫描

审计脚本：

- `tests/audit_binary_runtime.sh`
- `tests/audit_binary_deep.sh`

扫描根为 `/usr/local`，覆盖本项目安装的 Nginx、PHP、MariaDB、Redis、ImageMagick、
nghttp2、LuaJIT 和扩展模块。

| 项目 | 结果 |
|---|---:|
| ELF 文件 | 130 |
| `strings -a -n 4` 输出 | 4,925,201 行 |
| `readelf -Ws` / `nm -D -a` 符号输出 | 738,247 行 |
| `ldd` / `objdump -p` / 动态段和程序头 | 19,480 行 |
| 扫描工具错误 | 0 行 |
| 非特权用户可写 ELF/共享库目标 | 0 |
| 异常运行时可执行映射 | 0 |
| NX 缺失 | 0 |
| RELRO 缺失 | 0 |
| SUID/SGID 文件 | 1 |

`find` 共列出 222 个组可写/其它用户可写文件，逐项归类后均为 MariaDB 数据、日志、
binlog、undo、pid 等运行数据，不是 ELF、共享库或可加载代码。

### 7.1 strings 全量结果

高风险模式命中均查看了所在文件和上下文：

- `BEGIN PRIVATE KEY` / `BEGIN RSA PRIVATE KEY`：MariaDB TLS 密钥格式解析常量，不是
  内嵌私钥内容。
- `BEGIN OPENSSH PRIVATE KEY`：PHP/OpenSSL 相关格式识别字符串，不是私钥。
- `/etc/passwd`：Redis CLI 帮助示例 `cat /etc/passwd | redis-cli -x ...`。
- `SET @cmd=`：MariaDB 升级系统表的 SQL 文本。
- `cmd=%s`、`Cmd=%.*s`：Nginx/MariaDB 的内部日志和格式字符串。
- `User-Agent`、`Authorization`、`X-Forwarded-For`：HTTP 协议正常字段处理。

没有命中反向 shell、Meterpreter、C99/R57 webshell、`/dev/tcp`、`nc -e`、
`/bin/sh -i`、`/shell` 或 `/cmd` 后门载荷。

### 7.2 符号表

对 `system`、`exec*`、`popen`、`dlopen`、`dlsym`、`fork`、`setuid`、`setgid` 等敏感
符号逐文件归因。命中集中在正常需要进程管理、插件加载或命令执行能力的上游组件，
包括 Nginx master/worker 管理、PHP 标准能力、MariaDB 插件框架、ImageMagick delegate
和 LuaJIT 标准库。没有出现未知导出入口、隐藏构造器或与 HTTP 特殊字段配对的命令执行
符号。

### 7.3 动态链接与权限

- 4 个 RUNPATH 均固定为 `/usr/local/imagemagick/lib`，对应 ImageMagick 本体及
  `imagick.so`；目录不允许非特权用户写入。
- 13 个 `not found` 来自未启用的 MariaDB 可选工具/插件依赖，如 Galera、RocksDB、
  ODBC、Judy、snappy、lzo 和 cracklib。当前服务没有加载这些插件。
- 唯一 4755 文件是 MariaDB 官方 `auth_pam_tool`。PAM 插件查询结果为未加载；该 helper
  与已校验官方归档内文件逐字节一致。
- `mariadbd` 同样与归档内文件逐字节一致。归档自身 SHA-256 与项目固定清单一致。

## 8. 关键二进制独立重编

### 8.1 Nginx

`tests/audit_nginx_rebuild.sh` 使用固定哈希的 Nginx 1.30.4、OpenSSL 3.5.7、PCRE 8.45、
ngx_brotli 固定提交和 ngx_cache_purge 2.3，在相同 Debian 13 工具链和相同配置参数下
独立重编，未安装重编产物。

| ELF 段 | 比较结果 |
|---|---|
| `.text` | 5,144,638 字节，差异 0 |
| `.data` | 差异 0 |
| `.init_array` | 8 字节，差异 0 |
| `.rodata` | 同尺寸，仅 145 字节不同 |

`.rodata` 差异逐项定位为 OpenSSL 构建时间和编译器参数文本。符号差异也只由该参数
字符串长度引起。最关键的机器代码 `.text` 完全一致，且没有额外构造器。

### 8.2 PHP 8.3 与 Redis

`tests/audit_critical_rebuild.sh` 使用项目固定 SHA-256 的 PHP 8.3.33 和 Redis 8.10.0
归档，以已安装程序记录的 PHP configure 参数和相同工具链重编，未执行 `make install`。

| 二进制 | `.text` | `.data` | `.init_array` | `.rodata` 差异 |
|---|---|---|---|---:|
| PHP-FPM | 完全一致，5,491,127 字节 | 一致 | 一致 | 14 字节 |
| PHP CLI | 完全一致，5,436,829 字节 | 一致 | 一致 | 14 字节 |
| Redis Server | 完全一致，3,087,084 字节 | 一致 | 一致 | 5 字节 |

PHP 只读数据差异是构建日期/时间和动态字符串表排列；符号内容无差异。Redis 的 5 字节
差异对应构建 ID 中的时间值；符号内容无差异。三者均没有新增机器代码或构造器。

#### PHP SAPI 标识、进程标题和硬编码路径

按 SAPI 再做了一次独立的 `strings -a -n 4` 聚焦比较，匹配 CLI/FPM/FastCGI、进程
标题、`php.ini`、`php-fpm.conf` 和 `/usr/local/php` 等内容：

| 项目 | 结果 |
|---|---:|
| PHP CLI 聚焦字符串 | 44 行 |
| PHP-FPM 聚焦字符串 | 190 行 |
| 两者共有 | 35 行 |

CLI 独有内容为 `cli.h`、`cli-server`、`php_cli.c`、`php_cli_process_title.c` 等标准
CLI SAPI 标识。FPM 独有内容为 `FPM/FastCGI`、`php-fpm`、`master process (%s)`、
`pool %s`、`%s/etc/php-fpm.conf`、`log/php-fpm.log` 和标准 pool 管理错误文本。没有发现
额外 SAPI 名称、隐藏进程名称、伪装成系统进程的标题或第二套隐蔽配置名。

运行时交叉验证结果：

- PHP CLI 的 `PHP_SAPI` 为 `cli`。
- PHP-FPM 的 Server API 为 `FPM/FastCGI`。
- 编译配置目录为 `/usr/local/php/etc`，扫描目录为 `/usr/local/php/conf.d`。
- PHP-FPM 实际加载 `/usr/local/php/etc/php.ini`。
- master 标题为 `php-fpm: master process (/usr/local/php/etc/php-fpm.conf)`，worker 标题为
  `php-fpm: pool www`。

二进制中的 `/root/lnmp-clean-validation/src/php-8.3.33/...` 是编译器写入的源码/DWARF
构建路径，CLI 指向 `sapi/cli`，FPM 指向 `sapi/fpm`；它们不参与运行时配置查找，也不是
下载或执行地址。使用相同构建目录独立重编后，完整 strings diff 中 SAPI 标识、进程
标题、配置路径和配置名称均无变化；差异仍仅为构建时间及动态字符串表排列。

Redis 8.10 顶层默认目标还会尝试构建未安装的 Search/JSON/TimeSeries 可选模块，首次
审计因验证机没有 cargo 等可选依赖而返回失败。最终复跑只构建项目实际安装和运行的
`redis-server` 目标并成功完成比较，没有下载安装缺失依赖。

### 8.3 数据库处理边界

按本次审计要求，不对 MySQL/MariaDB 做源码编译。MariaDB 当前来自固定 SHA-256 的官方
通用二进制归档，因此采用归档内文件与已安装文件逐字节比较；`mariadbd` 和唯一 SUID
helper 均一致。这能直接回答安装后文件是否被额外替换，同时避免无关的数据库长时间编译。

## 9. HTTP 后门触发与压力测试

审计脚本：`tests/audit_http_triggers.sh`。临时 PHP 探针只监听
`127.0.0.1:18080`，退出时删除站点和配置并 reload Nginx。

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

- 30/30 curl 用例完成，响应异常内容命中 0。
- 四组 PHP 响应均为 13 字节 `AUDIT_PHP_OK`，SHA-256 完全相同。
- 可疑 Header 对首页响应未造成基线外内容。
- 重复 Content-Length 和 CL/TE 冲突均返回 `400 Bad Request`。
- 压力测试 200/200 返回 HTTP 200，curl 错误 0。
- 测试前后 Nginx、PHP-FPM、MariaDB、Redis 二进制哈希和已建立外连快照同哈希。
- Nginx 测试前后 `nginx -t` 均成功。

未观察到 shell 输出、UID/GID、`/etc/passwd`、环境变量、phpinfo、私钥格式内容或异常
响应 Header。

## 10. 正常例外与剩余边界

以下内容不是本轮确认问题，但需要避免误读：

- MariaDB 归档包含大量未启用插件，静态 `ldd` 会显示部分可选依赖缺失；运行服务未加载。
- SUID PAM helper 是官方归档内容且 PAM 未启用，不是项目额外植入。
- ImageMagick、PHP、LuaJIT、MariaDB 等正常包含命令执行或动态加载符号；符号存在本身
  不等于存在后门，已结合调用用途、字符串、进程映射和 HTTP 实测复核。
- Telegram 真实 API 基础发送、两类 400 降级、合法 MarkdownV2 和保留字符显示均已
  通过。
- Apache/LNMPA/LAMP 按项目规则只做静态对照；本次运行时后门测试针对 Debian 13 LNMP
  主线。三份管理脚本的下载、ACME 和公共管理逻辑已对照一致。

## 11. 可复查命令

在 Debian 13、已安装 LNMP 主线的验证机上，可从仓库根目录执行：

```bash
find . -type f -name '*.sh' -print0 | while IFS= read -r -d '' f; do
    bash -n "$f" || exit 1
done
bash t/lint.sh
bash t/consistency.sh

bash tests/audit_binary_runtime.sh /var/tmp/lnmp-runtime-audit
bash tests/audit_binary_deep.sh /var/tmp/lnmp-runtime-audit
bash tests/audit_http_triggers.sh /var/tmp/lnmp-http-trigger-audit
bash tests/audit_nginx_rebuild.sh
bash tests/audit_critical_rebuild.sh
```

重编脚本只在受限临时目录构建，不执行安装；HTTP 脚本使用本机监听并通过 trap 清理临时
配置。原始大体积 `strings`、符号和动态链接输出不提交到仓库，结论与统计保存在本报告，
测试逻辑保存在 `tests/audit_*.sh` 以便重复执行。
