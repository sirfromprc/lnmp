# LNMP 2.3 变更记录

> 本文档记录 LNMP 2.3 的功能调整、安全加固、兼容性修复和验证方法。

---

## 阅读方式

### 变更 ID 说明

本文档是按阶段持续追加的，ID 用来帮助引用，不要求全篇统一成一种格式。
前半段常用“变更性质 + 子系统 + 序号”，后半段更多按审计批次或专题编号。

| 形式或前缀 | 含义 | 示例 |
|---|---|---|
| `FIX-<子系统>-NNN` | 修复既存缺陷 | `FIX-DB-002`、`FIX-REDIS-004` |
| `SEC-<子系统>-NNN` | 安全加固 | `SEC-DL-004`、`SEC-PMA-002` |
| `REF` / `REN` / `DEL` / `CLN` | 重构、重编号、删除、清理 | `REF-DB-001`、`CLN-303` |
| `CONF-NNN` | 阶段 10 的配置模板梳理 | `CONF-006` |
| `GHA-NNN` | 阶段 11 的 GitHub Actions、发布与自动升版 | `GHA-010` |
| `SEC2-NNN` | 后续安全复核批次 | `SEC2-009` |
| `AUDIT-<子系统>-NNN` | Debian 12 实机审计发现的问题 | `AUDIT-DB-001`、`AUDIT-OPS-002` |
| `DBSEC` / `DBSAFE` / `FTPSEC` | 数据库安全、数据库可靠性、FTP 安全专题 | `DBSEC-001` |
| `OPS-NNN` | 运维或自动化流程问题 | `OPS-002` |
| `OPEN-NNN` | 已知但尚未处理或尚未验证的问题 | `OPEN-007` |
| `DOC` / `DOCSEC` | 文档调整或文档中的安全问题 | `DOC-005`、`DOCSEC-003` |
| `URL` / `VER` / `CHK` | 下载地址、组件版本、校验清单 | `URL-002`、`CHK-004` |
| `D-NNN` | 前期实现取舍的决策记录 | `D-005` |

三位数字只表示该前缀下的记录序号。跳号不代表缺项，例如 `GHA-008`
没有对应条目也不影响 `GHA-009`、`GHA-010` 的含义。历史 ID 与交叉引用均保留原样。

### 每条变更的字段含义

- **行为变化**：标明外部行为是否变化以及具体差异。
- **行号**：记录相关位置；删除操作同时记录修改前后的区间。
- **验证**：记录可重复执行的检查命令和结果。
- **验证状态**：静态检查通过写 `已验证（静态）`；在目标系统执行过写 `已实测`；
  本地尚未执行写 `待收尾验证`；需要真实密码、密钥或外部服务条件写
  `待人工真机验证`；结论或实现被修订写 `已返工`，并说明返工后的实际状态。

自动检查用于确认语法、静态模式和资源可用性；代码语义仍需结合实现复核。

### 范围与记录口径

- 本项目当前主线是 Debian 12、Nginx、PHP 8.3、MySQL 8.4、
  phpMyAdmin 5.2.1、Redis 与 WordPress 常用运维命令。
- Apache、其它发行版和非主线组合保留支持，但未专门实测时按低优先级记录，
  不能写成主线已通过。
- 发现的问题先写入 `todo.md` 的审计记录；修复并通过复验后，把实际结果写入本文档。
- 静态检查、函数级模拟、故障注入和完整实跑必须分别说明，不能互相替代。
- 文档只记录可复现的技术事实、范围、结果和遗留项，不写人员角色、回复指令或经验总结。

## 维护约定（改动本包前必读）

### 组件信任标准：官方域名的预编译二进制可接受

本项目判断一个组件能不能用，看的是：

1. 来源是不是该组件开发方的官方域名；
2. 有没有可核对的完整性凭据（静态清单、上游 SHA-256 或 PGP 签名）。

不以“有没有源码”“能不能复现构建”“是不是闭源”作为排除标准。
从官方域名取得的预编译二进制可以使用。

#### “官方域名”指组件开发方，不是本安装包的出品方

| 来源 | 含义 | 例子 | 判定 |
|---|---|---|---|
| 组件开发方官网 | 软件本身的开发方 | `nginx.org`、`www.php.net`、`cdn.mysql.com` / `dev.mysql.com`、`downloads.mariadb.org`、`archive.apache.org`、`archives.boost.io`、`files.phpmyadmin.net`、`pecl.php.net`、`ftp.gnu.org`、`www.ioncube.com` / `downloads.ioncube.com` | 可用 |
| 开发方认证的 GitHub 项目 | 上游自己维护的仓库 | `github.com/openssl/openssl`、`github.com/openresty/*`、`github.com/google/ngx_brotli`、`github.com/acmesh-official/acme.sh` | 可用 |
| 本安装包出品方的转存站 | 下游打包方转存组件 | `lnmp.org`、`vpser.net`、`soft.lnmp.com`、`soft.vpser.net`、`bbs.vpser.net` | 禁用 |
| 第三方镜像或加速站 | 非上游转手分发 | 各类 CDN 镜像、站长自建镜像 | 禁用 |

打包方不是组件开发方。LNMP 是这些组件的下游打包者，转存链路会增加一个
可以替换文件内容的位置。`SEC-DL-003`、`ACME-001`、`REPO-001` 的处理目标
就是改回组件上游来源。

`lnmp.org` 在本包里的两种出现性质不同：

- 代码注释里的出处署名、`lnmp` 命令启动横幅里的项目名可以保留；
- 下载源以及部署到用户站点页面上的可点击链接不保留，见 `SEC-WEB-003`。

因此，不再用“闭源、无源码、不可复现构建”单独排除组件。实际需要确认的是：
来源是否为组件上游、是否有校验值、`src/checksums.sha256` 是否按架构补齐。

### 编号只允许出现在 4 个文件

菜单编号只允许出现在 `include/profile.sh`、`include/main.sh`、
`include/multiplephp.sh`、`include/upgrade_mphp.sh`。

其余代码一律判断语义变量：`DB_Kind`（`mysql` / `mariadb` / `none`）、
`DB_Branch`、`PHP_Branch`、`PHP_Apache_Module` 等。增加版本、删除版本或重编号时，
安装主线只改 `include/profile.sh` 的映射表，并用 `t/lint.sh` 的 C1 检查。

### 改版本号必须做两件事

```bash
bash t/probe_urls.sh      # 确认新 URL 可达
bash t/gen_checksums.sh   # 重新采集哈希并更新 src/checksums.sha256
```

漏掉校验清单更新，fail-closed 校验会让安装在对应文件处中止。
多个上游只保留当前点版本，版本过期后 URL 可能直接返回 404；Apache 已通过
`URL-002` 改用归档源。

### 校验清单写“落地文件名”

清单写 `Download_Files` 的第二个参数，不是 URL 的 basename。GitHub tag 归档
尤其需要注意：URL 可以是 `v0.33.tar.gz`，落地文件可以是
`lua-resty-redis-0.33.tar.gz`，清单必须写后者。

### 防火墙操作只走 `include/firewall.sh`

不要直接调用 `nft` 或 `iptables`；`t/lint.sh` 的 C14 会拦截 `iptables`。
链的 policy 是 `accept`，原因见 `FW-001`。

### 版本比较使用 `Version_GE` / `Version_Compare`

不要用 `grep -Eqi '^8.[0-3].'` 这类正则划分版本区间。此类写法曾导致
PHP 8.4/8.5 落空，并会把 `8.10` 误判成 `8.1`。

```text
Version_GE a b       -> a >= b 返回 0
Version_Compare a b  -> 输出 0（相等）/ 1（大于）/ 2（小于）
```

### 下载后必须调用 `Require_File`

```bash
Download_Files <url> <filename>
Require_File "<filename>" "<描述>"
```

`Download_Files` 的返回值在部分调用点没有直接使用，`Require_File` 负责把
“下载失败但继续编译”变成明确失败。

后文若出现与本节冲突的历史说法，以本节为准。

---

## 改造前基线（2026-08-09 采集）

| 指标 | 数量 | 分布 |
|---|---|---|
| `DBSelect` / `PHPSelect` / `MPHP_Select` 出现次数 | 205 | 12 个文件 |
| `Download_Mirror` / 镜像域名引用 | 163 | 31 个文件 |
| 禁用域名（`lnmp.com`、`lnmp.org`、`vpser*.net`、`vpszt.*`） | 163 | 42 个文件 |
| `${DB_Info[}` / `${PHP_Info[}` / `${Apache_Info[}` 引用 | 141 | main.sh 109 + multiplephp.sh 32 |
| `src/patch/` 文件数 | 23 | — |
| 仓库文件总数 | 171 | — |

这些数字是进度指标。改造完成后期望值见「自检命令索引」。

---

## 复核结论（改造的起因）

### 未发现主动后门

逐项核查以下典型投毒特征，**均未发现**：

- 22 个 `.patch` 文件全部检查 — 均为正常编译兼容补丁（gcc8 类型转换、libxcrypt、
  icu70、openssl3.0、aarch64 汇编等），无代码注入
- `src/patch/mod_remoteip.c` 是 Apache 官方模块源码
- 无 base64 / gzinflate / str_rot13 混淆
- 无反弹 shell、`/dev/tcp`、`nc` 后门
- 无写 `authorized_keys`
- 无 crontab 后门（所有 crontab 操作都是**删除** certbot/acme 续期任务，
  且 acme.sh 那条本身还是注释掉的）
- `conf/ocp.php` 无 `eval` / `system` / `base64_decode`，是上游 ck-on/ocp.php
- `./configure` 参数干净，无可疑 `--add-module` 或 patch 注入

### 但供应链信任模型是失效的

这是改造的主要原因。风险不是「现在藏了恶意代码」，而是
**「这套机制让任何能劫持 HTTP 的人（包括镜像运营方本身）在任何时候都能推送任意二进制
到服务器上，而使用者没有任何检测手段」**。

| # | 问题 | 位置 |
|---|---|---|
| 1 | **SHA256 校验 100% 空转** — `src/checksums.sha256` 不存在时 `return 0`，而该文件在包内不存在（`src/` 下只有 `patch/`）。第二道在条目缺失时同样放行。ChangeLog 宣称的校验能力是空壳 | `include/main.sh:833,836` |
| 2 | **137 处 `Download_Files` 调用几乎都不检查返回值**，且全局无 `set -e`，下载失败会带着空文件继续编译 | 全仓库 |
| 3 | **核心组件全部使用项目维护方镜像** - nginx、PHP、Apache、MySQL 源码、OpenSSL、phpMyAdmin、pcre、Lua 组件 | `include/init.sh`, `nginx.sh` |
| 4 | **地理探测是可利用的降级链** — 用 `curl -sSk`（`-k` 硬编码跳过证书校验）从明文 HTTP 取一个字符串，该字符串控制 9 处分支。MITM 只需返回 `CN`，即可让 PHP 源码下载优先走明文 `http://php.vpszt.com` 而非 php.net | `include/main.sh:1018` → `addons.sh:254` |
| 5 | **拼接地址下载** — 从已下载的 MySQL 源码里 grep 出 boost 版本号再拼路径；`-DDOWNLOAD_BOOST=1` 让 cmake 自行联网下载，完全绕开本脚本的下载与校验通道 | `include/init.sh:767,773` |
| 6 | **管道直执远程代码** — `curl https://getcomposer.org/installer \| php --`，无 SHA384 校验（Composer 官方提供该校验方式） | `include/php.sh:222,234` |
| 7 | **`only.sh` 与 `init.sh` 是手工副本且已漂移** — only.sh 每个下载后有 `[ ! -s ]` 硬失败守卫，init.sh 没有。即 `./install.sh db` 下载失败会中止，`./install.sh lnmp` 下载失败会带空文件继续编译 | `only.sh:140-144` vs `init.sh:502-505` |
| 8 | **默认攻击面** — 每次安装往 web 根目录部署 `phpinfo.php`、`p.php`（来源不可审计的探针）、`ocp.php`、`phpmyadmin/`，且 `index.html` 主动链接它们 | `include/php.sh:1388-1419` |

### 无法回答的问题

**本包版本号自相矛盾**：目录名 `lnmp2.3`，但 `install.sh:18` 为 `LNMP_Ver='2.2'`，
ChangeLog 最新条目是 2.2，README 指向 `lnmp2.2.tar.gz`。

因明确的需求约束不下载 vpser.net 做比对，**「此包是否被第三方改动过」这个问题在本次改造中
无法回答**，只能通过「改完之后所有来源都是官方」来间接缓解。见「已知遗留问题」OPEN-002。

---

## 决策记录

> 只记「原因这样做」，不记「做了什么」。做了什么在变更条目里。

### D-001 先建间接层，再重编号

**背景** — 菜单编号散布在 205 处：29 处 `[[ "${DBSelect}" =~ ^(1|2|3|4|5|11)$ ]]` 式正则、
6 处 `echo "${PHPSelect}" | grep -Eqi` 式判断（只按 `=~` 搜索会全部漏掉）、5 处派发表、
141 处 `${DB_Info[n]}` / `${PHP_Info[n]}` 数组下标（0-based，而菜单是 1-based）。

**备选方案 A：直接重编号** — 需要在 29+ 处正则、5 处派发表、141 处数组下标之间保持一致。
任何中间 commit 都处于「新旧混用」状态且无法验证。off-by-one 不会报错，只会静默装错版本。

**备选方案 B：保持原编号不变，只删菜单项** — 风险最低，但菜单编号不连续。
用户明确选择了连续编号。

**选择：先建间接层（`include/profile.sh`）作为唯一的「编号 → 语义」映射表，
其余代码只判断 `DB_Kind`（mysql/mariadb/none）、`PHP_Branch` 等语义标识。**

理由：

1. **重编号从 O(散布) 降为 O(1)** — 最终只改一张表。
2. **裁剪后约 25 个编号判断站点变成恒真或恒假**，应被删除或常量折叠而非重编号。
   真正需要保留的映射只有 4~5 处。先建间接层能把这个事实暴露出来。
3. **四个既存 bug 同时消失且不会复发**（见 D-006）。
4. **产生了可测试的纯函数** — `profile.sh` 只有赋值无副作用，可在 Git Bash 里直接
   source 并断言。这是在 Windows 上验证重编号的唯一可行途径。
5. **阶段 1 具有「零行为变化」性质** — 黄金 trace 应逐字节相同。这把
   「间接层写对了吗」和「编号改对了吗」两个问题彻底分开。

**代价** — 一次性的转换风险：29 处正则改成 `DB_Kind` 判断时可能改反
（MySQL/MariaDB 弄颠倒）。缓解手段正是阶段 1 的零行为变化性质。

### D-002 数据库菜单按厂商分组，而非沿用旧相对顺序

旧编号的相对顺序是 5(MySQL8.0), 10(MariaDB10.11), 11(MySQL8.4), 12, 13，
直接平移会让菜单里 MySQL 和 MariaDB 交错，用户要在五行里来回跳才能看清有哪几个 MySQL。

沿用旧顺序的唯一好处是「便于对照旧编号做 diff」，而这个好处在引入 `DB_Kind` 之后
已经消失：代码不再关心编号是否按厂商连续。

**选择：按厂商分组、版本升序。**

### D-003 用 `case` 而非关联数组

关联数组需 bash 4.0+（2009）。裁剪后的目标发行版都满足（RHEL7 是 bash 4.2，
Ubuntu 18.04 是 bash 4.4），所以兼容性不是真问题。

但 `case` 方案同时具备：bash 3.2 兼容、与 `version.sh` 现有风格一致（diff 更小、
更易复核）、无 `declare -A` 作用域问题。**收益相同而约束更少，选 `case`。**

### D-004 only.sh 抽取共享函数，而非维护双份副本

不是「将来会漏改」，而是**已经漂移了**：`only.sh:140-144` 每个下载后有
`[ ! -s ]` 硬失败守卫，`init.sh:502-505` 没有。两份副本的存量差异本身就是一个
fail-open bug。

合并时**取 only.sh 的严格版**，这同时满足 fail-closed 目标（SEC-CHK-*）。

**不合并** `only.sh` 的 `DB_Dependent()` 与 `init.sh` 的 `CentOS_Dependent()`：
前者是 DB-only 场景的精简依赖集，后者是全栈依赖集，语义不同。
抽取时也不统一调用顺序，两条路径的依赖安装时机确实不同。

### D-005 upgrade 系列因域名约束强制纳入范围

原本倾向于把 upgrade 系列排除在外（范围可控）。但需求约束杜绝
`vpser*.net` / `vpszt.*` 域名，而 `upgrade_php.sh:36,43`、`upgrade_mphp.sh:132,139`
含 `php.vpszt.com`，`upgrade1.x-2.1.sh:199,315` 含 `soft.vpser.net`（acme.sh，
直接管理 TLS 私钥）。**不改无法满足约束**，故必须纳入。

既然纳入，就必须同步精简版本支持：否则 `lnmp upgrade` 会引导用户升级到已删除的版本，
而由于全局无 `set -e`，失败模式会极难诊断（错误发生点与报错点相隔数百行日志）。

### D-006 既存 bug 随语义化自动消失，不单独修

以下四个 bug 全部源于「用编号代替语义」。改成 `DB_Kind` 判断后自动消失，
且**不会复发**（加新版本时不需要记得更新某个编号集合）：

| bug | 位置 | 后果 |
|---|---|---|
| `Install_Boost` 只判断 `DBSelect=4/5`，漏了 11(MySQL 8.4) | `init.sh:766,781` | **MySQL 8.4 源码编译缺 `-DWITH_BOOST` 直接失败** |
| gcc-toolset-12 只判断 `DBSelect=5`，漏了 11 | `init.sh:411,426` + `only.sh:90,101` | EL9+ 上 8.4 源码编译拿不到工具链 |
| 清理 `${Boost_New_Ver}`(boost_1_67_0) 是死代码 | `end.sh:196-197` | 该变量从未用于下载；MySQL 8.0 走动态解析路径实际需要 boost 1.77，清理永远匹配不到 |
| MariaDB 10.11 只允许 x86_64，而 11.4/11.8 允许 aarch64 | `main.sh:257-285` | 架构白名单不一致 |

### D-007 `version_compare` 内联的理由是整洁，不是安全

初判时因「无扩展名 + 5280 字节」推断它可能是不可审计的二进制。
**读取内容后该前提不成立**：它是纯 Bash 脚本（Mark Carver 的 MIT 实现，
`version_compare()` + `version_compare_convert()`），完全可读可审计。

仍然内联，理由是：少一个外部可执行文件、少一次 fork、少一处 `chmod +x` 依赖。
**这是整洁性改进，不是安全修复**：记录于此以免日后误读。

### D-008 PHP 8.0 保留，故 `PHP_Openssl3_Patch` 必须保留

`Install_PHP_80` 与 `Install_PHP_81` 经逐字对比**完全相同，仅多一行
`PHP_Openssl3_Patch`**（`php.sh:1073`）。

故保留 PHP 8.0 意味着必须保留 `PHP_Openssl3_Patch()` 函数与
`src/patch/php-8.0-openssl3.0.patch`。该函数本身是「拼接路径」模式
（`php-${PHP_Short_Ver}-openssl3.0.patch`），需确保 8.0 是唯一可能取值。

---

## 编号映射总表

> **复核的第一入口。任何编号相关疑问先查这里。**

### 数据库

> 版本号随 VER-001 升级过，下表是 **2026-08-08 的当前值**；
> 权威来源始终是 `include/profile.sh` 的 `Set_DB_Profile`，本表仅供阅读。

| 新 | 旧 | 版本 | DB_Kind | 安装函数 | 备注 |
|----|----|------|---------|---------|------|
| 1 | 5 | MySQL 8.0.46 | mysql | `Install_MySQL_80` | 需 Boost；二进制仅 glibc2.28 |
| **2** | 11 | **MySQL 8.4.7 LTS** | mysql | `Install_MySQL_84` | **默认** / 需 Boost；二进制仅 glibc2.17-x86_64 |
| 3 | 10 | MariaDB 10.11.18 | mariadb | `Install_MariaDB_1011` | 唯一真实实现 |
| 4 | 12 | MariaDB 11.4.12 LTS | mariadb | `Install_MariaDB_114` | wrapper → 1011 |
| 5 | 13 | MariaDB 11.8.8 LTS | mariadb | `Install_MariaDB_118` | wrapper → 1011 |
| 0 | 0 | 不安装 | none | — | |
| — | 1 | MySQL 5.1.73 | — | 已删除 | DEL-DB-001 |
| — | 2 | MySQL 5.5.62 | — | 已删除 | DEL-DB-001 |
| — | 3 | MySQL 5.6.51 | — | 已删除 | DEL-DB-001 |
| — | 4 | MySQL 5.7.44 | — | 已删除 | DEL-DB-001 |
| — | 6 | MariaDB 5.5.68 | — | 已删除 | DEL-DB-002 |
| — | 7 | MariaDB 10.4.33 | — | 已删除 | DEL-DB-002 |
| — | 8 | MariaDB 10.5.24 | — | 已删除 | DEL-DB-002 |
| — | 9 | MariaDB 10.6.25 | — | 已删除 | DEL-DB-002 |
| — | — | MariaDB 10.3 | — | 已删除（**原本就是死代码**，`mariadb.sh:208-309` 无任何调用点） | DEL-DB-003 |

### PHP

> 版本号随 VER-001 升级过，下表是 **2026-08-08 的当前值**；
> 权威来源始终是 `include/profile.sh` 的 `Set_PHP_Profile`，本表仅供阅读。

| 新 | 旧 | 版本 | 安装函数 | 备注 |
|----|----|------|---------|------|
| 1 | 11 | PHP 8.0.30 | `Install_PHP_80` | 需 openssl3.0 patch；已 EOL |
| 2 | 12 | PHP 8.1.34 | `Install_PHP_81` | 已 EOL |
| 3 | 13 | PHP 8.2.33 | `Install_PHP_82` | |
| **4** | 14 | **PHP 8.3.33** | `Install_PHP_83` | **默认** |
| 5 | 15 | PHP 8.4.24 | `Install_PHP_84` | |
| 6 | 16 | PHP 8.5.9 | `Install_PHP_85` | |
| — | 1..5 | PHP 5.2 / 5.3 / 5.4 / 5.5 / 5.6 | 已删除 | 随 php.sh 1445→383 一并裁剪 |
| — | 6..10 | PHP 7.0 / 7.1 / 7.2 / 7.3 / 7.4 | 已删除 | 同上 |

上面六个 `Install_PHP_8x` **全部是同一个函数的 wrapper**：

```bash
Install_PHP_80() { Install_PHP_8x; }   # 80 到 85 六个都是这一行
```

版本差异已全部下沉到 `profile.sh` 的 `Php_Ver` 与 `PHP_Branch`，
函数本身不再有分支。保留六个名字只是为了让 `profile.sh` 的
`PHP_Install` 字段有一个可派发的目标，`t/test_dispatch.sh` 会检查它们真实存在。

### Apache

| 新 | 旧 | 版本 | 备注 |
|----|----|------|------|
| — | 1 | Apache 2.2.34 | 已删除（2017 EOL）/ DEL-APA-001；安装函数亦已删除，见 CLN-206 |
| （无选择） | 2 | Apache 2.4.68 | 唯一选项，`Apache_Selection()` 塌缩 |

### 注意：旧编号必须显式拒绝

原 `main.sh:376-379` 的 `*)` 分支是**静默回退到默认值**。重编号后若有人沿用
`DBSelect=12` 调用（例如已有的自动化脚本），会得到 MySQL 8.4 而非期望的
MariaDB 11.4，**且无任何警告**。

已改为报错退出并打印新旧对照表。见 REN-DB-002。

---

## 变更条目

> 按实施阶段分组。阶段 1 的所有条目「行为变化」应为"无"。

### 阶段 0 — 建立基线

（无代码变更，仅采集基线数据与创建本文档）

---

### REF-DB-001 新建 include/profile.sh 作为唯一编号映射表

- **文件**：`include/profile.sh`（**新建**，约 330 行）
- **类别**：REF 结构重构
- **内容**：`DB_Info` / `PHP_Info` / `Apache_Info` 三个菜单数组、
  `Set_DB_Profile` / `Set_PHP_Profile` / `Set_Apache_Profile` 三张 case 映射表、
  `Dispatch` 派发守卫、`DB_Bin_Available` / `Select_DB_Bin` / `Print_DB_Menu` /
  `Print_PHP_Menu` / `Legacy_Selection_Hint` 辅助函数、三个数组长度断言。
- **理由**：见 D-001。编号只在此文件与两处菜单读取点出现，其余代码改判语义变量。
- **行为变化**：无（阶段 1 时保留完整旧映射 DB 1..13 / PHP 1..16）
- **验证**：`bash t/test_profile.sh`
- **验证状态**：已验证

### REF-DB-002 version.sh 移除编号映射

- **文件**：`include/version.sh`
- **行号**：改前 28-103 / 改后 28-40
- **改动**：删除 `Mysql_Ver` / `Mariadb_Ver`（13 分支）、`Php_Ver`（16 分支）、
  `PhpMyAdmin_Ver`（3 分支）、`Apache_Ver`（2 分支）共 76 行条件赋值，
  改由 `profile.sh` 提供；保留与选择无关的组件版本（Nginx_Ver / Openssl_Ver 等）。
- **行为变化**：无
- **注意**：`version.sh` 原本在 `Press_Install()` 内被**延迟 source**（`main.sh:643`），
  这是它能读到 `${DBSelect}` 的原因。现在 `profile.sh` 在 `install.sh` 顶部
  source，映射由 `Set_*_Profile` 在菜单选择后调用填充。
- **验证状态**：已验证

### REF-DB-003 Database_Selection 折叠

- **文件**：`include/main.sh`
- **行号**：改前 7-379（373 行）/ 改后 7-43（37 行）
- **改动**：13 个逐字重复的 case 分支（差异仅为版本名、支持二进制的架构、
  未输入时的默认策略三项）折叠为 `Print_DB_Menu` + `Set_DB_Profile` + `Select_DB_Bin`。
  三项差异下沉为 `DB_Bin_Archs` / `DB_Bin_Default` / `DB_Note` 字段。
- **行为变化**：无
- **净删**：336 行
- **验证状态**：已验证

### REF-PHP-001 PHP_Selection 折叠

- **文件**：`include/main.sh`
- **行号**：改前 77-158 / 改后 77-97
- **改动**：16 个 case 分支（只做回显）折叠。PHP 5.2 需要数据库这一唯一约束
  下沉为 `PHP_Needs_DB` 字段。
- **行为变化**：无
- **验证状态**：已验证

### REF-DB-004 29 处编号正则改判语义

- **文件**：`include/end.sh`(10) `include/main.sh`(7) `include/only.sh`(6)
  `include/init.sh`(2) `include/mysql.sh`(2) `include/mariadb.sh`(2)
- **改动**：`[[ "${DBSelect}" =~ ^(1|2|3|4|5|11)$ ]]` → `[ "${DB_Kind}" = "mysql" ]`，
  `^(6|7|8|9|10|12|13)$` → `[ "${DB_Kind}" = "mariadb" ]`，`= "0"` → `= "none"`。
  `end.sh` 三个 `Add_*_Startup` 里逐字相同的数据库启动块合并为 `Startup_DB()`。
- **行为变化**：无
- **验证**：`bash t/lint.sh C1` 应零输出
- **验证状态**：已验证

### REF-PHP-002 php.sh 版本判断改用 Cur_PHP_Branch

- **文件**：`include/php.sh`
- **改动**：新增 `Cur_PHP_Branch()`（统一三条输入路径：`PHP_Branch` / `php_version` /
  `Php_Ver`）。`PHP_with_openssl` / `PHP_with_Sodium` / `PHP_with_Intl` /
  `Install_Composer` / `Creat_PHP_Tools` 五处 `grep -Eqi "^[数字范围]"` 式判断
  改为版本号比较。
- **行为变化**：**有**：见 FIX-PHP-001。
- **验证状态**：已验证

### FIX-PHP-001 修复 PHP_with_Sodium 的坏正则

- **文件**：`include/php.sh`
- **行号**：改前 125 / 改后 100-121（`PHP_with_Sodium()` 全体）
- **改前**：`echo "${PHPSelect}" | grep -Eqi "^[8-9]|1[0-2]$"`
- **改后**：**版本判断整个去掉**，`Enable_PHP_Sodium != n` 时无条件设
  `with_sodium='--with-sodium'`
- **问题**：交替 `|` 未加括号，实际语义是「`^[8-9]` **或** `1[0-2]$`」而非
  「`^([8-9]|1[0-2])$`」。旧编号 13~16（PHP 8.2/8.3/8.4/8.5）两侧都不匹配，
  落入 else 分支打印"请用 addons.sh 安装 sodium"，`--with-sodium` 从未传给 configure。
- **原因不是改成正确的版本判断**：sodium 从 PHP 7.2 起内建，而本包保留的
  版本全部是 8.x，判断恒为真：留着一个永远成立的条件只会让人以为还有别的分支。
  函数头部的注释写明了这一点，将来若重新引入 < 7.2 的版本需要把判断加回来。
- **行为变化**：**有**：PHP 8.2+ 且 `Enable_PHP_Sodium=y` 时现在会正确编译 sodium 扩展。
- **验证状态**：已验证
  （2026-08-08 内部复查：原条目「改后」写的是
  `Version_GE "$(Cur_PHP_Branch)" 7.2`，与实际代码不符，行号也已漂移，此处已订正。）

### FIX-DB-001 修复 MySQL 8.4 源码编译缺 Boost

- **文件**：`include/init.sh`
- **行号**：改前 719-761 / 改后 719-810
- **问题**：`Download_Boost` 判断 `DBSelect=4/5`、`Install_Boost` 判断 `DBSelect=4/5`，
  都漏了 11（MySQL 8.4）。8.4 + `Bin=n` 时两个分支都不进，`MySQL_WITH_BOOST` 保持空，
  cmake 缺 `-DWITH_BOOST` 直接编译失败。
- **改动**：改由 `DB_Boost_Mode`（pinned/auto）驱动，升级路径回退到解析 `mysql_version`。
- **行为变化**：**有**：MySQL 8.4 源码编译从必然失败变为可用。
- **返工（2026-08-09）**：原结论「MySQL 8.4 源码编译从必然失败变为可用」当时**不成立**。
  `auto` 模式从 `cmake/boost.cmake` 解析出的 boost（8.0.46 要 1.77.0、8.4.7 要 1.84.0）
  一条都不在当时的 `src/checksums.sha256` 里（清单只有 1.59 / 1.67），
  fail-closed 会在下载校验处中止：缺 `-DWITH_BOOST` 的失败只是换了个位置发生。
  本阶段补齐：清单换成 1_77_0 / 1_84_0 的官方值（见 `CHK-004`），
  下载改走 `Download_Verified boost`（见 `VERIFY-001`），
  同时删掉不可达的 `pinned` 分支（见 `CLN-302`）。
- **验证状态**：待收尾验证（MySQL 8.4 主线使用官方二进制，源码编译路径尚未实跑；2026-08-11 复核）。

### FIX-DB-002 修复 EL9+ 上 MySQL 8.4 缺 gcc-toolset-12

- **文件**：`include/init.sh`(2 处) `include/only.sh`(2 处) → `include/dbcommon.sh`
- **问题**：四处均只判断 `DBSelect=5`，漏了 11。
- **改动**：抽取为 `DB_Toolchain_EL9()`，改判 `DB_Kind = mysql`。
- **行为变化**：**有**：MySQL 8.4 在 EL9/EL10/Oracle9 上源码编译现在能拿到工具链。
- **验证状态**：待收尾验证（EL9+ 非当前 Debian 12 主线，尚无真机编译记录；2026-08-11 复核）。

### FIX-DB-003 移除 Boost_New_Ver 死清理

- **文件**：`include/end.sh`
- **行号**：改前 186-199 / 改后 158-172
- **问题**：`Clean_DB_Src_Dir` 按 `DBSelect=5` 清理 `${Boost_New_Ver}`(boost_1_67_0)，
  但该变量**从未用于下载**：MySQL 8.x 走 `init.sh` 的动态解析路径，
  实际需要的是 boost 1.77，所以这条清理永远匹配不到真实目录。
- **改动**：改为清理 `${Get_Boost_Ver}` 实际解析出的目录。
- **行为变化**：**有**：boost 源码目录现在会被真正清理。
- **验证状态**：已验证

### FIX-DB-004 修复 MySQL_Gcc7_Patch 的 gcc 版本正则

- **文件**：`include/mysql.sh`
- **改前**：`gcc -dumpversion | grep -Eq "^[7-9]|10"`
- **改后**：~~`grep -Eq "^[7-9]|1[0-9]"`~~：**该修正最终没有留在代码里**：
  `MySQL_Gcc7_Patch` 函数服务的是 MySQL 5.1，随 DEL-DB-001 整个删除了。
  现在全仓库搜不到这个函数名，复核时不必去找。
- **问题**：`10` 未锚定，且 gcc 11+ 不匹配。
- **行为变化**：**无实际影响**（函数已不存在）
- **验证状态**：已验证
  （2026-08-08 内部复查：原「改后」写的正则指向一个已被删除的函数，
  会让复核者去找一个找不到的东西，此处已订正。）

### SEC-DL-001 移除 -DDOWNLOAD_BOOST=1

- **文件**：`include/init.sh`
- **行号**：改前 741 / 改后 —（已删除）
- **问题**：兜底分支用 `-DDOWNLOAD_BOOST=1` 让 cmake 自行联网下载 boost，
  **完全绕开本脚本的下载与校验通道**，是一条不受控的外部获取路径。
- **改动**：改为强制显式下载 + `Require_File` 守卫；boost 改从
  `https://archives.boost.io/release/<ver>/source/` 官方获取。
  对从源码树 grep 出的版本号增加 `^[0-9]+_[0-9]+_[0-9]+$` 格式校验
  （这是「下载内容驱动后续下载」的拼接点）。
- **行为变化**：**有**：无法下载 boost 时从静默交给 cmake 变为明确报错。
- **验证**：`bash t/lint.sh C12` 应零输出
- **验证状态**：已验证

### REF-DUP-001 消除 only.sh 与 init.sh 的下载副本

- **文件**：`include/dbcommon.sh`（**新建**）、`include/init.sh`、`include/only.sh`
- **行号**：`init.sh` 改前 499-527 / `only.sh` 改前 135-183（109 行）→ 各自一行调用
- **改动**：抽取 `DB_Download_Files()`、`Require_File()`、`DB_Bin_Glibc_Ver()`、
  `DB_Toolchain_EL9()`。**取 only.sh 的严格版**（带 `[ ! -s ]` 硬失败守卫）。
  新增 `DB_Bin_Tarball` 变量，供安装函数解包时复用，消除文件名两处各拼一遍的漂移。
- **行为变化**：**有**：`./install.sh lnmp` 路径下载失败现在会中止而非带空文件继续编译
  （这正是 D-004 要修的 fail-open）。
- **验证**：`bash t/lint.sh C4`
- **验证状态**：已验证

### SEC-DL-002 数据库源码包改走官方源

- **文件**：`include/dbcommon.sh`
- **改前**：`${Download_Mirror}/datebase/mysql/${Mysql_Ver}.tar.gz`（站长镜像）
- **改后**：`https://cdn.mysql.com/Downloads/MySQL-${DB_Branch}/`，
  失败回退 `https://cdn.mysql.com/archives/mysql-${DB_Branch}/`
- **行为变化**：**有**：源码包来源从站长镜像改为 MySQL 官方 CDN。
- **验证状态**：已验证

### REN-DB-001 / REN-PHP-001 / REN-APA-001 重编号

- **文件**：`include/profile.sh`（仅此一处）+ `include/main.sh` 默认值
- **改动**：DB 13→5 项、PHP 16→6 项、Apache 2→1 项，编号连续化。
  默认值 `DBSelect` 11→2、`PHPSelect` 14→4、`ApacheSelect` 2→1。
- **关键**：因 D-001 的间接层，这一步**只改了一张表**，
  29 处正则与 141 处数组下标无需改动。
- **行为变化**：**有**：菜单编号变更，见「编号映射总表」。
- **验证状态**：已验证

### REN-DB-002 旧编号显式拒绝

- **文件**：`include/profile.sh`（`Legacy_Selection_Hint`）、`include/main.sh`（`Invalid_Selection`）
- **问题**：原 `main.sh:376-379` 的 `*)` 分支**静默回退到默认值**。重编号后
  沿用旧值的自动化脚本（如 `DBSelect=12` 本想装 MariaDB 11.4）会静默得到 MySQL 8.4。
- **改动**：超出范围的编号报错退出并打印新旧对照。
- **行为变化**：**有**：从静默回退改为硬失败。
- **返工（2026-08-09）**：原结论「超出范围的编号报错退出」**不成立**：
  `Invalid_Selection` 只负责打印，调用点没有把它变成真正的退出，
  空输入与非法输入也没有分开处理（直接回车同样落进"非法"提示）。
  已由 `FIX-SEL-001` 重做为真正的硬失败 + 空/非法分流。
- **验证状态**：已验证，见阶段 11 `GHA-007` 与阶段 15 `t/test_profile.sh` 回归（2026-08-11 复核）。

### DEL-DB-001 / DEL-DB-002 / DEL-DB-003 删除旧数据库安装函数

- **文件**：`include/mysql.sh` 897→356 行；`include/mariadb.sh` 748→222 行
- **删除**：`Install_MySQL_51/55/56/57`、`Install_MariaDB_5/103/104/105/106`
- **注**：`Install_MariaDB_103` **原本就是死代码**，全仓库无任何调用点。
- **连带删除**：`MySQL_ARM_Patch`、`MySQL_Gcc7_Patch`（仅服务 5.1/5.5）、
  `MariaDB_WITHSSL` 的 OpenSSL 1.0 分支（仅服务 10.0/10.1/10.4）、
  `MySQL_Sec_Setting` / `Mariadb_Sec_Setting` 里的旧密码语法分支。
- **行为变化**：**有**：这些版本不再可安装。
- **验证**：`bash t/lint.sh C6` 应零输出
- **验证状态**：已验证

### DEL-APA-001 删除 Apache 2.2

- **文件**：`include/profile.sh`、`include/main.sh`
- **改动**：`Apache_Info` 缩为 1 项；`Apache_Selection()` 不再询问（单选项）；
  PHP 5.2 与 Apache 2.4 不兼容的特判随 PHP 5.2 一并删除。
- **待删文件**：`src/patch/mod_remoteip.c`、`conf/httpd22-lamp.conf`、
  `conf/httpd22-lnmpa.conf`、`conf/httpd22-ssl.conf`、`include/apache.sh` 的
  `Install_Apache_22()`
- **行为变化**：**有**
- **验证状态**：已验证

### REF-APA-001 apache.sh 模块名判断语义化

- **文件**：`include/apache.sh`
- **行号**：52, 126
- **改前**：`[[ "${PHPSelect}" =~ ^([6-9]|1[0-6])$ ]]`
- **改后**：`[ "${PHP_Apache_Module}" != "libphp5.so" ]`
- **行为变化**：无
- **验证状态**：已验证

### REF-END-001 Check_Apache_Files / Check_DB_Files 收敛

- **文件**：`include/end.sh`
- **改动**：`Check_Apache_Files` 三分支（libphp5/libphp7/libphp.so）收敛为
  `${PHP_Apache_Module}`；`Check_DB_Files` 双分支收敛为 `${MySQL_Dir}` + `${DB_Kind}`。
- **行为变化**：无
- **验证状态**：已验证

### REF-MAIN-001 新增 Version_GE

- **文件**：`include/main.sh`
- **改动**：新增 `Version_GE <a> <b>`（基于 `sort -V`），替代按菜单编号划定版本区间。
  `Check_CMPT()` 的三处编号判断改用它。
- **注意**：`sort -V` 能正确处理 10.11 > 8.0（字典序会出错），
  测试用例已覆盖该陷阱。
- **行为变化**：无
- **验证状态**：已验证

### REF-TEST-001 新增验证脚本

- **文件**：`t/lint.sh`、`t/test_profile.sh`、`t/test_dispatch.sh`（**新建**）
- **内容**：见「自检命令索引」。`test_profile.sh` 含菜单文本与映射表一致性检查
  （捕获"改了表忘了改菜单"）；`test_dispatch.sh` 用 `declare -f` 验证每个编号
  指向的函数与配置文件真实存在。
- **行为变化**：无（仅新增测试）
- **验证状态**：已验证

### SEC-GEO-001 移除地理探测（降级攻击链）

- **文件**：`include/main.sh`（`Get_Country` / `Check_Mirror` 定义）、
  `addons.sh:254`、`include/init.sh`(2 处)、`include/imageMagick.sh`、
  `include/upgrade_php.sh`(2 处)、`include/upgrade_mphp.sh`
- **类别**：SEC 安全加固
- **问题**：`Get_Country()` 用 `curl -sSk`（`-k` **硬编码跳过证书校验**）从
  **明文** `http://ip.vpszt.com/country` 取一个字符串，该字符串控制 9 处分支。
  其中 `addons.sh:254` / `upgrade_php.sh:35` / `upgrade_mphp.sh:131` 的语义是
  「country=CN 时，PHP 源码**优先**从明文 `http://php.vpszt.com` 下载，
  php.net 只作兜底」。
- **攻击链**：中间人篡改 `ip.vpszt.com` 的明文响应为 `CN`
  → 后续 PHP 源码下载走明文 HTTP → 中间人替换 tarball
  → 用户亲手编译并以 root 安装。**全程无任何校验**。
- **改动**：删除 `Get_Country()` 与 `Check_Mirror()`（后者本就是死代码：
  只在 `Download_Mirror == 'https://soft.vpser.net'` 时触发，而默认值不是它）；
  固定 `country='US'`；9 处 `= "CN"` 分支全部删除；
  PHP 源码下载改为只走 `https://www.php.net/distributions/`。
- **行为变化**：**有**：国内服务器下载会变慢（这是换官方源的固有代价）。
- **验证**：`bash t/lint.sh C8` 应零输出
- **验证状态**：已验证

### SEC-CHK-001 校验改为 fail-closed

- **文件**：`include/main.sh`（`Verify_Download_File`）
- **行号**：改前 427-455 / 改后 427-486
- **问题**：旧实现存在两处 fail-open 提前返回：
  `[ ! -s "${Checksum_File}" ] && return 0`（清单不存在即放行）与
  `[ "${Expected_SHA256}" = "" ] && return 0`（条目不存在即放行）。
  而 `src/checksums.sha256` **在包内不存在**，于是校验 100% 空转。
  README/ChangeLog 宣称的"支持 SHA256 校验"从未生效过。
- **改动**：三种失败（清单缺失、条目缺失、哈希不匹配）一律 `exit 1` 并删除文件；
  `Download_Insecure='y'` 时增加显式告警。
- **行为变化**：**有，且影响很大**：见下方「注意：阻断性提醒」。
- **验证**：`bash t/lint.sh C11` 应零输出
- **返工（2026-08-09 二轮）**：**结构上做对了，但"fail-closed"当时并没有真正闭合。**
  本条只改了 `Verify_Download_File` 内部的三条早退，没管**外面**：
  1. 有 **6 处调用点**在外面套了 `if [ ! -s <文件> ]`，文件已存在时整个下载+校验
     函数不执行：缓存文件全程免检；
  2. `Enable_Download_Checksum != 'y'` 时是**静默 `return 0`**，
     关掉校验跑完全程一个字都不提示。
  两条都由 `SEC-CACHE-001` 修掉。
  另：行号「改前 427-455 / 改后 427-486」已漂移（`Verify_Download_File`
  现在在 `include/main.sh:504`）。
- **验证状态**：已验证，见阶段 14 全新安装及阶段 15 主线验收（2026-08-11 复核）。

### SEC-DL-003 下载源改上游官方 + 删除 Download_Mirror

- **文件**：`lnmp.conf`、`include/init.sh`、`include/nginx.sh`、
  `include/dbcommon.sh`、`include/main.sh`
- **改动**：

  | 组件 | 改后来源 |
  |---|---|
  | nginx | `https://nginx.org/download/` |
  | PHP | `https://www.php.net/distributions/` |
  | MySQL | `https://cdn.mysql.com/Downloads/MySQL-<branch>/` |
  | MariaDB | `https://downloads.mariadb.org/rest-api/mariadb/` |
  | Apache/APR | `https://downloads.apache.org/` |
  | OpenSSL | `https://github.com/openssl/openssl/releases`，回退 openssl.org |
  | phpMyAdmin | `https://files.phpmyadmin.net/phpMyAdmin/` |
  | libiconv | `https://ftp.gnu.org/gnu/libiconv/` |
  | mhash / pcre | `https://downloads.sourceforge.net/` |
  | jemalloc / gperftools / libunwind / Lua 组件 / ngx-fancyindex | 各自 GitHub 官方 release |
  | boost | `https://archives.boost.io/release/` |

- **连带**：`lnmp.conf` 删除 `Download_Mirror` 变量；
  `Check_LNMPConf` 去掉对它的非空校验（否则安装直接起不来）；
  `Print_APP_Ver` 改印 "upstream official only"。
- **行为变化**：**有**
- **验证**：`bash t/lint.sh C7`
- **返工（2026-08-09）**：原结论「下载源全部改上游官方」**范围写窄了**。
  上表列的全是**组件源码包**，漏掉了两类同样「下载后立即执行/生效」的取用：
  1. `acme.sh` 仍从 `vpser.net` 取并直接 `sh` 执行：见 `ACME-001`；
  2. RHEL/CentOS 的 `.repo` 配置仍从第三方镜像取：见 `REPO-001`。
  这两类的危害比源码包更大：一个是直接执行远程代码，一个决定此后**所有** yum 包的来源。
  另外「删除 `Download_Mirror`」时在 `lnmp.conf` 里把 `CheckMirror` 写成了直接赋值，
  反而废掉了环境变量覆盖，由 `FIX-CONF-002` 修正。
- **验证状态**：已验证，见阶段 11 `GHA-009` 与阶段 15主线安装、URL/校验回归（2026-08-11 复核）。

### FIX-DL-001 nginx 版本号被迫升级

- **文件**：`include/version.sh`
- **改前**：`Nginx_Ver='nginx-1.30.0'`
- **改后**：`Nginx_Ver='nginx-1.30.4'`
- **原因**：**nginx.org 只保留每个分支的最新点版本**，1.30.0 已下线，
  该分支现为 1.30.4。这是"改用官方源"的一个实际后果：
  镜像会保留历史点版本，官方不会。
- **影响**：今后每次 nginx 官方发新点版本，本项目必须同步跟进，
  否则下载会 404。**这是换官方源的长期维护成本，需要知悉。**
- **行为变化**：**有**：安装的 nginx 版本从 1.30.0 变为 1.30.4
- **验证状态**：已验证

### SEC-DL-004 Composer 安装不再管道直执

- **文件**：`include/php.sh`（`Install_Composer`）
- **改前**：`curl -sS https://getcomposer.org/installer | php -- ...`
  （管道直执远程代码，无任何校验）；另有一条从站长镜像取 `composer-2.2.phar`
  直接 `chmod +x` 放进 `/usr/local/bin`。
- **改后**：先下载 installer → 取 `https://composer.github.io/installer.sig`
  的官方 SHA384 → 核对 → 不匹配则拒绝执行并删除。
- **行为变化**：**有**：无法获取签名时拒绝安装 composer（原先会照装不误）。
- **返工（2026-08-09）**：校验逻辑本身没错，**错在失败处理**。
  `Install_Composer` 是被 source 进来的，里面的 `exit 1` 终止的是**整个安装脚本**，
  不是只跳过 composer。于是"取不到官方签名"这种网络抖动，
  就能让 PHP 安装与 PHP 升级整体中止：比原先"照装不误"更糟。
  已由 `FIX-CMP-001` 重做为独立下载通道 + `return 1`。
- **验证状态**：已验证，见阶段 14 Debian 12 全新安装（2026-08-11 复核）。

### SEC-WEB-001 / SEC-WEB-002 减少默认攻击面

- **文件**：`include/php.sh`（`Creat_PHP_Tools`）、`include/init.sh`、
  `include/opcache.sh`、`lnmp.conf`
- **改前**：每次安装无条件往网站根目录部署 `phpinfo.php`、`p.php`、
  `ocp.php`、`phpmyadmin/`，且 `conf/index.html` 主动链接它们。
- **改动**：
  - **删除 `p.tar.gz` 探针**：无上游官方来源、内容不可审计
  - **删除 `ocp.php` 部署**：泄露完整缓存文件路径列表（等于暴露应用目录树）
  - `phpinfo.php` / phpMyAdmin 改为 `lnmp.conf` 开关，**默认关闭**
    （新增 `Enable_PHPInfo_Page='n'` / `Enable_PhpMyAdmin='n'`）
  - phpMyAdmin 的 `blowfish_secret` 改用 `/dev/urandom` 生成
    （原先用 `date +%s%N` 拼固定字符串，可预测）
- **行为变化**：**有**：默认不再有 phpinfo / 探针 / phpMyAdmin。
- **验证**：`bash t/lint.sh C5`
- **验证状态**：已验证

### SEC-DOM-001 随机密码不再含禁用域名

- **文件**：`include/main.sh`
- **改前**：`DB_Root_Password="lnmp.org#$RANDOM"`
- **改后**：`DB_Root_Password="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"`
- **附带收益**：`$RANDOM` 只有 15 bit 熵且可预测，改用 `/dev/urandom` 后为 96 bit。
- **行为变化**：**有**：随机密码强度显著提高，格式改变。
- **验证状态**：已验证

### REF-VER-001 version_compare 内联

- **文件**：`include/main.sh`（新增 `Version_Compare`）、
  `include/nginx.sh`(3 处)、`include/upgrade_nginx.sh`(2 处)、
  `include/upgrade_mysql.sh`(1 处)
- **改动**：外部可执行文件 `include/version_compare` 内联为 `Version_Compare()`，
  输出语义保持一致（0=相等 / 1=大于 / 2=小于）。6 处调用点全部替换。
- **行为变化**：无
- **验证状态**：已验证

---

### 阶段 6 — 在 Debian 12 实机验证（2026-08-08）

> 本阶段起，验证环境是 VMware 本地虚拟机 Debian 12 bookworm（`root@<验证机IP>`，
> 2 核 / 2GB 内存 / 19G 磁盘），已配置免密 SSH。此前所有「未验证」的推导都在这里
> 被逐条实测，结论写在各条目的「实测」字段里。

### CLN-201 删除 XCache_Ver 变量

- **文件**：`include/version.sh:45`
- **改动**：删除 `XCache_Ver='xcache-3.2.0'`。`xcache.sh` 已删，该变量无人引用。
- **行为变化**：无
- **验证状态**：已验证

### CLN-202 opcache.sh 去掉 eAccelerator 残留提示

- **文件**：`include/opcache.sh:6,10`
- **改动**：删除 `Install Opcache will auto uninstall eAccelerator if exists...`
  与 `echo "Uninstall eAccelerator..."`。
- **注意**：紧随其后的 `rm -f ${PHP_Path}/conf.d/004-opcache.ini` **保留**：
  它删的是旧 opcache 配置，与 eAccelerator 无关，原提示文本本身就是错位的。
  已改写注释说明其真实用途。
- **行为变化**：仅提示文本
- **验证状态**：已验证

### CLN-203 addons.sh 拒绝提示改为不点名措辞

- **文件**：`addons.sh:319-320`
- **改动**：原提示逐个点名 eAccelerator / XCache / SourceGuardian，含被 lint C5
  拦截的字面量。改为一行通用说明；用户输入的名字由 `${action2}` 回显，信息不丢失。
- **理由**：保持 C5 严格（只要出现这些组件名就报），而不是为了放行而放宽检查口径。
- **行为变化**：仅提示文本
- **验证状态**：已验证

### CLN-204 删除 Check_Mirror 空函数及其调用

- **文件**：`include/main.sh:653-660`（删除函数）、`install.sh:69`（删除调用）
- **改动**：`Check_Mirror()` 函数体自 SEC-DL-003 起就是 `:`（空操作），保留它
  只是为了不动调用点。现在连同调用一起删除，原位置留注释说明去向。
- **注意**：`install.sh` 里包住它的 `if [ "${CheckMirror}" != "n" ]` 判断**保留**，
  因为同一个 if 里还有 `Modify_Source`。同时发现 `CheckMirror` 这个变量
  **全仓库只有读取、没有任何赋值**，即该条件恒为真：属既存问题，未在本阶段改动。
- **行为变化**：无
- **验证状态**：已验证

---

### URL-001 全部下载 URL 首次实测，修正 10 个 404

- **文件**：`t/probe_urls.sh`（**新建**）、`include/version.sh`、`include/profile.sh`、
  `include/init.sh`、`include/dbcommon.sh`、`include/apache.sh`、
  `include/imageMagick.sh`、`tools/fail2ban.sh`
- **类别**：FIX 缺陷修复
- **背景**：改造把下载源全部换成上游官方，但 URL 多是**按各项目命名规律推导**的，
  从未实际请求过。交接文档把这一整批列为「未验证项」。
- **做法**：新建 `t/probe_urls.sh`，只发 HEAD 请求（`wget --spider`）逐条探测，
  不下载、不改动系统。首轮 57 条中 **10 条 404**，逐个查证上游实际发布路径后修正。

修正明细：

| 组件 | 原值 | 问题 | 改为 |
|---|---|---|---|
| MySQL 8.4 | `mysql-8.4.8` | 该版本不存在 | `mysql-8.4.7` |
| MySQL 二进制 | `glibc2.12` | 已全部下线 | 8.0 用 `glibc2.28`，8.4 用 `glibc2.17` |
| Apache httpd | `2.4.67` | 已被 2.4.68 取代下线 | `2.4.68` |
| APR | `1.7.4` | 同上 | `1.7.6` |
| APR-util | `1.6.3` | 同上 | `1.6.4` |
| phpMyAdmin | 目录名拼成 `5.2.3-all-languages` | **URL 构造 bug** | 目录名只用版本号 `5.2.3` |
| ImageMagick | `imagemagick.org/archive/releases/` | 只留近期版本，7.1.1-8 已下线 | GitHub tag 归档，升至 `7.1.2-29` |
| pure-ftpd | `1.0.49` | 已下线 | `1.0.54` |
| fail2ban | tag `1.0.3` | 不存在 | `1.1.0` |

- **其中 phpMyAdmin 是真实的代码缺陷**，不是版本过期：
  `${PhpMyAdmin_Ver#phpMyAdmin-}` 只剥了前缀，拼出
  `.../phpMyAdmin/5.2.3-all-languages/...`，而官方目录名只有版本号。
  现改为剥两次（`init.sh:507-513`），并在注释里写明原因。
- **MySQL 二进制的架构可用性也一并实测**（写入 `profile.sh` 注释）：
  8.0.46 的 glibc2.28 包 x86_64/aarch64 都有、无 i686；
  8.4.7 只有 glibc2.17-x86_64，**官方未提供 aarch64/i686**：
  `DB_Bin_Archs` 已按实测收窄，避免在 ARM 上下载一个不存在的包。
- **确认无需修改的一项**：MariaDB 的 `downloads.mariadb.org/rest-api/...` 形式类似
  JSON 接口，实测下载回来确实是 gzip tarball，无需改动。
- **验证**：`bash t/probe_urls.sh` → **62 条全部可达，0 个 404**
- **返工（2026-08-09）**：两处不成立。
  1. 「**全部**下载 URL 首次实测」不实：探测集里没有 acme.sh，也没有 `.repo` 配置，
     而这两条是实际存在的取用路径（见 `ACME-001` / `REPO-001`）。
  2. 「8.0.46 的 glibc2.28 包 x86_64/aarch64 都有」与复核结论相反：
     重新核对官方下载页后，`profile.sh` 里五个数据库版本的 `DB_Bin_Archs`
     **全部收窄为 `x86_64`**（MariaDB 通用二进制只发 x86_64，MySQL 8.4 只有 glibc2.17-x86_64）。
- **验证状态**：已验证，见阶段 11 `GHA-009` 及阶段 15 URL 与校验清单回归（2026-08-11 复核）。

### URL-002 改用不会下线的归档源

- **文件**：`include/init.sh:515-519`、`include/apache.sh:82,89`
- **改动**：Apache 系列从 `downloads.apache.org` 改为 `archive.apache.org/dist`。
- **理由**：`downloads.apache.org` 与 nginx.org 一样**只保留当前版本**，
  点版本一发布旧的就 404（本次 2.4.67 正是这样失效的）。`archive.apache.org`
  保留全部历史版本，能把「上游发新版就得跟着改」的维护成本降下来。
- **行为变化**：下载域名改变，文件内容相同
- **验证状态**：已验证

### VER-001 组件版本升级至官方当前稳定版

- **文件**：`include/version.sh`（整体重写并加维护说明）、`include/profile.sh`
- **类别**：VER 版本更新
- **用户指定**（已逐条实测 tag 真实存在）：

```
Libzip_Ver='libzip-1.3.2'                     （保持不动）
Luajit_Ver='luajit2-2.1-20260701'
LuaNginxModule='lua-nginx-module-0.10.31'
LuaRestyCore='lua-resty-core-0.1.34rc3'
LuaRestyLrucache='lua-resty-lrucache-0.15'
NgxDevelKit='ngx_devel_kit-0.3.4'
LuaRestyLock='lua-resty-lock-0.09'            （新增）
LuaCjson='lua-cjson-2.1.0.19'                 （新增）
```

- **其余升级**：OpenSSL 3.5.5→3.5.7、jemalloc 5.3.0→5.3.1、
  gperftools 2.9.1→2.18.1、libunwind 1.2.1→1.8.3、nghttp2 1.65.0→1.70.0、
  ngx-fancyindex 0.5.2→0.6.0、Redis 8.6.0→8.10.0、
  PHP 8.2.30→8.2.33 / 8.3.30→8.3.33 / 8.4.20→8.4.24 / 8.5.5→8.5.9、
  MariaDB 10.11.16→10.11.18 / 11.4.10→11.4.12 / 11.8.6→11.8.8、
  pecl：redis 6.2.0→6.3.0、imagick 3.7.0→3.8.1、apcu 5.1.22→5.1.28、
  swoole 6.0.2→6.2.2、memcached 3.2.0→3.4.0
- **刻意不升的两项**：
  - **nginx 保持 1.30.4**：1.30 是 stable 分支（次版本号为偶数），1.31 是 mainline。
  - **OpenSSL 不跟进 4.0**：nginx / PHP 生态对 4.0 的适配尚未铺开，3.5 是当前 LTS。
- **PHP 8.0 / 8.1 保持原版本**：这两个分支已 EOL，上游不再出新点版本。
- **验证**：`bash t/probe_urls.sh`、`bash t/test_profile.sh`
- **验证状态**：已验证

---

### SEC-HTTP-001 消除残留的明文 HTTP 下载

- **文件**：`include/redis.sh`、`include/upgrade_mysql.sh`、`include/upgrade_nginx.sh`、
  `include/init.sh`、`t/lint.sh`
- **类别**：SEC 安全修复
- **背景**：改造目标是「下载源全部走 HTTPS 上游官方」，但复查时发现 8 处遗漏：
  - `redis.sh` 的 redis 源码与 3 处 pecl 下载走 `http://`
  - `upgrade_mysql.sh:869` 的 MySQL 源码走 `http://cdn.mysql.com`
  - `upgrade_nginx.sh:35` 的 nginx 源码走 `http://nginx.org`
  - `init.sh` 的阿里云 CentOS repo 配置与 Ubuntu old-releases 走 `http://`
- **风险**：明文 HTTP 下载可被中间人替换为任意内容。其中 `init.sh` 那两处尤其严重：
  下载的是 **yum repo 配置文件**，被替换意味着此后所有 yum 安装都从攻击者的源取包。
- **改动**：全部改为 `https://`，并新增 lint 检查 **C13** 防止回退。
  C13 与 C9 同口径，只拦「可执行的取用」（wget/curl/Download_Files 参数位置），
  不拦注释与 `tools/check502.sh` 里给用户填自己站点的示例 URL。
- **验证**：`bash t/lint.sh C13`
- **返工（2026-08-09）**：清点不全，且 `init.sh` 那条的**处理方式不对**。
  把阿里云镜像的 `http://` 改成 `https://`，仍然是**从第三方镜像下载 repo 配置**：
  加密解决的是传输问题，解决不了来源可信问题，而这个文件决定此后所有 yum 包从哪来。
  已由 `REPO-001` 重做为官方 HTTPS 源 + `gpgcheck=1` + 随包固定公钥。
  同批漏掉的还有 acme.sh（`http://` + 管道执行），见 `ACME-001`。
  lint 检查 C13 随 `t/` 清理失效。
- **验证状态**：已验证，见阶段 15 `t/lint.sh` 的 C13 与主线下载实跑（2026-08-11 复核）。

### CLN-205 redis.sh 裁剪已失效的版本分支

- **文件**：`include/redis.sh`
- **改动**：
  1. 删除 `gcc -dumpversion` 为 3/4 时回退 `redis-5.0.9` 的逻辑：那对应 CentOS 6
     时代的编译器，本包已不支持（见 `Check_CMPT`），且该回退版本不在校验清单内，
     fail-closed 下必然中止，属于走不通的死路。
  2. 删除按 PHP 5.2 / 5.3-5.6 分流到 phpredis 2.2.7 / 4.3.0 的两条分支：
     保留的 PHP 全是 8.x，这两条永不可达。
  3. 补上原先缺失的 `Require_File`（下载失败会继续编译的老问题）。
- **行为变化**：无（删除的都是不可达分支）
- **验证状态**：已验证

---

### FW-001 防火墙由 iptables 整体改为 nftables

- **文件**：`include/firewall.sh`（**新建**）、`include/end.sh`、`include/memcached.sh`、
  `include/redis.sh`、`pureftpd.sh`、`tools/fail2ban.sh`、`tools/denyhosts_removeip.sh`、
  `include/init.sh`（依赖清单）、`t/lint.sh`
- **类别**：REF 结构重构 + 用户需求
- **背景**：旧实现中的「加规则 → save → reload」逻辑，连同「yum 用
  iptables-services / apt 用 netfilter-persistent 或 iptables-persistent」的
  三重分支，在 6 处被逐字抄了一遍，共约 90 行。
- **改动**：新建 `include/firewall.sh`，收口为 6 个函数：

```
Firewall_Init          建 inet lnmp 表与 input 链，写入 lo / established 两条基础规则
Firewall_Allow         放行端口（支持 20000-30000 这样的区间）
Firewall_Allow_ICMP    放行 ping（v4 + v6）
Firewall_Block         挡掉端口的外部新建连接
Firewall_Unblock       按 handle 删除对应 drop 规则
Firewall_Save          持久化并 enable nftables.service
```

- **安全模型刻意保持不变**：链的 policy 仍是 **accept** 而非 drop。
  这不是一道「默认拒绝」的防火墙，只是把不该暴露的服务端口（3306/6379/11211）挡掉。
  **不改成默认拒绝是有意的**：用户机器上可能跑着本脚本一无所知的服务
  （自定义 SSH 端口、VPN、监控 agent），policy 一改成 drop，装完 LNMP 人就被
  关在门外了。要做默认拒绝应当是用户的显式决定，不该由安装脚本代劳。
- **规则顺序有语义**（nftables 首个匹配即终止）：
  `lo accept` → `established,related accept` → 各服务端口 `accept` → 敏感端口 `drop`。
  前两条保证本机经 lo 访问 3306/6379 不受影响、出站连接的回包不被打掉。
- **持久化**：不再依赖任何额外的包。Debian 系写 `/etc/nftables.conf`，
  RHEL 系写 `/etc/sysconfig/nftables.conf`，两边的 `nftables.service` 各自读这个文件。
- **firewalld**：`Firewall_Init` 检测到 firewalld 在跑会停用并禁用它：
  firewalld 自己也管 nftables，两边同时写会互相覆盖。
- **fail2ban**：封禁动作改为 `nftables[type=multiport]`。这一步是必须的：
  本包已不再安装 iptables，若仍用默认的 `iptables-multiport`，fail2ban 会在
  **首次封禁时**才失败，且只写自己的日志，极难察觉。
- **函数名 `Add_Iptables_Rules` 保留未改**：它有 3 处调用点（install.sh 的三条
  安装路径），改名收益不大而 diff 变大；实现已整体替换，函数内加了注释说明。
- **新增 lint 检查 C14**：拦 `iptables -X`、`service iptables`、以及
  iptables-services / iptables-persistent / netfilter-persistent 的安装，
  防止后续改动把 iptables 那套写回来：两套并存时规则会互相覆盖且极难排查。
- **实测**（Debian 12）：

```
table inet lnmp {
    chain input {
        type filter hook input priority filter; policy accept;
        iif "lo" accept
        ct state established,related accept
        tcp dport 22 accept / 80 / 443
        icmp/icmpv6 type echo-request accept
        tcp dport 3306 drop / 6379 / 11211，udp dport 11211 drop
        tcp dport 20 / 21 / 20000-30000 accept
    }
}
```

  幂等性（重复 `Firewall_Block tcp 3306` 两次仍只有一条规则）、
  `Firewall_Unblock` 生效、持久化文件写入并 `systemctl enable nftables` 成功，
  均已逐项验证通过。
- **返工（2026-08-09）**：方向对，但两处实现是错的。
  1. `Firewall_Save` 直接写 `/etc/nftables.conf`，会**整体覆盖用户已有的防火墙主配置**；
  2. 「检测到 firewalld 在跑就停用并禁用它」： 安装脚本无权替用户关掉系统防火墙。
  已由 `FW-002` 重做：规则只落在独立的 `inet lnmp` 表（用 `delete table` 而非 `flush ruleset`）、
  持久化只写自己的 include 文件、firewalld 在跑时改走 `firewall-cmd` 与之共存。
  上文「实测（Debian 12）」的规则清单是**改前版本**的输出，不代表当前实现。
- **验证状态**：已验证，见阶段 9 `SEC2-004` 与阶段 14 端口监听实测（2026-08-11 复核）。

---

### NGX-001 nginx 编译加入 brotli / cache_purge / lua 生态模块

- **文件**：`include/nginx.sh`、`include/version.sh`、`lnmp.conf`、`include/init.sh`
- **类别**：FEAT 功能新增（用户需求）
- **新增模块**：
  - **ngx_brotli**：Brotli 压缩，`--add-module`
  - **ngx_cache_purge 2.3**：提供 `proxy_cache_purge` / `fastcgi_cache_purge` 指令
  - **lua-cjson 2.1.0.19**：C 扩展，编译出 `cjson.so`
  - **lua-resty-lock 0.09** 及 8 个常用纯 Lua 库：
    string / redis / mysql / upload / websocket / dns / memcached / limit-traffic
- **开关**：`lnmp.conf` 新增 `Enable_Ngx_Brotli`、`Enable_Ngx_CachePurge`（默认 y），
  并把 `Enable_Nginx_Lua` 从 `n` 改为 `y`（需求约束默认支持 lua 生态）。
- **ngx_brotli 固定到 commit 而非 master 分支**：这一条很关键：
  分支归档（`archive/refs/heads/master.tar.gz`）的内容随上游**每次提交**变化，
  sha256 必然漂移，fail-closed 校验会在上游一提交就把安装打断。
  故固定 `a71f9312c2deb28875acc7bacfdd5695a111aa53`（2023-10-09，此后无新提交）。
  上游只有一个 2021 年的 `v1.0.0rc` tag，用它反而更旧。
- **ngx_brotli 的子模块问题**：GitHub 的 archive 包**不含 git 子模块**，
  而 `deps/brotli` 正是子模块。其 config 会先找系统的 libbrotlienc/dec，
  找到就不需要子模块：因此依赖清单里加入了 `libbrotli-dev`（Debian）/
  `brotli-devel`（EL）。
- **lua-cjson 与其他 resty 库装法不同**：它有 C 代码，必须针对 LuaJIT 的头文件
  编译，装进 `/usr/local/luajit/lib/lua/5.1/`，再由 `lua_package_cpath` 引用
  （`lua_package_path` 只管 `.lua`，`.so` 走 cpath，写错了不会加载）。
  `Install_Nginx` 里已加入 cpath 配置的写入。
- **纯 Lua 库用表驱动**：9 个库装法完全一致，故 `Install_Lua_Resty_Libs` 用一个
  循环处理，加库只需在 `version.sh` 和那张表里各加一行。它们不参与 nginx 编译，
  **单个装失败只告警不中止**：一个可选 Lua 库装不上不该让整个安装失败。
- **brotli 运行时配置**：编进去了就在 nginx.conf 里一并开启
  （`brotli on` / `brotli_static on` / comp_level 6 / 与 gzip 相同的 types），
  否则模块编译进去了却没生效。
- **验证**：`bash t/probe_urls.sh` 确认全部模块归档可下载；语法与 lint 通过。
  **编译本身未验证**：见「注意：阻断性提醒」第 2 条列出的 4 个风险点。
- **验证状态**：已验证，见阶段 8 `FIX-BROTLI-001`、阶段 9 `FIX-LUA-001` 及阶段 15 主线验收（2026-08-11 复核）。

### PHP-EXT-001 PHP 安装默认带上常用扩展

- **文件**：`include/php_default_ext.sh`（**新建**）、`include/imageMagick.sh`、
  `lnmp.conf`、`install.sh`
- **类别**：FEAT 功能新增（用户需求）
- **默认扩展**：opcache、igbinary、phpredis、imagick、fileinfo
- **原因单独建一个文件而不复用 addons.sh 的函数**：
  `addons.sh` 里那套 `Install_*` 是**交互式**的（`Press_Start` 等人按回车、
  `Restart_PHP` 依赖 addons.sh 自己的上下文），直接在 `install.sh` 的无人值守
  流程里调用会**卡住等待输入**。故重写为非交互版本。
- **共用重的部分**：ImageMagick 本体编译抽成 `Build_ImageMagick_Lib()`
  （`imageMagick.sh`），交互式安装与默认安装两条路径共用，避免各写一份
  随版本升级而漂移。
- **编译顺序有硬约束**：**igbinary 必须在 phpredis 之前**：phpredis 的
  `--enable-redis-igbinary` 需要 igbinary 的头文件。代码里按此顺序排列并加了注释；
  若 igbinary 装成功，phpredis 会自动带上 igbinary 序列化支持。
- **opcache 要写 `zend_extension` 而不是 `extension`**：它在 PHP 8.x 是编译进去的
  （configure 已有 `--enable-opcache`），但**默认不加载**，必须在 conf.d 写
  `zend_extension` 才生效，写成 `extension` 不会加载。
- **fileinfo 是 configure 阶段决定的**：`Enable_PHP_Fileinfo` 从 `n` 改为 `y`
  （很多框架做上传 MIME 检测依赖它）。它不能事后补装，故代码里只做结果核对，
  发现没编进去时明确提示「要在编译前就设为 y」。
- **失败处理**：单个扩展装失败只记录不中止，结尾统一汇总打印未装成的清单，
  避免「装完了才发现少东西」，也避免一个可选扩展拖垮整个 LNMP 安装。
- **验证**：`bash t/probe_urls.sh` 确认 pecl 包与 ImageMagick 归档可下载；
  语法与 lint 通过。**扩展能否真正编译并加载未验证。**
- **验证状态**：已验证，见阶段 15 PHP 8.3 WordPress 扩展加载清单（2026-08-11 复核）。

### VER-002 包版本号统一为 2.3

- **文件**：`install.sh:18`、`uninstall.sh:13`、`addons.sh:76`、`upgrade.sh:54`
- **背景**：目录名是 `lnmp2.3` 而 `LNMP_Ver='2.2'`，四处 banner 里两种写法混用。
  安全复核曾将本包是否被第三方改动列为待确认问题。
- **改动**：`LNMP_Ver` 统一为 `2.3`；`addons.sh` 与 `upgrade.sh` 里硬编码的
  `LNMP V2.2` 字样一并改为 `V2.3`。
- **注意**：这只是消除包内自相矛盾，**不代表与上游官方 2.3 版本对应**。
- **验证状态**：已验证

### CHK-001 新建 t/gen_checksums.sh 采集校验清单

- **文件**：`t/gen_checksums.sh`（**新建**）
- **类别**：TEST 验证工具
- **用途**：解决交接文档里的阻断项 2（`src/checksums.sha256` 只有 6 条）。
- **关键点：文件名必须是「落地文件名」而非 URL 的 basename**。
  校验是按 `Download_Files` 的第二个参数查表的，二者常常不同：GitHub tag
  归档尤其明显：URL 是 `v0.33.tar.gz`，落地名是 `lua-resty-redis-0.33.tar.gz`。
  文件名错误时，即使清单条目齐全，安装仍会因 fail-closed 校验中止。
- **信任模型（已写入脚本头部注释）**：本脚本是「下载下来再算哈希」，
  **不能**证明文件没被篡改：采集时若已被中间人替换，算出的哈希只会把坏文件
  固化下来。它保证的是**一致性**：此后所有机器装到的与采集这一刻逐字节相同。
  来源可信度由「全程 HTTPS 上游官方域名」+「有官方公布校验值的组件做交叉核对」提供。
  故明确要求在干净网络下执行。
- **磁盘控制**：逐个「下载 → 算哈希 → 立即删除」，避免几个 GB 的数据库包
  把磁盘撑满（验证机只有 19G）。
- **返工（2026-08-09）**：它的**信任模型被 `CHK-004` 否定**了：「下载下来再算哈希」只能保证一致性，
  采集时若已被替换，只会把坏文件固化。现在对**有官方校验值的组件一律改从上游机器可读来源取**：
  php.net releases JSON、MariaDB REST API、phpMyAdmin 的 `.sha256`、
  archives.boost.io 的 `<file>.json`、nginx 走 PGP 签名验证。
  只有 MySQL 因上游不提供任何机器可读校验值而例外，已在清单头部写明这个信任缺口。
- **验证状态**：已验证，见阶段 11 `GHA-007` 与阶段 15 校验清单回归（2026-08-11 复核）。

### CHK-002 src/checksums.sha256 补齐至 68 条

- **文件**：`src/checksums.sha256`（6 条 → **68 条**）
- **类别**：SEC 安全修复（解除上一版交接文档的阻断项 2）
- **背景**：`Verify_Download_File` 已是 fail-closed，而清单只有 6 条 PHP，
  意味着 `./install.sh` 必然在第一个未列入的文件处 `exit 1`。
- **做法**：在 Debian 12 上执行 `t/gen_checksums.sh`，逐个「下载 → 算哈希 → 删除」。
  磁盘峰值可控（验证机只有 19G，而 MySQL/MariaDB 的包合计好几个 GB）。
- **采集结果**：68 条，覆盖全部安装路径（含 lnmpa/lamp 的 Apache、
  三个 MariaDB LTS 的源码与二进制、全部可选模块与 pecl 扩展）。
- **采集链路的两重自验证**：
  1. **交叉核对**：5 项与上游发布的 `.sha256` 文件比对一致：
     openssl-3.5.7、httpd-2.4.68、apr-1.7.6、apr-util-1.6.4、phpMyAdmin-5.2.3。
  2. **旁证**：`php-8.0.30` 与 `php-8.1.34` 两条，与此前**直接从 php.net
     releases API 抄录**的值完全一致：说明「下载后计算」这条链路本身没问题。
- **同时修掉一个正则 bug**：仓库名提取用的 `sed 's/-[0-9][0-9.]*$//'` 处理不了
  预发布后缀，`lua-resty-core-0.1.34rc3` 的版本段是 `0.1.34rc3` 而非 `0.1.34`，
  匹配不上导致仓库名被算成整个字符串，拼出的 URL 必然 404。
  已改为 `sed -E 's/-[0-9][0-9.]*([a-zA-Z]+[0-9]*)?$//'`，
  **`include/nginx.sh` 的 `Install_Lua_Resty_Libs` 有同样的写法，一并修正**
  （当前 9 个库的版本号恰好都是纯数字所以没暴露，但加一个带 rc 的库就会触发）。
- **composer 不在清单内**：其 installer 是动态生成的，每次发布内容都变，
  无法固定哈希。它走独立机制：与官方 `composer.github.io/installer.sig`
  公布的 SHA384 比对，不一致就拒绝执行（`include/php.sh` 的 `Install_Composer`）。
- **清单头部写明了信任边界**：这些哈希保证的是**一致性**（此后所有机器装到的与
  采集这一刻逐字节相同），**不能**证明文件未被篡改：若采集时已被中间人替换，
  算出的哈希只会把坏文件固化下来。故要求在干净网络下采集。
- **验证**：`bash t/lint.sh C10` → `ok C10 校验清单格式正确 (68 条)`
- **返工（2026-08-09）**：「68 条，**覆盖全部安装路径**」**不成立**。
  清单是按落地文件名逐条列举的，结构上覆盖不到三类东西：
  架构变体（同一版本换个 arch 就是另一个文件）、只有特定条件才走到的分支包、
  以及版本要到运行时才确定的 boost。
  已由 `CHK-003`（架构与动态依赖）与 `CHK-004`（可信来源与信任边界）重做。
  当前清单为 **67 条**（boost 1.59/1.67 换成 1.77/1.84，ionCube 随 `DEL-IONC-001` 注释掉）。
- **本阶段独立静态复核**：项目外测试按当前 `version.sh/profile.sh` 支持矩阵生成固定落地名，
  双向差集结果为：期望 67、清单 67、缺失 0、陈旧 0、重复 0、格式错误 0。
  该结果只证明当前固定文件名覆盖，不证明来源真实性，也不覆盖“已有缓存跳过验证”；
  后两项分别见 `CHK-004` 和审计记录中的缓存/旁载项。
- **验证状态**：已验证（仅指返工后的 67 项固定文件名覆盖结论）

### CLN-206 删除 Install_Apache_22 死代码

- **文件**：`include/apache.sh`（137 → 83 行）
- **类别**：CLN 清理
- **背景**：Apache 2.2 于 2017-07 EOL，本阶段改造已把它从菜单移除
  （`profile.sh` 的 Apache 表只剩 2.4 一个编号），但安装函数一直留着。
- **原因必须删而不是留着**：它此刻已经是**必然失败**的死代码：
  依赖的 `conf/httpd22-{lamp,lnmpa,ssl}.conf` 和 `src/patch/mod_remoteip.c`
  都已删除。留着一个「看起来能用、实际执行即失败」的函数，
  比没有这个函数更糟。
- **保留的**：`conf/mod_remoteip.conf`（配置文件）仍被 `Install_Apache_24` 使用。
  Apache 2.4 内建 mod_remoteip，不需要像 2.2 那样单独 apxs 编译 `.c`。
- **行为变化**：无（没有任何路径能派发到该函数）
- **验证**：`bash t/test_dispatch.sh`、`bash t/lint.sh`
- **验证状态**：已验证

### SEC-WEB-002 清理 conf/ 下的匿名操作面与失效链接

- **文件**：`conf/memcached1.php`、`conf/memcached2.php`、`conf/index.html`、
  `include/memcached.sh`、`lnmp.conf`
- **类别**：SEC 安全修复（解除 OPEN-004）
- **改动 1：删除匿名 `$mem->flush()`**：
  两个演示页里都有 `$mem->flush()`，而页面被无条件部署到网站根目录、无任何鉴权。
  任何访客访问一次，就会清空**整个 memcached 实例**：不只是演示写入的两个 key，
  而是站点所有缓存数据。演示 flush 的价值远小于这个代价，故删除该段。
- **改动 2：演示页改为默认不部署**：
  新增 `Enable_Memcached_Test_Page='n'`，与 phpinfo / phpMyAdmin 同一口径。
  该页面会连上 memcached 并读写 key，等于把「本机有 memcached 且可用」
  公开出去。不部署时打印手工部署命令，不影响需要自测的人。
- **改动 3：index.html 的失效链接**：
  原有一行指向 `/p.php`、`/phpinfo.php`、`/phpmyadmin/`。这三个现在**都是 404**
  （探针已移除，后两个默认不部署），留着只会让人以为装坏了。
  改为说明现状 + 如何启用。
- **保留**：页面里指向 `https://lnmp.org` 的项目署名链接保留（用户确认），
  它是出处标注而非下载源，与 lint C9 的口径一致。
- **验证**：`grep -rn 'flush()' conf/` 无可执行结果
- **返工（2026-08-09）**：「保留 lnmp.org 署名链接（用户确认）」**把适用范围写宽了**。
  用户确认可以保留的是**代码注释里**的出处标注；
  部署到用户站点上的页面不该带任何站外链接：那是装完就对公网可见的内容。
  已由 `SEC-WEB-003` 清除 `conf/index.html` 等默认部署页面里的全部站外链接。
- **验证状态**：已验证，见阶段 8 `SEC-WEB-004` 与阶段 14/15 Web 主线实跑（2026-08-11 复核）。

### FIX-CONF-001 CheckMirror 从「恒真的死开关」变为可用配置

- **文件**：`lnmp.conf`、`include/init.sh`
- **类别**：FIX 缺陷修复
- **问题**：`CheckMirror` 在全仓库有 **6 处读取、0 处赋值**，
  `[ "${CheckMirror}" != "n" ]` 恒为真：这个开关等于不存在。
- **它到底控制什么**（读全部使用点后归纳）：是否允许在安装前做**联网准备动作**：
  NTP 对时、`apt-get update`、替换系统软件源、DNS 连通性探测；
  以及数据库是走通用二进制（联网下载）还是源码编译。
  名字是历史遗留，原本配合已删除的 `Download_Mirror`，现在名不副实。
- **改动**：在 `lnmp.conf` 给出显式默认值 `CheckMirror='y'`，并写清真实语义。
- **原因不改名**：它可以通过环境变量传入（`CheckMirror=n ./install.sh lnmp`），
  已有使用者的脚本可能依赖这个名字。改名的收益（语义清晰）小于破坏兼容的代价，
  故保留原名并在配置文件里把语义讲明白。
- **同时删掉一处死代码**：`init.sh:438` 在离线模式下 `rpm -ivh`
  `src/oniguruma-6.8.2-2.el7.x86_64.rpm`：**这两个 rpm 本包内并不存在**
  （`src/` 下无任何 `.rpm`），该分支一旦触发必然报文件不存在。
- **注意**：设 `n` 只跳过上述准备动作，**不会**跳过组件源码的下载
  （那是安装本身必需的）。真正的离线安装需要预先把 `src/` 填满。
- **返工（2026-08-09）**：「它可以通过环境变量传入（`CheckMirror=n ./install.sh lnmp`）」**不成立**。
  本条给出的写法是 `CheckMirror='y'`，而 `lnmp.conf` 是在环境变量之后被 source 的，
  这个赋值会把 `n` 直接冲掉：开关依旧恒为 `y`，等于换了种方式保持"死开关"。
  已由 `FIX-CONF-002` 改为 `CheckMirror="${CheckMirror:-y}"`，`lnmp.conf` 全部开关同口径。
- **验证状态**：待收尾验证（默认路径已运行，开关关闭分支没有独立实测；2026-08-11 复核）。

### DEL-UPG-001 upgrade 三件套裁剪至与安装侧一致的版本范围

- **文件**：`include/upgrade_mysql.sh`（905 → 432 行）、
  `include/upgrade_mariadb.sh`（279 → 268）、
  `include/upgrade_mysql2mariadb.sh`（288 → 276）
- **类别**：DEL 版本裁剪（解除交接文档的剩余项 2）
- **背景**：安装侧的版本表只剩 MySQL 8.0/8.4 与 MariaDB 10.11/11.4/11.8，
  升级侧却还留着通往 MySQL 5.1/5.5/5.6/5.7 与 MariaDB 10.1~10.6 的完整路径：
  等于允许用户把库「升级」到一个本包已不支持、上游也早已 EOL 的版本。
- **删除的**：`Upgrade_MySQL51 / 55 / 56 / 57` 四个函数（约 473 行）及其配套的
  `MySQL51MAOpt` / `MySQL55MAOpt`（分别是 5.1 的 autotools 选项和 5.5 的 cmake 选项，
  8.0/8.4 的命令里从来没引用过）。

**这次裁剪暴露出三个真实缺陷，都不是「版本老」而是「一跑就坏」：**

1. **派发处没有 else**：`Upgrade_MySQL()` 原本是 `if/elif` 六连、**没有兜底分支**。
   输入一个不认识的版本号，会一路走完 `Backup_MySQL`（`lnmp stop` +
   把 `/usr/local/mysql` 整个 `mv` 走），然后**什么都不装**，
   最后进 `Restore_Start_MySQL` 去启动一个并不存在的新库。
   **修法**：把版本白名单校验**前置到用户输入处**，在动数据库之前就拦下，
   失败时机器状态完全不变。MariaDB 那两个脚本原本连版本校验都没有
   （输入什么都往下走，直到下载阶段 404 才失败，那时库已经被停掉移走了），
   同样补上了前置校验。

2. **MariaDB 10.4 分支引用已删除的 patch**：它 `patch -p1 <
   src/patch/mariadb_10.4_install_db.patch`，而该文件已删除。
   这条分支一旦命中必然失败。连同另外两条用了 `-DWITH_XTRADB_STORAGE_ENGINE`
   （10.5+ 已移除该选项）的不可达分支一起删掉，四条 cmake 合并为一条。

3. **`mysql-boost-<ver>.tar.gz` 不在校验清单里**：源码升级路径对 5.7/8.0
   用的是内含 boost 的包名，而 `src/checksums.sha256` 里只有
   `mysql-<ver>.tar.gz`，fail-closed 下必然中止。改为与安装侧
   （`dbcommon.sh` 的 `DB_Download_Files`）统一用不带 boost 的包名，
   boost 由 `Install_Boost` 单独下载：两边同一个包名也省得维护两份哈希。

- **同时修正**：升级侧 MySQL 8.0 二进制的 glibc 后缀原为 `2.12`（非 aarch64 时），
  那批包已全部下线，改为实测值 `2.28`，与安装侧 `profile.sh` 一致。
- **交互提示更新**：`(example: 5.5.60 )` → `(example: 8.4.7 )`，
  MariaDB 的 `(example: 10.0.35 )` → `(example: 11.8.8 )`。
- **验证**：全部脚本 `bash -n`、`t/lint.sh`、`t/test_profile.sh`、`t/test_dispatch.sh`
- **返工（2026-08-09）**：裁剪本身属实，但结论**止步于"版本范围对齐"**，
  漏了升级路径上两个更严重的问题：
  1. **下载不经校验**：`upgrade_*.sh` 走的是各自的 `wget`，没有接进 fail-closed 校验；
  2. **失败无回滚**：数据库已停并 `mv` 走、nginx 二进制已替换之后再失败，机器就停在半截状态。
  已由 `VERIFY-001`（升级侧统一走可验证下载）与 `TXN-001`（先验证、再切换、失败回滚）重做。
- **验证状态**：已验证，见阶段 11 `GHA-007` 与阶段 15 `t/test_dispatch.sh`（2026-08-11 复核）。

### DOC-001 对本文档自身做一轮准确性核对

- **文件**：`changelog.md`、`t/lint.sh`
- **类别**：DOC 文档修正
- **起因**：需求约束核实历史未完成标记是否仍与后续结果一致。
  逐条比对文档声明与代码实际后，查出 6 处不一致：全部已订正。

**1. 「验证状态」字段被维护方误用（影响面最大）**

文档当时定义该字段**由复核人员填写**，并使用三种含义不清的旧取值。
但阶段 6 的 18 条条目里，维护方把自己跑测试的结果填了进去（写成"已实测"）。

这会让人误以为那些条目已经有人复核过。二者是不同维度：自动检查能证明
「语法没错、模式没残留、URL 能下载」，证明不了「这个改动是对的、没改坏语义」。

当时已全部退回未复核状态，括号里注明自动验证到了什么程度；
字段说明处补了一段讲清这个区分。本阶段状态以文档开头的新口径为准。

**2. `RUN-002` 是悬空引用**

NGX-001 与 PHP-EXT-001 的验证状态写着「验证见 RUN-002」，
而**文档里从来没有 RUN-002 这个条目**。已改为写明实际验证到哪一步、
哪些部分仍未验证。

（本段里 `RUN-002` 这个字样是对该问题的记述，不是引用。
用脚本扫悬空引用时它会作为唯一一条被报出来，属预期。）

**3. FIX-PHP-001 的「改后」与代码不符**

原文写改成了 `Version_GE "$(Cur_PHP_Branch)" 7.2`，实际代码里**版本判断被整个去掉**
（保留的 PHP 全是 8.x，判断恒为真）。行号也已漂移。已订正并补上「原因不是
改成正确的版本判断」的说明。

**4. FIX-DB-004 的「改后」指向一个已删除的函数**

它声称把 `MySQL_Gcc7_Patch` 的正则改对了，但该函数随 DEL-DB-001 整个删除，
现在全仓库搜不到。复核者会去找一个找不到的东西。已标注该修正没有留在代码里。

**5. 自检命令索引表与 `t/lint.sh` 的实现对不上**

- `C3` 在表里是一条，实现里是 `C3a` / `C3b` 两条
- **`C4` 在表里，但 `t/lint.sh` 从来没实现过它**，且预期值
  「`rg -c 'cdn.mysql.com'` 只输出一个文件」也已过时（升级侧脚本合法地含有该域名）
- `T4` 写「62 条」，实际已是 70 条

处理：**把 C4 真正实现进 `t/lint.sh`**（检查 DB 下载没有回流到
`only.sh` / `init.sh`，这是 REF-DUP-001 的不变式），
索引表整体改为「说明检查什么」而不再手抄 rg 命令：
两份定义并存只会互相矛盾，实际执行一律以 `t/lint.sh` 为准。

**6. 代码量数字是阶段 3 的快照，与当前值有出入**

`mysql.sh 897→356` 等数字停留在阶段 3 完成时，后续补注释与修复后
实际是 378 / 221 / 401 / 138。已在原处标注，避免复核时拿旧数字去对。

- **核实过但确认无误的**：必须保留的 4 个 patch 都还在、
  `Upgrade_PHP_52..74` 与 `Upgrade_MPHP5.6..8.0`
  确已删除、`Export_PHP_Autoconf` / `PHP_ICU70_Patch` / `Install_Old_Opcache`
  引用为零、`Download_Mirror` 只剩注释与 lint 正则、
  `Cur_PHP_Branch` / `Version_GE` / `DB_Toolchain_EL9` / `MySQL_WITH_BOOST` 均真实存在。
- **验证**：`bash t/lint.sh`（现 15 项，含新实现的 C4）
- **返工（2026-08-09）**：本条曾把「验证状态」写成三种含义不清的旧口径，
  与文档开头的现行口径不一致，**以开头为准**。
- **验证状态**：已验证，见阶段 7 `DOC-004`、`DOC-005` 及阶段 16 状态收尾（2026-08-11）。

---

### 阶段 7 — 按安全复核意见整改（2026-08-09 起）

> 本阶段逐条复核安全检查结果并完成整改，本节记录代码变更。
> P0、P1 和 P2 问题均经代码复核确认。
> 该目录在当前工作区存在，因此按检查快照与工作区版本不一致处理。

### ACME-001 acme.sh 安装链改为官方固定 tag + 硬校验

- **文件**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp`（三份各一处，改后行为一致）
- **类别**：SEC 安全修复
- **问题**：三份管理脚本都从 `https://soft.vpser.net/lib/acme.sh/latest.tar.gz`
  下载后 `cd acme.sh-*` 并以 **root** 执行 `./acme.sh --install`。
  这三个文件安装结束时会被复制成 `/bin/lnmp`，路径完全可达。
  `latest` 是浮动包，内容随时可变，**结构上就无法固定校验值**。
- **原因之前漏掉**：`t/lint.sh` 的 C7/C9 在没有 `rg` 的机器上退化成
  `grep --include='*.sh'`，而 `conf/lnmp` 没有扩展名：检查没扫到它。
  这是静态自检覆盖不足的直接后果，见 LINT-001。
- **改动**：
  1. 源改为 `https://github.com/acmesh-official/acme.sh/archive/refs/tags/3.1.4.tar.gz`，
     版本写死在 `Acme_Sh_Ver`，哈希写死在 `Acme_Sh_SHA256`（两者必须同步改）。
  2. 下载 → 校验 SHA256 → 不匹配立即删除并 `return 1`，**不解压、更不执行**。
  3. 解压到 `mktemp -d` 的私有目录（`chmod 700`），顶层目录名必须精确等于
     `acme.sh-<ver>`；原先的 `cd acme.sh-*` 通配一旦归档结构变化就会 cd 到别处。
  4. 下载、校验、解压、`--install` 任一步失败都 `return 1`，
     三个调用点改为 `Install_Check_Acme.sh || exit 1`。
- **同时修正一个与需求约束相反的行为**：旧实现生成的 `/usr/local/acme.sh/upgrade.sh`
  里有两条 `sed`，把 acme.sh 的 `DEFAULT_ACCOUNT_KEY_LENGTH` /
  `DEFAULT_DOMAIN_KEY_LENGTH` 从 **ec-256 改写成 2048（RSA）**，且每次
  `--upgrade` 后再改一遍；签发命令也都带 `-k 2048`（三份文件各 7 处）。
  明确的需求约束「acme.sh 默认的证书类型不修改，还是 ec-256」：
  两条 sed 已删除、21 处 `-k 2048` 已全部去掉，现在走 acme.sh 自身默认。
  **此前关于“本包没有签发逻辑，无需改动”的记录不正确**，签发逻辑位于
  `conf/lnmp` 的 `Add_SSL_Menu` / DNS 签发两条路径里。
- **行为变化**：**有**：(1) 装不上 acme.sh 时不再继续往下签证书；
  (2) 新签发的证书密钥从 RSA-2048 变为 EC-256。
  已装好的旧证书不受影响，续期时沿用原密钥类型。
- **验证**：`bash -n conf/lnmp conf/lnmpa conf/lamp`；
  `grep -n 'k 2048' conf/lnmp conf/lnmpa conf/lamp` 无输出
- **返工（2026-08-09 二轮）**：**本条列出的每一项都已逐条复核属实**：
  `Acme_Sh_Ver='3.1.4'`、`Acme_Sh_SHA256` 已写死、
  `grep -c 'k 2048' conf/lnmp conf/lnmpa conf/lamp` 三份均为 **0**、
  改写 `DEFAULT_*_KEY_LENGTH` 的两条 sed 已不存在、
  三个调用点均为 `Install_Check_Acme.sh || exit 1`。
  **漏的是安装之后**：acme.sh 的 `--upgrade` 会从 GitHub 拉代码覆盖自己、
  不核对任何哈希或签名：只要自更新开着，这里固定的 SHA256 第二天就不作数了，
  而它持有全部证书的私钥。由 `SEC-ACME-002` 补上（关闭 auto-upgrade、
  `upgrade.sh` 改为手动确认式）。
- **验证状态**：已验证，见阶段 9 `SSL-IP-001` 的 acme.sh 调用实测（2026-08-11 复核）。

### REPO-001 RHEL/CentOS 软件源改为官方 HTTPS + gpgcheck=1 + 随包固定公钥

- **文件**：`conf/rhel-9.repo`、`conf/rhel-10.repo`、`conf/CentOS8-vault.repo`、
  `conf/RPM-GPG-KEY-CentOS-Official`（**新增**）、`include/init.sh`；
  删除 `conf/CentOS6-Base-Vault.repo`
- **类别**：SEC 安全修复
- **问题**（逐项复核属实）：
  1. `rhel-9.repo` 三个仓库全走 `http://mirrors.ustc.edu.cn`，
     且 `baseos` / `crb` 是 `gpgcheck=0`：系统最核心的两个仓库不验签。
  2. `CentOS8-vault.repo` 全走 `http://mirrors.aliyun.com`，
     **所有启用的仓库都是 `gpgcheck=0`**。
  3. `CentOS6-Base-Vault.repo` 虽然 `gpgcheck=1`，但仓库和 **GPG 公钥都经
     HTTP 获取**：攻击者把两者一起换掉，等于用他自己的钥匙验他自己的包。
  4. `RHEL_Modify_Source` 从 `mirrors.aliyun.com` **动态下载 repo 文件后直接启用**，
     对内容零校验。
  5. `CentOS_Dependent` 会动态生成一个指向 `mirrors.ustc.edu.cn` 的 CRB 源，
     **公钥也从同一个第三方镜像在线取**。
- **影响**：这些源提供的是 gcc / binutils / 头文件。它们被污染时，
  即使 nginx、PHP 和 MySQL 源码包校验正确，被篡改的编译器仍会影响二进制结果。
  **这是本阶段所有校验工作的地基**，地基漏了上面做多少哈希都没用。
- **改动**：
  1. **公钥随包分发**：新增 `conf/RPM-GPG-KEY-CentOS-Official`（CentOS 官方签名公钥，
     rsa4096 / 2019-05-03）。新函数 `Install_CentOS_GPG_Key()` 先用 `gpg --show-keys`
     核对指纹 `99DB70FAE1D7CE227FB6488205B555B38483C65D`，不符即 `exit 1`，
     通过后装到 `/etc/pki/rpm-gpg/` 并 `rpm --import`。
     所有 `.repo` 的 `gpgkey` 改为 `file:///etc/pki/rpm-gpg/...`，**取公钥不再联网**。
  2. **源改官方 HTTPS**：EL9/EL10 → `https://mirror.stream.centos.org/<n>-stream/`；
     EL8 → `https://vault.centos.org/8.5.2111/`（官方归档）。全部 `gpgcheck=1`。
  3. **不再动态下载 repo 文件**：`RHEL_Modify_Source` 只用随包的三份配置，
     EL8/9/10 之外的版本**明确 `exit 1`** 并提示可设 `RHELRepo='local'`，
     不再"尽力而为"地拼一个来路不明的源。
  4. **动态生成的 CRB 源**改为官方 `mirror.stream.centos.org` + 本地公钥。
  5. **删除 CentOS 6 整条路径**（`CentOS6_Modify_Source` + repo 文件）。
     它有两个删除理由：`Check_CMPT` 在 `Modify_Source` **之前**就以
     「PHP 8 需要较新发行版」拒绝了 CentOS 4-6，这段代码从改造完成起
     **就没有执行路径**；而它本身又正好是「公钥和仓库同走 HTTP」的反面样本。
- **行为变化**：**有**：(1) EL8/9/10 之外的 RHEL 不再自动换源，改为报错退出；
  (2) 装依赖时会真正校验签名，若上游包签名有问题会装不上（这是预期行为）；
  (3) CentOS 6 彻底不支持。
- **验证**：`bash -n include/init.sh`；
  `grep -rn 'http://' conf/*.repo` 只剩注释；
  三个 baseurl 实测 `repodata/repomd.xml` 返回 200
- **返工（2026-08-09 二轮）**：**本条改的部分复核属实**：
  三个 `.repo` 现在都是官方 HTTPS + `gpgcheck=1` + `gpgkey` 指向随包本地公钥。
  **范围漏了一半**：本条只管**本包自己写入**的软件源，
  完全没看**宿主机上已经存在**的源。而编译依赖（gcc、各 `-devel`）
  正是从宿主机的源装的，那批包不经过 `src/checksums.sha256`：
  是整条供应链上唯一没被本包覆盖的环节。
  由 `SEC-REPO-002`（只读预检，分级告警）与 `SEC-REPO-003`
  （补 http 扫描、准确行号与原文输出）补上。
- **验证状态**：待收尾验证（配置与 URL 已静态核对，EL8/9/10 真机换源尚未执行；2026-08-11 复核）。

### FIX-SEL-001 非法编号真正硬失败（REN-DB-002 的返工）

- **文件**：`include/main.sh`（`Database_Selection` / `PHP_Selection` / `Apache_Selection`）
- **类别**：FIX 缺陷修复
- **问题**：`REN-DB-002` 声称旧编号会硬失败，**实际不会**。三处都是同一个写法：

  ```bash
  if ! Set_DB_Profile "${DBSelect}"; then      # 空输入和非法输入都会走到这里
      DBSelect="${DB_Default}"                 # 一律回退默认值
      Set_DB_Profile "${DBSelect}" || Invalid_Selection ...
  fi
  ```

  `Legacy_Selection_Hint` 只是 `echo` 一行提示后 `return 0`，拦不住任何东西。
  于是 `DBSelect=12`（2.2 里的 MariaDB 11.4）会**静默装成默认的 MySQL 8.4**，
  恰恰是该条目声称要消灭的行为。
- **根因**：把「没输入」和「输错了」合并成同一条失败路径。
  交互式下用户直接回车确实需要取默认值，但这不能同时给非法值也开一道门。
- **改动**：两者拆开：先判 `[ -z "${DBSelect}" ]` 取默认值，
  之后 `Set_DB_Profile ... || Invalid_Selection ...` 无条件生效
  （`Invalid_Selection` 本身就是 `exit 1`）。
  `Apache_Selection` 的两段式回退同样删掉。
- **三种入口现在的行为**：交互回车 → 默认值；`DBSelect=12 ./install.sh lnmp`
  → 打印新旧编号对照后 `exit 1`；命令行预置非数字 → `exit 1`。
  **拒绝发生在任何系统变更之前**（`Set_Profiles` 在 `Press_Install` 里，
  早于换源、装依赖、下载）。
- **已验证无需改的两处**：`include/multiplephp.sh:24-27` 与
  `include/upgrade_mphp.sh:53-56` 本来就是硬失败/重新询问，不存在回退。
- **行为变化**：**有**：非空非法编号从「静默装默认版本」变为「退出码 1」。
- **验证**：`bash -n include/main.sh`
- **验证状态**：已验证，见阶段 11 `GHA-007` 与阶段 15 `t/test_profile.sh` 非法编号用例（2026-08-11 复核）。

### FIX-CMP-001 Composer 改走独立下载通道（此前必然中止安装）

- **文件**：`include/php.sh`（`Install_Composer`）
- **类别**：FIX 缺陷修复
- **问题**：`SEC-DL-004` 把 composer 改成「先下载 installer 再核对 SHA384」，
  但下载那一步用了 `Download_Files https://getcomposer.org/installer "${cur_dir}/src/composer-setup.php"`。
  `Download_Files` 会调 fail-closed 的 `Verify_Download_File`，
  它拿**第二个参数的字面值**（这里是一整条绝对路径）去 `src/checksums.sha256` 查表；
  查不到就 `exit 1`。而 composer 的 installer 是官方动态生成的，
  内容每次发布都变、**没有可固定的哈希**，清单末尾也写明了它不在清单内。
- **实际后果比"composer 装不上"严重得多**：`exit 1` 是终止整个脚本。
  默认配置（`Enable_Download_Checksum='y'`）下
  `include/php.sh:290` 的正常 PHP 安装、`include/upgrade_php.sh:224` 的 PHP 升级
  **都会在这里稳定中止**；而那段独立 SHA384 校验一次也执行不到。
  这正是 CHK-002「覆盖全部安装路径」结论不成立的一个实例。
- **改动**：composer 不再经过 `Download_Files`，改用自己的通道：
  1. **先取签名再取程序**：先拉 `composer.github.io/installer.sig`，
     并校验它确实是 96 位十六进制：取回一个 404 页面当签名用只会更糟；
  2. 再下载 installer，比对 SHA384，不一致就删除且不执行；
  3. 两次 `wget` 都限制 `--max-redirect=3`，不关证书校验；
  4. installer 落在 `mktemp -d` 的私有目录，无论成败都清理；
  5. 函数末尾补 `return 0/1`，原先成功失败都返回 0。
- **行为变化**：**有**：默认配置下 PHP 安装/升级从「必然中止」变为可完成。
- **验证**：`bash -n include/php.sh`；
  `grep -n 'Download_Files' include/php.sh` 中不再有 composer 相关行
- **验证状态**：已验证，见阶段 14 Debian 12 全新安装（2026-08-11 复核）。

### FIX-RC-001 退出码真实反映安装结果

- **文件**：`install.sh`、`upgrade.sh`、`pureftpd.sh`、
  `include/only.sh`、`include/multiplephp.sh`、`include/end.sh`
- **类别**：FIX 缺陷修复
- **问题**：这条链上有三个独立的断点，任何一个都足以把失败报成成功。

  1. **`tee` 吞掉退出码**：`LNMP_Stack 2>&1 | tee /root/lnmp-install.log`。
     bash 默认取管道**最后一条**命令的状态，也就是 `tee` 的 0；
     左侧的 `exit 1` 完全传不出来。同样的写法在 `upgrade.sh` 有 8 处，
     `multiplephp.sh` / `only.sh` / `pureftpd.sh` 各 1 处。
  2. **未知目标返回 0**：`case` 的 `*)` 分支只打印 usage，
     而 `echo` 返回 0，脚本末尾又是无参数的 `exit`：
     `./install.sh typo` 什么都没装，退出码却是 0。
  3. **结果自检不返回失败**：`Check_LNMP_Install` 等三个函数在组件缺失时
     只调 `Print_Failed_Info`，而后者最后一条是 `Echo_Red`，返回 0。
     于是「nginx 没装上」和「装好了」对调用方是同一个退出码。
- **改动**：
  - 所有 `... | tee` 之后取 `${PIPESTATUS[0]}`，逐级传到入口的 `exit`；
    `upgrade.sh` 补上原本就缺失的末尾 `exit`。
  - `install.sh` 的 `*)` 分支设 `Install_Rc=1`。
  - `Print_Failed_Info` 与三个 `Check_*_Install` 补 `return 1`，
    成功分支显式 `return 0`。
  - 同时修掉 `Check_LNMPA_Install` 里 `"${isPHP}" = "ok"  &&"${isApache}"` 的
    粘连空格（`[[ ]]` 中可以执行，但容易被误读）。
- **原因不用 `set -o pipefail`**：本包全局没有 `set -e`，却有大量
  `cmd | grep -q ...` 形式的条件判断；全局打开 pipefail 会改变它们的退出状态，
  影响面远超这里要解决的问题。`PIPESTATUS[0]` 是精确到调用点的等价做法，
  该方式与复核时确定的备选方案一致。
- **同时**：`Print_Failed_Info` 原先引导用户把 `/root/lnmp-install.log`
  上传到论坛，而该日志里含数据库 root 密码（见 SEC-CRED-001），
  改为提示"外发前先清理"。
- **行为变化**：**有**：安装/升级失败现在返回非零。
  依赖"总是返回 0"的既有自动化脚本会开始报错，这正是本条的目的。
- **验证**：`bash -n install.sh upgrade.sh pureftpd.sh include/*.sh`
- **返工（2026-08-09 二轮）**：**逐条复核，未发现与代码不符之处。**
  - 全仓库 **16 处 `| tee`**，每一处后面都紧跟 `${PIPESTATUS[0]}` 通过
  - `install.sh` 的 `Install_Rc`（含 `*)` 分支置 1）、`upgrade.sh` 末尾的
    `exit ${Upgrade_Rc}` 均存在 通过
  - `Print_Failed_Info` 与三个 `Check_*_Install` 的 `return 1` / `return 0` 均存在 通过
  本条**保持原结论**。该结论保留待进一步证据确认：
  按现有代码复核未发现对应问题。
  唯一确定失效的是文档口径：`验证` 一栏里 `bash -n install.sh upgrade.sh include/*.sh`
  仍可执行，但本文档其余条目引用的 `t/lint.sh` 系列已随 `t/` 清理失效。
- **验证状态**：已验证，见阶段 15 `AUDIT-DB-002` 的故障注入与最终退出码复验（2026-08-11 复核）。

### FIX-ENTRY-001 独立入口补齐 Require_File 与 cur_dir

- **文件**：`include/main.sh`、`include/dbcommon.sh`、
  `tools/denyhosts.sh`、`tools/fail2ban.sh`
- **类别**：FIX 缺陷修复
- **问题**：
  1. `Require_File` 只定义在 `dbcommon.sh`，而**只有 `install.sh` 加载它**。
     `addons.sh`、`pureftpd.sh`、`tools/denyhosts.sh`、`tools/fail2ban.sh`
     都调用了 `Require_File`（经 `memcached.sh`/`imageMagick.sh`/`ionCube.sh`/
     `apcu.sh` 或直接调用），单独运行时必然 `command not found`。
     没有 `set -e`，于是"下载失败 → 守卫失效 → 继续解压编译"。
  2. 两个 `tools/` 脚本**完全没有设 `cur_dir`**。
     `Verify_Download_File` 把清单路径拼成 `/src/checksums.sha256`，
     `Tar_Cd` 会 `cd /src`：默认配置下 DenyHosts / Fail2ban 不是偶发失败，
     是**必然装不上**（清单不存在 → fail-closed → `exit 1`）。
- **改动**：
  - `Require_File` 定义移到 `include/main.sh`（所有入口都加载的模块），
    `dbcommon.sh` 原处留注释说明去向。
  - 两个 `tools/` 脚本用 `cur_dir=$(cd "$(dirname "$0")/.." && pwd)` 推导，
    并把 `. ../lnmp.conf` 之类的相对加载改成 `"${cur_dir}/..."`，
    `cd ../src` 改成 `cd "${cur_dir}/src"`：现在从任意目录执行都对。
- **同时确认**：`denyhosts-3.1.tar.gz` 与 `fail2ban-1.1.0.tar.gz` 已在
  `src/checksums.sha256` 里（174、175 行），修好 `cur_dir` 后校验就能真正生效。
- **行为变化**：**有**：DenyHosts / Fail2ban 从「必然失败」变为可安装；
  addons.sh 各插件下载失败时现在会真正中止而不是继续编译。
- **验证**：`bash -n tools/*.sh include/main.sh include/dbcommon.sh`；
  `grep -rn 'Require_File' --include='*.sh' .` 的调用点全部落在加载了 main.sh 的入口下
- **验证状态**：已验证，见阶段 11 `GHA-007`、`GHA-009` 的入口一致性与脚本执行检查（2026-08-11 复核）。

### FIX-PM-001 不再强杀包管理进程、不再删除系统锁

- **文件**：`include/main.sh`（`Kill_PM` → `Wait_PM`）
- **类别**：SEC/FIX
- **问题**：`Kill_PM` 用 `ps aux | grep -E "apt-get|dpkg|apt"` 找进程后 `kill -9`
  全部干掉，再 `rm` 掉 yum/dpkg 的锁文件。它由 `Press_Install` 在**每次完整安装
  开始时**调用。三个毛病：匹配太宽（命令行里带 "apt" 的无关进程会被误杀）；
  在 dpkg/rpm 写数据库中途 SIGKILL 会留下半配置的包和损坏的数据库；
  删活跃锁等于把并发保护关掉。
- **改动**：改为**等锁释放**。用 `fuser` 判断锁文件是否真被进程持有
  （回答"锁现在有没有主人"，而不是"有没有进程名字像包管理器"），
  最多等 `PM_Lock_Wait_Sec=300` 秒；超时明确 `exit 1` 让管理员处理。
  没有 `fuser` 时打印提示后跳过，不做任何破坏性动作。
  `Kill_PM` 保留为 `Wait_PM` 的别名，调用点不动。
- **行为变化**：**有**：系统自动更新期间安装会等待而不是打断它；
  长时间占用会导致安装退出（这正是目的）。
- **返工（2026-08-09 二轮）**：**逐条复核，未发现与代码不符之处。**
  `Wait_PM` 存在，用 `fuser` 判断锁归属、`PM_Lock_Wait_Sec=300`、
  无 `fuser` 时只提示不做破坏性动作、超时 `exit 1`；
  `Kill_PM` 作为别名保留（`include/main.sh:260`），
  由 `Press_Install`（`:277`）调用：调用点确实没动 通过
  全仓库已无 `kill -9` 包管理进程、无删除锁文件的代码 通过
  本条**保持原结论**。该结论保留待进一步证据确认。
- **验证状态**：已验证（静态专项复核），见阶段 11 `GHA-009` 及阶段 15 回归检查（2026-08-11 复核）。

### SEC-PERM-001 恢复最小权限基线

- **文件**：`include/init.sh`（`Disable_Selinux` → `Setup_Selinux`）、
  `include/nginx.sh`、`include/apache.sh`、
  `include/php.sh`、`include/multiplephp.sh`、
  `include/upgrade_php.sh`、`include/upgrade_mphp.sh`、`lnmp.conf`
- **类别**：SEC 安全修复
- **改动 1：SELinux 默认不再关闭**：
  旧实现无条件执行 `setenforce 0`，并将 `/etc/selinux/config` 改为 `disabled`，
  等于替用户永久拆掉整台机器的强制访问控制。在供应链场景下代价尤其大：
  万一编译产物或 Web 进程被投毒，SELinux 正是最后一道限制横向移动的机制。
  新增 `Disable_Selinux`（默认 `n`）：默认保留 SELinux，只尽量给
  `${Default_Website_Dir}` 与 `/home/wwwlogs` 打上合适上下文并开必要 boolean；
  显式设 `y` 才恢复原来的关闭行为。
  **注意：限制**：本包源码编译装到 `/usr/local`，targeted 策略没有对应规则，
  enforcing 路径**未在 RHEL 上验证过**，配置文件里已写明如何回退。
- **改动 2：日志目录 777 → 755**：`/home/wwwlogs` 原为 **777**，
  任意本地账号都能删除或伪造访问日志。日志文件由 nginx/httpd 的 master（root）
  创建，www 不需要写目录本身，改为 `755 root:root`。
- **改动 3：站点根目录**：`chmod +w` 不指定主体，结果取决于调用者 umask，
  umask 宽松时可能变成世界可写。改为显式 `chown -R www:www` + `chmod 755`。
- **改动 4：FPM socket 0666 → 0660**（4 处 pool 配置）：
  0666 意味着机器上**任何本地账号**都能连 FPM socket，构造 FastCGI 请求
  让 PHP 执行其可控脚本，等于直接暴露一个 `www` 身份。
  0660 + `listen.owner/group = www` 后只有 www 组能连，
  而 nginx worker / httpd 正是以 www 运行，不受影响。
- **行为变化**：**有**（四项都改变了默认安全姿态）
- **验证状态**：已验证，见阶段 8 `SEC2-003` 的服务身份与权限实测、阶段 14 完整安装复验（2026-08-11 复核）。

### FIX-BUILD-001 编译与解压步骤失败即停

- **文件**：`include/init.sh`（`Make_Install` / `PHP_Make_Install`）、
  `include/main.sh`（`Tar_Cd`）、`include/nginx.sh`（`Install_Nginx_Lua`）
- **类别**：FIX 缺陷修复
- **问题**：
  1. `Make_Install` 并行失败后退回串行重试（这个设计是对的），
     但**未检查第二次 `make` 和 `make install` 的结果**，编译失败后仍会继续执行。
  2. `Tar_Cd` 的 `cd` / `tar` / `cd` 三步返回值全不看。归档结构与预期不符时
     最后那个 `cd` 进不去，**当前目录还停在 `src/`**，
     调用方紧接着的 `./configure && make install` 就在 `src/` 里跑了。
  3. `Install_Nginx_Lua` 只对 LuaJIT / lua-nginx-module / ngx_devel_kit 三个
     调了 `Require_File`，**漏了 lua-resty-core 和 lua-resty-lrucache**；
     而新版 lua-nginx-module 运行时依赖 resty core：少了它编译能过，
     要到 nginx 启动才报模块缺失。
- **改动**：
  - `Make_Install` / `PHP_Make_Install` 任一步失败 → `Echo_Red` + 返回非零。
  - `Tar_Cd` 每步硬失败；未知扩展名也拒绝；
    `cd` 不进解压目录时明确报"归档结构与预期不符"并 `exit 1`。
  - 补上两个缺失的 `Require_File`；LuaJIT 的 `make` / `make install`、
    两个 resty 库的 `make install`、两处 `tar zxf` 全部加失败即停。
  - **新增冒烟测试**：Lua 组件安装后使用新安装的 luajit
    `require("resty.core"); require("resty.lrucache"); require("cjson")`，
    失败即中止：这正是"编译期查不出、启动期才失败"的那类问题的拦截点。
- **补充（2026-08-09）： `./configure` / `cmake` 的返回值检查**：
  全仓库约 30 处 `./configure` / `cmake`，**没有逐个加 `|| exit`**，
  而是新增 `Check_Makefile_Ready()` 作为**单一捕获点**，在
  `Make_Install` / `PHP_Make_Install` 开头调用。
  理由：configure/cmake 失败的表现是一致的：**当前目录不产出 Makefile**；
  在这里查一次等价于给全部调用点都加上检查，报错信息也比让 make 自己抱怨
  "No targets specified and no makefile found" 清楚得多。
  逐个加的写法在 30 处的规模上必然漏掉几个，而且以后每加一个组件都要记得加。
- **补充（2026-08-09）： 调用点的失败处理**：
  安装侧 26 处 `Make_Install || exit 1` / `PHP_Make_Install || exit 1`，
  `pureftpd.sh` 补 1 处，升级侧 4 处走 `if ! Make_Install; then` 分支。
  三条数据库升级路径（`upgrade_mysql.sh` ×2、`upgrade_mariadb.sh`、
  `upgrade_mysql2mariadb.sh`）的失败分支还**打印人工恢复步骤**：
  编译失败时旧库已经停掉并 `mv` 走了，光说一句"升级失败"等于把人扔在半截状态里：
  现在会向管理员说明把哪个目录搬回去、恢复哪个 init 脚本、怎么启动、备份 SQL 在哪。
- **注意：未做**：数据库升级的**自动**回滚事务（见 `TXN-001` 末尾的说明）。
- **行为变化**：**有**：构建失败从"静默继续"变为"就地停止"。
- **返工（2026-08-09 二轮）**：**本条改的部分属实，但只覆盖了一半的安装路径。**
  `Make_Install` / `PHP_Make_Install` / `Tar_Cd` / Lua 冒烟测试都在，
  后来又补了 `Check_Makefile_Ready` 与全部调用点的失败处理（见上方两条补充）。
  **漏的是数据库的通用二进制落地路径**：那是本包**默认**的数据库安装方式
  （`DB_Bin_Default='auto'`），三处 `Tar_Cd` + `mkdir` + `mv` 的返回值一个都不看，
  比有 `Make_Install` 兜底的源码路径保护得还少。由 `FIX-BIN-001` 补上。
- **验证状态**：已验证，见阶段 8 完整安装、阶段 14 `REF-LUA-001` 及阶段 15 主线验收（2026-08-11 复核）。

### FIX-CONF-002 lnmp.conf 全部开关改为可被环境变量覆盖

- **文件**：`lnmp.conf`（26 个变量）
- **类别**：FIX 缺陷修复
- **问题**：`FIX-CONF-001` 声称 `CheckMirror` 可以用
  `CheckMirror=n ./install.sh lnmp` 传入，**实际不能**。
  `install.sh` 是先读调用者环境、再 `. lnmp.conf`，
  而配置文件里写的是无条件赋值 `CheckMirror='y'`：环境里的 `n` 被直接冲掉。
  自动化以为关掉了换源/NTP/联网探测，实际全都照做。
- **改动**：文件里所有 `VAR='value'` 统一改成 `VAR="${VAR:-value}"`
  （共 26 个，含 `CheckMirror`、`Enable_Download_Checksum`、
  `Default_Website_Dir` 等）。只在未设置时赋默认值，环境变量真正生效。
  文件里加了一段注释说明原因必须这么写。
- **行为变化**：**有**：环境变量现在真的能覆盖配置。
- **验证状态**：已验证，见阶段 8、阶段 14 使用环境变量完成的非交互完整安装（2026-08-11 复核）。

### DEL-IONC-001 ionCube Loader 暂未接入安装流程

> **注意：本条已两次订正（2026-08-09）。原标题是「移除 ionCube 闭源 Loader」，
> 原结论与原理由都被推翻，下面保留全部经过。**

- **文件**：`addons.sh`、`src/checksums.sha256`、`README`
- **类别**：~~SEC 安全加固~~ → **范围决定**（不是安全整改）
- **当前事实**：`./addons.sh install ionCube` 打印说明并退出；
  `uninstall` 保留（只删 ini 并重启 PHP，不下载、不落地二进制）；
  `src/checksums.sha256` 里那条 x86-64 哈希被注释掉；
  编号 6 保留不复用（静默改成别的插件会让沿用旧编号的脚本装错东西，
  与主菜单 `Legacy_Selection_Hint` 同一口径）。

**注意：订正一：原来给出的理由不成立**

原文写的是：ionCube 是「运行期加载的不可审计本机代码」，
「没有源码、没有可复现构建、没有独立厂商签名验证」，
「与本包源码可读、逐个哈希的口径直接冲突」。

**本项目已明确否定这个理由**：
从 ionCube 官方域名（`downloads.ioncube.com`）取得的预编译二进制是**可接受的**，
本项目**不要求**第三方扩展提供可审计源码或可复现构建。

而且这条标准本身就不自洽：按同一口径衡量：
各 pecl 扩展是预编译分发的、MySQL / MariaDB 的**官方通用二进制包**更是
本包**默认**的数据库安装方式（`DB_Bin_Default='auto'`）。
以"必须源码可审计"排除 ionCube，却继续使用这些组件，判定标准不一致。

**真正剩下的技术障碍只有一个**（这一条经复核属实）：
原代码宣称支持 `x86` / `armv7l` / `aarch64`（`ARCH` 的三条映射分支），
而 `src/checksums.sha256` 只登记过 x86-64 一条：
非 x86-64 路径在 fail-closed 下必然中止，那几个架构的"支持"是假的。
要接回安装流程，需要按架构补齐校验条目。

**注意：订正二：「文件已删除」与实际不符**

原文写「**删除 `include/ionCube.sh`** 与 `addons.sh` 对它的 source」，
并在「已移除」标题下描述整件事。与工作区实际对照：

| 原文声明 | 实际 |
|---|---|
| 删除了 `include/ionCube.sh` | 全仓库 `find -iname '*ioncube*'` **无结果**；ionCube 逻辑一直内联在 `addons.sh` 里，没有这个文件可删 |
| ionCube 功能「已移除」 | `addons.sh` 里函数、菜单第 6 项、三处 usage 串**全都还在** |
| 那条哈希「已随 ionCube 功能一并移除」 | `t/gen_checksums.sh:191` 与 `t/probe_urls.sh:158` **仍在采集/探测该下载 URL** |

即：既没有删掉声称删掉的文件，"功能已移除"也言过其实：
准确的说法是**安装入口被改成拒绝，其余原样保留**。
`addons.sh:25` 与 `:36-57` 的同款措辞、`README`、
`src/checksums.sha256` 的注释均已一并订正。

- **改动（本次订正）**：
  1. 全部措辞由「已移除 / 因不安全而去掉」改为「**当前未接入安装流程**」，
     并写明**这不是安全判定**；
  2. `ionCube_Removed_Notice` 由红字改为黄字，内容改为说明真实原因
     （校验条目只有 x86-64）并指向官方站点；
  3. 菜单分组标题 `##### 已移除 #####` → `##### 暂未接入 #####`；
  4. `src/checksums.sha256` 的注释写明「不是因为不可信」以及接回来需要做什么。
- **未做**：**没有恢复安装功能**。用户此前明确「ionCube 无安全整改要求，
  只需修正 changelog 中的错误声明」，故本次只订正声明，不动安装流程。
  是否接回来是一个独立决定（需要按架构补齐 `src/checksums.sha256`）。
- **`t/` 两处残留未处理**：`t/gen_checksums.sh` 与 `t/probe_urls.sh` 里的
  ionCube URL 保留原样：用户已明确 `t/` 相关问题本阶段不投入。
  记在这里是为了让「功能已移除」这个说法不再被当成事实。
- **行为变化**：无（本次只改文案与注释，不改任何执行逻辑）
- **验证**：`bash -n addons.sh`；
  `grep -rn 'Install_ionCube' --include='*.sh' .` 无结果；
  `find . -iname '*ioncube*'` 无结果；
  `grep -rniI ioncube .` 的全部命中已逐条核对
- **验证状态**：已验证（静态专项复核），见阶段 11 `GHA-007` 的跨文件一致性检查（2026-08-11 复核）。

### SEC-WEB-003 清除默认部署页面里的站外链接

- **文件**：`conf/index.html`、`conf/redis.php`、
  `conf/memcached1.php`、`conf/memcached2.php`
- **类别**：SEC 安全加固
- **问题**：这四个页面会被部署到**用户站点的根目录**，对任何访客可见。
  `index.html` 里有 5 条指向 `lnmp.org` / `bbs.vpser.net` / `www.vpser.net`
  的外链（其中两条是 VPS 推广），三个 PHP 测试页页脚各有 2 条。
  它们不是自动下载链，但会把管理员或访客引向本包已判定不可信的域名：
  域名易主、跳转投毒都是现实风险，而且这些页面在用户自己的域名下，
  看起来像是站点主人的背书。
- **改动**：四个文件里的站外 `<a href>` 全部删除，改为指向随包的
  README / changelog.md。`index.html` 页脚的署名保留文字、去掉链接。
- **与 SEC-WEB-002「署名链接保留」的关系**：那条针对的是**代码注释**里的
  `https://lnmp.org`（出处标注，只有维护者看得到）。
  这里是**部署到公网页面上的可点击链接**，两者不是一回事，口径不冲突。
- **行为变化**：**有**（页面内容变化，不影响功能）
- **验证**：`grep -rnE 'lnmp\.org|vpser' conf/index.html conf/*.php` 无结果
- **验证状态**：已验证，见阶段 14 完整安装后的默认站点与 WordPress 访问复验（2026-08-11 复核）。

### SEC-TOOL-001 重写 root 密码重置工具

- **文件**：`tools/reset_mysql_root_password.sh`（整体重写）
- **类别**：SEC 安全修复
- **问题**（复核后确认，共发现以下问题）：
  1. `mysqld_safe --skip-grant-tables` **没有** `--skip-networking`，
     重置窗口内数据库可能带着"无需鉴权"的状态监听在网络上。
  2. 固定 `sleep 5` 就认为起好了：起慢了直接失败，起快了白等。
  3. 结束时 `killall mysqld`，杀的可能是别的实例；
     脚本也从不确认自己连上的到底是不是刚拉起的那个临时实例。
  4. 密码原样拼进 SQL 单引号：含 `'` 或 `\` 的**合法**密码会语法错误，
     构造过的输入能改变 SQL 语义；成功后还把明文密码打印到终端。
  5. **版本正则错误**：
     `'^8.0.|^5.7.|^10.[2345678].'` 不但点号没转义，而且
     **漏了 MySQL 8.4 和 MariaDB 11.x**：本包当前默认就是这两类。
     它们会落进 `else` 分支执行
     `update mysql.user set password = Password(...)`，
     该语法在 MySQL 8.x / MariaDB 11.x 上早已不存在，
     于是脚本报"重置成功"，密码其实一点没改。
- **改动：改用官方推荐的 `--init-file` 恢复流程**：
  它在服务器启动阶段以内部特权执行那条 SQL，**全程不需要
  `--skip-grant-tables`**，也就不存在"临时开放一个无鉴权数据库"的窗口。
  配合 `--skip-networking` + 私有 socket，只能从本机 Unix socket 访问。
  其余：
  - 私有 `mktemp -d` 工作目录（`umask 077` + `chmod 700` + `trap` 清理），
    socket / pid / init-file / 日志全在里面；
  - 用 `mysqladmin ping` 轮询等待就绪（上限 120 秒），不再固定 `sleep`；
  - 通过**显式指定的 pid 文件**确认临时实例身份，
    再用 `mysqladmin shutdown` 优雅关闭，不再 `killall`；
  - 密码用 `read -s` 读取、两次确认、**全程不回显**，也不写进任何留存文件；
  - SQL 转义用 bash 参数展开（先转 `\` 再转 `'`，顺序不能反），
    已用 `it's` / `back\slash` / `'; DROP TABLE mysql.user; --` 等
    7 组输入验证过生成的语句；
  - 版本判断改用 `sort -V` 的 `Version_GE`，低于 MySQL 5.7 / MariaDB 10.2
    **明确拒绝**，而不是悄悄退回一条早已不存在的 SQL；
  - 每一步失败都有明确报错，临时实例起不来时会恢复原服务并 `exit 1`。
- **行为变化**：**有**：输入密码时不再回显（这是有意的）；
  过老的数据库版本从"假装成功"变为"明确拒绝"。
- **返工（2026-08-09 二轮）**：**逐条复核，未发现与代码不符之处。**
  `tools/reset_mysql_root_password.sh` 现在走 `mysqld_safe --init-file`
  + `--skip-networking` + 私有 socket；`Version_GE` 版本门槛、
  `mysqladmin ping` 轮询、`mysqladmin shutdown` 均在；
  代码中已无 `killall`（仅在开头注释中作为旧实现的问题被提及）；
  密码用 `read -s` 读入、不回显、经 `Sql_Quote` 转义 通过
  本条**保持原结论**。该结论保留待进一步证据确认。
- **验证状态**：待人工真机验证（涉及数据库 root 凭据与破坏性密码重置，只在隔离真机人工执行；2026-08-11 复核）。

### FIX-UNINST-001 卸载流程的数据保护与多 PHP 清理

- **文件**：`uninstall.sh`
- **类别**：FIX 缺陷修复
- **问题 1：可能造成不可恢复的数据丢失**：
  三个卸载函数都是 `mv ${MySQL_Data_Dir} /root/databases_backup_<ts>` 之后
  **不看返回值**，紧接着 `rm -rf /usr/local/${DB_Name}`。
  而默认的 `MySQL_Data_Dir` 是 `/usr/local/mysql/var`：**就在待删目录里面**。
  只要 `mv` 失败（磁盘满、`/root` 只读、目标已存在……），
  后续 `rm -rf` 会同时删除数据库数据，而脚本仍会打印"卸载完成"。
- **问题 2：多 PHP 清理对当前版本完全无效**：
  循环写的是 `for mphp in /usr/local/php[5,7].[0-9]`，
  **匹配不到 `php8.x`**，而本包现在只支持 PHP 8.x：
  卸载后会留下 `/usr/local/php8.3`、`/etc/init.d/php-fpm8.3` 和开机自启项。
  字符类里那个逗号还是笔误：`[5,7]` 表示"5 或 `,` 或 7"，
  同时允许了 `/usr/local/php,.3` 这种路径。
  更麻烦的是 **LNMPA / LAMP 两个分支没有这个循环**，三个栈行为不对称。
- **改动**：
  - 新增 `Backup_DB_Data()`：`mv` 失败 → `exit 1`；
    搬完还要确认目标目录存在且非空（防 `mv` 返回 0 但结果不对，
    例如目标是已存在目录、源被搬成了它的子目录）；
    并检查备份路径不在 `/usr/local` 下（在的话等于没备份）。
    **任何一项不满足都在删除任何文件之前中止**。
  - 新增 `Remove_Multiple_PHP()`：由受支持版本表 `8.0..8.5` 驱动
    （与 `include/profile.sh` 一致），逐个停服务、撤自启、删 init 脚本、
    删 `enable-php<ver>.conf`、删目录。**三个栈共用同一实现**。
  - `Remove_DB_Files()` / `Remove_Acme()` 同样抽成共享函数，
    消掉三份逐字重复的代码。
  - `Remove_Acme` 同时修一个逻辑错误：原来是
    `if crontab -l|grep -v "..."`：`grep -v` 只要还有**任何别的**
    crontab 行就返回 0，判断条件写反了，应该用 `grep -q` 判存在。
- **同时修掉入口的三处笔误与一处缺失**：
  `case` 模式 `[lL][nN][nM][pP]` 拼出来是 "lnnp"、
  `[lL][aA][nM][pP]` 是 "lanp"：按提示输入 `lnmp` / `lamp` 匹配不上。
  另外原来没有 `*)` 分支，输错任何值都静默退出且退出码为 0。
- **行为变化**：**有**：备份失败从"继续删除"变为"中止且不删任何文件"；
  PHP 8.x 多版本现在会被真正清理；输入非法值会报错退出。
- **验证**：`bash -n uninstall.sh`
- **返工（2026-08-09 二轮）**：**逐条复核，未发现与代码不符之处。**
  `Backup_DB_Data()` 存在且在两处调用点先于任何 `rm` 执行；
  多 PHP 清理改由 `MPHP_Supported_Vers='8.0 8.1 8.2 8.3 8.4 8.5'` 驱动，
  旧的 `/usr/local/php[5,7].[0-9]` 通配已不存在 通过
  本条**保持原结论**。该结论保留待进一步证据确认。
- **验证状态**：待收尾验证（尚未实际执行完整卸载并核对备份与多 PHP 清理；2026-08-11 复核）。

### FW-002 nftables 规则隔离，不再覆盖系统防火墙主配置

- **文件**：`include/firewall.sh`（大改）、`include/end.sh`
- **类别**：SEC 安全修复
- **问题 1：`Firewall_Save` 会清空整台机器的防火墙**：
  它把 `/etc/nftables.conf`（或 `/etc/sysconfig/nftables.conf`）**整个覆盖**，
  内容是 `flush ruleset` + 当时的全量 `nft list ruleset`。三个后果：
  1. 管理员原有的持久化结构、`include`、注释被抹掉，不可恢复；
  2. 采集失败时（`nft list` 出错、磁盘满）文件里可能**只剩 `flush ruleset`**：
     服务一重启，整台机器的防火墙规则被清空；
  3. 装/卸 Redis、Memcached、Pure-FTPd 都会再触发一次全量覆盖。
- **问题 2：抢 firewalld 的管理权**：
  `Firewall_Init` 检测到 firewalld 就 `stop` + `disable`，
  而且发生在**证明自己这套能用之前**。firewalld 可能正管着这台机器的
  全部策略（zone、rich rule、其他服务的端口），停掉它等于把那些一起作废。
- **问题 3：失败被转成成功**：`end.sh` 是 `Firewall_Init || return 0`，
  "防火墙没配上"和"配好了"对调用方毫无区别，3306 就这么失去防护。
- **改动**：
  1. **两种后端，不抢管理权**：firewalld 在跑就用 `firewall-cmd`
     （`--permanent` + `--reload`），完全不碰 nftables 规则集；
     否则才用自己的 `inet lnmp` 表。
  2. **只维护自己的文件**：规则写到 `/etc/nftables.d/lnmp.nft`，
     主配置至多**追加一行 `include`**（且先检查有没有），已有内容一律不动。
  3. **写入是原子的**：临时文件 → 内容完整性检查 → `nft -c -f` 语法校验 →
     `mv -f` 替换。任一步不过就保留旧文件，不得半截替换。
  4. **不再有 `flush ruleset`**：改用
     `table inet lnmp` + `delete table inet lnmp` + 完整定义 的标准幂等写法，
     全程只影响这一张表。
  5. `Firewall_Save` / `Firewall_Init` 每步失败都返回非零并置 `FW_Failed='y'`；
     `end.sh` 的 `Add_Iptables_Rules` 如实返回并明确提示"3306 可能暴露"。
  6. 同时：`Firewall_Allow` / `Firewall_Allow_ICMP` 补上表/链存在性检查：
     `pureftpd.sh` 会直接调它们而不先 `Firewall_Init`，
     原来这种情况下 `nft add rule` 是静默失败的。
- **行为变化**：**有**：不再停用 firewalld；不再改写防火墙主配置；
  防火墙配置失败会如实反映。
- **验证**：`bash -n include/firewall.sh include/end.sh`
- **返工（2026-08-09 二轮）**：**逐条复核，未发现与代码不符之处。**
  `FW_INCLUDE_FILE='/etc/nftables.d/lnmp.nft'`（只维护自己的文件）、
  firewalld 在跑时改走 `firewall-cmd` 共存而不停用它、
  `FW_Failed` 失败标记、`delete table` 幂等写法均在；
  全仓库已无 `flush ruleset` 通过
  本条**保持原结论**。该结论保留待进一步证据确认。
- **验证状态**：已验证，见阶段 8 `SEC2-004`、阶段 14 与阶段 15 的监听及防火墙复验（2026-08-11 复核）。

### SEC-CRED-001 消除固定临时文件、明文凭据回显与 SQL 拼接

- **文件**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp`、
  `include/main.sh`、`include/end.sh`、
  `include/upgrade_mysql.sh`、`include/upgrade_mariadb.sh`、
  `include/upgrade_mysql2mariadb.sh`
- **类别**：SEC 安全修复
- **问题 1：可预测的临时文件（本地提权面）**：
  `/tmp/.mysql.tmp`、`/tmp/.add_mysql.sql`、`/tmp/.del.mysql.sql`、
  `/tmp/pass<ftp账号>` 全是固定名字。本机任意低权限用户可以提前把它建成
  指向别处的符号链接，等 root 运行管理命令时，那条重定向就以 **root 身份**
  覆盖链接指向的文件。而这些文件里装的正是 SQL 和明文密码。
- **问题 2：明文凭据到处回显**：
  `main.sh` 选择阶段 `echo "MySQL root password: ..."`、
  `end.sh` 完成摘要再印一遍、`lnmp vhost add` 的摘要印数据库和 FTP 密码。
  整个输出被 `install.sh` 的 `tee` 写进 `/root/lnmp-install.log`，
  而 `Print_Failed_Info` 还引导用户把该日志上传到论坛：
  一条完整、可用的凭据外泄路径。
  数据库升级里的 `mysql_upgrade -u root -p${DB_Root_Password}`
  则把密码暴露在**进程参数**里，同机任何用户 `ps` 就能看到。
- **问题 3：SQL 直接拼接**：库名/用户名/密码只检查非空就塞进单引号或反引号。
  含 `'` 或反引号的**合法**密码会让语句语法错误，构造过的输入能改变 SQL 语义。
- **改动**：
  - 新增 `LNMP_Mktemp`：私有 `mktemp -d` 目录（`chmod 700` + `trap` 清理），
    所有临时文件放里面，名字不可预测。`Do_Query` 与四处 SQL/密码文件全部改用它。
  - 新增 `Sql_Quote`（先转 `\` 再转 `'`）用于密码；
    新增 `Check_DB_Identifier` 对库名/用户名/FTP 账号走
    `[A-Za-z0-9_]` 白名单：标识符没有可靠的通用转义方式，
    与其想办法转义不如直接拒绝越界输入。
  - 所有密码输入改 `read -r -s`（不回显）。
  - `end.sh` 新增 `Print_DB_Password_Notice`：用户自己输入的不回显；
    **随机生成**的写进 `/root/.lnmp_db_root_password`（`umask 077`）
    并告知路径，不再印到屏幕和日志。
  - 三处 `mysql_upgrade -u root -p<密码>` 改为 `--defaults-file=~/.my.cnf`。
  - `Make_TempMycnf` 先备份管理员原有的 `~/.my.cnf`，
    `TempMycnf_Clean` 结束时还原；旧实现会直接覆盖并删除原配置。
- **同时修掉一个失效分支**：`Edit_Database` 按
  `'^5.7.' / '^8.0.'` 分三条路，两条用的 `PASSWORD()` 函数在
  MySQL 8.0+ / MariaDB 10.4+ 早已移除；正则的点没转义、也没覆盖 8.4 与
  MariaDB：**本包的默认版本落进最后那条早已失效的 else**。
  现统一为 `ALTER USER ... IDENTIFIED BY`，在支持的版本上通用。
- **行为变化**：**有**：密码输入不再回显；完成摘要不再显示密码
  （随机生成的改为写文件）；库名/用户名字符集受限。
- **验证**：`bash -n conf/lnmp conf/lnmpa conf/lamp include/*.sh`；
  `grep -n '/tmp/\.add_mysql\|/tmp/\.del\.mysql\|/tmp/pass\${' conf/*` 只剩注释
- **返工（2026-08-09 二轮）**：主体复核属实：
  `LNMP_Mktemp`、`Sql_Quote`、`~/.my.cnf` 备份还原均在 通过
  **查出一处残留**：`TempMycnf_Clean()` 里还留着 `rm -f /tmp/.mysql.tmp`，
  那是旧实现固定临时文件名时代的清理动作。本条改完之后这个名字已不再产生，
  保留该文件名会使静态检索误判代码仍在使用固定临时文件。
  三份管理脚本里的这行已删除并加注说明。
  （安全影响：无：`rm -f` 不跟随符号链接，删的是链接本身。属清理不彻底。）
- **验证状态**：已验证，见阶段 12 `SEC2-007` 的恶意输入测试及阶段 15 建站、建库、删库实测（2026-08-11 复核）。

### SEC-INPUT-001 /bin/lnmp 的域名、附加域名与站点目录加严格边界

- **文件**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp`
- **类别**：SEC 安全修复
- **问题**：三份脚本以 root 运行，对三样输入只检查了"非空"
  （域名再加一条"不含空格"），而它们的去处都很实在：
  - **主域名** → 拼成 `/usr/local/nginx/conf/vhost/${domain}.conf` 的路径。
    含 `../` 的输入能让配置文件落到 vhost 目录之外。
  - **附加域名** → 原样插进 Nginx/Apache 配置。**完全不做语法检查**，
    含 `;` `{` `}` 的输入可以塞进配置语法片段。
  - **vhostdir** → 交给未加引号的 `mkdir -p`、`chmod -R 755`、`chown -R www:www`。
    含空格的目录名会被单词拆分，递归改权限打到别的目录上；
    值本身也没有任何范围限制，填 `/` 或 `/usr` 就是不可逆的破坏。
- **改动：三个校验函数，宁可拒绝古怪但合法的输入，也不接受能改变行为的输入**：
  - `Check_Domain_Name`：按 DNS 标签规则校验（字母数字加连字符、点分隔、
    可带 `*.` 泛域名前缀，长度 ≤253），**明确拒绝路径分隔符、空白，
    以及 `;` `{` `}` `$` 反引号等配置元字符**：它们对合法域名毫无意义。
  - `Check_More_Domains`：把空格分隔的串逐个交给上面那个，一个不合法就整体拒绝。
  - `Check_Vhost_Dir`：必须绝对路径；拒绝空白与 shell 元字符；
    折掉多余的 `/` 与 `./` 后拒绝任何 `..`；**限制在
    `/home` `/var/www` `/srv` `/data` `/www` 之下**；
    拒绝符号链接（否则递归改权限会跟着链接跑出去）；
    通过后把**规范化的路径写回 `vhostdir`**。
  - 三个函数接进了全部读取点：`Add_VHost`、`Del_VHost`、
    SSL 菜单、DNS-SSL 菜单、FTP 目录（每份文件 3~6 处）。
  - 所有 `mkdir -p ${vhostdir}` / `chmod -R` / `chown -R` / `.user.ini`
    路径统一加引号。
- **同时修一处会留下坏配置的流程**：`Create_VHost` 原来是
  `nginx -t` 之后**不看结果**直接 `nginx -s reload`。
  reload 会被 nginx 拒绝，但脚本报告成功，而那份坏配置还留在 vhost 目录里：
  下次 nginx 重启就起不来了。现改为测试不过就删掉刚写的 vhost 并 `exit 1`
  （LNMPA 两个配置一起撤，LAMP 同理）。
- **验证**：抽出三个函数跑了一组正反例，
  通过：`example.com` / `*.example.com` / `x1-y2.example.co.uk` /
  `/home/wwwroot/a.com` / `/home/wwwroot//a.com/`（规范化为 `/home/wwwroot/a.com`）；
  拒绝：`../../etc/nginx` / `a b.com` / `evil.com;}` / `x.com{root /;}` /
  `a$(id).com` / `-bad.com` / `no-dot` / `/` / `/etc` / `/usr/local` /
  `/home/../etc` / `/home/a b` / `/home/x;rm -rf /`。
- **行为变化**：**有**：以前能接受的畸形域名/路径现在会被拒绝并要求重输。
- **返工（2026-08-09 二轮）**：**逐条复核，未发现与代码不符之处。**
  `Check_DB_Identifier` / `Check_Domain_Name` / `Check_More_Domains` /
  `Check_Vhost_Dir` 四个校验函数在三份管理脚本中均存在 通过
  本条**保持原结论**。该结论保留待进一步证据确认。
- **验证状态**：已验证，见阶段 12 `SEC2-007` 的路径绕过测试及阶段 14、15 的 WordPress 建站流程（2026-08-11 复核）。

### VERIFY-001 新建 include/verify.sh，升级侧统一走可验证的下载

- **文件**：`include/verify.sh`（**新建**）、`conf/nginx-signing-keys.asc`（**新增**）、
  `include/main.sh`（`Download_Files`）、
  `include/upgrade_{nginx,php,mphp,mysql,mariadb,mysql2mariadb,phpmyadmin}.sh`、
  `include/init.sh`（`Download_Boost`）、
  七个入口脚本（加载 verify.sh）
- **类别**：SEC 安全修复
- **问题**：本包有两类下载，原先各走各的路，**行为正好相反**：
  - 安装侧走 `Download_Files` → fail-closed 静态清单。版本固定，这条没问题。
  - 升级侧的版本由**用户当场输入**，静态清单不可能预先收录。于是出现两种
    都不对的做法：`upgrade_nginx.sh` / `upgrade_phpmyadmin.sh` **直接使用未经额外校验的 wget**，
    连已有本地包都不校验就解压编译替换线上二进制（投毒窗口）；
    而 `upgrade_php/mphp/mysql/mariadb` 调 `Download_Files`，清单里没有那个版本
    → **必然 `exit 1`**（常规升级默认不可用）。两套相反的行为并存，
    维护者很容易误判"升级是有校验的"。
  - 另外 `Download_Files` 的 wget 不限制重定向次数，也拦不住 HTTPS→HTTP 降级：
    实测 `downloads.mariadb.org` 会 302 到第三方镜像、SourceForge 跳到动态
    镜像主机：**"代码里写的是官方域名"不等于"字节来自官方存储"**。
- **改动 1：统一取字节的地方（`Download_Fetch`）**：
  只走 HTTPS，**重定向也必须留在 HTTPS**，重定向次数上限 5。
  用 `curl --proto '=https' --proto-redir '=https' --max-redirs 5` 表达这两条；
  没有 curl 时退回 wget 并明确提示"这一层防护弱于预期"
  （wget 的 `--https-only` 只在递归模式下生效，没有等价选项）。
  安装侧的 `Download_Files` 也改成经由它取字节。
- **改动 2：动态版本去核对上游公布的校验值/签名（`Download_Verified`）**：
  校验强度按上游能提供什么依次退让，但**不得退到"不校验"**：

  | 上游 | 可用依据 | 实测 |
  |---|---|---|
  | PHP | `www.php.net/releases/?json&version=` 逐文件 sha256 | 通过 |
  | MariaDB | `downloads.mariadb.org/rest-api/mariadb/<ver>/` 的 sha256sum | 通过 |
  | phpMyAdmin | `<文件URL>.sha256` | 通过 |
  | Boost | `archives.boost.io/.../<文件>.json` 里的 sha256 | 通过 |
  | nginx | 只有 PGP 签名 `<文件URL>.asc` | 通过 验签 |
  | MySQL | **没有**机器可读的官方校验文件（`.asc` 全部 404） | 未通过 |

  顺序是：静态清单里有就用清单（与安装侧同一个值，两边不会打架）→
  上游官方 sha256 → PGP 验签 → **都没有就报错退出**，
  并告诉使用者怎么把哈希写进 `src/checksums.sha256`。
  MySQL 走的正是最后这条：明确报错，而不是"拿不到校验值就照装"。
- **改动 3：nginx 的 PGP 验签**：新增 `conf/nginx-signing-keys.asc`
  （nginx.org 公布的 6 个签名公钥）。用 `gpgv --keyring` 验签：
  它只做"用指定钥匙串验签"这一件事，不需要 gpg-agent、不碰用户的 `~/.gnupg`、
  也不会把公钥导进任何信任库。**公钥随包分发不联网取**：
  从签名同源的站点取公钥等于用攻击者的钥匙验攻击者的包。
- **实测验证**：
  - 上游 sha256 与 `src/checksums.sha256` 的**双向交叉核对**：
    php-8.3.33 / php-8.4.24 / mariadb-11.8.8 / mariadb-10.11.18-linux-systemd-x86_64 /
    phpMyAdmin-5.2.3 **五条全部逐字节一致**。
  - nginx-1.30.4.tar.gz 的 `.asc` 用随包公钥验签：
    `Good signature from "Roman Arutyunyan <r.arutyunyan@f5.com>"`。
  - boost 1.77.0 / 1.84.0 的官方 `.json` sha256 均能取到。
- **不依赖 python/jq**：JSON 取值用一个十几行的 `_Json_Sha256_After`
  （按逗号拆行 + 锚点向后找），本包是纯 Shell 安装器，
  为读一个字段引入运行时依赖不划算。
- **行为变化**：**有**：nginx/phpMyAdmin 升级从"不校验"变为强制校验；
  PHP/MariaDB 的常规版本升级从"默认不可用"变为可用；
  MySQL 升级到清单外的版本会明确报错（原先也失败，但错误信息没有指向解法）。
- **返工（2026-08-09 二轮）**：`include/verify.sh` 的四个核心函数
  （`Download_Fetch` / `Verify_SHA256_Value` / `Upstream_SHA256` / `Download_Verified`）
  均存在且被升级侧调用 通过 **但有两处实质缺陷，都不是小问题**：
  1. **nginx 验签是坏的**：依赖判断写成"gpgv 和 gpg 有一个就放行"，
     而 `--dearmor` 只有 gpg 有、验签要用 gpgv，两个都得有；
     `gnupg` 还不在依赖清单里；钥匙串未收窄（随包公钥文件不在
     `src/checksums.sha256` 里，被换掉不会被任何机制发现）；
     只看退出码不确认 `GOODSIG`。全部由 `SEC-SIG-001` 修掉并做了真包实测。
  2. **升级侧有 4 处缓存绕过**：`upgrade_mysql.sh` / `upgrade_mariadb.sh` /
     `upgrade_mysql2mariadb.sh` 在外面套了 `if [ -s ]`，
     文件已存在时 `Download_Verified` 不执行。由 `SEC-CACHE-001` 修掉。
- **验证状态**：待收尾验证（升级下载与缓存分支虽经专项检查，完整升级路径尚未实跑；2026-08-11 复核）。

### CLN-301 删除随发行版下限一起失效的兼容分支

- **文件**：`include/main.sh`（新增 `Check_Supported_Distro`）、
  `include/init.sh`、`include/version.sh`、`include/end.sh`、
  `include/only.sh`、`install.sh`、`include/upgrade_php.sh`
- **类别**：CLN 清理 + FIX
- **问题**：复核发现条件路径仍会下载 `freetype-2.7`、ICU 58/60、
  OpenSSL 1.0.2u/1.1.1w，而这些**都不在 `src/checksums.sha256` 里**。
  进一步检查确认，其中三个函数
  （`Install_Openssl`、`Install_Openssl_Compat`、`Install_Icu60`）
  **全仓库零调用点**，是纯死代码；`Install_Icu4c` 的触发条件是
  `icu-config --version` 以 `3.` 开头（ICU 3.x 属 RHEL 5/6 时代）；
  freetype-2.7 那条 `else` 只服务于 CentOS ≤7 / Debian ≤8 这类系统。
  它们的共同点是：**即使被命中，也只会在 fail-closed 校验处中止**：
  代码表面包含支持分支，但实际无法使用。
- **改动**：
  1. 新增 `Check_Supported_Distro`：把发行版下限**显式写出来**
     （EL8+ / Debian 10+ / Ubuntu 18.04+ / Fedora 30+ 及同代），
     不满足就当场 `exit 1` 并说明原因。
     依据是本包的组件底线：PHP 8.0+ / MySQL 8.0+ / OpenSSL 3.5 / nginx 1.30。
     原先没有这道门，老系统会一路走到编译阶段才失败。
  2. 删除上述三个零调用点的函数与 `Install_Icu4c`（含两处调用点），
     以及 freetype 的 2.7 分支（改为明确报错，防止将来加新发行版时漏改条件）。
  3. `version.sh` 里随之失效的 `Freetype_Ver` / `Libicu4c_Ver` /
     `Openssl_Ver` / `Openssl_Compat_Ver` 一并删除，原处留注释说明去向。
- **注意：删变量时发现的一个真实隐患（同时修掉）**：
  `include/end.sh` 与 `include/only.sh` 各有两行
  `[[ -d "${cur_dir}/src/${Openssl_Ver}" ]] && rm -rf ${cur_dir}/src/${Openssl_Ver}`。
  只删变量定义而不删这两行的话，它会展开成
  `[[ -d "${cur_dir}/src/" ]] && rm -rf ${cur_dir}/src/`：
  **等于 `rm -rf` 掉整个 src 目录**。四行已一并删除，并在原处留注释说明。
- **行为变化**：**有**：低于下限的发行版从"跑到一半失败"变为"一开始就明确拒绝"。
- **验证状态**：已验证（静态专项复核），见阶段 11 `GHA-007`、`GHA-009` 及阶段 15 全量回归检查（2026-08-11 复核）。

### CHK-003 校验覆盖：架构与动态依赖

- **文件**：`include/profile.sh`、`src/checksums.sha256`、
  `include/init.sh`（`Download_Boost`）、`include/verify.sh`
- **类别**：SEC 修复
- **问题 1：虚假的架构支持**：`profile.sh` 宣称 MySQL 8.0 支持
  x86_64+aarch64、MariaDB 11.x 支持 i686/aarch64，而清单里只有 x86_64。
  实测（MariaDB 逐个查官方 REST API、MySQL 用 HEAD 请求）：
  - **MariaDB 三条 LTS 官方只提供 x86_64 的 linux-systemd 通用二进制**：
    i686/aarch64 是**不存在的包**，写在表里纯属虚假支持；
  - MySQL 8.0.46 确实有 aarch64 包，但 MySQL 不公布机器可读的校验值，
    本包无法自动核对它。
  → `DB_Bin_Archs` 全部收窄为 `x86_64`，并在注释里写明取值口径是
  「上游确实提供 **且** 本包能校验完整性」。
  **非 x86_64 不是不能装**：`Select_DB_Bin` 会自动落到源码编译，
  只是少了"下个二进制包直接用"的捷径。
- **问题 2：动态 Boost**：版本要从 MySQL 源码的 `cmake/boost.cmake` 解析
  （实测 8.0.46 要 **1.77.0**、8.4.7 要 **1.84.0**），
  而清单里只有 `boost_1_59_0` / `boost_1_67_0`（MySQL 5.7 时代的）：
  **源码编译 MySQL 必然在这一步中止**。静态清单原理上也穷举不了。
  → `Download_Boost` 改走 `Download_Verified boost`，
  从 `archives.boost.io` 的官方 `.json` 取 sha256，解析出哪个版本都能核对；
  清单里换成实际需要的 1_77_0 / 1_84_0（供离线安装用），
  并删掉两条 5.7 时代的遗留条目。
- **继续复核发现（2026-08-09）**：当前支持矩阵与清单的静态双向差集确为 0
  （期望 67、清单 67、缺失 0、陈旧 0），但 `Download_Boost()` 只在文件不存在时
  调用 `Download_Verified`。同名非空缓存会直接进入解压，静态清单和官方 JSON 都不检查。
  因而“动态依赖已验证”的核心安全结论仍不成立；详见审计记录中的缓存/旁载项。
- **返工（2026-08-09 二轮）**：**结论属实，但其中一半在代码里是被架空的。**
  - 架构收窄部分属实：`profile.sh` 五个数据库版本的 `DB_Bin_Archs` 均为 `x86_64` 通过
  - **动态 boost 部分当时不生效**：`Download_Boost` 确实改成了
    `Download_Verified boost`，但外面套着 `if [ ! -s boost_*.tar.bz2 ]`：
    文件已存在时整段都不执行，"动态取官方 sha256"从未发生。
    boost 是最不该开这个口子的：它的版本由**下载回来的 MySQL 源码树**决定。
    由 `SEC-CACHE-001` 修掉；同时删掉了不可达且绕过校验的 `pinned` 分支（`CLN-302`）。
- **验证状态**：已验证，见阶段 14、15 完整安装中的动态组件下载、校验与加载结果（2026-08-11 复核）。

### CHK-004 校验清单的可信来源与信任边界

- **文件**：`src/checksums.sha256`（头部说明）、`changelog.md`
- **类别**：DOC/SEC
- **问题确认**：`t/gen_checksums.sh` 是"下载后计算哈希"，
  这**不能**证明来源真实，只能证明一致性。原文档把两者混为一谈了。
- **本阶段实际做到的**：当前清单实际为 **67 条**。其中 15 条已与上游官方发布值
  独立核对一致：PHP 六个版本共 6 条；MariaDB 三个版本的源码包与 x86_64 systemd
  包共 6 条；Boost 1.77.0 / 1.84.0 共 2 条；phpMyAdmin 5.2.3 共 1 条。
  这些是**独立于"采集时获取的内容"的第二来源**。
- **Nginx 验签边界订正**：`conf/nginx-signing-keys.asc` 实含 8 把钥匙，不是
  `VERIFY-001` 声称的 6 把。7 把与当前官方 PGP 页面提供的 key 文件一致；第 8 把
  Maxim Konovalov 钥匙仍由 `nginx.org/keys/maxim.key` 官方托管，但已不在当前列表中，
  是否应继续信任无法确认。本阶段没有取得 nginx-1.30.4 源码包与 `.asc` 完成实际验签，
  因而不能沿用“已实测 Good signature”的结论。
- **注意：仍然不成立的部分（需要明确）**：清单里其余大多数条目
  （libiconv、pcre、jemalloc、各 pecl 扩展、GitHub tag 归档等）
  上游没有公布可自动核对的校验值，它们仍然只是"采集那一刻的一致性"。
  也就是说：**当前的 67 条哈希不能独立证明每个文件都来自未被篡改的上游**。
  这一条不因本阶段改动而消失，已写进「已知遗留问题」。
- **验证状态**：已验证（结论成立；数量、已核对范围和 Nginx 验签陈述已订正）

### TXN-001 升级流程改为「先验证、再切换、失败回滚」的事务

- **文件**：`include/upgrade_nginx.sh`、`include/upgrade_php.sh`、
  `include/upgrade_mphp.sh`、`include/upgrade_phpmyadmin.sh`、
  `include/multiplephp.sh`
- **类别**：FIX 缺陷修复
- **共同的病根**：**先把线上下线，再去做可能失败的事**。
  普通的下载失败、依赖缺失、编译错误就足以造成站点长时间不可用，
  而恢复要靠人工：脚本自己不会回滚。
- **nginx（`Upgrade_Nginx`）**：
  - 原顺序：编译（第二次 `make` 的结果不看）→ 立刻把现用 nginx 移走 →
    复制新二进制 → `nginx -t`（结果不看）→ `make upgrade`（结果不看）→
    最后只检查"文件存不存在"，失败分支还返回 0。
  - 新顺序的关键一步：**在动线上二进制之前，先用新二进制去测现有配置**
    （`./objs/nginx -t -p /usr/local/nginx -c .../nginx.conf`）。
    新版本删了某个指令、或这次少编了某个模块，这一步就能发现，
    而此时线上完全没被动过。
  - 之后：备份旧二进制 → 替换 → `make upgrade` → **确认进程在跑且
    `nginx -v` 是目标版本**。任一步失败调 `Rollback_Nginx`
    （换回旧二进制、`nginx -t`、reload 或重启）并 `exit 1`。
- **PHP（`Upgrade_PHP_8x`）**：
  - `lnmp stop` 与"把 `/usr/local/php` 移走"整段从**编译前**挪到**编译后**。
  - 用 `make install INSTALL_ROOT=<暂存目录>`（PHP 支持的 DESTDIR 机制）
    安装到暂存区，先执行 `php -v` 冒烟测试确认版本，**再**停止服务、
    备份旧目录、把暂存目录搬到 `/usr/local/php`。
  - 新增 `Rollback_PHP`：恢复旧目录、init 脚本、Apache 模块与 httpd.conf，
    重做符号链接并 `lnmp start`。
  - `Check_PHP_Upgrade_Files` 每个分支都给确定返回值，并新增两项复检：
    运行中的 `php -v` 是否为目标版本、php-fpm master 是否起来了。
- **多 PHP（`Upgrade_MPHP8x`）**：同 PHP 的处理。
  另外修复一个高风险失败分支：旧实现在失败时执行 `rm -rf ${Cur_MPHP_Path}`：
  **把新目录删掉就完事，备份从来不恢复**，结果是这个 PHP 版本
  直接从机器上消失。现在一律走 `Rollback_MPHP` 把备份换回去并返回非零。
- **phpMyAdmin（`Upgrade_phpMyAdmin`）**：
  旧实现**先移动线上目录**，再执行解压、mv、cp 和 chmod，且不检查中间返回值，
  最后无论如何都打印"upgrade completed"。归档结构一变，
  线上目录已经没了而新目录没建起来：站点直接 404，脚本却说成功。
  现改为：解压到暂存区 → 校验顶层目录与 `index.php` 存在 →
  在暂存区里把 config 和目录都准备好 → **最后才**备份线上目录并整体切换，
  失败恢复原目录。
- **新增多 PHP 版本（`Install_MPHP8x`）**：这是「新增」不是「升级」，
  现有站点不应受影响。旧实现却在下载源码**之前**执行 `lnmp stop`，
  而 `Require_File` 失败是 `exit 1` 且没有 trap：
  等于为了装个额外版本把线上站点弄停机。
  `lnmp stop` 已删除，`lnmp start` 保留在真正需要它的地方（让 nginx 读到
  新的 `enable-php<ver>.conf`）。
- **行为变化**：**有**：构建阶段失败不再造成停机；升级失败会自动回滚
  并返回非零（原先返回 0）。
- **注意：未做的部分（明确记下）**：数据库升级
  （`upgrade_mysql.sh` / `upgrade_mariadb.sh` / `upgrade_mysql2mariadb.sh`）
  的回滚事务**没有做**。它涉及数据目录迁移与 `mysql_upgrade`，
  回滚必须考虑数据一致性，不能只恢复目录，需要单独设计
  （见「已知遗留问题」）。
- **返工（2026-08-09 二轮）**：**已做的部分逐条复核属实**：
  `Rollback_Nginx`（3 个调用点）、`Rollback_PHP`、`Rollback_MPHP`、
  `Smoke_Test_PHP`、`Switch_To_New_PHP` 均存在 通过
  **未做且明确保留**：数据库升级的**自动**回滚事务没有做。
  该项已按需求约束归入 `暂缓 暂不处理`：属运营（可用性）类，
  且触发条件很窄（须同时"主动做数据库大版本升级"且"新版编译/初始化失败"），
  命中时机器不会被攻破，失败分支已打印完整的人工恢复步骤。见 `SCOPE-001`。
- **验证状态**：待收尾验证（数据库真实升级、失败回滚与恢复流程尚未实跑；2026-08-11 复核）。

### CLN-302 删除 boost 的 `pinned` 分支与两个固定版本变量

- **文件**：`include/version.sh`、`include/init.sh`、`include/end.sh`、`include/profile.sh`
- **类别**：CLN 死代码清理（`FIX-DB-001` 返工时发现）
- **问题**：`Boost_Mode` 有 `pinned` / `auto` 两种模式，`pinned` 用 `version.sh` 里写死的
  `Boost_Ver='boost_1_59_0'`。这条路只服务 MySQL 5.7，而 5.7 已随 `DEL-DB-001`
  （安装侧）和 `DEL-UPG-001`（升级侧）删干净了：没有任何 profile 会把
  `DB_Boost_Mode` 设成 `pinned`，`Boost_Mode` 里那条 `^5\.7\.` 的兜底同样打不到。
- **此外，它还是一条绕过校验的下载路径**：`pinned` 分支走的是未经额外校验的 `Download_Files`，
  而 `boost_1_59_0` 早已不在 `src/checksums.sha256` 里（`CHK-004` 换成了 1.77 / 1.84）。
  留着只会让人误以为「固定版本 boost」还是一条可用的退路。
- **改动**：删除 `pinned` 分支、`Boost_Ver`、`Boost_New_Ver`；
  `Boost_Mode` 收敛为 `auto` / `none` 两种；`profile.sh` 的字段说明同步更正。
  `end.sh` 的清理只留动态路径一条，并把「变量为空时 `rm -rf ${cur_dir}/src/`
  会删掉整个 src 目录」此风险写进注释（这是本次改造中真实触发过的一次险情）。
- **行为变化**：无：删的是不可达分支。
- **验证状态**：已验证（静态专项复核），见阶段 11 `GHA-007` 的跨文件一致性检查（2026-08-11 复核）。

### DOC-003 README 收尾：清掉与代码不符的字句

- **文件**：`README`
- **类别**：DOC 文档修正
- **口径（用户确认）**：**只删/改不实的，不扩写**。不新增章节、不重排结构，
  diff 保持最小，方便复核者逐条对照代码。
- **改动**：

  | 位置 | 原文与代码不符之处 | 改为 |
  |---|---|---|
  | `mphp` 说明 | 「只支持 7.2.x-7.2.x 类似小版本升级」 | 同大版本内小版本升级；列出实际支持的 8.0~8.5 |
  | `addons.sh` 用法串 | 列着 `eaccelerator\|xcache`，而 addons.sh 已不接受这两个参数 | 用法串去掉；条目保留并标注「已失效」 |
  | opcache / apcu | 指引访问 `ocp.php` / `apc.php` 管理界面 | 两个界面已随 `SEC-WEB-001` 移除，改为注明不再部署 |
  | ionCube | 「安装/卸载执行 `./addons.sh {install\|uninstall} ionCube`」 | install 已改为拒绝并打印说明；uninstall 保留用于清理旧安装的 ini |
  | sodium | 「PHP 7.2 以下版本不支持」 | 删除：本包最低 PHP 8.0，这句话没有适用对象 |
  | 多PHP目录示例 | `/usr/local/php5.6/` | `/usr/local/php8.3/` |
  | 多PHP版本号说明 | 「换成 5.\*、7.\* 或 8.\* 之类的」 | 「8.0~8.5」 |
  | 「已彻底移除的」清单 | 少列了两项 | 补上 APCu 管理界面 `apc.php`、ionCube Loader |

- **原因 xcache / eaccelerator 保留条目而不是删干净**（用户选定）：
  这两个是老用户会主动去找的名字。直接从文档里消失，人只会以为「文档漏写了」
  然后去翻 `addons.sh`；写明「已失效 + 原因」才真正回答了他们的问题。
  代码侧 `addons.sh` 本阶段不动：它已经不接受这两个参数，没有不一致。
- **行为变化**：无（纯文档）
- **验证状态**：已验证（文档复核），见阶段 13 发布前审计与阶段 15 主线验收口径（2026-08-11 复核）。

### SCOPE-001 处理范围收窄（**需求约束，非维护方判断**）

- **文件**：`README`（新增「支持的发行版与验证范围」）
- **类别**：DOC 范围声明
- **注意：这一条记录的是范围决定，不是复核结论，也不是本文档维护方的技术判断。**
  单独立条是为了让后续复核者知道「原因有些已确认的问题被搁置」：
  它们不是被漏掉的，是被有意排在后面的。

用户于 2026-08-09 明确四条：

1. **聚焦安全性问题。**
2. **运营类（可用性 / 易用性 / 排障体验）问题中，触发几率不大的可以不处理。**
   这类条目不纳入当前版本的整改范围，并记录触发条件，
   用于判断不同场景是否受影响。
3. **本文档里当时尚未收口的验证状态暂时不管**：等安全性问题全部解决后再上真机实测，
   届时一并复核。现在不必为了消掉这个字段做任何事。
4. **CentOS / RHEL 系不是主要关注对象**：代码里的支持保留
   （软件源已由 `REPO-001` 改为官方 HTTPS + `gpgcheck=1` + 随包固定公钥），
   但不投入额外验证轮次，README 已注明。主要目标是 Debian 系。

**按此搁置的条目**（当前只有一条）：

| 条目 | 类别 | 触发条件 | 搁置理由 |
|---|---|---|---|
| 数据库升级的**自动**回滚事务 | 运营（可用性） | 需同时满足：主动执行数据库大版本升级 **且** 新版编译/初始化失败 | 命中时机器不会被攻破，只是停在半截状态；失败分支已打印完整的人工恢复步骤 |

**没有任何安全类条目被搁置。**本阶段收尾时又做了一遍针对性扫描
（明文 HTTP 下载、禁用下载域名、`gpgcheck=0`、`chmod 777/666`、
`eval` 的输入来源、可预测临时文件），结果见 `SEC-SCAN-001`。

- **行为变化**：无（纯文档）
- **验证状态**：已验证（范围复核），见阶段 13、阶段 15 对主线与低优先级路径的分项记录（2026-08-11 复核）。

### SEC-SCAN-001 收尾安全扫描

- **类别**：SEC 验证记录（无代码改动）
- **背景**：需求约束「聚焦安全性问题」，故在收尾前对既有加固做一遍回归扫描，
  确认没有后续修改未引入回归的地方。扫描范围含无扩展名的
  `conf/lnmp` / `conf/lnmpa` / `conf/lamp`（这三个会被装成 `/bin/lnmp`，
  这些文件曾因静态检查按扩展名筛选而遗漏）。

| 检查项 | 结果 |
|---|---|
| 明文 `http://` 的下载/软件源/gpgkey | 通过 零命中（仅剩一条注释在讲被删除的旧实现） |
| 禁用下载域名 `vpser.net` / `soft.lnmp.com` | 通过 零命中 |
| `lnmp.org` | 通过 仅剩 `/bin/lnmp` 启动横幅里的**署名文字**，非下载源，非部署到网页 |
| `.repo` 文件的 `gpgcheck` | 通过 全部 `=1`，`gpgkey` 全部指向随包本地公钥文件 |
| `chmod 777` / `666` / `a+w` | 通过 零命中（仅剩注释记录旧实现） |
| 可预测的固定临时文件 | 通过 全部改为 `mktemp -d`（`/tmp/.lnmp-adm.XXXXXXXX`、`/tmp/acme.sh.XXXXXXXX`） |
| `eval` 的输入来源 | 通过 唯一一处 `Print_Sys_Info` 的 `eval`，`${DISTRO}` 只在代码内被赋成字面量，不接受外部输入 |

- **未列入本次扫描、仍然成立的信任缺口**：校验清单里大多数条目只能证明
  「一致性」而非「来源真实性」，MySQL 更是上游完全不提供机器可读校验值。
  见「阻断性提醒」与 `CHK-004`。这是**设计上的已知边界**，不是回归。
- **验证状态**：已验证（静态专项复核），见阶段 12 `SEC2-007`、阶段 13 发布前审计及阶段 15 回归检查（2026-08-11 复核）。

### SEC-CACHE-001 消除"文件已存在则跳过校验"的免检通道

- **文件**：`include/init.sh`（`Download_Boost`）、`addons.sh`、`include/apache.sh`、
  `include/upgrade_mysql.sh`、`include/upgrade_mariadb.sh`、
  `include/upgrade_mysql2mariadb.sh`、`include/main.sh`（`Verify_Download_File`）、
  `include/end.sh`
- **类别**：SEC 安全修复
- **问题**：`Download_Files` 与 `Download_Verified` **本身都是对的**：
  它们内部就处理"已存在则不重复下载"，且**无论是否新下载都会校验**。
  但有 6 处调用点在外面又套了一层 `if [ ! -s <文件> ]` / `if [ -s <文件> ]; then echo [found]`，
  于是文件已存在时**整个下载+校验函数不执行**：

  | 位置 | 组件 | 原因这处特别糟 |
  |---|---|---|
  | `init.sh` `Download_Boost` | boost | 版本由**下载回来的 MySQL 源码树**解析得出，本就是"下载内容驱动后续下载"的拼接 |
  | `upgrade_mysql.sh` | MySQL 源码 | MySQL 是唯一没有上游机器可读校验值的组件，静态清单是它**仅有**的一道防线 |
  | `upgrade_mariadb.sh` / `upgrade_mysql2mariadb.sh` | MariaDB | 升级路径，出问题时库已经停了 |
  | `addons.sh` | PHP 源码 | 装扩展要重新编译 PHP，等于用未校验源码替换线上 PHP |
  | `apache.sh` ×2 | APR / APR-util | 「src/ 下已有就直接 cp 进 srclib/」，连下载函数都不经过 |

  这不是"少校验一次"，而是**整轮 fail-closed 设计对缓存文件全面失效**：
  只要 `src/` 下先有一个同名文件（上次中断留下的、别人放的、被替换过的），
  它就会被直接拿去编译。
- **改动**：删掉全部 6 处外层 `if`，一律直接调下载函数，由它统一处理
  "已存在就不重下、但一定要校验"。`apache.sh` 改为先在 `src/` 里下载并校验，
  再 `cp` 进 `srclib/`。
- **同时修掉「校验总开关是静默的」**：`Verify_Download_File` 在
  `Enable_Download_Checksum != 'y'` 时是**静默 `return 0`**：
  `Enable_Download_Checksum=n ./install.sh lnmp` 能跑完全程一个字都不提示，
  日志里看不出这台机器的组件从来没被校验过。
  （`lnmp.conf` 的开关现在可被环境变量覆盖，见 `FIX-CONF-002`，
  所以"不小心关着跑完"比以前更容易发生。）
  现在每个文件都会红字提示，**并在安装结束的摘要里再警告一次**
  （`end.sh`）： 安装过程刷屏几千行，开头的警告早滚没了，
  而这句话决定了这台机器的组件到底有没有可信来源。
- **行为变化**：**有**：缓存文件现在也必须通过校验；
  校验关闭时从静默变为全程红字告警。正常安装流程无变化。
- **验证状态**：已验证，见阶段 14、15 完整安装中的缓存复用校验与组件安装结果（2026-08-11 复核）。

### SEC-ACME-002 关闭 acme.sh 的自更新通道

- **文件**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp`（三份 `/bin/lnmp`）
- **类别**：SEC 安全修复
- **问题**：`ACME-001` 把 acme.sh 的**安装**固定成了 tag + SHA256 校验，
  但没管**安装之后**。acme.sh 的 `--upgrade` 直接从 GitHub 拉最新代码覆盖自己，
  不核对任何哈希或签名：只要自更新是开着的，那个固定的 SHA256 第二天就不作数了。
  这是本包唯一一处「安装后仍会自我改写」的组件，**而它持有系统中的全部证书的私钥**。
- **改动**：
  1. 安装后显式执行 `acme.sh --upgrade --auto-upgrade 0`，关掉自带的自动升级；
  2. 定时自动升级的 crontab 本就已注释掉，保持不装；
  3. `upgrade.sh` 保留但改为**手动确认式**：打印风险说明、要求输入 `yes`
     才继续，升级完再关一次 auto-upgrade。
     需要跟进上游安全修复时由管理员自己决定，不在后台悄悄换掉。
- **原因不干脆删掉 `upgrade.sh`**：acme.sh 自己也会有安全修复，
  完全堵死升级路径会让人卡在一个有已知漏洞的版本上。
  正确的形态是「可以升，但必须是人有意识地升」，而不是「后台自己换」。
- **行为变化**：**有**：acme.sh 不再自动升级；手动升级需交互确认。
- **验证状态**：已验证（静态专项复核），见阶段 11 `GHA-009` 与阶段 15 回归检查（2026-08-11 复核）。

### SEC-REPO-002 宿主机软件源的信任预检（只警告，不阻断）

- **文件**：`include/init.sh`（新增 `Check_Host_Repo_Trust`）、
  `install.sh`、`include/only.sh`(2 处独立入口)
- **类别**：SEC 安全检查
- **问题**：本包所有编译依赖（gcc、各种 `-devel`）都来自**宿主机已配置的软件源**。
  这批包不经过 `src/checksums.sha256`，是整条供应链上**唯一没被本包覆盖的环节**。
  软件源本身若不可信，后续 fail-closed 校验无法覆盖由软件源安装的依赖；
  被篡改的编译器同样会影响最终构建结果。
- **原因做成「只警告」而不是拦截**（这是有意的设计选择）：
  内网镜像、公司自建源、离线场景下的 `[trusted=yes]` 都是**合法配置**。
  安装脚本无法代替管理员判断这些配置是否可信，因此只报告检测结果，
  由管理员根据实际环境决定是否继续。
  同理，本函数**只读**，不会修改任何源配置。
- **严重程度是分级的**，不能一律当漏洞报（全报出来人就不看了）：

  | 情况 | 判定 | 理由 |
  |---|---|---|
  | APT `[trusted=yes]` / `allow-insecure=yes` | ❗ 问题 | 直接关掉签名校验 |
  | APT `AllowUnauthenticated "true"` | ❗ 问题 | 全局允许未签名包 |
  | yum/dnf **启用中**的 repo `gpgcheck=0` | ❗ 问题 | 不验证包签名 |
  | yum/dnf `sslverify=0` | ❗ 问题 | 不验证 TLS 证书 |
  | 明文 `http://` 源 | ℹ️ 不报 | APT 的 Release 有 GPG 签名、yum 在 `gpgcheck=1` 时包签名仍有效，**http 本身不构成签名绕过**，只是丢失传输保密。报它属噪声 |
  | 第三方源目录下的条目 | ℹ️ 仅列出 | 是事实陈述，不是指控 |

- **yum 侧必须按 section 解析，不能整文件 `grep`**：发行版自带的 `.repo` 里
  常有一堆 `enabled=0` 的备用段（debuginfo / source / testing），
  它们带 `gpgcheck=0` 并不影响安全。整文件 grep 会把这些全报出来，
  噪声一大人就不看了，等于没做这个检查。现用 awk 逐段解析
  `enabled` / `gpgcheck` / `sslverify`，只报**启用中**的段，并打印段名。
- **调用点**：`install.sh` 的 `Init_Install`（放在 `Modify_Source` **之后**，
  这样本包自己改写过的 RHEL 源也一并被检查到，检查的是即将真正用于装依赖的
  最终状态）；`include/only.sh` 的 nginx / db 两条独立入口同样补上。
- **实测**（构造样例验证，非真机安装）：
  - APT：`[trusted=yes]`、`allow-insecure=yes`、`AllowUnauthenticated "true"` 三种全部命中；
    正常的 `deb http://deb.debian.org/debian bookworm main` **不误报** 通过
  - yum：`[thirdparty]` 段（`enabled=1` + `gpgcheck=0` + `sslverify=0`）命中并打印段名；
    `[base-debuginfo]` 段（`enabled=0` + `gpgcheck=0`）**不误报**；
    `[base]` 段（`gpgcheck=1`）不报 通过
  - 干净配置下输出「未发现关闭签名或 TLS 校验的软件源配置」通过
- **行为变化**：**有**：多一段只读检查输出；命中时暂停 10 秒让人看见。
  **不改变任何安装结果，不修改任何配置，永不返回非零。**
- **验证状态**：已验证（构造样例专项检查），见本条实测记录及阶段 15 回归检查（2026-08-11 复核）。

### SEC-SIG-001 nginx 验签：修正 gpg/gpgv 依赖、收窄钥匙串、确认验签结果

- **文件**：`include/verify.sh`（`Verify_Nginx_Signature`、新增 `Nginx_Key_Fingerprints`
  与 `Nginx_Key_Allowed`）、`include/init.sh`（依赖清单）
- **类别**：SEC 安全修复
- **三处缺陷，逐个说**：

**1. 依赖判断写反了**

  ```
  if ! command -v gpgv && ! command -v gpg; then 报错; fi
  ```

  这是「两个里有一个就放行」，可后面 **gpg 和 gpgv 是都要用的**：
  `--dearmor` 只有 `gpg` 有，验签用 `gpgv`。
  只装了 gpgv 的机器会一路走到 `gpg --dearmor` 失败，
  报出来的却是「无法解析 nginx-signing-keys.asc」，
  **把环境缺包误报成随包公钥文件损坏**，排查方向直接被带偏。
  现改为分别检查，并各自给出对应发行版的安装命令。

  **而且 `gnupg` 不在依赖清单里**：最小化安装的 Debian 上没有 gpgv，
  nginx 升级会直接卡死在这一步。已把 `gnupg gpgv`（Debian 系）与
  `gnupg2`（RHEL 系）加进 `Deb_Dependent` / `CentOS_Dependent`。

**2. 钥匙串没有收窄**

  旧实现将 `conf/nginx-signing-keys.asc` 中的**所有**公钥都视为可信。
  而这个文件**不在 `src/checksums.sha256` 里**（清单只管下载物），
  也就是说**它被替换不会被任何机制发现**：
  往里加一个公钥，攻击者签的包就能验过，整条 PGP 链就绕开了。

  现改为**指纹白名单**：`Nginx_Key_Fingerprints` 里固定 8 个主密钥指纹
  （取自 nginx.org 官方公布的签名密钥，2026-08 核对），
  dearmor 后逐个核对，出现清单外的密钥**整体拒绝验签**。
  宁可停下，也不拿一把来路不明的钥匙去验。

  > **维护提醒**：更新随包公钥时**必须**同步更新这份指纹清单，
  > 否则新密钥会被拒绝。这是有意的：公钥能被静默换掉才是问题。

**3. 只看退出码，没有确认验签结果**

  现改为 `gpgv --status-fd 1`，**解析机器可读输出**：
  必须出现 `GOODSIG`，且 `VALIDSIG` 给出的指纹要在白名单内。
  `VALIDSIG` 第 1 个参数是**签名密钥**指纹（可能是子密钥）、
  最后一个参数才是**主密钥**指纹，白名单存的是主密钥，
  所以两个都取、任一命中即可：用子密钥签名时只有最后那个能对上。
  成功时把签名者主密钥指纹打印出来。

- **另修一个隐蔽陷阱**：`gpgv --keyring` 的**相对路径会被当成相对 `~/.gnupg`**，
  找不到时不报路径错，而是一路走到 `Can't check signature: No public key`：
  表现得像公钥不对，实际是路径问题。本阶段实测触发过，已在代码里注释说明。
  （现用 `mktemp -d` 给的绝对路径，不受影响。）
- **实测**（nginx-1.30.4 真包 + nginx.org 的 `.asc`）：
  - 正常验签 → `GOODSIG` + 签名者主密钥 `43387825…15D87369`（Roman Arutyunyan），返回 0 通过
  - 文件被追加 1 字节 → `BAD signature`，拒绝，返回 1 通过
  - 模拟公钥文件被换（白名单改成不匹配值）→ 逐个报出白名单外的公钥并整体拒绝，返回 1 通过
- **行为变化**：**有**：缺 gpg/gpgv 时报错更准确；
  随包公钥与白名单不符时拒绝验签（此前会照验）。
- **验证状态**：已验证，见本条 nginx 1.30.4 真包验签、篡改拒绝与公钥白名单实测（2026-08-11 复核）。

### SEC-REPO-003 软件源预检补齐：http 扫描、准确行号、原文输出

- **文件**：`include/init.sh`（`Check_Host_Repo_Trust`）
- **类别**：SEC 安全检查（`SEC-REPO-002` 的补完）
- **问题**：上一版只报文件名，不给行号也不给原文，
  等于让人自己再去翻一遍配置：**这个检查的价值就在于"直接指到那一行"**，
  否则不如不做。另外明文 `http://` 源虽然不构成签名绕过，
  但完全不扫也不对：它常常是由其他人员配置的，应纳入检查结果。
- **改动**：
  - **统一输出格式 `文件:行号:原文`**，APT 与 yum 两侧一致。
  - **新增 http:// 扫描**，归入**提示**而非问题：
    APT 的 Release 有 GPG 签名、yum 在 `gpgcheck=1` 时包签名仍有效，
    http **不等于能被塞包**；它丢的是传输保密性和更早发现篡改的机会。
    把它计入问题数会淹没真正的问题，所以列出来但不计数。
  - APT 侧覆盖 **deb822 格式**（`.sources` 的 `URIs:` / `Trusted:`），
    不只是老式 `.list`。
  - yum 侧的 awk 除段名外还带出**行号与原文**，
    并处理 `gpgcheck = 0`（等号两边有空格）这类写法。
  - 补 `/etc/yum.conf`、`/etc/dnf/dnf.conf` 的全局 `gpgcheck=0` 行号输出。
- **实现注意事项**：`grep | while read` 在子 shell 中执行，
  循环内累加的 `problems` / `notes` 无法在循环外保留，导致检查始终报告"未发现问题"。
  改为先落到 `mktemp` 的临时文件再重定向读入。
- **实测**（构造样例）：
  - APT：`[trusted=yes]`（第 5 行）、`allow-insecure=yes`（第 1 行）、
    deb822 的 `Trusted: yes`（第 4 行）、`AllowUnauthenticated "true"`（第 1 行）
    全部命中并打印行号与原文 通过
  - http 提示正确列出 3 条（含 deb822 的 `URIs:`），且**不计入问题数** 通过
  - yum：`[thirdparty]` 的 `gpgcheck = 0`（第 16 行）与 `sslverify=0`（第 17 行）
    命中并打印段名、行号、原文；`[base-debuginfo]`（`enabled=0`）**不误报** 通过
- **行为变化**：无（仍是只读、只警告、永不返回非零）
- **验证状态**：已验证（构造样例专项检查），见本条 APT、deb822、yum 命中与误报测试（2026-08-11 复核）。

### DOC-004 二轮返工：14 条「已返工」的复核结果

- **文件**：`changelog.md`、`conf/lnmp` / `conf/lnmpa` / `conf/lamp`
- **类别**：DOC 文档修正
- **背景**：用户第二轮复核把阶段 7 的 14 条标为「已返工」。
  逐条对着代码核完，结论**不是一边倒的**，如实分成三类：

| 类别 | 条数 | 条目 |
|---|---|---|
| **范围漏了**：改的部分属实，但没覆盖到二轮才暴露的面 | 6 | `SEC-CHK-001`、`ACME-001`、`REPO-001`、`FIX-BUILD-001`、`VERIFY-001`、`CHK-003` |
| **结论被架空**：写了改动，但被外层逻辑绕过 / 明确未做 | 2 | `CHK-003` 的动态 boost（与上一行重叠）、`TXN-001` 的数据库回滚 |
| **复核不出问题**：逐条比对代码，未发现与实际不符 | 7 | `FIX-RC-001`、`FIX-PM-001`、`SEC-TOOL-001`、`FIX-UNINST-001`、`FW-002`、`SEC-INPUT-001`、`SEC-CRED-001`（主体） |

- **"范围漏了"那 6 条已分别由二轮的新条目补上**：
  `SEC-CACHE-001`（6 处缓存绕过 + 静默的校验总开关）、
  `SEC-ACME-002`（acme.sh 自更新）、
  `SEC-REPO-002` / `SEC-REPO-003`（宿主机已有软件源的预检）、
  `SEC-SIG-001`（nginx 验签的 gpg/gpgv 依赖、钥匙串收窄、确认验签结果）、
  `FIX-BIN-001`（数据库通用二进制落地路径失败即停）。
- **二轮新查出的一处代码残留**：`TempMycnf_Clean()` 里还留着
  `rm -f /tmp/.mysql.tmp`：旧固定临时文件名时代的清理动作。
  `SEC-CRED-001` 之后不再生成该文件名，保留旧名称会使静态检索
  误判"代码里还在用固定临时文件"。三份管理脚本已删除该行并加注。
  安全影响为零（`rm -f` 不跟随符号链接），属清理不彻底。
- **注意：复核未确认其中 7 条问题**：已在各条下写明**具体核对了哪些函数/取值**，
  并保持原结论。**该结论保留待进一步证据确认**：
  按现有代码无法定位对应问题，硬改成"已修复"只会制造新的不实记录。
- **本条不覆盖的**：`changelog.md` 里当时尚未收口的验证状态按需求约束**暂不处理**，
  等安全问题全部解决后上真机实测时一并复核（见 `SCOPE-001`）。
- **行为变化**：无（除删掉一行已失效的 `rm -f`，不改任何执行逻辑）
- **验证状态**：已验证（文档复核），见阶段 13 发布前审计与阶段 15 最终回归检查（2026-08-11 复核）。

### DOC-005 README 重写为 README.md：面向使用者的发布文档

- **文件**：`README` → **`README.md`**（重写）、`conf/index.html`（引用更名）
- **类别**：DOC 文档
- **起因**：需求约束：改名为 `.md`；简要介绍本分支改了什么，
  **不要突出对原 LNMP 出品方的不信任**；「常用功能说明」着重
  MySQL / Nginx / Redis / PHP 并把命令写全（含运维命令）；
  **必须**说明以后手工升级要怎么改；并按 `qa.txt` 增加答疑。
- **改动**：

  **1. 语气与定位调整。** 旧版是一路整改下来的产物，通篇在解释
  「原来那条命令有什么问题、原因删掉」，不适合作为正式发布文档。
  重写后改为直接讲**现在是什么、怎么用**：
  - 删掉「原 README 这里写的是 `wget https://soft.lnmp.com/...`，该命令有两个问题」
    整段：使用者不需要知道被删掉的旧命令长什么样；
  - 「组件的信任标准」一节由「哪些域名禁用、原因不可信」改为
    正面表述「从各组件开发方官网下载 + 强制校验」，禁用域名不再点名批评；
  - 保留了必要的风险告知（真机未端到端验证、CentOS 系验证投入少、
    数据库升级无自动回滚），这些是使用者做决策需要的，不是立场表达。

  **2. 「本分支改了什么」压缩为四组**：版本与组件、下载与完整性、
  安全基线、可靠性。每组三到六条，只说结果不说过程，细节指向 `changelog.md`。

  **3. 「常用功能说明」按服务重组**，每个服务给出**目录表 + 日常命令**：
  - **服务管理**：`lnmp start|stop|restart|reload|kill|status`
    与单服务控制，并说明 `reload` / `restart` / `kill` 的区别；
  - **Nginx**：配置文件分布、`nginx -t` / `-s reload` / `-V`、
    虚拟主机增删查、改默认站点域名、日志切割；
  - **MySQL/MariaDB**：目录与错误日志位置、登录/状态/备份命令、
    `lnmp database` 四个子命令、重置 root 密码；
  - **PHP**：配置文件分布、`-v` / `-m` / `-i` / `--ini` / `php-fpm -t`、
    装扩展、多版本 PHP 切换、进程数调优（给了每进程 30~50MB 的估算依据）；
  - **Redis**：安装、`redis-cli ping/info/monitor`、
    并写明**默认只监听本机且端口被防火墙挡掉是有意的**；
  - 另加 Memcached、SSL、FTP、`tools/` 脚本表、nftables 查看命令。

  **4. 新增「以后手工升级怎么改」整章**（明确的需求约束）：
  - 优先用 `./upgrade.sh`，并说明哪些是事务式可回滚、哪些不是；
  - 改默认版本号去 `include/version.sh`，**数据库与 PHP 在 `include/profile.sh`**
    （因为那里一个条目同时决定菜单、安装函数、二进制架构等一整组信息）；
  - **注意：改完版本号必须做的两件事**：更新 `src/checksums.sha256`
    （强调「落地文件名 ≠ URL 的 basename」这个最容易遗漏的要点），
    以及确认 URL 仍有效（Nginx 只保留每分支最新点版本）；
  - 校验值来源按可信度排序，并写明「自己下载后算哈希」只能保证一致性、
    不能证明未被篡改；
  - 新增下载组件的四条规矩；升级后的检查清单
    （特别提示 PHP 升级后扩展需重装）。

  **5. 新增「常见问题」章节**，覆盖 `qa.txt` 的全部条目。
  原文里的答案大多是「解决方法：<链接>」，**按要求不再出现任何外部链接**，
  改为按本分支代码的实际情况直接给出可执行的步骤。
  其中若干条答案与原文**已经不同**，因为本分支改过实现：

  | 问题 | 原答案 | 本分支的实际情况 |
  |---|---|---|
  | 数据库 root 默认密码 | `lnmp.org#随机数字`，安装后显示、可查安装日志 | 随机密码改为 `/dev/urandom` 生成，**不再打印到屏幕和日志**，写入 `/root/.lnmp_db_root_password`（0600） |
  | 80/443 不通 | 「一般是 iptables 引起的，删掉或停掉 iptables」 | 本包用 **nftables**，去停 iptables 没有意义；改为给出 `nft list table inet lnmp` 的排查顺序，并把「云服务器安全组」列为最常见原因 |
  | 数据库远程连接 | 指向论坛帖子 | 明确写出授权、`bind-address`、放行端口三步都要做，并建议只对固定 IP 放行而非开放公网 3306 |
  | 防跨目录 | 指向 FAQ 锚点 | 写明 `.user.ini` 带 `chattr +i`、需要先解锁、改完约 5 分钟或重启 FPM 生效 |
  | 重置 root 密码 | 指向教程 | 直接给脚本路径，并说明现在走禁用网络 + 私有 socket，重置期间数据库不对外可见 |
  | 清理数据库日志 | 指向论坛帖子 | 改为 `PURGE BINARY LOGS BEFORE ...`，并说明原因不能直接 `rm` 日志文件 |
  | 限流限速、404 页、伪静态、优化 | 均为链接 | 均改为可直接粘贴的配置片段与命令 |

  另补了原文没有但实际会遇到的：IPv6 站点要加 `listen [::]:80`、
  PHP 升级后扩展要重装、`display_errors` 必须在 `php-fpm.conf` 里设
  （改 `php.ini` 无效，会被 FPM 覆盖）。

  **6. 「安装」一章重写为「获取 → 安装」两步。**
  上一稿开头是「本分支不提供网络下载入口。使用自行取得并核对的 2.3 包……」：
  这句话是整改期的说法（当时刚删掉指向站长镜像的 wget 命令，又没有替代来源），
  **对使用者来说读不懂**：不提供下载入口，那包从哪来？
  本项目会发布到 GitHub，现改为直接给两种获取方式：
  - `git clone`（方便后续 `git pull`）
  - 下载 release 压缩包

  并补上三条实际有用的提示：
  - **优先用 tag / release 而不是 `main` 分支**：tag 是固定的，
    `main` 随时可能在两次安装之间变化，两台机器装出来的东西就不一样了；
  - 完整性核对改为可操作的动作：`git log -1` 核对提交哈希，或用 release 页公布的校验值；
  - 三种模式（lnmp / lnmpa / lamp）各是什么，以及
    **注意：必须在干净机器上安装**：脚本会卸载系统自带的 nginx/php/apache/mysql
    并接管防火墙，不应在已有业务的服务器上直接执行。

  仓库地址目前写作 `<你的用户名>/<仓库名>` 占位，发布前需替换为真实地址。
- **`conf/index.html`** 里指向 README 的文字同步改为 `README.md`。
- **行为变化**：无（纯文档）
- **验证状态**：已验证（文档与实跑结果对照），见阶段 14、15 Debian 12 + WordPress 主线验收（2026-08-11 复核）。

---

# 阶段 8 — Debian 12 真机验证（2026-08-09 起）

> 前七个阶段以静态检查和整改为主。本阶段的问题均由**实际执行**发现，
> 环境：Debian 12 bookworm / x86_64。
> 验证命令：`LNMP_Auto=y DBSelect=2 Bin=y PHPSelect=4 SelectMalloc=1 InstallInnodb=y ./install.sh lnmp`
> 即 nginx 1.30.4 + PHP 8.3.33 + MySQL 8.4.7（官方通用二进制）+ phpMyAdmin 5.2.3。

### FIX-MCRYPT-001 删除 libmcrypt / mcrypt：安装第一个阻断（P0）

**现象**：安装在 `Install_Libiconv` 成功之后立刻中止：

```
[+] Installing libmcrypt-2.5.8
Uncompress libmcrypt-2.5.8.tar.gz...
tar (child): libmcrypt-2.5.8.tar.gz: Cannot open: No such file or directory
FATAL: failed to uncompress libmcrypt-2.5.8.tar.gz
```

**根因**：调用点与下载清单跨文件不一致。

- `install.sh` 的 `Init_Install` **无条件**调用 `Install_Libmcrypt` 和 `Install_Mcrypt`；
- 但 `include/init.sh` 的 `Check_Download` 里**没有这两个组件的下载条目**；
- `src/checksums.sha256` 里同样没有它们的校验值。

于是 `Tar_Cd` 对着一个从未下载过的文件解压，必然失败。

**原因静态检查查不出来**：单看每个文件都自洽：`version.sh` 里变量有定义，
`init.sh` 里函数有实现，`install.sh` 里调用有目标。问题只存在于
「调用点 → 下载清单 → 校验清单」这条**跨三个文件的链路**上，
而这条链路此前没有任何自动检查覆盖。这也印证了阻断性提醒第 2 条：
静态检查不能替代完整安装验证。

**处理**：整个删除，而不是补下载条目。理由：

1. mcrypt 扩展自 **PHP 7.2 起移出核心**，本包现在只支持 PHP 8.x；
2. 三处 PHP `configure`（`php.sh:293/295`、`multiplephp.sh:67`、`upgrade_php.sh:285/287`）
   **都没有 `--with-mcrypt`**：就算装上也没有任何东西会用它；
3. libmcrypt 上游最后一次发布是 2007 年，早已无人维护。
   为一个用不到的扩展编译一个停更 18 年的加密库进 `/usr/local/lib` 再 `ldconfig`，
   是纯粹的攻击面扩大。

**改动**：

- `install.sh`：`Init_Install` 删去 `Install_Libmcrypt` / `Install_Mcrypt` 两行调用
- `include/init.sh`：删除 `Install_Libmcrypt()` / `Install_Mcrypt()` 两个函数（约 28 行），
  原位置留注释说明删除理由
- `include/version.sh`：删除 `LibMcrypt_Ver` / `Mcypt_Ver` 两个变量

**未一并处理（另记）**：`Install_Mhash` **保留**。它与前两者不同：
下载条目和 checksum 条目齐全，本次验证中也已成功编译安装，
且三处 PHP `configure` 都带 `--with-mhash`。
但 `--with-mhash` 在 PHP 8 上是否仍有实际效果**尚未验证**（hash 扩展已内置，
mhash 兼容层在 PHP 7.4 废弃）。若确认为 no-op，则 mhash 0.9.9.9（2007 年发布）
也应按同样理由删除。见 OPEN-006。

- **行为变化**：安装不再在 libiconv 之后中止；不再有 `/usr/local/lib/libmcrypt.*`
  及其到 `/usr/lib` 的软链
- **验证状态**：已实测（重跑安装验证）

### SEC-WEB-004 Redis 演示页补上开关：SEC-WEB-002 的遗漏

**问题**：`include/redis.sh:78` **无条件**把 `conf/redis.php` 部署到网站根目录：

```bash
echo "Copy Redis PHP Test file..."
\cp ${cur_dir}/conf/redis.php ${Default_Website_Dir}/redis.php
```

memcached 的同类演示页在 SEC-WEB-002 里已经加了 `Enable_Memcached_Test_Page`
开关并默认关闭，phpinfo / phpMyAdmin 也早有各自开关：**唯独 redis 漏了**。
装完 Redis 的机器上，`http://<站点>/redis.php` 对任何人开放。

**危害**（比 memcached 那个轻，但性质相同）：

1. 无鉴权，任何人可访问；
2. 回显 `$redis->info()['redis_version']`，把 Redis 精确版本号公开出去，
   便于攻击者直接匹配已知漏洞；
3. 每次访问都对生产 Redis 执行一次 `set('key1', ...)` + `del('key1')`：
   这是一个**未授权的写入口**。它没有 memcached 演示页那样的 `flush()`
   （SEC-WEB-002 处理的正是那个），所以不至于清空缓存，但仍不该对外开放；
4. 页面本身还等于公开宣告「本机装了 Redis 且 PHP 能连上它」。

**改动**：

- `lnmp.conf`：新增 `Enable_Redis_Test_Page="${Enable_Redis_Test_Page:-n}"`，
  默认 `n`，写法与其余开关一致（`${VAR:-default}`，可被调用者环境覆盖）
- `include/redis.sh`：部署动作套上开关；不部署时打印出手工自测的命令，
  与 memcached 的处理保持逐字一致的口径

**未改动**：`conf/redis.php` 文件本身保留，只是不再自动部署。
需要自测的用户按提示手工 `cp` 一次即可。

- **行为变化**：`./addons.sh install redis` 不再向网站根目录写 `redis.php`。
  已经装过 Redis 的机器需要手工删除遗留文件：
  `rm -f /home/wwwroot/default/redis.php`
- **验证状态**：已实测（本阶段 Redis 安装验证）

---

# 阶段 9 — 第二轮安全复核整改（2026-08-10）

> 第二轮安全复核共确认 9 条问题和 1 条部分成立的问题。以下为整改记录。

### SEC2-002 OpenResty 安装用固定 `/tmp` 文件名（P1，本阶段自己引入的）

**问题**：`include/openresty.sh` 用固定路径 `/tmp/openresty-pubkey.gpg` 落公钥。

root 执行安装时，本机**任何低权限用户**都可以预先创建

```
/tmp/openresty-pubkey.gpg -> /etc/shadow
```

这样的符号链接。`curl -o` / `wget -O` 会**跟随链接**去写目标文件：
任意文件截断/覆盖，而且是 root 权限。

**这个漏洞类型此前已经从管理脚本里清理过**（`include/main.sh:1030` 还留着当时的
说明注释），是 OR-001 的新代码把它重新引入的。全仓库排查确认只有这一处。

**改动**：`umask 077` + `mktemp -d` 建私有目录（名字不可预测、权限 0700），
下载与临时 keyring 都放进去，`trap ... RETURN INT TERM` 覆盖正常返回、
异常返回和信号打断三种退出路径。

- **验证状态**：已改，语法通过；全仓库同类模式已排查（另两处命中均为注释）

### SEC2-003 Redis 与 Memcached 以 root 运行（P1）

**问题**：两个缓存服务都以 root 身份运行。

| | 证据 | 性质 |
|---|---|---|
| Redis (systemd) | `init.d/redis.service` 无 `User=` / `Group=` | 继承 root |
| Redis (SysV) | `init.d/init.d.redis` 直接 `"$EXEC" "$CONF"` | 继承 root |
| Memcached | `init.d/init.d.memcached:22` **`USER=root`** 并显式传给 `-u` | **主动指定 root** |

Memcached 默认拒绝以 root 运行，除非显式
`-u root`：旧实现绕过了该保护机制。
而 `include/memcached.sh:102` 还建了个 `nobody` 账号，建完没用。

**危害**：两者默认都无认证，同机的 PHP / Web 进程可以直接连。
于是任何协议滥用、配置写入能力或内存安全漏洞，都会从"缓存服务权限"
**直接放大成 root**。Web 应用失陷不该自动取得系统最高权限。

**改动**：

- 新建专用系统账号 `redis` / `memcached`（`useradd -r -M -s /sbin/nologin`）。
  **不用 `nobody`**：那是被大量服务共用的账号，拿它做隔离等于没隔离。
- `redis.service` 加 `User=` / `Group=`，并补了几项基础加固
  （`NoNewPrivileges` / `ProtectSystem=full` / `ProtectHome` / `PrivateDevices`，
  `ReadWritePaths` 只开放数据目录）。
- SysV 路径新增 `Redis_Exec()`：redis-server 自身没有 `-u` 参数（不像 memcached），
  只能由启动方降权：优先 `setpriv`（不起 shell），退回 `su`。
  账号不存在时（老机器升级）明确告警但仍启动，不因降权不成而让服务起不来。
- **pidfile 从 `/var/run/redis.pid` 迁到 `/usr/local/redis/var/redis.pid`**：
  降权后 `/var/run` 是 root 的，redis 写不进去。
- 权限收口：数据目录 `redis:redis 750`；**配置文件保持 root 所有（`root:redis 640`）**
：redis 进程没必要能改自己的配置，能改配置就能改 `dir` / `dbfilename`，
  那正是历史上"写入 SSH 公钥"那类利用的前提。
- memcached 的 init 脚本在账号缺失时自动补建并说明原因。

**实测回归**：

```
Redis     运行身份 redis（原 root）   status running   ping PONG
          写入 ok   dump.rdb 属主 redis:redis
          restart 停→启正常，重启后仍是 redis 身份
Memcached 运行身份 memcached (uid 996)   STAT pid/version 正常
          防火墙 tcp+udp 11211 均 drop
```

- **验证状态**：已实测（启动 / 写入 / 持久化 / 重启 / 身份 全部验证）

### SEC2-004 防火墙失败不传播到退出码，数据库未绑定回环（P1）

**部分属实**：其中一条论据经实测不成立，见文末。

**问题 1：防火墙失败被吞掉。**
`Add_Iptables_Rules` 失败会返回 1 并置 `FW_Failed='y'`，但
`install.sh` 的三个安装栈（`:141/154/166`）**都无条件往下走**，
而 `Check_*_Install` 只检查组件文件在不在，**不看 `FW_Failed`**。

于是 nftables 缺失、规则写入失败、持久化失败时，安装仍以 **0 退出**并打印"完成"，
而 3306 就那么暴露着。自动化只看退出码，发现不了安全控制已经失效。

**问题 2：规则写入不检查结果。**
`Firewall_Block`（写 3306 / 6379 的 drop）和 `Firewall_Allow` 的
`nft add rule` 都不看返回值。链策略是 `policy accept`：
**drop 规则没写进去，端口就是敞开的**。

**问题 3：数据库没有 `bind-address`。**
`/etc/my.cnf` 里 `skip-networking` 是注释掉的，也没有 `bind-address`，
实测 MySQL 监听 `*:3306`（所有接口）。防火墙成了**唯一**的阻拦。

**改动**：

- 新增 `Check_Firewall_Result()`（`include/end.sh`），并入三个
  `Check_*_Install` 的成功判定：**防火墙没配上就不算安装成功**，退出码为 1，
  同时打印可直接执行的自查命令。
  组件本身仍然装完（不中断安装），但结果如实反映。
- `Firewall_Block` / `Firewall_Allow` 检查 `nft add rule` 的返回值，
  失败时置 `FW_Failed` 并返回 1。
- **MySQL 与 MariaDB 的三处 my.cnf 模板都加上 `bind-address = 127.0.0.1`**，
  让防火墙回到"第二道防线"的位置，而不是唯一防线。

**注意：复核中有一条论据不成立**：原文称

> `nft add table inet lnmp`：「表已存在时该命令本来就返回非零，
> 因此当前实现与其『幂等』注释相反」

**实测三次全部返回 0**（已存在的表、新建表、重复 add 同一张表）。
`nft add` 本来就是幂等的，这正是它与 `nft create` 的区别：
后者才会因 `File exists` 失败。**该处代码与注释一致，未做改动。**

**实测**：

```
FW_Failed=n → Check_Firewall_Result 退出码 0
FW_Failed=y → 退出码 1，并打印处置指引
```

- **验证状态**：已验证；退出码传播见本条实测，`bind-address` 与 33060 收口见阶段 14、15 完整安装复验（2026-08-11 复核）。

### DOCSEC-003 文档里的访问控制示例会被 nginx location 规则绕过（P1）

**这是本批里最危险的一条**，因为它**给出虚假的安全感**。

`HowtoGuides.md` 原先建议：

```nginx
location /phpmyadmin/ {      # 普通前缀 location
    allow 你的办公IP;
    deny all;
}
```

**实测对比**（真机构造，非推理）：

```
/phpmyadmin/x.txt      → 403   ← 管理员看到这个，以为防护生效了
/phpmyadmin/index.php  → 200   ← PHP 入口完全敞开，且确实执行了
```

原因：`.php` 请求会匹配到 `conf/enable-php.conf` 里的**正则** location，
而 nginx 中**正则优先于普通前缀**。静态文件被拦住恰恰是最误导人的部分：
它让人以为规则生效了。

uploads 禁止执行那条同理：nginx 按**出现顺序**匹配正则 location，
用第一个匹配上的。示例若按习惯追加到 server 块**末尾**，
该规则无法匹配：上传的 webshell 仍会交给 PHP-FPM。

**改动**：给出经实测验证的正确写法，并解释原因。

- phpMyAdmin 改用 `location ^~ /phpmyadmin/`（`^~` 使前缀胜出且**不再匹配正则**），
  内层嵌套一个 PHP location 处理 `.php`（不嵌套的话 phpMyAdmin 跑不起来）
- uploads 规则明确要求放在 `include enable-php.conf;` **之前**，并说明原因
- 两处都补了**可执行的验证命令**，并强调 `nginx -t` 通过说明不了任何问题

**实测确认修正后的配置**：

```
/phpmyadmin/index.php        → 403
/phpmyadmin/x.txt            → 403
/wp-content/uploads/evil.php → 403
/ok.php                      → NORMAL-OK   ← 正常 PHP 不受影响
```

- **验证状态**：已实测（错误写法与正确写法都做了对照实验）

### DOCSEC-001/002/004/005/006/007 HowtoGuides.md 其余安全问题

六条一并整改，全部属实。

**DOCSEC-001 站点文件属主。** 原先 `chown -R www:www` 整个站点，
`wp-config.php` 也是 `www:www 640`：权限位挡住了"其他用户"，
但**文件所有者正是运行 PHP 的账号**。任一插件/主题/站点代码失陷，
就能改写 `wp-config.php`、核心文件、插件主题来持久化。

改为：代码归 `root:www 640/750`（PHP 只读），
只有 `uploads` / `cache` / `upgrade` 三个目录给 `www` 写。
**并明确写出代价**：这样配置后台的插件在线安装与自动升级会失效，
给出"走命令行升级"（推荐）与"放开 plugins/themes 写权限"两种取舍，
但强调 `wp-config.php` 和核心目录无论如何不能给。

同时撤回了把 `open_basedir` 说成完整站点隔离边界的措辞：
它挡的是路径穿越，多站点共用 `www` 账号时没有内核层面的租户隔离。

**DOCSEC-002 凭据进命令行与 HTTP。** 原先把管理员密码 POST 到 `http://`，
密码直接写在 curl 参数里，还带 `pw_weak=1`；多处示例用 `-p'密码'`。
命令行参数对同机所有用户可见（`ps` / `/proc/<pid>/cmdline`），
还会进 shell history、终端录屏和自动化日志。

改为：**默认引导走 HTTPS 页面 + 交互式输入**；命令行方式移进折叠块并前置风险说明
（必须 HTTPS、必须受控环境、密码从环境变量读、装完立即改密码）。
`mysql -p'密码'` 全部改为 `-p` 交互提示；无人值守备份改用
权限 0600 的 option file（`--defaults-file`）。

**DOCSEC-004 下载校验不是 fail-stop。** 原先校验失败只 `echo "不要继续"`，
返回码仍是 0，后续命令照常执行；还用了浮动的 `latest.tar.gz`。

改为：固定版本号；校验不通过 `rm` 掉文件并 `exit 1`；
明确说明 **SHA-1 只能挡传输损坏和缓存污染，不构成强完整性保证**（已不抗碰撞）。
插件同样固定版本，并说明 **wordpress.org 插件目录不提供逐文件哈希或签名**：
不能因为域名是官方的就跳过验证这件事，至少记录自己部署那份的 sha256 供日后比对。

**DOCSEC-005 撤回"Redis 回环即安全"的结论。** 原文说"只要只监听回环就够安全"。
结合 SEC2-003（当时以 root 运行）这个结论站不住，而且即使降权后也只对了一半：
回环解决的是公网暴露，**不解决本机进程之间的信任隔离**。
同机所有 PHP 进程都能连上无认证的 Redis，`WP_REDIS_PREFIX` 只是命名约定、
**不是授权边界**（攻击者可以直接 `KEYS *`）。

改为：把回环称为**必要条件而非充分条件**，并按部署模型给出真正的隔离手段
（单租户可接受 / 多站点用独立实例或 ACL / 合规场景用 Unix socket + 文件权限）。

**DOCSEC-006 安全基线措辞过强。** 两处不实：

| 原文 | 实际 |
|---|---|
| "只放行 22/80/443 + ICMP" | 链策略是 **`policy accept`**，只是额外 drop 几个敏感端口：是"阻断这几个"，不是"只允许这几个" |
| "全部强制 SHA256 校验" | 分四种机制：静态 SHA256 清单、上游 SHA256、PGP 签名（nginx/OpenResty 源码）、包仓库 GPG 签名（OpenResty apt/yum），而且 `Enable_Download_Checksum` **可以关掉** |

改为按机制分别列出，并加了一段说明：**这张表描述的是"安装脚本尝试做到的状态"，
不等于"当前系统的实际状态"**：防火墙可能失败（见 SEC2-004），
给出上线前实测三条命令（`nft list` / `ss -lntp` / `ps -o user`）。

**DOCSEC-007 debug.log 可能被公开访问。** 原先只开 `WP_DEBUG` + `WP_DEBUG_LOG`，
**没关 `WP_DEBUG_DISPLAY`**（报错会直接打印给访客），
日志又默认写到 Web 根目录下的 `wp-content/debug.log`。

改为：三个常量一起设（`WP_DEBUG_DISPLAY=false` + `ini_set('display_errors',0)`），
日志路径指向 `/var/log/wordpress/`（站点根目录之外）；
补充清理历史遗留 `debug.log` 的命令，以及一条兜底的 nginx 规则
（拒绝 `.log|.sql|.bak|.old|.swp|.env`，同样要放在 PHP 正则之前）。

- **验证状态**：文档改动，未涉及代码。其中 DOCSEC-003 的配置片段已实测
  （见该条目），本条的其余部分为文档表述修正

### OR-001 新增 OpenResty 安装选项（新增功能，用户需求）

**需求**：初次安装时可选 OpenResty，**与 nginx 官方版互斥**，
**nginx 现有逻辑不得改变**，OpenResty 可选「编译」或「apt 下载」两种装法，
且要能升级。不支持的情况直接报错说明即可，不用自动降级。

#### 上游事实（均为实测，非文档推断）

| 事实 | 值 |
|---|---|
| 稳定版 | `openresty-1.31.1.1`（2026-05-13 发布，内置 nginx 1.31.1） |
| 预编译包 | 只提供 **apt/yum 软件仓库**，不提供通用静态 tarball |
| Debian 仓库现有代号 | jessie / stretch / buster / bullseye / **bookworm** |
| **Debian 13 (trixie)** | **仓库中不存在**（`dists/trixie/Release` 返回 **404**） |
| 源码 tarball | 提供，`https://openresty.org/download/openresty-<ver>.tar.gz` |
| 源码校验方式 | **只有 PGP 签名（.asc），没有 sha256** |
| 仓库签名密钥 | `E52218E7087897DC6DEA6D6D97DB7443D5EDEB74`（OpenResty Admin） |
| 源码签名密钥 | `25451EB088460026195BD62CB550E09EA0E98066`（Yichun Zhang） |

**注意：官方博客把 Debian 13 列进了支持列表，但仓库里确实没有 trixie 的包**
（2026-08-10 实测，仓库最近更新时间 2026-06-10，说明在维护中，只是还没发）。
**文档超前于实际发布状态**：这也是本项目一贯以实测为准、不以文档为准的又一例。

**注意：仓库包与源码包用的不是同一个密钥。** 仓库那条路的完整性由 apt/yum 自己的
GPG 校验保证，不走本包的验签；源码那条路才用 Yichun Zhang 的密钥。

#### 实现

**新增文件**：

- `include/openresty.sh`：安装（两种方式）、互斥检查、卸载
- `include/upgrade_openresty.sh`：升级（按安装方式自动分流）
- `conf/openresty-signing-key.asc`：Yichun Zhang 的公钥，随包附带

**两条安装路径**（`OpenResty_Install_Mode`）：

| 模式 | 做法 | 校验 | 限制 |
|---|---|---|---|
| `pkg`（默认） | 配官方 apt/yum 仓库装 `openresty` 包，**不编译** | apt/yum 的 GPG 签名 | 仓库必须有当前发行版代号 |
| `source` | 下载官方源码 tarball 自行编译 | **PGP 验签**（`Verify_OpenResty_Signature`） | 慢，但不挑发行版 |

**关键设计：`/usr/local/nginx` 软链。** 安装完成后建立

```
/usr/local/nginx -> /usr/local/openresty/nginx
```

于是 `conf/lnmp` 的全部 vhost 管理逻辑、`init.d/nginx`、`tools/` 下的脚本
**全部零改动复用**：它们引用的都是 `/usr/local/nginx/...`。
这是让 OpenResty 融入现有体系代价最小的做法。

**互斥是双向的**，且检查两次：

1. 菜单阶段（`Web_Selection`）： 早拦，别等编译完一堆东西才发现装不了
2. 落地前（`Install_OpenResty`）： 防止绕过菜单直接调用

判据是 `/usr/local/nginx` **是不是真实目录**：装了 OpenResty 时它是软链，
装了源码 nginx 时它是真实目录，两者可区分。

**apt 方式先探仓库再动手**：新增 `Download_Head_OK`（verify.sh），
安装前先 HEAD 探测 `dists/<代号>/Release` 是否存在。
不探的话要等到 `apt-get update` 才报 404，而那时坏源已经写进
`/etc/apt/sources.list.d/`，会连累后续所有 apt 操作。
探测失败时明确告知「这不是本包的限制，是上游尚未发布该发行版的包」，
并给出两条出路（改用源码编译 / 改用 nginx）。

**用 `signed-by` 而不是 `apt-key`**：公钥装进 `/usr/share/keyrings/openresty.gpg`
并在源行里用 `signed-by=` 绑定到这一个源。`apt-key` 已废弃，且它把密钥加进
全局信任集：等于让 openresty 的密钥能给**任何**仓库的包背书。

**停用随包的 systemd 服务**：包安装会带一个 `openresty.service`，
与本包的 `/etc/init.d/nginx` 抢同一个二进制和 pid 文件。
安装后 `systemctl disable openresty`，统一由 `lnmp` 管理，避免两个管理者打架。

**升级**（`./upgrade.sh openresty` 或菜单 9）：**按当初的安装方式自动分流**，
不问用户：包管理器里有 `openresty` 就走 `apt-get install --only-upgrade`
（带 `--force-confold` 保留本地配置，否则站点 vhost 会被包里的默认配置覆盖），
否则走源码重编。源码升级前先备份 `conf/` 目录，且 configure/make 任一失败
都中止且不替换现有安装。升级后先 `nginx -t` 再 restart：配置不过就不重载，
让站点继续跑在旧进程上。

**卸载**：`uninstall.sh` 在 `rm -rf /usr/local/nginx` **之前**调用
`Uninstall_OpenResty`。顺序很重要：那个路径是软链，先删软链再删目录，
否则 `rm -rf` 会顺着软链把 OpenResty 的内容删掉，而包管理器还认为它装着，
留下一个不完整的状态。

**nginx 那条路一个字节都没改**：`Install_Nginx` 及其全部调用参数原样保留，
只是在 `LNMP_Stack` / `LNMPA_Stack` 里把 `Install_Nginx` 换成了
`Install_WebServer`（一个只做分流的两行函数），`WebServer` 默认值就是 `nginx`。
不选 OpenResty 时，执行路径与改动前完全一致。

#### 非交互用法

```bash
WebSelect=1                  # 装 nginx（默认，行为与改动前一致）
WebSelect=2 ORMode=1         # 装 OpenResty，官方仓库预编译包（不编译）
WebSelect=2 ORMode=2         # 装 OpenResty，源码编译
```

- **行为变化**：新增一个菜单项；不选 OpenResty 时无任何变化

#### 实测记录（Debian 12，2026-08-10）

**互斥（双向）**

```
已装 nginx 时选 OpenResty：
  检测到已安装 nginx（/usr/local/nginx 是真实目录）。
  OpenResty 与 nginx 官方版互斥，不能同时安装：
  如需改用 OpenResty，请先卸载现有环境：./uninstall.sh lnmp     ← 正确拦截
未装 OpenResty 时选 nginx：放行                                  ← 正确
```

**仓库探测**

```
bookworm  可用 ✓
trixie    不可用 ✓（触发报错说明，而不是等 apt-get update 才失败）
```

**完整安装**（`WebSelect=2 ORMode=1`，耗时 **7 分钟**，比 nginx 源码编译快 2 分钟）

```
[+] Installing OpenResty (pkg) ...
检查 OpenResty 官方仓库是否提供 Debian bookworm 的包...
仓库中存在 bookworm 的包，继续。
Get:4 https://openresty.org/package/debian bookworm InRelease        ← GPG 验证通过
装入：openresty 1.31.1.1-1~bookworm1
      + openresty-openssl3 3.5.7 / openresty-pcre2 10.47 / openresty-zlib 1.3.2
Install lnmp V2.3 completed!
```

**安装结果核验**

| 项 | 结果 |
|---|---|
| 版本（经软链访问） | `nginx version: openresty/1.31.1.1` |
| 包管理器视角 | `ii openresty 1.31.1.1-1~bookworm1` |
| 软链 | `/usr/local/nginx -> /usr/local/openresty/nginx` |
| 本包 nginx.conf | 已生效（`user www www`、`include vhost/*.conf`） |
| Lua 路径 | 指向 `/usr/local/openresty/lualib/`（OpenResty 自带那套） |
| vhost / rewrite 目录 | 齐备 |
| 随包 systemd 服务 | `openresty.service: disabled` ← 已按预期停用 |
| 服务管理 | `/etc/init.d/nginx status` → running |
| `nginx -t` | successful |

**关键验证：OpenResty 自带 LuaJIT 在真实 worker 里可用**

```
curl http://127.0.0.1/lua  →  hello world
```

这是全新的代码路径：用的是 OpenResty 自己的 `lualib`，与源码 nginx 那套
（`/usr/local/nginx/lib/lua` + 单独编译的 LuaJIT）完全不同。

**现有运维命令零改动可用**（软链方案的核心价值）

```
lnmp vhost add   → 建站成功，rewrite 引用 /usr/local/nginx/conf/rewrite/wordpress.conf
                   nginx -t successful，数据库同步创建
lnmp vhost list  → 正常
lnmp nginx reload→ 正常
静态文件         → static-ok
PHP              → OpenResty+PHP OK 8.3.33
```

**升级**

```
安装方式自动判定：pkg
当前 OpenResty 版本：1.31.1.1（安装方式：pkg）
openresty is already the newest version (1.31.1.1-1~bookworm1).
nginx: configuration file ... test is successful
OpenResty 升级完成：1.31.1.1 -> 1.31.1.1
```

- **验证状态**：**pkg 路径已完整实测**（安装 → 建站 → 运维命令 → 升级）。
  **source 路径（源码编译）仅验证了验签环节**
  （已确认 Yichun Zhang 的公钥能验通 `openresty-1.31.1.1.tar.gz` 的 `.asc`，
  GOODSIG + VALIDSIG）；**source 路径待收尾验证**（尚未执行完整的源码编译安装；
  2026-08-11 复核）：
  它也是 Debian 13 上唯一可用的路径，应与 trixie 实测一并进行。

### SSL-IP-001 `default` 站点转为 IP 证书流程（新增功能，用户需求）

**需求**：`lnmp vhost add` / `lnmp ssl add` 输入 `default` 时，
应当转为申请 **IP 证书**，并让使用者看到清楚的说明文字。

**改动前的行为**：输入 `default` 会被 `Check_Domain_Name` 的正则直接拒绝
（正则要求至少含一个点），提示"域名不合法"后循环重问：用户无从知道
default 该怎么用，也没有任何关于 IP 证书的提示。

**上游事实**（均经查证，不是推断）：

- Let's Encrypt 自 2025 年起支持为 IP 地址签发证书，但**只有 shortlived
  profile 支持 IP 标识符**（classic / tlsserver 都只支持 DNS）
- shortlived 证书有效期 **7 天**
- **只支持 IPv4**，IPv6 申请不了
- acme.sh 的参数是 `--certificate-profile`（别名 `--cert-profile`），
  经核对上游主脚本确认存在（`acme.sh` 第 8004 / 8790 行）
- BuyPass 与 ZeroSSL 都不提供 IP 证书

**实现**（`conf/lnmp`）：

1. `Check_Domain_Name` 放行 `default` 这个保留名
2. `Add_VHost` 里输入 default 时说明它的含义（默认站点 / 按 IP 访问 / 无域名），
   并预告证书会走 IP 流程；提示想建域名站点就 Ctrl+C 重来
3. 新增 `Detect_Server_IP`：先问内核默认路由的源地址，
   若拿到的是私有地址再问外部服务取公网出口地址
4. 新增 `Is_Private_IP`：覆盖 10/172.16-31/192.168/127/169.254
   以及运营商级 NAT 的 100.64-127 段
5. 新增 `Prepare_Default_Site_IP_Cert`：打印说明并把申请目标从域名换成 IP
6. 新增 `Print_Self_Signed_Hint`：私有 IP 场景给出可直接粘贴的自签名证书命令

**申请参数**（经用户在真实公网 VPS 上实测可用）：

```bash
acme.sh --issue -d <IPv4> -w /home/wwwroot/default \
        --server letsencrypt --certificate-profile shortlived --days 6
```

`--days 6` 不能省：acme.sh 的 cron 按「距上次签发超过 --days 天就续」判断，
默认值 60 是给 90 天证书用的。shortlived 只有 7 天，不收紧阈值 cron 会一直
不续，证书到期站点直接不可访问。取 6 是比有效期提前 1 天，留出重试余量。

本包安装的 acme.sh cron 为每 6 小时一次，足够覆盖：

```
30 2,8,14,20 * * * "/usr/local/acme.sh"/acme.sh --cron --home "/usr/local/acme.sh"
```

**分场景的说明文字**：

| 场景 | 行为 |
|---|---|
| 私有 IP | 明确告知任何公信 CA 都不会签发，给出三条出路 + 自签名证书命令，中止 |
| 公网 IPv4 | 列出全部限制（7 天有效期 / 仅 IPv4 / 依赖 cron / 80 端口需公网可达 / 邮箱不能用保留域名），并提示 NAT 场景下探测到的可能是出口 IP 而非本机 |
| 选了 BuyPass/ZeroSSL | 自动改用 Let's Encrypt 并说明原因 |

**验证状态**：**流程已实测**，说明文字、IP 探测、profile 参数、自动改用
Let's Encrypt 均按预期工作，acme.sh 被正确调用。
**证书真实签发待人工真机验证**（2026-08-11 复核）：需要公网可达地址、真实邮箱与签发条件；验证机在 NAT 后面，且测试用的邮箱域名被 Let's Encrypt
拒绝（`invalidContact: forbidden domain`，这条已补进说明文字）。
真实签发需要公网可达的 80 端口 + 可收信的邮箱域名。

### FIX-EOF-001 交互脚本在 stdin 耗尽时无限刷屏

**现象**：用管道给 `lnmp ssl add` / `lnmp vhost add` 喂输入时，只要少喂一项，
就会看到同一行提示无限刷下去，吃满一个 CPU 核，只能 Ctrl+C 或 timeout 打断：

```
Enter 1, 2, 3 or 4: Please Enter 1, 2, 3 or 4!
Enter 1, 2, 3 or 4: Please Enter 1, 2, 3 or 4!
...（无限）
```

**根因**：脚本里大量 `while :; do ... read x ...; done` 的校验循环：
输入不合法就重问。但 `read` 在 **EOF** 时会立刻返回非零并把变量置空，
空值同样不合法，因此循环不会结束。**所有调用点均未检查 read 的返回值。**

交互使用碰不到（终端不产生 EOF），但凡是管道/重定向喂输入的场景
（自动化部署、CI、文档里的示例）少喂一项就必然触发。
本阶段验证中它三次打断了测试流程。

**改动**：新增 `Read_Input` / `Read_Secret` 两个包装函数，检测 EOF 后
明确报错退出，并提示"请核对输入项的数量与顺序"。替换了 10 处高危读取点：
域名（4 处）、邮箱、证书来源、DNS 证书来源、数据库名、数据库 root 密码、
FTP 账号名。

**同时修掉的邮箱校验误伤**：`Check_Acme_EMail` 的正则把顶级域限制为
`{2,4}`，`.online` / `.email` / `.technology` 这类合法邮箱会被判为非法，
而用户只看到 "invalid! Please re-enter"，不知道错在哪。放宽为 `{2,63}`。

- **行为变化**：非交互调用时快速失败并给出可操作的提示，不再空转刷屏
- **验证状态**：已实测（故意少喂一项，确认明确报错退出而非死循环）

### FIX-DBADD-001 建库用了 MySQL 8 已移除的语法：第五个阻断（P0）

**现象**：`lnmp vhost add`（勾选建库）与 `lnmp database add` 建库必然失败：

```
ERROR 1064 (42000) at line 3: You have an error in your SQL syntax; ...
    near 'IDENTIFIED BY 'xxx'' at line 1
Add database failed!
```

**根因**：版本判断只认 8.0.x。

```bash
if echo "${MySQL_Ver}" | grep -Eqi '^8\.0\.';then   # 新语法分支
```

本包的**默认数据库是 MySQL 8.4**（`profile.sh` 的 `DB_Default='2'`），
`8.4.7` 不匹配 `^8\.0\.`，于是落进 else 分支，用了 MySQL 5.7 时代的写法：

```sql
GRANT USAGE ON *.* TO 'user'@'localhost' IDENTIFIED BY 'pass';
```

而 `GRANT ... IDENTIFIED BY` **在 MySQL 8.0 就已被移除**。
结果：默认配置下建库功能完全不可用：而这正是 `lnmp vhost add` 里
「Create database and MySQL user with same name」那一步做的事。

**这个 bug 此前被修过一半。** `Edit_Database`（改库用户密码）旁边的注释
其中明确记录：「旧实现的三条分支……正则 `'^5.7.'` / `'^8.0.'` 的点没转义、
也没覆盖 8.4 与 MariaDB，于是本包的默认版本落进最后那条早已失效的 else」。
同一份分析、同一个结论，当时只改了改密码那条路径，**建库这条漏了**，
而且三个管理脚本（`conf/lnmp` / `conf/lamp` / `conf/lnmpa`）里各有一份。

**改动**：三个文件同步，删掉整个版本分支，统一用一套语法。
本包支持的 MySQL 8.0/8.4 与 MariaDB 10.11/11.4/11.8 都适用
`CREATE USER` + 不带 `IDENTIFIED BY` 的 `GRANT`。

**同时修掉的第二个问题：SQL 脚本没有幂等性。**

mysql 客户端逐条执行，中途报错时**前面几条已经生效了**。上一次因 1064
中断时，两条 `CREATE USER` 其实已经成功：于是重试变成：

```
ERROR 1396 (HY000): Operation CREATE USER failed for 'wpdemo'@'localhost'
```

用户被半建出来，然后再也建不成，只能手工进数据库 `DROP USER` 清理。
现改为 `CREATE USER IF NOT EXISTS` + 紧跟 `ALTER USER`：
既可重试，又保证密码一定是本次输入的那个
（`IF NOT EXISTS` 命中时不会更新密码，光靠它是不够的）。

**实测结果**：

```
Add database Sucessfully.

$ mysql -u wpdemo -p'***' -h 127.0.0.1 -e 'SELECT CURRENT_USER(); SHOW DATABASES;'
wpdemo@127.0.0.1
information_schema / performance_schema / wpdemo      ← 权限隔离正确
```

- **行为变化**：MySQL 8.4（默认）与 MariaDB 上建库都能成功；
  中断后重试不再残留半建的用户
- **验证状态**：已实测（先复现 1064 与 1396，修复后从零建站验证账号可登录）

### FIX-VHOST-001 `vhost del` 的 .user.ini 清理从未生效

**现象**：删除站点后，站点目录**删不掉**：

```
rm: cannot remove '/home/wwwroot/wp.demo.test/.user.ini': Operation not permitted
```

重建同名站点时也会失败：

```
/usr/bin/lnmp: line 643: /home/wwwroot/wp.demo.test/.user.ini: Operation not permitted
chmod: changing permissions of '.../.user.ini': Operation not permitted
```

**根因**：`Add_VHost` 会给 `.user.ini` 加 immutable 属性（`chattr +i`，
防止站点被入侵后篡改 `open_basedir`，这个设计本身是对的）。
`Del_VHost` 里也确实有对应的清理代码：

```bash
if [ -f "${vhostdir}/.user.ini" ]; then
    chattr -i "${vhostdir}/.user.ini"
    rm -f "${vhostdir}/.user.ini"
fi
```

**但 `Del_VHost` 全程只 `read` 了 `domain`，从没给 `vhostdir` 赋过值。**
路径恒为 `/.user.ini`，`[ -f ]` 判断永远为假：**这段清理从来没有执行过**。

于是每删一个站点，就在原目录留下一个带 immutable 属性的 `.user.ini`：
用户既删不掉它、也删不掉它所在的目录，重建同名站点时写入同样失败
（写不进去意味着 `open_basedir` 还是上一次的值：站点目录换了，
限制却指向旧路径）。

**改动**（`conf/lnmp`）：

1. `Del_VHost`：从 vhost 配置文件里解析真实站点目录
   （`awk` 取 `root` 指令的值），且**在删除配置文件之前**解析：
   配置一删就再也查不到目录了。清理成功时打印一行确认。
2. `Add_VHost`：写 `.user.ini` **之前**先 `chattr -i`，
   覆盖「重建同名站点」这个场景。

**实测结果**：

```
已移除 /home/wwwroot/wp.demo.test/.user.ini（先解除 immutable 属性）
Domain: wp.demo.test has been deleted.
$ rm -rf /home/wwwroot/wp.demo.test        ← 现在能删掉了
```

重建后 `.user.ini` 内容正确（`open_basedir=/home/wwwroot/wp.demo.test:/tmp/:/proc/`）
且 immutable 属性已重新加上（`lsattr` 显示 `----i---------e-------`）。

- **行为变化**：删除站点后不再残留无法删除的文件；重建同名站点可正常进行
- **验证状态**：已实测

### FIX-REDIS-003 Redis 8.x 装完起不来，且 init 脚本错误报告成功：第四个阻断（P0）

**现象**：`./addons.sh install redis` 全程无报错，末尾打印
`====== Redis install completed ======`、`Redis installed successfully, enjoy it!`，
`/etc/init.d/redis status` 也说 `Redis server is running.`

但实际上：

```
$ ss -lntp | grep 6379          → 无输出
$ redis-cli ping                → Could not connect: Connection refused
$ pgrep -a redis-server         → 没有 redis-server 进程
```

**服务从头到尾就没起来过，而每一层都报告成功。** 三个独立缺陷叠在一起。

#### 缺陷 1：Redis 8.x 的默认配置引用了未安装的模块（根因）

前台启动才看得到真实原因：

```
# Module ./modules/redisbloom/redisbloom.so failed to load: No such file or directory
# Can't load module from ./modules/redisbloom/redisbloom.so: server aborting
```

Redis **8.0 起把 RedisBloom / RediSearch / RedisJSON / RedisTimeSeries
并入官方发行版**，配置模板里预置了四行 `loadmodule`（本版本在 redis.conf
第 2718-2721 行）。但 `make PREFIX=/usr/local/redis install`
**只安装二进制，不构建也不安装模块**（模块各有构建链，RediSearch 还要 Rust）。
于是 redis-server 找不到 .so 就 `server aborting`。

Redis 7.x 的配置模板不含这些指令；该兼容性问题从 Redis 8.x 开始出现，
本包当前的 `Redis_Stable_Ver` 为 `redis-8.8.0`。

**改动**：复制 redis.conf 后把 `^loadmodule ` 整体注释掉，并打印一行说明。
LNMP 场景要的是核心键值/缓存能力，这四个模块用不到；需要的用户自行构建后放开。

#### 缺陷 2：`init.d/redis` 里 `[ "$?"="0" ]` 恒为真

```bash
$EXEC $CONF
if [ "$?"="0" ]; then    # 等号两侧没有空格
    echo " done"
```

`[ "$?"="0" ]` **不是比较**，而是对字符串 `"0=0"` 做单参数测试：
非空即真。所以 start / stop / kill **永远打印 done**，
redis-server 启动失败也一样报成功。这就是"安装看起来一切正常"的直接原因。

#### 缺陷 3：只凭 pidfile 判断服务状态

```bash
status)
    if [ -f "$PIDFILE" ]; then echo "Redis server is running."
```

Redis 启动到一半 abort 会留下 `/var/run/redis.pid`。于是：

- `status` 报 running（实测就是这样：pidfile 在，进程早没了）
- `start` 撞上 `if [ -f "$PIDFILE" ]` 分支，打印
  "process is already running or crashed" 后**直接不启动**：
  服务从此再也起不来，且每次都错误报告为运行中

**改动**：`init.d/init.d.redis` 重写。统一用 `Redis_Running()` 判断
（pidfile 里的 PID 必须 `kill -0` 得通），并且：

- `start`：主动清理陈旧 pidfile；daemonize 后轮询等待 pidfile 就绪；
  失败时打印**真实退出码**和常见原因（loadmodule / 端口占用 / dir 不可写），
  并给出前台复现命令
- `stop`：发完 shutdown 后确认进程真的退出，超时则报失败
- `status`：区分「运行中」「停止（有陈旧 pidfile）」「停止」三态，
  退出码分别为 0 / 1 / 3（符合 LSB 约定）
- 所有 `[ "$?"="0" ]` 一并修正

#### 附带修复：数据目录与日志

- **`dir ./`**：相对路径。daemonize 之后工作目录是启动时的 cwd，
  从 init 脚本或 systemd 启动就是 `/`：dump.rdb 会直接落在根目录。
  改为 `/usr/local/redis/var`（权限 750）。
- **`logfile ""`**：表示输出到 stdout，而 daemonize 之后 stdout 没人接，
  **启动失败的原因彻底丢失**。本次排查正是因此只能靠前台启动复现。
  改为 `/usr/local/redis/var/redis.log`。

**实测结果**（修复后重装）：

```
/etc/init.d/redis status   → Redis server is running (pid 833640).  退出码 0
ss -lntp | grep 6379       → 127.0.0.1:6379 与 [::1]:6379
redis-cli ping             → PONG        redis_version:8.10.0
config get dir             → /usr/local/redis/var
PHP igbinary 序列化存取数组 → {"a":1,"b":[2,3]}
```

- **行为变化**：Redis 装完确实能用；init 脚本不再错误报告成功；
  RDB 与日志落在固定目录
- **验证状态**：已实测（先复现全部三个缺陷，修复后卸载重装逐项验证）

### FIX-REDIS-004 Redis 服务起不来时仍报告"安装成功"

**发现经过**：最终验收时 `addons.sh install redis` 打印了
`Redis installed successfully, enjoy it!`，但紧接着
`/etc/init.d/redis status` 报 `Redis server is stopped.`

（本次触发原因是环境残留：此前启动的 Redis 进程仍占用 6379，
新进程 `bind: Address already in use` 起不来。属于清理不当，不是代码 bug：
**但它暴露了成功判定的缺陷**。同时也验证了 FIX-REDIS-003 的价值：
新的 init 脚本正确报告 stopped，旧版会错误报告 running，
两层一起错误报告的话这个问题不会被发现。）

**根因**：成功判定只检查两个**文件是否存在**：

```bash
if [ -s "${zend_ext}" ] && [ -s /usr/local/redis/bin/redis-server ]; then
    Echo_Green "Redis installed successfully, enjoy it!"
```

编译产物在 ≠ 服务跑起来了。端口被占、数据目录不可写、配置有问题
等一切导致启动失败的情况，都会被判成成功：
用户要等到应用连不上缓存才发现，而那时离安装已经隔了很久。

**改动**（`include/redis.sh`）：判定拆成两层。

1. 文件缺失 → 报 `install failed`，清掉 ini，返回 1（同原逻辑）
2. 文件都在 → **再查 `/etc/init.d/redis status`**，
   服务确实在跑才报成功；否则明确告知"装好了但没启动"，
   列出三个常见原因（端口占用 / 数据目录 / loadmodule）并给出排查命令

区分这两种情况很重要：**装失败**要重装，**装好了没起来**只需排查启动问题，
两者的处置动作完全不同，不该用同一句话打发。

- **行为变化**：服务未启动时不再错误报告成功，退出码为 1
- **验证状态**：已实测（先复现"报成功但 stopped"，改后端口冲突场景给出正确提示；
  清掉冲突进程后重装报成功且 `redis-cli ping` 通）

### FIX-REDIS-002 addons.sh 装 Redis 会降级已有的 phpredis

**现象**：主安装（`Enable_PHP_Default_Redis='y'`，默认）已经装好 phpredis 后，
再执行 `./addons.sh install redis`，PHP 启动报：

```
PHP Warning:  Module "redis" is already loaded in Unknown on line 0
```

**根因**：两条安装路径互不知道对方的存在，且约定不一致。

| | 主安装 `php_default_ext.sh` | addons `redis.sh`（改动前）|
|---|---|---|
| ini 文件名 | `021-redis.ini` | `007-redis.ini` |
| 编译选项 | `--enable-redis-igbinary` | **无** |

于是执行一次 addons 安装后：

1. **重复加载**。清理时只 `rm -f 007-redis.ini`，主安装写的 `021-redis.ini`
   原封不动：两份 `extension = "redis.so"` 同时存在。这是那行 Warning 的来源。

2. **加载顺序被破坏**（比 Warning 严重）。`conf.d` 按文件名顺序加载，
   主安装刻意把编号排成 `020-igbinary.ini` → `021-redis.ini`，
   保证 igbinary 先于 phpredis 就位。`007-redis.ini` 排在 020 **之前**，
   phpredis 先加载，igbinary 序列化器在运行时不可用。

3. **扩展本身被降级**（最严重）。addons 路径编译 phpredis 时不带
   `--enable-redis-igbinary`，编出来的 `redis.so` 覆盖掉主安装那个
   **带 igbinary 支持**的版本。对用 Redis 做对象缓存的站点（WordPress
   的 redis-cache 插件是典型）来说，igbinary 序列化在体积和速度上都明显更优，
   这一步等于把已有能力悄悄拿掉了。

**改动**（`include/redis.sh`）：

- 清理改为通配 `rm -f ${PHP_Path}/conf.d/*redis.ini`，
  覆盖两种历史文件名（安装前、安装失败回滚、卸载三处都改）
- 编译前检测 `igbinary.so`，在场就加上 `--enable-redis-igbinary`，
  与主安装路径行为一致
- 写入的 ini 改名为 `021-redis.ini`，与主安装统一，保证排在 igbinary 之后

- **行为变化**：`addons.sh install redis` 不再产生重复配置，
  不再降级已有的 phpredis；卸载时能清干净两种文件名
- **验证状态**：已实测（本阶段先复现了 Warning 与重复的两个 ini，改后重装验证）

### CLN-303 删除 mhash：OPEN-006 的实测定论

**OPEN-006 提出的疑问**：`--with-mhash` 在 PHP 8 上是否仍有效果？
本阶段实际执行结果表明：**参数有效，但未使用外部库。**

**实测证据**（PHP 8.3.33，Debian 12）：

```
phpinfo:
    MHASH support => Enabled
    MHASH API Version => Emulated Support        ← 关键在 Emulated

ldd /usr/local/php/sbin/php-fpm | grep -i mhash  → 无输出
ldd /usr/local/php/bin/php      | grep -i mhash  → 无输出

php -r 'var_dump(function_exists("mhash"));'            → true
php -r 'var_dump(function_exists("mhash_keygen_s2k"));' → true
```

结论分两半，**不要混为一谈**：

| | 结论 | 处理 |
|---|---|---|
| `--with-mhash` configure 参数 | **有效**：它启用 hash 扩展里的 mhash 兼容函数 | **保留** |
| 外部 libmhash 库（`Install_Mhash`） | **完全没被链接**：PHP 7.4 起改用内置实现模拟 | **删除** |

也就是说：编译安装 mhash 0.9.9.9（2007 年发布，上游停更近 20 年）、
再往 `/usr/lib` 铺 5 个软链，产出的东西没有任何程序在用。
与 FIX-MCRYPT-001 是同一类问题：为一个早已内置的能力保留外部依赖。

**改动**：

- `install.sh`：`Init_Install` 删去 `Install_Mhash` 调用
- `include/init.sh`：删除 `Install_Mhash()` 函数，删除 `Check_Download` 里的下载条目
- `include/version.sh`：删除 `Mhash_Ver`
- `src/checksums.sha256`：删除 mhash 条目
- `t/gen_checksums.sh`、`t/probe_urls.sh`：删除各自的 mhash 行
  （不删的话 `${Mhash_Ver}` 会展开成空串，拼出错误 URL）

**未改动**：三处 PHP `configure` 的 `--with-mhash` 原样保留：
删掉它会让 `mhash()` / `mhash_keygen_s2k()` 这些函数消失，
那是**行为变更**，可能影响依赖它们的老代码。而保留它零成本。

- **行为变化**：少编译一个组件（安装略快）；**新装**的机器不再有
  `/usr/local/lib/libmhash.*` 与 `/usr/lib/libmhash.*` 软链；
  **PHP 的 mhash 函数照常可用**
- **注意：老机器上会残留**：`uninstall.sh` 只删 `/usr/local/{nginx,php,mysql}` 等
  主目录，**不清理 `/usr/local/lib` 下的编译期基础库**。所以在装过旧版的机器上
  卸载重装后，`libmhash.*` 仍会留在那里（本阶段验收就观察到了：文件时间戳
  来自此前安装，而本阶段日志中 `Installing mhash` 计数为 0，
  证明确实没再装）。它不被任何东西加载，留着无害；要清干净可手工执行：
  ```bash
  rm -f /usr/local/lib/libmhash.* /usr/lib/libmhash.* && ldconfig
  ```
  `libmcrypt` 同理（FIX-MCRYPT-001）。
- **验证状态**：**已实测**。完整安装流程验证通过：libiconv 之后直接进 freetype，
  日志中 `Installing mhash` 计数为 0；PHP 侧 `MHASH support => Enabled`
  与 `function_exists("mhash") === true` 均保持不变

### DEB13-001 兼容 Debian 13 (trixie)：依赖清单整理

**背景**：需求约束本项目适配 Debian 13。

**先说结论：发行版判断本身不用改。** 逐条复核了全部版本判断点：

| 位置 | 判断 | Debian 13 的结果 |
|---|---|---|
| `init.sh` `Check_Supported_Distro` | `^9\|1[0-9]` | 通过（在支持范围内）|
| `main.sh:831` MySQL 8.x 源码编译门槛 | 拒绝 `^[4-8]` | 通过 |
| `main.sh:838` PHP 7.4+ 门槛 | 拒绝 `^[4-8]` | 通过 |
| `main.sh:845` PHP 5.2 上限 | 拒绝 `^1[0-9]` | 不可达（本包只剩 PHP 8.x）|

**真正的风险在依赖清单**：里面积了一批早已消失的包名，而 Debian 13 又做了
**64-bit time_t 转换**，一批共享库包改成 t64 后缀（`libglib2.0-0` →
`libglib2.0-0t64`、`libcurl3-gnutls` → `libcurl3t64-gnutls`）。

安装方式是 `for` 循环逐个 `apt-get install`，单个失败不中止：
这既是好事（不会因一个过期包名导致失败整个安装），也是坏事：
**必需包改名后会静默装不上，故障推迟到编译时才以另一副面孔出现**。

**注意：最关键的一条：`libpcre2-dev` 缺失。**

trixie 已彻底移除 `libpcre3-dev`（PCRE1 EOL，经 packages.debian.org 核实
返回「Package not available in this suite」），而清单里**只有** `libpcre3-dev`。
nginx 1.22+ 优先使用 PCRE2：Debian 12 上安装能成功，是因为 `libpcre2-dev`
被别的包当**传递依赖**捎带装上了（实测 `dpkg -l` 确认它在，但它不在清单里）。
那是运气，不是声明。到了 Debian 13，`libpcre3-dev` 装不上，
若没有别的包捎带 PCRE2，nginx 的 configure 就会因找不到 PCRE 而失败。

**改动**（`include/init.sh` 的 `Deb_Dependent`）：

1. **新增 `libpcre2-dev`**：本次最重要的一项，把真实依赖显式声明出来，
   对 Debian 12 同样是正确的（不再依赖运气）。
2. **新增 `libncurses-dev`**（trixie 的名字），与 `libncurses5-dev` 并存，
   各发行版各取所需。
3. **删除确定已消失的名字**：`zlibc`（Debian 11 起移除）、
   `libpng3` / `libpng12-0` / `libpng12-dev`（更早就没了，
   且 `libpng12-dev` 在原清单里**重复出现两次**）、`rcconf`（trixie 已移除，
   经确认全仓库没有任何代码使用它）。
4. **删除纯运行时库**：`libcurl3-gnutls`、`libglib2.0-0`、`libbz2-1.0`、
   `libpq5`、`libncurses5`、`zlib1g`、`libxslt1.1`。它们都会作为对应 -dev
   包的依赖自动装上，单独列出没有收益：而且正是这类包在 t64 转换中改了名，
   留着只会每次安装白等一轮 apt。
5. **`libc-client` 单独处理**：PHP imap 扩展依赖的 uw-imap 库
   （`libc-client-dev` / `libc-client2007e-dev`）**已从 Debian 13 移除**
   （上游 2011 年后停更）。原先混在主清单里静默失败，现在改为
   仅当 `Enable_PHP_Imap='y'` 时单独安装，装不上就明确告知
   「PHP imap 扩展将无法编译，不需要请设 `Enable_PHP_Imap='n'`」。

**已知限制**：Debian 13 上 `Enable_PHP_Imap='y'` 无法满足，这是上游库消失
导致的，不是本包能解决的。默认值本来就是 `n`。

- **行为变化**：依赖安装轮数减少（去掉 11 个死包名）；
  PCRE2 从「碰运气」变为显式依赖
- **验证状态**：
  - **Debian 12：整理后的清单已实测**（逐包执行确认 62 个包零失败，
    且 `libpcre2-dev` 确实到位、`pcre2.h` 就位）。
  - **Debian 13：待收尾验证（非 Debian 12 主线；2026-08-11 复核）。** 用户确认**老版本 v2.1 已能在
    Debian 13 上运行**（2026-08-10），因此 trixie 兼容性不是本次的风险项，
    相关验证已从任务列表移除。
    包名结论来自 packages.debian.org 逐个查证
    （`libpcre3-dev` 已确认返回「Package not available in this suite」）。

  **本条目的价值不依赖 Debian 13。** 即便只看 Debian 12，它修的也是实际问题：
  11 个早已消失的包名让每次安装白等一轮 apt；而 `libpcre2-dev` 从
  「靠别的包传递依赖捎带装上」变成**显式声明**：nginx 1.22+ 用 PCRE2，
  这个依赖本来就该写出来，不该靠运气。

### FIX-BROTLI-001 ngx_brotli 缺 brotli 库，nginx 编译必失败：安装第三个阻断（P0）

**现象**：Lua 那关过了之后，nginx 的 configure 直接中止：

```
adding module in /root/lnmp2.3/src/ngx_brotli-a71f9312c2deb28875acc7bacfdd5695a111aa53
./configure: error: Brotli library is missing from
    .../ngx_brotli-a71f9312.../deps/brotli/c directory.
Please make sure that the git submodule has been checked out:
```

随后 `Make_Install` 报 `Error: make failed in .../nginx-1.30.4`。

**根因**：`ngx_brotli` 的 `filter/config` 把库路径写死在自己的子模块目录里：

```sh
brotli="$ngx_addon_dir/deps/brotli/c"
if [ ! -f "$brotli/include/brotli/encode.h" ]; then
    ... exit 1
fi
```

**它没有任何系统库检测机制**：没有 pkg-config，没有 `ngx_feature`，
没有 `USE_SYSTEM_BROTLI` 开关。2026-08 实际执行时获取上游 master 的
`filter/config` 复核，至今仍是如此。

而本包用的是 GitHub 的 **archive 包**（为了固定 commit 以稳定 sha256），
archive **不含 git 子模块**，解压出来的 `deps/brotli/` 是个空目录。

所以只要 `Enable_Ngx_Brotli='y'`（**这是默认值**），nginx 编译必然失败。
换言之，Brotli 这个默认开启的功能从来没有真正编译成功过。

**原注释的错误假设**：`version.sh` 里写着

> 它依赖 brotli 库：系统装了 libbrotli-dev 就用系统库，否则需要拉 git 子模块

前半句是错的：装了也不会被看见，`config` 不去找系统库。
依赖清单里加 `libbrotli-dev` 这个动作本身是对的（下面的修复正依赖它），
但它当时并不能让 ngx_brotli 编译通过。

**原因不换个版本解决**：经 GitHub API 复核，`a71f9312`（2023-10-09）
**就是 master 的最后一次提交**，此后近三年无新提交。
`version.sh` 里「此后该仓库无新提交」这句是准确的。没有更新版本可换。

**改动**：新增 `Link_System_Brotli()`（`include/nginx.sh`），
在解压 ngx_brotli 之后、nginx configure 之前，把系统 brotli **软链**成
它期望的目录结构：

```
deps/brotli/c/include/brotli → /usr/include/brotli
deps/brotli/out              → <系统库目录>
```

`config` 里的链接参数是 `-L<out> -lbrotlienc -lbrotlicommon -lm`，
链接器在系统库目录里会优先选到 `.so`，于是 nginx **动态链接**系统 brotli。

**原因不下载 brotli 源码自己编译**（另一条可行路）：动态链接系统库意味着
发行版推 brotli 安全更新时**不必重编 nginx**；自带一份固定版本的源码则要
自己盯 CVE、自己重编，还要多一个下载源和一条 checksum 条目。
本包依赖清单里本来就装了 `libbrotli-dev`，用它才是原本的设计意图。

**库目录怎么定位**：用 `gcc -print-file-name=libbrotlienc.so`，
而不是硬编码 `/usr/lib/x86_64-linux-gnu`（Debian）或 `/usr/lib64`（RHEL）：
直接问编译器自己的搜索路径，跨发行版、跨架构都不用改。
实测在 Debian 12 上解析为 `/usr/lib/x86_64-linux-gnu`。

找不到头文件或库时**明确报错并中止**，给出两条可执行的出路
（装 `libbrotli-dev` / `brotli-devel`，或设 `Enable_Ngx_Brotli='n'`），
不静默降级成"装了模块但没编进去"。

**实测证据**：

```
$ ldd objs/nginx | grep -i brotli
libbrotlienc.so.1 => /lib/x86_64-linux-gnu/libbrotlienc.so.1
libbrotlicommon.so.1 => /lib/x86_64-linux-gnu/libbrotlicommon.so.1
```

- **行为变化**：`Enable_Ngx_Brotli='y'`（默认）时 nginx 能正常编译完成，
  且 brotli 走系统共享库
- **验证状态**：已实测（configure + make + ldd 三步验证）

### FIX-UNINST-002 卸载脚本：不假设 `/bin/lnmp` 存在，且命令行参数要生效

为执行全新安装而运行 `./uninstall.sh lnmp` 时发现两个问题。

**问题 1：`lnmp: command not found` 后继续删文件。**

```
./uninstall.sh: line 162: lnmp: command not found
./uninstall.sh: line 163: lnmp: command not found
```

三处 `Uninstall_*` 函数开头都直接 `lnmp kill; lnmp stop`。但**卸载最常见的
场景之一恰恰是「上次安装装到一半失败了，要清干净重来」**：
那时 `/bin/lnmp` 还没被创建（它是安装最后一步 `Add_LNMP_Startup` 才写入的）。

于是这两行报错后**流程照常往下走**，服务一个都没停就开始 `rm -rf`。
可能删到正在被进程使用的文件，或留下孤儿进程继续占着 80 / 3306 端口，
让紧接着的重装在「端口已被占用」上失败：而失败原因离真正的起因已经隔了很远。

**改动**：新增 `Stop_Stack_Services()`，三处调用点统一改为调用它。
有 `lnmp` 就用 `lnmp kill/stop`；没有就退回逐个执行 `/etc/init.d/*` 的 stop，
再兜底 `pkill -x`。init 脚本一并缺失时也能保证进程确实停了。

**问题 2：命令行参数被忽略。**

`uninstall.sh` 开头有 `Stack=$1`，但选择卸载哪个栈的分支读的是
`read -p "(Please input 1, 2 or 3): " action`：**`${Stack}` 从头到尾没被使用过**。
传入 `./uninstall.sh lnmp` 的参数未生效，脚本仍停在提示符等待输入。

自动化只能靠管道喂 stdin，而多余的字符还会被后面 `Press_Start` 的
`dd count=1`（一次读 512 字节）吞掉，实际行为很难预测：
本阶段验证使用的 `printf "1\ny\ny\ny\n"` 中，三个 `y` 均被该读取操作消耗。

**改动**：`action="${Stack}"`，为空时才进入交互提问，并回显取到的值。

**未改动**：`Press_Start` 仍不受 `LNMP_Auto` 控制（`install.sh` 的 `Press_Install`
是受控的，两者不一致）。这次没动是因为它影响 `addons.sh` / `upgrade.sh` 等多个
调用点，不宜在验证过程中扩大改动范围。见 OPEN-007。

- **行为变化**：`./uninstall.sh lnmp` 不再追问；卸载半装环境不再报
  command not found，服务会被真正停掉
- **验证状态**：待收尾验证（修复后尚未实际执行完整卸载流程；2026-08-11 复核）。

### FIX-LUA-001 Lua 冒烟测试用错方法，必然失败：安装第二个阻断（P0）

**现象**：全部 lua-resty-* 库都装完之后，安装在 nginx 编译前中止：

```
/usr/local/luajit/bin/luajit: /usr/local/nginx/lib/lua/resty/core.lua:3:
    attempt to index global 'ngx' (a nil value)
stack traceback:
	/usr/local/nginx/lib/lua/resty/core.lua:3: in main chunk
	[C]: in function 'require'
Lua 运行库冒烟测试失败：resty.core / resty.lrucache / cjson 无法 require。
继续编译只会把问题推迟到 nginx 启动时才暴露，这里中止。
```

**根因**：**测试方法本身是错的，与安装是否成功无关。**

```bash
luajit -e 'require("resty.core"); require("resty.lrucache"); require("cjson")'
```

`resty.core` 在 require 的过程中就要访问 `ngx` 全局表：那张表是
**lua-nginx-module 在 nginx worker 进程里注入**的，独立 LuaJIT 解释器里不存在。
所以这行命令**在任何机器上、无论安装是否正确，都必然报错**。
这个守卫从写下的那天起就没有一次能通过，它拦住的全是正常安装。

同时还有第二个错误：`LUA_CPATH` 写的是 `/usr/local/nginx/lib/lua/?.so`，
而 `Install_Lua_Cjson` 把 `cjson.so` 装在 `/usr/local/luajit/lib/lua/5.1/`
（`nginx.sh:141`），`nginx.conf` 的 `lua_package_cpath` 也是指向后者
（`nginx.sh:285`）。就算 resty.core 那关不存在，cjson 这关同样过不去。

**这条同样是纯静态检查发现不了的**：代码本身语法正确、逻辑自洽、
路径检查无法发现该问题，实际执行时 `resty.core` 不接受这种调用方式。

**改动**：按「模块能否脱离 nginx 运行」分两类检查。

| 模块 | 能否在裸 luajit 里 require | 现在怎么查 |
|---|---|---|
| `resty.core` | **否**（`core.lua:3` 访问 ngx） | `loadfile()` 只编译不执行，验证语法与文件完整性 |
| `resty.lrucache` | **否**（`lrucache.lua:9` 访问 ngx） | 同上 |
| `cjson` | 是（纯 C 模块，不碰 ngx） | 真正 `require`，cpath 指向实际安装位置 |

首次修复仅将 `resty.core` 归为不能直接 require 的模块，仍尝试直接加载
仅依赖 ffi 的 `resty.lrucache`，执行后出现相同错误：

```
/usr/local/nginx/lib/lua/resty/lrucache.lua:9: attempt to index global 'ngx' (a nil value)
```

**lua-resty-* 这一族库的惯例就是在 main chunk 里直接引用 `ngx`**，
因此这些模块均不能脱离 nginx worker 加载。模块依赖关系应通过实际验证确认，
不能仅根据导入项推断。

另外补了三个文件的存在性检查，并把各项检查的结果汇总后再决定是否中止：
旧实现在首次失败时立即 `exit`，只能报告第一个问题。

**注意：编译期的语法检查不是 Lua 可用性的证明，只是早期守卫。**

`loadfile` 能抓到的只有「文件没装上」「文件损坏」「与 LuaJIT 版本不兼容」
这类问题：它们值得在编译前就拦住，但**通过了也不能说明 Lua 能用**。
lua-nginx-module 是否正确编入、`ngx` 表是否注入、`lua_package_path` /
`lua_package_cpath` 是否指对、resty 库在真实 worker 里能否 require：
这些全都是**运行期**的事，静态检查一个都覆盖不到。

**唯一有意义的验证点是 nginx 起来之后走一次 server 块**。
`nginx.conf` 里本来就有现成的：

```nginx
location /lua {
    default_type text/html;
    content_by_lua 'ngx.say("hello world")';
}
```

`curl http://127.0.0.1/lua` 返回 `hello world`，才算 Lua 这条链路通了。
本条目的验证状态以这个结果为准，不以编译期检查为准。

- **行为变化**：Lua 冒烟测试不再必然失败；检查内容从「三个 require」
  变为「三个文件存在 + core.lua/lrucache.lua 可编译 + cjson 可 require」
- **验证状态**：**已实测，运行期证据完整。**

  编译期：`Lua 运行库冒烟测试通过。`，安装继续到底。

  运行期（决定性证据，在真实 nginx worker 里执行）：

  ```
  $ curl http://127.0.0.1/lua
  hello world

  $ curl http://127.0.0.1:8099/resty        # 临时 server 块，验完已删除
  resty.core     : OK
  resty.lrucache : OK
  cjson          : OK
  cjson encode   : {"ver":2.3,"lnmp":true}
  lrucache 读写  : v
  ngx.var 可用   : /resty
  ```

  `nginx -V` 确认 `lua-nginx-module-0.10.31` 与 `ngx_devel_kit-0.3.4` 均已编入，
  `nginx.conf` 的 `lua_package_path` / `lua_package_cpath` 生效。
  编译期检查够不到的部分（模块编入、ngx 表注入、路径配置、真实 require）
  至此全部覆盖。

### SEC-PMA-001 phpMyAdmin 升级路径的 blowfish_secret 可预测

**问题**：`include/upgrade_phpmyadmin.sh:64` 生成 blowfish_secret 用的是时间戳：

```bash
sed -i "s/LNMPORG/lnmp_$(date +%s%N | head -c 13)/g" ...
```

`date +%s%N` 取前 13 位就是**毫秒级 UNIX 时间戳**。

blowfish_secret 是 phpMyAdmin 用来**加密 cookie 中数据库凭据**的密钥
（`$cfg['blowfish_secret']`，cookie 认证模式下必需）。用时间戳当密钥有两个问题：

1. **可预测**。攻击者只要知道升级发生的大致日期，搜索空间就压缩到当天的毫秒数
   （8.64e7 种）：若能从服务器响应头、文件 mtime 等旁路把范围缩到几分钟，
   就只剩几十万种，离线爆破轻而易举。密钥一破，被截获的 cookie 即可解出
   数据库账号密码。
2. **长度不足**。phpMyAdmin 要求 32 字节，这里只有 13 个字符，
   新版本会直接告警 "The secret passphrase in configuration is too short"。

**原因漏掉**：首装路径 `include/php.sh:427` 在早期整改中已经改对了
（`head -c 32 /dev/urandom | od -An -tx1`），但升级路径是另一个文件里的
**同一个占位符替换**，当时只改了其中一处。两处写法一直不一致。

**改动**：`upgrade_phpmyadmin.sh` 改用与 `php.sh` 逐字相同的写法：
`head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'`，产出 64 个十六进制字符。

**影响面**：只影响**通过 `./upgrade.sh phpmyadmin` 升级过**的机器。
首装路径生成的密钥一直是安全的。

- **行为变化**：升级后的 `config.inc.php` 里 blowfish_secret 变为 64 位十六进制随机串
- **注意：已经升级过的机器需要手工轮换**：密钥可预测这件事不会因为以后再升级而消除，
  历史 cookie 仍可能被解密。执行
  `sed -i "s/^\$cfg\['blowfish_secret'\].*/\$cfg['blowfish_secret'] = '$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')';/" /home/wwwroot/default/phpmyadmin/config.inc.php`
  后重新登录即可
- **验证状态**：待收尾验证（尚未执行 `upgrade.sh phpmyadmin` 升级路径；2026-08-11 复核）。

### FIX-DBHARDEN-001 数据库加固步骤对 MySQL 8.x 的过时假设

**现象**：MySQL 8.4.7 安装过程中，两条加固步骤稳定报失败：

```
Remove anonymous users...
ERROR 1396 (HY000) at line 1: Operation DROP USER failed for ''@'%'
 ... Failed!
Remove test database...
ERROR 1008 (HY000) at line 1: Can't drop database 'test'; database doesn't exist
 ... Failed!
```

**根因**：这两条是 MySQL 5.x 时代 `mysql_secure_installation` 的固定动作。
MySQL 8.x 的 `--initialize-insecure` **已经不再创建匿名用户，也不再创建 test 库**，
所以 `DROP USER ''@'%'` 和 `DROP DATABASE test` 必然报「对象不存在」。

而判定逻辑恰好取的就是这两条的退出码：

```bash
Do_Query "DELETE FROM mysql.user WHERE User='';"   # 这条其实成功了
Do_Query "DROP USER ''@'%';"                       # 这条必然失败
[ $? -eq 0 ] && echo " ... Success." || echo " ... Failed!"   # 取的是上一条
```

**危害是误导，不是漏洞**。实际安全状态是对的（匿名用户和 test 库确实都不存在），
但输出让人以为加固没生效。更麻烦的是反向：这两行**永远**是 `Failed!`，
于是真正的失败也被淹没在预期的噪声里，等于这两项加固失去了结果反馈。

**改动**（`include/mysql.sh` 与 `include/mariadb.sh` 同步）：

- 删除冗余的 `DROP USER ''@'%';`。保留的 `DELETE FROM mysql.user WHERE User='';`
  覆盖面**更广**（所有 host 的匿名用户，不止 `%` 这一个），
  且匹配 0 行时返回成功：语义正是「确保不存在」而非「必须删掉一个」。
- `DROP DATABASE test;` → `DROP DATABASE IF EXISTS test;`
- 判定位置不变，但现在取到的是有意义的退出码。

**未改动**：`DELETE FROM mysql.user WHERE User='root' AND Host NOT IN (...)`
这条本来就在无匹配时返回成功，行为正确。后面紧跟着 `FLUSH PRIVILEGES`，
直接改系统表所需的权限重载已经有了。

- **行为变化**：加固结果不再恒为 `Failed!`；实际生效范围不变
  （改动前后 `mysql.user` 与 `SHOW DATABASES` 的最终状态一致，已实测比对）
- **验证状态**：已实测

# 阶段 10 — conf/ 配置模板梳理（2026-08-10）

起因：`conf/` 下的模板大多是 2013 年前后定稿的，此后组件版本换了好几轮，
里面既有已被上游删除的配置项（写了也不生效，但会误导人照抄），
也有当年合理、现在已不成立的取舍。本阶段逐个文件对齐现状，
并给不看文档就猜不出用途的配置项补上中文说明。

**取向**：注释只讲「现在怎么用、改错了会怎样」，不记录历史写法。

## CONF-000 回归实测暴露的 MySQL X Protocol 敞口

阶段 9 加的 `bind-address = 127.0.0.1` 在完整安装后复测，结果是：

```
LISTEN 0 500  127.0.0.1:3306   users:(("mysqld",...))   ← 已收敛
LISTEN 0 70          *:33060   users:(("mysqld",...))   ← 仍对全网监听
```

33060 是 MySQL X Protocol（X Plugin），能执行与 3306 等价的 SQL。
它**不受 `bind-address` 约束**，由独立的 `mysqlx_bind_address` 控制，默认值 `*`。
防火墙那边也只有一条 `tcp dport 3306 drop`。也就是说阶段 9 堵住的只是正门。

- **改动**
  - `include/mysql.sh` 两处 my.cnf 模板：`bind-address` 下方补
    `loose-mysqlx-bind-address = 127.0.0.1`。
    `loose-` 前缀是必需的：X Plugin 被显式关闭（`mysqlx=OFF`）时该选项不存在，
    不加前缀 mysqld 会因「未知选项」拒绝启动，加了则降级为一条警告。
  - `include/end.sh`：`Firewall_Block tcp 3306` 后补 `Firewall_Block tcp 33060`。
    MariaDB 没有这个端口，多这条规则无副作用。
- **未改** `include/mariadb.sh`：MariaDB 不含 X Plugin，写进去会导致启动失败。
- **验证状态**：已验证，见阶段 14、15 的 3306/33060 回环监听与防火墙复验（2026-08-11 复核）。

## CONF-001 `conf/nginx.conf` / `conf/nginx_a.conf`

- **`/nginx_status` 限制为本机访问**（安全）。`stub_status` 会输出当前连接数、
  握手总量、请求总量，是给攻击者做流量画像和探测服务规模的现成素材，
  而原模板对全网开放。现加 `allow 127.0.0.1; allow ::1; deny all;`。
  远程采集（Zabbix / Prometheus）请把采集端 IP 加进 `allow`，而不是删掉 `deny all`。
- **`.well-known` 改用 `^~` 前缀匹配**。ACME 的 HTTP-01 验证要读
  `/.well-known/acme-challenge/`，而这个路径会被 `location ~ /\.` 的 `deny all` 拦住。
  原来靠「正则按书写顺序匹配」这一隐式规则险胜，且正则里的点号未转义
  （`/Xwell-known` 也能命中）。`^~` 的优先级高于所有正则，命中即停止匹配，
  与书写顺序无关。
- **`(js|css)?$` 的问号去掉**。问号让扩展名变成可选，任何以点号结尾的 URI
  都会命中并被加上 12h 缓存头。
- **`gzip_types` 补 `application/json`、`image/svg+xml`、`application/rss+xml`**；
  删掉 `gzip_disable "MSIE [1-6]\."`（代价是每个请求跑一次 UA 正则，
  换来的是对早已退役浏览器的兼容）和 `gzip_http_version 1.1`（本就是默认值）。
- **补中文注释**：`worker_cpu_affinity`（VPS/容器里应关闭）、`multi_accept` /
  `accept_mutex` 为何都是 off、`sendfile_max_chunk` 的作用、fastcgi buffer
  三兄弟的区别（响应头超 `buffer_size` 直接 502，响应体超 `buffers` 只是落盘）、
  `gzip_vary` 与 CDN 的关系、`server_name _` 与 `default_server` 的分工、
  `client_max_body_size` 必须与 PHP 两个上传参数同步改。
- **`nginx_a.conf` 由 `nginx.conf` 派生**，仅 `include proxy-pass-php.conf` 一行不同，
  并在该处注明 LNMPA 与 LNMP 的架构差异。
- **保留的 sed 锚点**（脚本依赖，改动模板时不要动）：
  `server_tokens off;`、`include enable-php.conf;`、`include proxy-pass-php.conf;`、
  `gzip on;`、`listen 80 default_server;`、`location /nginx_status`、
  `/home/wwwroot/default`。
- **验证状态**：已验证，见阶段 14 `REF-NGX-001`、阶段 15 `lnmp vhost add` 与 `nginx -t` 实测（2026-08-11 复核）。

## CONF-002 `conf/enable-php.conf` / `enable-php-pathinfo.conf` / `pathinfo.conf`

配置本身没改，全部是注释补充：这三个文件是全站 PHP 执行的入口，
但每一行都不自解释，改错了直接就是解析漏洞。

- `enable-php.conf`：说明 `try_files $uri =404` 是安全边界，
  没有它 `/uploads/avatar.jpg/x.php` 会被送进 php-fpm；
  以及原因正则要写成 `[^/]\.php(/|$)` 而不是 `\.php$`。
- `pathinfo.conf`：逐行说明四条指令。重点是 `set $path_info $fastcgi_path_info;`
 该指令是必需的：下一行 `try_files` 会重新执行 location 匹配，
  过程中 `$fastcgi_path_info` 会被重置为空；以及最后一行
  `try_files $fastcgi_script_name =404` 就是 pathinfo 版本的存在性校验，
  删掉等于把解析漏洞放回来。
- 一并说明 `cgi.fix_pathinfo=0`（安装脚本设置）与这两套配置的配合关系。
- **验证状态**：仅注释，无行为变化

## CONF-003 `conf/proxy.conf` / `proxy-pass-php.conf`

- **补 `proxy_http_version 1.1`**。nginx 默认用 HTTP/1.0 与上游通信，
  不支持 chunked 请求体，上传大文件或调用某些 API 会失败。
- **删冗余的 `proxy_set_header Referer` / `Cookie`**。nginx 默认就会把客户端
  请求头原样转发，这两行不产生任何效果。
- **补 WebSocket 说明**（默认不开，注释里给出需要加的两行）。
- **补注释**：`Accept-Encoding ''` 与 `proxy_hide_header Vary` 是一组
 ：让压缩统一由 nginx 做，代价是后端压缩配置失效；`Host $http_host`
  不能省，省了会导致多站点全部串到后端的默认虚拟主机；
  `X-Forwarded-Proto` 缺失会让 WordPress 出现后台无限跳转。
- `proxy-pass-php.conf`：说明 `try_files $uri @apache` 的分工
  （静态走 nginx、伪静态走 Apache 才能读 `.htaccess`）和 `internal` 的作用。
- **验证状态**：待收尾验证（LNMPA 代理路径尚未完成安装实测；2026-08-11 复核）。

## CONF-004 `conf/config.inc.php`（phpMyAdmin 5.2.x）

**删除已被上游移除的配置项**：这些项写了也不生效，留着只会被照抄：

| 配置项 | 状态 |
|---|---|
| `$cfg['Servers'][$i]['connect_type']` | phpMyAdmin 4.7 起移除 |
| `$cfg['Servers'][$i]['extension']` | 4.2 起只支持 mysqli，配置项已移除 |
| `$cfg['Servers'][$i]['designer_coords']` | 4.7 起移除 |
| `$cfg['Servers'][$i]['auth_swekey_config']` | 4.6 起移除（Swekey 支持已废弃） |
| `$cfg['DefaultDisplay']` | 早期版本遗留，现已无效 |

**安全改动：`UploadDir` / `SaveDir` 默认关闭**：

原配置是 `$cfg['UploadDir'] = 'upload'; $cfg['SaveDir'] = 'save';`（相对路径），
`include/php.sh` 还会在**网站根目录下**创建 `phpmyadmin/upload`、`phpmyadmin/save`
并 `chown www:www`。「导出 → 保存到服务器」写出的是完整的库转储，
落在网站目录里等于把整个数据库放到公网可下载的位置，只差猜到文件名。

现改为留空（功能关闭），`php.sh` 与 `upgrade_phpmyadmin.sh` 不再创建这两个目录。
确需使用时，配置注释里给出了在网站根目录之外建目录的完整步骤。

**新增项**：

- `$cfg['TempDir'] = '/var/lib/phpmyadmin/tmp'`：模板缓存目录。
  不设置的话每次请求都要重新编译模板，页面明显变慢；
  放在网站根目录之外，避免出现「PHP 可写 + 公网可访问」的目录。
  由 `php.sh` / `upgrade_phpmyadmin.sh` 创建（属主 www，权限 700）。
- `$cfg['ShowServerInfo'] = false`：首页不再显示 MySQL 版本、协议版本、主机名。
- `$cfg['LoginCookieValidity'] = 1440`：并注明它受 `session.gc_maxlifetime` 约束，
  取两者较小值，想延长必须两边一起改。
- `AllowRoot`、配置存储（`pmadb` 等）补齐到 5.2 的完整表并加说明。

**保留**：`blowfish_secret` 的占位符 `LNMPORG` 不能改名：
`php.sh:427` 和 `upgrade_phpmyadmin.sh:68` 都靠 `sed s/LNMPORG/<32字节随机值>/` 替换它。

- **验证状态**：已验证，见阶段 14 `SEC-PMA-002` 的真实登录、缓存目录与 PHP 日志复验（2026-08-11 复核）。

## CONF-005 Apache 配置模板对齐 2.4

- **`httpd-vhosts-lamp.conf` / `httpd-vhosts-lnmpa.conf`**
  - 删 `NameVirtualHost`：Apache 2.4 已移除该指令，只会在启动时留一条
    "NameVirtualHost has no effect" 的警告。
  - `Order allow,deny` + `Allow from all` → `Require all granted`（2.4 语法）。
  - 删 `<Directory>` 里的 `SetOutputFilter DEFLATE`：它不分类型全都压，
    图片、视频、zip 都要过一遍 deflate，白烧 CPU。压缩交给
    `httpd-default.conf` 里按类型挑的 `AddOutputFilterByType`。
- **`conf/lamp`（2 处）、`conf/lnmpa`（1 处）、
  `conf/example/enable-apache-ssl-vhost-example.conf`** 同样处理：
  这些才是 `lnmp vhost add` 实际生成用户站点配置的地方。
- **`httpd24-lamp.conf` / `httpd24-lnmpa.conf`**
  - 删 `LoadModule php5_module modules/libphp5.so`。本包只支持 PHP 8.x，
    模块名早已是 `php_module` / `libphp.so`，且由 PHP 的
    `configure --with-apxs2` 自动追加，模板不需要预写。
    （`apache.sh` 里那条 `sed /^LoadModule php5_module/d` 保留作为兜底。）
  - 注释掉 `proxy_connect` / `proxy_ftp` / `proxy_scgi` / `proxy_ajp` /
    `proxy_express` 五个子模块：普通建站用不到，每个都是额外的解析代码。
    尤其 `proxy_connect`：配错 `ProxyRequests` 就是一台开放代理。
  - 在 `remoteip_module` 上方注明两种架构的差别：LNMPA 需要它还原真实 IP，
    LAMP **不能**启用（没有可信前置代理时，任何人都能伪造 X-Forwarded-For）。
- **`httpd-default.conf`**
  - `ServerSignature On` → `Off`。与 `ServerTokens Prod` 是一对，
    只设一个等于没设：版本号会从错误页那条路漏出去。
  - 删末尾的全局 `SetOutputFilter DEFLATE`（同上，它把按类型压缩的配置架空了）。
  - `Timeout 300` → `60`，并补 `mod_reqtimeout` 的
    `RequestReadTimeout header=20-40,MinRate=500 body=20,MinRate=500`，
    针对 slowloris 类慢速攻击。
  - `KeepAlive Off` → `On` + `KeepAliveTimeout 5`。本包用的是 event MPM，
    闲置长连接由单独的监听线程照看，不像 prefork 那样一个连接占一个进程，
    开着的代价很小，而 LAMP 架构下省掉的握手很可观。
  - DEFLATE 类型表补 `application/javascript`、`application/json`、
    `application/rss+xml`、`image/svg+xml`。
- **`mod_remoteip.conf`**：删掉那行注释状态的 `LoadModule`（模块在 httpd.conf
  里已经加载），补 `RemoteIPInternalProxy ::1`，并写明这份配置的安全性
  完全取决于 InternalProxy 列表写得准不准。
- **验证状态**：待收尾验证（验证机为 LNMP，Apache/LAMP/LNMPA 路径尚未实跑；2026-08-11 复核）。

## CONF-006 TLS 配置现代化（nginx 与 Apache 一并）

原先所有 HTTPS 站点用的是同一串加密套件：

```
TLS13-AES-256-GCM-SHA384:...:EECDH+CHACHA20-draft:...:RSA+AES128:...:EECDH+3DES:RSA+3DES:!MD5
```

三个问题：`TLS13-*` 是 OpenSSL 1.1.0 预发布/BoringSSL 的命名，
在 OpenSSL 1.1.1+ 上这些名字**不生效**（TLS 1.3 有独立的套件命名空间）；
`EECDH+CHACHA20-draft` 早已不存在；真正生效的部分里保留了
3DES（Sweet32）和静态 RSA 密钥交换（无前向保密）。

统一换成只含前向保密 + AEAD 的清单，并配套调整：

| 项 | 改动 |
|---|---|
| `ssl_ciphers` / `SSLCipherSuite` | ECDHE/DHE + GCM/CHACHA20，去掉 3DES、静态 RSA、CBC |
| `ssl_prefer_server_ciphers` | `on` → `off`（让手机选到有硬件加速的 CHACHA20） |
| `ssl_session_cache` | `builtin:1000 shared:SSL:10m` → `shared:SSL:10m`（官方不建议混用 builtin） |
| `ssl_session_tickets` | 新增 `off`：ticket 密钥长期不变，泄露会抵消前向保密 |
| `listen 443 ssl http2` | 拆成 `listen 443 ssl;` + `http2 on;`（nginx 1.25.1 起前者已废弃） |
| HSTS | 以注释形式给出，并写明「浏览器记住后无法用 http 回退」的风险 |
| `SSLProtocol`（Apache） | `all -SSLv2 -SSLv3` → `-all +TLSv1.2 +TLSv1.3` |
| `H2ModernTLSOnly`（Apache） | `off` → `on` |

**不开 OCSP Stapling**：Let's Encrypt 已退出 OCSP，新证书里不再包含响应端
地址、响应端本身也已停服，吊销状态改由 CRL 承担。本项目默认签发的就是
Let's Encrypt 证书，开了只会在错误日志里反复留下查不到响应端的记录。
`httpd24-ssl.conf` 里以注释说明了换用仍提供 OCSP 的商业 CA 时该怎么加回来。

同时删掉 `httpd24-ssl.conf` 的 `Mutex sysvsem default`（覆盖全局默认无必要），
`SSLPassPhraseDialog` 保留但注明「加密的私钥会让 Apache 无法开机自启」。

**改动落点**：`conf/lnmp`、`conf/lnmpa`（`lnmp ssl add` 生成用户站点配置的地方）、
`conf/httpd24-ssl.conf`、`conf/example/` 下全部 8 个示例。
`enable_ipv6` 分支里那条 `sed 's/#listen \[::\]:443 ssl http2;/.../'`
也已同步改成新写法：不改的话 IPv6 开关会静默失效。

- **验证状态**：已实测（见下）

### 实测结果（Debian 12 验证机）

```
tls1_1   握手失败（Cipher: 0000）        ← 已拒绝
tls1_2   ECDHE-RSA-AES256-GCM-SHA384
tls1_3   TLS_AES_256_GCM_SHA384
HTTP/2   ALPN 协商版本 = 2               ← http2 on 生效
DES-CBC3-SHA      已拒绝
AES128-SHA        已拒绝（静态 RSA + CBC）
AES256-GCM-SHA384 已拒绝（静态 RSA）
```

nginx 主配置的行为验证：

```
本机 /nginx_status                200      外网口 /nginx_status   403
/.env                             403      /.well-known/…/t1      200
/                                 200      /t.php                 200
/lua                              200      /x.gif/a.php           404
a.css     -> Cache-Control: max-age=43200
dotend.   -> 无缓存头                       ← (js|css)? 的问号已去掉
```

## CONF-007 伪静态规则清理

逐个文件放入测试 vhost 并执行 `nginx -t`，结果如下：

- **`sablog.conf` 语法错误，会让 nginx 直接起不到**：
  `directive "rewrite" is not terminated by ";"`：文件里混进了乱码的
  全角引号。选了这条规则的站点会连累整个 nginx 无法启动。SaBlog-X 本身
  也已停更十余年，直接删除。
- **`ecshop.conf` 有一条永远匹配不上的规则**：`exchange-` 那行的正则
  少了开头的引号，末尾的 `$"` 让整条正则无法命中。已补上引号。
  （该文件整体语法是合法的，所以 `nginx -t` 发现不了。）
- **删除已停止运营/停更的规则**：`dabr`（Twitter 客户端，2013 年即停）、
  `sablog`、`phpwind`（2018 年停止运营）、`shopex`（旧版）、
  `discuz`（Discuz! 7.x，EOL）、`discuzx2`（Discuz! X2，EOL）。
  保留 `discuzx`（覆盖在维护的 X3.x）。
- **`lnmp vhost add` 的提示文字改成按实际存在的文件列出**（原来只列 8 个，
  实际有 16 个），并说明输入其它名字会建一个空文件、规则得自己填。
- 其余 16 个规则文件 `nginx -t` 全部通过。
- **验证状态**：已实测（逐文件 `nginx -t`）

## CONF-008 pure-ftpd：口令明文传输与点号文件可写

- **启用 FTPS**。`pureftpd.sh` 的 `configure` 一直带着 `--with-tls`，
  但 `pure-ftpd.conf` 里 `TLS` 那行是注释状态：等于编译了不用，
  账号口令仍然明文过网。现设 `TLS 1`（明文与加密都接受，不影响老客户端），
  并在 `pureftpd.sh` 里生成自签证书（pure-ftpd 要求私钥和证书合并在同一个
  pem，缺文件时开 TLS 会直接启动失败，所以必须成对改）。
  配置注释里说明了「全部客户端确认支持后应改成 `TLS 2`」。
- **`ProhibitDotFilesWrite no` → `yes`**。本项目用 `.user.ini` 给每个站点
  设 `open_basedir`，FTP 用户若能覆盖它就能把限制改宽，进而读取同机其它
  站点的代码和数据库口令；`.htaccess` 在 LAMP / LNMPA 下还能让上传目录
  重新执行 PHP。代价（需要自己传 `.htaccess` 的用户会被挡）已写进注释。
- **验证状态**：待收尾验证（验证机未安装 Pure-FTPd，TLS 与点号文件限制尚未实跑；2026-08-11 复核）。

## CONF-009 其它

- `conf/index.html`：功能介绍里的「Redis/Xcache」改为「Redis/Memcached」。
  Xcache 不支持 PHP 7 及以上，本包早已不含它。
- **未处理（按需求约束搁置）**：`CentOS8-vault.repo`、`rhel-9.repo`、
  `rhel-10.repo`、`RPM-GPG-KEY-CentOS-Official` 等 RHEL 系仓库文件：
  CentOS 不是本阶段主目标。

# 阶段 11 — GitHub Actions 自动化（2026-08-10）

项目要公开发布到 GitHub。本阶段加了五个工作流和配套脚本，
把「每月查上游 → 升级 → 验证 → 发布」这条链自动化，
并把两类此前只能靠人记的约束固化成 CI 门禁。

工作流的操作说明单独写在 `.github/WORKFLOWS.md`（面向 GitHub Desktop 用户，
全部操作在网页 Actions 页面完成，不需要命令行）。

## GHA-001 五个工作流

| 文件 | 触发 | 职责 |
| --- | --- | --- |
| `ci.yml` | push / PR | 语法、ShellCheck、`t/lint.sh`、`t/consistency.sh`、编号映射与派发自测 |
| `build-test.yml` | 被调用 / 手动 | 在 debian:12 容器中**实际编译并启动**，分 quick / full 两档 |
| `upstream-check.yml` | 每月 8 号 03:00(北京) / 手动 | 查上游 → 升级 → 重算校验值 → 一致性回检 → URL 探测 → 实际编译 → 开 PR |
| `url-health.yml` | 每周二 03:00(北京) / 手动 | 探测下载 URL 是否失效，失效则开 issue |
| `release.yml` | 手动 / 推 `v2.3-*` tag | 静态检查 → full 编译验证 → 打包 → 构建证明 → 发 Release |

cron 写的是 UTC：`0 19 7 * *` 即北京时间 8 号凌晨 3 点。

**发布门禁**：`release.yml` 的 `publish` job `needs: [static, build]`，
编译验证不过就没有 Release 产出。

## GHA-002 版本号方案：产品版本不变，tag 唯一

产品版本固定 `v2.3`。但 git tag 不能反复移动：同名 tag、不同内容，
会让已下载的人二次校验时对不上，是供应链上最难排查的一类问题。故：

```
tag        v2.3-20260908
Release 名 LNMP v2.3 (2026-09-08)
包名       lnmp-v2.3-20260908.tar.gz
```

日期只是本次发布的标识，产品版本始终是 v2.3。

## GHA-003 签名：优先用不需要管密钥的方案

默认用 GitHub 原生的构建证明（`actions/attest-build-provenance`）：
基于工作流的 OIDC 身份，**不需要在仓库里存任何私钥**，
使用者 `gh attestation verify` 即可验证「这个包确实由本仓库这次工作流产出」。

GPG 分离签名作为可选项：配了 `GPG_PRIVATE_KEY` / `GPG_PASSPHRASE`
两个 secret 才走，没配自动跳过。考虑到发布者用的是 Windows + GitHub Desktop，
不应该为了发布被迫去折腾密钥管理。

## GHA-004 版本自动升级：分四类，默认只自动升 AUTO

新增 `t/check_upstream.sh`（只读，查上游）与 `t/bump_version.sh`（落盘）。

- **AUTO** 同分支内点版本，无跨组件耦合：自动升
- **COUPLED** Lua 组件，必须成组更新：默认不自动更新，可手动触发
- **MANUAL** 换 nginx stable 分支、OpenResty 大版本等：只报告
- **PINNED** 连查都不查，理由写在 `version.sh` 各自注释里

**分支锁定**是这套东西的核心约束，不是"取最新"：
nginx 只在当前 stable 分支内走（次版本偶数），出现新 stable 分支只提示；
OpenSSL 锁 3.5 LTS，不跟 3.6+/4.x；MySQL 只在 8.0 / 8.4 两个 LTS 内，
不得跳 9.x innovation；PHP 六个分支各自独立升点版本。

`t/bump_version.sh` 逐类处理**五个功能性落点**：`include/version.sh`、
`include/profile.sh`（菜单文本数组 + `Set_*_Profile` 的 case 分支，是两处）、
`t/probe_urls.sh`、`t/gen_checksums.sh`、`t/test_profile.sh`。
仅修改一处会导致菜单显示版本与实际下载版本不一致。

## GHA-005 Lua 组件的耦合处理

`lua-resty-core` 的 `lib/resty/core/base.lua` 里是硬断言：

```lua
or ngx.config.ngx_lua_version ~= 10031
error("ngx_http_lua_module 0.10.31 required but got " .. ver)
```

`10031` = `major*1000000 + minor*1000 + patch` = lua-nginx-module 0.10.31。
**它在 Lua 运行时才触发**，所以 `./configure`、`make`、`nginx -t`、
编译和 nginx 启动均可能成功，仅在首次访问包含 Lua 的 location 时返回 500。

处理办法：

1. `check_upstream.sh` 先定 `lua-nginx-module` 的目标版本，再逐个拉
   `lua-resty-core` 近 10 个 tag 的 `base.lua`，解析出它声明需要的版本，
   **配得上才成对提建议**；配不上（新模块发布了、配套 resty-core 还没出）
   整组不动。
2. 容忍 rc：当前包用的就是 `lua-resty-core-0.1.34rc3`。新模块发布后配套的
   往往只有 rc，此时用 rc 是对的，退回上一个正式版反而起不来。
3. `t/build_test.sh lua` 最后一步**发送实际请求**（curl 一个
   `content_by_lua` 的 location 并比对响应体）。少这一步拦不住。
4. `t/consistency.sh` 的 V5 做离线版校验（本地有源码时直接读断言）。

**实际验证**：当前 `lua-nginx-module` 最新 tag 为 0.10.31（与包内一致），
而 `lua-resty-core` 已有 `0.1.35rc1`（其 master 的 base.lua 要求 0.10.32）。
脚本正确地判定「整组不动」： 这正是要防的那种情况。

## GHA-006 新增的配套脚本

| 脚本 | 作用 |
| --- | --- |
| `t/check_upstream.sh` | 查上游版本，产出 `bumps.tsv` + `report.md`，**不改文件** |
| `t/bump_version.sh` | 跨五个落点一致地写入新版本号 |
| `t/refresh_checksums.sh` | **只**重算受影响的 sha256 条目 |
| `t/consistency.sh` | 跨文件一致性回检（V1–V6） |
| `t/build_test.sh` | 实际编译验证，lua / nginx / php 三档 |

`t/gen_checksums.sh` 加了 `LIST_ONLY=1` 模式（只打印「URL 落地文件名」不下载），
供 `refresh_checksums.sh` 取下载地址：地址的唯一事实来源就是那个文件，
在别处再抄一份迟早会对不上。

**原因校验值只重算受影响的条目**：全量重生成要把 MySQL / MariaDB 的
二进制包（每个 1GB 上下）全下一遍；更要紧的是**全量重生成会同时覆盖没动过的条目**，
万一某个上游悄悄重新打包了同名文件，这次重生成就把「被换掉的包」
当成新基线固化了，fail-closed 校验反而失去意义。

## GHA-007 `t/consistency.sh`：把跨文件不一致变成 CI 红灯

本项目历史上 5 个 P0 全部是跨文件不一致：单看每个文件都自洽，合起来对不上，
逐文件静态检查无法发现跨文件版本不一致，因此增加以下六项检查：

- **V1** `profile.sh` 的菜单文本数组 与 `Set_*_Profile` 的 case 分支同版本
- **V2** `t/probe_urls.sh` 的硬编码版本列表 与 `profile.sh` 一致
- **V3** `t/gen_checksums.sh` 的采集列表 与 `profile.sh` 一致
- **V4** `version.sh` 里每个组件在 `checksums.sha256` 里都有条目
  （这是 fail-closed 能生效的前提，漏一条就是装了半小时之后才中止）
- **V5** Lua 组件版本配套（离线版）
- **V6** `profile.sh` 可加载，数组长度断言通过

当前仓库执行结果：6 项全部通过。

## GHA-009 实际执行验证结果

五个工作流的 YAML 已在 Debian 12 上用 PyYAML 解析通过，
job 结构符合预期。六个脚本 `bash -n` 全部通过。

引擎实际执行（联网）：

```
lua-nginx-module 已是最新 (0.10.31)，整组不动     ← 耦合保护生效
nginx 1.30 分支最新 : 1.30.4（与包内一致）
openssl 3.5 最新    : 3.5.7（与包内一致）
PHP 8.1/8.3/8.5     : 8.1.34 / 8.3.33 / 8.5.9（均与包内一致）
MySQL 8.4           : 8.4.7 -> 8.4.11            ← 发现真实可升级项
跳过 igbinary：上游当前只有预发布版 3.2.17RC1
```

`bump_version.sh --dry-run` 对 MySQL 那一项正确定位到全部五个落点。

**过程中改掉的两个自身缺陷**：

1. **PECL 的 `stable.txt` 并不总是正式版**：igbinary 返回 `3.2.17RC1`。
   不过滤的话会把 RC 提上来，正好推翻 `version.sh` 里特意钉在 3.2.16 的决定。
   已改为带字母的一律挡掉，并在日志里说明跳过原因。
2. **php.net 接口有两种返回形态**：`?json&version=8.3` 直接返回该分支最新版的
   对象、**没有** `version` 字段；`?json&max=1&version=8` 才是以版本号为键。
   原先按字段解析，对前者恒返回空：是个会静默失效的假阴性。
   已改为从 `source[].filename` 里解析版本号，两种形态都成立。

第 2 条值得单独记：**取数脚本的失败方式是"悄悄返回空"**，
表现和"已是最新"一模一样。所以 `check_upstream.sh` 里凡是取数失败都要
计入 `errors` 并写进报告，不能静默 continue。

## GHA-010 `.gitattributes`：换行符统一为 LF

本项目在 Windows 上开发、在 Linux 上运行，是最容易出换行符事故的组合。
shell 脚本一旦混进 CRLF，在 Linux 上报的是

```
/bin/bash^M: bad interpreter: No such file or directory
```

或者更难查的 `command not found`（行尾的 `\r` 被当成命令的一部分），
而这类文件在 Windows 编辑器里看起来完全正常。

```
* text=auto eol=lf
```

`eol=lf` 是关键：只写 `text=auto` 的话仓库里是 LF，但 Windows 检出仍是 CRLF，
在本地 Git Bash 中直接执行 `t/` 下的脚本仍会出现问题。

另外单列的几类：

- `*.gif` / 各种归档 → `binary`，永不做换行转换
- `*.asc` → `-text`。这是 nginx.org 与 OpenResty 的验签公钥，
  今天已是 LF，标 `-text` 是防止将来被某个编辑器另存成 CRLF 而静默改写：
  密钥文件不该因为换行策略变动一个字节
- `src/checksums.sha256` → 显式 `eol=lf`。行尾多个 `\r` 会让
  `sha256sum -c` 的文件名对不上，表现是"文件明明在、却报校验失败"
- `conf/lnmp` / `lnmpa` / `lamp`（无扩展名的运维脚本）、`init.d/*`、
  `*.patch` 显式声明 LF

**趁 `git init` 之前加**：此时加不会产生一次全库重规范化的巨型 diff。

**同时修掉的两个文件**：`conf/rewrite/codeigniter.conf` 与
`conf/rewrite/laravel.conf` 原本就是 CRLF（从上游带来的），已规范化为 LF。

**新增 `t/consistency.sh` 的 V7 检查**：全库不允许出现 CRLF。
`.gitattributes` 负责提交/检出时统一，V7 是最后一道：
万一有人绕过去，CI 要红。已用故障注入验证：塞一个 CRLF 文件进去，
V7 立刻 `FAIL`，删掉后恢复 `ok`。

# 阶段 12 — 第三轮安全复核整改（2026-08-10）

第三轮安全复核列出 4 条 P2。逐条核对代码后全部确认，其中 SEC2-007
在验证机上实测复现。本阶段全部整改完成。

## SEC2-007 站点目录校验可被父级符号链接绕过

`Check_Vhost_Dir` 只用 `[ -L "${norm}" ]` 检查**最后一个路径组件**。
攻击者在自己可写的目录里预埋 `/home/<user>/link -> /`，管理员把站点目录填成
`/home/<user>/link/etc` 时，末段解析出来的 `/etc` 是真目录，`[ -L ]` 判为假：
校验放行，随后 `conf/lnmp:651` 的 `chmod -R 755` + `chown -R www:www`
就落在真实的 `/etc` 上。

**实测复现**（Debian 12，造 `/home/<user>/link -> /` 后单独执行该函数）：

```
/home/<user>/link            REJECT: 是符号链接           ← 末段是链接，原检查能拦
/home/<user>/link/etc        ACCEPT  → 实际解析到 /etc         ← 漏
/home/<user>/link/usr/local  ACCEPT  → 实际解析到 /usr/local   ← 漏
/etc                         REJECT: 不在允许的站点根之下      ← 直写能拦
```

- **改动**（`conf/lnmp` / `lnmpa` / `lamp` 三份，函数原本逐字节相同，同步替换）
  1. **逐级检查路径组件**，任一为符号链接即拒绝。从**匹配到的允许根之下**
     开始查、不查根本身：有些部署里 `/home` 自己就是符号链接
     （`/home -> /mnt/data/home`），那是管理员的决定，不该被拒。
  2. **`realpath -m` 交叉确认**：解析掉所有符号链接后仍须落在允许根之下。
     允许根本身也解析后再比，避免上面那种部署被误判。
     `realpath -m` 不要求路径已存在，Debian/CentOS 的 coreutils 均自带。
- **同时修复同类问题**：旧校验**允许直接填写 `/home` 本身**。
  `case "/home/" in "/home"/*)` 里的 `*` 可以匹配空串，所以 `/home` 会通过，
  接着就是 `chown -R www:www /home`：所有用户的家目录一起改掉。
  现要求至少比允许根深一层。
- **验证状态**：已实测。攻击场景 7 项全部 REJECT（含跨租户的
  `link2 -> /home/wwwroot/other`，这条只靠 realpath 是抓不到的），
  正常场景 4 项全部 ACCEPT（含目录尚不存在的新站点）。

**原因两层都要**：只加 realpath 挡不住 `link -> /home/wwwroot/other` 这种
「仍落在允许根内、但指向别的租户」的情况；只加组件遍历则挡不住
允许根自身被改指向的情况。两层各补一个缺口。

## SEC2-006 独立装库把数据库 root 密码写进安装日志

`include/only.sh` 在成功后 `Echo_Green "MySQL root password: ${DB_Root_Password}"`，
而整个函数的输出被 `tee /root/install_database.log` 收走：
密码永久留在日志里。入口是 `./install.sh db`。

这条的性质要明确：**主安装路径早就修好了**。`include/end.sh` 的
`Print_DB_Password_Notice`（SEC-CRED-001）已改成「随机密码写 0600 文件、
用户自设的不回显」，注释里还写着"密码不再打印到屏幕与安装日志"。
独立装库这条路当时漏了：又一次「修了一条路径、漏了另一条」，
和本项目那 5 个 P0 属同一类。

- **改动**
  - `Install_Database` 里删掉密码回显，只保留完成提示。
  - `Install_Only_Database` 在 `tee` 管道**之外**调用
    `Print_DB_Password_Notice`（`end.sh` 早于 `only.sh` 加载，函数可见）。
    `DB_Root_Password` / `DB_Root_Password_Random` 由更早的
    `Database_Selection` 在当前 shell 里设好，管道子 shell 不影响它们。
- **效果**：终端仍看得到密码去向（随机的给出 0600 文件路径），日志里只有
  "Install ... completed"。
- **验证状态**：待收尾验证（尚未执行独立 `./install.sh db` 并检查日志；2026-08-11 复核）。

## SEC2-008 安装 DenyHosts 前无条件清空 SSH 认证日志

`tools/denyhosts.sh:33` `cat /dev/null > /var/log/secure`、
`:39` `cat /dev/null > /var/log/auth.log`。在下载安装**之前**执行，
无备份、无确认。

原因这不只是不体贴：管理员来装 SSH 防爆破工具，通常正是因为
**已经发现被爆破**。那些日志里记着攻击源 IP、被试的账号、有没有成功登录过：
是溯源和定损的唯一依据。装个防护工具把它先删了，等于在事故现场先打扫一遍。

- **改动**：删除两行，并在原位留注释说明原因不能加回来。
  DenyHosts 本身不需要空日志：它用 `/var/lib/denyhosts/offset` 记录读到哪儿，
  首次运行会从头扫历史（这正是它能立刻封禁老攻击源的原因）。
  确实想跳过历史，应该用它自己的 offset 机制。
- **验证状态**：已验证（静态专项复核），删除操作与调用点见阶段 12 `SEC2-008`，回归检查通过（2026-08-11 复核）。

## SEC2-009 异机备份走明文 FTP，凭据进程可见

`tools/backup.sh` 旧实现存在两处问题：`lftp ${FTP_Host} -u ${FTP_Username},${FTP_Password}`
和 `mysqldump -u.. -p$MYSQL_PassWord`：口令都进了**进程参数**
（同机任何用户 `ps aux` 可见），且 FTP 控制通道与数据全程明文，
传的是完整站点文件加数据库转储。

边界成立：这是模板脚本，安装流程不会自动调度，属明示功能而非暗桩。
问题只在传输方式和凭据处理。

- **改动**
  - **异机上传改 SFTP**。`StrictHostKeyChecking=yes` +
    独立的 `UserKnownHostsFile`，**指纹文件为空就直接拒绝运行**，
    不做 `accept-new`：自动接受等于把首次连接完全交给网络。
    脚本里给出了 `ssh-keyscan` 固定指纹、再用带外方式
    （在备份服务器本机 `ssh-keygen -lf`）核对的完整步骤。
  - **专用 SSH 密钥**，配 `IdentitiesOnly=yes`（不让 agent 里的其它密钥参与）、
    `BatchMode=yes`（cron 里不会卡住）。注释里说明了原因不能复用日常密钥、
    以及在备份服务器上用 `command="internal-sftp"` 限权。
  - **数据库凭据改 option file**：`--defaults-extra-file` 指向 0600 的文件，
    口令不再出现在进程参数里。用 `extra` 而非 `--defaults-file`，
    socket 路径等系统默认仍生效。
  - **启动前校验权限**：option file 与 SSH 私钥不是 600/400 就中止并给出
    修复命令。
  - `Enable_FTP=0 表示启用` 这种反直觉写法改成
    `Enable_Remote_Backup=0 表示禁用`，且**默认禁用**。
  - 备份产物 `umask 077` + 备份目录 700：里面是整个数据库和站点源码。
  - 只能用 FTPS 或明文 FTP 时的做法写进注释（FTPS 必须固定并校验证书、
    不能关校验；明文 FTP 必须先建 WireGuard/SSH 隧道）。
  - 同时修了两处稳定性问题：`mysqldump` 在管道左侧时退出码要取
    `PIPESTATUS[0]`（旧实现会将导出失败视为成功）；数组变量 `Backup_Dir`
    与同名函数 `Backup_Dir()` 并存，函数改名 `Backup_One_Dir`。
- **验证状态**：待人工真机验证（需要真实 SFTP 服务器、SSH 私钥与主机指纹，人工执行上传、保留与恢复检查；2026-08-11 复核）。

## 本阶段回归

```
t/lint.sh          全部通过（C1–C14 + T1）
t/consistency.sh   通过 7 项，失败 0 项
t/test_profile.sh  全部通过
t/test_dispatch.sh 全部通过
bash -n            6 个改动文件全部通过
```

## 注意：阻断性提醒（上线前必读）

### 1. ~~`src/checksums.sha256` 未补齐~~：已解除（2026-08-08）

清单已由 `t/gen_checksums.sha256` 采集补齐至 **68 条**，覆盖全部安装路径。
详见 CHK-002。

**但它是有保质期的**：清单绑定具体版本号，改了 `version.sh` 或 `profile.sh`
里任何一个版本而不重新采集，安装就会在那个文件处 fail-closed 中止。

```bash
bash t/probe_urls.sh      # 改版本号后：先确认 URL 可达
bash t/gen_checksums.sh   # 再重新采集哈希
```

临时绕过的办法是 `lnmp.conf` 里设 `Enable_Download_Checksum='n'`，
但这等于回到改造前的无校验状态，**只应用于排查问题，不可用于上线**。

### 2. 完整安装历史阻断：已解除

此处是阶段 12 当时的历史状态。阶段 14、15 已在 Debian 12 完成两轮完整
`./install.sh lnmp` 与 WordPress 主线验收（2026-08-11 复核）。

以下是当时列出的风险，现保留用于追溯；前三项已由阶段 8、14、15 的编译、加载与
回归实测覆盖，内存需求属于机器规格条件，不是未完成验证项：

1. **ngx_brotli 能否编译**：依赖系统 `libbrotli-dev` 提供 libbrotlienc/dec。
   GitHub archive 不含 git 子模块，若 config 没找到系统库就会失败。
   依赖清单已加，后续见阶段 8 `FIX-BROTLI-001` 实测。
2. **ngx_cache_purge 2.3 与 nginx 1.30 的兼容性**：FRiCKLE 原仓库停更于 2015 年，
   老模块对新版 nginx 的内部 API 可能不适配。
   备选：`nginx-modules/ngx_cache_purge`（活跃 fork，2.5.x / 3.0.x，归档实测可下载）。
3. **lua-cjson 的编译参数**：`LUA_INCLUDE_DIR` 指向
   `/usr/local/luajit/include/luajit-2.1`，该路径依赖 LuaJIT 的实际安装布局。
4. **内存是否够编译**：PHP 与 nginx 编译较吃内存。

验证环境与方法见「验证环境」一节。

### 3. ~~`t/test_dispatch.sh` 目前必定失败~~：已解除

现已通过。`upgrade_php.sh` 对已删除函数的引用在后续阶段清理完毕。

### 4. ~~插件安装当前一定失败~~：已解除

`Download_Mirror` 的约 40 处引用已全部改为 pecl / 上游官方源，
lint 的 C7 现在为零输出。这批 URL 也已由 `t/probe_urls.sh` 实测可达。

---

> 本节是早期进度快照，后续状态以阶段 14、15 和阶段 16 的收尾索引为准。

### 已完成

- 阶段 0 建立基线
- 阶段 1 间接层（`profile.sh`）+ 全部编号语义化：**C1 收敛不变式已达成**
- 阶段 2 `only.sh` 去重（`dbcommon.sh`）
- 阶段 4 重编号（DB 1..5 / PHP 1..6 / Apache 1）
- 阶段 5x `version_compare` 内联（6 处调用点全部替换）
- 阶段 3 主体：`mysql.sh` 897→356、`mariadb.sh` 748→222、`php.sh` 1445→383、
  `multiplephp.sh` 1484→130
  （以上是阶段 3 完成时的快照。后续阶段补了注释与修复，2026-08-08 的实际值是
  378 / 221 / 401 / 138：核对行数时以当前文件为准，不要拿这里的数字去对。）
- 阶段 5 主体：地理探测移除、校验 fail-closed、**全部保留组件的下载源改上游官方**、
  composer 管道直执治理、默认攻击面收敛、`-DDOWNLOAD_BOOST=1` 移除
- 插件下载源改 pecl / 上游官方：memcached、apcu、imagemagick、swoole、
  sodium、opcache、ionCube、pureftpd、denyhosts、fail2ban
- 验证脚本已写好（`t/lint.sh`、`t/test_profile.sh`、`t/test_dispatch.sh`）

### 历史未完成项

> 下表是 2026-08-08 之前的状态，现均已完成，保留以便追溯。

| 项 | 说明 | 状态 |
|---|---|---|
| 校验清单 | `src/checksums.sha256` 只填了 6 个 PHP 条目 | 通过 已补至 68 条（CHK-002） |
| 阶段 3 剩余 | `apache.sh` 删 `Install_Apache_22` | 通过 已删（CLN-206） |
| 阶段 6 剩余 | `upgrade_php.sh` / `upgrade_mphp.sh` 的老版本与失效引用 | 通过 已清理，`t/test_dispatch.sh` 通过 |
| 域名清除 | 约 40 个文件仍含禁用域名 | 通过 可执行取用已清零（lint C9）；banner / FAQ 里的署名文本按用户确认保留 |
| 升级侧裁剪 | `upgrade_mysql/mariadb/mysql2mariadb` 的老版本 | 通过 已裁剪（DEL-UPG-001） |
| **真实安装** | 当时尚未完整执行 `./install.sh` | 已完成：见阶段 14、15 Debian 12 主线实跑 |

#### FIX-001：`main.sh:660` 多余的 `}`（已修）

`bash -n` 首轮扫描查出，是本次改造引入的**唯一**语法错误。

删除 `Check_Mirror` 旧函数体（原 45 行的镜像探测与切换逻辑）时，
函数体末尾的 `}` 未一并删除，与新写的 `}` 重复：

```bash
Check_Mirror()
{
    :
}
}          # ← 残留
```

影响：`include/main.sh` 整个文件无法被 source，即**任何入口脚本都跑不起来**。
这是一处可通过静态语法检查发现的严重错误，说明修改后必须执行 `bash -n`。

### 注意：需要人工确认的遗留

1. `Install_MySQL_80` / `Install_MySQL_84` 现引用 `${DB_Bin_Tarball}`
   （由 `DB_Download_Files` 设定）。若走 `Bin=y` 但未经 `DB_Download_Files`
   的路径调用这两个函数，该变量为空：需确认无此路径。
2. `include/upgrade_php.sh` / `upgrade_mphp.sh` 仍引用已删除的函数
   （在待裁剪的老版本升级函数体内）。这会让 `t/test_dispatch.sh` 报错，
   也会让 `lnmp upgrade` 走到老版本分支时失败。
3. 部分官方下载 URL 是按命名规律推导的（如 jemalloc / libunwind / nghttp2 /
   ngx-fancyindex / denyhosts / fail2ban 的 GitHub release 路径，
   libmemcached 的 launchpad 路径）。**这些 URL 未经实际下载验证**，
   首次运行时若 404 需按各项目实际发布路径修正。

---


## 自检命令索引

**实际执行以 `t/lint.sh` 为准**，一条命令跑完全部静态检查：

```bash
bash t/lint.sh          # 全部；或 bash t/lint.sh C7 只跑单项
```

下表说明每项检查什么、对应哪些变更条目。这里**不再抄写具体的 rg 命令**：
2026-08-08 核对时发现手抄的命令已与实现漂移（C3 在实现里是 C3a/C3b 两项，
C4 压根没实现过，预期值也过时了），两份定义只会互相矛盾。

| ID | 检查内容 | 覆盖条目 |
|----|---------|---------|
| C1 | 选择变量只出现在 profile / main / multiplephp / upgrade_mphp | 全部 REN-* |
| C2 | 无残留的旧版本标识（mysql-5.x / php-5.x / php-7.x 等） | DEL-DB-*, DEL-PHP-* |
| C3a/C3b | `DB_Info` / `PHP_Info` 数组下标未越界 | REN-DB-001 |
| C4 | 数据库下载未在 only.sh / init.sh 重复 | REF-DUP-001 |
| C5 | 无不可信组件引用（p.php / ocp.php / SourceGuardian / XCache / eAccelerator） | SEC-WEB-*, DEL-* |
| C6 | 无对已删除安装函数的引用 | DEL-* |
| C7 | 无站长镜像引用（Download_Mirror / soft.vpser / Check_Mirror） | SEC-DL-* |
| C8 | 无地理探测（Get_Country / ip.vpszt） | SEC-GEO-* |
| C9 | 无禁用域名**下载**（只拦 wget/curl/Download_Files 参数位置，不拦署名文本） | SEC-DOM-* |
| C10 | `src/checksums.sha256` 格式正确，并报告条目数 | SEC-CHK-*, CHK-002 |
| C11 | 校验已 fail-closed（无 fail-open 早退） | SEC-CHK-001 |
| C12 | 无 `-DDOWNLOAD_BOOST`（不让 cmake 自行联网） | SEC-DL-* |
| C13 | 无明文 HTTP 下载 | SEC-HTTP-001 |
| C14 | 无 iptables 调用与持久化包安装 | FW-001 |
| T1 | 全部 `*.sh` 通过 `bash -n` | 全部 |
| T2 | `bash t/test_profile.sh` — 编号映射表 | REN-* |
| T3 | `bash t/test_dispatch.sh` — 派发可达性 | DEL-*, REN- |
| T4 | `bash t/probe_urls.sh` — 70 条下载 URL 可达性 | URL-001, VER-001, NGX-001 |

需要联网的只有 T4（以及采集用的 `t/gen_checksums.sh`），其余在任何有 bash
的机器上均可执行，包括 Windows 的 Git Bash。

---

## 验证环境

> 本节记录改造期间实际使用的验证环境与操作方式，供后续维护复现。

- **代码**：Windows，`<本地代码目录>`
- **验证机**：VMware 本地虚拟机 **Debian 12 bookworm**，`root@<验证机IP>`
  - 2 核 / **2GB 内存** / 975M swap / **19G 磁盘**
  - MySQL 源码编译在此配置下内存与磁盘都吃紧（官方建议 4G+ 内存），
    实际验证优先使用通用二进制包路径（`DB_Bin_Default='auto'` 默认即二进制）
- **免密 SSH 已配置**：

```bash
ssh -i <你的私钥文件> -o BatchMode=yes root@<验证机IP> '<命令>'

# 同步代码（整包 1.4M，直接全量推）
scp -i <你的私钥文件> -o BatchMode=yes -q -r \
    <本地代码目录>/. root@<验证机IP>:/root/lnmp2.3/
```

### 安装验证注意事项

**不要在生产机上直接执行 `./install.sh`。** 它以 root 运行，会：

- `yum -y remove httpd* php*` / `apt-get purge` 卸载系统自带包
- 接管防火墙：停用 firewalld，改由 nftables 管理（见 FW-001）

（`Check_Hosts` 覆写 `/etc/resolv.conf` 的行为已在早期改造中修掉，改为只提示。）

建议在可回滚的环境里验证：VMware 快照，或一次性容器：

```bash
docker run --rm -it -v /root/lnmp2.3:/pkg -w /pkg debian:12 bash
./install.sh lnmp
```

安装是交互式的（选数据库、PHP 版本、内存分配器），默认值
DB=2（MySQL 8.4 LTS）、PHP=4（8.3）。日志写到 `/root/lnmp-install.log`。

---

## 已知遗留问题

> 明确不在本次范围内的事项，避免复核时反复提出。

### OPEN-001 upgrade 系列的独立编号体系

`upgrade_mphp.sh` 的 `MPHP_Select` 是第四套独立编号（`:61-102`, `:168-190`），
`multiplephp.sh` 是第三套。它们靠用户 `read` 输入的版本字符串做正则匹配，
**不依赖 `DBSelect`/`PHPSelect`**，所以重编号不影响它们：但版本裁剪影响。

本次已纳入范围（见 D-005），但**未统一到 `profile.sh` 间接层**。
四套编号体系仍然存在，只是内容被裁剪一致了。

### OPEN-002 本包未与官方原版做 diff

见「复核结论 — 无法回答的问题」。明确的需求约束不下载 vpser.net。
**「此包是否被第三方改动过」在本次改造中无法回答。**

### OPEN-003 `src/checksums.sha256` 的维护成本

每次上游版本升级都需要更新哈希清单。若清单未更新而 `version.sh` 已改版本号，
fail-closed 逻辑会让安装直接失败：这是**预期行为**，但会造成维护负担。

替代方案（本次未采用）：改用 GPG 签名验证。nginx/php/apache/openssl 都提供 `.asc`
签名文件，优点是版本升级时不用更新清单，缺点是需要内置各项目公钥、实现复杂度高得多。

**2026-08-08 补充**：维护负担已用 `t/gen_checksums.sh` 摊平：改完版本号跑一遍
就能重新生成整份清单，不必逐条手抄。但**仍需记得跑**，这一点没有变。

另外注意 GPG 方案并不能覆盖全部组件：本清单里的 lua-resty-* 系列、
ngx_brotli、ngx_cache_purge、pecl 扩展等都只有 GitHub / pecl 的 tag 归档，
上游不提供签名文件。真要上 GPG，也只能是「有签名的用签名、没有的还得靠哈希」
的混合方案，复杂度反而更高。

### ~~OPEN-005 本次改造未在真实环境执行过~~：部分解除（2026-08-08）

原文：开发环境是 Windows，`t/` 下的验证脚本尚未运行，语法错误是最可能的残留缺陷。

**已解除的部分**：全部脚本的 `bash -n`、`t/lint.sh`（14 项）、`t/test_profile.sh`、
`t/test_dispatch.sh`、`t/probe_urls.sh`（62 条 URL）均已在 Debian 12 上跑通。
静态检查已在 Debian 12 上执行。

**仍未解除的部分**：**尚未完整执行 `./install.sh`**。编译层面的正确性
（configure 参数、模块能否编入、扩展能否加载）仍是静态推理。
见「注意：阻断性提醒」第 2 条。

### OPEN-007 `Press_Start` 不受 `LNMP_Auto` 控制

`install.sh` 走的 `Press_Install` 会检查 `${LNMP_Auto}`，设了就跳过按键等待；
但 `include/main.sh:315` 的 `Press_Start` **没有这个判断**，无条件执行
`stty` + `dd count=1`。

后果：`uninstall.sh`、`addons.sh`、`upgrade.sh` 在非交互环境下都会走到这里，
在没有 tty 时打印 `stty: 'standard input': Inappropriate ioctl for device`，
并从 stdin 吞掉最多 512 字节：后续如果还有 `read`，读到的内容就是错乱的。

**未在本阶段处理**：调用点分散在多个脚本，改动范围超出本阶段验证修复范围。
建议的改法与 `Press_Install` 一致：函数开头加 `[ -n "${LNMP_Auto}" ] && return 0`。

### OPEN-006 `--with-mhash` 在 PHP 8 上是否仍有效果未验证

见 FIX-MCRYPT-001 末尾。`Install_Mhash` 编译安装的是 mhash 0.9.9.9（2007 年发布，
上游已停更），三处 PHP `configure` 都带 `--with-mhash`。

但 PHP 的 hash 扩展自 7.4 起内置，mhash 兼容层在 7.4 废弃、**8.0 已移除**，
`--with-mhash` 很可能只是被 configure 忽略的未知选项（只警告不失败，
因此安装仍能通过）。若确认 PHP 8.3 的 `php -m` 中没有组件依赖它，
应按 FIX-MCRYPT-001 的同一理由删除：少编译一个停更 18 年的库。

**验证方法**：安装完成后
`ldd /usr/local/php/sbin/php-fpm | grep -i mhash`，
以及 `grep -i mhash /usr/local/php/etc/php.ini` 与 configure 输出里的
`unrecognized option` 警告。

### ~~OPEN-004 conf/ 下的信息泄露面未完全清理~~：已解除（2026-08-08）

见 SEC-WEB-002：匿名 `$mem->flush()` 已删除，演示页改为默认不部署
（`Enable_Memcached_Test_Page='n'`），`index.html` 里指向已失效页面的链接也已修正。

# 阶段 13 — 发布前审计整改（2026-08-10）

本阶段处理审计记录中的 6 项问题。逐项复核后确认全部属实，均已修复。
改动集中在数据库升级路径的数据完整性、CI 与自动升版的可信度，以及 FTP 目录边界。

## DBSEC-001 数据库升级会撤销本地监听限制

**位置**：`include/upgrade_mysql.sh`（两处模板）、`include/upgrade_mariadb.sh`、
`include/upgrade_mysql2mariadb.sh`

全新安装写入 `bind-address = 127.0.0.1`，MySQL 另加
`loose-mysqlx-bind-address = 127.0.0.1`。三条升级路径都会重新生成
`/etc/my.cnf`，但模板里没有这两行——升级完成后 3306 改为监听所有网卡，
MySQL 的 33060 同样暴露。

防火墙仍在，但安装路径已把本地监听作为独立的一道防线，升级不应静默撤销它。

**改动**：三处模板补齐与安装路径相同的监听基线。MySQL 两处模板内容逐字节相同，
一并替换；MariaDB 无 X Protocol，只需 `bind-address`。

## DBSAFE-002 备份、导入或升级失败仍报告成功

**位置**：`include/dbcommon.sh`（新增校验函数）、三条升级路径

三条路径的最终成功判定只检查二进制与 `/etc/my.cnf` 是否存在，
中间步骤的结果基本不看：

| 步骤 | 原实现 |
| --- | --- |
| `mysqldump` | 检查退出码，但不检查产物是否完整 |
| 导入备份 | MySQL/MariaDB 两条完全不检查；转 MariaDB 那条打印失败后继续执行 |
| `mysql_upgrade` | 不检查 |
| `mysqld --upgrade=FORCE` | 后台执行 + `sleep 180` + 无条件 shutdown，退出状态从未读取 |

`upgrade.sh` 已经用 `${PIPESTATUS[0]}` 捕获退出码，问题不在捕获机制，
而在于函数自身失败时不返回非零。

**改动**：`include/dbcommon.sh` 新增四个共用函数：

- `Check_DB_Backup` —— 确认备份文件存在、非空，且含 `-- Dump completed` 结束标记。
  仅看 `mysqldump` 的退出码不足以判定完整性：磁盘写满或进程被中断时，
  重定向产生的文件依然存在且体积可观，内容却是截断的。
- `Snapshot_DB_List` —— 停服前记录库列表。排除 `information_schema` /
  `performance_schema` / `sys`：这三个库由服务端按版本自行维护，
  跨版本乃至 MySQL 与 MariaDB 之间的存在性并不一致。`mysql` 库保留，
  账号与授权丢失同样是升级事故。
- `Verify_DB_Upgraded` —— 升级后依次确认服务可连接、库列表无缺失
  （`comm -23`，只报缺失不报新增）、监听地址符合基线。
- `DB_Upgrade_Abort` —— 统一提示备份与原实例目录位置，说明现场已保留。

三条路径接入后，任一关键步骤失败即 `exit 1` 并保留现场；
`mysqld --upgrade=FORCE` 改为轮询实例可用性（上限 30 分钟）替代固定等待，
原实现对大库可能未升完就 shutdown，对小库则空等三分钟。

**验证**：`Check_DB_Backup` 对空文件、不存在、截断、完整四种输入判定正确；
库列表比对对「无变化 / 缺一个库 / 新增一个库」分别得出
空、缺失该库、空——符合预期。真实升级需在验证机上另行实测。

## OPS-001 自动升版的真编译验证跑的是升级前代码

**位置**：`.github/workflows/build-test.yml`、`.github/workflows/upstream-check.yml`

`check` job 把升版结果上传为 `bumped-tree`，但被复用的 `build-test.yml`
重新 checkout 当前提交，从未下载该 artifact。因此 verify 编译的是升级前版本，
而 PR 文案会声称升级后的 Lua 组合已通过真编译。

**改动**：`build-test.yml` 增加可选入参 `artifact`，非空时在 checkout 之后
下载并覆盖工作区，三个编译 job 均已接入；另加一步打印实际参与编译的版本号，
便于从日志确认。`upstream-check.yml` 的 verify 传入 `bumped-tree`。
`release.yml` 不传该参数，行为不变——发布时代码已经提交。

## OPS-002 PHP 与 Apache 自动升版未同步测试期望值

**位置**：`t/bump_version.sh`、新增 `t/test_bump.sh`

MySQL/MariaDB 分支会把 `t/test_profile.sh` 传给替换函数，PHP 与 Apache 分支没有。
自动升版后映射表已更新，测试仍断言旧版本，常规 CI 必然失败——
故障出在升版脚本，报错却出现在测试里。

**改动**：

1. PHP 与 Apache 分支补上 `${TESTPF}`。
2. 新增 `t/test_bump.sh`：对每类在 `t/test_profile.sh` 中有断言的组件，
   在临时副本上各做一次真实升版，随后执行 `t/test_profile.sh`。
   任一分支漏掉需要同步的文件，对应用例即失败。
   版本号从 `t/test_profile.sh` 现有断言中提取，不需要随组件升级维护该文件。
3. 接入 `ci.yml` 与 `release.yml` 的静态检查。

**验证**：12 个用例（PHP 6 个分支、Apache、MySQL 2 个、MariaDB 3 个）全部通过。
反向验证：把 PHP 分支还原成缺少 `${TESTPF}` 的写法后重跑，
6 个 PHP 用例立即失败并指向 `t/bump_version.sh` 中对应的分支。

## FTPSEC-001 FTP 用户目录缺少边界校验

**位置**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp`

FTP add/edit 接受任意非空目录，创建后直接传给 `pure-pw -d`，
没有调用同一脚本中已有的 `Check_Vhost_Dir`。管理员误填 `/` 或 `/etc` 时，
该目录会被 `mkdir -p` 与 `chown -R www:www`，并成为 FTP 账号的根目录。

**改动**：三份脚本的 `Add_Ftp_Menu`、`Edit_Ftp`、`Add_Ftp` 均接入
`Check_Vhost_Dir`。`Edit_Ftp` 留空表示不修改目录，因此只在确实填了新值时校验。
`Add_Ftp` 处的校验为兜底——该函数也可由 vhost 流程直接调用，
不能假设 `vhostdir` 已经过校验；`Check_Vhost_Dir` 幂等，重复调用无副作用。
`conf/lnmp` 一并把两处 `read` 换成带 EOF 守卫的 `Read_Input`。

## 复核中未采纳的一项

审计指出 `nft add table` 对已存在的表返回非零。实测三次均返回 0——
`nft add` 本身就是幂等的，这正是它与 `nft create` 的区别。
该处代码与注释一致，未作改动。

## 本阶段验证结果

- `t/lint.sh`、`t/consistency.sh`、`t/test_profile.sh`、`t/test_dispatch.sh`、
  `t/test_bump.sh` 退出码均为 0。
- 改动涉及的全部 shell 文件通过 `bash -n`。
- 数据库升级路径的改动为静态修复，真实升级实测尚未进行，
  正式启用升级功能前应在验证机上跑一次完整的 MySQL 与 MariaDB 升级。

---

# 阶段 14 — 注释整改后的复核与真机实跑（2026-08-10）

上一轮对全仓注释做了整改。本阶段先确认整改没有误删代码或留下大段空白，
再在 Debian 12 上做一次全新安装的 WordPress 场景实跑，并复核代码与运营安全。
共修复 4 个问题，另按要求完成 2 项规范化。

## CLN-BLANK-001 删注释残留 99 处大段空白

**位置**：34 个 shell 文件 + `conf/lnmp`、`conf/lnmpa`

注释整改后留下 3～37 行的连续空行，最严重的在 `include/firewall.sh` 开头（37 行）、
`addons.sh`（27 行）、`include/profile.sh`（25 行）。

**核查结论**：仅为空行，无代码丢失。依据三项：全量 `bash -n` 通过；
函数定义与调用比对无缺失（406 个定义，命令位置上的调用全部有对应定义，
其余疑似项经查全是版本号变量）；`t/` 自检套件全绿。

**处理**：连续空行压缩为一个。处理时跳过 heredoc 区域，
避免改动脚本生成的配置文件内容。

## FIX-MYCNF-001 残留的 ~/.my.cnf 导致数据库初始化失败

**位置**：`include/mysql.sh`、`include/mariadb.sh`

`mysqladmin -u root password` 未指定选项文件，MySQL 客户端会自动读取
`~/.my.cnf`。系统上若存在上一次安装遗留的该文件，客户端会带**旧密码**连接，
这一步必然失败，日志中出现
`Access denied for user 'root'@'localhost' (using password: YES)`。

成因在于 `Make_TempMycnf` 备份原文件、`TempMycnf_Clean` 用 `cp -p` 恢复。
该机制本身正确（保护用户既有的客户端配置），但恢复出来的文件会干扰下一次安装。
干净系统上没有备份可恢复，因此不残留。

**处理**：两处 `mysqladmin` 改为 `--defaults-file=/etc/my.cnf`，只读主配置，
不再受 `~/.my.cnf` 影响。回退路径里的 `~/.emptymy.cnf` 一并改为
显式的 `${HOME}` 路径并补上 `socket`，同时套 `umask 077`。

**验证**：真机上先复现失败（未加参数时建库被拒），再用同一手法执行建库成功。

## SEC-SQLESC-001 root 密码未转义即拼入 SQL 与选项文件

**位置**：`include/main.sh`、`include/mysql.sh`、`include/mariadb.sh`

`SET PASSWORD FOR 'root'@'localhost' = '${DB_Root_Password}'` 以及
`Make_TempMycnf` 写入的 `password='$1'` 都是直接拼接。密码含单引号或反斜杠时
会截断语句，导致实际生效的密码与用户输入不一致。

**处理**：`include/main.sh` 新增 `SQL_Escape()`，转义反斜杠与单引号——
MySQL 的 SQL 字面量与选项文件的引号内取值使用同一套转义规则，两处通用。
应用于 `Make_TempMycnf` 及 `mysql.sh` 两处、`mariadb.sh` 一处。

建库路径此前已使用 `${mysql_password_q}` 并对库名做白名单校验，
`tools/reset_mysql_root_password.sh` 已用 `${Sql_Escaped_Password}`，
本次补齐的是 root 密码这条遗漏路径。

## SEC-EXPOSE-001 X-Powered-By 暴露 PHP 版本

**位置**：`include/php.sh`、`include/multiplephp.sh`、
`include/upgrade_php.sh`、`include/upgrade_mphp.sh`

`php.ini-production` 的 `expose_php` 默认为 `On`，安装流程未关闭，
PHP 响应头带 `X-Powered-By: PHP/8.3.33`。

**处理**：四条 PHP 安装与升级路径统一在设置 `cgi.fix_pathinfo` 之后
追加 `expose_php = Off`。

**验证**：真机应用后该响应头消失。

## STYLE-CONF-001 配置文件花括号风格统一

`events` 换行再写 `{` 的写法统一改为 `events {`。

**范围**：`conf/` 下 20 个 nginx 配置文件共 56 处，
以及 `conf/lnmp`、`conf/lnmpa` 中 heredoc 内 vhost 生成模板的 16 处。

`conf/lnmp`、`conf/lamp`、`conf/lnmpa` 里 shell 函数定义的换行花括号
是本项目既有代码风格，不属于配置文件风格，未作改动。

**验证**：真机 `nginx -t` 通过；`lnmp vhost add` 生成的虚拟主机配置
确认为新风格且 `nginx -t` 通过。

## REF-OR-001 OpenResty 使用独立配置模板

**位置**：`include/openresty.sh`，新增 `conf/openresty.conf`

原先复制 `conf/nginx.conf`，再用三段 `sed` 注入 `lua_package_path`、
`lua_package_cpath` 和 `location /lua`。锚点是 `server_tokens off;` 与
`include enable-php.conf;`——主模板一旦改动这两行，Lua 搜索路径就会静默失效。

**处理**：新增独立模板 `conf/openresty.conf`，Lua 路径指向 OpenResty 自带的
`/usr/local/openresty/lualib`；`openresty.sh` 直接铺该模板，三段 sed 全部删除。
源码版 nginx 的 Lua 路径指向 `/usr/local/nginx/lib/lua`，两者不再共用模板。

`upgrade_openresty.sh` 只备份 conf 目录、不铺模板，无需同步改动。

**验证**：真机 `nginx -t` 通过，含 `content_by_lua_block` 语法。

## SEC-PMA-002 phpMyAdmin 移出网站根目录，访问路径随机化

**位置**：`include/main.sh`、`include/php.sh`、`include/end.sh`、
`include/upgrade_phpmyadmin.sh`、`conf/lnmp`、`uninstall.sh`、
`conf/nginx.conf`、`conf/nginx_a.conf`、`conf/httpd24-lamp.conf`、
`conf/httpd24-lnmpa.conf`

原先装在 `${Default_Website_Dir}/phpmyadmin`，固定路径 `/phpmyadmin/`
是自动化扫描与爆破的常规目标；且程序位于网站根目录下，
Web 服务器配置一旦失效，整套源码连同 `config.inc.php` 就能被当作静态文件下载。
升级脚本把旧版本备份到同为网站根目录的 `phpmyadmin<日期>`，同样可被下载。

**处理**：

1. 程序改装到 `/usr/local/phpmyadmin`（新增常量 `PhpMyAdmin_Dir`），
   升级的备份目录一并移到 `/usr/local/phpmyadmin.bak.<日期>`。
2. 访问路径每次安装随机生成，形如 `49763abb_phpmyadmin`，
   记录在 `${PhpMyAdmin_Dir}/.access_url`（0600）。
   保留 `_phpmyadmin` 结尾：默认站点若配了严格访问控制，
   这个固定后缀便于辨认用途，写放行或封禁规则时不至于误伤。
3. 新增 `Config_PhpMyAdmin_Access`，按 `Enable_PhpMyAdmin` **双向**同步入口——
   开启时生成映射片段，关闭时删除，不需要手工改 default 站点的配置。
   片段落在 `phpmyadmin.enable.conf`，主配置用通配 `include` 引入；
   通配符没匹配到文件时不报错，所以关闭只需删文件。
   LNMP 走 fastcgi，LNMPA 反代给 Apache，LAMP 用 Apache 的 `Alias`。
4. 程序已不在网站根目录下，根目录里的 `.user.ini` 管不到它，
   `open_basedir` 改由片段中的 `PHP_ADMIN_VALUE` 下发，
   范围限定为程序目录、模板缓存目录、`/tmp` 与 `/proc`。
5. 安装结束提示与 `lnmp status` 均回显实际路径；
   卸载清理 `/usr/local/phpmyadmin*` 与 `/var/lib/phpmyadmin`。

**说明**：随机路径挡的是批量扫描和源码直接下载，**不等于访问控制**。
对外服务仍建议追加来源白名单，做法见 `HowtoGuides.md`。

**验证**（真机逐项实测）：无片段文件时 `nginx -t` 通过（关闭态可用）；
开启后 `/<随机路径>` 301 跳转、登录页 200、静态资源 200；
用 root 账号完成一次真实登录（302 且后续页面回显 MySQL 信息），
php-fpm 日志无 `open_basedir` 报错；旧固定路径 `/phpmyadmin/` 返回 404；
`config.inc.php` 经 PHP 执行返回 0 字节，不泄露源码；
关闭后片段被删除、`nginx -t` 通过、访问返回 404。

## FIX-DBMSG-001 数据库初始化的回退路径打印误导性报错

**位置**：`include/mysql.sh`、`include/mariadb.sh`

设置 root 密码有两条途径，第一条失败会由第二条兜底，属于正常分支。
但第一条的 stderr 直接打到终端，安装日志里出现
`Access denied for user 'root'@'localhost'`，很容易被当成安装失败。

**处理**：第一条途径的报错先收进变量，只有两条都失败时才展示，
并把提示改写为说明性文字。诊断信息没有丢失。

## 本阶段验证结果

实跑环境：Debian 12 bookworm / x86_64。口径：

```
LNMP_Auto=y DBSelect=2 Bin=y PHPSelect=4 SelectMalloc=1 InstallInnodb=y \
Enable_PhpMyAdmin=y DB_Root_Password=<测试密码> ./install.sh lnmp
```

- 全新安装 **9 分钟**跑通，nginx 1.30.4 + PHP 8.3.33 + MySQL 8.4.7 + phpMyAdmin 5.2.3
  三个服务全部 active。
- WordPress 全流程通过：`lnmp vhost add` 建站 → 建库 → 部署 → 安装向导完成 →
  首页渲染、后台登录页、伪静态均返回 200。
- 对外监听仅 80 与 22；`3306` 与 `33060` 均绑回环，
  确认 `loose-mysqlx-bind-address` 生效（旧版本曾是 `*:33060`）。
- `t/lint.sh`、`t/consistency.sh`、`t/test_profile.sh`、`t/test_dispatch.sh`、
  全部退出码均为 0；全部 shell 文件通过 `bash -n`。

# 阶段 15 — Debian 12 + WordPress 主线验收（2026-08-10）

本阶段按指定版本实跑：Nginx 1.30.4、PHP 8.3.33、MySQL 8.4.7 官方通用二进制、
phpMyAdmin 5.2.1、Redis 8.8.0。

## 版本调整

- phpMyAdmin 从 5.2.3 调整为 5.2.1。
- Redis Server 从 8.10.0 调整为 8.8.0。
- 同步更新版本入口、URL 探测值、README 示例和 `src/checksums.sha256`；两个归档的
  SHA-256 与下载文件一致。

## 当前实测结果

- LNMP 主安装完成，Nginx、PHP-FPM、MySQL 均启动；PHP 8.3.33 的 WordPress 常用扩展
  `mysqli`、`pdo_mysql`、`curl`、`mbstring`、`gd`、`zip`、`intl`、`xml`、`redis`、
  `imagick` 均已加载。
- MySQL 8.4 客户端因缺少 `libncurses.so.5`、`libtinfo.so.5` 无法启动，且初始化命令
  失败没有中止安装，已分别记录为 `AUDIT-DB-001`、`AUDIT-DB-002`。
- 验证机补装 Debian 12 的 `libncurses5`、`libtinfo5` 后，MySQL 客户端和 root 登录恢复；
  数据库无匿名账号与 test 库，InnoDB 正常，3306 与 33060 只监听回环地址。
- phpMyAdmin 5.2.1 登录页返回 200，程序位于网站根目录外，通过随机路径映射访问。
- Redis 8.8.0 安装成功并设为自启，只监听回环地址；`PING`、PHP 连接及写读删除均通过。
- `lnmp vhost add/list` 已创建 WordPress 伪静态站点，`nginx -t` 通过；
  `lnmp database add/list` 已创建并列出测试库。
- 官方 WordPress 7.0.3 已完成安装，数据库表创建成功；首页、登录页与固定链接页面均返回
  200，固定链接页面正文匹配，响应头不含 `X-Powered-By`。
- `lnmp status`、`lnmp nginx reload` 均正常；`lnmp restart` 返回 0 且业务请求成功，
  但 Nginx 与 PHP-FPM 的 systemd 状态变为 `failed`，记录为 `AUDIT-OPS-001`。
- 整机重启后 Nginx、PHP-FPM、MySQL、Redis 均为 `enabled`、`active`，WordPress、
  phpMyAdmin、MySQL 查询和 Redis PING 均恢复，确认开机自启动正常。
- `lnmp database del` 成功删除测试库及同名用户，复核计数均为 0。
- `lnmp vhost del` 删除了配置文件与列表项，但未 reload Nginx，站点仍继续提供服务；
  手工执行 `lnmp nginx reload` 后才下线，记录为 `AUDIT-OPS-002`。
- 本地干净副本的 `bash -n`、`t/lint.sh`、`t/consistency.sh`、`t/test_profile.sh`、
  `t/test_dispatch.sh`、`t/test_bump.sh` 均通过。

## 审计整改（2026-08-10）

### AUDIT-DB-001 Debian 缺 ncurses 5 运行库，MySQL 客户端起不来

- **文件**：`include/init.sh`（新增 `Deb_Ncurses5_Compat`）、`include/only.sh`
- **问题**：MySQL 8.4 官方通用二进制里的 `mysql` 客户端链接的是
  `libncurses.so.5` / `libtinfo.so.5`，而依赖清单只装了 `libncurses-dev`、
  `libncurses5-dev`、`libtinfo-dev` —— 都是头文件包，运行库是 `.so.6`。
  客户端在动态链接阶段就退出，连带初始化 SQL 和装完之后的
  `lnmp database add/list/del` 全部不可用。
- **做法**：新增 `Deb_Ncurses5_Compat`，先装 Debian 12 仓库里的
  `libncurses5`、`libtinfo5`；Debian 13 已移除这两个包，此时从 `ldconfig -p`
  取 `.so.6` 的实际路径，软链成 `.so.5` 再 `ldconfig`。
  `Deb_Dependent`（`install.sh lnmp` 路径）与 `DB_Dependent`（`install.sh db` 路径）
  各调用一次。
- **行为变化**：Debian/Ubuntu 上多装两个小包；取不到包时自动退回软链。
- **验证状态**：已实测（Debian 12 定向复验通过）。

### AUDIT-DB-002 数据库初始化失败没有传递到安装结果

- **文件**：`include/dbcommon.sh`（新增 `DB_Init_Failed` / `DB_Init_Step` /
  `Check_DB_Client_Runnable`）、`include/mysql.sh`、`include/mariadb.sh`、
  `include/end.sh`（新增 `Check_DB_Init_Result`）、`include/only.sh`
- **问题**：初始化 SQL（设 root 密码、清匿名账号、禁远程 root、删 test 库、
  刷权限）每条只打印 `Success` / `Failed!`，不影响任何返回值。客户端整体不可用时
  六条全失败，安装照样输出 `Install lnmp V2.3 completed`，退出码 0，
  最终检查还显示 `MySQL: OK` —— 因为 `Check_DB_Files` 只看二进制和
  `/etc/my.cnf` 在不在。本次实跑恰好没有匿名账号与 test 库，
  那是初始化后的天然状态，不代表处理正确。
- **做法**：
  1. `Check_DB_Client_Runnable` 在初始化前先跑一次 `mysql --version`，
     把动态链接的原始报错打在最前面，免得被后面五条 `Failed!` 淹没；
  2. 五条初始化 SQL 改走 `DB_Init_Step`，任一条失败即置 `DB_Init_Failed='y'`
     并记下步骤名；root 密码两条路径都失败时同样置位；
  3. `end.sh` 新增 `Check_DB_Init_Result`，与既有的 `Check_Firewall_Result`
     同一模式：组件仍然可用，但退出码为 1，并列出失败步骤和手工核对命令。
     三个 `Check_*_Install` 都调用，且两项检查互不短路；
  4. `only.sh` 的 `Install_Database` 同步返回非零。
- **行为变化**：初始化失败时 `install.sh` 退出码由 0 变为 1。
- **验证状态**：已实测（故障注入与最终检查返回码均通过）。

### AUDIT-OPS-001 `lnmp` 命令绕开 systemd，unit 状态失真

- **文件**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp`（新增 `Svc` / `Check_Svc_State`）、
  `init.d/nginx.service`、`init.d/php-fpm.service`、`include/end.sh`、
  `include/only.sh`、`include/upgrade_mysql2mariadb.sh`
- **问题**：装机时服务由 `StartOrStop` 经 `systemctl` 拉起，
  但 `/bin/lnmp` 一律直调 `/etc/init.d/<服务>`。执行过一次 `lnmp restart` 之后，
  新进程跑在 systemd 之外，unit 立刻变成 `failed`：
  `lnmp restart` 返回 0、网站正常，`systemctl is-active nginx php-fpm` 却都是
  `failed`。此后 `systemctl stop/restart`、故障恢复和一切基于 unit 状态的监控
  全部失真。Redis 插件安装时调用 PHP-FPM restart 也会造成同样结果。
- **做法**：
  1. 三个管理脚本各新增 `Svc <服务> <动作>`：有 systemd（`/run/systemd/system`
     存在）且本包装过对应 unit 时走 `systemctl`，否则退回 SysV 脚本；
     `configtest` / `force-quit` / `kill` 这些 systemd 里没有的动作始终走 SysV；
  2. 新增 `Check_Svc_State`，`start` / `restart` 结束后核对 unit 状态，
     对不上就明确提示（而不是留到下次故障恢复才发现）；
  3. 数据库服务名收敛成脚本顶部的 `DB_SERVICE` 一行，
     `end.sh` 的 `Startup_DB` 与 `upgrade_mysql2mariadb.sh` 改为只改那一行；
     `install.sh nginx` 路径把它置空，`Svc` 遇到空服务名直接跳过；
  4. `nginx.service` 的 `ExecStop` 从 `kill -s QUIT $MAINPID` 改为
     `nginx -s quit` —— 前者在 `$MAINPID` 为空时直接返回 1 把 unit 打成 failed，
     后者从 pid 文件读主进程号，谁拉起来的都能正常停掉；
  5. `php-fpm.service` 从 `Type=simple` + `--nodaemonize` 改为
     `Type=forking` + `PIDFile`：`php-fpm.conf` 里配了 pid 文件，
     SysV 脚本和 `lnmp status` 都以它为准，`--nodaemonize` 时 php-fpm 不写该文件，
     systemd 与另外两处对「是否在跑」的判断会分叉。
- **行为变化**：`lnmp start/stop/restart/reload/status` 与
  `lnmp {nginx|mysql|mariadb|php-fpm|pureftpd|httpd} <动作>` 优先走 systemctl。
  多版本 PHP 的 `php-fpm8.x` 没有 unit，仍走 SysV 脚本。
- **验证状态**：已实测（Debian 12 定向复验通过）。

### AUDIT-OPS-002 `lnmp vhost del` 删完不 reload，站点仍在线

- **文件**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp`、`init.d/init.d.httpd`
- **问题**：`vhost del` 删掉 vhost 配置文件、列表里也没有了、命令提示"已删除"，
  但运行中的 Nginx 用的是已加载的配置，站点继续对外提供服务。
  手工 `lnmp nginx reload` 之后才真正下线。`vhost add` 有 `nginx -t` + reload，
  `del` 这一侧从来没有。
- **做法**：三个脚本的 `Del_VHost` 在删除后调用新增的 `Del_VHost_Reload*`：
  先 `nginx -t` / `httpd -t`，通过才 reload；任一步失败即返回非零并说清楚
  「配置文件已删除，但线上仍在提供该站点」以及该执行哪条命令。
  服务本来就没在跑时跳过重载，不报错。
- **附带修复**：`init.d/init.d.httpd` 的 `configtest` 分支只打印 ` failed`
  却返回 0，导致 `conf/lnmpa`、`conf/lamp` 里
  `if ! /etc/init.d/httpd configtest` 的回滚判断从来没生效过，现补上 `exit 1`。
- **行为变化**：`vhost del` 会重载 Web 服务；重载失败时退出码为 1。
- **验证状态**：已实测（Debian 12 定向复验通过）。

### AUDIT-DB-003 MySQL 8.4 配置含弃用项

- **文件**：`include/mysql.sh`（新增 `MySQL_Deprecated_Opt`）、`include/upgrade_mysql.sh`
- **问题**：MySQL 8.4.7 启动日志对 `binlog_format`、`innodb_log_file_size`、
  `innodb_log_files_in_group` 报弃用警告。
- **做法**：新增 `MySQL_Deprecated_Opt`，在 `MySQL_Opt` 之后执行
  （先按内存分档算出 `innodb_log_file_size`，再换算）：
  `innodb_log_file_size` 改写为 `innodb_redo_log_capacity`，
  取值为原值 ×2（旧配置默认 2 个日志文件，总量等价）；
  删除 `innodb_log_files_in_group` 与 `binlog_format`（8.4 只剩 `ROW` 一种取值，
  正是默认值）。函数内部按版本自守：低于 8.4 直接返回，8.0 的配置不动。
  升级路径以用户输入的 `mysql_version` 为准，而不是 `lnmp.conf` 里的 `DBSelect`。
- **行为变化**：8.4 及以上的 `/etc/my.cnf` 不再出现这三项。
- **验证状态**：已实测（临时转换、配置校验与恢复均通过）。

### AUDIT-APA-001 Debian 清理阶段处理不存在的旧包

- **文件**：`include/init.sh`（新增 `Deb_Purge_Installed`，重写 `Deb_RemoveAMP`）、
  `include/only.sh`
- **问题**：清理阶段无条件对一长串包名执行 `apt-get purge` 与 `dpkg -P`，
  其中 `apache2.2-*`、`php5*`、`mysql-*-5.5`、`libmysqlclient15*` 在
  Debian 10+ / Ubuntu 18.04+ 上根本不存在（系统下限见 `Check_Supported_Distro`）。
  全新系统因此刷出十几条包管理报错，真出问题的那条反而看不出来。
- **做法**：新增 `Deb_Purge_Installed`，用 `dpkg-query -W -f='${Status}'`
  过滤出确实装着的包再一次性 purge；包名清单收敛到受支持发行版里可能存在的那些。
  `killall apache2` 改为 `pkill -x apache2` 并静默。
  `/etc/mysql` 不再直接删除 —— `mysql.sh` / `mariadb.sh` 本来就会改名备份，
  这里只提示。
- **行为变化**：清理阶段输出变干净；不再对不存在的包报错。
- **验证状态**：已实测（函数级模拟通过，未扩展测试 Apache）。

### 本阶段验证结果

- `bash -n`：全部 shell 文件、`conf/lnmp`、`conf/lnmpa`、`conf/lamp` 均通过。
- `t/lint.sh` 全部通过（C1–C14 + T1）。
- `t/consistency.sh` 通过 7 项，失败 0 项。
- `t/test_profile.sh`、`t/test_dispatch.sh`、`t/test_bump.sh` 全部通过。
- `MySQL_Deprecated_Opt` 的换算逻辑用样例 `my.cnf` 单独验证：
  `innodb_log_file_size = 128M` → `innodb_redo_log_capacity = 256M`，
  `binlog_format`、`innodb_log_files_in_group` 被删除。
- Debian 12 定向复验已完成，结果见下节。

### Debian 12 定向复验（2026-08-10）

本次只复验上述六项修复，没有重跑 WordPress 完整安装，也没有扩展测试 Apache。

- `AUDIT-DB-001`：`Deb_Ncurses5_Compat` 返回 0；Debian 12 已正确识别
  `libncurses5`、`libtinfo5`；MySQL 8.4.7 客户端可执行，`ldd` 无 `not found`。
- `AUDIT-DB-002`：注入 SQL 执行失败后，`DB_Init_Step` 返回 1 并设置
  `DB_Init_Failed=y`；`Check_DB_Init_Result` 与最终 `Check_LNMP_Install` 均返回 1，
  失败步骤被列出。
- `AUDIT-OPS-001`：`lnmp restart` 返回 0，随后 Nginx、PHP-FPM、MySQL 的
  systemd 状态均为 `active`；`lnmp php-fpm restart` 后 PHP-FPM 仍为
  `active (running)`；本机 HTTP 返回 200。
- `AUDIT-OPS-002`：创建 `fix-audit.test` 并写入唯一标识后执行
  `lnmp vhost del`，命令返回 0；配置文件已删除，`nginx -t` 通过且自动 reload，
  删除后请求不再返回测试标识。
- `AUDIT-DB-003`：在备份保护下转换验证机的 MySQL 8.4 配置，
  `innodb_log_file_size = 128M` 转为 `innodb_redo_log_capacity = 256M`，
  弃用项全部消失，`mysqld --validate-config` 返回 0；测试后原配置校验值一致。
- `AUDIT-APA-001`：用“已安装包 + 不存在的 Apache 2.2/PHP 5 包名”模拟清理，
  purge 只收到已安装包，不存在的旧包名已被过滤；未执行 Apache 安装测试。
- 回归检查：`bash -n`、`t/lint.sh`、`t/consistency.sh`、
  `t/test_profile.sh`、`t/test_dispatch.sh` 全部通过。
- 最终复核：Nginx、PHP-FPM、MySQL、Redis 均为 `active`，Nginx 配置正常，
  MySQL 客户端依赖完整，本机 HTTP 返回 200，测试 vhost 与站点目录已清理。

# 阶段 16 — 历史验证状态收尾（2026-08-11）

## AUDIT-VERIFY-001 历史验证状态与后续证据对账

本阶段只整理验证记录，不改代码。逐条对照阶段 8 至阶段 15 的 Debian 12 实跑、
WordPress 主线验收、专项故障注入和静态检查，历史状态按以下口径收口：

- 已有后续证据的条目改为“已验证”，并在原条目注明阶段与 ID；静态专项检查明确
  标为静态，不写成真机实跑。
- Debian 12 主线已经覆盖完整安装、Nginx、PHP 8.3、MySQL 8.4 官方二进制、
  phpMyAdmin 5.2.1、Redis 8.8.0、WordPress、建站建库及常用运维命令。
- 阶段 12 中“从未执行完整安装”和历史未完成表已经按阶段 14、15 的结果关闭。

仍需普通收尾验证：`FIX-DB-001`、`FIX-DB-002`、`FIX-CONF-001`、`REPO-001`、
`FIX-UNINST-001`、`VERIFY-001`、`TXN-001`、`OR-001` source 路径、`DEB13-001`、
`FIX-UNINST-002`、`SEC-PMA-001`、`CONF-003`、`CONF-005`、`CONF-008`、`SEC2-006`。
这些分别涉及非主线源码编译、EL/Debian 13、升级/卸载、LNMPA/Apache、Pure-FTPd
或独立数据库安装，原条目均已改为“待收尾验证”。

待人工真机验证：`SEC-TOOL-001`、`SSL-IP-001` 的真实证书签发、`SEC2-009`。
这三项需要真实数据库 root 凭据、公网签发条件，或 SFTP 服务器、SSH 私钥与主机指纹，
不应在普通自动化验证中代填凭据或模拟为已完成。

- **验证状态**：已验证；历史状态逐条复核完成，未完成项已集中列明（2026-08-11）。

# 阶段 17 — database 子命令补全、退出码与凭据清理（2026-08-10）

本阶段只涉及三个管理脚本 `conf/lnmp`、`conf/lnmpa`、`conf/lamp` 的
`database` 子命令及其共用的临时文件与凭据处理，未改动安装、升级流程。

## FIX-DB-010 临时目录在命令替换的子 shell 中初始化，database 子命令整体不可用

**位置**：三个管理脚本的 `LNMP_Mktemp`，以及 `Do_Query`、`Add_Database`、
`Del_Database`、`Add_Ftp`、`Edit_Ftp` 五个调用点

`LNMP_Mktemp` 把临时目录的创建和 `trap ... EXIT INT TERM` 的注册放在函数内部，
而它的返回值必须通过 `$(LNMP_Mktemp ...)` 取回 —— 命令替换是子 shell：

- 子 shell 里给 `LNMP_Tmp_Dir` 赋的值传不回父 shell，父 shell 该变量恒为空，
  退出时的清理实际是 `rm -rf ""`，临时目录从未被删除；
- 子 shell 退出时触发自己注册的 EXIT trap，把刚创建的目录连同里面的文件一起删掉，
  函数返回的路径指向一个已经不存在的文件。

后果是 `cat > "${sql_file}"` 和 `mysql < "${sql_file}"` 双双失败：
`Do_Query` 永远返回非 0，`Verify_DB_Password` 把正确的 root 密码也判为错误并继续
循环追问，`database add` / `del` 无法执行；`Add_Ftp`、`Edit_Ftp` 写不进 pure-pw
的密码文件，同样失效。

**改动**：拆成两个函数。`LNMP_Tmp_Init` 负责创建目录并注册 trap，必须由调用方
在当前 shell 执行；`LNMP_Mktemp` 只在已初始化的目录里创建文件，可安全用于命令替换。
五个调用点前各增加一行 `LNMP_Tmp_Init`。

初始化失败的处理按调用点区分：`Add_Database`、`Del_Database` 用 `return 1`，
让退出码逐层传出；`Do_Query` 用 `exit 1`，因为 `Verify_DB_Password` 把 `Do_Query`
的任何非 0 返回都当成密码错误并继续重试，在这里返回非 0 会让建不出临时目录的
环境问题变成一个永不结束的密码追问循环。

**行为变化**：`database` 与 `ftp` 子命令由不可用恢复为可用；临时目录在退出时确实被删除。

## FIX-DB-011 中途退出的分支不清理数据库 root 凭据

**位置**：三个管理脚本的 `Make_TempMycnf`、`TempMycnf_Clean`，新增 `LNMP_Cleanup`、
`LNMP_Set_Trap`；`Add_VHost` 建库路径

`~/.my.cnf` 里是数据库 root 明文密码，原先只在主分派 `database)` 的末尾调用一次
`TempMycnf_Clean`。以下路径都绕过了这次清理：

- `vhost add` 选择“同时建库”时调用 `Verify_DB_Password`，整条流程从头到尾没有清理，
  凭据文件长期留在磁盘上，管理员原有的 `~/.my.cnf` 也一直停在 `.lnmp-bak` 备份里；
- 参数非法、系统库拒删、密码为空、读输入遇 EOF 等 `exit` 分支；
- Ctrl+C 中断。

**改动**：`Make_TempMycnf` 写入凭据后置位 `LNMP_Mycnf_Owned` 并注册统一的 EXIT trap，
临时目录和凭据由 `LNMP_Cleanup` 一并清理。`TempMycnf_Clean` 改为只清理本次执行自己
写入的凭据，可重复调用，不再误删管理员原有的 `~/.my.cnf`。`vhost add` 的建库步骤
结束后立即显式清理一次，不等到进程退出。

INT/TERM 的处理同时改为显式 `exit 130`：原先 trap 执行完脚本会继续往下跑，
`Del_Database` 提示的 “Press ctrl+c to cancel” 倒计时实际取消不掉删除动作。

**行为变化**：任何退出路径都不再残留 `~/.my.cnf`；Ctrl+C 可以真正取消删库倒计时。

## FIX-DB-012 database 子命令的返回码不反映实际结果

**位置**：三个管理脚本的 `Function_Database`、`Add_Database_Menu`、`Add_Database`、
`List_Database`、`Edit_Database`、`Del_Database`，以及主分派的 `database)` 分支

原实现统一使用 `[ $? -eq 0 ] && echo 成功 || echo 失败`，函数返回码取自最后那个
`echo`，恒为 0；主分派末尾的 `exit` 不带参数，取的是 `TempMycnf_Clean` 的结果。
外部自动化无法判断 `lnmp database add` 是否真的成功。

`Edit_Database` 另有一处判断错位：三条 SQL 分三次调用 `Do_Query`，只检查了中间那次，
第一条和 `FLUSH PRIVILEGES` 失败都会被报成成功。

**改动**：五个操作函数改为保存实际返回码、失败时红字提示并返回该码；
`Edit_Database` 的三条语句合并为一次执行（mysql 客户端默认遇错即停）；
`Function_Database` 的默认分支与 `exit` 分支改为 `return 1`；
主分派保存 `Function_Database` 的返回码，清理凭据后 `exit` 该码。
`Add_Database_Menu` 密码为空时由 `exit 1` 改为 `return 1`，
`vhost add` 的调用点补 `|| exit 1`，建库失败时站点摘要明确提示建库未完成。
站点摘要读取建库结果时写作 `${database_add_rc:-1}`：该变量只在选择了建库的分支里
赋值，不给默认值的话，一旦有路径绕过赋值，`[ "" -eq 0 ]` 会报
“integer expression expected”，把判断结果变成不确定。

**行为变化**：`lnmp database {add|list|edit|del|export|import}` 成功返回 0、
失败返回非 0；失败提示改为红字，文案不变。

## FEAT-DB-001 新增 database export / import

**位置**：三个管理脚本新增 `Check_Dump_Bin`、`Database_Exists`、`Check_Backup_Path`、
`Export_Database`、`Import_Database`，`Function_Database` 增加两个分支，
主分派增加 `arg3`、`arg4`

```
lnmp database export <数据库名> <文件.sql.gz>
lnmp database import <数据库名> <文件.sql.gz>
```

实现要点：

- 导出使用与 mysql 客户端同目录的 `mysqldump`，参数为
  `--single-transaction --quick --routines --triggers --events
  --default-character-set=utf8mb4`，不使用 `--databases`，
  产物不含 `CREATE DATABASE` / `USE`。目标库完全由命令行参数决定，
  备份文件里记录的库名不会反过来覆盖用户指定的库，同一份备份可恢复到另一个库名。
- 导出先在目标目录用 `mktemp` 建临时文件，成功后 `mv` 改名；
  `mysqldump` 或 `gzip` 任一失败（按 `PIPESTATUS` 判定）即删除临时文件并返回非 0，
  不会留下半截备份。目标文件已存在时直接报错，不覆盖。
- 库名沿用 `Check_DB_Identifier` 白名单；备份路径检查父目录存在、
  不以 `/` 结尾、目标不是目录或其它非普通文件。
- 库是否存在用 `information_schema.SCHEMATA` 精确比较，
  不用 `SHOW DATABASES LIKE`（`LIKE` 会把库名中的下划线当作通配符）。
- 导入按文件内容而非扩展名判断是否为 gzip，未压缩的 `.sql` 也能导入；
  目标库必须已存在，不自动建库（建库还需建用户和授权，属于 `database add` 的职责）；
  执行前有 10 秒倒计时，可 Ctrl+C 取消。

**行为变化**：新增两个子命令；`Function_Database` 内部帮助此前只列
`add|list|del`，遗漏了已实现的 `edit`，现补齐并列出 export / import，
与脚本底部的帮助一致。

**文档**：`README.md` 的“数据库管理”与 `HowtoGuides.md` 的 8.3 节同步补上这两条
命令，并写明不覆盖已有文件、目标库须先存在、导入有 10 秒可取消倒计时、
全部 `database` 子命令成功返回 0 失败返回非 0。

## 本阶段验证结果

- `bash -n`：`conf/lnmp`、`conf/lnmpa`、`conf/lamp` 均通过。
- `t/lint.sh` 全部通过（C1–C14 + T1）；`t/consistency.sh` 通过 7 项，失败 0 项。
- 函数级定向测试（stub 顶替 mysql / mysqldump，不依赖真实数据库）：
  三个脚本各 54 项全部通过，覆盖内部帮助内容、六个子命令的成功与失败返回码、
  非法库名、系统库拒删、备份路径校验、目标已存在不覆盖、
  `mysqldump` 失败不留产物与临时文件、gzip 与明文两种导入、
  凭据清理的幂等性与 EXIT trap 清理，以及 FIX-DB-010 的回归断言
  （`LNMP_Mktemp` 返回的文件在命令替换结束后仍存在且可写）。
- 端到端测试（副本中仅顶替 root 检查与 `Check_DB` 的二进制探测，
  其余走真实命令行入口）：三个脚本各 17 项全部通过，覆盖
  `database` 无子命令 / 未知子命令的退出码与帮助内容、`list` 成功与失败、
  `export` 缺参数 / 成功 / 不覆盖已有文件、`import` 成功 / 文件不存在 / 库不存在，
  以及退出后 `~/.my.cnf`、`.lnmp-bak` 与 `/tmp/.lnmp-adm.*` 均无残留、
  管理员原有 `~/.my.cnf` 被还原。
- **验证状态**：已验证（静态与 stub 环境）。未在 Debian 12 上对真实
  MySQL 8.4 执行导出导入，真机复验待收尾。
- 本阶段发现但未处理的问题已记入 `todo.md`：
  `TODO-DB-001` 至 `TODO-DB-004`、`TODO-FTP-001`。

# 阶段 18 — 数据库凭据交互与删库语义（2026-08-10）

处理阶段 17 记录在 `todo.md` 的 `TODO-DB-001` 至 `TODO-DB-004`，
范围仍限于三个管理脚本的 `database` 路径。`TODO-FTP-001` 按计划留待 FTP 大修，
未在本阶段改动。

## FIX-DB-013 数据库 root 密码校验会无限重试，非交互执行时空转刷屏

**位置**：三个管理脚本的 `Verify_DB_Password`，以及主分派 `database)` 分支和
`Add_VHost` 的建库路径；`conf/lnmpa`、`conf/lamp` 新增 `Read_Input`、`Read_Secret`

`Verify_DB_Password` 原本是 `status=1; while [ $status -eq 1 ]` 的无上限循环，
只要 `Do_Query` 返回非 0 就继续追问密码：

- 交互执行时密码输错只能 Ctrl+C 退出，没有正常出口；
- 非交互执行（管道、重定向）时输入耗尽后 `read` 立即返回，循环变成空转刷屏。
  `conf/lnmp` 已有带 EOF 检测的 `Read_Secret`，`conf/lnmpa`、`conf/lamp` 仍用裸
  `read -s`，是这条路径上最容易踩到的组合。

同一问题还出现在 `Add_Database_Menu` 与 `Edit_Database` 的密码输入循环里，
三个脚本都用的是裸 `read -r -s`。

**改动**：`Verify_DB_Password` 改为最多重试 3 次，每次失败打印第几次，
超限后返回 1；`conf/lnmpa`、`conf/lamp` 补上 `Read_Input`、`Read_Secret`
（与 `conf/lnmp` 同一份实现），`database` 路径上的裸 `read` 全部替换为这两个函数。
主分派与 `Add_VHost` 的调用点改为 `Verify_DB_Password || exit 1`，
校验失败不再继续往下执行。FTP 路径的 `read` 本次未动。

**行为变化**：密码连错 3 次返回非 0 并退出，不再无限追问；
非交互执行遇到输入耗尽时明确报 EOF 并退出，不再空转。

## FIX-DB-014 含反斜杠的数据库密码写入 option file 后被解析成别的字符

**位置**：三个管理脚本的 `Make_TempMycnf`

`~/.my.cnf` 里写的是 `password='$1'`，密码原样代入。MySQL 解析 option file 时，
引号包裹的值内部会把反斜杠当转义符（`\n`、`\t`、`\s` 等），
密码 `pa\nss` 被解析成中间带换行的字符串，表现为“密码明明是对的却认证失败”，
而且因为 `Verify_DB_Password` 此前会无限重试，用户看到的是反复追问密码。

单引号不需要处理：解析时只按首尾配对剥引号，值中间的单引号原样保留。

**改动**：写入前把值里的反斜杠加倍（`pw="${1//\/\\}"`），再代入 heredoc。
SQL 语句一侧的 `Sql_Quote` 不受影响，两者各管各的转义场景。

**验证**：密码 `pa\nss` 写出 `password='pa\nss'`，MySQL 解析回 `pa\nss`；
密码 `pa'ss` 仍原样写入。

## FIX-DB-015 删库时同名用户已不存在会导致整批语句失败

**位置**：三个管理脚本的 `Del_Database`

删除脚本按 `DROP USER` → `DROP USER` → `DROP DATABASE` → `FLUSH PRIVILEGES`
顺序下发，`DROP USER` 未加 `IF EXISTS`。同名用户此前被手工删掉时，
第一条语句即报错，mysql 客户端默认遇错停止，后面的 `DROP DATABASE` 不再执行 ——
库删不掉，而阶段 17 之前的返回码还是 0，失败完全看不出来。

库名敲错时同样只能等 10 秒倒计时走完、执行到 SQL 才报错。

**改动**：两条 `DROP USER` 改为 `DROP USER IF EXISTS`
（MySQL 5.7+、MariaDB 10.1.3+ 支持，本项目最低为 MySQL 8.0 / MariaDB 10.11）;
`DROP DATABASE` 保持不加 `IF EXISTS`，因为删除前已确认库存在。
`Check_DB_Identifier` 与新增的 `Database_Exists` 检查一并提到倒计时之前：
库不存在直接报错返回 1，把“库名敲错”和“删除失败”区分开，也不用等完倒计时。

**行为变化**：同名用户缺失时删库继续完成并返回 0；
库不存在时立即返回 1，不再进入 10 秒倒计时。

## CLN-401 明确临时文件与凭据的 trap 注册约束

**位置**：三个管理脚本 `LNMP_Set_Trap` 上方的注释

`Make_TempMycnf` 和 `LNMP_Tmp_Init` 会注册 EXIT trap。若在 `$(...)` 或管道右侧
调用它们，子 shell 继承 `LNMP_Tmp_Dir` 的值却在自己退出时执行该 trap，
会把主 shell 还在使用的临时目录和 `~/.my.cnf` 一并删掉。
当前所有调用点都在主 shell，行为正确；此处补注释固定该约束，供后续改动参考
（`todo.md` 的 `TODO-FTP-001` 已引用）。

**行为变化**：无，仅注释。

## 本阶段验证结果

- `bash -n`：三个管理脚本均通过；`t/lint.sh` 全部通过；
  `t/consistency.sh` 通过 7 项，失败 0 项。
- 函数级定向测试三个脚本各 66 项全部通过（较阶段 17 增加 12 项）：
  密码正确返回 0、连续失败恰好重试 3 次后返回 1、
  `Verify_DB_Password` / `Add_Database_Menu` / `Edit_Database` 在输入耗尽时
  明确退出而不空转（用超时判定，撞上空转即判失败）、
  含反斜杠与含单引号的密码写入 option file 的实际内容、
  库不存在时删库返回 1、库存在时返回 0 且下发的 SQL 含 `DROP USER IF EXISTS`
  与 `DROP DATABASE`。
- 端到端测试三个脚本各 17 项全部通过。阶段 17 中 `conf/lnmpa`、`conf/lamp`
  因无限重试而只能靠超时判定的 G5，现已返回 1，与 `conf/lnmp` 一致。
- **验证状态**：已验证（静态与 stub 环境）。含反斜杠密码的认证结果依赖 MySQL
  自身的 option file 解析，未在真实 MySQL 8.4 上复验，真机复验待收尾。
- `todo.md` 中 `TODO-DB-001` 至 `TODO-DB-004` 已关闭并删除，
  仅保留 `TODO-FTP-001`。

# 阶段 19 — FTP 子命令大修与备份功能化（2026-08-10）

本阶段处理两件事：`todo.md` 里挂着的 `TODO-FTP-001`，以及把
`tools/backup.sh` 这个手工模板做成正式运维命令 `lnmp backup`。

## FIX-FTP-001 FTP 子命令的返回码、帮助与失败文案

**位置**：三个管理脚本的 `Function_Ftp`、`Add_Ftp_Menu`、`Add_Ftp`、`List_Ftp`、
`Edit_Ftp`、`Del_Ftp`、`Show_Ftp`，主分派 `ftp)` 分支，`Add_VHost` 的建账号路径

与阶段 17 的 `database` 同类问题：五个操作函数都是
`[ $? -eq 0 ] && echo 成功 || echo 失败`，返回码取自最后那个 `echo`，恒为 0；
`Function_Ftp` 的默认分支用 `exit 1`，内部帮助只列 `add|list|del`，
漏掉已实现的 `edit` 和 `show`。

失败文案还会误导排查方向：`Add_Ftp` 把所有失败一律说成
“FTP User: xxx already exists!”，`Del_Ftp` 一律说成 “not exists!”，
而实际可能是密码库不可写、`www` 账号缺失或参数不合法。
`www` 缺失时 `id -u www` 输出为空，`pure-pw` 会收到空的 `-u`/`-g` 参数并报一个
与真实原因对不上的用法错误。

**改动**：五个函数保存并返回真实退出码，失败时红字给出 pure-pw 的返回码和
常见原因；`Edit_Ftp` 的改密码与改目录各自判定，任一失败整体返回非 0；
`Function_Ftp` 帮助补齐 `edit|show`、默认分支改 `return 1`；
主分派传出真实退出码；`Add_Ftp`、`Edit_Ftp` 显式检查 `www` 账号是否存在，
`mkdir` 失败也不再被忽略；账号名统一加引号传给 `pure-pw`。
`Add_VHost` 记录建账号结果，失败时在站点摘要里如实说明并提示可单独重试。

`Add_Ftp_Menu` 的密码输入原先明文回显，且与 `Enter_Ftp_Name`、`Edit_Ftp`
一样用裸 `read`（输入耗尽时空转刷屏）。现统一改用带 EOF 检测的
`Read_Secret`/`Read_Input`，密码不再回显，与数据库那边的行为一致。

**行为变化**：`lnmp ftp {add|list|edit|del|show}` 成功返回 0、失败返回非 0；
新增 FTP 账号时密码输入不回显。

## FIX-PIPE-001 PIPESTATUS 取第二个下标永远取不到管道右侧的退出码

**位置**：三个管理脚本的 `Export_Database`、`Import_Database`，
`tools/lnmp-backup.sh` 的 `Dump_Db`、`Tar_Dir`

```bash
dump_rc=${PIPESTATUS[0]}
gzip_rc=${PIPESTATUS[1]}     # 恒为空
```

第一条赋值语句本身就会把 `PIPESTATUS` 重置成那条赋值的状态（单元素数组），
第二行取到的不是管道右侧的退出码。`set -u` 下直接报 unbound variable；
没开 `set -u` 的管理脚本里则展开成空字符串，
`[ "" -ne 0 ]` 报 “integer expression expected” 并判定为假 ——
gzip 写盘失败被完全忽略，磁盘写满时导出会“成功”。

阶段 17 新增 `database export` 时就带进了这个写法，当时的测试只覆盖了
`mysqldump` 一侧的失败，没有发现。

**改动**：四处统一改为先快照整个数组再取下标：

```bash
pipe_st=("${PIPESTATUS[@]}")
dump_rc=${pipe_st[0]}
gzip_rc=${pipe_st[1]}
```

只取 `${PIPESTATUS[0]}` 且是管道后首次引用的地方（`include/multiplephp.sh`、
`install.sh`、`upgrade.sh` 等）不受影响，未改动。

**行为变化**：`database export`、`database import` 与备份中 gzip 一侧的失败
现在能被真实发现并反映到退出码。

## FEAT-BACKUP-001 备份从手工模板改为正式运维命令 lnmp backup

**位置**：新增 `tools/lnmp-backup.sh`（安装为 `/bin/lnmp-backup`）；
三个管理脚本新增 `Function_Backup` 与 `backup)` 分支；
`include/end.sh` 新增 `Install_LNMP_Command`；`include/only.sh`、`pureftpd.sh`、
`uninstall.sh` 同步；`tools/backup.sh` 改为废弃转发

原 `tools/backup.sh` 是一个需要手工编辑数组、手工加 cron 的模板，
安装流程既不配置它也不调度它，且存在以下问题（逐条对应本次的处理）：

| 原问题 | 现在的做法 |
| --- | --- |
| 只取 `mysqldump` 的退出码，gzip 与写盘失败被忽略 | 快照整个 `PIPESTATUS`，两侧都检查；另外校验 mysqldump 的 `-- Dump completed` 结束标记，退出码为 0 但被截断的转储也会判失败 |
| 产物直接写最终文件名 | 先写 `.part`，全部检查通过后才 `mv` 改名 |
| `Keep_Days=3` 只删“正好三天前”那一天 | 批次名按 `YYYYmmdd-HHMMSS` 与截止日期数值比较，删除所有早于保留期的批次 |
| 保留期只有一个，README 还写成“保留份数” | 库与网站各自的 `Keep_Days_Db`、`Keep_Days_Web`，并用 `Web_Interval_Days` 让网站按更长周期备份 |
| 同一天重复执行会覆盖 | 批次目录用秒级时间戳 |
| 没有并发锁 | `flock`；没有 flock 的环境退回 `mkdir` 原子锁，并按 PID 判断陈旧锁 |
| 远端先删旧备份再上传新的 | 上传 → 核对 → 改名 → 最后才清理旧批次；本次有失败项时完全跳过清理 |
| 上传直接用最终名，中断会留下残缺文件 | 先传到远端 `.incoming/<批次>-<类型>/`，核对通过后整目录 `rename` 到正式目录 |
| 没有校验清单，没有恢复验证 | 每个批次生成 `SHA256SUMS`；`restore` 前强制校验；新增 `test` 子命令做试恢复 |
| 配置靠手工维护数组，站点与库没有对应关系 | `/etc/lnmp/backup.conf`（600）按 `域名\|网站目录\|数据库名` 建立关联，`init` 扫描 vhost 并从 `wp-config.php` 读 `DB_NAME` 自动生成 |
| 不是自动功能 | `init` 生成 systemd service + timer 并启用；无 systemd 时退回 `/etc/cron.d/lnmp-backup` |

子命令：

```
lnmp backup init                 生成配置、备份目录与定时任务
lnmp backup run [db|web|all]     执行备份；不带参数按配置周期决定是否备份网站
lnmp backup status               上次结果、下次计划与配置概览
lnmp backup list [db|web]        列出本地与远端批次
lnmp backup restore db  <库名> [批次]
lnmp backup restore web <域名> [批次]
lnmp backup test                 试恢复：导入临时库校验后删除
```

其它实现要点：

- 备份实现是独立文件，三个管理脚本共用同一份，不各存一份副本；
  `Install_LNMP_Command` 把管理脚本与备份实现一起安装，避免只更新其中一个。
- 导出用 `--single-transaction --quick --routines --triggers --events`，
  不用 `--databases`，产物不含 `CREATE DATABASE`/`USE`，可恢复到别的库名。
- 删除批次前核对目标：必须落在 `${Backup_Home}/{db,www}` 下且名字是合法批次，
  不合格式的目录不删。
- 凭据不进命令行参数：数据库口令走 0600 的 option file（写入时对反斜杠做转义，
  同 `FIX-DB-014`），上传走专用 SSH 密钥 + 固定主机指纹，`StrictHostKeyChecking=yes`。
- 可选 age / gpg 加密，校验清单针对加密后的文件计算。

**已知边界**：受限的 `internal-sftp` 账号无法在远端执行校验命令，
所以远端只做逐文件大小核对（能发现截断与缺失），内容级 SHA-256 校验在本地清单上做。
这一点在 `HowtoGuides.md` 中明确写出，不表述为“远端已校验”。

## DOC-401 异地备份的配置步骤写入操作文档

**位置**：`HowtoGuides.md` 新增 8.5 节「异地备份（SFTP）」，原 8.5 日志顺延为 8.6；
8.4 与 `README.md` 的备份段落加上指向该节的链接

`lnmp backup` 的异地上传默认关闭，开启需要一台独立备份服务器并在两侧各配一次。
只写「把 `Enable_Remote_Backup` 改成 1」不足以让人配起来 —— chroot 目录的属主与
权限、`authorized_keys` 为什么放在 chroot 外、主机指纹要带外核对，
这些不写清楚第一次配一定会卡住。

新增小节按操作顺序分为：备份机建账号与目录（含 chroot 的属主/权限硬性要求）、
备份机限制该账号只能走 internal-sftp、生产机生成专用密钥与固定并核对主机指纹、
生产机开启上传并按 4 步顺序验证、出错时的现象-原因-处理对照表、
以及远端只做大小核对这一边界的说明。

**验证状态**：该节命令未在真机执行过，节首已明确标注，并指向
`todo.md` 的 `TODO-BK-001`。文档中不含伪造的执行回显。

## DEPR-001 tools/backup.sh 废弃

原文件改为一个转发脚本：检测到 `/bin/lnmp-backup` 就打印废弃提示并
`exec /bin/lnmp-backup run all`，否则报错并给出补装与 `init` 指引。
这样老的 cron 条目不会在升级后静默停止备份，也不必维护两套备份实现。
`README.md` 与 `HowtoGuides.md` 的备份章节同步改写。

## 本阶段验证结果

- `bash -n`：三个管理脚本、`tools/lnmp-backup.sh`、`tools/backup.sh`、
  `include/end.sh`、`include/only.sh`、`pureftpd.sh`、`uninstall.sh` 均通过。
- `t/lint.sh` 全部通过；`t/consistency.sh` 通过 7 项，失败 0 项。
- FTP 定向测试（stub 顶替 `pure-pw`，硬编码路径重写到临时目录）：
  三个脚本各 24 项全部通过。覆盖帮助补齐、六个入口的成功与失败返回码、
  失败文案不再一律说“已存在 / 不存在”、密码经 stdin 传入且不出现在命令行参数、
  临时密码文件不残留、缺少 `www` 账号时的提示、`Edit_Ftp` 两段独立判定、
  输入耗尽不空转。
- 备份定向测试（stub 顶替 mysqldump / mysql，远端用本地目录模拟 SFTP）：
  54 项全部通过。覆盖：秒级批次不覆盖、`SHA256SUMS` 生成与校验、
  mysqldump 失败 / 转储为空 / 转储缺少结束标记 / gzip 失败四种情况都返回非 0
  且不留 `.part`、保留算法删除所有早于保留期的批次而不是只删某一天、
  非批次格式目录不被误删、库与网站保留期各自独立、并发锁、
  上传成功后 `.incoming` 清空、上传失败与远端截断都不污染正式目录、
  上传失败时不清理旧批次、试恢复建临时库并在结束后删除、
  校验和被篡改时 `restore` 与 `test` 均拒绝、站点无库名时只备份文件、
  `Web_Interval_Days` 控制网站备份周期。
- 数据库与端到端测试回归：三个脚本各 66 项、17 项全部通过。
- **验证状态**：已验证（静态与 stub 环境）。以下未在 Debian 12 真机执行，
  待收尾验证：真实 `mysqldump`/`tar` 产物、真实 SFTP 服务器上的上传与改名、
  systemd timer 的实际触发、`init` 的交互流程、age/gpg 加密路径。
- `todo.md` 的 `TODO-FTP-001` 已关闭并删除；本阶段新增的待验证项记入 `todo.md`。

# 阶段 20 — OpenResty 自定义模块配置化与 Telegram 通知（2026-08-10）

## FEAT-OR-001 OpenResty 自定义编译模块与 Lua 库管理

**位置**：新增 `include/openresty_modules.sh`；`lnmp.conf` 新增配置块；
`include/openresty.sh`、`include/upgrade_openresty.sh`、`conf/openresty.conf`、
`install.sh`、`upgrade.sh` 同步

原先只有 `include/version.sh` 里一个 `OpenResty_Modules_Options` 变量，
是个裸的 `./configure` 参数入口。六个缺口逐条补齐：

| 原状况 | 现在 |
| --- | --- |
| 变量只在 `include/version.sh` 定义，`lnmp.conf` 里没有配置项和说明 | `lnmp.conf` 新增配置块，含格式说明与 GeoIP2 示例 |
| 官方软件包安装方式（`ORMode=1`）加不了编译模块，且静默忽略 | 配了模块却选包安装时直接报错，并给出「改 ORMode=2」或「清空配置」两条出路 |
| 不负责下载、校验或保存插件源码 | 按 `名称\|下载地址\|SHA256\|类型` 配置，自动下载、**强制 SHA256 校验**、解压到 `src/or-modules/<名称>/` 并保留源码包 |
| 初装临时传入的参数不持久化，升级忘记再传就会编译出不含模块的版本 | 初装成功后写入 `/etc/lnmp/openresty-build.conf`，`./upgrade.sh openresty` 自动沿用；当前显式配置优先 |
| 动态模块的 `load_module` 配置没有自动生成 | 编译后扫描 `nginx/modules/*.so` 生成 `conf/load_modules.conf`，`nginx.conf` 顶部 include |
| Lua 库没有 LuaRocks 或自定义 lualib 管理入口 | `OpenResty_Custom_Lualib` 进 `lua_package_path`（生成 `conf/lua_paths.conf`）；`OpenResty_Opm_Packages` 走 opm，`OpenResty_Luarocks_Packages` 走 luarocks |

实现细节：

- 模块名走白名单（字母数字点下划线连字符），拒绝 `..`、点开头和路径分隔符 ——
  这个值会用作源码目录名。
- 下载地址必须是 https；SHA256 必填且不可跳过：这些代码会被编译进对外服务的
  进程，比普通依赖更需要确认来源。校验失败即删除下载的文件。
- 解压用 `--strip-components=1` 到固定目录名：上游归档包的顶层目录名通常带
  版本号，不固定下来就没法把 configure 参数写死。
- 解压后检查是否存在 `config` 文件，不是 nginx 模块源码时直接报错，
  而不是等到 configure 阶段报一堆看不懂的错。
- `load_modules.conf` 直接扫描 `.so` 而不是照配置推断文件名：`.so` 的名字由
  模块自己的 `config` 决定，未必等于配置里写的名称。生成动作可重复执行。
- opm / luarocks 装包失败只告警不中止：Web 服务本身是好的，缺库可以事后补。

**行为变化**：`ORMode=1` + 配置了自定义模块的组合由静默忽略改为报错退出；
动态模块现在会真正被加载（此前编译出 `.so` 但无人写 `load_module`，等于没装）。

## FEAT-NOTIFY-001 Telegram 通知与全局 tgnotice 函数

**位置**：新增 `tools/lnmp-tgnotice.sh`（安装为 `/bin/lnmp-tgnotice`）；
`include/end.sh` 新增 `Install_Tgnotice_Profile`；三个管理脚本加载函数并新增
`tgnotice` 子命令；`install.sh`、`upgrade.sh`、`pureftpd.sh`、`uninstall.sh` 同步

```bash
tgnotice "备份失败：wpdemo"      # 默认 HTML
tgnotice "*备份完成*" md         # MarkdownV2
tgnotice "原样文本 < & >" text   # 不做格式解析
```

函数通过 `/etc/profile.d/lnmp-tgnotice.sh` 自动加载，交互 shell、管理脚本、
安装与升级流程里都能直接调用。同一份文件既可被 source 取得函数，
也可直接当命令执行（`BASH_SOURCE` 与 `$0` 比较决定是否跑命令行入口）。

配置 `/etc/lnmp/notify.conf`（600），由 `lnmp tgnotice --init` 交互生成。

实现要点：

- **凭据不进命令行参数**：bot token 等同于 bot 的完整控制权，进程参数对同机
  所有用户可见。URL 与消息体都写进权限 600 的 curl 配置文件，`argv` 里只有
  `--config`。消息正文同样处理（可能含内网信息）。
- **文本原样发送，不替用户转义**：HTML 模式下 `<b>粗体</b>` 是用户想要的效果，
  代替转义就用不了了。代价是纯文本里的 `<` `&` 会让 Telegram 返回 400，
  因此**解析失败时自动降级为纯文本重发一次**并打印告警 ——
  通知的首要目标是送达，格式是次要的。
- 未配置或 `TG_Enable=0` 时静默跳过并返回 0：这个函数会散落在各处被调用，
  未启用时每次都刷提示反而干扰正常输出。启用了却缺 token / chat_id 则报错，
  那是配置错误，应该被发现。
- 超过 4000 字符截断并加说明（Telegram 单条上限 4096）。
- 失败重试 `TG_Retry` 次；返回码如实反映结果，调用方按需 `|| true`。
- `--status` 只显示 token 前段，不回显完整值。

## 本阶段验证结果

- `bash -n`：新增与改动的全部文件通过；`t/lint.sh` 全部通过；
  `t/consistency.sh` 通过 7 项，失败 0 项。
- OpenResty 模块定向测试 54 项全部通过：模块名白名单（含 `..`、路径分隔符、
  命令分隔符）、包安装方式冲突检测与提示内容、缺 SHA256 / 非 https / 类型非法 /
  缺地址 / 校验不匹配（并删除下载文件）/ 解压后非模块源码 六种拒绝路径、
  静态与动态模块的 configure 参数、`--strip-components` 后的目录结构、
  注释条目跳过、`load_modules.conf` 的生成与重复执行不累加、
  `lua_paths.conf` 的自定义目录与相对路径拒绝、持久化与沿用的往返一致性
  （含带空格和引号的参数）、显式配置优先于持久化文件。
- Telegram 通知定向测试 39 项全部通过：未配置 / 未启用时静默跳过且不发请求、
  缺 token 报错、token 与正文都不出现在命令行参数、curl 配置文件权限 600、
  三种格式映射与默认格式跟随配置、引号 / 反斜杠 / 换行的转义、超长截断、
  解析失败后降级重发且去掉 `parse_mode`、非格式类错误与网络失败返回非 0、
  重试次数、临时文件不残留、被 source 时不执行命令行入口。
- 数据库、FTP、备份测试回归：各 66 / 24 / 54 项全部通过。
- **验证状态**：已验证（静态与 stub 环境）。以下未在真机执行，待收尾验证：
  真实 OpenResty 源码编译加载自定义模块、`opm` / `luarocks` 装包、
  向真实 Telegram API 发送消息。已记入 `todo.md`。
