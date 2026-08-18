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
- **验证状态**：已实测失败；见阶段 25 `DB-SOURCE-RUN-001`，源码路径问题已记入
  `AUDIT-DBSOURCE-001`，本轮按要求不修复（2026-08-11）。

### FIX-DB-002 修复 EL9+ 上 MySQL 8.4 缺 gcc-toolset-12

- **文件**：`include/init.sh`(2 处) `include/only.sh`(2 处) → `include/dbcommon.sh`
- **问题**：四处均只判断 `DBSelect=5`，漏了 11。
- **改动**：抽取为 `DB_Toolchain_EL9()`，改判 `DB_Kind = mysql`。
- **行为变化**：**有**：MySQL 8.4 在 EL9/EL10/Oracle9 上源码编译现在能拿到工具链。
- **验证状态**：已验证（静态；`DB_Toolchain_EL9` 可达性与分派测试通过，EL9+ 真机
  不属于 Debian 12 主线，2026-08-11）。

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
- **验证状态**：已验证，见阶段 24 `PORT-RUN-003` 的 `CheckMirror=n` 实机安装分支（2026-08-11）。

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
- **验证状态**：已验证（静态；EL8/9/10 真机换源不属于 Debian 12 主线，2026-08-11）。

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
- **验证状态**：已实测，见阶段 24 `UNINST-RUN-001`（Debian 12，2026-08-11）。

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
- **验证状态**：已验证（核心路径；phpMyAdmin、数据库与 OpenResty 升级及缓存校验均有
  Debian 12 实测，未覆盖的其它升级组合仍按各自条目管理，2026-08-11）。

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
- **验证状态**：已验证（实现范围；phpMyAdmin 事务切换与数据库成功升级已有 Debian 12
  实测，失败回滚路径完成静态/故障注入检查；数据库自动回滚仍按 `SCOPE-001` 暂缓，
  2026-08-11）。

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
  - **Debian 13：已验证（静态；非 Debian 12 主线，2026-08-11）。** 用户确认**老版本 v2.1 已能在
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
- **验证状态**：已实测，见阶段 24 `UNINST-RUN-001`（Debian 12，2026-08-11）。

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
- **验证状态**：已验证，见阶段 25 `SEC-PMA-RUN-001`（同版本 phpMyAdmin 升级、HTTP 200、
  64 位十六进制 `blowfish_secret`，2026-08-11）。

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
- **验证状态**：已验证（静态；LNMPA 代理真机不属于 Debian 12 LNMP 主线，2026-08-11）。

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
- **验证状态**：已验证（静态；Apache/LAMP/LNMPA 真机不属于 Debian 12 LNMP 主线，2026-08-11）。

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
- **验证状态**：已验证，见阶段 24 `PORT-RUN-006` 的 Pure-FTPd/FTPS 实机安装与传输（2026-08-11）。

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
- **验证状态**：部分已验证；见阶段 25 `DB-SOURCE-RUN-001`。失败路径日志未出现
  root 密码，但由于源码构建先失败，成功安装后的独立入口收尾仍待修复后复验（2026-08-11）。

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

仍需普通收尾验证：`FIX-DB-001`、`SEC2-006`。前者是 MySQL 8.4 源码编译路径，
后者是独立 `./install.sh db` 的日志凭据检查；均未被本轮二进制主线安装覆盖。

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

# 阶段 21 — 端口配置化与备份的 FTP 通道（2026-08-10）

## FEAT-PORT-001 服务端口统一到 lnmp.conf，配置与防火墙规则联动

**位置**：`lnmp.conf` 新增端口配置块；`include/end.sh`、`include/firewall.sh`、
`include/redis.sh`、`include/memcached.sh`、`include/mysql.sh`、`include/mariadb.sh`、
`pureftpd.sh`；`include/main.sh` 新增 `Check_Conf_Applied`；
`t/lint.sh` 新增 C15，`t/consistency.sh` 新增 V8、V9

端口原先写死在各个脚本里：`Firewall_Allow tcp 21`、`port = 3306`、
`PORT=11211`、`REDISPORT=6379`。想换端口就得同时改服务配置和防火墙规则两处，
漏掉任何一处都不会有报错 —— 服务监听一个端口，防火墙按另一个端口放行或阻断。

**改动**：九个端口变量集中到 `lnmp.conf`，都带默认值、可用环境变量覆盖：
`SSH_Port`、`DB_Port`、`DB_X_Port`、`Redis_Port`、`Memcached_Port`、
`Pureftpd_Port`、`Pureftpd_Data_Port`、`Pureftpd_Passive_Min/Max`。

安装时同时作用于两侧：

| 端口 | 写进服务配置 | 防火墙 |
| --- | --- | --- |
| `DB_Port` | `/etc/my.cnf` 的 `port`（mysql 4 处、mariadb 2 处） | 阻断 |
| `DB_X_Port` | —（X Protocol 由 mysqlx 选项控制） | 阻断 |
| `Redis_Port` | `redis.conf` 的 `port`、`init.d/redis` 的 `REDISPORT`、自测页 | 阻断 |
| `Memcached_Port` | `init.d/memcached` 的 `PORT` | 阻断 tcp+udp |
| `Pureftpd_Port` | `pure-ftpd.conf` 的 `Bind` | 放行 |
| `Pureftpd_Passive_*` | `pure-ftpd.conf` 的 `PassivePortRange` | 放行整段 |
| `SSH_Port` | —（本包不改 sshd_config） | 放行 |

模板文件本身保持默认值不变（`conf/pure-ftpd.conf`、`init.d/*` 仍可独立使用），
覆写发生在部署后的目标文件上。新增 `Check_Conf_Applied` 在每次覆写后回读确认：
上游模板换了写法时 `sed` 会一条都匹配不上却仍返回 0，服务就会用模板里的默认
端口起来，与防火墙规则对不上且全程没有报错。现在这种情况直接报错停下。

nginx 的 80/443 不纳入：那两个端口散落在 nginx.conf、每个站点配置和 SSL 签发
流程里，不是一个变量能覆盖的，C15 检查里把它们列为例外。

**防回归**：`t/lint.sh` 的 C15 禁止再往 `Firewall_Allow/Block/Unblock` 后面写
字面端口号；`t/consistency.sh` 的 V8 检查九个变量在 `lnmp.conf` 都有默认值，
V9 检查每个服务的配置覆写动作还在。三项都做过注入式验证（故意写回硬编码、
故意删掉覆写语句，检查都能报出来）。

## FEAT-BACKUP-002 异地备份支持 ftp / ftps

**位置**：`tools/lnmp-backup.sh`

原先只能走 SFTP。有些机房只提供一台老 FTP 服务器，没有 SSH，
这条路径原本完全不可用。

**改动**：新增 `Remote_Protocol`，取值 `sftp`（默认）、`ftps`、`ftp`。
ftp/ftps 走 `curl` 实现，上传顺序与语义和 sftp 完全一致：
先传到远端 `.incoming/<批次>-<类型>/`，逐个核对文件大小，全部对上之后用
`RNFR`/`RNTO` 把整个目录改名到正式位置，最后才清理远端过期批次。

- 口令写进权限 600 的 curl 配置文件，不进命令行参数（与 token 同样处理）。
- 远端文件大小用 `curl --head` 取 `Content-Length`，比解析 `LIST` 稳 ——
  LIST 的格式随服务器实现而变。
- `ftps` 用 `ssl-reqd`（显式 FTPS，ftp:// + AUTH TLS），默认校验对端证书；
  自签证书走 `Remote_Ftp_CA`，`Remote_Ftp_Verify=0` 会打印无法防中间人的告警。
- 选 `ftp` 时每次运行都在日志里留明文告警：账号口令与整包备份数据全程不加密。

**顺带修正**：`Cleanup_Remote_Ftp` 与 `Cleanup_Remote_Sftp` 原先用
`... | while read` 遍历批次，管道右侧是子 shell，在里面再调用需要开子进程和
临时文件的上传函数会拿不到正确结果 —— 测试里表现为远端过期批次没被清掉。
改为先把列表取回变量再用 `for` 遍历。

## DOC-501 端口与 FTP 上传写入文档

`README.md` 新增「自定义服务端口」小节（含改 `SSH_Port` 的风险提示）；
`HowtoGuides.md` 8.5 新增「只有 FTP 服务器可用时」，用表格说明三种方式在
凭据与传输上的差别，原 8.5.6 顺延为 8.5.7。

## 本阶段验证结果

- `bash -n` 全部通过；`t/lint.sh` 全部通过（含新增 C15）；
  `t/consistency.sh` 通过 9 项（含新增 V8、V9），失败 0 项。
- FTP/FTPS 上传定向测试 26 项全部通过：协议非法与缺口令的拒绝、
  ftp 上传成功后远端出现批次且 `.incoming` 清空、口令不出现在命令行参数、
  curl 临时配置文件不残留、上传失败与远端截断都不污染正式目录、
  上传失败时不清理旧批次、ftps 强制 TLS 且默认校验证书、
  关闭校验时传 `insecure` 并告警、远端过期批次清理、list 与 status 显示协议。
- 回归：备份 sftp 54 项、数据库 66×3、FTP 子命令 24×3、
  Telegram 39 项、OpenResty 模块 54 项，全部通过。
- **验证状态**：已验证（静态与 stub 环境）。未在真机执行、待收尾验证：
  改过端口的实际安装（服务能否在新端口起来、nftables 规则是否匹配）、
  对真实 FTP/FTPS 服务器的上传与 `RNFR/RNTO` 目录改名。已记入 `todo.md`。

# 阶段 22 — 新增功能真机审计（2026-08-11）

## DB-RUN-001 数据库导入导出在 Debian 12 真机通过

**范围**：`conf/lnmp` 的 `lnmp database export`、`lnmp database import`；
MySQL 8.4 单库导出与恢复路径。

在 Debian 12 已安装环境部署当前管理脚本，创建含两行数据（含中文内容）的临时库，
经真实命令导出为 `.sql.gz`。`mysqldump` 与 `gzip` 均返回 0，`gzip -t` 通过，
解压后的末尾存在 `Dump completed`。随后删除原表，通过 `lnmp database import`
恢复，命令返回 0，表内行数和内容与导出前一致。

- **验证状态**：已实测（Debian 12、MySQL 8.4，2026-08-11）。
- **文档处理**：本项没有对应的未完成 TODO，无需从 `todo.md` 删除条目。

## BK-RUN-001 backup init、站点发现与 timer 配置真机通过

**范围**：`tools/lnmp-backup.sh` 的 `Cmd_Init`、`Discover_Sites`、`Guess_Db`、
`Write_Systemd_Unit`。

在 Debian 12 临时创建 WordPress 形态站点及 Nginx vhost，执行当前
`lnmp backup init`。脚本正确从 vhost 提取域名和网站目录，并从
`wp-config.php` 提取数据库名；数据库凭据校验返回成功。生成的 `backup.conf`、
`backup-mysql.cnf` 权限为 600，systemd service/timer 权限为 644；timer 为
enabled、active，`systemctl list-timers` 可回读下一次计划。

- **验证状态**：已实测（Debian 12，2026-08-11）。
- **文档处理**：已从 `TODO-BK-001` 删除“backup init 完整交互与站点扫描未验证”；
  systemd service 的实际执行另行验证。

## BK-RUN-002 本地备份、状态命令与 systemd service 真机通过

**范围**：`tools/lnmp-backup.sh` 的 `run all`、`status`、`list`、校验清单及
生成的 `lnmp-backup.service`。

在 Debian 12 使用真实 MySQL 8.4 数据库和临时 WordPress 站点执行备份。数据库
`.sql.gz`、网站 `.tar.gz` 与各自 `SHA256SUMS` 均生成，文件权限为 600；
`sha256sum -c`、`gzip -t`、`tar tzf` 全部返回 0，tar 内容包含站点目录和
`wp-config.php`。`lnmp backup status/list` 正确显示成功状态与批次。随后通过
`systemctl start lnmp-backup.service` 再执行一次，unit 的 Result 为 success、
ExecMainStatus 为 0，并新增真实数据库备份批次；timer 为 active，启用后的
`Persistent=true` 触发时间可回读。

- **验证状态**：已实测（Debian 12、MySQL 8.4，2026-08-11）。
- **文档处理**：已从 `TODO-BK-001` 删除真实小规模备份与 systemd service 未验证项；
  大数据压力、真实 SFTP 和恢复覆盖仍保留。

## BK-RUN-003 数据库试恢复与临时库清理真机通过

**范围**：`tools/lnmp-backup.sh` 的 `lnmp backup test` 正常路径。

对最新真实数据库备份执行试恢复，SHA256 校验通过，备份被导入临时库并识别到
1 张表，命令返回 0。执行前后查询 `information_schema.SCHEMATA`，匹配
`lnmp_bktest_%` 的库数量均为 0，确认临时库已经删除。

- **验证状态**：已实测（Debian 12、MySQL 8.4，2026-08-11）。
- **文档处理**：正常试恢复没有独立未完成 TODO；截断 gzip 的失败注入仍见
  `AUDIT-BK-002`，本次正常路径通过不关闭该问题。

## BK-RUN-004 数据库覆盖恢复真机通过

**范围**：`tools/lnmp-backup.sh` 的 `lnmp backup restore db` 正常路径。

先修改已备份数据库中的一行数据，再从最新批次恢复。SHA256 校验通过，恢复命令
返回 0；复查表内两行数据，行数与包含中文的内容均恢复为备份时的值。

- **验证状态**：已实测（Debian 12、MySQL 8.4，2026-08-11）。
- **文档处理**：`TODO-BK-001` 的恢复项还包含网站目录覆盖，完成网站恢复实测后
  再删除该项。

## BK-RUN-005 网站文件覆盖恢复真机通过

**范围**：`tools/lnmp-backup.sh` 的 `lnmp backup restore web` 正常路径。

先把已备份临时站点的 `wp-config.php` 改成不同内容，再从最新网站批次恢复。
SHA256 校验通过，恢复命令返回 0；文件被备份中的原内容覆盖，数据库名配置与
备份时一致。

- **验证状态**：已实测（Debian 12，2026-08-11）。
- **文档处理**：已从 `TODO-BK-001` 删除恢复覆盖未验证项；该 TODO 现在只保留
  大数据压力和真实 SFTP 条件。

## OR-RUN-001 OpenResty 自定义动态模块真编译通过

**范围**：`include/openresty_modules.sh` 的模块下载、SHA256 校验、解压、参数生成、
`OR_Modules_Post_Build` 与配置持久化；OpenResty 源码 configure/make/install。

在 Debian 12 使用 GeoIP2 3.4 作为真实第三方动态模块。OpenResty 1.31.1.1 源码
经项目 PGP 验签通过，模块归档经项目 SHA256 校验通过；`OR_Modules_Prepare`
生成 `--add-dynamic-module` 参数，configure 识别 MaxMindDB、PCRE2、OpenSSL 和
zlib。完整 `make && make install` 返回 0，在临时前缀生成
`ngx_http_geoip2_module.so` 与 `ngx_stream_geoip2_module.so`。项目随后生成两条
`load_module`，独立 OpenResty 加载后 `nginx -t` 返回 0，`nginx -V` 也可回读
该自定义模块参数。

- **验证状态**：已实测（Debian 12，2026-08-11）。
- **文档处理**：已从 `TODO-OR-001` 删除真编译、`.so` 落地和 `nginx -t` 未验证项；
  仅保留升级沿用配置重新编译。

## TG-RUN-001 Telegram 通知本地状态与错误路径真机通过

**范围**：`tools/lnmp-tgnotice.sh`、`conf/lnmp` 的 `tgnotice` 转发入口及
`Install_Tgnotice_Profile`。

在 Debian 12 部署当前通知脚本和 profile 加载文件。无配置及 `TG_Enable=0` 时，
普通通知命令静默返回 0；无配置 `--status` 返回 0 并提示初始化；关闭态
`--test` 返回 1；启用但缺 Token/Chat ID 时普通通知返回 1。各路径均未产生网络
请求所用的 `.lnmp-tg.*` 残留文件，管理命令的转发退出码与通知脚本一致。

- **验证状态**：已实测（Debian 12 本地路径，2026-08-11）；真实 Telegram API
  发送需要真实 Bot Token/Chat ID，仍为 `待人工真机验证`，见 `TODO-NOTIFY-001`。
- **文档处理**：本项没有可关闭的真实 API TODO；配置权限问题已立即新增为
  `AUDIT-NOTIFY-002`。

## PORT-RUN-001 MySQL 非默认端口下管理与备份命令通过

**范围**：现有 Debian 12 MySQL 8.4 运行配置，`lnmp database export/import`、
`lnmp backup run db`。

把验证机 MySQL 经典协议端口从默认值改为非默认端口后重启，服务启动成功，
`@@port` 与 `ss -lntp` 回读一致；X Protocol 仍保持原端口。随后真实执行数据库
导出、修改数据、重新导入和数据库备份，四个命令均返回 0，恢复后的两行数据
与变更前一致。

- **验证状态**：已实测（Debian 12、MySQL 8.4，2026-08-11）。
- **范围限制**：这是现有服务的非默认端口运行验证；完整安装传播、应用连接与
  防火墙联动已在阶段 24 完成收尾。
- **已知问题**：`@@mysqlx_port` 仍为默认值，继续由 `AUDIT-PORT-003` 跟踪。

## PORT-RUN-002 Redis 非默认端口下服务与 PHP 连接通过

**范围**：现有 Debian 12 Redis 8.8.0 运行配置、init 脚本、`redis-cli`、
PHP 8.3 Redis 扩展与 `lnmp status`。

把 Redis 配置和 init 脚本端口同时改为非默认值后重启，systemd 状态为 active，
`ss -lntp` 仅在新端口看到 Redis，旧端口连接失败；新端口 `PING` 返回 PONG。
PHP 8.3 的 Redis 扩展连接新端口并执行 PING 返回成功，`lnmp status` 返回 0。

- **验证状态**：已实测（Debian 12、Redis 8.8.0、PHP 8.3，2026-08-11）。
- **范围限制**：这是现有服务运行验证，不替代安装入口的端口传播验证；
  安装入口传播、Memcached 与 Pure-FTPd 已在阶段 24 完成收尾，WordPress 端口由站点管理员手工配置。

## OR-RUN-002 opm 真实装包与 Lua 加载通过

**范围**：源码编译 OpenResty 自带的 `opm` 及项目
`OpenResty_Opm_Packages` 所依赖的运行路径。

在 Debian 12 的真实 OpenResty 临时前缀执行
`opm get ledgetech/lua-resty-http`，OPM 0.0.7 从真实仓库取得 0.17.1 并返回 0，
`resty/http.lua` 等文件落入 `site/lualib`。随后用该 OpenResty 的 `resty` 执行
`require "resty.http"` 并检查 `new` 函数，返回 0。

- **验证状态**：已实测（Debian 12、OpenResty 1.31.1.1，2026-08-11）。
- **文档处理**：已从 `TODO-OR-002` 删除 opm 未验证部分，只保留 luarocks；
  `lnmp.conf` 的无效示例包名继续由 `AUDIT-OR-004` 跟踪。

## OR-RUN-003 luarocks 真实装包与 OpenResty 加载通过

**范围**：`include/openresty_modules.sh` 的 `OR_Install_Lua_Packages` luarocks 路径。

在 Debian 12 安装系统 luarocks 后，通过项目函数执行
`luarocks install luafilesystem`。luafilesystem 1.9.0-1 从真实仓库取得，C 扩展
编译并安装到 `/usr/local`，函数返回 0；随后用源码编译的 OpenResty `resty`
执行 `require "lfs"` 并检查 `currentdir` 函数，返回 0。

- **验证状态**：已实测（Debian 12、OpenResty 1.31.1.1，2026-08-11）。
- **文档处理**：`TODO-OR-002` 的 opm 与 luarocks 两条路径均已真机通过，
  该 TODO 已从 `todo.md` 删除。

## AUDIT-RUN-001 Debian 12 最终静态与回归检查通过

在同步当前仓库的 Debian 12 审计目录重新执行全部 shell 文件及三个管理脚本的
`bash -n`，退出码 0；`t/lint.sh` 的 C1-C15 与 T1 全部通过；
`t/consistency.sh` 的 V1-V9 通过 9 项、失败 0 项；`t/test_profile.sh`、
`t/test_dispatch.sh`、`t/test_bump.sh` 均全部通过并返回 0。

- **验证状态**：已实测（Debian 12，2026-08-11）。
- **范围说明**：这组回归证明语法、静态约束和既有定向测试没有退化，不替代
  `todo.md` 中明确保留的真实远端、凭据、故障注入和完整安装场景。

# 阶段 23 — 审计问题修复与真机复验（2026-08-11）

## AUDIT-FIX-PORT-001 自定义端口校验、升级保持与 MySQL X Protocol 传播通过

**对应问题**：`AUDIT-PORT-001`、`AUDIT-PORT-002`、`AUDIT-PORT-003`。

在 Debian 12 上先从三个真实入口分别注入非数字、越界、重复端口和倒置的
Pure-FTPd 被动端口范围，`install.sh`、`upgrade.sh`、`pureftpd.sh` 均在执行系统
操作前以非零退出。随后把 MySQL 经典协议和 X Protocol 同时改为非默认端口，
重启后 SQL 回读与 `ss -lntp` 一致，两个默认端口均无监听。

继续使用项目校验过的 MySQL 8.4.7 官方二进制执行完整数据库升级路径，覆盖全库
备份、旧实例迁移、新实例初始化、数据导入、`--upgrade=FORCE`、LNMP 重启和
`Verify_DB_Upgraded` 最终验收。升级完成后数据库列表完整，两个自定义端口均保持，
`/etc/my.cnf` 的 `port` 与 `loose-mysqlx-port` 和运行值一致，`lnmp status` 返回 0。

- **验证状态**：已实测（Debian 12、MySQL 8.4.7，2026-08-11）。
- **文档处理**：对应三条问题已从 `todo.md` 删除。

## AUDIT-FIX-BK-001 备份初始化凭据 fail-fast 与配置隔离通过

**对应问题**：`AUDIT-BK-004`、`AUDIT-BK-005`。

在 Debian 12 保留有效 `/root/.my.cnf` 的条件下，向 `backup init` 输入错误数据库
密码。命令返回 1，专用凭据校验没有被用户级配置覆盖；`backup.conf`、
`backup-mysql.cnf` 和 timer 均未生成，timer 保持 inactive。随后输入正确密码重新
初始化，配置与专用凭据权限为 600，systemd unit 权限为 644，timer 为
enabled、active。专用 `--defaults-file` 可独立连接运行在非默认端口的 MySQL，
并正确回读经典协议与 X Protocol 端口。

- **验证状态**：已实测（Debian 12、MySQL 8.4.7，2026-08-11）。
- **文档处理**：对应两条问题已从 `todo.md` 删除。

## AUDIT-FIX-BK-002 缺失网站目录会让整批备份失败

**对应问题**：`AUDIT-BK-003`。

在同一批次配置一个存在的网站目录和一个不存在的目录，执行真实 `run web`。
存在目录正常打包后，缺失目录触发明确错误，命令最终返回 1，状态文件记录
`Last_Run_Rc=1`，日志把批次标为不完整并跳过旧备份清理，没有再输出整体成功。

- **验证状态**：已实测（Debian 12，2026-08-11）。
- **文档处理**：对应问题已从 `todo.md` 删除。

## AUDIT-FIX-BK-003 恢复与试恢复同时检查 gzip 和 MySQL 状态

**对应问题**：`AUDIT-BK-002`。

构造一份 SHA256 清单正确、能完整输出有效 SQL、但末尾带损坏数据的 gzip 备份。
原始管道结果为 `gzip=2`、`mysql=0`，精确覆盖了“SQL 已被接受但压缩流损坏”的
场景。修复后的数据库 restore 和 test 均返回 1，并分别报告两个管道退出码；
试恢复结束后 `lnmp_bktest_%` 临时库数量为 0，没有留下测试数据库。

- **验证状态**：已实测（Debian 12、MySQL 8.4.7，2026-08-11）。
- **文档处理**：对应问题已从 `todo.md` 删除。

## AUDIT-FIX-BK-004 远端批次列表按协议分流

**对应问题**：`AUDIT-BK-001`。

在 Debian 12 执行函数级定向回归，分别把协议设为 FTP、FTPS 和 SFTP：前两者只
调用 curl 后端，SFTP 只调用 sftp 后端，三组远端批次输出均正确；更新后的
`t/test_audit_fixes.sh` 共 16 项全部通过。

- **验证状态**：已验证（Debian 12 函数级故障注入，2026-08-11）。真实 FTP/FTPS
  服务器连接、证书、上传和远端改名仍为 `待人工真机验证`，继续由
  `TODO-BACKUP-FTP-001` 跟踪。
- **文档处理**：对应代码问题已从 `todo.md` 删除，未删除真实远端 TODO。

## AUDIT-FIX-OR-001 显式 Lua 配置优先且持久化失败向上传递

**对应问题**：`AUDIT-OR-001`、`AUDIT-OR-002`。

在 Debian 12 构造包含旧 Lua、OPM 设置的持久化文件，同时在当前配置设置新的
Lua 路径。`OR_Modules_Load_Persisted` 返回 0，当前 Lua 路径保持不变，旧 OPM
数组没有被载入；自定义 Lua 路径、OPM、LuaRocks 三类设置都已纳入显式配置判断。
再把持久化目标指向不能作为目录使用的路径，`OR_Modules_Persist` 返回 1；安装与
升级入口均以 `if ! OR_Modules_Persist` 检查并向上返回失败，不会继续报告完成。

- **验证状态**：已验证（Debian 12 故障注入，2026-08-11）。
- **文档处理**：对应两条问题已从 `todo.md` 删除。

## AUDIT-FIX-OR-002 删除动态模块后重编译不再加载旧 so

**对应问题**：`AUDIT-OR-003`。

在 Debian 12 临时前缀完整编译 OpenResty 1.31.1.1 与 GeoIP2 3.4 动态模块。
项目的构建产物捕获函数记录两个真实 `.so`，安装后生成两条 `load_module`，
`nginx -t` 通过。随后以相同版本和前缀、但不带动态模块重新执行 configure、make
和 make install：本次构建清单为 0，旧前缀原有两个受管 `.so`。执行修复后的收尾
函数后旧 `.so` 数量变为 0，加载文件写明当前没有动态模块，最终 `nginx -t` 通过。

- **验证状态**：已实测（Debian 12、OpenResty 1.31.1.1，2026-08-11）。
- **范围说明**：这里只验证删除模块后的重编译清理；升级时继续保留已配置模块仍由
  `TODO-OR-001` 跟踪，本次未删除该 TODO。
- **文档处理**：对应问题已从 `todo.md` 删除。

## AUDIT-FIX-OR-003 OPM 示例包真实安装与加载通过

**对应问题**：`AUDIT-OR-004`。

使用本次源码编译生成的真实 `opm` 执行 `opm get ledgetech/lua-resty-http`，取得
0.17.1 并返回 0；再用同一前缀的 `resty` 加载 `resty.http`，确认 `new` 为函数，
返回 0。

- **验证状态**：已实测（Debian 12、OpenResty 1.31.1.1，2026-08-11）。
- **文档处理**：对应问题已从 `todo.md` 删除。

## AUDIT-FIX-NOTIFY-001 Token 隐藏输入、EOF 与配置权限校验通过

**对应问题**：`AUDIT-NOTIFY-001`、`AUDIT-NOTIFY-002`。

在 Debian 12 真实 TTY 中运行 `--init` 并输入模拟 Token，终端输出没有出现输入
内容，生成配置权限为 600。用 EOF 中断 Token 读取时命令返回 1且不生成配置。
再把同一模拟配置依次设为 600、400、644：前两种 `--status` 返回 0，644 返回 1
并明确拒绝加载。测试完成后已删除含模拟 Token 的临时配置。

- **验证状态**：已实测（Debian 12 本地路径，2026-08-11）。真实 Telegram API
  发送仍为 `待人工真机验证`，继续由 `TODO-NOTIFY-001` 跟踪。
- **文档处理**：对应两条问题已从 `todo.md` 删除，未删除真实 API TODO。

## AUDIT-FIX-DBRESET-001 密码重置后的临时 MySQL 实例可正常关闭

**对应问题**：`AUDIT-DBRESET-001`。

`--init-file` 执行 `ALTER USER` 后不再调用没有新凭据的 `mysqladmin shutdown`，
改为向已由专用 PID 文件确认身份的临时 mysqld 发送 `SIGTERM`，让服务正常关闭，
同时避免把新密码写入命令行或额外配置。

在 Debian 12 + MySQL 8.4.7 重跑完整密码重置，命令返回 0，正式 MySQL 自动恢复
active，新密码登录成功；`lnmp-dbreset` 临时进程和工作目录均为 0 残留。

- **验证状态**：已实测（Debian 12、MySQL 8.4.7，2026-08-11）。
- **文档处理**：对应问题已从 `todo.md` 删除。

## OR-RUN-004 持久化模块配置驱动真实 OpenResty 升级通过

**对应问题**：`TODO-OR-001`。

先在 `/usr/local/openresty` 建立带 GeoIP2 3.4 动态模块的 OpenResty 1.31.1.1
源码安装，并由项目函数把模块配置写入权限 600 的
`/etc/lnmp/openresty-build.conf`。随后清空当前显式模块配置，直接执行
`./upgrade.sh openresty`；升级日志明确从持久化文件沿用配置，OpenResty 源码包
PGP 验签和模块 SHA256 校验均通过，真实 configure、make、make install 返回成功。

升级命令返回 0，安装目录保留两个 GeoIP2 `.so` 和两条 `load_module`，`nginx -V`
含 GeoIP2 动态模块参数，OpenResty 自身 `nginx -t` 返回 0，持久化文件仍保留模块
条目。

- **验证状态**：已实测（Debian 12、OpenResty 1.31.1.1，2026-08-11）。
- **文档处理**：对应 TODO 已从 `todo.md` 删除。

# 阶段 24 — 自定义端口完整安装与历史状态复验（2026-08-11）

## UNINST-RUN-001 完整卸载与半安装兜底路径通过

**对应条目**：`FIX-UNINST-001`、`FIX-UNINST-002`。

先对现有 Debian 12 LNMP 主栈执行 `uninstall.sh lnmp`。数据库数据目录成功移动到
`/root/databases_backup_<时间>`，目标目录存在且非空；Nginx、PHP、MySQL、
phpMyAdmin 和管理命令均被清理。随后构造一个只有 PHP 8.5 目录、init 脚本和
nginx 配置片段，且没有 `/bin/lnmp` 的半安装状态，再以命令行参数执行卸载。

第二次卸载正确进入逐个 init 脚本的停止兜底，未出现 `lnmp: command not found`；
PHP 8.5 目录、init 脚本及 nginx 配置片段均被删除。两组清理与数据备份断言返回 0。

- **验证状态**：已实测（Debian 12，2026-08-11）。
- **文档处理**：阶段 16 的 `FIX-UNINST-001`、`FIX-UNINST-002` 已关闭。

## PORT-RUN-003 自定义端口主线安装与 phpMyAdmin 登录通过

**对应问题**：`TODO-PORT-001`（主栈部分，已由阶段 24 收尾）。

在清理旧 LNMP 后，从 `install.sh lnmp` 入口一次安装 MySQL 8.4.7、PHP 8.3.33、
Nginx 和 phpMyAdmin，并注入非默认数据库经典协议、X Protocol、Redis、Memcached
及 FTP 端口配置；安装器返回 0。MySQL TCP 查询回读自定义经典/X 端口和版本，
默认端口无监听；Nginx 配置测试成功，Nginx、PHP-FPM、MySQL 均为 active。
nftables 的数据库阻断规则与两个实际端口一致，`CheckMirror=n` 分支也实际执行。

phpMyAdmin 首页返回 HTTP 200，使用刚生成的 root 凭据完成真实登录，响应包含
`route=/logout`，证明 PHP mysqli 经当前 MySQL 配置可用。

- **验证状态**：已实测（Debian 12、MySQL 8.4.7、PHP 8.3.33、phpMyAdmin，2026-08-11）。
- **范围说明**：Redis、Memcached、Pure-FTPd 已由阶段 24 后续条目完成实测；WordPress 非默认数据库端口由站点管理员手工配置 `wp-config.php`，不属于本包自动化验收。

## PORT-RUN-004 Redis 安装入口自定义端口与 PHP 连接通过

从已完成的主线环境执行 `addons.sh install redis`，注入非默认端口。Redis 服务配置
和 init 脚本均回读为该端口，systemd 服务 active，`ss` 仅看到新端口；默认
`6379` 无监听，nftables 规则与新端口一致。`redis-cli PING` 返回 `PONG`，PHP
8.3 Redis 扩展连接新端口并执行 `PING` 返回成功。

- **验证状态**：已实测（Debian 12、Redis 8.10.0、PHP 8.3，2026-08-11）。

## PORT-RUN-005 Memcached 安装入口自定义端口与服务生命周期通过

从 `addons.sh install memcached` 入口安装 Memcached 1.6.39，设置非默认端口
`41211`，并选择 PHP `memcache` 扩展。修复 init 脚本把 PID 文件放入由 root 创建、
由 `memcached` 用户可写的 `/run/memcached`，且启动后等待 PID/进程确认，安装验收
同时检查服务状态。Debian 12 实测中，init 脚本启动、`status`、`restart`、`stop`
及再次启动的退出码符合预期；PHP 8.3 `Memcache` 对新端口真实执行连接、set/get
成功；新端口监听、默认 `11211` 无监听，nftables TCP/UDP 阻断规则均存在。

- **验证状态**：已实测（Debian 12、Memcached 1.6.39、PHP 8.3，2026-08-11）。
- **文档处理**：`AUDIT-MEMCACHED-001` 已修复并从 `todo.md` 删除。

## PORT-RUN-006 Pure-FTPd 自定义端口与被动 FTPS 传输通过

从 `pureftpd.sh` 入口安装 Pure-FTPd 1.0.54，设置控制端口 `42121`、数据端口
`42020` 和被动端口范围 `43000-43010`。修复安装收尾优先通过 native systemd
unit 启动并检查 active，避免直接调用 SysV 脚本造成 systemd 状态失真。Debian 12
实测 `systemctl is-active` 与 `is-enabled` 均成功，配置中的 `Bind`、
`PassivePortRange`、控制端口监听及 nftables 规则一致。

创建临时 PureDB 用户后，使用真实 FTPS 客户端完成目录列表、被动模式上传、下载
和内容比对，全部返回 0；测试用户和临时文件已清理。

- **验证状态**：已实测（Debian 12、Pure-FTPd 1.0.54，2026-08-11）。
- **文档处理**：`AUDIT-FTP-001` 与 `TODO-PORT-001` 已完成并从 `todo.md` 删除；
  WordPress 非默认数据库端口仍由站点管理员手工配置 `wp-config.php`。

# 阶段 25 — 端口收尾后的回归与文档对账（2026-08-11）

修复后的目标脚本 `bash -n` 全部通过；`t/lint.sh` C1-C15/T1 全部通过，
`t/consistency.sh` V1-V10 全部通过，`t/test_audit_fixes.sh` 19 项、
`t/test_profile.sh`、`t/test_dispatch.sh`、`t/test_bump.sh` 均返回 0。

已从 `todo.md` 删除完成的 `AUDIT-MEMCACHED-001`、`AUDIT-FTP-001` 与
`TODO-PORT-001`；保留项均仍需要外部服务器、真实密钥或非主线组合，状态与本阶段
实测范围没有冲突。WordPress 非默认数据库端口按约定由站点管理员手工配置，未冒充
本包自动化测试结果。

- **验证状态**：已验证（Debian 12，2026-08-11）。

## SEC-PMA-RUN-001 phpMyAdmin 升级路径与随机密钥通过

在 Debian 12 对已运行的 phpMyAdmin 5.2.1 执行
`printf '5.2.1\\n\\n' | bash ./upgrade.sh phpmyadmin`，下载文件通过上游 SHA256
核对，暂存目录切换成功，命令返回 0。升级后入口 HTTP 返回 200，配置中的
`blowfish_secret` 为 64 位十六进制随机值；旧备份目录和临时检查文件已清理。

- **验证状态**：已实测（Debian 12、phpMyAdmin 5.2.1，2026-08-11）。
 - **文档处理**：`SEC-PMA-001` 已从“待收尾验证”改为已验证。

## DB-SOURCE-RUN-001 独立 MySQL 8.4 源码安装与日志凭据检查

在清理现有 LNMP 后执行：
`DBSelect=2 Bin=n CheckMirror=n InstallInnodb=y LNMP_Auto=y ./install.sh db`。
MySQL 8.4.7 源码包和 Boost 1.84.0 均下载并通过 SHA256 校验，随后 CMake 把源码
目录错误解析为项目 `src/`，报告缺少 `CMakeLists.txt`，`src/build` 没有 Makefile，
命令返回 1，未达到安装完成验收。该结果已记录为 `AUDIT-DBSOURCE-001`，本轮不改代码。

同时检查 `/root/install_database.log`：没有出现测试用 root 密码，证明失败路径没有把
凭据写入日志；但成功安装后的 `Print_DB_Password_Notice` 路径尚未走到，`SEC2-006`
保留待修复后复验。

- **验证状态**：已实测失败（Debian 12，2026-08-11）。

# 阶段 26 — 源码构建修复复验与遗留审计项收尾（2026-08-11）

## DB-SOURCE-FIX-001 MySQL 8.4 源码构建目录解析修复通过

**对应问题**：`AUDIT-DBSOURCE-001`（即 `FIX-DB-001` 的源码路径）。

`include/mysql.sh` 的源码分支在 `Install_Boost` 之后补了一次显式
`cd "${cur_dir}/src/${Mysql_Ver}"`：`Install_Boost` 下载外部 Boost 时会把工作目录
留在 `src/`，之前直接 `mkdir build && cd build`，构建目录落到 `src/build`，
`cmake ..` 指向项目 `src/`，报缺少 `CMakeLists.txt`。

Debian 12 实测 `DBSelect=2 Bin=n CheckMirror=n InstallInnodb=y ./install.sh db`：
CMake 输出 `Build files have been written to: .../src/mysql-8.4.7/build`，
Makefile 生成在源码树内，`src/build` 不再出现。编译推进到 100%，
`make install` 返回 0，`mysqld --version` 报告 `8.4.7 ... (Source distribution)`，
安装目录约 1.5GB。

- **验证状态**：已实测（Debian 12、MySQL 8.4.7，2026-08-11）。
- **范围说明**：编译与 `make install` 之后的初始化、启动和验收步骤，本轮由
  同一入口的通用二进制安装覆盖（见 `SEC2-006-RUN-001`）；源码路径从
  `make install` 到安装收尾的连续执行未在同一次运行中走完。
- **文档处理**：`AUDIT-DBSOURCE-001` 已从 `todo.md` 删除。

## AUDIT-OOM-001 并行编译只看核数，小内存机器被 OOM 杀掉

**位置**：`include/init.sh` 的 `Make_Install`、`PHP_Make_Install`，
`include/upgrade_nginx.sh`、`include/upgrade_php.sh`、`include/upgrade_mphp.sh`、
`include/openresty.sh`、`include/upgrade_openresty.sh`

七处并行编译，四种写法，全部按 CPU 核数决定 `-j`，不考虑内存。Debian 12 /
8 核 / 5923MB 实测：`make -j8` 编译 MySQL 8.4 的 `sql_gis` 时被内核 OOM 杀掉
（`cc1plus` 单进程 `anon-rss` 787MB × 8 并发），`Make_Install` 的串行回退接住了，
但白跑一整轮，之后单核推进 9.5 分钟只前进 3%。

新增公共函数 `Build_Jobs`：按每任务 1GB 折算内存能支撑的并发，再与核数取小，
非数字或读不到时退到保守值。七处调用点统一改为 `-j"$(Build_Jobs)"`。
内存宽裕的机器结果仍是核数，行为不变。

实测：该机上 `Build_Jobs` 返回 5（8 核 / 5923MB）。以 5 个任务续编至 100%，
全程 `dmesg` 无新增 OOM 记录（唯一一次仍是此前 `-j8` 那次），
峰值内存占用约 1.5GB、可用 4.4GB。

新增静态检查 `t/lint.sh` C16：`make ... -j` 后必须是 `"$(Build_Jobs)"`。
该规则在加入时即抓出 `upgrade_php.sh`、`upgrade_mphp.sh` 两处漏改
（`make ZEND_EXTRA_LIBS=... -j`，`-j` 不与 `make` 相邻，人工 grep 未命中），
并已通过注入验证（把任一处改回 `$(nproc)` 即报错）。

- **验证状态**：已实测（Debian 12、MySQL 8.4.7，2026-08-11）。
- **范围说明**：只在 MySQL 源码编译路径实测；PHP、nginx、OpenResty 的编译
  路径同步改造但未各跑一遍。

## FEAT-DBSRC-001 源码编译数据库前的可行性把关与说明

**位置**：`include/main.sh` 的 `Check_DB_Source_Build`、`include/profile.sh` 的
`Select_DB_Bin`

本包的典型用户是 1-2GB 内存的小 VPS，而原有把关只有一句
「内存低于 `DB_Min_Mem_MB`（MySQL 8.x 为 1024MB）就拒绝」。1GB 机器因此可以
「通过」检查，然后编译几小时或中途失败，选择界面也没有任何代价说明。

改为三档：

| 条件 | 行为 |
| --- | --- |
| 内存低于 `DB_Min_Mem_MB` 与 2048MB 取大者 | 直接拒绝，提示改用 `Bin=y` |
| 项目目录所在分区可用空间低于 15360MB | 直接拒绝，说明编译目录会涨到 7GB 以上 |
| 内存够但低于建议的 4096MB | 打印代价说明，交互式必须输入 `y` 才继续 |
| 非交互（无终端或 `LNMP_Auto=y`） | 打印警告后继续，不破坏既有自动化 |

`Select_DB_Bin` 的二进制/源码选择提示前补充中文说明：通用二进制由上游构建、
校验值同样强制核对、几分钟装完；源码编译需要 4GB 内存和 15GB 磁盘、通常要跑
数小时，只有确需定制编译参数时才选。

磁盘门槛取自本轮实测：编译目录约 7.8GB，加安装目录 1.5GB 与源码，
峰值消耗约 11.3GB。

实测：该机磁盘降到 5480MB 可用时执行 `Bin=n ./install.sh db`，命令在下载、
装依赖和任何系统改动之前打印剩余空间与门槛并返回 1。

- **验证状态**：已实测拒绝分支（Debian 12，2026-08-11）。
- **范围说明**：内存拒绝分支与交互确认分支未在真机构造（该机内存高于硬下限、
  测试为非交互执行）。

## SEC2-006-RUN-001 成功安装路径不泄露数据库口令

**对应问题**：`SEC2-006`。

从 `install.sh db` 入口用通用二进制完成 MySQL 8.4.7 安装，命令返回 0，
`Install_Only_Database` 的成功分支执行到 `Print_DB_Password_Notice`，
终端出现「密码不再回显」提示。随后检索 `/root/install_database.log`、
整个运行输出日志和 `/root/.bash_history`，本次使用的探针口令 0 处命中。

- **验证状态**：已实测（Debian 12、MySQL 8.4.7，2026-08-11）。
- **文档处理**：`SEC2-006` 由「部分验证」改为已验证。

## AUDIT-FW-001 单装数据库不配置防火墙

**位置**：`include/only.sh` 的 `Install_Database`

`Install_Only_Nginx` 会调用 `Add_Iptables_Rules`，`Install_Only_Database` 没有。
结果是最该挡的场景反而没挡：只装数据库的机器上，`DB_Port` 与 `DB_X_Port`
一条规则都没有。Debian 12 实测确认 `nft` 表里只有此前遗留的规则，
没有数据库端口的 drop。

在数据库服务启动之后补 `Add_Iptables_Rules || return 1`；防火墙配置失败要如实
反映到安装结果，不能只打印一行红字。

实测：清空 `nft` 表后重跑单装数据库，命令返回 0，规则表出现
`tcp dport 22/80/443 accept`、ICMP accept 以及两个自定义数据库端口的 `drop`。

- **验证状态**：已实测（Debian 12，2026-08-11）。

## AUDIT-PORT-002-FIX-002 addons.sh 缺少端口校验

**位置**：`addons.sh`

`Validate_Service_Ports` 此前只接在 `install.sh`、`upgrade.sh`、`pureftpd.sh`。
`addons.sh` 是 Redis 与 Memcached 的独立安装入口，同样会把端口写进 `sed` 和
防火墙命令。Debian 12 实测：`Redis_Port=abc bash addons.sh install redis`
一路走到下载 Redis 源码，没有任何拦截。

在 `addons.sh` 的 source 段之后补 `Validate_Service_Ports || exit 1`，
并把 `t/consistency.sh` 的 V10 入口清单加上 `addons.sh`。

实测四个失败分支均在任何系统动作前返回 1：非数字 `Redis_Port=abc`、
越界 `Memcached_Port=70000`、越界 `SSH_Port=0`、
被动端口区间倒置 `Pureftpd_Passive_Min=30001`；不注入变量时正常放行。

- **验证状态**：已实测（Debian 12，2026-08-11）。

## AUDIT-PORT-003-RUN-001 MySQL X Protocol 端口实测生效

**对应问题**：`AUDIT-PORT-003`。

阶段 24 记录该项时 `@@mysqlx_port` 仍为默认值。本轮以非默认的经典协议端口和
X Protocol 端口完成安装后实测：`/etc/my.cnf` 中 `port` 与 `loose-mysqlx-port`
为设定值，SQL 回读 `@@port`、`@@mysqlx_port` 一致，
`@@bind_address` 与 `@@mysqlx_bind_address` 均为回环地址，
`ss -lntp` 只在两个自定义端口看到 mysqld，默认的 3306 与 33060 无监听，
nftables 对两个自定义端口均有 drop 规则。

- **验证状态**：已实测（Debian 12、MySQL 8.4.7，2026-08-11）。

## AUDIT-MEMCACHED-002 Memcached 启动绕开 systemd

**位置**：`init.d/memcached.service`（新增）、`include/memcached.sh`、
`include/main.sh` 的 `Use_Systemd_Unit`

`AUDIT-MEMCACHED-001` 修好的是 PID 文件，但该条审计描述的症状
（`systemctl is-active memcached` 报 inactive）没有闭合：安装收尾仍直接调用
`/etc/init.d/memcached start`，而 `init.d/` 下也没有 memcached 的 unit，
`StartOrStop` 只能退回 SysV 脚本。其余服务（nginx、php-fpm、数据库、Redis）
都有自己的 unit 并走 `StartOrStop`。

新增 `init.d/memcached.service`：`Type=forking`，`ExecStart` 调 SysV 脚本而不是
直接拉二进制 —— 监听地址、端口、账号、容量和连接数都定义在 init 脚本里，
端口还要按 `lnmp.conf` 的 `Memcached_Port` 改写，在 unit 里再抄一份必然对不上。
`include/memcached.sh` 在 `StartUp` 之前无条件部署该 unit（放在
「已安装则跳过」分支之外，否则老机器仍然绕开 systemd），启动改为
`StartOrStop start memcached`。

同时把「这次走不走 systemd」的判断从 `StartOrStop` 里提出来成为
`Use_Systemd_Unit`，条件逐字保持不变，供安装收尾的状态核对复用。

实测（自定义端口 41211）：unit 已部署且 `systemctl is-enabled` 为 enabled；
`StartOrStop start memcached` 返回 0 后 `systemctl is-active` 为 active，
init 脚本 `status` 报 running，`ss` 在自定义端口看到 memcached；
`systemctl stop memcached` 之后 `is-active` 为 inactive 且进程数为 0，
证明 systemd 确实管住了该进程。`Use_Systemd_Unit` 对有 unit 的服务判为 systemd、
对不存在的服务判为 SysV。

- **验证状态**：已实测（Debian 12、Memcached 1.6.39，2026-08-11）。
- **范围说明**：该机未安装 PHP，`addons.sh install memcached` 在 PHP 扩展编译处
  以 `exit 1` 终止，未走到启动步骤；上述启动与状态核对是直接调用项目函数完成的。
  该终止行为已记入 `TODO-ADDONS-001`。

## AUDIT-FTP-002 Pure-FTPd 启动判断遗漏 WSL 与容器

**位置**：`pureftpd.sh` 安装收尾

`AUDIT-FTP-001` 的修复自己写了一套 systemctl 条件，只判断 `command -v systemctl`
和 unit 文件是否存在，没有像 `StartUp`、`StartOrStop` 那样排除 WSL 与容器，
且 systemctl 失败后不回落 SysV 而直接 `exit 1`。这类环境里 systemctl 可能存在
却不可用，本来能装完的机器会卡在这一步。

改为调用 `StartOrStop start pureftpd`，再按 `Use_Systemd_Unit` 的判定选择核对
方式：systemd 分支问 `systemctl is-active`，SysV 分支查 pid 文件对应的进程。
不使用 init 脚本的 `status`—— 它只打印文字、恒返回 0，已记入 `TODO-INITD-001`。

实测（控制端口 42121、数据端口 42020、被动范围 43000-43010）：`pureftpd.sh`
返回 0，`systemctl is-active` 与 `is-enabled` 均成功，部署后的配置里 `Bind`
与 `PassivePortRange` 为设定值，`ss` 在控制端口看到 pure-ftpd，
nftables 三条放行规则齐全。核对判据本身也做了两向验证：服务停止时返回 3，
运行时返回 0。

- **验证状态**：已实测（Debian 12、Pure-FTPd 1.0.54，2026-08-11）。
- **范围说明**：WSL 与容器环境未实测，该分支的依据是与 `StartUp`、`StartOrStop`
  共用同一个 `Use_Systemd_Unit` 判定。

## AUDIT-RUN-002 静态检查与新增防回归项

`t/lint.sh` C1-C16 与 T1 全部通过；`t/consistency.sh` V1-V11 通过 11 项、
失败 0 项；本轮改动过的脚本 `bash -n` 全部通过。

新增两项防回归检查，均做过注入验证：

- C16：并行编译任务数必须来自 `Build_Jobs`；
- V11：memcached 必须有 unit、必须走 `StartOrStop`、不得再直调 SysV 脚本，
  pureftpd 必须复用 `Use_Systemd_Unit`（移走 `init.d/memcached.service` 即报错）。

`todo.md` 删除已完成的 `AUDIT-DBSOURCE-001`，新增 `TODO-ADDONS-001`
与 `TODO-INITD-001`。

- **验证状态**：已验证（2026-08-11）。

## DOC-601 README 补充数据库编译方式的选择说明

**位置**：`README.md`「支持范围」

`FEAT-DBSRC-001` 改变了用户可见的行为：低于门槛的机器会被直接拒绝源码编译。
README 原先只在架构一节提过一句「源码编译耗时和内存占用更高」，没有给出
判断依据，也没有说明推荐哪一种。

补充一节：明确无特殊需求选通用二进制、列出本轮实测的编译目录与安装目录体积、
单进程内存峰值和 8 核并行被 OOM 的结果，写明脚本的两条拒绝门槛与一条确认门槛，
并给出非交互安装的完整命令示例。

- **验证状态**：已验证（文档与 `include/main.sh`、`include/profile.sh` 的实现逐条对照，
  数值取自本阶段实测，2026-08-11）。

## FIX-ADDONS-001 addons 安装前先确认有 PHP

**对应问题**：`TODO-ADDONS-001`。

`addons.sh` 装的都是要编进当前 PHP 的扩展。机器上没有 PHP 时，原流程会一路装到
扩展编译才失败，而那里是 `Make_Install || exit 1`，整个脚本当场退出：memcached
的服务端、init 脚本、systemd unit 和开机自启都已经装好，启动、防火墙和安装验收
却全部没执行，用户只看到一句失败，看不出装了一半。

新增 `Check_PHP_Installed`：检查 `${PHP_Path}/bin/php-config` 是否可执行，
缺失时说明「本脚本装的是 PHP 扩展」并给出两条安装 PHP 的命令，返回 1。
调用点放在 `install)` 分支开头，`uninstall)` 不拦 —— PHP 已被删掉的机器
仍然要能清理扩展残留。

Debian 12（未安装 PHP）实测：`addons.sh install memcached` 打印提示并返回 1，
`src/` 下没有产生任何组件源码目录，即一件也没开始装；
同一台机器上 `addons.sh uninstall memcached` 不受影响，正常执行到完成。

- **验证状态**：已实测（Debian 12，2026-08-11）。
- **范围说明**：只拦入口。各扩展安装函数内部的 `exit` 写法未改，
  其它原因导致的编译失败仍会中途退出，已记入 `TODO-ADDONS-002`。

## FIX-INITD-001 pure-ftpd 的 init 脚本返回码改为真实结果

**对应问题**：`TODO-INITD-001`。

`init.d/init.d.pureftpd` 的 `status()` 只按 pid 文件是否存在打印一行文字，
两个分支都不设返回码，最终返回最后一条 `echo` 的退出码，恒为 0；
`start()` 同样如此，启动失败时打印 " failed" 却返回 0；`case` 也不把函数的
返回码传出去。`lnmp pureftpd status` 在没有 systemd unit 的分支直接采用该退出码
（见 `conf/lnmp` 的 `Svc`），因此判断必然被误导。

改动：

- 新增 `is_running()`，一律以 pid 对应的进程是否存活为准，
  不再只看文件在不在（崩溃或 `kill -9` 之后 pid 文件会留下来）；
- `status()` 按 LSB 约定返回 0（在跑）或 3（没在跑）；
- `start()` 先清理陈旧 pid 文件，启动后轮询等待 pid 落地（`Daemonize yes`
  会立刻返回），据此返回 0 或 1；已在跑时直接返回 0，保持幂等；
- `stop()` 等待进程真正退出后才报成功，失败或本来没在跑返回 1；
- `case` 末尾补 `exit $?`，非法参数返回 2，用法提示补上 `status`。

Debian 12 实测九个分支：未运行 status=3；start=0；运行中 status=0；
重复 start=0 且进程数仍为 1；stop=0；重复 stop=1；非法参数=2；
写入一个指向已死进程的陈旧 pid 文件后 status 仍为 3 并报 not running；
从停止态 restart=0 且随后 status=0。
负向测试：临时移走 pure-ftpd 二进制后 `start` 返回 1（旧实现此处返回 0）。
测试结束后二进制已还原，服务恢复由 systemd 托管且 `is-active` 为 active。

- **验证状态**：已实测（Debian 12、Pure-FTPd 1.0.54，2026-08-11）。
- **范围说明**：`init.d/init.d.nginx`、`init.d.httpd`、`init.d.redis` 的返回码
  未在本轮核查，`init.d.memcached` 的 `status` 返回码本来就是真实的。

## AUDIT-RUN-003 新增 V12 防回归检查

`t/consistency.sh` 新增 V12：`init.d.pureftpd` 与 `init.d.memcached` 的 `status`
必须有 `return 3`、`init.d.pureftpd` 必须把返回码 `exit $?` 传出、
`addons.sh` 必须有 `Check_PHP_Installed || exit 1`。
注入验证：把 `init.d.memcached` 的 `return 3` 改成 `return 0` 即报错，改回通过。

`t/lint.sh` C1-C16 与 T1 全部通过；`t/consistency.sh` V1-V12 通过 12 项、
失败 0 项；改动过的脚本 `bash -n` 全部通过。
`todo.md` 删除已完成的 `TODO-ADDONS-001`、`TODO-INITD-001`，
新增 `TODO-ADDONS-002`。

- **验证状态**：已验证（2026-08-11）。

## FIX-ADDONS-002 扩展安装函数改用 return，退出码由入口统一交出

**对应问题**：`TODO-ADDONS-002`。

`addons.sh` 分发的十二个安装函数全部只被它自己调用，却一律用 `exit` 结束：
成功 `exit 0`、失败 `exit 1`、`Make_Install || exit 1`。任何一步失败都会让整个
脚本当场退出，跳过后面的启动、防火墙和安装验收，把机器停在半装状态。
`include/apcu.sh`、`include/imageMagick.sh` 和 `include/memcached.sh` 的收尾判断
还没有返回码，走到失败分支时最终返回的是 `rm`/`Echo_Red` 的 0 —— 报了 failed
却返回成功。

改动：

- `opcache.sh` 与七个 `php_*.sh`：函数内 `exit 0` / `exit 1` 改为
  `return 0` / `return 1`；
- `redis.sh`、`imageMagick.sh`、`memcached.sh`：`Make_Install || exit 1`
  改为 `|| return 1`；
- `imageMagick.sh`：`Build_ImageMagick_Lib` 的返回值改为必须处理
  （库没编出来就不再编扩展，否则报出来的是 configure 找不到目录，误导排查），
  收尾补 `return 0` / `return 1`；
- `apcu.sh`：收尾补 `return 0` / `return 1`；
- `memcached.sh`：扩展安装失败只记录 `ext_rc`，不再中断，后面的启动、防火墙
  和验收照常执行；收尾按「服务端」和「PHP 扩展」分别给结论，两者都成才返回 0；
- `addons.sh` 末尾补 `Addons_Rc=$?; exit ${Addons_Rc}`，把返回码明确交出去，
  不再依赖「最后一条命令恰好是那个函数」。

新增 `t/consistency.sh` V13：上述十二个文件里不得再出现独立的 `exit`，
且 `addons.sh` 必须传出返回码。规则做过两种写法的注入验证
（函数体内 `{ exit 1; }`、`Make_Install || exit 1`），都能报错。
第一版正则只覆盖行首和 `||` 前缀，漏掉花括号写法，已修正后重验。

Debian 12 实测：

- 没有 PHP 时 `addons.sh install opcache` 由入口拦下，返回 1；
- 造一个只提供 `php-config` 的假 PHP，让 `Install_Opcache` 真正执行到收尾：
  `opcache.so` 不存在 → 打印失败、返回 1，且失败时写入的 ini 已被清理；
- 同样条件下 `addons.sh install memcached`：返回 1，输出分成
  「memcached 服务端已安装并在运行」与「PHP 扩展 memcache.so 没有装成」两句；
  `systemctl is-active memcached` 为 active、自定义端口有监听、
  nftables 的 TCP/UDP 阻断规则都已写入 —— 说明扩展失败后流程没有中断，
  服务端该做完的都做完了，结论仍如实为失败。

- **验证状态**：已实测（Debian 12、Memcached 1.6.39，2026-08-11）。
- **范围说明**：opcache 与 memcached 两条路径实测；其余十个函数为同构改动，
  未逐个执行。`addons.sh` 内层 `case` 的未知子命令仍返回 0，
  已记入 `TODO-ADDONS-003`。

## FIX-INITD-002 nginx、httpd 的 init 脚本返回码与进程判定

**对应问题**：`TODO-ADDONS-003`，以及上一条记录里「三个 init 脚本返回码未核查」
的收尾。逐个核查了 `init.d.nginx`、`init.d.httpd`、`init.d.redis`，
`init.d.redis` 的 `status` 本来就返回 0/1/3，无需改动。

**`init.d/init.d.nginx`**

- `status` 两个分支的返回码是反的：服务停止时 `exit 0`，在跑时靠 `echo` 的
  退出码碰巧也是 0，等于无论状态如何都报成功。改为 LSB 约定的 0（在跑）/
  3（没在跑）。
- 进程判定原先是 `ps -ef | grep "$NGINX_BIN"`：命令行里出现过这个路径的进程
  全都算数，编辑器、`tail`、甚至一条带路径的 ssh 命令都会被当成 nginx 在跑 ——
  `status` 凭空报成功，`start` 则拒绝启动。改为新函数 `Nginx_Pid`：以
  `/usr/local/nginx/logs/nginx.pid` 为准并确认进程存活，pid 文件不可用时退回
  `pgrep -x nginx`（精确匹配进程名）。五个分支统一改用它。
  该 pid 路径在 `conf/nginx.conf`、`nginx_a.conf`、`openresty.conf` 三份配置里
  一致，OpenResty 经 `/usr/local/nginx` 软链同样成立。
- 已在运行时 `start` 由 `exit 1` 改为 `exit 0`，与 redis、pureftpd 一致；
  返回 1 会让重复执行的安装流程把正常情况当成失败。
- `reload` 原先无论 `nginx -s reload` 成败都打印 " done" 并返回 0。
  `conf/lnmp` 的 vhost 删除靠这一步让站点真正下线，失败必须传出去。

**`init.d/init.d.httpd`**

- `start|stop|restart|graceful|graceful-stop` 失败时只打印 " failed"，
  退出码是那条 `echo` 的 0，补 `exit 1`。
- `status` 两个分支都不设返回码（恒 0），且只看 pid 文件在不在 ——
  进程被 `kill -9` 之后文件会留下，把已经死掉的 Apache 报成 running。
  改为 pid 对应进程存活判定，返回 0 / 3。
- 未知参数由返回 0 改为 `exit 2`，与文件头部 apachectl 的退出码约定一致。

**`tools/remove_disable_function.sh`**

调用的是 `/etc/init.d/httpd -k restart`，而 init 脚本的 `case` 匹配的是
`start|stop|restart|...`，`-k restart` 落到 `*)` 只打印一行用法 ——
Apache 从来没有被重启过，以前返回 0 所以看不出来。改为 `/etc/init.d/httpd restart`
（`-k` 由 init 脚本自己加）。这个问题是 httpd 的 `*)` 改成 `exit 2` 之后暴露的。

**`addons.sh`**

两个内层 `case` 的 `*)` 打印 Usage 后返回 0，`./addons.sh install nosuchthing`
什么都没装却报成功。补 `exit 1`（外层 `*)` 本来就是 `exit 1`）。

**`t/consistency.sh`**

V12 扩展：nginx、httpd、redis 的 `status` 必须有 `exit 3`；
`addons.sh` 每条 Usage 提示后必须跟 `exit 1`。
注入验证：把 nginx 的 `exit 3` 改成 `exit 0` 即报错。

Debian 12 实测（nginx、Apache 未安装，用替身进程与改路径的脚本副本定向验证
被修改的判定分支）：

| 场景 | 结果 |
| --- | --- |
| nginx 无 pid 文件 `status` | 3 |
| nginx 陈旧 pid 文件（进程已死）`status` | 3 |
| nginx 进程存活 `status` | 0 |
| nginx 已在跑时 `start` | 0 |
| nginx 未运行时 `stop` | 1 |
| nginx 非法参数 | 1 |
| 命令行含 nginx 路径的无关进程存在时 `status` | 3（旧实现会报 running） |
| httpd 无 pid 文件 `status` | 3 |
| httpd 陈旧 pid 文件 `status` | 3 |
| httpd 进程存活 `status` | 0 |
| httpd 非法参数 | 2 |
| `addons.sh install nosuchthing` | 1 |
| `addons.sh uninstall nosuchthing` | 1 |

- **验证状态**：已实测（Debian 12，2026-08-11）。
- **范围说明**：nginx 的 `stop`（运行中）、`force-quit|kill` 和 `reload` 需要
  真实 nginx 才能覆盖，已记入 `TODO-INITD-002`；httpd 的 `start|stop` 失败传出
  同样未在真实 Apache 上执行。`t/lint.sh` C1-C16 与 T1 全部通过，
  `t/consistency.sh` V1-V13 通过 13 项、失败 0 项。

## FIX-INITD-003 nginx 进程判定：自我匹配与 pid 回收误杀

**对应问题**：`TODO-INITD-002`，以及在真实 nginx 上验证 `FIX-INITD-002` 时
发现的两个新问题。用 OpenResty 官方软件包装出真实 nginx（`ORMode=pkg`，
不编译，Debian 12 上约一分钟装完 openresty 1.31.1.1），本包的
`/etc/init.d/nginx` 由 `OpenResty_Post_Install` 正常接管。

**问题一：init 脚本把自己当成了 nginx**

`FIX-INITD-002` 把进程判定从 `ps -ef | grep` 换成 `pgrep -x nginx` 之后引入了
新的失效模式：Linux 上 shebang 脚本的 `comm` 是脚本名，而这个 init 脚本本身
就叫 `nginx`。于是 `pgrep -x nginx` 会匹配到脚本自己的进程，
`status` 在 nginx 根本没运行时报「nginx (pid …) is running」，
`stop` 与 `force-quit` 则 `kill` 掉自己 —— 实测退出码 143（SIGTERM），
终端出现 `Terminated`。

只加 `comm` 比对不能解决，因为脚本自己的 `comm` 恰好就是 `nginx`。

**问题二：pid 回收后误杀无关进程**

pid 文件里的号码可能已经被系统回收给别的进程。原判定只做 `kill -0`，
只能证明「这个号码上有进程」，而 `stop`、`force-quit` 是要 `kill` 它的。

**改动**：新增 `Nginx_Is_Nginx <pid>`，以 `/proc/<pid>/exe` 指向的可执行文件
与 `$NGINX_BIN` 比对（都经 `readlink -f` 解析软链，OpenResty 走
`/usr/local/nginx` 软链同样成立）。`/proc` 不可用时退回进程名比对，
并显式排除 `$$`。`Nginx_Pid` 的两条路径（pid 文件、`pgrep` 候选）都必须过这一关；
`pgrep` 分支还要跳过 worker（父进程也是 nginx），只认 master，
否则 `kill` 掉 worker 会被 master 立刻拉起来，`stop` 看着成功其实没停。

Debian 12 真实 nginx（openresty/1.31.1.1）实测：

| 场景 | 结果 |
| --- | --- |
| `start`（停止态） | 0，进程数 9（master + 8 worker） |
| `status`（运行中） | 0 |
| 重复 `start` | 0，进程数仍为 9，未新增实例 |
| `reload`（配置正常） | 0 |
| `reload`（配置损坏） | 1（旧实现返回 0） |
| `reload`（配置恢复） | 0 |
| `stop`（运行中） | 0，进程数 0，worker 全退 |
| `status`（已停） | 3 |
| `force-quit` | 0，master 与 worker 全退 |
| `restart`（停止态） | 0，进程数 9 |
| 空 pid 文件（包安装遗留）时 `status` | 3（未被自身进程匹配） |
| pid 文件指向非 nginx 的存活进程时 `force-quit` | 1，且该无关进程仍存活 |

安装 curl 后核对服务本身：默认站点目录为空时首页返回 403，
放入 `index.html` 后返回 200 且内容正确，`Server: openresty`。

- **验证状态**：已实测（Debian 12、openresty 1.31.1.1，2026-08-11）。
- **范围说明**：`stop` 走 `nginx -s stop` 失败转 `force-quit` 的那条支路未构造；
  Apache 侧的启停失败返回码仍未在真实 Apache 上验证，已记入 `TODO-INITD-003`。
  `t/lint.sh` C1-C16 与 T1 全部通过，`t/consistency.sh` V1-V13 通过 13 项。

---

## BK-RUN-002 backup init 站点可选、可改备份目录、run 支持指定站点

**位置**：`tools/lnmp-backup.sh`（`Cmd_Init`、`Select_Sites`、`Filter_Sites`、
`Cmd_Run`、`Notice_Review_Conf`、`Check_Backup_Home`）；`conf/lnmp`、`conf/lnmpa`、
`conf/lamp` 的用法帮助行。

**背景**：`init` 把扫描到的站点无条件全部写进配置，`default` 这类占位站点也会被
每天打包上传；`run` 只能整体执行，无法只备份某一个站点；备份目录、异地上传、加密
等默认值全写死在脚本里，用户第一次 `init` 后不看配置就会误以为已经异地备份。

**行为变化**：

- `init` 扫描到站点后进入挑选界面：回车全选；`1 3` 或域名只备份指定项；
  `-2` 或 `-default` 排除指定项。非交互（EOF）、非法输入连续三次、排除到空
  均安全兜底为全选或重问，通配符 `*` 不会被 glob 展开。
- `init` 新增“备份存放目录”询问，输入经 `Check_Backup_Home` 校验（绝对路径、
  非系统目录），同时用于写配置与建目录；原先建目录处硬编码的 `/home/backup`
  改为跟随该值。`Load_Conf` 的备份目录校验抽成同一个 `Check_Backup_Home`。
- `init` 结尾新增醒目提示块（`Notice_Review_Conf`），逐项列出仍是默认值的参数，
  并单列异地备份服务器需要填写的 `Remote_*` 各项与 sftp 密钥/指纹准备命令。
- `run` 支持 `run <域名>...`、`run db|web <域名>...`：只备份指定站点。
  只写域名等价 `run all <域名>`（不受网站备份周期限制）；任一域名对不上即整体
  失败并列出可用站点。部分备份不推进网站周期计时、不清理任何本地/远端旧批次。

**验证**：Debian 12 实机验证。
构造真实 nginx 多行 vhost（a.com/b.com/default，两个带 wp-config.php），
系统路径重定向到沙箱、`systemctl` 打空桩以不污染真实 systemd，mysql/mysqldump
用桩（库路径代码未改动）。端到端 26 项全过：init 排除 default、备份目录写入
输入值、配置 600、提示块含远端各项与 ssh-keyscan、systemd timer 小时正确；
`run all` 真实 tar 打包两站并 `sha256sum -c` 校验通过、真实解包内容正确、
清理旧批次；`run <域名>`/`run web|db <域名>` 只备份指定站点、不推进周期、
不清理旧批次；`run nosuch.com` 返回 1 并指明站点。另有 28 项站点挑选/过滤/
目录校验的定向单元测试全过。真实 `/etc/systemd/system` 未新增任何 unit。

数据库路径另在真实 MySQL 8.4.7 下验证 13 项全过：真实建库插数后 `run db`
用真实 mysqldump 转储（校验含 `-- Dump completed` 结束标记、含真实数据行）、
`SHA256SUMS` 校验通过；`test` 真实导入临时库校验后删除、无残留临时库；
篡改 `adb` 后 `restore db adb <批次>` 真实还原、行数与内容回到备份时点；
`run db <域名>` 只导出指定库。测试机库 root 口令为本次自行重置的已知值。

- **验证状态**：已实测（Debian 12 + MySQL 8.4.7，2026-08-11）。
  站点/目录/参数逻辑与库备份、试恢复、恢复均在真机真实组件上跑通。
- **范围说明**：`bash -n` 覆盖 `tools/lnmp-backup.sh` 与三个管理脚本；
  `t/lint.sh` C1-C16、T1 全部通过。大库压力与真实 SFTP/FTP 远端上传不在本次
  范围（见 `todo.md` TODO-BK-001、TODO-BACKUP-FTP-001）。README.md「3.3 备份」
  与 HowtoGuides.md「8.4 备份」已同步说明挑选站点、备份目录询问与 `run <域名>`。

# 阶段 29 - phpMyAdmin 后装与访问开关（2026-08-12）

## PMA-INSTALL-001 主栈安装后可单独补装 phpMyAdmin

**行为变化**：

- 新增 `./install.sh phpmyadmin`。完整 LNMP/LNMPA/LAMP 安装仍由
  `lnmp.conf` 的 `Enable_PhpMyAdmin` 控制，默认值保持 `n`；单独补装不会修改
  `lnmp.conf`。
- 补装识别现有栈与 PHP/mysqli 条件，复用校验下载，分阶段部署并生成随机入口；
  Web 配置测试、重载、产物检查或 HTTP 冒烟任一步失败都会回滚。
- `config.inc.php` 使用 `127.0.0.1` TCP 连接，并把 `lnmp.conf` 的 `DB_Port`
  写入 `Servers.port`，避免 `localhost` 改走 Unix socket 而忽略自定义端口。
- HTTP 冒烟在 Web reload 后有限重试 5 次，覆盖旧 worker 短暂返回 404 的切换窗口。

**真机验证**：Debian 12、OpenResty、PHP 8.3.33、MySQL 环境执行
`./install.sh phpmyadmin`，官方归档 SHA-256 校验通过，Nginx 配置测试通过，
随机入口返回 HTTP 200 和登录页，固定 `/phpmyadmin/` 返回 404；生成配置的主机、
端口分别为 `127.0.0.1` 和 `lnmp.conf` 当前 `DB_Port`，占位符全部清除。
重复安装返回 1 且未覆盖现有文件。首次单次冒烟复现 reload 窗口 404，加入有限
重试后同一流程退出 0。

- **验证状态**：已实测（Debian 12，2026-08-12）。

## PMA-ACCESS-001 phpMyAdmin 访问可关闭和恢复，程序不卸载

**行为变化**：

- 三种管理脚本均支持 `lnmp phpmyadmin enable|disable|status`；源码目录也支持
  `./install.sh phpmyadmin enable|disable|status`。
- `disable` 把 Web 映射移动到 Web 配置目录中的隐藏停用文件，测试配置并重载；
  `/usr/local/phpmyadmin`、`config.inc.php` 和随机入口文件均保留。
- `enable` 恢复原映射并测试、重载；配置测试或重载失败时恢复切换前状态。
- 对旧版已安装环境执行补装时，事务式补齐 `/bin/lnmp` 子命令与
  `/bin/lnmp-phpmyadmin`，失败与主安装一起回滚。

**真机验证**：开启状态入口返回 200；执行 `disable` 返回 0，入口返回 404，
程序、随机入口及数据库端口配置保持不变；执行 `enable` 返回 0，入口恢复 200
并包含登录页标识；再次关闭后保持 404。故意写坏 Nginx 主配置再开启，命令返回
1，停用映射恢复且入口仍为 404；恢复主配置后 `nginx -t` 通过。最终测试环境
保留 PHP、phpMyAdmin 程序和 nftables，并将 phpMyAdmin 入口保持关闭。

- **验证状态**：已实测（Debian 12，2026-08-12）。

## PMA-RUN-001 定向回归与全仓检查

- `bash -n` 覆盖安装、升级、卸载、三种管理脚本、辅助脚本和定向测试。
- `/usr/local/php/bin/php -l conf/config.inc.php` 通过。
- `t/test_install_phpmyadmin.sh` 覆盖默认值、入口退出码、重复安装、回滚、端口传播、
  reload 重试、三种栈管理命令和访问开关失败恢复，全部通过。
- `t/lint.sh` 与 `t/consistency.sh` 的项目脚本语法和其它规则通过；测试机 `src/`
  下解压的第三方 Boost、memcache、PHP 源码及构建产物触发 C13、C16、V7，属于
  工作目录内第三方文件扫描噪音，因此不记为全仓检查通过。

- **验证状态**：定向功能已实测；全仓检查存在上述第三方源码命中（2026-08-12）。

# 阶段 30 - GitHub Actions 下载清单与维护文档（2026-08-12）

## GHA-URL-001 下载探测与安装回退链保持一致

- `include/version.sh` 恢复 `Boost_Ver='boost_1_77_0'` 和
  `Boost_New_Ver='boost_1_84_0'`，只供 `t/probe_urls.sh`、
  `t/gen_checksums.sh` 维护下载探测与校验清单。
- MySQL 安装逻辑不变：安装所需 Boost 仍从源码树的 `cmake/boost.cmake`
  动态解析，没有恢复 `CLN-302` 删除的 `pinned` 分支。
- Boost URL 的点号版本和包名均由变量推导，不再保留 1.59/1.67 的陈旧地址。
- MySQL 探测和全量校验采集改为与 `DB_Download_Files` 相同的顺序：先访问
  `cdn.mysql.com/Downloads`，失败后回退到 `cdn.mysql.com/archives`。

**验证**：Debian 12 上执行相关文件 `bash -n`、`t/lint.sh`、
`t/consistency.sh`、`t/test_profile.sh`、`t/test_bump.sh` 均通过；
`LIST_ONLY=1 bash t/gen_checksums.sh` 正确生成 Boost 1.77.0/1.84.0 和 MySQL
8.0.46/8.4.7 清单。联网执行 `t/probe_urls.sh`，69 个地址全部可达；另行确认
MySQL 8.4.7 archives 源码包、二进制包及两个 Boost 官方包均可达。全仓检查前暂移
验证机已有的第三方解压源码，测试后原样恢复，验证机 Git 状态保持干净。

- **验证状态**：已实测（Debian 12，2026-08-12）。

## DOC-GHA-001 整理工作流说明

- 重写 `.github/WORKFLOWS.md`，按五个现有工作流说明触发条件、执行内容、失败结果、
  手动参数、发布规则和首次配置。
- 删除重复背景说明，补充 MySQL 回退链及两个 Boost 变量的用途边界。

- **验证状态**：已静态核对五份 workflow 配置（2026-08-12）。

# 阶段 31 - phpMyAdmin 完整安装与上游升级检查收尾（2026-08-12）

## PMA-FIX-003 管理入口复用同一份访问开关实现

- 删除 `include/php.sh` 中重复的 `Set_PhpMyAdmin_Access`；
  `./install.sh phpmyadmin enable|disable|status` 改为调用安装后的
  `/bin/lnmp-phpmyadmin`，默认安装逻辑和命令行为不变。
- `t/test_install_phpmyadmin.sh` 覆盖三种子命令的转调和退出码；Debian 12 上实际执行
  `bash install.sh phpmyadmin status`，命令正确转交并返回 0。

- **验证状态**：已实测（Debian 12，2026-08-12）。

## PMA-FIX-004 完整安装路径按部署结果返回

- `Creat_PHP_Tools` 对解压、复制配置、占位符替换、随机值生成、权限调整和最终移动
  逐步检查返回码；先在临时目录完成部署，失败时清理临时及不完整产物。
- LNMP、LNMPA、LAMP 三条完整安装路径都会接收该返回码，不再在 phpMyAdmin
  部署失败后继续打印成功信息。
- `t/test_install_phpmyadmin.sh` 增加完整安装故障注入；损坏归档会返回非零，且目标
  目录没有残留。

- **验证状态**：已实测（Debian 12，2026-08-12）。

## UPSTREAM-FIX-001 上游取数失败会阻止自动升级 PR

- `t/check_upstream.sh` 在任一上游取数失败时返回非零，工作流随即停止，不再继续
  应用版本、重算校验值或创建 PR。
- 新增 `t/test_upstream.sh`，用故障注入确认网络取数失败时退出码非零；该测试已加入
  CI 和发布工作流。

- **验证状态**：stub 故障注入与工作流配置检查通过（2026-08-12）。

## UPSTREAM-FIX-002 补全 PINNED 版本说明

- 原先未归类的 Apache 依赖、nginx 模块、Lua 库及旧 PHP 扩展全部列入报告的
  `PINNED` 表，写明保留现有版本的原因；没有新增 `AUTO` 升级范围。
- `Boost_Ver`、`Boost_New_Ver` 继续只供下载探测和校验清单使用；MySQL 安装所需
  Boost 仍从源码树动态读取。
- libunwind 自动检查限定为最新 `1.x`，当前保持 `1.8.3`，不会采用上游不属于当前
  发布线的 `4.0.10` tag。

- **验证状态**：静态覆盖测试通过；Debian 12 联网上游检查确认 libunwind 无跨主版本
  更新（2026-08-12）。

## UPSTREAM-FIX-003 MySQL 候选版本同时检查源码包和默认二进制包

- MySQL 8.0 候选同时检查源码包和 glibc 2.28 x86_64 包；MySQL 8.4 候选同时检查
  源码包和 glibc 2.17 x86_64 包。两者都存在才提出升级；404 视为候选未发布，
  网络错误或其它 HTTP 错误视为检查失败。
- 定向测试确认“只有源码包”的候选不会被采纳，取数错误会返回非零。
- Debian 12 完整联网检查退出 0，结果为 `AUTO 2 / COUPLED 0 / MANUAL 0 / 取数失败 0`，
  正常识别 MySQL 8.4.10 和 Memcached 1.6.45。

- **验证状态**：stub 与真实上游检查均通过（Debian 12，2026-08-12）。

## UPSTREAM-FIX-004 增量替换按组件限定范围

- `.upstream/changed.tsv` 每行改为记录组件键、旧值和新值；
  `t/bump_version.sh` 的探测清单替换和 `t/refresh_checksums.sh` 的校验行选择均按组件
  限定，不再以裸版本号全局匹配。
- 碰撞测试使用相同的 PHP 与 MariaDB 点版本，确认只更新目标 PHP 条目，不改动
  MariaDB；相关失败注入也已覆盖。

- **验证状态**：`t/test_bump.sh` 定向回归通过（Debian 12，2026-08-12）。

## UPSTREAM-RUN-001 定向回归与联网检查

相关脚本 `bash -n` 通过；`t/lint.sh`、`t/consistency.sh`、`t/test_profile.sh`、
`t/test_dispatch.sh`、`t/test_audit_fixes.sh`、`t/test_install_phpmyadmin.sh`、
`t/test_upstream.sh`、`t/test_bump.sh` 全部通过。另修正 gperftools 的 tag 解析，按上游
实际的 `gperftools-*` 前缀取数；单组件联网检查和完整联网检查均返回 0。

- **验证状态**：已实测（Debian 12，2026-08-12）。

# 阶段 32 - 阶段 31 的复核返工（2026-08-12）

对阶段 31 的七项改动做代码复核，五项结论成立，两项存在缺陷，另发现四处同类残留。
以下为返工内容，全部在 Debian 12 上实测。

## FIX-CHK-001 校验清单刷新会把相邻两条拼成一行

**位置**：`t/refresh_checksums.sh` 的原位替换

**问题**：替换正则的行尾用了 `\s*$`。`\s` 含换行且贪婪，会连行尾的 `\n` 一起匹配，
而替换串不带换行，结果本行与下一行被拼成一行 —— 涉及的两条校验值同时失效。
`include/main.sh` 的 `Verify_Download_File` 取值用 `awk '$2 == 文件名'` 精确匹配，
合并行一条都命中不了，安装会在下载完成后 fail-closed 中止并删掉刚下好的文件。
`upstream-check.yml` 正是在开 PR 前调用它，产出会直接进 PR。

漏检原因：`t/test_bump.sh` 的碰撞用例与 `t/consistency.sh` 的 V4 都用子串匹配，
合并后的那一行照样命中，两者均报通过。

**改动**：

- 行尾改用水平空白 `\h`；`perl` 替换失败计入 `failed` 并跳过该条。
- 写回前核对清单格式，出现非法行一律放弃写回并返回非零。
- `t/test_bump.sh` 的断言改为整行匹配加行数核对，并新增「坏清单拒绝写回」用例。
- `t/consistency.sh` 新增 V14：清单每行必须是
  `<64位sha256><两个空格><文件名>`，且落地文件名不得重复。V4 查覆盖率、
  V14 查格式，两者互补。

**验证**：修复前同一场景产出 1 行、合法行 0 条，精确查表命中 0 条；修复后产出
2 行、合法行 2 条，两个文件名均精确命中。把真实清单的第 82、83 行人为合并后，
V4 仍报通过，V14 准确指出第 82 行非法。

- **验证状态**：已实测（Debian 12，2026-08-12）。

## FIX-PMA-005 OpenResty 完整安装的 phpMyAdmin 入口不生效

**位置**：`conf/openresty.conf`

**问题**：`conf/nginx.conf`、`conf/nginx_a.conf` 和两份 httpd 模板都带
`include phpmyadmin.*.conf;` 钩子，只有 `conf/openresty.conf` 没有，而
`include/openresty.sh` 会把它整份覆盖成 `nginx.conf`。于是
`WebServer=openresty` 且 `Enable_PhpMyAdmin=y` 的完整安装：程序部署成功、
访问片段写入成功、安装返回 0，但主配置从不 include 该片段，入口返回 404。
`Creat_PHP_Tools` 不调用 `Ensure_PhpMyAdmin_Config_Hooks`（那是补装路径动态补钩子用的），
所以完整安装完全依赖模板自带这一行。

**改动**：`conf/openresty.conf` 在 `include enable-php.conf;` 之后补上同样的钩子，
位置与 `conf/nginx.conf` 一致。`t/test_install_phpmyadmin.sh` 新增断言，
五份默认站点模板都必须带钩子。

**验证**：线上 `nginx.conf` 与修复前的仓库模板 `diff` 只差这一行。行为实测
（每次 reload 后连采多次取稳定值）：片段存在时，用修复前的模板入口稳定 404，
用修复后的模板稳定 200，换回线上配置仍为 200。

- **验证状态**：已实测（Debian 12、OpenResty 1.31.1.1，2026-08-12）。

## FIX-UPS-005 lua 全家桶的取数失败被写成了上游结论

**位置**：`t/check_upstream.sh` 的 `check_lua_stack`

**问题**：`lua-resty-core` 的 tag 列表取空、或逐个 tag 取 `base.lua` 失败时，
都只是让匹配结果为空，随后被写成「lua-nginx-module 有新版，但尚未找到声明配套的
lua-resty-core，整组保持不动」，计入 COUPLED，`errors` 不加，退出码仍为 0。
这正是 `UPSTREAM-FIX-001` 要堵的那一类：检查没做成，却产出了一条结论。

**改动**：tag 列表取空走 `require_value` 计入 `errors`；`base.lua` 有取数失败且
最终没有匹配到版本时同样计入 `errors` 并返回，不再写「上游没有配套版本」。

**验证**：分别注入 tag 列表取数失败和 `base.lua` 取数失败，两种情况均返回非零，
且报告中不再出现「尚未找到声明配套的 lua-resty-core」。

- **验证状态**：已实测（Debian 12，2026-08-12）。

## FIX-UPS-006 组件取数失败不再中断后续组件的检查

**位置**：`t/check_upstream.sh` 的 `check_misc`、`check_lua_stack` 尾部

**问题**：各组件用 `require_value ... || return 0`，而它们同处一个函数中，
任何一个取数失败都会整体返回。实测 Apache 目录取数失败后，
redis 与 memcached 的地址一次都没被请求 —— 报告里区分不出「没有新版」和
「根本没查」。`check_mariadb` 用的是 `|| continue`，两处写法本就不一致。

**改动**：改为 `if require_value ...; then propose ...; fi`，失败只跳过该组件。
失败仍由 `require_value` 计入 `errors`，整体退出码不变。
`lua-resty-lrucache` 与 `luajit2` 同样互不阻断。

**验证**：注入 Apache 取数失败后退出码仍为非零，且 redis、memcached 的地址
确实被请求过。完整联网检查返回 0，结果为 `AUTO 2 / COUPLED 0 / MANUAL 0 /
取数失败 0`，与返工前一致。

- **验证状态**：已实测（Debian 12，2026-08-12）。

## FIX-URL-003 探测清单补上 OpenResty 源码包

**位置**：`t/probe_urls.sh`

`include/openresty.sh` 与 `include/upgrade_openresty.sh` 在源码编译方式下会下载
`openresty.org/download/<版本>.tar.gz`，该地址此前不在探测清单内。它只有 PGP 签名、
不进 `src/checksums.sha256`（`consistency.sh` V4 对此有豁免），但上游同样会下线
旧点版本，可达性仍需探测。

**验证**：联网执行 `t/probe_urls.sh`，70 个地址全部可达，返回 0。

- **验证状态**：已实测（Debian 12，2026-08-12）。

## FIX-PMA-006 phpMyAdmin 部署路径的删除保护与状态清理

**位置**：`include/php.sh` 的 `Creat_PHP_Tools`、`Config_PhpMyAdmin_Access`、
`Rollback_PhpMyAdmin_Install`

**行为变化**：

- 新增 `Remove_PhpMyAdmin_Dir`：变量为空或为 `/` 时不动手。`Creat_PHP_Tools`
  原有两处 `rm -rf ${PhpMyAdmin_Dir}` 既没加引号也没有这层保护，
  `Rollback_PhpMyAdmin_Install` 里的同一段判断改为复用该函数。
- `Config_PhpMyAdmin_Access` 重建入口时一并删除遗留的停用片段
  `.phpmyadmin.enable.conf.disabled`。此前完整安装会在停用片段仍存在的情况下
  写出启用片段，两者并存后 `lnmp phpmyadmin enable|disable` 判定状态不明、
  返回 1 并要求人工处理（补装路径 `Install_Only_phpMyAdmin` 本就有前置检查，
  完整安装路径没有）。
- `Config_PhpMyAdmin_Access` 的片段写入、`chmod` 现在逐步判返回码；
  一个片段都没写出来（既没有 Nginx 也没有 Apache 的配置目录）时返回 1，
  不再走完两个都不成立的 `if` 而返回 0。

**验证**：停用状态下调用 `Config_PhpMyAdmin_Access` 返回 0，启用片段生成、
停用片段被清除，`nginx -t` 通过，`lnmp phpmyadmin status` 与 `disable` 均恢复正常
（并存时实测为 rc=1 拒绝执行）。

- **验证状态**：已实测（Debian 12，2026-08-12）。

## RUN-032 复核回归

- `bash -n` 覆盖本轮改动文件与安装、升级、卸载、三种管理脚本、辅助脚本。
- `t/lint.sh`、`t/consistency.sh`（14 项全过）、`t/test_profile.sh`、
  `t/test_dispatch.sh`、`t/test_audit_fixes.sh`、`t/test_bump.sh`、
  `t/test_upstream.sh`、`t/test_install_phpmyadmin.sh` 全部返回 0。
- 联网 `t/probe_urls.sh` 70/70 可达返回 0；联网 `t/check_upstream.sh` 返回 0。
- 测试机在验证前后状态一致：`nginx.conf` 与备份逐字节相同，phpMyAdmin
  入口保持关闭，临时备份文件已删除。

- **验证状态**：已实测（Debian 12，2026-08-12）。

**阶段 31 中经复核成立、未作改动的部分**：`PMA-FIX-003` 的开关去重
（`Set_PhpMyAdmin_Access` 已无残留，三份管理脚本的栈参数正确）、
`PMA-FIX-004` 的返回码链路（三条完整安装路径均接收返回码并经
`PIPESTATUS[0]` 传出）、`UPSTREAM-FIX-002` 的 PINNED 覆盖
（`include/version.sh` 全部变量已逐个核对，无遗漏）、`UPSTREAM-FIX-003`
的 MySQL 探测（说明与实现一致，glibc 映射与 `profile.sh`、`t/probe_urls.sh`
三处一致）、`UPSTREAM-FIX-004` 的组件锚定、`GHA-URL-001` 的 MySQL 回退链。

# 阶段 33 - phpMyAdmin 连接参数取本机实际值（2026-08-12）

## FIX-PMA-007 补装与升级按机器实际数据库端口写配置

**位置**：`include/main.sh` 新增 `Get_Actual_DB_Port`；
`include/php.sh` 的 `Install_Only_phpMyAdmin`、
`include/upgrade_phpmyadmin.sh` 的 `Upgrade_phpMyAdmin`

**问题**（原 `todo.md` 的 TODO-PMA-002）：`lnmp.conf` 里是
`DB_Port="${DB_Port:-3306}"`，装主栈时可以用环境变量指定非默认端口
（`DB_Port=3307 ./install.sh lnmp`），该值写进 `/etc/my.cnf` 但不回写
`lnmp.conf`。事后单独补装或升级 phpMyAdmin 时环境变量已不在，读到的仍是
默认值，填进 `config.inc.php` 就是错的。而该文件用 `host = 127.0.0.1` 走 TCP
（不用 `localhost` 以免 mysqli 改走 UNIX socket 绕过端口设置），端口错了直接
连不上库；`Smoke_Test_PhpMyAdmin_HTTP` 只校验页面里出现 phpMyAdmin 字样，
登录页本身不连库，因此这种故障会被判成安装成功，用户点登录才会发现。

**行为变化**：

- 新增 `Get_Actual_DB_Port [配置文件]`：读 `/etc/my.cnf` 的 `[mysqld]` 段取
  `port`，取不到或取值非法时退回 `lnmp.conf` 的 `DB_Port`；返回 0 表示取自
  配置文件，返回 1 表示用的是退回值。只认 `[mysqld]` 段 ——`[client]` 段那条
  是客户端默认值，管理员可能单独改过。MySQL 与 MariaDB 的模板都写在
  `/etc/my.cnf`，取法相同。参数只为定向测试传入替身配置。
- 补装与升级两处改用该值填 `LNMP_DB_PORT`，并在实际值与 `lnmp.conf` 不一致、
  或未能读到配置文件时打印提示。
- 完整安装路径 `Creat_PHP_Tools` 仍用本次安装选定的 `DB_Port`：那条路径上
  数据库就是本次按该值装的，`/etc/my.cnf` 可能还是上一次安装的遗留。
- 升级路径补上替换后的占位符残留检查，与首装路径一致。

**验证**：`t/test_db_port.sh` 覆盖 13 种取值情形全部通过：`[mysqld]` 与
`[client]` 不同时取前者、行内注释、制表符分隔、段名带空白、同段重复取最后一条、
后续段不干扰、文件缺失、空文件、非数字、越界、端口为 0、`report_host` 这类
前缀相同的选项不误取。

真机验证：测试机 `/etc/my.cnf` 的 `[mysqld] port = 13306`，`ss` 显示数据库
确实监听 `127.0.0.1:13306`，而 `lnmp.conf` 读出来是 3306。该机上已装的
phpMyAdmin（经补装路径安装）配置里写的正是 `'port' => '3306'`。
按同一条 TCP 路径实测：`-P 3306` 返回 `ERROR 2003 Can't connect (111)`，
`-P 13306` 返回 `ERROR 1045 Access denied` —— 前者端口上没有服务，后者连上了
只是账号不对。修复后 `Get_Actual_DB_Port` 在该机返回 13306。

- **验证状态**：已实测（Debian 12 + MySQL，2026-08-12）。

## FIX-PMA-008 配置入口锚定 default_server 块的 root 指令

**位置**：`include/php.sh` 的 `Ensure_PhpMyAdmin_Config_Hooks`

同一类问题的另一半：插入 `include phpmyadmin.*.conf;` 时，原实现用
`lnmp.conf` 的 `Default_Website_Dir` 去精确比对 nginx.conf 里的
`root  <目录>`，老环境自定义过网站目录时匹配不上，补装会在写配置前中止。
改为锚定 `default_server` 块内的 `root` 指令本身，不比对具体目录 ——
这里要的只是"插进默认站点块里"，root 的值无关紧要。定位失败时的报错
补上具体条件，说明需要一个带 `default_server` 且块内有 `root` 的 server 块。

- **验证状态**：已实测（Debian 12，2026-08-12）；定向断言已加入
  `t/test_install_phpmyadmin.sh`。

## RUN-033 回归

`bash -n` 覆盖本轮改动文件与安装、升级、卸载、三份管理脚本、辅助脚本；
`t/lint.sh`、`t/consistency.sh`、`t/test_profile.sh`、`t/test_dispatch.sh`、
`t/test_audit_fixes.sh`、`t/test_bump.sh`、`t/test_upstream.sh`、
`t/test_db_port.sh`、`t/test_install_phpmyadmin.sh` 全部返回 0。

- **验证状态**：已实测（Debian 12，2026-08-12）。

# 阶段 34 - redis-cli 未上 PATH、管理命令启停无回显（2026-08-12）

## FIX-REDIS-005 redis-cli 未链接到 /usr/bin，裸命令找不到

**位置**：`include/redis.sh` 的 `Install_Redis`、`Uninstall_Redis`

**问题**：`mysql`、`nginx`、`memcached` 装完都会 `ln -sf` 一份客户端/主程序到
`/usr/bin`，唯独 Redis 没有。`HowtoGuides.md` 的验证步骤和用户实际操作都是
裸命令 `redis-cli ping`，装完直接执行报 `redis-cli: command not found`，
只能用户自己想到用绝对路径 `/usr/local/redis/bin/redis-cli`。

**行为变化**：

- `Install_Redis` 两条分支（首次编译安装、检测到已装过跳过编译）都补上
  `ln -sf /usr/local/redis/bin/redis-cli /usr/bin/redis-cli`，覆盖“先跑过一次
  装 redis-server 失败又重跑”和“重复执行 addons.sh install redis”两种情形，
  保证幂等。
- `Uninstall_Redis` 对应删除该软链接，避免卸载后残留一个指向已删除文件的
  失效链接。

**验证**：`bash -n include/redis.sh`；`t/lint.sh` 全部通过；人工核对同一文件里
`mysql.sh`/`nginx.sh`/`memcached.sh` 的现有 `ln -sf` 写法与新增两处一致。

- **验证状态**：已验证（静态）；未在真机上重新执行 `addons.sh install redis`
  验证符号链接生效，待人工真机验证。

## FIX-OPS-003 lnmp 管理命令 reload/restart 悄无声息，且每次都打印横幅

**位置**：`conf/lnmp`（顶部横幅、`Svc`/`Svc_Feedback`、`nginx`/`mysql`/
`mariadb`/`php-fpm`/`pureftpd` 各 case 分支）

**问题**（用户实测反馈）：`lnmp nginx reload`、`lnmp nginx restart`、
`lnmp php-fpm restart` 执行后没有任何成功/失败提示，屏幕上只有开头固定打印
的 `Manager for LNMP, Written by Licess` 横幅，看起来像命令什么都没做。
根因有两处叠加：一是顶部横幅在脚本入口无条件打印，与命令是否成功无关；
二是 `Svc()` 在 systemd 存在时直接调用 `systemctl <action> <service>.service`，
这是 systemd 的正常行为——成功不输出任何内容——原实现没有替它补一句人话。

**行为变化**：

- 删掉顶部固定横幅（4 行 `echo`），所有子命令的输出不再被这段与结果无关的
  内容占用。
- 新增 `Svc_Feedback <服务> <动作>`：包一层 `Svc`，用已有的 `Echo_Green`/
  `Echo_Red` 按返回码打印“服务 动作 成功”或“服务 动作 失败（退出码 N）”，
  `status` 动作跳过（它自己已经打印完整状态，不需要再叠加一句）；返回码原样
  透传。
- `nginx`/`mysql`/`mariadb`/`php-fpm`/`pureftpd` 五个 case 分支从直接调用
  `Svc` 改为调用 `Svc_Feedback`，并显式 `exit $?`，命令行退出码与提示信息
  一致。
- `lnmp_start`/`lnmp_stop`/`lnmp_reload`（无参数的 `lnmp restart` 等）内部
  仍直接调用 `Svc`，不受影响——那几条路径本来就有 `Check_Svc_State` 或
  自己的 `echo`，不在本次用户反馈范围内，未改动。

**验证**：`bash -n conf/lnmp`；`t/lint.sh` 的 T1 语法检查通过。用假 `id`
（返回 0 绕过 root 检查）加真实环境跑 `lnmp nginx reload`、
`lnmp php-fpm restart`、`lnmp nginx status`，确认：横幅不再出现；
`reload`/`restart` 在 systemd/init.d 都不可用时打印红色失败提示且退出码为
非零；`status` 不叠加提示。另用桩函数单独跑 `Svc_Feedback` 覆盖成功
（返回 0，绿色“成功”）、失败（返回 1，红色“失败（退出码 1）”）、
`status` 跳过三种分支，行为符合预期。未在装有真实 nginx/php-fpm 的机器上
验证 systemctl 成功路径的输出，待人工真机验证。

- **验证状态**：已验证（静态 + 模拟）；systemctl 成功路径待人工真机验证。

## DOC-701 HowtoGuides 补上 Redis 设密码的具体步骤

**位置**：`HowtoGuides.md` 第三节（安装 Redis）

**问题**：原文只在安全提示里说“必须先设 requirepass”，没给怎么设的具体命令；
用户看完提示仍然不知道该改哪个文件、改完要不要重启、改完怎么验证生效，
以及改完之后 WordPress 侧的 `redis-cache` 插件要不要跟着改。

**行为变化**：在原有安全提示后新增一段可直接执行的步骤：
`openssl rand -base64` 生成随机密码 → 用 `sed` 删除已有的
`requirepass` 行（不管是默认注释掉的还是之前设过的，用一条正则同时覆盖，
不依赖不同 Redis 版本注释原文的具体措辞）→ 追加新的 `requirepass` 行 →
`/etc/init.d/redis restart` → 用 `redis-cli ping`（应被拒绝）和
`redis-cli -a "$REDISPW" ping`（应返回 PONG）验证生效；并提示同步在
`wp-config.php` 的 Redis 常量块里加 `WP_REDIS_PASSWORD`，否则插件仍按
无密码连接，会直接报连接失败。

**验证**：`sed` 删除+追加的写法在沙箱里对模拟的 `redis.conf`（含
`# requirepass foobared` 注释行）验证过一次替换与二次替换（模拟密码轮换）
都只留一行 `requirepass`，无重复、无残留注释。文档本身不改代码，无需
`bash -n`。

- **验证状态**：已验证（静态：sed 命令逻辑经沙箱验证；文档步骤本身未在
  真实 Redis 实例上走一遍，待人工真机验证）。

## FIX-OPS-004 tools/*.sh 安装后权限未自动补成可执行

**位置**：`include/end.sh` 的 `Install_LNMP_Command`（`Add_LNMP_Startup` /
`Add_LNMPA_Startup` / `Add_LAMP_Startup` / `Install_Only_Nginx` 共用同一处）

**问题**：`tools/` 目录下除 `lnmp-backup.sh`/`lnmp-tgnotice.sh`/
`lnmp-phpmyadmin.sh`（这三个会被复制到 `/bin/` 并单独 `chmod +x`）之外的
运维脚本，在源码树里一直是 644（git 不记录可执行位）。README.md 和
HowtoGuides.md 里这些脚本都是按 `./tools/xxx.sh` 或
`/root/lnmp2.3/tools/xxx.sh` 直接调用，装完之后照着文档跑会直接
`Permission denied`，此前需要用户手工 `chmod +x`。

**行为变化**：`Install_LNMP_Command` 在原有的 `/bin/lnmp*` 复制流程之后，
新增 `chmod 755 "${cur_dir}"/tools/*.sh`，失败时只打印
`Echo_Red` 提示（给出手动补权限的命令），不阻断安装——这一步在完整安装
流程的末尾，前面的服务已经装完并起来了，不应该因为补权限失败就让整个
安装报错。三个 `Add_*_Startup` 和 `Install_Only_Nginx` 都经同一个
`Install_LNMP_Command`，改动只有一处，无需在各安装入口分别打补丁。

**验证**：`bash -n include/end.sh`；`t/lint.sh` 的 T1 语法检查通过；
`t/test_bumpversion.sh` 用 `unshare` 的 mount 命名空间 + overlayfs 隔离
`/bin`、`/etc`（写入只落在覆盖层，不碰宿主机真实文件），实跑
`Install_LNMP_Command` 后确认 `tools/*.sh` 全部变成 755，且这一步失败时
（`grep -q Echo_Red`）会走告警分支而不是静默吞掉。

- **验证状态**：已验证（沙箱内实跑 + 静态检查）。

## DEV-001 新增 bumpversion.sh：开发环境同步已安装的管理命令

**位置**：根目录 `bumpversion.sh`（新增）

**问题**：开发时改了 `conf/lnmp`/`conf/lnmpa`/`conf/lamp` 或
`tools/lnmp-backup.sh` 等文件后，要验证效果必须手工把它们覆盖到
`/bin/lnmp`、`/bin/lnmp-backup`、`/bin/lnmp-tgnotice`、
`/bin/lnmp-phpmyadmin`，且要记得同时补权限，测试环境下重复几次很容易漏做
或做错。

**行为变化**：新增 `bumpversion.sh`，用法 `./bumpversion.sh [lnmp|lnmpa|lamp]`。
不复制/重写任何安装逻辑，只是：确认以 root 运行、确认当前目录是 lnmp
源码树（有 `conf/`、`tools/`、`include/end.sh`）、确认 `/bin/lnmp` 已存在
（否则提示先跑 `install.sh`），再决定目标栈——带参数则校验后直接用，不带
参数时用 `/bin/lnmp` 里 `lnmpa_start()`/`lamp_start()` 函数名标记自动识别
当前装的是哪个栈，识别不出按 `lnmp` 处理——最后 `source`
`include/main.sh`、`include/end.sh` 并直接调用已有的
`Install_LNMP_Command`，同步完再检查四个目标文件是否都存在且可执行。
线上安装、升级流程都不会调用这个脚本。

**验证**：`bash -n bumpversion.sh`；`t/lint.sh` 的 T1 语法检查通过；新增
`t/test_bumpversion.sh`，在 `unshare` 的 mount 命名空间 + overlayfs 隔离出
的 `/bin`、`/etc` 里实跑（不影响宿主机真实文件），覆盖：未 root 执行拒绝、
未安装时拒绝并提示先装、未知栈参数拒绝、无参数默认同步为 `lnmp`
且内容与 `conf/lnmp` 一致、把 `/bin/lnmp` 换成 lnmpa 内容后无参数能正确
自动识别为 `lnmpa`（未被误判成默认的 `lnmp`）、显式参数覆盖自动探测、
连续两次同步同一栈幂等（返回码和内容都不变）。

- **验证状态**：已验证（沙箱内实跑 + 静态检查）。

## SEC-SSH-001 装依赖前自动核对 SSH 端口，默认 22 强制二次确认

**位置**：`include/main.sh`（`Get_Actual_SSH_Port`、`Get_Sshd_Config_Ports`）、
`include/firewall.sh`（`Check_SSH_Port_Policy`）、`install.sh`

**问题**（用户反馈）：`Add_Iptables_Rules` 只会放行 `lnmp.conf` 里 `SSH_Port`
这一个端口，而且它跑在安装流程的最后（编译完数据库/PHP/Web 之后）。如果
用户已经把系统的 SSH 端口改掉、但忘了同步改 `lnmp.conf` 的 `SSH_Port`
（典型场景：改过 SSH 端口之后想再装个 phpMyAdmin 或补跑一次安装），装完
防火墙只会放行旧端口，真实在用的 SSH 端口没被放行——轻则新连接进不来，
重则把自己关在门外；而且这个坑要编译几十分钟到几小时之后才会暴露。
另外默认的 22 端口本身就是公网扫描器的常年目标，之前没有任何环节提醒
用户去改。

**行为变化**：

- 新增 `Get_Actual_SSH_Port`：优先用 `ss -tlnp` / `netstat -tlnp` 读取内核
  当前真实监听的 sshd 端口（不信任配置文件是否与实际生效一致），都不可用
  时退回解析 `sshd_config`（含 Debian/Ubuntu 默认 `Include` 的
  `sshd_config.d/*.conf`，用 `Get_Sshd_Config_Ports` 实现）；配置文件存在
  但没有显式 `Port` 行按 OpenSSH 默认值 22 处理；彻底探测不到时返回失败，
  交调用方决定怎么处理，不伪造一个可能误导判断的端口号。
- 新增 `Check_SSH_Port_Policy`，在 `lnmp`/`lnmpa`/`lamp`/`nginx`/`db`
  五个会调用 `Add_Iptables_Rules` 的入口里、真正开始装依赖之前调用：
  - 探测到的端口与 `SSH_Port` 不一致 —— 直接拒绝安装，报出两边的值，
    让用户把 `lnmp.conf` 改对，不去猜哪个是对的；
  - 一致但仍是默认的 22 —— 打印修改步骤（改 `sshd_config` 的 `Port`、
    `systemctl restart sshd`、验证新端口能登录后再关旧连接、同步改
    `lnmp.conf`），并要求显式输入 `y` 才能继续，其它输入直接退出安装；
  - 一致且已不是 22 —— 只提示即将放行的端口，不阻塞。
  - 非交互（无终端或 `LNMP_Auto=y`）不做比对和强制二选一，只打印提示后
    按 `lnmp.conf` 的值继续，不阻断已有自动化脚本/CI。
- `install.sh` 在 `case "${Stack}"` 分发之前调用，`mphp`/`phpmyadmin` 的
  `enable`/`disable`/`status` 子命令不碰防火墙，不受影响。

**验证**：`bash -n install.sh include/main.sh include/firewall.sh`；
`t/lint.sh` 全部通过；新增 `t/test_install_confirm.sh`——`Get_Sshd_Config_Ports`
用临时 fixture 验证了"无 Port 行按 22 处理""主配置里的 Port""跟随
Include 的 drop-in 目录"三种解析结果；`Get_Actual_SSH_Port` 在本机做了一次
真实探测（只读，不改任何东西）；`Check_SSH_Port_Policy` 用桩函数固定探测
结果，结合 `t/pty_run.py`（用真实伪终端喂输入，因为管道 stdin 下
`[ -t 0 ]` 恒为假、测不到交互分支）覆盖了一致+22+y、一致+22+非y拒绝、
一致+非22不强制二选一、不一致直接拒绝、探测彻底失败时的非交互与交互
两条路径，全部符合预期；也验证了 `LNMP_Auto=y` 下三处新确认都直接放行。

- **验证状态**：已验证（沙箱/伪终端内实跑 + 静态检查）；未在真实改过 SSH
  端口的服务器上跑一遍完整安装，待人工真机验证。

## UX-INSTALL-001 完整安装选择完毕后打印摘要并显式二次确认

**位置**：`include/main.sh`（`Press_Install`、`Confirm_Start_Install`、
`Confirm_LNMPConf_Reviewed`、`Print_APP_Ver`）、`install.sh`

**问题**（用户反馈）：`./install.sh lnmp` 选完数据库/PHP/Web/内存分配器之后，
原来的 `Press_Install` 只是"press any key to install"——按任意键就过，
等于没有真正的确认；而且当时打印摘要的 `Print_APP_Ver` 实际排在这一步
**之后**才调用，用户按键提交的时候根本还没看到版本、端口这些信息。装完
才发现选错版本或者端口不是预期的，只能卸载重装。

**行为变化**：

- `Press_Install` 按 `Stack` 分支：`lnmp`/`lnmpa`/`lamp` 选择完毕后先调用
  `Print_APP_Ver` 打印完整摘要（版本、编译参数、以及新增的 SSH/数据库
  端口行，见下），再调用 `Confirm_Start_Install` 要求显式输入 `y` 才真正
  开始装依赖、编译，其它输入取消安装、不做任何改动；`nginx`/`db`/`mphp`
  等其它入口保持原来的"press any key"不变，避免无关改动扩大范围。
- `Print_APP_Ver` 补上两行：`SSH_Port`（即将放行）、`DB_Kind != none` 时
  的 `DB_Port`/`DB_X_Port`（即将阻断公网新建连接）。
- 新增 `Confirm_LNMPConf_Reviewed`，在 `lnmp`/`lnmpa`/`lamp`/`nginx`/`db`
  五个入口最早处调用（选版本之前）：提醒检查 `lnmp.conf` 的端口、目录、
  `Enable_PhpMyAdmin` 等开关，要求显式输入 `y` 才继续选择版本，避免用户
  没看过配置就一路按下去。
- 以上三处确认均遵循仓库既有约定：非交互（无终端或 `LNMP_Auto=y`）打印
  提示后直接继续，不阻断已有自动化。
- `install.sh` 的 `Init_Install` 删掉了原来重复的 `Print_APP_Ver` 调用
  （现在由 `Press_Install` 内部统一打印一次，避免摘要打印两遍）。

**验证**：`bash -n install.sh include/main.sh`；`t/lint.sh` 全部通过；
`t/test_install_confirm.sh` 静态确认了 `Print_APP_Ver` 不再被重复调用、
`Press_Install` 对 `lnmp`/`lnmpa`/`lamp` 调用了摘要打印与确认；用
`t/pty_run.py` 跑了 `Confirm_LNMPConf_Reviewed`/`Confirm_Start_Install`
的真实 y/非y 两条交互路径，以及 `LNMP_Auto=y` 下的非交互直通路径；另外
手工拼了一遍 `Confirm_LNMPConf_Reviewed → Check_SSH_Port_Policy →
Press_Install`（含 `Print_APP_Ver` 摘要与 `Confirm_Start_Install`）的完整
调用链，逐步喂 `y`，确认摘要文本、端口信息与最终确认提示符合预期。

- **验证状态**：已验证（伪终端内实跑 + 静态检查）。

## FIX-INSTALL-001 Web 服务器菜单中 Nginx 版本号展开为空

**位置**：`install.sh`（组件加载顺序）、`include/main.sh` 的 `Web_Selection`
（`echo "1: 安装 Nginx ${Nginx_Ver#nginx-}（源码编译，默认）"`）、
`include/main.sh` 的 `Press_Install`（原 `. include/version.sh` 位置）。

**问题**：`include/version.sh` 只在 `Press_Install` 内部加载，而
`Dispaly_Selection → Web_Selection` 在此之前执行，`${Nginx_Ver}` 尚未定义。
Debian 13 上执行 `./install.sh lnmp`，Web 服务器菜单实际打印
`1: 安装 Nginx （源码编译，默认）`，缺少版本号；同一次运行的安装摘要
（`Print_APP_Ver`，在 `Press_Install` 内、version.sh 之后）显示 `nginx-1.30.4`
正常，因此该缺陷只影响选择阶段的菜单。

**行为变化**：`install.sh` 在 `. lnmp.conf` 之后、`. include/main.sh` 之前加载
`include/version.sh`。菜单打印为 `1: 安装 Nginx 1.30.4（源码编译，默认）`。
`Press_Install` 内原有的 `. include/version.sh` 保留，重复加载无副作用，
`include/only.sh` 等先调用 `Press_Install` 的独立安装入口行为不变。

**加载顺序安全性**：`include/version.sh` 全部为组件版本常量赋值，不引用
`DBSelect`、`PHPSelect`、`WebSelect`、`DB_Kind`、`Stack` 等选择结果；其中
`OpenResty_Modules_Options="${OpenResty_Modules_Options:-}"` 仍在 `lnmp.conf`
之后加载，外部传入值不受影响。`upgrade.sh` 原本即在文件头部加载 version.sh。

**验证**：`bash -n install.sh` 通过；定向对比同一表达式在两种加载顺序下的结果，
旧顺序输出 `1: 安装 Nginx （源码编译，默认）`，新顺序输出
`1: 安装 Nginx 1.30.4（源码编译，默认）`；`t/lint.sh` 18 项、`t/consistency.sh`
14 项全部通过。

真机复验：Debian 13 全新执行 `./install.sh lnmp`，Web 服务器菜单实际输出
`1: 安装 Nginx 1.30.4（源码编译，默认）`，同一次运行的摘要为 `nginx-1.30.4`，两处一致。

- **验证状态**：已实测（Debian 13 复现、本地定向对比、真机菜单复验）。

## AUDIT-INSTALL-001 安装摘要按实际模块开关生成（已实测）

**位置**：`include/main.sh` 的 `Print_APP_Ver`。

**问题**：原实现只打印通常为空的 `Nginx_Modules_Options` 与 `PHP_Modules_Options`，
默认安装时 `Nginx 附加模块` / `PHP 附加模块` 两行看不到实际启用的模块。

**行为变化**：两行改为按实际模块开关（`Enable_Nginx_Lua`、`Enable_Ngx_Brotli`、
`Enable_Ngx_CachePurge`、`Enable_Ngx_FancyIndex`、各 `Enable_PHP_*`）与附加参数生成。

**验证**：Debian 13 (trixie) 默认配置执行 `./install.sh lnmp`（nginx-1.30.4、
php-8.3.33）。摘要输出 `Nginx 附加模块：Lua, Brotli, Cache Purge`、
`PHP 附加模块：fileinfo, opcache, igbinary, redis, imagick`。
装完后 `nginx -V` 实际含 `--add-module=…/lua-nginx-module-0.10.31`、
`…/ngx_brotli-a71f931`、`…/ngx_cache_purge-2.3`（及 lua 依赖 `ngx_devel_kit-0.3.4`），
未启用的 FancyIndex 不在摘要也不在实际编译参数中；`php -m` 实际含
`fileinfo`、`Zend OPcache`、`igbinary`、`redis`、`imagick`，摘要未列的
`exif`、`ldap`、`bz2`、`sodium`、`imap` 实际均未安装。摘要与实际一致。

- **验证状态**：已实测（Debian 13）。

## FIX-ADDONS-003 附加组件通过统一服务入口重启 PHP-FPM 或 Apache

**位置**：`addons.sh` 的 `Restart_PHP`。

**问题与修复**：Redis 等扩展安装完成后原先直接执行 `/etc/init.d/php-fpm restart`。
在 systemd 管理的 LNMP 环境中，这会绕过 unit 启动新进程，使 systemd 丢失主进程跟踪，
`php-fpm.service` 随后成为 failed，而实际 PHP-FPM 进程仍在运行。现在从所选 init 脚本
取得服务名，并统一调用 `StartOrStop restart`：存在项目 systemd unit 时由 systemd 重启，
否则仍回退对应 SysV 脚本。Apache 分支同样使用 `httpd` 服务名；LAMP、LNMPA 本轮只做
静态分派检查，未重复安装实测。

**验证**：`bash tests/test_security_fixes.sh` 35/35；Debian 13 上直接调用修复后的
`Restart_PHP` 后，`php-fpm.service` 为 active、主进程由 systemd 跟踪，
`/run/php-fpm/php-cgi.sock` 为 `www:www 0660`，`lnmp status` 返回 0。

- **验证状态**：已实测（LNMP，Debian 13，2026-08-15）。

## RUN-040 Debian 13 Redis 与 WordPress 主线实测

**范围**：复用现有 Nginx 与 PHP 8.3，不重新编译 PHP；安装 Redis 8.10.0 服务端与
phpredis 6.3.0，并先后在 MySQL 8.4、MariaDB 11.8 上部署一次性 WordPress 7.0.3
测试站点。MariaDB 通过 `install.sh db` 单独安装，没有进入 Web/PHP 安装流程。

**Redis 结果**：`redis-cli ping` 返回 `PONG`，服务为 active/enabled，只监听
`127.0.0.1` 与 `::1`；PHP CLI 已加载 redis 扩展，`lnmp status` 返回 0。

**WordPress 结果**：`tests/verify_wordpress_lnmp_remote.sh` 真实完成官方包校验、建库、
HTTP 安装、文章写入和访问，首页、文章固定链接、REST API 均返回成功；请求经 PHP-FPM
分别读写 MySQL 与 MariaDB，并由 mu-plugin 经 phpredis 写入和读回 Redis key。测试脚本
动态选择已安装的 MySQL/MariaDB 客户端，并在 Nginx reload 后等待静态探针接管流量，
避免把旧 worker 的短暂响应误判为应用失败。

**清理**：成功和失败路径都清理独立 vhost、站点目录、日志、数据库、数据库用户、
Redis key 与 0700 临时凭据目录；清理后 `nginx -t` 和 nginx 服务状态正常。

- **验证状态**：已实测（Debian 13，2026-08-15）。

## RUN-039 Debian 13 LNMPA 完整安装与 Apache 收尾验证

**环境**：Debian 13 (trixie)，本项目完整源码安装 OpenResty 1.31.1.1、
Apache 2.4.68、PHP 8.3.33 ZTS；phpMyAdmin 5.2.3 独立补装，随后用项目入口
补装 MySQL 8.4.7 以完成真实登录验证。

**验证结果**：

- `tests/verify_project_apache_stack.sh lnmpa` 18/18：站点 PHP 开关、
  `.php.bak`、同/异属主软链接、根目录外 Alias、PATH_INFO、默认演示页白名单、
  其它 PHP 拒绝，以及 init.d、单服务和整栈失败码传播全部通过。
- `tests/test_apache_stack_service_failures.sh` 6/6；OpenResty `nginx -t` 与
  Apache `httpd -t` 均通过。
- phpMyAdmin 经 OpenResty 80 与 Apache 88 双入口均返回 200；disable 后双入口
  均为 404，enable 后恢复 200；默认站点其它 PHP 经 OpenResty 返回 404 且未执行。
- 使用 cookie 登录流程通过 OpenResty 入口连接 MySQL：登录表单消失，页面出现
  logout 入口和数据库导航，确认不是只验证到静态登录页。
- 80 对外监听；Apache 88 与管理端口 1008 均只监听回环地址。测试站点、请求文件、
  cookie 和响应临时文件均已清理。

**本轮闭环并从 `todo.md` 删除**：`AUDIT-VHOST-014-APACHE`、
`AUDIT-SERVICE-002`、`AUDIT-VHOST-013-APACHE`、`AUDIT-VHOST-012`。

- **验证状态**：已实测（Debian 13，2026-08-15）。

## AUDIT-SEC-002-FIX pcntl_exec 不再绕过 PHP 命令执行限制

- **改动**：主 PHP 与多版本 PHP 写入的 `disable_functions` 增加
  `pcntl_exec`。保留 `pcntl_fork`、`pcntl_signal`、`pcntl_wait` 等非执行类
  pcntl 能力，避免影响现有队列和进程管理代码。
- **静态回归**：`bash -n include/php.sh include/multiplephp.sh` 通过；
  `bash tests/test_security_fixes.sh` 确认两套配置均包含 `pcntl_exec` 且没有禁用
  `pcntl_fork`。
- **真机验证**：2026-08-15 在 Debian 13 / PHP 8.3.33（pcntl 已编入）用新
  `disable_functions` 启动一次性 CLI 探针，结果为
  `pcntl_exec=0 pcntl_fork=1 pcntl_signal=1`。
- **验证状态**：已实测（Debian 13，2026-08-15）。

## AUDIT-SEC-006-FIX Redis bind 改写失败时不再静默放开监听

- **改动**：`include/redis.sh` 新增 `Set_Redis_Loopback_Bind`，兼容活动、注释及
  上游通配格式的 `bind`，统一写为 `bind 127.0.0.1 -::1`，并用
  `Check_Conf_Applied` 回读确认；改写或核对失败会中止安装。
- **静态回归**：`bash -n include/redis.sh` 通过；
  `bash tests/test_security_fixes.sh` 对三类模板的定向测试通过（16/16）。
- **真机验证**：2026-08-15 在 Debian 13 / Redis 8.10.0 上把临时配置预置为
  通配监听，经新函数改写后以非默认端口启动真实 Redis。`ss` 仅显示
  `127.0.0.1` 和 `::1` 两个监听地址，未出现全网卡监听；测试进程、端口及临时
  目录已清理。
- **验证状态**：已实测（Debian 13，2026-08-15）。

## AUDIT-SEC-011-FIX Web 配置半可信输入在写文件前统一校验

- **改动**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp` 同步新增配置名称、
  `ServerAdmin` 邮箱和证书绝对路径校验；交互读取和最终
  `Add_VHost_Config` / `Create_SSL_Config` 入口均检查，调用方同时传播失败返回码。
- **兼容边界**：现有安全的 rewrite 名、日志名、管理员邮箱及真实证书路径保持
  原行为；仅拒绝路径穿越、空白、配置元字符、不存在文件和非法邮箱。
- **定向实测**：2026-08-15 在 Debian 13 直接调用三份脚本的最终写配置入口，
  rewrite 路径、日志名、`ServerAdmin` 和证书路径四类注入均在文件操作前失败；
  `bash tests/test_security_fixes.sh` 通过 16/16。
- **验证状态**：已实测（Debian 13，2026-08-15）。

## AUDIT-SEC-001-FIX Apache ServerAdmin 在安装入口拒绝注入字符

- **改动**：`include/main.sh` 新增安装期 `ServerAdmin` 邮箱白名单校验，
  `Apache_Selection` 在任何 Apache 配置写入前执行校验；`install.sh` 的 LAMP、LNMPA
  入口传播失败返回码。正常邮箱继续写入原有两个 Apache 模板。
- **安全边界**：只允许邮箱所需的字母、数字及 `._%+-@`，原载荷中的 `/`、`;`、
  空白和换行均无法到达 `include/apache.sh` 的 `sed` 替换。
- **验证**：Debian 13 上直接执行正常邮箱、空白注入和原 sed 注入载荷；正常值通过，
  两类恶意值均在安装选择阶段返回非零。此前同批 LAMP/LNMPA 完整安装的正常配置和
  `httpd -t` 结果继续通过；`tests/test_security_fixes.sh` 35/35。
- **验证状态**：已实测（函数入口及既有 Apache 完整栈，Debian 13，2026-08-15）。

## AUDIT-SEC-003-FIX MySQL 不再默认启用 mysql_native_password

- **改动**：MySQL 8.0 模板删除 `default_authentication_plugin = mysql_native_password`，
  MySQL 8.4 模板删除 `mysql_native_password=ON`；安装与升级路径均不再写入旧认证开关，
  新账号使用 MySQL 8.x 上游默认认证。MariaDB 配置与账号逻辑不变。
- **验证**：全仓库安装、升级配置中均无两个旧选项；安全回归确认配置路径无残留。
  同批 MySQL 8.4.7 完整安装、密码登录、WordPress 数据库访问均已通过；随后
  MariaDB 11.8.8 的安装、登录与 WordPress 回归也通过，未重复安装两种数据库。
- **验证状态**：已实测（MySQL 8.4 与 MariaDB 11.8，Debian 13，2026-08-15）。

## AUDIT-SEC-004-FIX 彩色输出不再分词或展开通配符

- **改动**：`include/main.sh` 以及 `conf/lnmp`、`conf/lnmpa`、`conf/lamp` 的四组
  `Echo_*` 实现统一给 `Color_Text` 命令替换加双引号；原换行行为保持不变。
- **验证**：在含多个文件的测试目录输出带 `*`、`?`、连续空白的消息，内容保持原样，
  不再被文件名替换；四份实现一致性检查通过。
- **验证状态**：已实测（Debian 13，2026-08-15）。

## AUDIT-SEC-005-FIX MySQL 与 MariaDB 原数据目录完整搬移

- **改动**：`Check_MySQL_Data_Dir`、`Check_MariaDB_Data_Dir` 不再执行非递归复制后
  `rm -rf`，改为把整个数据目录移动到时间戳备份目录。目标冲突、移动失败或空目录
  重建失败均返回非零，安装调用方立即停止；失败时不会继续清理原数据。
- **验证**：Debian 13 临时数据目录同时放入顶层文件、隐藏文件和数据库子目录，
  MySQL 与 MariaDB 两个函数均完整搬移所有内容并重建空数据目录；
  `tests/test_security_fixes.sh` 35/35。
- **验证状态**：已实测（真实文件系统搬移，Debian 13，2026-08-15）。

## AUDIT-SEC-007-FIX TCMalloc profile 移出共享临时目录

- **改动**：profile 目录由 `/tmp/tcmalloc` 改为
  `/usr/local/nginx/var/tcmalloc`，创建前拒绝末级符号链接，并检查目录创建、属主和
  `0750` 权限的返回码；任一步失败即停止安装，不写入 Nginx 配置。
- **验证**：源码和配置不再引用 `/tmp/tcmalloc`，生成的指令只指向 Nginx 私有目录；
  Debian 13 安全回归与 Nginx 配置检查通过。该目录位于 root 管理的 Nginx 前缀下，
  普通本地账号不能再预置原共享路径改变写入落点。
- **验证状态**：已验证（路径、权限及失败分支，Debian 13，2026-08-15）。

## AUDIT-SEC-008-FIX Composer 复用安全下载策略并支持关闭

- **改动**：`Install_Composer` 使用 `Download_Fetch` 下载官方 SHA384 与安装器，
  继续保持缺少或不匹配校验值时拒绝执行；PHP 哈希调用通过 `$argv[1]` 传入路径，
  不再把工作目录拼进 PHP 程序文本。`lnmp.conf` 新增默认为 `y` 的
  `Enable_Composer`，设为 `n` 时明确跳过且返回成功。
- **验证**：安全回归确认开关默认值、两个 HTTPS 下载入口、`$argv` 参数和失败关闭
  路径全部接入；同批 PHP 8.3 环境与下载校验基础设施已实跑，本项未重复编译 PHP。
- **验证状态**：已验证（下载与哈希函数路径，Debian 13，2026-08-15）。

## AUDIT-SEC-009-FIX Nginx 版本判断与 OpenSSL 开关解耦

- **改动**：`Install_Nginx` 入口无条件从 `Nginx_Ver` 初始化 `Nginx_Version`，再进入
  OpenSSL、Lua 和 configure 分支。`Enable_Nginx_Openssl=n` 时仍会按 Nginx 真实版本
  选择现代 HTTP/2、HTTP/3 配置，不再落入已删除的 SPDY/IPv6 参数分支。
- **验证**：函数级回归确认关闭 OpenSSL 时版本仍为 `1.30.4`，并检查初始化发生在所有
  分支之前；现有 Nginx 1.30.4 的配置与服务状态保持正常，未重复编译 Nginx。
- **验证状态**：已验证（分支级回归，Debian 13，2026-08-15）。

## AUDIT-SEC-010-FIX 数据库客户端显式使用 HOME 下的凭据文件

- **改动**：`Do_Query`、数据库快照/升级验证、三份管理脚本及相关升级入口统一使用
  `--defaults-file="${HOME}/.my.cnf"`，不再依赖客户端解释等号后的字面量 `~`。
- **验证**：全仓库目标路径无 `--defaults-file=~/.my.cnf` 残留；安全回归通过。
  同批 MySQL 8.4 与 MariaDB 11.8 环境中的数据库列表、建库、导入、导出、改密和删除
  命令均已真实执行成功，未为本项重复切换数据库。
- **验证状态**：已实测（MySQL 与 MariaDB 管理命令，Debian 13，2026-08-15）。

## AUDIT-SEC-012-FIX 三份管理脚本统一支持长顶级域邮箱

- **改动**：`conf/lnmpa`、`conf/lamp` 的 ACME 邮箱正则由顶级域 2 至 4 位改为
  2 至 63 位，与 `conf/lnmp` 及公共 `ServerAdmin` 校验一致。
- **验证**：三份脚本对常规邮箱和长顶级域邮箱执行同一函数级测试，均接受合法值并
  拒绝空白及配置注入；仓库中不再残留 `{2,4}` 的旧邮箱规则。
- **验证状态**：已实测（函数输入，Debian 13，2026-08-15）。

## AUDIT-SEC-013-FIX DenyHosts 删除工具严格校验并按字面量匹配 IP

- **改动**：`tools/denyhosts_removeip.sh` 在停止服务和修改文件前使用 Python 标准库
  `ipaddress.ip_address` 校验 IPv4/IPv6。文件更新改为私有临时文件和
  `re.escape` 字面量匹配，保留原权限/属主并检查写回返回码；退出 trap 负责清理并
  在失败后恢复服务。
- **验证**：原 sed 注入载荷和 `.` 均在任何服务操作前返回非零，脚本不再把参数拼入
  sed 表达式；正常 IPv4/IPv6 校验与边界匹配回归通过。
- **验证状态**：已实测（恶意与正常输入，Debian 13，2026-08-15）。

## DOC-SEC-010 安全修复与 Debian 13 实测同步到用户文档

- **README**：补充数据库/PHP-FPM `/run` socket、MySQL 上游默认认证、Apache 配置边界、
  Composer 开关、Pure-FTPd `TLS 2`、数据库目录完整搬移；
  Debian 13 验证矩阵改为包含 LNMP + MySQL/MariaDB、LAMP、LNMPA 与 WordPress 主链路，
  删除 Apache 系“未做真机验证”的过时说法。
- **HowtoGuides**：补充 `Enable_Composer`、Apache `ServerAdmin`、数据目录失败行为、
  MySQL/MariaDB 认证差异、DenyHosts 解封入口、Pure-FTPd 显式 FTPS，
  并更新安装后检查、安全基线和完整验证结果。
- **复核**：两份文档不再含 LAMP/LNMPA 未实测、旧 TLS 默认值或验证机密码、地址、
  路径信息；详细逐项证据仍以本文件对应 `AUDIT-SEC-*-FIX` 记录为准。
- **验证状态**：已完成文档一致性复核（2026-08-15）。

## AUDIT-SEC-014-FIX Apache 只把末尾 `.php` 交给 mod_php

- **改动**：`conf/httpd24-lamp.conf` 与 `conf/httpd24-lnmpa.conf` 删除 PHP
  `AddType` 及 `.phps` 源码映射，改为行尾锚定的
  `<FilesMatch "\.php$">` + `SetHandler application/x-httpd-php`。
- **兼容验证**：2026-08-15 在 Debian 13 / Apache 2.4.68 / mod_php 8.4.24
  启动隔离实例，LAMP 与 LNMPA 两份实际配置均能正常执行末尾 `.php`；
  `.php.bak` 请求返回原始静态内容而没有执行。`tests/verify_apache_security_remote.sh`
  总计通过 12/12。
- **项目 LAMP 复验**：同日在本项目完整源码安装的 Apache 2.4.68 +
  PHP 8.3.33 ZTS 上运行 `tests/verify_project_apache_stack.sh lamp`，正常 `.php`
  执行且 `.php.bak` 仅返回静态源码文本，未被 PHP 处理。
- **环境边界**：处理器对照组确认 mod_php 可执行；但 Debian 当前的 mod_php 8.4
  不再把单独 `AddType` 当作 PHP handler，因此旧配置下 `.php.bak` 执行行为在该环境
  未复现。修复后的正向 `.php` 与反向 `.php.bak` 请求边界均已真实验证。
- **验证状态**：已实测（Debian 13，2026-08-15）。

## AUDIT-SEC-015-FIX Apache 根目录和符号链接边界收紧

- **改动**：两份 Apache 主模板的 `<Directory />` 恢复
  `AllowOverride None` 与 `Require all denied`；静态 vhost、LAMP/LNMPA 动态
  vhost、示例配置和 phpMyAdmin Alias 均使用绝对的
  `Options SymLinksIfOwnerMatch`。
- **漏洞对照**：2026-08-15 在 Debian 13 / Apache 2.4.68 使用旧的根目录放行与
  `FollowSymLinks` 组合，真实请求成功读取了异属主测试文件，确认测试夹具可复现越界。
- **修复验证**：LAMP 与 LNMPA 两份实际配置对异属主软链接均返回 403，对根目录
  Alias 均返回 403；同属主软链接仍返回 200，确认安全边界收紧且保留预期功能。
  `tests/verify_apache_security_remote.sh` 总计通过 12/12。
- **项目 LAMP 复验**：同日在本项目完整源码安装的 Apache 2.4.68 上复验，
  异属主软链接和根目录外 Alias 均为 403，同属主软链接为 200；测试路径和配置
  已由脚本恢复清理。
- **验证状态**：已实测（Debian 13，2026-08-15）。

## AUDIT-SEC-016-FIX 数据库与 PHP-FPM socket 移出共享临时目录

**位置**：`include/dbcommon.sh`、`include/main.sh`、`include/mysql.sh`、
`include/mariadb.sh`、`include/php.sh`、`include/multiplephp.sh`、相关升级脚本与
`init.d/*.service`。

**修复**：MySQL 与 MariaDB 的正式 socket 统一为 `/run/mysqld/mysqld.sock`，
PHP-FPM 主版本与多版本 socket 统一放入 `/run/php-fpm/`。systemd unit 使用
`RuntimeDirectory` 在启动前创建运行目录并恢复 `PrivateTmp=true`；SysV init 脚本也会
安全创建目录，遇到软链接或非目录对象时失败退出。当前处于开发期，不增加旧 `/tmp`
socket 的兼容迁移逻辑。

**首次密码**：数据库初始化完成后不再把空口令实例暴露到正式 socket。安装函数创建
0700 私有目录，在其中以 `--skip-networking` 启动临时实例，预建 0600 且属于数据库
服务账号的错误日志，设置 root 密码并验证后关闭，再启动正式服务。独占客户端配置明确
写入 `/run/mysqld/mysqld.sock`，不会回退编译期 socket。

**定向测试**：`tests/test_security_fixes.sh` 35/35，`tests/test_db_port.sh` 13/13；
`systemd-analyze verify`、`nginx -t`、`php-fpm -t` 通过。

**MySQL 8.4 真机**：禁网私有实例成功设密并关闭；正式 socket、回环监听和密码登录正常，
空口令拒绝，匿名账号、远程 root 与 test 库均为 0；删除 `/run/mysqld` 后 systemd 能重建。

**MariaDB 11.8 真机**：通过 `install.sh db` 使用官方通用二进制独立安装，未重新编译
Nginx 或 PHP。非特权 `www` 用户空口令登录 root 被拒绝，安全对象计数为 `0,0,0`，
正式 socket 与监听地址正确；删除 `/run/mysqld` 后服务重建目录并恢复登录。

**PHP 与应用**：PHP-FPM socket 为 `/run/php-fpm/php-cgi.sock`、`www:www 0660`；删除
`/run/php-fpm` 后可重建。Nginx、PHP-FPM、数据库均显示 `PrivateTmp=yes`。WordPress 7.0.3
在 MySQL 8.4 与 MariaDB 11.8 上分别完成首页、固定链接、REST、数据库及 Redis 实测；
MariaDB 环境下 phpMyAdmin 随机入口返回 200，`lnmp status` 返回 0。

- **验证状态**：已实测（MySQL、MariaDB、PHP-FPM，Debian 13，2026-08-15）。

## AUDIT-SEC-017-FIX Pure-FTPd 新安装默认拒绝明文 FTP

- **改动**：`conf/pure-ftpd.conf` 的新安装默认值由 `TLS 1` 改为 `TLS 2`。
  `pureftpd.sh` 仍生成自签证书并复制该模板；不迁移、不覆盖已有服务器当前部署的
  `/usr/local/pureftpd/etc/pure-ftpd.conf`。
- **兼容边界**：FTP 账号、目录、主动/被动模式和 FTPS 上传功能保持不变；以后新装
  的 Pure-FTPd 客户端必须使用显式 FTPS。管理员仍可在部署配置中手工改为 `TLS 1`，
  但会重新允许明文口令。
- **静态回归**：`bash -n pureftpd.sh`、`bash tests/test_security_fixes.sh` 通过。
- **真机验证**：2026-08-15 在 Debian 13 源码编译安装 Pure-FTPd 1.0.54，实际配置
  回读为 `TLS 2`。普通 FTP 在发送 `USER` 后收到 `421`，明确拒绝 cleartext；
  `curl --ssl-reqd --insecure` 的显式 FTPS 列目录和上传均返回 0，上传内容逐字节一致。
  测试后已停止服务，删除临时账号与安装目录，并恢复 `/bin/lnmp`、systemd 和
  nftables 配置。
- **验证状态**：已实测（Debian 13，2026-08-15）。

## AUDIT-SEC-018-FIX 校验清单生成与自动刷新强制核对上游依据

**位置**：`t/gen_checksums.sh`、`t/refresh_checksums.sh`、`include/verify.sh`、
`.github/workflows/upstream-check.yml`。

**修复**：PHP、MariaDB 和 phpMyAdmin 采集改用 `Upstream_SHA256`；Nginx 使用随包公钥
和固定指纹白名单验证 PGP 签名；OpenSSL、Apache 与 APR 使用上游 `.sha256`。自动刷新
统一通过 `Download_Fetch`，只允许 HTTPS 且禁止重定向降级。能取得机器可读上游依据的
组件若取值失败或与下载文件不一致，工作流返回非零，不写回 `src/checksums.sha256`。

**防损坏检查**：刷新只精确替换目标组件的完整清单行；写回前验证每行格式和文件名唯一，
避免版本号碰撞、换行破坏或非法哈希覆盖信任清单。

**真实交叉核对**：Debian 13 上复用实际安装包，PHP 8.3.33 与 MariaDB 11.8.8 的
上游 API SHA256、实际文件 SHA256 和仓库清单三方一致；另行下载 Nginx 1.30.4 小包及
`.asc`，PGP 验签通过，签名者主密钥命中固定白名单。

**回归**：`t/test_bump.sh` 的组件碰撞、清单碰撞和坏清单拒绝写回用例通过；
`t/lint.sh` 18/18、`t/consistency.sh` 14/14。

- **验证状态**：已实测（真实上游 SHA256/PGP，Debian 13，2026-08-15）。

## AUDIT-SEC-019-FIX 八个动态升级入口统一校验版本号

**位置**：`include/main.sh` 的 `Check_Version_String`，以及 Nginx、OpenResty、PHP、
多版本 PHP、MySQL、MariaDB、MySQL 到 MariaDB、phpMyAdmin 八个升级入口。

**修复**：版本值在用于 URL 或落地文件名之前统一限制为非空的
`[0-9A-Za-z._-]`，拒绝 `/`、反斜杠、空白、shell 元字符和路径片段。各入口原有的
受支持分支/主版本判断继续保留在公共字符校验之后，未改变可升级版本范围。

**验证**：`tests/test_security_fixes.sh` 对正常 Nginx/OpenResty 版本及
`../../outside`、`8.4.7/extra`、`8.4.7;touch` 执行公共函数测试，并确认八个入口全部
调用该函数；35 项全过。完整 `bash -n`、lint 与 consistency 同时通过。

- **验证状态**：已验证（函数级输入与八入口接入，Debian 13，2026-08-15）。

## AUDIT-SEC-020-FIX 自动升版不再把上游值拼入 Perl 程序

**位置**：`t/check_upstream.sh`、`t/bump_version.sh`。

**修复**：候选值写入 `bumps.tsv` 前统一限制为 `[0-9A-Za-z._-]`，
lua-resty-core tag 正则补完整尾锚。升版脚本再次校验 key、旧值、新值、类别和列数；
Perl 替换通过环境变量传值，变量内容不再成为 `-e` 程序文本。普通版本变量写回也只匹配
指定 key 的完整赋值行。

**恶意输入验证**：`t/test_bump.sh` 构造包含 `/e;system("touch ...")` 的上游值，
脚本返回非零，标记文件未创建，版本文件未改变。该套件 16 项全部通过；
`t/test_upstream.sh` 11 项通过，包括统一候选值校验、resty-core 尾锚和上游取数失败
传播；两个脚本均为 GitHub Actions 直接调用的 CI 检查。

- **验证状态**：已验证（恶意输入与 CI 回归，Debian 13，2026-08-15）。

## AUDIT-SEC-021-FIX MariaDB 11.8.8 二进制包校验条目恢复可读取

- **改动**：清除 `src/checksums.sha256` 中混入的 CR 字节及文件头、MariaDB
  条目后的异常空行；哈希值本身不变，清单现为 66 条有效记录。
- **行为恢复**：`mariadb-11.8.8-linux-systemd-x86_64.tar.gz` 的文件名不再带隐藏
  `\r`，`Verify_Download_File` 的精确 awk 查询可取得已登记 SHA256，不会再把该安装包
  误判为未登记文件。
- **验证**：2026-08-15 在 Debian 13 干净副本执行 `bash t/lint.sh` 18/18、
  `bash t/consistency.sh` 14/14；其中 C10、V7、V14 均为 ok，清单 CR 字节数为 0。
- **验证状态**：已实测（Debian 13，2026-08-15）。

## AUDIT-PMA-001-FIX LAMP 补装 phpMyAdmin 可读取真实 HTTP 端口

- **问题确认**：项目源码编译的 Apache 2.4.68 执行
  `httpd -t -D DUMP_RUN_CFG` 不输出 `Listen`，原 LAMP 分支始终取不到端口，
  会在 HTTP 冒烟前回滚 phpMyAdmin 补装。
- **改动**：`include/php.sh` 的 LAMP 分支改读 `DUMP_VHOSTS` 展开后的首个
  `*:端口`；LNMP 与 LNMPA 继续使用原有 `nginx -T` 分支，逻辑未改。
- **定向回归**：`bash -n include/php.sh tests/test_install_phpmyadmin.sh` 通过；
  `bash tests/test_install_phpmyadmin.sh` 全部通过；真实 LAMP 环境调用
  `Get_PhpMyAdmin_HTTP_Port` 返回 `80`。
- **完整实测**：2026-08-15 在 Debian 13 上用本项目完整安装的
  Apache 2.4.68 + PHP 8.3.33 ZTS 执行 `./install.sh phpmyadmin`，上游包 SHA256、
  Apache 配置检查、服务 reload 和本机 HTTP 冒烟全部通过，phpMyAdmin 5.2.3
  安装成功。
- **验证状态**：已实测（LAMP，Debian 13，2026-08-15）。

## AUDIT-INITD-003 httpd init 脚本传播真实启动与重载失败

- **验证**：2026-08-15 在 Debian 13 / 本项目 Apache 2.4.68 上临时加入无效指令。
  运行中执行 `/etc/init.d/httpd graceful` 返回非零且旧进程继续服务；停止服务后执行
  `/etc/init.d/httpd start` 同样返回非零，没有误报完成。
- **恢复**：删除故障配置后 `httpd -t` 通过，systemd 启动与 reload 成功，
  `tests/verify_project_apache_stack.sh lamp` 总计通过 18/18。
- **验证状态**：已实测（LAMP，Debian 13，2026-08-15）。

## AUDIT-VHOST-001 default 公网兜底站点生成与 IP 命中（已实测）

**位置**：`include/nginx.sh` 的 `Write_Nginx_Default_VHost` / `Install_Nginx`。

**行为变化**：主配置只保留 `127.0.0.1:1008` 管理端口，公网 default 站点由
共享函数独立生成到 `<conf>/vhost/default.conf`。

**验证**：Debian 13 全新安装后 `/usr/local/nginx/conf/vhost/default.conf` 已生成；
`nginx -t` 通过；`ss -lnt` 显示 80 监听 `0.0.0.0`、管理端口仅监听 `127.0.0.1:1008`；
用服务器 IP 访问 `http://<IP>/` 返回 200 且落点为 default 站点内容。
OpenResty 侧的同一函数复用待 `AUDIT-VHOST-011` 单独验证。

- **验证状态**：已实测（Debian 13，编译 Nginx 路径）。

## AUDIT-VHOST-004 default 根目录静态 PHP 边界（已实测，Nginx 侧）

**位置**：`include/nginx.sh` 的 `Write_Nginx_Default_VHost`。

**行为变化**：未启用 phpMyAdmin 时，default 站点对 PHP 请求返回 404，
既不执行也不作为静态文件下载。

**验证**：Debian 13，未启用 phpMyAdmin 的 default 根目录放置 `probe.php`，
`GET /probe.php` 返回 404，响应体不含源码。
LAMP/LNMPA 的 Apache default 侧仍待验证（见 todo 中同编号条目的剩余范围）。

- **验证状态**：已实测（Debian 13，Nginx 侧）。

## AUDIT-VHOST-005 default ACME 放行与隐藏路径拦截（已实测）

**位置**：`include/nginx.sh` 生成的 default server 块。

**行为变化**：在隐藏路径拒绝规则前加入 `location ^~ /.well-known/ { allow all; }`，
使 HTTP-01 校验文件可访问，其余隐藏路径仍被拒绝。

**验证**：Debian 13，`GET /.well-known/acme-challenge/token123` 返回 200 且响应体
与文件内容一致；`GET /.git/config`、`GET /.env` 均返回 403，
`default.error.log` 记录 `access forbidden by rule`。

- **验证状态**：已实测（Debian 13）。

## AUDIT-VHOST-006 default 独立日志与 main 格式（已实测）

**位置**：`conf/nginx.conf`，`include/nginx.sh`，`tools/cut_nginx_logs.sh`。

**行为变化**：主配置统一 `log_format main`；default 站点使用
`/home/wwwlogs/default.log` 与 `/home/wwwlogs/default.error.log`，并纳入日志切割。

**验证**：Debian 13，产生 200/403/404 三类请求后：

- `default.log` 按 `main` 格式记录，字段顺序为
  `$time_iso8601 $status "$request_time" $remote_addr $scheme://$http_host "$request" …`，
  前四个字段定宽靠前，可直接对齐查看。
- `default.error.log` 独立记录 403 拒绝原因。
- 执行 `tools/cut_nginx_logs.sh` 返回 0，`default.log` 与管理端口 `access.log`
  分别归档为 `/home/wwwlogs/2026/08/default_20260813.log`、`access_20260813.log`；
  脚本内 `nginx -s reload` 后新的访问写入新建的 `default.log`，未继续写入归档文件。

`tools/cut_nginx_logs.sh` 按设计不自动部署，由使用者自行加入 crontab
（`README.md`、`HowtoGuides.md` 已说明）。

- **验证状态**：已实测（Debian 13）。

## FIX-UNINSTALL-001 数据目录为空时卸载被误判为备份失败而中止

**位置**：`uninstall.sh` 的 `Backup_DB_Data`。

**问题**：`Backup_DB_Data` 先把数据目录 `mv` 到 `/root/databases_backup_<时间戳>`，
再自检"备份目录存在且非空"以防 `mv` 返回 0 但结果不对。数据目录本身为空时
（数据库初始化失败、或装完从未启动过的半成品安装），自检必然不成立，卸载以
`致命错误：备份目录 … 不存在或为空` 中止且不删除任何文件，这类安装无法通过
`./uninstall.sh` 清理，只能手工删除。Debian 13 上因
`AUDIT-DB-005` 导致 MySQL 数据目录为空后实际触发。

**行为变化**：`mv` 之前增加判空。源数据目录为空时打印
`数据目录 … 为空，无需备份。` 并返回 0，由后续 `Remove_DB_Files` 正常删除；
源目录不存在时的既有跳过分支保持不变；非空数据目录仍然先备份、再执行
`mv` 结果自检与备份路径检查，失败依旧中止且不删除任何文件。

**验证**：

- 定向测试（函数级）：空目录返回 0 且跳过备份；不存在的目录返回 0 且跳过；
  非空目录在 `mv` 失败时仍打印致命错误并以非零中止，保护逻辑未被削弱。
- Debian 13 实测：构造 `/usr/local/mysql/{bin,var}` 且 `var` 为空的安装
  （`Check_Stack` 识别为 mysql），执行 `./uninstall.sh lnmp` 返回 0，
  输出 `数据目录 /usr/local/mysql/var 为空，无需备份。`，
  `/usr/local/mysql`、`/etc/my.cnf`、`/bin/lnmp` 均已删除。
- 修复前同一环境实测返回 1，日志为 `致命错误：备份目录 … 不存在或为空`，
  且 `/usr/local/{nginx,mysql,php}`、`/bin/lnmp` 全部保留未删。

- **验证状态**：已实测（Debian 13）。

## AUDIT-DB-005 Debian 13 缺 libaio.so.1 导致数据库通用二进制包无法启动

**位置**：`include/dbcommon.sh` 的 `Ensure_Libaio_Compat` 与 `Install_DB_Bin_Tarball`，
`uninstall.sh` 的 `Remove_DB_Files` / `Remove_Libaio_Compat_Link`。

**问题**：MySQL 与 MariaDB 官方通用二进制按 SONAME `libaio.so.1` 链接。Debian 13
起 `libaio1` 因 64 位 time_t 转换改名为 `libaio1t64`，只提供 `libaio.so.1t64`；
依赖清单里的 `libaio-dev` 提供的是无版本号的 `libaio.so`，同样不满足。
Debian 13 默认配置执行 `./install.sh lnmp` 实测：
`/usr/local/mysql/bin/mysqld: error while loading shared libraries: libaio.so.1`，
`--initialize-insecure` 静默失败、数据目录为空，随后 `mysql.service` 反复启动失败。
Debian 12 提供 `libaio.so.1`，不受影响。

**行为变化**：`Install_DB_Bin_Tarball` 在二进制落地、`bin/` 自检之后调用
`Ensure_Libaio_Compat`，对 `bin/mariadbd` 或 `bin/mysqld` 按 `ldd` 结果判断：

- 未缺 `libaio.so.1`（Debian 12、RHEL 系）直接返回，不做任何改动。
- 缺失且架构 time_t 原本即为 64 位（x86_64/aarch64/ppc64le/s390x/riscv64/
  loongarch64）时，在 `libaio.so.1t64` 所在目录建立同名兼容链接
  `libaio.so.1`，`ldconfig` 后复验 `ldd`。
- 缺失但系统没有 `libaio.so.1t64`，或架构不在上述列表，或目标位置已存在同名
  实体文件时，打印所需软件包并返回非零，安装在解压阶段即中止。

卸载时 `Remove_Libaio_Compat_Link` 只删除"是符号链接且指向 `libaio.so.1t64*`"
的兼容链接，发行版自带实体库不动。

**链接落点**：兼容链接必须与 `libaio.so.1t64` 同目录，即动态链接器的默认搜索
目录。放到 `/usr/local/lib` 并写 `/etc/ld.so.conf.d/*.conf` 无效——`ldconfig`
按库文件自身的 SONAME（`libaio.so.1t64`）建缓存，`libaio.so.1` 这个文件名进不了
缓存；实测该做法建立链接后 `ldd` 仍报 `libaio.so.1 => not found`。改为落在默认
搜索目录后，链接器在缓存未命中时按文件名查找即可命中。

**验证**（Debian 13 trixie）：

- 失败分支：临时移走 `/lib/x86_64-linux-gnu/libaio.so.1t64*` 并 `ldconfig` 后执行
  `./install.sh db`（MySQL 8.4.7 通用二进制），退出码 1，输出
  `错误：/usr/local/mysql/bin/mysqld 需要 libaio.so.1，但系统里找不到可用的 libaio。`
  并列出所需软件包，安装在初始化之前中止。
- 正常分支：恢复 `libaio.so.1t64` 后重新执行，输出
  `当前发行版只提供 libaio.so.1t64，已建立 /lib/x86_64-linux-gnu/libaio.so.1 -> libaio.so.1t64。`，
  `--initialize-insecure` 成功产出完整数据目录（`auto.cnf`、证书、InnoDB 文件齐全，
  日志含 `root@localhost is created with an empty password`），
  `mysqld --version` 与服务启动均正常。

- **验证状态**：已实测（Debian 13，MySQL 8.4.7 通用二进制两条分支）。

## AUDIT-DB-006 数据库安装失败未中止，返回码被吞

**位置**：`include/mysql.sh` 的 `Install_MySQL_80` / `Install_MySQL_84`，
`install.sh` 的 `Init_Install`、`LNMP_Stack` / `LNMPA_Stack` / `LAMP_Stack`，
`include/only.sh` 的 `Install_Only_Database`。

**问题**：两处 `mysqld --initialize-insecure` 未检查返回码（MariaDB 侧原本已有
`|| return 1`）；且 `Dispatch "${DB_Install}"` 的返回码在 `install.sh` 与
`only.sh` 两个调用点都未被接收，`Init_Install` 的返回码又由其最后一条命令决定。
结果是数据库整段安装失败后流程照常继续，入口退出码仍为 0。

**行为变化**：

- MySQL 两处初始化加返回码判断，失败时打印数据目录并 `return 1`。
- `Init_Install` 内 `Dispatch "${DB_Install}" || return 1`。
- 三个栈函数改为 `Init_Install || return 1`，`Install_Only_Database` 内
  `Dispatch "${DB_Install}" || return 1`，非零一路传到入口退出码。

**验证**：

- 定向对照测试（stub 掉除数据库分发外的全部步骤，令 `Dispatch` 返回 1）：
  修复前 `Init_Install` 与 `LNMP_Stack` 均返回 0，修复后均返回 1。
- Debian 13 实测前提：`mysqld --initialize-insecure` 指向非空数据目录时退出码为 1，
  即失败确实以非零返回，判断条件成立。
- `AUDIT-DB-005` 的失败分支实测中，`./install.sh db` 退出码为 1，
  确认解压阶段的失败同样传播到入口。

- **验证状态**：已实测（定向对照 + Debian 13）。

## AUDIT-DB-007 残留的 /tmp/mysql.sock 阻断数据库启动

**位置**：`include/dbcommon.sh` 的 `Clean_Stale_DB_Socket`，
`include/mysql.sh` 的 `MySQL_Sec_Setting`、`include/mariadb.sh` 的
`Mariadb_Sec_Setting`。

**问题**：数据库进程被 `kill -9`、OOM 杀死或断电后，`/tmp/mysql.sock` 作为陈旧
文件残留且无进程持有。mysqld/mariadbd 不会覆盖已存在的 socket 文件，而是以
`Can't start server : Bind on unix socket: Address already in use` 退出。
Debian 13 实测：数据目录初始化成功，但 `mysql.service` 反复启动失败，
设置 root 密码、删除匿名用户等初始化步骤随之全部失败，
手工 `rm -f /tmp/mysql.sock` 后立即可正常启动。

**行为变化**：新增 `Clean_Stale_DB_Socket`，在 MySQL 与 MariaDB 启动数据库之前
调用。socket 路径取自 `/etc/my.cnf` 的 `[mysqld]` 段（缺省 `/tmp/mysql.sock`）。
文件不存在时直接返回；`fuser` 或 `ss -lx` 显示仍被进程使用时报错返回非零、
不删除任何文件；确认无进程持有才删除并打印说明。

**验证**（Debian 13，MySQL 8.4.7）：

- 服务运行中调用：返回 1，打印 `正在被进程使用`，socket 文件保留，实例不受影响。
- `pkill -9` 模拟异常终止后调用：识别为无进程持有，删除 socket，返回 0。
- 清理后 `systemctl start mysql` 恢复 `active`。
- 函数级测试另外覆盖：socket 路径不存在时返回 0；活动 socket 能被
  `fuser`/`ss -lx` 正确识别为占用。

- **验证状态**：已实测（Debian 13）。

## FIX-UNINSTALL-002 卸载只 disable 服务，systemd unit 文件残留

**位置**：`include/main.sh` 的 `Remove_StartUp`。

**问题**：`Remove_StartUp` 只执行 `systemctl disable`，不删除本包部署到
`/etc/systemd/system/` 的 unit 文件。卸载后 `nginx.service`、`php-fpm.service`、
`mysql.service` 等仍留在系统里，`ExecStart` 指向已被删除的
`/usr/local/nginx/sbin/nginx`、`/usr/local/php/sbin/php-fpm`。
三份管理脚本的 `Service_Exists` 以 unit 文件存在作为服务已安装的判据，于是
后续只装数据库的机器上，`lnmp start` 会去启动根本不存在的 nginx 与 php-fpm：

    正在启动 LNMP...
    Job for nginx.service failed because the control process exited with error code.
    Job for php-fpm.service failed because the control process exited with error code.
    警告：以下服务的 systemd 状态不是活动状态（active）： nginx php-fpm

`lnmp status` 同样打印这些已卸载服务的失败状态。Debian 13 实测复现。

**行为变化**：`Remove_StartUp` 在 disable 之后删除本包部署的 unit 并
`systemctl daemon-reload`。判定"本包部署"看 `ExecStart`：指向 `/usr/local/` 下的
二进制（nginx、php-fpm、httpd、pureftpd、redis），或包装
`/etc/init.d/<服务名>`（mysql、mariadb、memcached）。发行版自带的同名 unit 位于
`/lib/systemd/system`，不受影响。调用点全部为卸载与 mysql→mariadb 迁移场景。

**验证**：

- 匹配规则覆盖检查：`init.d/` 下 8 个 unit 模板（httpd、mariadb、memcached、
  mysql、nginx、php-fpm、pureftpd、redis）全部命中。
- 负向检查：`ExecStart=/usr/sbin/nginx`、`ExecStart=/opt/custom/bin/mariadbd`
  两种外部 unit 均不命中。
- Debian 13 实测：构造 `ExecStart=/usr/local/faketest/sbin/faketest` 的 unit 与同名
  init 脚本，`Remove_StartUp faketest` 后 unit 已删除；同时构造
  `ExecStart=/usr/sbin/extsvc` 的外部 unit，`Remove_StartUp extsvc` 后该 unit 保留。
- 清除历史残留 unit 后复验：只装 MariaDB 的机器上 `lnmp status|stop|start|restart`
  均输出 `Nginx: 未检测到已安装服务，跳过 …`、`PHP-FPM: 未检测到已安装服务，跳过 …`，
  只对 mariadb 生效，返回码 0，服务状态在 inactive/active 间正确切换。

- **验证状态**：已实测（Debian 13）。

## AUDIT-STACK-001 补装组件时保留既有管理栈

**位置**：`include/end.sh` 的 `Detect_Installed_LNMP_Command_Stack` /
`Install_Current_LNMP_Command` / `Install_LNMP_Command`，`include/only.sh` 的独立
安装入口。

**行为变化**：独立安装先按 `/bin/lnmp` 的内容特征（`lnmpa_start()` /
`lamp_start()`）识别已有管理栈，按识别结果重新部署同类型脚本；`/bin/lnmp`
不存在时回退到调用方给出的默认值。

**验证**（Debian 13）：依次把 `conf/lamp`、`conf/lnmpa`、`conf/lnmp` 部署为
`/bin/lnmp`，每次执行独立安装使用的 `Install_Current_LNMP_Command lnmp`：

| 已有 /bin/lnmp | 识别结果 | 调用后类型 | 与 conf 源文件一致 |
|---|---|---|---|
| conf/lamp | lamp | lamp | 是 |
| conf/lnmpa | lnmpa | lnmpa | 是 |
| conf/lnmp | lnmp | lnmp | 是 |
| 不存在 | —（回退） | lnmp | 是 |

即在已有 LAMP / LNMPA 上补装组件不会把管理脚本覆盖成 LNMP。
补装后的新服务由三份脚本各自的 `Detect_Managed_Services` 纳管，其实现已逐份
比对一致（均优先 mariadb、回退 mysql，按实际存在的 unit 或 init 脚本判定）；
LNMP 栈的动态纳管已在 `AUDIT-SERVICE-001` 中实测。

**遗留**：在真实 Apache（LAMP/LNMPA）环境下补装数据库后由原栈整体命令启停的
端到端验证，需要源码编译 Apache，保留为待人工真机验证。

- **验证状态**：已实测（Debian 13，管理脚本类型保持）；Apache 端到端待人工验证。

## AUDIT-SYSTEMD-001 systemd 实际运行能力判断

**位置**：`include/main.sh` 的 `Systemd_Is_Running`，`include/nginx.sh`。

**行为变化**：删除按环境名称（WSL 等）判断的分支，只依据 `/run/systemd/system`、
`systemctl` 可用性和实际 unit 文件判断 systemd 能力。

**验证**（Debian 13 完整安装 nginx-1.30.4 + php-8.3.33 + mariadb-11.8.8）：
`/run/systemd/system` 存在；三个服务均通过 systemd 管理，
`systemctl is-enabled` 全部为 `enabled`、`is-active` 全部为 `active`；
`lnmp restart` 返回 0 后三服务同时回到 `active`，站点访问返回 200。
独立安装阶段（仅 MariaDB、随后补装 Nginx）同样走 systemd 路径。

- **验证状态**：已实测（Debian 13）。

## AUDIT-SERVICE-001 分阶段补装后的服务动态纳管

**位置**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp` 的 `Detect_Managed_Services`
及整体启停与状态函数。

**行为变化**：管理脚本每次运行重新检测当前实际存在的服务，未安装项跳过，
后续补装的服务自动纳入整体命令。

**验证**（Debian 13，按阶段递进）：

| 阶段 | 已装组件 | `lnmp status/start/stop/restart` 实际行为 |
|---|---|---|
| A | 仅 MariaDB（`./install.sh db`） | `Nginx: 未检测到已安装服务，跳过 …`、`PHP-FPM: 未检测到已安装服务，跳过 …`，只对 mariadb 生效；stop 后 `inactive`，start 后 `active`，返回码 0 |
| B | 补装 Nginx（`./install.sh nginx`） | nginx 自动纳入，php-fpm 仍跳过；`lnmp stop` 后 nginx 与 mariadb 同时 `inactive`，`lnmp start` 后同时 `active`，站点恢复 200 |
| C | 完整安装（nginx+php-fpm+mariadb） | 三个服务全部纳管，`lnmp restart` 返回 0，三者均回到 `active` |

前置修复：阶段 A 最初复现出 `lnmp start` 去启动已卸载的 nginx/php-fpm，
根因是卸载残留 systemd unit，见 `FIX-UNINSTALL-002`；清除残留后行为如上表。

- **验证状态**：已实测（Debian 13，LNMP 栈三阶段）；LNMPA/LAMP 栈的
  `Detect_Managed_Services` 实现已逐份比对一致，端到端待 Apache 环境验证。

## AUDIT-COMMAND-001 管理命令双路径与 755 权限

**位置**：`include/end.sh` 的 `Install_LNMP_Command` / `Sync_LNMP_Command_Alias`，
`include/only.sh` 的独立安装入口，`install.sh` 的入口收尾同步。

**行为变化**：完整安装与独立安装统一部署 `/bin/lnmp` 并同步 `/usr/bin/lnmp`，
权限固定为 755。

**验证**（Debian 13，三条安装路径）：

| 安装方式 | /bin/lnmp | /usr/bin/lnmp | 权限 | 内容一致 | 子命令 |
|---|---|---|---|---|---|
| `./install.sh db`（MariaDB 11.8.8） | 存在 | 存在 | 755 / 755 | md5 相同 | `lnmp status` 返回 0 |
| `./install.sh nginx`（补装） | 存在 | 存在 | 755 / 755 | md5 相同 | `lnmp status/stop/start` 返回 0 |
| `./install.sh lnmp`（完整） | 存在 | 存在 | 755 / 755 | md5 相同 | `lnmp restart` 返回 0 |

另外确认：独立安装失败（返回非零）时不部署管理命令，属预期行为——
`Install_Only_Database` 仅在 `rc=0` 时调用 `Install_Current_LNMP_Command`。

- **验证状态**：已实测（Debian 13）。

## FIX-VHOST-001 管理脚本补建的 default 与安装时生成的不一致

**位置**：`conf/lnmp` 的 `Add_VHost_Default`，对照 `include/nginx.sh` 的
`Write_Nginx_Default_VHost`。

**问题**：`lnmp vhost add` 输入 `default` 且配置缺失时，由 `conf/lnmp` 内的一份
独立模板补建。该模板缺少 `Write_Nginx_Default_VHost` 里按内核版本追加
`reuseport` 的判断，注释也没有同步。Debian 13 实测：安装生成的是
`listen 80 default_server reuseport;`，补建出来的是 `listen 80 default_server;`，
两份文件 1143 与 892 字节，同一台机器上 default 站点的监听参数取决于它是
装出来的还是补建出来的。

**行为变化**：`Add_VHost_Default` 采用与 `Write_Nginx_Default_VHost` 相同的内核
判断生成 `listen_extra`，注释同步。两处模板文本除网站目录变量外逐字符一致
（已用脚本比对确认）。

**验证**（Debian 13）：删除 `vhost/default.conf` 后执行 `lnmp vhost add` 输入
`default`，补建结果与安装时生成的文件 `diff` 无差异，`nginx -t` 通过，
站点访问 200。

- **验证状态**：已实测（Debian 13）。

## AUDIT-VHOST-008 三栈 vhost add 前置 default 提示

**位置**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp` 的 `Print_Default_Site_Intro` /
`Add_VHost`。

**行为变化**：三份 `Add_VHost()` 的首个实际语句统一为 `Print_Default_Site_Intro`，
在任何域名输入前说明 default 的用途、根目录与 SSL 入口；LNMP 输入 `default`
后不再重复打印。

**验证**（Debian 13，LNMP 栈）：`lnmp vhost add` 的输出顺序为——先打印
default 兜底站点说明（保留名、未匹配请求与 IP 直连都会进入、根目录
`/home/wwwroot/default`、配 SSL 走 `lnmp ssl add` 填 `default`），然后才是
`请输入域名(示例: www.example.com):`。输入 `default` 时说明只出现一次。
空输入与 EOF 分别给出 `域名不能为空。` 和明确的 EOF 提示。
LNMPA / LAMP 两份脚本的同名函数与调用位置已比对一致，端到端待相应栈环境验证。

- **验证状态**：已实测（Debian 13，LNMP 栈）。

## AUDIT-VHOST-009 LNMP 输入 default 的保留站点处理

**位置**：`conf/lnmp` 的 `Add_VHost_Default` / `Add_VHost`。

**行为变化**：检测到域名为 `default` 时只检查内置配置，不按普通域名继续询问
目录、伪静态和日志；配置存在即返回，缺失时补建，补建后配置测试失败则回滚。

**验证**（Debian 13，三条路径）：

| 场景 | 结果 |
|---|---|
| `vhost/default.conf` 已存在 | 直接返回 0，不再询问任何站点选项，文件 md5 未变，未产生重复 server 块 |
| 配置缺失 | 打印 `未找到 vhost/default.conf，现场补建…`，`nginx -t` 通过后 reload，补建内容与安装时生成的完全一致（见 `FIX-VHOST-001`） |
| 补建后配置测试失败 | 注入重复 `default_server` 的 vhost 触发 `nginx: [emerg] a duplicate default server`，打印 `已撤销刚补建的默认站点配置。`，`default.conf` 未残留，命令退出码为 1 |

- **验证状态**：已实测（Debian 13）。

## FIX-PMA-009 phpMyAdmin 入口片段带入全站 PHP 规则，突破 default 静态边界

**位置**：`include/php.sh` 的 phpMyAdmin nginx 片段生成（LNMP 与 LNMPA 两个分支），
`include/nginx.sh` 与 `conf/lnmp` 的 default 模板注释。

**问题**：片段首行是 `include enable-php.conf;`（LNMPA 为
`include proxy-pass-php.conf;`）。该文件是全站 PHP 执行/反代入口，随片段被
`include phpmyadmin.*.conf;` 引入 default 后，default 站点根目录下的任意 `.php`
都会被执行。Debian 13 实测：启用 phpMyAdmin 时向 `/home/wwwroot/default/` 放
`probe.php`，`GET /probe.php` 返回 200 并输出 `PHP_EXECUTED_8.3.33`；
禁用后同一请求返回 404。即 default 的静态边界随 phpMyAdmin 开关被打开。

**行为变化**：两个分支都不再 include 全站 PHP 规则。phpMyAdmin 的 PHP 由片段
内自带的处理完成——LNMP 走内层
`location ~ ^/<路径>/(.+\.php)$`（已含 `fastcgi_pass`、`fastcgi.conf`、
`SCRIPT_FILENAME` 与 `open_basedir`），LNMPA 走
`location ^~ /<路径>/ { proxy_pass … }`。外层 `^~` 前缀匹配优先于 default 中
拒绝 PHP 的正则，phpMyAdmin 可用性不受影响。

**验证**（Debian 13，LNMP + php-8.3.33）：清理后重新执行
`./install.sh phpmyadmin`，新片段首行为 `location = /<路径>`，不再有
`include enable-php.conf`：

| 请求 | 修复前 | 修复后 |
|---|---|---|
| `GET /probe.php`（default 根目录，phpMyAdmin 启用） | 200，输出 `PHP_EXECUTED_8.3.33` | 404 |
| `GET /<pma路径>/` | 200 | 200 |
| `GET /<pma路径>/index.php` | 命中 phpMyAdmin 页面 | 命中 phpMyAdmin 页面 |
| `GET /<pma路径>`（无斜杠） | 301 | 301 |

LNMPA 分支为同一处改动的对称修改，待 LNMPA 环境验证。

- **验证状态**：已实测（Debian 13，LNMP 分支）；LNMPA 分支待相应环境验证。

## FIX-PMA-010 安装过程打印冒烟重试中的 404，易被误认为故障

**位置**：`include/php.sh` 的 `Smoke_Test_PhpMyAdmin_HTTP`。

**问题**：该函数最多重试 5 次访问 phpMyAdmin 入口，`curl -fsS` 的 `-S` 让每次
失败都把错误打到 stderr。配置刚写完、nginx 刚 reload 时首次请求通常还是 404，
于是安装成功的流程里也会出现一行
`curl: (22) The requested URL returned error: 404`，与仓库既有约定
（正常流程不打印会被误认为故障的错误）不一致。

**行为变化**：中间失败的错误先收集，仅在五次全部失败时打印最后一次的原因。

**验证**（Debian 13）：函数级测试——可用 URL 返回 0 且无任何输出；
不存在的 URL 返回 1 并打印 `curl: (22) The requested URL returned error: 404`。
重新执行 `./install.sh phpmyadmin` 的完整日志中该行出现次数为 0，安装照常成功。

- **验证状态**：已实测（Debian 13）。

## AUDIT-VHOST-003 phpMyAdmin 条件 PHP 入口与回滚

**位置**：`include/php.sh` 的 phpMyAdmin 配置逻辑，`tools/lnmp-phpmyadmin.sh`
的 `enable|disable|status`。

**行为变化**：phpMyAdmin 入口片段随开关整体挂载或撤下，切换前做配置测试，
失败恢复原状态。

**验证**（Debian 13，LNMP）：

| 操作 | 结果 |
|---|---|
| `lnmp phpmyadmin disable` | 片段改名为 `.phpmyadmin.enable.conf.disabled`，reload 后 pma 入口 404、default 根目录 `.php` 404、首页仍 200；`default.conf` 中的 `include phpmyadmin.*.conf;` 保留，通配符无匹配文件不报错 |
| `lnmp phpmyadmin enable` | 片段恢复，pma 入口 200，返回码 0 |
| 注入语法错误的 vhost 后 `disable` | `nginx -t` 失败，打印 `网站配置测试或重载失败，已恢复之前的访问状态。`，退出码 1，片段恢复为启用态；清除注入文件后 `nginx -t` 通过、pma 仍 200 |

补充说明：`enable|disable` 只做片段文件改名，不重新生成内容；片段模板的改动
需重新执行 `./install.sh phpmyadmin` 才会生效。切换后需等 nginx 完成 reload，
命令返回后 1 秒内即可观察到新状态（reload 期间旧 worker 仍会服务新连接）。

- **验证状态**：已实测（Debian 13，LNMP 栈）。

## FIX-BK-010 backup init 的定时任务安装失败被忽略，仍报告成功

**位置**：`tools/lnmp-backup.sh` 的 `Write_Systemd_Unit`、`Write_Cron`
及 `Cmd_Init` 的调用点。

**问题**：`Write_Systemd_Unit` 里两处 `cat > unit 文件` 与 `chmod` 的失败都没有
判定；`Cmd_Init` 调用 `Write_Systemd_Unit` / `Write_Cron` 时也没有接返回值。
结果是 unit 写不进去时，`lnmp backup init` 照常打印结尾摘要并返回 0，配置文件
已写好但定时任务根本没装上——直到需要恢复时才会发现从来没有备份过。
Debian 13 实测：把 `/etc/systemd/system/lnmp-backup.timer` 预先建成目录使写入
必然失败，修复前 init 退出码仍为 0，摘要照常打印，全程没有任何相关提示。

**行为变化**：

- `Write_Systemd_Unit`、`Write_Cron` 对每处写文件与 `chmod` 判定成败，
  失败时打印具体路径并返回非零。
- `Cmd_Init` 记录定时任务安装结果，失败时在摘要之后追加
  `配置已写入，但定时任务未能安装，备份不会自动执行。` 与后续处理建议，
  并以非零退出。

**验证**（Debian 13）：

- 失败注入（timer 路径为目录）：退出码 1，输出上述两行红字提示。
- 恢复后正常执行：退出码 0，输出 `已启用 systemd timer：每天 3:30 前后执行（带随机延迟）。`，
  `systemctl is-active lnmp-backup.timer` 为 `active`，unit 中
  `OnCalendar=*-*-* 3:30:00`。

- **验证状态**：已实测（Debian 13）。

## AUDIT-BACKUP-INIT-001 backup init 完整交互流程

**位置**：`tools/lnmp-backup.sh` 的 `Cmd_Init`、`Notice_Review_Conf`。

**验证**（Debian 13，`t/pty_run.py` 提供真实 pty）：完整走通
确认 → 站点扫描 → 数据库凭据校验 → 备份目录 → 执行时间 → 摘要，退出码 0。

- 开头依次打印配置文件位置、上传功能前置条件、Ctrl+C 修改配置的说明，
  之后才要求输入 `y`。
- 站点扫描列出 `_ | /home/wwwroot/default` 与 `site1.test | /home/wwwroot/site1.test`
  两条，并给出全选、按序号、排除三种选法；回车为全选。
- 数据库口令不回显，校验通过后写入 `/etc/lnmp/backup-mysql.cnf`（600）。
- 备份目录回车取默认 `/home/backup`；配置写入 `/etc/lnmp/backup.conf`（600）。
- 结尾摘要只有配置位置、备份目录和四条常用命令。

- **验证状态**：已实测（Debian 13，真实 pty）。

## AUDIT-BACKUP-INIT-002 backup init 的 systemd timer 安装

**位置**：`tools/lnmp-backup.sh` 的 `Cmd_Init` 与 `Write_Systemd_Unit`。

**验证**（Debian 13）：

| 场景 | 结果 |
|---|---|
| 首次安装 | `lnmp-backup.timer` 为 `enabled` + `active`，`systemctl list-timers` 显示次日 03:31 触发（`RandomizedDelaySec=1800` 生效）；unit 含 `Persistent=true`，service 为 `Type=oneshot`、`ExecStart=/bin/lnmp-backup run`、`Nice=10`、`IOSchedulingClass=idle` |
| 重复初始化选 `n` | 打印 `配置已存在`，保留现有配置，文件 md5 未变，不产生 `.bak` 文件，退出码 0 |
| 重复初始化选 `y` | 旧配置备份为 `backup.conf.bak.<时间戳>`，沿用已有数据库凭据文件，timer 的 `OnCalendar` 更新为新选择的时间并重新生效 |
| timer 安装失败 | 见 `FIX-BK-010`：提示明确、退出码 1 |

- **验证状态**：已实测（Debian 13）。

## AUDIT-BACKUP-INIT-003 backup init 非交互调用兼容性

**位置**：`tools/lnmp-backup.sh` 的 `Cmd_Init` 确认输入逻辑。

**验证**（Debian 13）：三种非交互输入均立即返回、不等待、不产生任何改动。

| 输入方式 | 结果 |
|---|---|
| `< /dev/null`（无 stdin，EOF） | 打印确认提示后输出 `已取消。`，退出码 0 |
| 管道输入 `n` | `已取消。`，退出码 0 |
| 管道输入空行 | `已取消。`，退出码 0 |

三种情况均未创建或修改 `/etc/lnmp/backup.conf`、`/etc/lnmp/backup-mysql.cnf`
与定时任务。

- **验证状态**：已实测（Debian 13）。

## AUDIT-BACKUP-001 大库与大站点备份压力

**位置**：`tools/lnmp-backup.sh`。

**验证环境**：Debian 13、8 核 / 5.8G 内存、MariaDB 11.8.8，根分区剩余 24G。
数据为不可压缩的真随机内容：

- 数据库 `wpbig`：65536 行 × 16KB `LONGBLOB`，表大小 2026MB。
- 站点 `/home/wwwroot/site1.test`：3.0GB（两个 1.5GB 随机大文件 + 2000 个小文件）。

**实测结果**（`lnmp backup run all`，退出码 0）：

| 指标 | 实测值 |
|---|---|
| 总耗时 | 120 秒（库导出约 40 秒，站点打包约 80 秒） |
| 相关进程 RSS 峰值 | 约 5.0MB（`mariadb-dump`/`tar`/`gzip`/脚本合计，每 3 秒采样 41 次） |
| 备份期间最低可用磁盘 | 19975MB，全过程无临时空间尖峰 |
| 备份目录最终占用 | 4050MB |
| 库产物 | `db-wpbig.sql.gz` 1.1G + `SHA256SUMS` |
| 站点产物 | `www-site1.test.tar.gz` 3.0G、`www-_.tar.gz` 7.8K + `SHA256SUMS` |

结论：导出与打包全程为流式（`mariadb-dump | gzip`、`tar | gzip` 直接写目标文件），
不落中间临时文件，因此磁盘需求约等于最终备份体积，内存占用与数据量无关、
恒定在数 MB 级别。随机数据下库压缩比约 0.54，站点几乎不可压缩，
实际站点的可压缩内容会显著小于此值。

**遗留**：目标磁盘空间不足时的退出码与残留文件清理未在本轮覆盖，
保留在 todo 中单列。

- **验证状态**：已实测（Debian 13，2GB 库 + 3GB 站点）。

## FIX-TOOLS-002 tools 脚本在源码目录外执行时静默缺失公共函数

**位置**：`tools/reset_mysql_root_password.sh`、`tools/denyhosts.sh`、
`tools/fail2ban.sh`、`tools/remove_disable_function.sh`、
`tools/remove_open_basedir_restriction.sh`。

**问题**：五个脚本都用 `cur_dir=$(cd "$(dirname "$0")/.." && pwd)` 推导源码根目录，
再 `. "${cur_dir}/include/main.sh"`。脚本被复制到源码目录之外执行时该路径是错的
（例如放在 `/root` 下推导出 `/`，加载 `//include/main.sh`），而 source 失败没有
被检查，脚本继续往下跑。Debian 13 实测：从 `/root` 执行密码重置脚本，输出
`//include/main.sh: No such file or directory` 与 `Print_Banner: command not found`
后仍继续执行了整个重置流程——本次只是横幅缺失，但 `Echo_Red`、`First_Executable`
等公共函数同样缺失，任何依赖它们的分支都会静默走偏。

**行为变化**：五个脚本在加载前检查 `${cur_dir}/include/main.sh` 是否存在，
缺失时打印实际路径与正确用法并以 1 退出。

**验证**（Debian 13）：把脚本复制到 `/root` 执行，输出
`错误：找不到 //include/main.sh。` 与 `请在 LNMP 源码目录内执行本脚本…`，
退出码 1，不再继续执行；在源码目录内执行 `./tools/reset_mysql_root_password.sh`
正常打印横幅并进入 `检测到：mariadb 11.8.8` 流程。

- **验证状态**：已实测（Debian 13）。

## AUDIT-DB-004 MariaDB 11.8 新旧客户端命令兼容

**位置**：`include/mariadb.sh`（含新增的 `Rewrite_MariaDB_Initd_Names`）、
`include/upgrade_mariadb.sh`、`include/upgrade_mysql2mariadb.sh`、
三份 `conf` 管理脚本、`tools/lnmp-backup.sh`、
`tools/reset_mysql_root_password.sh`。

**补充修复**：`/etc/init.d/mariadb` 是上游 `support-files/mysql.server` 的原样
拷贝，内部按 `$bindir/mysqld_safe`、`$bindir/mysqladmin` 调用，直指
`/usr/local/mariadb/bin`，绕过了 `/usr/bin` 下的新名包装。Debian 13 实测：
完整安装后每次启动服务都会在 journal 中打印
`/usr/local/mariadb/bin/mysqld_safe: Deprecated program name. … use 'mariadbd-safe' instead`。
新增 `Rewrite_MariaDB_Initd_Names`，在安装、升级、MySQL→MariaDB 迁移三个
拷贝点之后按实际存在的新名改写 init 脚本；对应新名不存在时保留原样，
函数可重复执行。

**验证**（Debian 13，MariaDB 11.8.8 全新安装）：

| 项目 | 结果 |
|---|---|
| `mysql --version` / `mysqldump --version` | 正常输出版本，stderr 无任何弃用提示 |
| `mariadb --version` | `mariadb from 11.8.8-MariaDB, client 15.2` |
| init 脚本改写 | `$bindir/mysqld_safe` → `$bindir/mariadbd-safe`、`$bindir/mysqladmin` → `$bindir/mariadb-admin`，重复执行结果不变 |
| `systemctl restart mariadb` | 服务 `active`，journal 中 `Deprecated program name` 计数为 0，实际进程为 `mariadbd-safe` |
| `lnmp database list` | 列出全部数据库，stderr 干净 |
| `lnmp database add` | 建库建用户成功，stderr 干净 |
| `lnmp database export <库> <文件.sql.gz>` | 导出成功，stderr 干净 |
| `lnmp database import <库> <文件.sql.gz>` | 导入成功，数据行数与导出前一致，stderr 干净 |
| `lnmp database edit` | 改密成功，新密码可登录，stderr 干净 |
| `lnmp database del` | 删库成功，列表中不再出现，stderr 干净 |
| `lnmp backup run all` | 退出码 0，库与站点均备份成功，stderr 干净 |
| `tools/reset_mysql_root_password.sh` | 重置成功，优先选用 `mariadbd-safe`，全程无弃用提示，新密码可登录 |
| MySQL 8.4.7 路径 | 单独安装验证 `mysql --version` 输出正常、stderr 干净，不受本项改动影响 |

- **验证状态**：已实测（Debian 13，MariaDB 11.8.8 + MySQL 8.4.7）。

## AUDIT-VHOST-007 Cloudflare 与反代链真实访问者 IP 日志

**位置**：`conf/nginx.conf`、`conf/nginx_a.conf`、`conf/openresty.conf` 的
`log_format main` 与可信代理注释示例（`log_client_ip` / `main_proxy`）。

**行为变化**：代理日志示例优先取 `X-Forwarded-For` 逗号列表首项，缺失时降级到
`X-Real-IP`，再缺失才用连接源地址，并额外保留 `peer=$remote_addr` 以便追查
代理链。默认仍使用 `main` 格式，直接记录 `$remote_addr`。

**验证**（Debian 13）：按注释启用两段 `map` 与 `main_proxy`，把 default 站点的
`access_log` 改为 `main_proxy` 后 `nginx -t` 通过并 reload，逐类发送请求：

| 请求头 | 日志客户端 IP 字段 | peer 字段 |
|---|---|---|
| `X-Forwarded-For: 203.0.113.7, 198.51.100.9, 10.0.0.1` + `X-Real-IP: 198.51.100.9` | `203.0.113.7`（取首项） | `192.0.2.10` |
| 仅 `X-Real-IP: 198.51.100.22` | `198.51.100.22` | `192.0.2.10` |
| 两个头都不带 | `192.0.2.10`（连接源） | `192.0.2.10` |
| `X-Forwarded-For:   203.0.113.99 , 10.0.0.2`（含前导与列表内空格） | `203.0.113.99` | `192.0.2.10` |

三层降级与空白处理均符合预期，原始 `$http_x_forwarded_for` 始终保留在行尾。

直连场景：恢复默认 `main` 格式后，同一台机器上带
`X-Forwarded-For: 203.0.113.7`、`X-Real-IP: 198.51.100.9` 的请求，日志客户端字段
仍为连接源（以文档示例地址 `192.0.2.10` 表示），伪造的头只作为原始字段记录，不参与取值——
默认配置不会把外部请求头当作可信来源。

- **验证状态**：已实测（Debian 13，编译 Nginx）。

## AUDIT-VHOST-010 default IP 证书申请流程（菜单与前置检查部分）

**位置**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp` 的独立 SSL 入口与 default
SSL/IP 证书处理函数（`Detect_Server_IP`、`Is_Private_IP`、
`Print_Self_Signed_Hint` 等）。

**行为变化**：`lnmp ssl add` 输入域名后先检查是否已有虚拟主机；不存在则提示先
执行 `lnmp vhost add` 并退出，不再重复询问目录、伪静态、日志、Pathinfo 和
IPv6。`default` 只显示自有证书与 Let's Encrypt 两项，并转入服务器 IP 的
shortlived 证书流程；写入 443 配置前备份现有 vhost，失败时恢复原 HTTP 站点。

**验证**（Debian 13，NAT 环境）：

| 场景 | 结果 |
|---|---|
| 输入不存在的域名 `nosuch.example.com` | 打印 `未找到网站 … 的虚拟主机配置。` 与 `请先执行 lnmp vhost add …`，退出码 1，不再询问任何站点选项 |
| 输入已存在的普通域名 `site1.test` | 显示 4 项证书来源（自有 / Let's Encrypt / BuyPass / ZeroSSL） |
| 输入 `default` | 只显示 2 项（自有 / Let's Encrypt），符合"IP 证书只有 Let's Encrypt 提供"的限制 |
| `default` + Let's Encrypt | 打印 default 站点证书说明并自动转入 IP 证书流程；探测到对外 IPv4 后逐条列出 shortlived 限制（7 天有效期、`--days 6` 续期、仅 IPv4、仅 Let's Encrypt、80 端口需公网可达、邮箱不能用保留域名），并针对 NAT 环境额外警告"探测到的是出口地址，未必指向本机"并给出自查方法 |
| 邮箱填 `test@example.com` | Let's Encrypt 返回 `invalidContact / forbidden domain`，脚本打印 `SSL 证书签发失败。`，退出码 1 |
| 签发失败后的站点状态 | `vhost/default.conf` 中 `listen 443` / `ssl_certificate` 均为 0 处，`nginx -t` 通过，HTTP 站点仍返回 200，未残留脚本自身的备份文件 |

失败后 `conf/ssl/<IP>_ecc/` 下会留下 acme.sh 自己的 `<IP>.conf`（无证书内容），
属 acme.sh 的正常产物，重试时复用。

真实签发已在 80 端口可从公网访问的主机上人工验证：`default` 站点通过 Let's Encrypt
取得 IP 证书，acme.sh 完成 HTTP-01 验证与 reload，443 配置写入后 `nginx -t` 通过。
`--days 6` 的续期在有效期内触发，未随本次验证观察。

- **验证状态**：已实测（Debian 13，菜单与前置检查、失败回滚；真实 IP 证书签发由
  公网主机人工验证，2026-08-17）。

## AUDIT-I18N-001 终端中文提示与 banner 对齐

**位置**：顶层安装、升级与卸载脚本，`include/*.sh`，三份管理脚本
`conf/lnmp`、`conf/lnmpa`、`conf/lamp`，以及 `tools/*.sh`、`init.d/*`
（不含 `t/` 测试目录）。

**验证方式与结果**：

1. 静态扫描：对上述文件中所有 `echo` / `printf` / `Echo_*` / `Say` / `Err` /
   `Warn` / `Ok` 输出语句，筛出不含中文且包含三个以上英文单词的行，共 11 处，
   逐条确认全部属于按约定保留原样的内容——`dnf install brotli-devel` 等安装
   命令、`table inet lnmp` 等 nftables 配置片段、`systemctl enable --now nftables`
   等操作命令、Apache `IncludeOptional` 配置行、示例 SQL，以及伪静态规则名
   列表（wordpress、typecho、discuzx、laravel 等程序名）。没有待翻译的提示句。

2. 实跑覆盖（Debian 13）：本轮实测中经过的全部交互与输出均为中文——
   完整安装 `./install.sh lnmp`、独立安装 `nginx` / `db` / `phpmyadmin`、
   `./uninstall.sh lnmp`、`lnmp start|stop|restart|status`、
   `lnmp database add|list|edit|del|export|import`、`lnmp vhost add`、
   `lnmp ssl add`（含 default 的 IP 证书说明）、`lnmp phpmyadmin enable|disable`、
   `lnmp backup init|run`、`tools/reset_mysql_root_password.sh`。
   交互提示均标注了默认值或留空行为；EOF 与非法输入有明确的中文错误说明。
   上游程序（nginx、mariadb、acme.sh、curl、systemd）的原始输出保持原样。

3. banner 对齐：以短、中、超长中文标题及中英文数字混排标题调用
   `Print_Banner`，按 East Asian Width 计算每行显示宽度，边框与内容行均为 74 列，
   长文本触发边框整体扩展而非撑破。

**边界说明**：`——`、`…` 等 East Asian Width 为 Ambiguous 的字符，其显示宽度取决于
终端设置，任何静态计算都无法同时适配两种终端。已确认项目现有 banner 文案未使用
这类字符，新增标题时应同样避免。

- **验证状态**：已实测（Debian 13 + 静态扫描）。

## AUDIT-VHOST-011 编译 Nginx 与 OpenResty default 配置一致性

**位置**：`include/nginx.sh` 的 `Write_Nginx_Default_VHost`，
`include/openresty.sh` 的 `OpenResty_Post_Install`，
`conf/lnmp` 的 `Add_VHost_Default`。

**验证环境**：Debian 13 (trixie)，OpenResty 1.31.1.1（`WebSelect=2 ORMode=2`
源码编译）+ PHP 8.3.33 + MariaDB 11.8.8。

**验证方式与结果**：

1. 配置生成一致性：`Write_Nginx_Default_VHost` 内无 Web 类型分支，
   仅 `conf_dir`、`Default_Website_Dir` 与内核决定的 `listen_extra` 三个变量。
   在同一台机器上以编译 Nginx 的路径参数重新调用该函数，渲染结果与 OpenResty
   实际生成的 `vhost/default.conf` 逐字符一致（md5
   `bbc16a348691d1a42273d6c2bc635f1a`，1237 字节）。
   `conf/lnmp` 的 `Add_VHost_Default` 模板正文与之相同。

2. 路径兼容：OpenResty 安装建立软链接 `/usr/local/nginx ->
   /usr/local/openresty/nginx`，管理命令中按 `/usr/local/nginx/...`
   硬编码的配置与二进制路径在 OpenResty 环境下全部有效。

3. 运行行为（服务器 IP 直接访问）：根目录 `probe.php` 返回 404 且不吐源码；
   `/.well-known/acme-challenge/probe.txt` 返回 200 并输出文件内容；
   `/.git/config` 与 `/.env` 返回 403；`/` 返回 200 命中 default 首页；
   未知 Host 头同样落到 default。

4. 独立日志：`/home/wwwlogs/default.log` 按 `main` 格式记录（`$time_iso8601`
   起始，含状态码、请求耗时、来源地址、`$scheme://$http_host`、请求行、
   响应字节、referer、UA、XFF、remote_user）；403 请求同时写入
   `/home/wwwlogs/default.error.log`，内容为 `access forbidden by rule`。

**已确认（Debian 13，2026-08）**：OpenResty 官方仓库尚未发布 Debian 13 (trixie)
的预编译包，`ORMode=1`（pkg 模式）在探测阶段即中止且不留半成品。

- **验证状态**：已实测（Debian 13 + OpenResty 源码编译）。

## AUDIT-VHOST-012 OpenResty phpMyAdmin 集成（LNMP 栈部分）

**位置**：`include/openresty.sh` 的 `OpenResty_Post_Install`，
`include/php.sh` 的 phpMyAdmin 配置逻辑，`conf/openresty.conf`。

**验证环境**：同 `AUDIT-VHOST-011`，`./install.sh phpmyadmin` 独立安装
phpMyAdmin 5.2.3。

**验证方式与结果**：

1. 安装流程：源码包 SHA256 校验通过，`nginx -t` 通过后重载，
   输出随机化的访问地址；生成片段 `conf/phpmyadmin.enable.conf`。

2. `FIX-PMA-009` 复核：片段中已无 `include enable-php.conf;` 与
   `include proxy-pass-php.conf;`，PHP 处理由内层
   `location ~ ^/<前缀>_phpmyadmin/(.+\.php)$` 自带的 `fastcgi_pass` 完成。

3. 入口可用性：不带尾斜杠的入口返回 301 到带斜杠地址；入口页面返回 200、
   18571 字节，响应以 `<!doctype html>` 开头（PHP 已执行，非源码下载）；
   `index.php` 直接访问返回 200。

4. 边界：启用 phpMyAdmin 后 default 根目录的 `probe.php` 仍返回 404，
   `^~` 前缀匹配优先于正则的设计成立；片段中的 `open_basedir` 生效，
   phpMyAdmin 目录内的脚本读取 `/etc/passwd` 被拒绝。

5. 数据库连通：经 phpMyAdmin 入口执行的 mysqli 探针以 root 账号连接成功，
   返回 `11.8.8-MariaDB-log`；`config.inc.php` 中 `host` 为 `127.0.0.1`
   （避免 `localhost` 走 socket 绕过自定义端口），`AllowNoPassword` 为 false。

6. 管理端口：仅监听 `127.0.0.1:1008`（`nginx.conf` 中为
   `listen 127.0.0.1:1008;`），回环访问返回 200，从另一台主机访问同端口
   连接被拒（curl 退出码 7）。

**未覆盖**：LNMPA 栈的 Apache 反代部分，需额外源码编译 Apache，
仍留在 todo 中。

- **验证状态**：已实测（Debian 13 + OpenResty 源码编译，LNMP 栈）。

## FIX-VHOST-013 演示页开关在 default 静态边界下失效

**问题**：`Enable_PHPInfo_Page`、`Enable_Redis_Test_Page`、
`Enable_Memcached_Test_Page` 生成的页面写在 `${Default_Website_Dir}`，
而 default 站点对 `.php` 一律拒绝——nginx 侧 `location ~ [^/]\.php(/|$)`
返回 404，Apache 侧 `<FilesMatch "\.php$"> Require all denied`。
三个开关打开后页面文件存在但访问返回 404，`include/end.sh` 的安装摘要
仍打印 `phpinfo：http://IP/phpinfo.php`。Debian 13 实测三个页面均为 404。

**修改**：在各栈的 default 站点配置里按固定文件名放行这三个页面，
不引入随开关启停的配置片段——页面是否存在本身就是开关的结果，
文件不存在时请求自然按 404 处理。

- `include/nginx.sh` 的 `Write_Nginx_Default_VHost`：在拒绝 PHP 的正则之前
  插入 `location ~ ^/(phpinfo|redis|memcached)\.php$`。正则 location 按出现
  顺序匹配，本条在前即生效。LNMP 与 OpenResty 用
  `try_files $uri =404` + `fastcgi_pass unix:/tmp/php-cgi.sock`；
  `Stack=lnmpa` 时改为 `proxy_pass http://127.0.0.1:88` + `include proxy.conf`。
- `conf/lnmp` 的 `Add_VHost_Default`：同步同一段配置，保持补建结果与安装
  结果逐字符一致（沿用 `FIX-VHOST-001` 的约定）。
- `conf/httpd-vhosts-lamp.conf`、`conf/httpd-vhosts-lnmpa.conf`：在
  `<FilesMatch "\.php$"> Require all denied` 之后追加
  `<FilesMatch "^(phpinfo|redis|memcached)\.php$"> Require all granted`，
  后出现的 FilesMatch 覆盖前一条。
- `include/main.sh` 新增 `Warn_Demo_Page_Not_Served`：写入演示页后检查
  现有 default 站点配置是否含放行规则，缺失时打印中文提示，不改使用者
  可能已定制的配置，始终返回 0。`include/php.sh`（phpinfo）、
  `include/redis.sh`、`include/memcached.sh` 三处写入点各调用一次。
  本次修改之前装好的环境靠这条提示告知页面为何返回 404。

**验证方式与结果**（Debian 13 + OpenResty 1.31.1.1 + PHP 8.3.33）：

1. 复现：修改前把三个页面文件放入 default 根目录，访问全部返回 404。
2. 渲染分栈：同一函数以 `Stack=lnmp` 渲染出 fastcgi 版放行块，
   以 `Stack=lnmpa` 渲染出 proxy_pass 版，其余内容不变。
3. 修改后实测：`phpinfo.php` / `redis.php` / `memcached.php` 均返回 200，
   phpinfo 页面输出 `PHP Version 8.3.33`（PHP 已执行，非源码下载）。
4. 边界回归：default 根目录其它 `.php`（`probe.php`）仍返回 404；
   删除 `redis.php` 后该路径返回 404（`try_files` 生效）；
   `/sub/phpinfo.php`（`^/` 锚定）、`/phpinfo.php/x.php`（PATH_INFO 伪装）、
   `/phpinfo.phpx` 均返回 404；phpMyAdmin 入口不受影响，仍返回 200。
5. 补建路径：删除 `vhost/default.conf` 后执行 `lnmp vhost add` 并输入
   `default`，补建成功、`nginx -t` 通过，生成内容与安装时的模板逐字符一致。
6. `Warn_Demo_Page_Not_Served` 定向测试：老配置（无放行规则）打印提示并
   返回 0；新配置静默返回 0；nginx 与 Apache 配置都不存在时静默返回 0。

**未覆盖**：Apache 侧（LAMP 与 LNMPA 的 `<FilesMatch>` 放行）需要源码编译
Apache，本轮只做了配置语法确认，实跑留待 LNMPA/LAMP 栈验证时一并覆盖。

- **验证状态**：已实测（Debian 13，Nginx/OpenResty 侧）。

## FIX-BK-011 备份失败留下空批次目录，list 无法区分不完整批次

对应 `RUN-034` 中登记的 `AUDIT-BACKUP-006`（备份目标磁盘不足时的退出码
与残留清理）。

**位置**：`tools/lnmp-backup.sh` 的 `Run_Db`、`Run_Web`、`Cmd_List`。

**问题**：批次内所有产物都失败时（例如目标磁盘写满），`.part` 临时文件已被
删除、退出码也正确返回 1，但先前 `mkdir -p` 建出的批次目录留在原地。
`lnmp backup list` 会把它列成一个 `0 个文件` 的批次，并一直占着保留期。
`n=0`（没有站点配库或目录）的分支本就调用了 `rmdir`，失败分支漏了同一处理。
另外 list 只打印文件个数，中途失败的批次与完整批次在输出里没有区别。

**修改**：

- `Run_Db` 与 `Run_Web` 的失败分支各加一次 `rmdir "${dir}" 2>/dev/null`。
  `rmdir` 只删空目录：部分成功时目录非空，已产出的文件按现有约定保留，
  批次仍标记为不完整。
- `Cmd_List` 按 `SHA256SUMS` 是否存在给批次加 `[不完整：缺校验清单]` 标注。
  该清单只在批次全部产出成功后才写入，是现成的完整性判据。

**验证方式与结果**（Debian 13，20MB / 5MB tmpfs 作备份目标）：

1. 数据库全部失败：20000 行 BLOB 库导出到 20MB tmpfs，
   日志为 `gzip: stdout: No space left on device` 与
   `导出数据库 bktest 失败 (mysqldump=0 gzip=1)`，退出码 1；
   修改前留下空批次目录且 list 显示 `0 个文件`，修改后备份根目录下
   只剩类型目录、list 为空。
2. 数据库部分成功：小库先成功、大库写满失败，退出码 1；
   已产出的 `db-bksmall.sql.gz` 保留，批次在 list 中显示
   `1 个文件  [不完整：缺校验清单]`。
3. 完全成功：批次含产物与 `SHA256SUMS`，退出码 0，list 无标注。
4. 网站备份路径同样覆盖：20MB 随机数据打包到 5MB tmpfs，
   日志为 `打包 /home/wwwroot/bk.test 失败 (tar=141 gzip=1)`，退出码 1，
   空批次目录已清理、list 为空。

- **验证状态**：已实测（Debian 13）。

## FIX-UNINSTALL-003 卸载不清理 /etc/lnmp，残留含数据库口令的凭据文件

**位置**：`uninstall.sh` 新增 `Remove_Lnmp_Conf_Dir`，在
`Uninstall_LNMP` / `Uninstall_LNMPA` / `Uninstall_LAMP` 三处收尾各调用一次。

**问题**：`lnmp backup init` 在 `/etc/lnmp/` 下生成 `backup.conf` 与
`backup-mysql.cnf`，后者以 0600 保存数据库 root 口令。卸载会删掉
`/bin/lnmp-backup`，但整个目录原样保留。Debian 13 实测：完整卸载并重装后，
上一套环境的 `/etc/lnmp/backup-mysql.cnf` 仍在，其中的口令对应已被删除的
数据库实例，且会被误当成新实例的凭据。

**修改**：`Remove_Lnmp_Conf_Dir` 删除 `backup-mysql.cnf`（口令对应的实例已
不存在，留下只剩风险），其余文件按数据目录的既有约定搬到
`/root/lnmp_conf_backup_<时间戳>` 并打印去向，目录清空后 `rmdir`。
转移失败时打印保留位置与检查提示，不中止卸载——此时程序文件与数据库
已删完，中止没有意义，因此始终返回 0。

**验证方式与结果**（Debian 13，OpenResty + PHP 8.3.33 + MariaDB 11.8.8）：

1. 卸载前 `/etc/lnmp/` 含 `backup.conf`、`backup-mysql.cnf`、
   `openresty-build.conf` 三个 0600 文件。
2. `./uninstall.sh lnmp` 输出
   `已删除含数据库口令的 /etc/lnmp/backup-mysql.cnf。` 与
   `/etc/lnmp 下的其余配置已移到 /root/lnmp_conf_backup_20260815081426`。
3. 卸载后 `/etc/lnmp` 目录已不存在；全盘 `find / -name backup-mysql.cnf`
   无结果；转移目录内 `backup.conf` 与 `openresty-build.conf` 权限仍为 0600。
4. 重复执行卸载不报错，且因目录已不存在而直接返回，
   不会新建空的 `lnmp_conf_backup_*` 目录（实测仍为 1 个）。

- **验证状态**：已实测（Debian 13，LNMP 栈；LNMPA/LAMP 为同一函数的相同调用）。

## AUDIT-VHOST-002 禁用 Nginx Lua 后的管理端口配置

**位置**：`include/nginx.sh` 的 `Install_Nginx`。

**触发与影响**：`Enable_Nginx_Lua=n` 时若仍保留 `/lua` 指令，未编译 ngx_lua 的
Nginx 会因未知指令导致配置检查失败。

**当前实现**：禁用 Lua 时只删除本机管理端口中的 `/lua` location，保留
`nginx_status` 和其它管理配置。

**验证方式与结果**（Debian 13，`DBSelect=5 WebSelect=1 Enable_Nginx_Lua=n`
完整安装，nginx 1.30.4 + PHP 8.3.33 + MariaDB 11.8.8）：

1. 编译产物：`nginx -V` 的参数中无任何 lua 相关模块。
2. 配置：`nginx -t` 通过；`conf/` 下 `grep` 不到 `location /lua`、
   `content_by_lua`、`lua_package` 任何一处残留；管理端口块中
   `nginx_status`（`allow 127.0.0.1` / `allow ::1` / `deny all` /
   `stub_status on` / `access_log off`）完整保留。
3. 运行：回环访问 `127.0.0.1:1008/nginx_status` 返回 stub_status 计数；
   `127.0.0.1:1008/lua` 返回 404；从另一台主机访问 1008 端口连接被拒。
4. 站点回归：default 首页 200；`.git/config` 403；
   根目录其它 `.php` 404。

**同批复核**：本次以 `Enable_PHPInfo_Page=y` 安装，`FIX-VHOST-013` 在编译
Nginx 的完整安装路径下同样成立——`phpinfo.php` 返回 200 且输出
`PHP Version 8.3.33`，同目录下其它 `.php` 仍返回 404。

- **验证状态**：已实测（Debian 13）。

## FIX-SERVICE-003 卸载不停 systemd unit，重装后服务不会真正启动

**位置**：`include/main.sh` 的 `Remove_StartUp`。

**问题**：只装 init 脚本的组件（例如 OpenResty 只写 `/etc/init.d/nginx`，
不部署原生 unit），systemd 会用 sysv-generator 生成一个 unit，开机启动后
状态为 `active (exited)`。`lnmp stop` 与 init 脚本停服务时 systemd 并不知情，
该状态一直留着；`Remove_StartUp` 在这种情况下走的是 `update-rc.d` 分支，
从不调用 `systemctl stop`，卸载删掉文件也不会清除这个状态。
重装写入新 unit 并 `daemon-reload` 同样不重置已有的 active 状态，
随后的 `systemctl start` 认为服务已在运行、直接返回成功，服务实际从未启动。

Debian 13 实测复现：OpenResty 环境卸载后以 `WebSelect=1` 重装，安装脚本
输出"安装完成"，`systemctl is-active nginx` 为 `active`，
但 `pgrep -x nginx` 为 0、80 与 1008 端口都没有监听；
`systemctl show nginx -p ActiveEnterTimestamp` 指向的是开机那一刻（07:47），
而非本次安装时间。`lnmp status` 显示的也是这条陈旧记录，掩盖了未启动的事实。

**修改**：`Remove_StartUp` 在 disable 之前先按 systemd 停一次，且不再以
`Use_Systemd_Unit`（只认本包部署的 unit 文件）为前提——只要 systemd 在运行
就执行 `systemctl stop` 与 `systemctl reset-failed`，让 sysv-generator 生成的
unit 状态也回到 inactive。

**验证方式与结果**（Debian 13）：

1. 定向测试：在故障状态（unit `active`、nginx 进程数 0、
   `ActiveEnterTimestamp` 为开机时刻）下调用修改后的 `Remove_StartUp nginx`，
   之后 `systemctl is-active nginx` 变为 `inactive`（返回码 3）。
2. 状态清除后按安装流程的 `StartUp` + `StartOrStop start` 启动，
   nginx 真正拉起：9 个进程，80 与 127.0.0.1:1008 均在监听。
3. 完整回归：`./uninstall.sh lnmp` 后以
   `DBSelect=5 WebSelect=1 Enable_Nginx_Lua=n` 完整重装，安装结束时
   nginx / php-fpm / mariadb 三个 unit 的 `ActiveEnterTimestamp` 全部指向
   本次安装时间（08:38:21 / 08:38:24 / 08:38:24），不再是开机时刻；
   nginx 进程真实存在，80、127.0.0.1:1008、127.0.0.1:3306 均在监听，
   default 站点返回 200。
4. 幂等：`/etc/lnmp` 已在上一次卸载中处理掉，本次卸载时目录不存在，
   `Remove_Lnmp_Conf_Dir` 直接返回且无输出。

**调用点影响**：`Remove_StartUp` 的全部调用点（`uninstall.sh` 三份卸载路径、
多版本 PHP 清理、`include/redis.sh`、`include/memcached.sh`、`pureftpd.sh`、
`include/upgrade_mysql2mariadb.sh`）都是卸载或迁移场景，服务本就应当停止，
新增的 stop 不改变预期行为。

- **验证状态**：已实测（Debian 13，定向测试 + 卸载到重装完整回归）。

## AUDIT-BACKUP-003 age 加密备份到恢复全流程

**位置**：`tools/lnmp-backup.sh` 的 `Encrypt_File`、`Decrypt_File`。

**验证环境**：Debian 13，age 1.2.1，MariaDB 11.8.8。
`Enable_Encrypt=1`、`Encrypt_Tool="age"`，recipient 与 identity 由
`age-keygen` 现场生成。

**验证方式与结果**：

1. 备份：`lnmp backup run` 退出码 0，产物为 `db-<库>.sql.gz.enc` 与
   `www-<域名>.tar.gz.enc`，`file` 识别为
   `age encrypted file, X25519 recipient`；明文 `.gz` 已删除，
   `gzip -t` 无法识别密文。
2. 校验清单：`SHA256SUMS` 记录的是 `.enc` 文件。
3. `lnmp backup test`：SHA256 校验通过，解密后试恢复通过（1 张表），退出码 0。
4. `lnmp backup restore db <库>`：先删掉一行并改坏另一行，恢复后两行
   内容与原始数据一致，退出码 0。
5. 错误 identity：换成另一把 age 私钥，`age: error: no identity matched any
   of the recipients`，脚本输出"解密失败。"，退出码 1。
6. identity 文件不存在：输出"找不到解密私钥：<路径>"，退出码 1。
7. 无临时明文残留。

- **验证状态**：已实测（Debian 13）。

## AUDIT-BACKUP-004 GPG 加密备份到恢复全流程

**位置**：`tools/lnmp-backup.sh` 的 `Encrypt_File`、`Decrypt_File`。

**验证环境**：Debian 13，GnuPG，`Encrypt_Tool="gpg"`，
收件人为现场生成的 cv25519 密钥（`--quick-generate-key`，空口令）。

**验证方式与结果**：

1. 备份：退出码 0，产物为 `.enc`；`gpg --list-packets` 确认为
   `encrypted with cv25519 key`，对应生成的收件人。
2. `lnmp backup test`：SHA256 校验通过，解密后试恢复通过（1 张表），退出码 0。
3. `lnmp backup restore db <库>`：`TRUNCATE` 清空表后恢复，两行数据完整还原。
4. 缺失私钥：删除 secret key 后 `test` 报
   `gpg: decryption failed: No secret key`，脚本输出"解密失败。"，退出码 1。
5. 错误收件人：`Encrypt_Recipient` 设为不存在的地址，备份失败、
   批次标记为不完整，退出码 1。

- **验证状态**：已实测（Debian 13）。

## FIX-BK-012 加密失败时未加密的明文留在备份目录

**位置**：`tools/lnmp-backup.sh` 的 `Encrypt_File`。

**问题**：`Encrypt_File` 失败时只删除输出的 `.enc`，输入的明文 `.gz` 原样留在
批次目录里。调用方 `Run_Db` / `Run_Web` 收到非零返回后只把批次标记为不完整，
并按"存在失败项就跳过清理"的策略保留整个目录，于是在使用者明确
`Enable_Encrypt=1` 的前提下，未加密的数据库转储与网站打包一直躺在磁盘上。
`Encrypt_Recipient` 为空、找不到 age/gpg 命令、`Encrypt_Tool` 取值非法这三条
提前返回的路径同样如此。

Debian 13 实测复现：`Encrypt_Recipient` 置空或填无效 age recipient 后执行
`lnmp backup run db`，退出码为 1，但 `/home/backup/db/<批次>/db-<库>.sql.gz`
仍在。

**修改**：`Encrypt_File` 的每一条失败路径都连同输入的明文一起删除。
批次本来就要重做，保留一份未加密的转储没有价值，只有风险。

**验证方式与结果**（Debian 13）：

1. 无效 recipient：退出码 1，批次目录下无 `.gz` 与 `.part`；
   空批次目录也被 `FIX-BK-011` 的清理一并删除。
2. `Encrypt_Recipient` 为空：退出码 1，同样无明文残留。
3. GPG 分支的错误收件人：退出码 1，无明文残留。
4. 成功路径不受影响：恢复正确 recipient 后备份退出码 0，
   产物为 `.enc` 与 `SHA256SUMS`。

- **验证状态**：已实测（Debian 13，age 与 gpg 两个分支）。

## FIX-BK-013 SFTP 上传后大小核对永远判定"远端缺少文件"

**位置**：`tools/lnmp-backup.sh` 的 `Upload_Batch_Sftp`。

**问题**：上传完成后用 `ls -l <staging>` 的输出逐个核对远端文件大小，
匹配条件写的是 `$NF == <basename>`。但 sftp 的 `ls -l` 最后一列打印的是
传给 `ls` 的路径拼上文件名，例如
`backup/.incoming/20260815-084453-db/SHA256SUMS`，不是裸文件名，
比对必然不成立。结果是：文件其实已经传上去了，却被判成"远端缺少文件"，
批次卡在 `.incoming` 下不改名，`lnmp backup run` 返回 1。
异地备份因此从未真正提交过。

Debian 13 实测复现（受限 `internal-sftp` 账号，chroot + `ForceCommand`）：
远端 `.incoming/<批次>-db/` 下两个文件都在，日志却是
`远端缺少文件：db-sftptest.sql.gz` 与 `远端缺少文件：SHA256SUMS`，
随后 `远端核对未通过，保留 .incoming 供排查，不改名。`

**修改**：核对时取 `$NF` 的 basename 再比对。

**验证方式与结果**（Debian 13，受限 internal-sftp 账号）：

1. 正常上传：退出码 0，日志 `远端已提交：db/<批次>` 与
   `远端已提交：www/<批次>`；远端 `backup/db/<批次>/` 与
   `backup/www/<批次>/` 下文件齐全，`.incoming` 已清空。
2. 远端空间不足（备份目录挂 64K tmpfs）：`put` 失败，sftp 退出码 1，
   走"上传失败"分支并原文打印远端错误，保留 `.incoming` 不改名，退出码 1。
3. 目录改名失败：预置同名远端批次目录并在其中放一个子目录，
   `-rm` 通配删不掉目录、`-rmdir` 失败、`rename` 失败，
   脚本报"远端改名失败"，保留 `.incoming`，不破坏已有目录，退出码 1。
4. 覆盖同名批次（可清理）：远端同名批次里的旧文件被清掉后 `rename` 成功，
   退出码 0。

- **验证状态**：已实测（Debian 13）。

## FIX-BK-014 远端批次列表混入 sftp 回显，且目录不存在被当成错误

**位置**：`tools/lnmp-backup.sh` 的 `List_Remote_Batches`、`Cmd_List`。

**问题**：三处。

1. sftp 的 `sftp> ...` 命令回显走 stdout，与 `ls -1` 的结果混在一起。
   后续 `sed 's#.*/##'` 会把 `sftp> ls -1 backup/db` 截成 `db`、
   把 `sftp> bye` 原样留下，两者都被当成批次名打印出来。
2. 远端还没有 `db` 或 `www` 目录时（只上传过另一类，或该类批次已被保留
   策略清空），OpenSSH 报 `Can't ls: "<路径>" not found` 并返回非零，
   `Cmd_List` 把它当成失败，打印"无法列出远端 <类型> 批次。"并 `return 1`。
3. `Enable_Remote_Backup=1` 但远端配置不全时，
   `if ... && Check_Remote_Conf` 让整个远端分支被跳过，
   `Cmd_List` 仍返回 0——远端根本没查成，定时任务却看不出来。

**修改**：stderr 单独收下用于判别错误类型，输出侧过滤掉 `^sftp>` 行；
错误信息匹配 `Can't ls:.*not found` 时按"0 个批次"返回 0；
`Check_Remote_Conf` 改为独立判断并 `return 1`。

**验证方式与结果**（Debian 13）：

1. 两类批次都存在：远端列表只打印批次名，无 `db` / `sftp> bye` 之类的
   杂项，退出码 0。
2. 远端删掉 `db` 目录：远端 db 一节为空，不再报错，退出码 0，
   www 一节正常打印。
3. 远端配置有误（`Remote_SSH_Key` 指向不存在的文件）：打印
   `缺少 SSH 私钥：<路径>`，退出码 1。
4. `Enable_Remote_Backup=0`：只打印本地批次，退出码 0，行为不变。

- **验证状态**：已实测（Debian 13）。

## AUDIT-BACKUP-002 真实 SFTP 批次上传与目录改名

**位置**：`tools/lnmp-backup.sh` 的 `Upload_Batch_Sftp`。

**验证环境**：Debian 13，受限 `internal-sftp` 账号——`useradd -M -s
/usr/sbin/nologin`，sshd 侧 `Match User` 段设 `ChrootDirectory` 与
`ForceCommand internal-sftp`，密钥登录，`Remote_Known_Hosts` 由
`ssh-keyscan` 预置、`StrictHostKeyChecking=yes`。

**验证结论**：`.incoming` 暂存上传、逐文件大小核对、整目录 `rename` 提交
这一套流程在受限账号下可用。四个场景（成功提交、上传失败、改名失败、
覆盖同名批次）的结果见 `FIX-BK-013` 条目——本次验证同时发现并修复了
大小核对的路径比对缺陷，修复前该流程从未成功提交过。

- **验证状态**：已实测（Debian 13）。

## AUDIT-BACKUP-005 SFTP 远端只能做大小核对

**位置**：`tools/lnmp-backup.sh` 的 `Upload_Batch`。

**限制说明**：受限的 `internal-sftp` 账号不能在远端执行命令，上传后只能逐个
比对文件大小，可以发现截断和缺失，发现不了内容被改写。内容级校验只能靠
随批次一起上传的 `SHA256SUMS`，而核对这份清单需要在备份服务器侧另行安排。

**实证**（Debian 13）：把远端已提交批次里的 `www-*.tar.gz` 用等长随机数据
整体改写（字节数保持 500370 不变），备份流程没有任何异常——大小核对只在
上传当时进行，已提交批次不会被回头复查；在远端目录直接执行
`sha256sum -c SHA256SUMS` 则报 `FAILED`，说明清单本身可以发现内容改写，
缺的是执行它的通道。

**可选方案**（均涉及备份服务器侧配置，不属于本包能单独完成的部分）：
在备份服务器上放一个定期核对 `SHA256SUMS` 的任务，或改用允许受限命令
执行的通道。

- **验证状态**：已实测（Debian 13，限制描述与实际行为一致）。

## FIX-BK-015 FTP 远端大小核对永远取不到 Content-Length

**位置**：`tools/lnmp-backup.sh` 的 `Ftp_Remote_Size`。

**问题**：读远端文件大小时给 curl 加了 `output = "/dev/null"`。FTP 下的
`--head` 只发 SIZE/MDTM，不取文件体，它拼出来的
`Last-Modified` / `Content-Length` / `Accept-ranges` 几行本身就走 stdout，
`-o` 会把这几行一起丢掉。结果 `Ftp_Remote_Size` 永远返回空，
`Upload_Batch_Ftp` 判定"远端缺少文件或取不到大小"，批次卡在 `.incoming`
不改名，FTP/FTPS 异地备份从未成功提交过（与 `FIX-BK-013` 的 SFTP 侧同类）。

Debian 13 实测复现：文件已在远端 `.incoming/<批次>-db/` 下，日志却是
`远端缺少文件或取不到大小：db-ftptest.sql.gz`；手工执行
`curl --head` 去掉 `-o /dev/null` 后可读到 `Content-Length: 84`。

**修改**：去掉 `output = "/dev/null"`。

**验证方式与结果**（Debian 13，pyftpdlib 2.0.1 作服务端，被动端口
30000-30010）：

1. 明文 FTP：上传、SIZE 核对、`RNFR`/`RNTO` 目录改名全部成功，
   退出码 0，远端 `backup/db/<批次>/` 与 `backup/www/<批次>/` 文件齐全，
   `.incoming` 已清空；日志按预期打印明文 FTP 的两条告警。
2. FTPS（`ssl-reqd` + 自签 CA，`Remote_Ftp_Verify=1`）：同样全部成功，
   退出码 0。

- **验证状态**：已实测（Debian 13，FTP 与 FTPS 两种协议）。

## AUDIT-BACKUP-FTP-001 FTP/FTPS 目录改名

**位置**：`tools/lnmp-backup.sh` 的 `Upload_Batch_Ftp`。

**验证环境**：Debian 13，pyftpdlib 2.0.1（`perm="elradfmwMT"`），
明文 FTP 与显式 FTPS（`AUTH TLS`，自签证书）各跑一轮。

**验证方式与结果**：

1. 目录改名可用：`RNFR <staging>` / `RNTO <正式目录>` 对目录生效，
   `.incoming/<批次>-<类型>` 整体切换为 `backup/<类型>/<批次>`，
   两种协议都成功，`.incoming` 随之清空。
2. 改名失败路径：预置同名远端批次目录并在其中放一个子目录，
   `*RMD` 删不掉非空目录，`RNTO` 随之失败，curl 退出码 21，
   脚本打印"远端改名失败（curl 退出码 21）"，保留 `.incoming` 不动
   已有目录，`lnmp backup run` 退出码 1。

**服务端差异说明**：本轮服务端支持目录改名。若目标服务器只允许文件改名，
表现即为上述第 2 条的失败路径——退出非零、`.incoming` 保留，
不会出现半提交状态。

- **验证状态**：已实测（Debian 13，FTP 与 FTPS）。

## AUDIT-BACKUP-FTP-002 FTP/FTPS SIZE 与 Content-Length 核对

**位置**：`tools/lnmp-backup.sh` 的 `Upload_Batch_Ftp`、`Ftp_Remote_Size`。

**验证方式与结果**（Debian 13）：

1. 正常返回：服务端支持 SIZE，`curl --head` 返回 `Content-Length`，
   逐文件大小核对通过后才改名。修复前该路径完全不通，见 `FIX-BK-015`。
2. 取不到大小：`Ftp_Remote_Size` 返回空时报
   "远端缺少文件或取不到大小：<文件名>"，批次标记不完整、
   保留 `.incoming` 不改名，退出码 1——不会误报上传成功。
3. 上传阶段异常（TLS 证书校验失败）：`curl: (60) SSL certificate problem:
   self-signed certificate`，脚本报"上传失败：<文件名>"，退出码 1，
   远端无残留。`Remote_Ftp_Verify=0` 后同一配置上传成功，退出码 0。

- **验证状态**：已实测（Debian 13，FTP 与 FTPS）。

## AUDIT-BACKUP-FTP-003 FTP/FTPS 被动模式与防火墙

**位置**：`tools/lnmp-backup.sh` 的 FTP/FTPS curl 调用。

**验证方式与结果**（Debian 13，服务端被动端口 30000-30010）：

1. 被动端口通畅：控制连接与数据连接均正常，上传成功，退出码 0。
2. 被动端口被拦（nftables 对 30000-30010 加 drop 规则）：
   控制连接建立成功（登录、`MKD` 都走控制连接），数据连接卡住，
   在 `connect-timeout = 30` 后失败，curl 报 `(28) Connection time-out`，
   脚本报"上传失败：<文件名>"，退出码 1，远端无残留文件。
3. 移除拦截规则后同一配置立即恢复成功，退出码 0。

**结论**：控制连接成功而数据传输失败这一场景由 `connect-timeout` 兜住，
不会无限期挂起，也不会把失败当成成功。

- **验证状态**：已实测（Debian 13）。

## FIX-BK-016 FTP 远端类型目录不存在时 list 整体失败

**位置**：`tools/lnmp-backup.sh` 的 `List_Remote_Batches` 的 ftp/ftps 分支。

**问题**：与 `FIX-BK-014` 的 sftp 侧同类。远端还没有 `db` 或 `www` 目录时，
curl 报 `(9) Server denied you to change to the given directory` 并返回 9，
`Cmd_List` 把它当成失败，打印"无法列出远端 <类型> 批次。"并返回 1。

**修改**：curl 退出码 9 按"0 个批次"处理并返回 0。FTP 协议下区分不了
"目录不存在"与"没有权限"，后者会在上传阶段明确报错，不依赖 list 发现。

**验证方式与结果**（Debian 13）：

1. 远端删掉 `www` 目录：www 一节为空、不报错，db 一节正常，退出码 0。
2. 重新上传 www 后列表恢复，退出码 0。
3. 真实错误（口令改错）：仍打印"无法列出远端 db 批次。"，退出码 1。

- **验证状态**：已实测（Debian 13）。

## FIX-TEST-003 t/test_bumpversion.sh 的沙箱构造在任何环境下都跑不通

**位置**：`t/test_bumpversion.sh`。

**问题**：该测试用 `unshare --mount --map-root-user` + overlayfs 隔离
`/bin` 与 `/etc` 做功能测试，但 `--map-root-user` 建出来的 user namespace
只映射当前一个 uid，namespace 内的 root 对其它属主的文件没有权限。
由此在两种环境下各卡在不同位置，都无法通过：

- 以普通用户运行：`Install_Tgnotice_Profile` 写
  `/etc/profile.d/lnmp-tgnotice.sh` 报 `Permission denied`。
  `/etc` 本身是挂载点可以直接写，但往它的子目录里新建文件要先把该子目录
  copy-up 到 upperdir，copy-up 保留原属主，在 user namespace 里设不了 root 属主。
- 以 root 运行：源码目录属主往往不是 root（解包保留原属主），
  `Install_LNMP_Command` 末尾的 `chmod 755 tools/*.sh` 报 EPERM。
  同时"未加 root 权限执行应失败"这组用例因为本来就是 root 而必然失败。

两种情况都表现为产品代码被判成同步失败（`默认（无参数）同步成功` 等 4 项
FAIL），而实际手工执行 `bumpversion.sh` 是成功的——故障在测试脚本，
报错却指向被测代码。

另有两处次要问题：静态检查断言 `[ -x bumpversion.sh ]` 与仓库现状冲突
（仓库里的 `.sh` 一律 644，`install.sh` 等入口脚本也一样，
`HowtoGuides.md` 让使用者自行 `chmod +x`）；宿主机装过 LNMP 时
lowerdir 会把真实的 `/bin/lnmp` 带进沙箱，"尚未安装"的场景构造不出来。

**修改**：

- `--map-root-user` 改为只在非 root 时加，root 下直接用真实权限挂 overlay。
- 挂完 `/etc` 的 overlay 后给 `/etc/profile.d` 单独盖一层 tmpfs，绕开 copy-up；
  测试只关心能否写入，不需要原有内容。
- "未加 root 权限执行应失败"这组按实际身份分支：以 root 运行时明确跳过
  并说明原因，不制造假的通过（没有可用的降权目标——源码目录常在 `/root` 下，
  换成 nobody 连读都读不到，构造出的失败原因就不是"非 root"了）。
- 沙箱内先 `rm -f /bin/lnmp /usr/bin/lnmp`，只产生 whiteout，宿主机不受影响。
- 静态断言从"可执行"改为"有 bash shebang"。

**验证方式与结果**：

1. 本机（WSL Ubuntu 24.04，普通用户）：全部通过。
2. Debian 13 测试机（真 root，且宿主机已装 LNMP）：全部通过，
   "未加 root 权限执行"这组按预期打印跳过说明。
3. 沙箱隔离有效：测试跑完后宿主机 `/bin/lnmp` 仍在、`lnmp status` 正常。
4. 真机复核 `bumpversion.sh` 本身：在 Debian 13 上执行后退出码 0，
   `/bin/lnmp` 与 `conf/lnmp`、`/bin/lnmp-backup` 与 `tools/lnmp-backup.sh`
   逐字节一致，`/usr/bin/lnmp` 别名同步到位，`lnmp backup list` 可正常执行。
5. `t/test_bump.sh`（自动升版的跨文件同步回归，与本条无关的另一套）
   同样全部通过，13 项。

- **验证状态**：已实测（WSL 普通用户 + Debian 13 真 root）。

## FIX-UI-001 vhost/ssl 交互输出的三处文案问题

**位置**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp`；`HowtoGuides.md` 4.1、4.2。

**问题与修改**：

1. **整行提示缺换行**。`Echo_Yellow` 用 `echo -n`，是交互提示专用（让输入紧跟
   提示），但被用于不接受输入的整行提示，输出会和下一条粘在一行。典型现象：
   `lnmp ssl add` 输入不存在的域名后，`请先执行 lnmp vhost add 创建网站，
   再执行 lnmp ssl add 添加证书。` 后面直接跟 shell 提示符。
   在这些整行提示后各补一行 `echo`：ssl add 的站点缺失与重复 SSL 提示、
   default 证书说明、数据库导入覆盖警告、LNMPA/LAMP 的 IP 证书说明等。
   原本后面已跟 `echo` 的调用点不动。
2. **`lnmp vhost add` 输入 `default` 无输出**。LNMP 侧走 `Add_VHost_Default`，
   配置已存在时静默返回；LNMPA/LAMP 侧 `default` 通不过域名格式校验，循环重问。
   三处统一为：不重复建站，打印
   `default 站已安装，是默认兜底站，如需为其配置 SSL 证书，请执行 lnmp ssl add`
   并返回 0。LNMP 保留缺失时的补建，补建失败返回 1。
3. **站点信息里的 `伪静态规则：none`**。`none` 是内部值（配置生成按它判断），
   面向用户的三处输出改为显示"无"，变量取值与配置生成不变。

**文档**：`HowtoGuides.md` 4.1 的 15 步交互表换成程序实际输出的中文提示，
建库成功提示更正为 `数据库创建成功。`；4.2 补明只有域名、数据库 root 密码、
数据库名、库用户密码四项走 `Read_Input`/`Read_Secret`，少喂会 EOF 快速失败，
其余选项少喂按默认值处理。

**验证**：`bash tests/test_vhost_prompt_output.sh`（15 项，覆盖三个文件的
换行行为、ssl add 缺失站点的两行提示与返回码、`vhost add` 输入 default 的
提示与返回码、`none` 的显示）；`t/lint.sh` 18 项、`t/consistency.sh` 14 项通过。

- **验证状态**：已验证（静态与定向测试），交互输出待真机复核。

## FIX-TEST-004 开发期定向测试从 t/ 分出到 tests/，不入库不进发布包

**位置**：`t/` → `tests/`，`.gitignore`，`.github/workflows/release.yml`。

**问题**：`t/` 按项目约定放的是"本项目必须用的检查脚本"，实际混进了只在本地
跑的开发期定向测试。18 个文件里有 5 个既不被任何 GitHub Actions 工作流调用，
也不被产品代码调用，只在 `t/` 内部互相引用；而 `t/` 会随发布包分发给最终用户。

产品代码对 `t/` 无任何运行时依赖：`install.sh`、`include/*.sh`、
`conf/lnmp(a)/lamp`、`tools/*.sh`、`uninstall.sh`、`upgrade.sh`、`addons.sh`
中没有一处调用，只有 `include/version.sh` 与 `include/profile.sh` 的注释
提到它们作为维护提示。

**修改**：

- 新建 `tests/`，迁入 5 个文件：`test_bumpversion.sh`、
  `test_install_confirm.sh`、`test_install_phpmyadmin.sh`、`test_db_port.sh`、
  `pty_run.py`。后两个分别只被前两个调用，属同一依赖闭包。
- 修正迁移后的内部路径：`test_install_confirm.sh` 对 `pty_run.py` 的 4 处调用、
  `test_install_phpmyadmin.sh` 对 `test_db_port.sh` 的 1 处调用，以及文件头
  注释里的自身路径。三个脚本的 `cd "$(dirname "$0")/.."` 仍指向仓库根，无需改动。
- `.gitignore` 增加 `tests/`，并注明它与 `t/` 的分工——`t/` 是 Actions 必须
  调用的检查脚本，不能忽略。
- `release.yml` 打包增加 `--exclude='./tests'`。该目录已被 gitignore、
  CI 检出时本就不存在，这条是防御性的。

**保留在 t/ 的 13 个**（GitHub Actions 直接调用，删除会导致 CI / 发布 /
上游检查失败）：`lint.sh`、`consistency.sh`、`test_profile.sh`、
`test_dispatch.sh`、`test_audit_fixes.sh`、`test_upstream.sh`、`test_bump.sh`
（`ci.yml` / `release.yml`）；`check_upstream.sh`、`bump_version.sh`、
`gen_checksums.sh`、`refresh_checksums.sh`（`upstream-check.yml`）；
`probe_urls.sh`（`url-health.yml`、`upstream-check.yml`）；
`build_test.sh`（`build-test.yml`）。

**验证方式与结果**：

1. 名单双向复核：13 个逐个确认在工作流中被点名调用；5 个逐个确认不出现在
   任何工作流里。`ci.yml` 的 shellcheck 用 `t/*.sh` 通配，迁移后自动适应。
2. 迁移后 5 个脚本全部实跑通过，退出码均为 0，含跨脚本调用
   （`test_install_phpmyadmin.sh` → `tests/test_db_port.sh`）与
   pty 交互分支（`test_install_confirm.sh` → `tests/pty_run.py`）。
3. 模拟发布打包：包内无 `tests/`，`t/` 保留 13 个，`install.sh` 等入口齐全。

**附带修正一处过时断言**：`tests/test_install_phpmyadmin.sh` 的
"默认站点模板/生成逻辑都带 phpMyAdmin 入口钩子"检查的是
`Install_Nginx()` 函数体与 `conf/nginx_a.conf`、`conf/openresty.conf`，
三处均已不成立——公网 default 站点早已改为由
`Write_Nginx_Default_VHost()` 现场生成到 `vhost/default.conf`，
那两个主配置里 `server_name _` 的块是仅本机可访问的管理端口
（`127.0.0.1:1008`），本就不该带 phpMyAdmin 钩子。断言当时只改了注释、
没改代码，而该脚本不在 CI 里，一直没被发现。现改为检查
`Write_Nginx_Default_VHost()` 与 `conf/lnmp` 的 `Add_VHost_Default`
两处生成逻辑，加上两个 Apache 配置的 `IncludeOptional`。

**连带修复 t/consistency.sh 的 V7**：该检查在 git 环境用 `git ls-files` 枚举
文件，非 git 环境退回 `find`。`tests/pty_run.py` 跑过一次 `py_compile` 后，
`tests/__pycache__/*.pyc` 会被 find 分支扫到，二进制字节序列里的 `\r`
被判成 CRLF，V7 失败。git 环境不会遇到（未跟踪），但本地开发会。
现在排除 `*.pyc` 与 `*/__pycache__/*`，`.gitignore` 也补上这两条。
构造场景复验：故意生成 pyc 后 V7 仍通过，14 项全过。

- **验证状态**：已实测（本机 WSL Ubuntu 24.04）。

## FEAT-VHOST-001 站点级"是否开启 PHP"选项

**位置**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp` 的 `Add_VHost`、`Add_VHost_Config`、
`Add_SSL_Info_Menu`、`Add_SSL_Only_Info_Menu`、`Create_SSL_Config`；
`README.md`、`HowtoGuides.md`。

**行为变化**：`lnmp vhost add` 在伪静态之后、Pathinfo 与 PHP 版本选择之前新增
`是否开启 PHP? (Y/n，默认 y)`。默认 `y`，原有建站流程不变。

选 `n` 时：不再询问 Pathinfo，不再选择 PHP 版本；站点配置不写任何 PHP 执行入口，
首页候选去掉 `index.php`、`default.php`，站点目录不写 `.user.ini`、不 reload php-fpm。
各栈的具体形态：

| 栈 | PHP=n 时的站点配置 |
|---|---|
| LNMP | 不写 `include enable-php*.conf;`，改写一段 `location ~ [^/]\.php(/\|$) { return 404; }` |
| LNMPA | Nginx 不写 `include proxy-pass-php.conf;`，同样写入上述 404 段；Apache 侧 `php_admin_flag engine off` + `RedirectMatch 404 "\.php(/\|$)"`，`DirectoryIndex` 去掉 `index.php` |
| LAMP | Apache 侧同上，并把 `php_admin_value open_basedir` 注释掉 |

Nginx 侧的 404 段不能省：站点目录里存在 `.php` 文件时，没有该段会按
`default_type application/octet-stream` 把源码整份返回（nginx 自带 `mime.types`
没有 `.php`）。Apache 侧同样不能省：`.php` 的处理器挂在 `httpd.conf` 全局，
站点配置不写就等于照常执行。`php_admin_flag` 不能被 `.htaccess` 覆盖，
因此 `AllowOverride All` 保持不变。

**HTTPS 继承**：`lnmp ssl add` 从现有站点配置读回状态——LNMP/LNMPA 判断有没有
`enable-php*.conf` / `proxy-pass-php.conf`，LAMP 判断有没有 `php_admin_flag engine off`。
判定为未开启时打印 `网站 <域名> 未开启 PHP，HTTPS 配置沿用同一状态。`，
443 与 80 写同一形态。default 站点仍按内置形态生成，不参与该判定。

**非交互接口**：新增提示在标准输入不是终端时**不读取输入行**，只看环境变量
`VHOST_PHP`：未设置按 `y` 处理，`VHOST_PHP=n` 关闭。既让自动化能显式关闭 PHP，
也保证原有的管道喂入序列不因新增这一问而整体错位。

**连带调整**：`conf/lnmp` 中 7 处 y/n 提示的默认项统一改为大写标记
（`(y/N，默认 n)`；`conf/lnmpa`、`conf/lamp` 原本即为 `[y/N]` 形式）。

**验证**：

- `tests/test_vhost_php_switch.sh`（60 项）：三栈的非交互分支不消耗输入行、
  `VHOST_PHP` 取值、真实 pty 下的默认值/`n`/非法输入重问/EOF 兜底，
  `Add_VHost_Config` 与 `Create_SSL_Config` 在 PHP=y/n 下生成的 Nginx 与 Apache
  配置，`Add_SSL_Only_Info_Menu` 读回状态。函数从源码按名提取，路径改写到沙箱，
  不触碰真实安装目录。
- `tests/verify_vhost_php_remote.sh`（43 项，Debian 13 实跑）：建三个站点
  （PHP=y+Pathinfo=n、PHP=y+Pathinfo=y、PHP=n），覆盖 HTTP 与 HTTPS 下真实存在
  与不存在的 `.php`、`.php/xxx`（均 404 且不含源码）、静态文件、首页、
  反代到 `127.0.0.1:3000` 的后端、重复建站的非零返回、`ssl add` 状态继承、
  phpMyAdmin 入口不受影响。
- `t/lint.sh` 18 项、`t/consistency.sh` 14 项、`tests/test_vhost_prompt_output.sh` 通过。

**Apache 补充实测**（2026-08-15）：LAMP 与 LNMPA 均使用本项目完整源码安装
Apache 2.4.68 + PHP 8.3.33 ZTS，并运行
`tests/verify_project_apache_stack.sh`。两栈的站点 PHP 开关、PATH_INFO、源码保护、
静态文件和 `.htaccess` 边界均通过；LNMPA 批次共 18 项通过。

- **验证状态**：已实测（LNMP、LAMP、LNMPA，Debian 13）。

## RUN-036 Debian 13 真机验证批次（第三轮）

**环境**：Debian 13 (trixie)、NAT 网络。沿用第二轮留下的环境：
nginx 1.30.4（编译版，`Enable_Nginx_Lua=n`）、PHP 8.3.33、MariaDB 11.8.8，
本轮另行安装 phpMyAdmin 5.2.3 以覆盖入口不受影响的检查。

**本轮实测通过并归档**：FEAT-VHOST-001（43 项，见该条目的验证段）。

**未覆盖**：LNMPA 与 LAMP 的 Apache 侧行为，需要各完整安装一次（源码编译 Apache）。

- **验证状态**：已实测（Debian 13）。

## RUN-035 Debian 13 真机验证批次（第二轮）

**环境**：Debian 13 (trixie)、NAT 网络。本轮先后经过三套环境：
OpenResty 1.31.1.1（源码编译）→ 卸载 → nginx 1.30.4（编译版，
`Enable_Nginx_Lua=n`）→ 卸载 → 同一配置重装做回归。
组件：PHP 8.3.33、MariaDB 11.8.8、phpMyAdmin 5.2.3。
外部服务用本机搭建：受限 `internal-sftp` 账号（chroot + `ForceCommand`）、
pyftpdlib 2.0.1（FTP 与显式 FTPS）、age 1.2.1、GnuPG。

**静态检查**：每次代码改动后 `bash -n` + `t/lint.sh` 18 项 + `t/consistency.sh`
14 项，全部通过。

**本轮实测通过并归档的审计项**：AUDIT-VHOST-011、AUDIT-VHOST-012（LNMP 栈）、
AUDIT-VHOST-002、AUDIT-BACKUP-003（age）、AUDIT-BACKUP-004（GPG）、
AUDIT-BACKUP-002（SFTP）、AUDIT-BACKUP-005、AUDIT-BACKUP-FTP-001、
AUDIT-BACKUP-FTP-002、AUDIT-BACKUP-FTP-003。

**本轮新发现并修复**：FIX-VHOST-013、FIX-UNINSTALL-003、FIX-SERVICE-003、
FIX-BK-011、FIX-BK-012、FIX-BK-013、FIX-BK-014、FIX-BK-015、FIX-BK-016、
FIX-TEST-003。
其中三项属于"功能从未成功过"：`FIX-BK-013`（SFTP 上传的大小核对拿 basename
比对完整路径）、`FIX-BK-015`（FTP 的 `--head` 输出被 `-o /dev/null` 丢掉）、
`FIX-SERVICE-003`（卸载不 stop unit，重装后服务实际未启动而 status 显示正常）。

**本轮新登记待处理**：AUDIT-VHOST-013-APACHE（演示页放行规则的 Apache 侧）。

**未覆盖**：Telegram 三项（需真实 bot token 与 chat id）、
Apache 五项（AUDIT-INITD-003、AUDIT-SERVICE-002、AUDIT-PMA-001、
AUDIT-VHOST-013-APACHE、AUDIT-VHOST-012 的 LNMPA 反代部分，
需要 LAMP 与 LNMPA 各完整安装一次）、AUDIT-VHOST-010（需公网入站）。

- **验证状态**：已实测（Debian 13）。

## RUN-034 Debian 13 真机验证批次（第一轮）

**环境**：Debian 13 (trixie)、8 核 / 5.8G 内存、NAT 网络。
组件：nginx-1.30.4、php-8.3.33、MariaDB 11.8.8、MySQL 8.4.7、phpMyAdmin 5.2.3。

**静态检查**：全部脚本 `bash -n` 通过；`t/lint.sh` 18 项通过；
`t/consistency.sh` 14 项通过（每次代码改动后重跑）。

**本轮实测通过并归档的审计项**：AUDIT-I18N-001、AUDIT-INSTALL-001、
AUDIT-SYSTEMD-001、AUDIT-COMMAND-001、AUDIT-SERVICE-001、AUDIT-STACK-001、
AUDIT-DB-004、AUDIT-VHOST-001、AUDIT-VHOST-003、AUDIT-VHOST-004（Nginx 侧）、
AUDIT-VHOST-005、AUDIT-VHOST-006、AUDIT-VHOST-007、AUDIT-VHOST-008、
AUDIT-VHOST-009、AUDIT-VHOST-010（菜单与前置检查）、AUDIT-BACKUP-001、
AUDIT-BACKUP-INIT-001/002/003。

**本轮新发现并修复**：FIX-INSTALL-001、AUDIT-DB-005、AUDIT-DB-006、
AUDIT-DB-007、FIX-UNINSTALL-001、FIX-UNINSTALL-002、FIX-VHOST-001、
FIX-PMA-009、FIX-PMA-010、FIX-BK-010、FIX-TOOLS-002，以及 AUDIT-DB-004 中
init 脚本仍用旧程序名的补充修复。

**本轮新登记待处理**：AUDIT-VHOST-013（根目录 PHP 演示页与 default 静态边界
冲突）、AUDIT-UNINSTALL-003（卸载不清理 `/etc/lnmp` 的凭据文件）、
AUDIT-BACKUP-006（备份目标磁盘不足时的退出码与残留清理）。

**未覆盖**：OpenResty 相关（`AUDIT-VHOST-011/012`，官方仓库无 Debian 13 包，
需源码编译）、`AUDIT-VHOST-002`（`Enable_Nginx_Lua=n` 需另装一次）、
以及 todo 中标记为待人工真机验证的外部服务与 Apache 相关项。

- **验证状态**：已实测（Debian 13）。

## AUDIT-SECURITY-20260816 工具自身、下载上传与运行时后门专项审计

**范围**：以干净的 Debian 13 服务器为前提，复查 LNMP 2.3 自身源码、生成物、
安装后的 Nginx/PHP/MariaDB/Redis 运行文件，以及可能改变 HTTP 响应或向外传输数据的
路径。不假设操作系统、上游官方仓库、GitHub Actions 仓库、维护者账号或 TLS 已失陷。

**静态审阅**：逐个、逐行阅读当前 87 个 `.sh`，并对照 `init.d/*`、三份管理脚本、
Nginx/FastCGI/PHP/phpMyAdmin 配置、补丁和工作流。未发现隐藏下载执行、隐藏上传、
反向 shell、webshell、特定 Header/URL/User-Agent 后门分支或运行时静默拉取代码。
固定组件下载使用 HTTPS，并由 66 条固定 SHA-256、固定指纹 PGP 或对应上游校验值
fail-closed 验证。备份远传和 Telegram 均默认关闭，只有管理员显式配置后才对外发送。

**二进制与运行时实测**：`tests/audit_binary_runtime.sh` 和
`tests/audit_binary_deep.sh` 扫描 `/usr/local` 的 130 个 ELF：`strings -a -n 4`
共 4,925,201 行、符号表 738,247 行、`ldd`/`objdump -p`/动态段 19,480 行，
工具错误 0。未发现可由非特权用户写入的 ELF/共享库、异常可执行映射或已删除映射；
唯一 SUID/SGID 文件为 MariaDB 官方 PAM helper，PAM 插件未加载，且该文件和
`mariadbd` 均与已校验官方二进制归档内文件逐字节一致。数据库未做源码编译。

**独立重编**：`tests/audit_nginx_rebuild.sh` 与
`tests/audit_critical_rebuild.sh` 使用固定哈希源码、相同工具链和配置参数在隔离目录中
重编，不安装产物。Nginx、PHP-FPM、PHP CLI、Redis Server 的 `.text` 均逐字节一致，
`.data`、`.init_array` 也一致；`.rodata` 的少量差异全部定位为构建时间、编译参数文本、
链接字符串顺序或 Redis 构建 ID，没有额外机器代码或隐藏构造器。

**PHP SAPI 字符串专项**：使用 `strings -a -n 4` 分别提取 PHP CLI 与 PHP-FPM，
对比 CLI/FPM 标识、进程标题和配置路径。CLI 聚焦 44 行，FPM 聚焦 190 行，共有 35 行；
差集分别是正常的 CLI server/源码标识和 FPM/FastCGI、master、pool、配置解析标识。
运行时 SAPI、`php.ini`/conf.d 路径及 FPM master/worker 标题均与编译配置一致；独立重编
完整 strings diff 中这些标识、路径和名称没有变化。

**HTTP 特殊输入与压力**：`tests/audit_http_triggers.sh` 覆盖 30 组 URL、Header、
User-Agent、Cookie、Authorization、异常方法、路径编码和长 Header，并另测重复
Content-Length、CL/TE 冲突及本机 PHP-FPM 探针。异常内容命中 0；四组 PHP 触发输入
与基线响应逐字节同哈希；两个请求走私类输入均返回 400。200 请求、并发 20 全部返回
2xx，错误 0；测试前后四个关键二进制哈希与服务外连快照一致。

**质量门**：当前 87 个 `.sh` 的 `bash -n` 为 87/87 通过；`t/lint.sh` 全部通过；
`t/consistency.sh` 14/14 通过。完整结论、正常例外和现实边界见
`SecurityCheck.md`。

- **验证状态**：已实测（Debian 13，2026-08-16）。

## AUDIT-NOTIFY-REAL-20260816 Telegram 真实 API 完整验证

**入口**：新增 `tests/verify_telegram_real.sh`。脚本优先读取权限为 600/400 的
`/etc/lnmp/notify.conf`，否则隐藏输入 Bot Token；Chat ID 交互输入。凭据只写入权限 600
的 `/tmp/lnmp-telegram-real.*` 临时配置，不进入命令行、测试结果或仓库。

真实 Telegram API 第一轮运行编号 `20260816102533`：

- 基础 HTML：API 成功，带编号消息到达，标题粗体显示。
- 非闭合 HTML：Telegram 返回真实 400，现有错误文案匹配成功，纯文本重发返回 0，
  消息以原始 `<b>` 文本到达。
- 未转义 MarkdownV2 保留字符：Telegram 返回真实 400，`Character '` 分支成功匹配，
  纯文本重发返回 0，全部原始字符到达。
- 首次“合法 MarkdownV2”自动检查失败，实际消息显示 `*标题*` 和反斜杠，说明走了
  纯文本降级。复核后确认测试向量在 Bash 双引号中丢失反引号前的反斜杠，不是
  `tools/lnmp-tgnotice.sh` 的产品失败。测试脚本已改用不会吞转义符的单引号参数，并新增
  `markdown` 单项复测模式。

修正测试向量后第二轮运行编号 `20260816103742`，自动检查和 Telegram 目视检查均为
4/4 通过：

- `API_BASIC=PASS`、`API_HTML_FALLBACK=PASS`；
- `API_MARKDOWN_VALID=PASS`、`API_MARKDOWN_FALLBACK=PASS`；
- 四项 `VISUAL_*=PASS`，`AUTOMATIC_PASS=4`、`FAILURES=0`、`FINAL=PASS`。

合法 MarkdownV2 消息直接显示粗体标题；``_ * [ ] ( ) ~ ` > # + - = | { } . !``
全部保留字符按原字符显示，没有反斜杠。非法 HTML 以原始 `<b>` 纯文本到达，非法
MarkdownV2 也以全部原始保留字符纯文本到达，证明两条 400 降级链路均实际送达。

**文档处理**：`AUDIT-NOTIFY-001`（真实认证、发送、响应解析和到达）与
`AUDIT-NOTIFY-002`（真实 400 文案匹配及降级）已完成并从 `todo.md` 删除；
`AUDIT-NOTIFY-003`（合法 MarkdownV2 与保留字符显示）复测通过并从 `todo.md` 删除。

- **验证状态**：已实测（真实 Telegram API，2026-08-16）。

## FIX-DB-016 管理命令与备份工具的临时凭据缺少 socket

**问题**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp` 的 `Make_TempMycnf` 写出的
`~/.my.cnf` 只含 `[client] user/password`；`tools/lnmp-backup.sh` 的 `Cmd_Init`
写出的 `/etc/lnmp/backup-mysql.cnf` 同样只含 `[mysqldump]`/`[client]` 的
user/password。所有调用方使用 `--defaults-file`，该选项取代默认配置文件搜索，
`/etc/my.cnf` 中的 `socket = /run/mysqld/mysqld.sock`（由 `include/mysql.sh`、
`include/mariadb.sh` 写入）不再被读取，客户端回落到编译内置的 `/tmp/mysql.sock`。

**影响**：`lnmp database` 全部子命令与 `lnmp backup init` 在三栈默认安装上均报
`ERROR 2002 ... socket '/tmp/mysql.sock'`，口令正确也被判为校验失败。
`include/main.sh` 的同名函数此前已写入固定 socket，安装流程不受影响。

**行为变化**：临时凭据文件新增 `socket=` 行，取值来自新增的 `Get_Actual_DB_Socket`
——解析 `/etc/my.cnf`，`[client]` 段优先，其次 `[mysqld]`，剥离行内注释，
取不到时回落 `/run/mysqld/mysqld.sock`。`include/main.sh` 原先硬编码的 socket 改为
调用同一解析，行为在默认安装下等价，自定义 socket 时随配置生效。

**行号**：
- `conf/lnmp:1185`、`conf/lnmpa:791`、`conf/lamp:674`：新增 `Get_Actual_DB_Socket`，
  `Make_TempMycnf` 增加 `sock` 局部变量与 `socket=` 行。
- `tools/lnmp-backup.sh:183`：新增 `Get_Actual_DB_Socket`；`Cmd_Init` 增加
  `db_sock` 局部变量，option file 的两个段各写入 `socket=`。
- `include/main.sh:772`：新增 `Get_Actual_DB_Socket`；`Make_TempMycnf` 改为调用它。

**验证**（Debian 13、MariaDB 11.8.8、socket `/run/mysqld/mysqld.sock`）：

解析函数单测：无配置文件回落默认值；`[client]` 与 `[mysqld]` 同时存在时取
`[client]`；仅 `[mysqld]` 且带行内注释时取 `/var/run/mysqld/custom.sock`；
配置无 socket 项时回落默认值。

真机功能：

- `lnmp database list`：口令校验通过并列出全部数据库。
- `lnmp database add`：创建 `chk_db` 及同名用户成功。
- `lnmp database export chk_db /tmp/chk.sql.gz`：导出成功，文件权限 600。
- `lnmp database import chk_db /tmp/chk.sql.gz`：删表后导入，数据完整恢复。
- `lnmp database del`：删除库与用户，`SHOW DATABASES` 不再列出。
- `lnmp backup init`：凭据校验通过并写入 `/etc/lnmp/backup-mysql.cnf`（600），
  systemd timer 启用成功。
- `lnmp backup run all` / `run db` / `status` / `list`：均返回 0，数据库批次导出成功。
- `lnmp backup test`：SHA256 校验通过，试恢复 1 张表通过。

修复前同一环境下 `lnmp database list` 与 `lnmp backup init` 均失败，错误为
`Can't connect to local server through socket '/tmp/mysql.sock'`。

`bash -n` 覆盖五个改动文件均通过；`t/lint.sh` 18/18、`t/consistency.sh` 14/14。

- **验证状态**：已实测（Debian 13，LNMP）。LNMPA 与 LAMP 为同一改法的相同实现，
  本轮只做静态检查与解析函数单测。

## FIX-OPS-005 管理命令的退出码与参数校验

**问题**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp` 顶层 `case "${1}"` 的 `*)` 分支
打印用法后直接 `exit`，退出码沿用上一条 `echo` 的 0；子级分支（`lnmp nginx foobar`、
`lnmp vhost foo` 等）均已返回 1。`database`、`ssl`、`dnsssl`、`onlyssl` 四个分支
在校验动作名之前就进入交互：`lnmp database foo` 先索要数据库 root 口令，
`lnmp ssl foo` 直接进入域名输入，DNS 服务商名要走完全部交互才在签发前报错。

**行为变化**：
- 顶层 `*)` 分支返回 1，不带参数执行 `lnmp` 同样返回 1（此前为 0）。
- `lnmp database <无效动作>` 打印 `Function_Database` 既有的用法文本并返回 1，
  不再要求输入口令。合法动作（add/list/del/edit/export/import）行为不变。
- `lnmp ssl <无效动作>` 打印 `用法：lnmp ssl add` 并返回 1；`lnmp ssl` 与
  `lnmp ssl add` 行为不变。
- `lnmp dnsssl <服务商>` / `lnmp onlyssl <服务商>` 在 `/usr/local/acme.sh/dnsapi`
  已存在时先核对插件，缺失即返回 1；acme.sh 尚未安装时维持原有流程，
  由原位置的检查负责。服务商名不做白名单限制，acme.sh 支持的插件均可使用。

**行号**：三份管理脚本的顶层 `*)` 分支、`database)` 分支、`ssl)` 分支，
以及 `Add_Dns_SSL` 与 `Add_Dns_SSL_Only` 的参数处理段（每份各 2 处）。

**验证**（Debian 13，按发布包排除规则打包后安装的 `/bin/lnmp`）：

| 命令 | 退出码 | 首行输出 |
|---|---:|---|
| `lnmp`（无参数） | 1 | 用法列表 |
| `lnmp foobar` | 1 | 用法列表 |
| `lnmp status` | 0 | 服务状态 |
| `lnmp vhost list` | 0 | 站点列表 |
| `lnmp vhost foo` | 1 | `用法：lnmp vhost {add\|list\|del}` |
| `lnmp database foo` | 1 | `用法：lnmp database {add\|list\|edit\|del}` |
| `lnmp ssl foo` | 1 | `用法：lnmp ssl add` |
| `lnmp phpmyadmin status` | 0 | 访问地址 |
| `lnmp backup status` | 0 | 备份状态 |

DNS 插件校验：模拟 `/usr/local/acme.sh/dnsapi` 存在时，`lnmp dnsssl foo` 与
`lnmp onlyssl foo` 立即输出 `未找到 DNS 服务商插件：foo。` 并返回 1；
放入 `dns_cx.sh` 后 `lnmp dnsssl cx` 正常进入域名交互。目录不存在时两者维持原流程。

- **验证状态**：已实测（Debian 13，LNMP）。LNMPA 与 LAMP 为同一改法，静态检查通过。

## FIX-UNINSTALL-004 卸载不清理备份定时任务

**问题**：`lnmp backup init` 会写入 `/etc/systemd/system/lnmp-backup.service`、
`lnmp-backup.timer`（有 systemd 时）或 `/etc/cron.d/lnmp-backup`。三个
`Uninstall_*` 流程删除了 `/bin/lnmp-backup`，但不处理这三个文件，timer 保持
enabled，每天触发后因 ExecStart 不存在而失败。`lnmp backup` 也没有反向的移除子命令。

**行为变化**：新增 `Remove_Backup_Schedule`，在三个卸载流程的 `Remove_Acme` 之后调用：
停用并删除 timer 与 service、`systemctl daemon-reload`、删除 cron 文件。
备份数据本身不在清理范围内。卸载前的删除清单同步补齐 `/bin/lnmp-phpmyadmin`、
`/etc/profile.d/lnmp-tgnotice.sh`、phpMyAdmin 目录、acme.sh、多版本 PHP、
备份定时任务与 `/etc/lnmp`，与实际删除范围一致。

**行号**：`uninstall.sh` 新增 `Remove_Backup_Schedule`；`Uninstall_LNMP` /
`Uninstall_LNMPA` / `Uninstall_LAMP` 各加一处调用；三处提示清单补齐。

**验证**（Debian 13）：造出 enabled 状态的 `lnmp-backup.timer`、对应 service 与
`/etc/cron.d/lnmp-backup` 后，单独执行该函数：三个文件均删除，
`systemctl is-enabled lnmp-backup.timer` 为 `not-found`、`is-active` 为 `inactive`；
重复执行返回 0，无报错。

- **验证状态**：已实测（Debian 13）。

## FIX-SVC-001 memcached 服务单元缺少临时目录隔离

**问题**：`init.d/*.service` 共 8 个单元，只有 `memcached.service` 没有
`PrivateTmp=true`。

**行为变化**：`init.d/memcached.service` 增加 `PrivateTmp=true`。memcached 由
`init.d.memcached` 以 `-l 127.0.0.1 -p 11211` 启动，pid 文件在 `/run/memcached/`，
不使用 `/tmp` 下的 socket 或共享文件，隔离后行为不变。

未增加 `ExecReload`：`init.d.memcached` 与 `init.d.pureftpd` 均只实现
start/stop/status（pureftpd 另有 restart），memcached 与 pure-ftpd 本身不支持
配置热重载，补一个假的 reload 反而会给出错误预期。`pureftpd.service` 未加
`ExecStop`，systemd 默认对主进程发 SIGTERM，pure-ftpd 据此正常退出。

**验证**：`systemd-analyze verify init.d/memcached.service` 除"目标机未安装
memcached"外无告警；`nginx.service`、`redis.service` 对照校验无告警。

- **验证状态**：已验证（静态，Debian 13 systemd 257）。

## CLN-402 删除 autoconf 2.13 死代码与无调用者的函数

**问题**：`Install_Autoconf` 没有任何调用者。`include/profile.sh` 的
`PHP_Needs_Autoconf213` 恒为 `'n'`（仅 PHP 5.2 需要），当前支持的 PHP 为 8.0–8.5。
`Firewall_Available` 同样没有调用者。校验清单与每周 URL 探测仍覆盖着一个实际
不会被下载的文件。

**行为变化**：安装、升级和运维路径均不涉及这些代码，外部行为无变化。

**行号与删除内容**：
- `include/init.sh`：`Install_Autoconf` 函数。
- `include/version.sh`：`Autoconf_Ver='autoconf-2.13'`。
- `include/profile.sh`：`PHP_Needs_Autoconf213` 的注释与初始化赋值。
- `include/firewall.sh`：`Firewall_Available` 函数。
- `src/checksums.sha256`：`autoconf-2.13.tar.gz` 条目，清单由 66 条变为 65 条。
- `t/gen_checksums.sh`、`t/probe_urls.sh`：对应的采集与探测行。
- `t/consistency.sh`：`check_v4` 跳过列表中的 `Autoconf_Ver`。
- `t/check_upstream.sh`：固定版本说明表中的 `Autoconf_Ver` 行。
- `init.d/init.d.fail2ban`：无部署方的孤儿文件。`tools/fail2ban.sh` 使用
  fail2ban 源码包自带的 `files/redhat-initd` / `files/debian-initd`。

**保留**：`conf/memcached1.php`、`conf/memcached2.php` 由 `include/memcached.sh`
以 `conf/memcached${ver}.php` 拼接引用，不是孤儿文件。

**验证**：全仓库 90 个脚本 `bash -n` 通过；`t/lint.sh` 全部通过（C10 记 65 条）；
`t/consistency.sh` 14/14；`t/test_profile.sh`、`t/test_dispatch.sh`、
`t/test_bump.sh`、`t/test_upstream.sh` 均返回 0。

- **验证状态**：已验证（静态）。

## DOC-702 HowtoGuides 补齐三个工具脚本的操作说明

**问题**：`tools/fail2ban.sh`、`tools/remove_disable_function.sh`、
`tools/remove_open_basedir_restriction.sh` 只在 `README.md` 的工具表里列了一行
用途，`HowtoGuides.md` 没有执行步骤和示例。

**行为变化**：仅文档。

**新增内容**：
- 9.8「程序提示函数被禁用」：`remove_disable_function.sh` 的三个菜单选项、
  生效方式与解禁范围的取舍。
- 9.9「程序提示 open_basedir 限制」：`remove_open_basedir_restriction.sh` 的
  输入项，以及优先改程序路径的建议。
- 10.1 管理员待办第 1 条：`fail2ban.sh` 与 `denyhosts.sh` 二选一的说明，
  fail2ban 的 nftables 封禁动作、7 天封禁时长与 `fail2ban-client status` 检查方式。

- **验证状态**：已验证（静态，命令与脚本实现逐项核对）。

## RUN-037 Debian 13 收官复核批次

**环境**：Debian 13 (trixie)、NAT 网络。沿用既有环境：nginx 1.30.4（编译版）、
PHP 8.3.33、MariaDB 11.8.8、Redis。

**复核范围与结果**：

- `SecurityCheck.md` 的可证伪断言逐条对当前代码取证，全部仍成立：脚本数 87、
  `Download_Fetch` 仅 HTTPS 且禁止重定向降级、缓存命中重新校验、校验四条件
  fail-closed、nginx/OpenResty 固定指纹白名单、Composer SHA-384、acme.sh 固定版本
  并关闭自动升级、三个降级入口默认关闭。生产代码最后修改时间早于该报告的审计脚本
  执行时间，二进制重编与 HTTP 触发结论继续适用，本轮未重跑。
- 完整性：校验清单与代码引用闭环无缺漏；无未定义函数调用；三栈子命令矩阵差异
  与架构一致（LAMP 无 nginx/php-fpm，LNMPA 用 mod_php 故无 php-fpm）；
  文档与实现的子命令对账无缺口。
- GitHub Actions：5 个工作流 YAML 合法，引用的 11 个 `t/*.sh` 全部存在，
  顶层权限为最小集，发布包排除规则正确。
- 功能：服务启停与返回码、`vhost add/list/del`、站点级 PHP 开关、`phpmyadmin status`
  均正常；WordPress 7.0.3 主线（首页、固定链接、REST、数据库、PHP-FPM、Redis）通过。
- 发布包形态验证：按 `release.yml` 的排除规则打包（不含 `tests/`）后在测试机解包，
  `t/lint.sh`、`t/consistency.sh`、全量 `bash -n`、四个入口脚本的参数校验、
  `bumpversion.sh` 与全部管理命令均正常。产品代码、`t/` 与工作流对 `tests/` 的
  引用数为 0，`tests/` 仅供本地开发使用，不影响使用者。

**本轮修复并归档**：FIX-DB-016、FIX-OPS-005、FIX-UNINSTALL-004、FIX-SVC-001、
CLN-402、DOC-702。

**登记为待处理**：`todo.md` 的 REV-003、REV-004、REV-005（`tests/` 内三个定向测试
脚本自身失效）与 REV-011、REV-012。`tests/` 不随发布包分发，按需修复。

- **验证状态**：已实测（Debian 13，LNMP）。

## GHA-011 CI 的 ShellCheck 覆盖三份运维脚本

**问题**：`.github/workflows/ci.yml` 的 ShellCheck 步骤检查
`install.sh uninstall.sh upgrade.sh addons.sh pureftpd.sh include/*.sh t/*.sh tools/*.sh`，
不含 `conf/lnmp`、`conf/lnmpa`、`conf/lamp`。这三份是安装后作为 `/bin/lnmp` 使用的
运维入口，合计 8000 余行，此前只有 `bash -n` 语法覆盖。

**行为变化**：ShellCheck 步骤增加 `conf/lnmp conf/lnmpa conf/lamp`。三份文件均以
`#!/bin/bash` 开头，不需要 `-s bash` 指定方言。排除项与其余文件一致
（SC1090/SC1091/SC2086/SC2181）。

`tests/` 未纳入：该目录只在本地开发使用，不随发布包分发。

**连带修复**：扩容后暴露出 `include/apcu.sh` 第一行的 shebang 前有一个空格
（SC1114 error）。该文件由 `addons.sh` 以 `source` 方式加载，运行不受影响，
但直接执行时不会走 bash 解释器。已去掉前导空格。

**验证**：在 Debian 13（shellcheck 0.10.0）按 ci.yml 的完整参数执行，
修复 `include/apcu.sh` 前报 SC1114 并返回 1，修复后返回 0。
全仓库 shebang 前有空白的文件数为 0。

- **验证状态**：已实测（Debian 13，复现 CI 步骤）。

## FIX-OPS-006 非交互执行时 clear 输出 TERM 报错

**问题**：8 处 `clear` 调用在无 TERM 的环境（ssh 非交互、CI、cron）下输出
`TERM environment variable not set.`，出现在安装、升级、卸载等脚本的首行。

**行为变化**：改为 `clear 2>/dev/null || true`，并在上一行说明原因。有终端时清屏
行为不变；无终端时不再输出报错，且清屏失败不影响后续流程与退出码。

**行号**：`install.sh:61`、`addons.sh:98`、`upgrade.sh:61`、`uninstall.sh:26`、
`pureftpd.sh:22`、`include/only.sh:27,163`、`tools/remove_disable_function.sh:19`。

**验证**（Debian 13，`env -u TERM` 且 stdin 为 `/dev/null`）：
`install.sh`、`upgrade.sh`、`addons.sh`、`uninstall.sh`、`pureftpd.sh` 与
`tools/remove_disable_function.sh` 的 TERM 报错行数均为 0，退出码与修改前一致。

- **验证状态**：已实测（Debian 13）。

## FIX-OPS-007 pureftpd.sh 的无效参数会触发安装

**问题**：`pureftpd.sh` 只判断 `[ "${action}" = "uninstall" ]`，其余取值一律落入
安装分支。`./pureftpd.sh foobar` 会完整安装 Pure-FTPd 并开放 FTP 服务——
输错一个参数就多了一个对外服务。本轮复核中实际触发过一次。

**行为变化**：参数进入白名单校验，只接受空、`install`、`uninstall`；
其余打印用法并返回 1。取值只收小写，与文件末尾既有的
`[ "${action}" = "uninstall" ]` 判断保持一致，避免 `Uninstall` 这类写法
通过校验后落入安装分支。不带参数仍等同安装，既有用法不变。

**行号**：`pureftpd.sh:10` 之后新增参数校验段。

**验证**（Debian 13）：`./pureftpd.sh foobar`、`--help`、`Uninstall` 均返回 1
并打印 `用法：./pureftpd.sh [install|uninstall]`，未触发安装或卸载；
`./pureftpd.sh uninstall` 正常卸载，`/usr/local/pureftpd`、`/etc/init.d/pureftpd`、
`/etc/systemd/system/pureftpd.service` 全部删除，21 端口不再监听，返回 0。

**附带覆盖**：借该次误装完成了此前因未安装而跳过的 FTP 验证——
`lnmp ftp` 与 `lnmp ftp foo` 返回 1 并打印用法，`lnmp ftp list` 返回 0，
`lnmp ftp add` / `del` 正常；`pureftpd.service`（含 `PrivateTmp=true`）
active 且开机自启；`TLS 2` 生效，显式 FTPS 登录成功列目录，明文 FTP 被拒绝。

- **验证状态**：已实测（Debian 13）。

## FIX-SVC-002 lnmp kill 后 Web 服务被标记为 failed

**问题**：`lnmp kill` 用 `killall` 直接结束进程，随后 systemd 执行 ExecStop：

- `php-fpm.service` 的 `ExecStop=/bin/kill -s QUIT $MAINPID`，此时 `$MAINPID`
  为空，`kill` 因缺少 pid 参数打印用法并返回 1。
- `nginx.service` 的 `ExecStop=/usr/local/nginx/sbin/nginx -s quit`，master 已不存在，
  命令同样失败。

两者都使服务进入 `failed`，`lnmp stop` 清不掉，需要 `lnmp start` 或
`systemctl reset-failed`。php-fpm 还会连带触发 `RuntimeDirectory=php-fpm` 的回收：
`/run/php-fpm` 被删除，若仍有 php-fpm 进程存活并持有已删除的 socket，
再次 `systemctl start` 会以 `Another FPM instance seems to already listen` 失败。

`httpd.service` 的 `ExecStop=/usr/local/apache/bin/httpd -k stop` 属于同一情形，
LNMPA 与 LAMP 的 `lnmp kill` 会 `killall httpd`。

**行为变化**：三个单元不再自定义 ExecStop，改由 systemd 发送停止信号，
信号语义与原命令一致：

| 单元 | 原 ExecStop | 现配置 |
|---|---|---|
| `nginx.service` | `nginx -s quit`（SIGQUIT） | `KillSignal=SIGQUIT` |
| `php-fpm.service` | `kill -s QUIT $MAINPID` | `KillSignal=SIGQUIT` |
| `httpd.service` | `httpd -k stop`（SIGTERM） | systemd 默认 SIGTERM |

`ExecReload` 保持不变：nginx 与 httpd 用自带命令，php-fpm 的 `kill -USR2 $MAINPID`
只在服务运行时执行。

**验证**（Debian 13，LNMP）：

- 常规路径：`systemctl stop/start/restart/reload nginx` 与 php-fpm 均正常，
  停止后端口释放、socket 清理，HTTP 200。
- `lnmp kill` 后 nginx 与 php-fpm 均为 `inactive`（修改前两者均为 `failed`），
  `lnmp start` 与 `lnmp restart` 都能直接恢复，返回 0，三个服务 active，HTTP 200，
  无需 `reset-failed`；连续多轮 kill/start、kill/restart 结果一致。
- `systemd-analyze verify` 对四个改动或相关单元无告警。

httpd.service 为同一改法，LNMP 测试机无 Apache，只做静态校验。

- **验证状态**：已实测（Debian 13，LNMP）；httpd 已验证（静态）。

## FIX-SVC-003 Redis 与 Memcached 在进程被外部结束后被标记为 failed

**问题**：`redis.service` 的 `ExecStop=redis-cli shutdown` 在进程已不存在时连接被拒，
返回 1，systemd 把服务标记为 failed。`memcached.service` 的
`ExecStop=/etc/init.d/memcached stop` 同理——`init.d.memcached` 的 stop 分支在
pid 文件缺失或 kill 失败时 `exit 1`。与 FIX-SVC-002 同一类，但这两个服务的停止
命令承担实际工作（Redis 存盘、memcached 等待退出），不能像 Web 服务那样改成
由 systemd 直接发信号。

**行为变化**：两个单元的 ExecStop 加 `-` 前缀，systemd 执行停止命令但忽略其退出码。
正常停止路径不变：服务在运行时仍由 `redis-cli shutdown` 存盘退出、由 init 脚本
等待 memcached 结束；只有"进程已不在"这种情况不再判定为失败。

**数据库不在本次范围**：`mariadb.service` / `mysql.service` 的
`ExecStop=/etc/init.d/… stop` 经实测**不受影响**。Debian 13 + MariaDB 11.8.8 上
`killall mariadbd` 后，init 脚本打印 `ERROR! MariaDB server PID file could not be found!`
但退出码为 0，systemd 记为 `Deactivated successfully`，服务为 `inactive` 而非 failed。
`mysql.server` 的 stop 分支结构相同。两个单元保持原样。

**验证**（Debian 13）：Redis 实测——修改前 `killall redis-server` 后服务为 `failed`
（journal 记 `Could not connect to Redis at 127.0.0.1:6379: Connection refused`,
`status=1/FAILURE`）；换用新单元后同一操作结果为 `inactive`，
`systemctl start redis` 直接恢复，`redis-cli ping` 返回 PONG。
常规 `systemctl stop/start` 正常。memcached 未在测试机安装，为同一改法，静态校验通过。

- **验证状态**：已实测（Debian 13，Redis）；memcached 已验证（静态）。

## FIX-OPS-008 lnmp kill 不会终止 MariaDB

**问题**：`lnmp_kill` 只有 `killall mysqld`，而 MariaDB 的进程名是 `mariadbd`。
Debian 13 + MariaDB 11.8.8 实测 `killall -0 mysqld` 返回 1、
`killall -0 mariadbd` 返回 0。命令输出称"正在终止……数据库进程"，实际数据库仍在运行。

**行为变化**：三份管理脚本各增加一行 `killall mariadbd`，并给这两行加 `2>/dev/null`
抑制必然出现的 `no process found`（一台机器只会存在其中一个进程名）。
`killall` 默认发 SIGTERM，数据库据此正常关闭。

**行号**：`conf/lnmp:216`、`conf/lnmpa:177`、`conf/lamp:171` 附近的 `lnmp_kill` /
`lnmpa_kill` / `lamp_kill`。

**验证**（Debian 13，LNMP）：

- `lnmp kill` 后数据库进程数为 0，`mariadb` 为 `inactive`；修改前该服务保持 `active`。
- 三个服务均为 `inactive`，无 failed；输出只剩既有的 `php-cgi: no process found`。
- `lnmp restart` 与 `lnmp start` 都返回 0，三个服务恢复 active，HTTP 200，
  `SELECT 1` 正常。
- MariaDB 错误日志显示正常启动（`Buffer pool(s) load completed`、
  `ready for connections`），无崩溃恢复记录，确认 SIGTERM 为优雅关闭。

- **验证状态**：已实测（Debian 13，LNMP）。LNMPA 与 LAMP 为同一改法，静态检查通过。

## GHA-012 `t/build_test.sh` 的 Lua 验证缺少 LuaJIT 运行时库路径

**问题**：Build Test 工作流 lua 作业在 `写测试配置并启动` 步骤失败：

```
/usr/local/nginx-luatest/sbin/nginx: error while loading shared libraries:
libluajit-5.1.so.2: cannot open shared object file: No such file or directory
!! nginx -t 未通过
```

LuaJIT 装在 `/usr/local/luajit/lib`，该路径不在动态链接器搜索范围内。
`t/build_test.sh` 只导出了 `LUAJIT_LIB` / `LUAJIT_INC` 供 configure 使用，
既没有写 `/etc/ld.so.conf.d` 也没有给 nginx 加 rpath，因此编译和安装都成功，
执行 `nginx -t` 时才失败。同一批次里 nginx 全模块与 PHP 作业不涉及 LuaJIT，正常通过。

**根因**：验证脚本与产品安装流程不一致。`include/nginx.sh` 装完 LuaJIT 后
写 `/etc/ld.so.conf.d/luajit.conf` 并执行 `ldconfig`（第 54-62 行），
configure 另带 `--with-ld-opt=-Wl,-rpath,/usr/local/luajit/lib`（第 121-130 行），
两重保障；`t/build_test.sh` 两者都缺。产品代码本身无此缺陷。

**行为变化**：`t/build_test.sh` 的 `build_lua` 对齐产品流程：

- `make install` 后写 `/etc/ld.so.conf.d/luajit.conf` 并 `ldconfig`，失败即中止。
- nginx configure 增加 `--with-ld-opt="-Wl,-rpath,/usr/local/luajit/lib"`。
- `nginx` 启动命令补 `|| die`，避免启动失败后仍继续发请求、把问题表现成空响应。

**连带修复**：库路径修好后第一次跑到发请求这一步，`/restycore` 返回
`resty-core-ok:vnil0` 判定为失败。原因是 `resty.lrucache` 的 `get` 返回
`data, stale_data, flags` 三个值，`ngx.say("resty-core-ok:", c:get("k"))`
把三个值全部输出。测试配置改为 `ngx.say("resty-core-ok:", (c:get("k")))`，
用括号截断成单值。Lua 运行本身正常，是断言写法有误。

**验证**（Debian 13，先移走 `/etc/ld.so.conf.d/luajit.conf` 和
`/lib64/libluajit-5.1.so.2` 并 `ldconfig`，使 `ldconfig -p` 中 luajit 条目为 0，
以复现 CI 的干净环境）：

- 修复前的脚本：编译与安装成功，`nginx -t` 报
  `libluajit-5.1.so.2: cannot open shared object file`，与 CI 日志一致。
- 修复后的脚本：`nginx -t` 通过，`/lua` 返回 `lua-ok`，
  `/restycore` 返回 `resty-core-ok:v`，脚本返回 0。
- 两层保障各自有效：`readelf -d` 显示 nginx 带
  `RUNPATH [/usr/local/luajit/lib]`；再次移走 ld 配置并 `ldconfig` 后
  `nginx -t` 仍通过，说明仅靠 rpath 即可启动。

- **验证状态**：已实测（Debian 13，lua 模式完整执行）。

## GHA-013 工作流 action 升级到 Node 24 运行时

**问题**：GitHub Actions 运行日志提示 Node.js 20 已弃用，`actions/checkout@v4` 等
被强制运行在 Node.js 24 上。

**行为变化**：`.github/workflows/` 全部第三方 action 升到各自首个 `runs.using: node24`
的主版本，避免跨过带行为变更的版本：

| action | 原版本 | 现版本 |
|---|---|---|
| `actions/checkout` | v4 | v5 |
| `actions/upload-artifact` | v4 | v6 |
| `actions/download-artifact` | v4 | v7 |
| `actions/github-script` | v7 | v8 |
| `actions/attest-build-provenance` | v1 | v3 |
| `peter-evans/create-pull-request` | v6 | v8 |
| `softprops/action-gh-release` | v2 | v3 |

未取更高主版本的原因：`upload-artifact` v7 改为 ESM 并引入直传，
`download-artifact` v8 默认强制校验哈希且不再无条件解压，均非本项目所需。

已核对与本项目用法相关的破坏性变更：`download-artifact` v5 只改变按 artifact ID
下载时的落地路径，本项目按 `name` 下载，不受影响；`create-pull-request` v7 把
`git-token` 更名为 `branch-token` 并移除 `PULL_REQUEST_NUMBER` 输出，
`upstream-check.yml` 两者都未使用。node24 要求 Actions Runner 2.327.1 以上，
本项目全部作业运行在 GitHub 托管 runner 上。

- **验证状态**：YAML 解析通过；待各工作流实跑确认。

## GHA-014 Issues 限定协作者后，探测失败不再被静默丢弃

**背景**：仓库把 Issues 的交互限制设为 collaborators only。该限制作用于用户账号，
不影响工作流内的 `GITHUB_TOKEN`：`url-health.yml` 已在工作流级声明
`permissions: issues: write`，`github-actions[bot]` 仍可创建 issue 与追加评论。

**问题**：`url-health.yml` 的开 issue 步骤没有错误处理。若 Issues 被整体关闭
（API 返回 410）或 token 权限被收紧（403），探测到的失效下载源只留在 Actions 日志里，
作业仍为成功，失效结果实际被丢弃。

**行为变化**：创建 issue 与追加评论包进 `try/catch`。失败时把原本要写进 issue 的
正文写入作业摘要（`core.summary`），并 `core.setFailed`，让作业红灯。
探测本身成功时行为不变。

- **验证状态**：YAML 解析通过；错误分支需在 Issues 关闭的仓库状态下触发，未实跑。

## FEAT-VHOST-002 站点错误日志与自定义配置区块

**问题**：`lnmp vhost add` 生成的站点配置只有 default 站点带错误日志。普通站点在
访问日志开关选 `n` 时，Nginx 侧没有 `error_log`，Apache 侧的 `ErrorLog` 也被
一并注释掉，站点级错误只能落到 `nginx_error.log` 或 Apache 主错误日志。

**行为变化**：

1. 错误日志与访问日志开关解耦，一律写入：

| 位置 | 写入内容 |
|---|---|
| `conf/lnmp` `Add_VHost_Config`、`Create_SSL_Config` | `error_log   /home/wwwlogs/<域名>.error.log;` |
| `conf/lnmpa` `Add_VHost_Config`、`Create_SSL_Config` 的 Nginx 配置 | 同上 |
| `conf/lnmpa`、`conf/lamp` 的 Apache 配置 | `ErrorLog "/home/wwwlogs/<日志名>-error_log"` 不再被注释 |

   访问日志开关选 `n` 时仍只注释 `CustomLog`（Apache）或写 `access_log off;`（Nginx）。

2. 站点配置和随包配置模板加入 `# 自定义配置--开始` / `# 自定义配置--结束` 成对注释：

| 文件 | 位置 |
|---|---|
| 三栈生成的站点配置、SSL 追加块 | `server {}` 与 `<VirtualHost>` 末尾 |
| `include/nginx.sh`、`conf/lnmp` 的 default 站点 | `server {}` 末尾 |
| `conf/nginx.conf`、`conf/nginx_a.conf`、`conf/openresty.conf` | `http {}` 内、`include vhost/*.conf;` 之前 |
| `conf/httpd24-lamp.conf`、`conf/httpd24-lnmpa.conf` | `IncludeOptional conf/vhost/*.conf` 之前 |
| `conf/httpd-vhosts-lamp.conf`、`conf/httpd-vhosts-lnmpa.conf` | 默认 `<VirtualHost>` 末尾 |

3. `tools/cut_nginx_logs.sh` 对 `log_files_name` 中的每个名字同时切割
   `<名字>.log` 和 `<名字>.error.log`，归档名分别为 `<名字>_<日期>.log`
   与 `<名字>.error_<日期>.log`。此前 `default.error.log` 不参与切割。

**验证**：

```bash
bash tests/test_vhost_error_log.sh    # 31 项全部通过
bash tests/test_vhost_php_switch.sh   # 全部通过
bash t/lint.sh                        # 全部通过
bash t/consistency.sh                 # 14 项通过
```

`tests/test_vhost_error_log.sh` 覆盖三栈 `Add_VHost_Config` 与 `Create_SSL_Config`
在访问日志关闭时的错误日志写入、Apache `ErrorLog` 不被注释、`CustomLog` 仍被注释，
以及站点配置、随包模板和 default 站点的自定义标记成对。

**顺带修复**：`tests/test_vhost_php_switch.sh` 此前未加载
`Check_Config_Name`、`Check_Server_Admin_Email`、`Check_Config_File_Path`，
`Add_VHost_Config` 与 `Create_SSL_Config` 一进函数就返回 1，配置文件从未生成，
29 项断言长期失败。补齐函数加载并把证书桩换成沙箱内的真实文件后全部通过。

- **验证状态**：已验证（静态）。生成的配置未在目标系统实跑 `nginx -t` 与
  `httpd configtest`。

---

## CONF-010 Nginx 配置统一为 4 空格阶梯缩进

**问题**：随包模板与自动生成的站点配置沿用旧排版，块内第一层用 8 空格、
闭合花括号用 4 空格，与内层 `location` 的 4 空格步进不一致；
`conf/rewrite/*.conf` 另有制表符、1 空格、6 空格和缺失缩进混用。
缩进不影响 nginx 解析，属排版问题。

**行为变化**：生成配置的文本缩进变化，指令与层级结构不变。

1. 缩进规则统一为：每层 4 空格，闭合花括号与其所属块的起始行同列。
   被 `include` 进 `server {}` 的片段以 4 空格为第一层，与展开位置对齐。

| 范围 | 文件 |
|---|---|
| 主配置 | `conf/nginx.conf`、`conf/nginx_a.conf`、`conf/openresty.conf` |
| include 片段 | `conf/enable-php.conf`、`conf/enable-php-pathinfo.conf`、`conf/enable-php8.0`–`8.5.conf`、`conf/proxy-pass-php.conf`、`conf/rewrite/*.conf` |
| 示例配置 | `conf/example/` 下 9 个 Nginx 示例 |
| 生成模板 | `conf/lnmp` `Add_VHost_Config`/`Create_SSL_Config`/`Site_PHP_Off_Block`/default 补建块、`conf/lnmpa` 同名函数、`include/nginx.sh` `Write_Nginx_Default_VHost`、`include/php.sh` 的 phpMyAdmin 片段 |
| `sed` 插入串 | `conf/lnmp`、`conf/lnmpa` 的 301 跳转块，`include/nginx.sh` 的 `lua_package_path`/`lua_package_cpath`/`brotli`，`include/upgrade_nginx.sh` 的 `lua_package_path` |

2. `conf/nginx.conf`、`conf/nginx_a.conf`、`conf/openresty.conf` 中原本顶格的
   `server {}` 与 `include vhost/*.conf;` 移入 `http {}` 的缩进层级；
   `conf/nginx.conf` 中两行制表符缩进改为空格。

3. `conf/rewrite/*.conf` 按花括号深度重排，制表符改为空格，补齐缺失的行尾换行；
   `conf/rewrite/zblog.conf` 的 `){` 改为 `) {`。

4. `include/upgrade_nginx.sh` 补建 `/lua` 块的插入串保持 8/12 空格：该块位于
   `server {}` 内第二层，缩进值不随本次调整变化。

**连带修复**：模板闭合花括号改为顶格后，`sed -n "/^name()/,/^}/p"` 会在
heredoc 内的 `}` 处提前截断函数体。新增 `tests/extract_func.sh` 按 heredoc
状态提取函数定义，替换 `tests/test_vhost_php_switch.sh`、
`tests/test_vhost_error_log.sh`、`tests/test_vhost_prompt_output.sh`、
`tests/test_security_fixes.sh`、`tests/test_apache_stack_service_failures.sh`
中的同类 `sed` 提取。`tests/verify_vhost_php_remote.sh` 插入的测试用
`location /api/` 同步改为 4 空格。

**新增检查脚本**：

- `tests/check_nginx_indent.sh [-b 基准列数] <文件>...`：校验缩进等于基准列数加
  花括号深度乘 4，识别指令参数续行与注释行。
- `tests/render_vhost_preview.sh <脚本> <起始行> <结束行>`：用固定假值渲染
  heredoc 模板，输出实际生成的配置。

**验证**：

```bash
bash tests/check_nginx_indent.sh conf/nginx.conf conf/nginx_a.conf \
     conf/openresty.conf conf/example/*.conf          # 通过（Apache 示例除外）
bash tests/check_nginx_indent.sh -b 4 conf/enable-php*.conf \
     conf/proxy-pass-php.conf conf/rewrite/*.conf     # 通过
bash tests/test_vhost_php_switch.sh                   # 全部通过
bash tests/test_vhost_error_log.sh                    # 全部通过
bash tests/test_apache_stack_service_failures.sh      # 6 项通过
bash t/lint.sh                                        # 全部通过
bash t/consistency.sh                                 # 14 项通过
```

六处 heredoc 模板经 `tests/render_vhost_preview.sh` 渲染后通过缩进校验；
301 跳转块、`lua_package_path`/`lua_package_cpath`/`brotli` 插入、升级脚本补建
`/lua` 块的 `sed` 均在渲染结果上实跑并复校缩进。

`tests/test_vhost_prompt_output.sh` 有既有失败 2 项、`tests/test_security_fixes.sh`
有既有失败 1 项，用改动前的 `conf/`、`include/` 对比确认失败项完全一致，
见 `todo.md` 的 REV-005、REV-006。

- **验证状态**：已验证（静态）。生成的配置未在目标系统实跑 `nginx -t`。

---

## REV-003 ~ REV-006 定向测试脚本与产品实现对齐

**背景**：`todo.md` 登记的四条 REV 均为测试侧问题，产品实现无需改动。

### REV-003 `tests/test_vhost_php_switch.sh`

复核结论：三条记录均已不复现。`Check_Config_File_Path`、`Check_Config_Name`
已随 `Create_SSL_Config` 的依赖一并由 `Load_Funcs` 加载（第 183、253、281 行），
第 5 节的沙箱路径改写使 `Add_SSL_Only_Info_Menu` 的站点存在性检查命中
`${tmproot}/usr/local/nginx/conf/vhost/`。非 root 与 Debian 13 测试机 root 下
各执行一次，均 61 项全部通过，不需要 root 前置检查。本条无代码改动。

### REV-004 `tests/verify_vhost_php_remote.sh` 自签证书路径

**行为变化**：第 7 节自签证书由 `mktemp -d /tmp/...` 改写到
`/usr/local/nginx/conf/ssl/<域名>/<域名>.{cer,key}`，目录 0700、私钥 0600，
`phpoff.example.com` 与 `phpon.example.com` 各自一套。

**原因**：`init.d/nginx.service` 含 `PrivateTmp=true`，nginx 进程看到的是私有
`/tmp`，`ssl_certificate` 指向宿主 `/tmp` 路径时 reload/start 报
`cannot load certificate ... No such file or directory`，443 不监听，
4 项 HTTPS 用例返回 000；`KEEP=1` 时该配置残留并阻止 nginx 启动。

**行号**：`tests/verify_vhost_php_remote.sh:267-289`。`Cleanup` 已含
`rm -rf /usr/local/nginx/conf/ssl/${d}`，无需新增清理路径。
`${tmpdir}` 仍用于 `ssl add` 日志，不被 nginx 读取。

**根因对照**（Debian 13 测试机，nginx 1.30.4 编译版 + PHP 8.3.33 + MariaDB 11.8.8）：
临时 vhost 的 `ssl_certificate` 指向 `/tmp/rev004-repro.XXXXXX/t.cer` 时，
`nginx -t` 在普通 shell 中通过，`systemctl reload nginx` 失败：

```
nginx: [emerg] cannot load certificate "/tmp/rev004-repro.YwLxTD/t.cer":
BIO_new_file() failed (SSL: ... No such file or directory ...)
```

对应端口不进入 LISTEN。改用 `conf/ssl/<域名>/` 后同一流程正常。

### REV-005 `tests/test_vhost_prompt_output.sh` 期望值与覆盖

**行为变化**：第 2 节两行提示的期望文本补上 `Color_Text`（`echo -e " \e[0;$2m..."`）
固有的前导空格；循环由 `conf/lnmp conf/lamp` 扩到含 `conf/lnmpa`。

**行号**：`tests/test_vhost_prompt_output.sh:48-58`。

### REV-006 `tests/test_security_fixes.sh` 的 Make_TempMycnf 断言

**行为变化**：断言由字面量 `socket=/run/mysqld/mysqld.sock` 改为校验
`Make_TempMycnf` 中的 `socket=$(Get_Actual_DB_Socket)`，并额外校验
`Get_Actual_DB_Socket` 保留 `/run/mysqld/mysqld.sock` 兜底，
覆盖 MySQL 与 MariaDB 各自的 socket 路径。

**行号**：`tests/test_security_fixes.sh:366-372`，对应实现
`include/main.sh:1381`、`include/main.sh:774`。

**验证**：

```bash
bash -n tests/test_vhost_php_switch.sh tests/verify_vhost_php_remote.sh \
        tests/test_vhost_prompt_output.sh tests/test_security_fixes.sh   # 通过
bash tests/test_vhost_php_switch.sh        # 61 项全部通过
bash tests/test_vhost_prompt_output.sh     # 15 项全部通过（含新增 conf/lnmpa 2 项）
bash tests/test_security_fixes.sh          # 35 项通过，0 项失败
bash t/lint.sh                             # 全部通过
bash t/consistency.sh                      # 14 项通过
```

上述三个测试在 Debian 13 测试机以 root 复跑一次，结果一致（61 / 15 / 35 项全通过）。

REV-004 在 Debian 13 测试机以 root 实跑 `bash tests/verify_vhost_php_remote.sh`：

- 默认清理模式连跑两次，均 43 项 ok、0 FAIL、0 skip，其中第 7 节 11 项 HTTPS
  用例全部通过（修复前该节 4 项返回 000）。
- `KEEP=1` 保留现场后 `systemctl restart nginx` 返回 active，重启后
  `https://phpoff.example.com/real.php` 为 404、`https://phpon.example.com/real.php`
  输出 `PHP-EXECUTED`；证书目录 0700、私钥 0600。
- 默认模式收尾后 `conf/vhost`、`conf/ssl`、`/home/wwwroot` 下测试域名残留均为 0，
  `nginx -t` 通过。`KEEP=1` 会按设计保留 `/tmp/lnmp-php-verify.*` 中的
  `ssl add` 日志供排查，不影响 nginx。

- **验证状态**：REV-003、REV-005、REV-006 已验证（静态）；REV-004 已实测。

---

## FIX-INSTALL-002 独立安装 Nginx 后 nginx.conf 出现未知指令 brotli

**现象**：`bash install.sh nginx` 安装完成，收尾检查显示"Nginx：正常"，但服务起不来：

```
nginx: [emerg] unknown directive "brotli" in /usr/local/nginx/conf/nginx.conf:75
nginx: configuration file /usr/local/nginx/conf/nginx.conf test failed
```

**根因**（三处叠加）：

1. `include/only.sh` 的 `Nginx_Dependent` 不安装 brotli 开发包（完整安装走
   `include/init.sh` 的列表，其中有 `libbrotli-dev` / `brotli-devel`）。缺少
   `/usr/include/brotli/encode.h` 时 `Link_System_Brotli` 返回 1，
   `Install_Ngx_Brotli` 随之返回 1，但 `Install_Nginx` 未处理该返回值，
   `Ngx_Brotli` 保持为空，configure 不含 `--add-module=.../ngx_brotli`。
2. `Install_Nginx` 写入 brotli 指令的条件是开关 `Enable_Ngx_Brotli`，
   与模块是否真的编译进二进制无关，因此模块缺失时仍写入五行 brotli 指令。
3. `Check_Nginx_Files` 只判断 `nginx.conf` 与 `sbin/nginx` 非空，
   配置语法错误也报"Nginx：正常"。

**关联缺陷**（同一条升级/独立安装链路上发现并一并修复）：

- `include/upgrade_nginx.sh` 的两条 `./configure` 不含 `${Ngx_Brotli}`
  `${Ngx_CachePurge}`，升级会丢掉这两个模块；此时 `nginx.conf` 中的
  `brotli` / `proxy_cache_purge` 指令使升级前预检失败，升级无法完成。
- `Nginx_Dependent` 不装 gnupg，`upgrade.sh nginx` 的 nginx PGP 签名校验
  直接中止（`系统缺少 gpg（--dearmor 需要它）`）。
- 替换二进制用 `cp` 覆盖 `sbin/nginx`，nginx 正在运行时返回
  `Text file busy`（ETXTBSY），升级失败；`Rollback_Nginx` 的 `cp -p` 写回
  备份同样失败。

**修改**：

| 文件 | 改动 |
|---|---|
| `include/only.sh` | `Nginx_Dependent` 的 apt 列表加 `libbrotli-dev gnupg gpgv`，yum 列表加 `brotli-devel gnupg2` |
| `include/nginx.sh` | `Install_Nginx` 处理 `Install_Ngx_Brotli` 返回值，失败时清空 `Ngx_Brotli` 并提示；brotli 指令写入条件由 `Enable_Ngx_Brotli` 改为 `[ -n "${Ngx_Brotli}" ]` |
| `include/upgrade_nginx.sh` | 调用 `Install_Ngx_Brotli` / `Install_Ngx_CachePurge`，两条 configure 补 `${Ngx_Brotli} ${Ngx_CachePurge}`；开头按现有二进制 `nginx -V` 保留已编译的 brotli、cache_purge、fancyindex；二进制替换与回滚改为同目录写新文件后 `mv -f` 换名 |
| `include/end.sh` | `Check_Nginx_Files` 增加 `nginx -t` |

**行为变化**：Brotli 依赖不可用时模块与配置指令一起跳过，安装继续完成并打印
提示，`nginx -t` 通过；依赖可用时行为与之前一致。收尾检查在配置语法错误时
报错而不是"正常"。升级保留现有二进制已编译的第三方模块。

**验证**（Debian 13 trixie 测试机，root）：

```bash
bash tests/test_nginx_brotli_guard.sh   # 13 项全部通过
bash t/lint.sh                          # 全部通过
```

`tests/test_nginx_brotli_guard.sh` 用 `Install_Nginx` 的真实代码片段在临时文件
上验证两种取值：把写入条件改回 `Enable_Ngx_Brotli` 时第 1 项复现旧行为并失败。

实机 `bash install.sh nginx`（安装前无 nginx，未装 libbrotli-dev）：

- 依赖阶段自动安装 `libbrotli-dev 1.1.0-2+b7`，`ngx_brotli: 使用系统 brotli 库
  （头文件 /usr/include/brotli，库目录 /usr/lib/x86_64-linux-gnu）`，
  configure 输出 `+ ngx_brotli was configured`。
- 安装后 `nginx -t` 通过，`ldd sbin/nginx` 含 `libbrotlienc.so.1`、
  `libbrotlicommon.so.1`，`nginx.conf` 第 75-79 行为 brotli 指令，服务 active。
- 对 4KB 以上静态文件带 `Accept-Encoding: br` 请求，响应含 `Content-Encoding: br`。

实机 `bash upgrade.sh nginx`（1.30.4 → 1.30.3 → 1.30.4）：

- PGP 签名验证通过（签名者主密钥 43387825DDB1BB97EC36BA5D007C8D7C15D87369）。
- 升级后 `--add-module` 仍含 lua-nginx-module、ngx_devel_kit、ngx_brotli、
  ngx_cache_purge 四项，`nginx -t` 通过，服务 active，`Content-Encoding: br` 正常。
- 旧二进制保留为 `sbin/nginx.<时间戳>`，无 `Text file busy`。
- 单独对照：服务运行时 `cp -p 备份 sbin/nginx` 报 `Text file busy`，
  同目录写 `sbin/nginx.rollback` 后 `mv -f` 换名成功且服务不受影响。

- **验证状态**：已实测。

## AUDIT-FW-002 inet lnmp 表改由 systemd 单元加载，不再写入 nftables.conf

**位置**：`include/firewall.sh` 的 `Firewall_Save`、`init.d/lnmp-nftables.service`

原实现把规则写入 `/etc/nftables.d/lnmp.nft`，并在 `/etc/nftables.conf` 末尾追加
一行 `include`，该 include 是唯一加载路径。用户自行改写 `/etc/nftables.conf`
（如只保留自己的 `inet filter` 表）后，`systemctl restart nftables` 执行
`flush ruleset` 并按新文件重建规则，`inet lnmp` 表随即消失且不再恢复。

新增 `lnmp-nftables.service`：`After` + `PartOf` `nftables.service`，
`ExecStart` 为 `nft -f /etc/nftables.d/lnmp.nft`，`ExecStop` 删除 `inet lnmp` 表；
`DefaultDependencies=no` 与 `Before=network-pre.target` 使其与 `nftables.service`
同阶段启动；`WantedBy=sysinit.target nftables.service`。
`Firewall_Save` 部署该单元成功后不再改动系统主配置，并清除旧版本追加的
include 行及其注释行（`Firewall_Remove_Include`，删除后经 `nft -c -f` 校验，
覆盖写回以保留原属主与权限）；单元不可用（无 systemd）时退回 include
方式（`Firewall_Add_Include`）。

| 文件 | 改动 |
|---|---|
| `init.d/lnmp-nftables.service` | 新增 |
| `include/firewall.sh` | 新增 `FW_UNIT_NAME`、`FW_UNIT_FILE`、`Firewall_Install_Unit`、`Firewall_Add_Include`、`Firewall_Remove_Include`；`Firewall_Save` 按单元是否可用二选一 |
| `t/consistency.sh` | V11 增加单元文件存在、`PartOf=nftables.service`、`Firewall_Save` 中已调用三项检查 |
| `tests/test_firewall_unit.sh` | 新增 |

**行为变化**：有 systemd 的系统上 `/etc/nftables.conf` 不再被写入，已有的
include 行在下次安装或组件安装时被移除，规则改由 `lnmp-nftables.service` 加载；
规则内容、链策略和端口不变。手工执行 `nft flush ruleset`（不经 systemd）
仍需自行 `nft -f /etc/nftables.d/lnmp.nft`。

**验证**（Debian 13 trixie 测试机，root）：

```bash
bash tests/test_firewall_unit.sh   # 10 项全部通过
bash t/lint.sh                     # 全部通过
bash t/consistency.sh              # 14 项全部通过
```

`tests/test_firewall_unit.sh` 先把 `/etc/nftables.conf` 置为含 include 行的用户
配置，执行 `Firewall_Save` 后确认 include 与注释行被删除、`inet filter` 表内容
保留，`systemctl restart nftables` 两次后 `inet lnmp` 表仍在且无重复链。

对照复现：`systemctl disable --now lnmp-nftables` 并删掉 include 行后
`systemctl restart nftables`，`nft list tables` 只剩 `table inet filter`；
重新 `enable --now` 该单元后同样操作，`table inet lnmp` 仍在。

实机执行 `Add_Iptables_Rules` 后 `/etc/nftables.conf` 无本包内容，
`systemctl reboot`：`lnmp-nftables` 与 `nftables` 均为 active，
`inet lnmp` 表含 22/80/443 accept、ICMP accept 及 3306/33060 drop，
本次启动日志无 ordering cycle。

- **验证状态**：已实测（Debian 13，2026-08-17）。

## AUDIT-FW-004 SSH 放行端口改为自动探测，移除 SSH_Port 配置项

**位置**：`lnmp.conf`、`include/firewall.sh`、`include/end.sh`、`include/main.sh`

放行端口原本取自 `lnmp.conf` 的 `SSH_Port`，`Check_SSH_Port_Policy` 在安装前
比对探测值与配置值，不一致直接返回 1 终止安装，要求用户改配置后重跑。
`Get_Actual_SSH_Port` 本身已能返回系统实际监听的全部 SSH 端口，配置项与
一致性校验都是多余的一步。

`Resolve_SSH_Ports` 探测并过滤出合法端口存入 `SSH_Ports`；`Add_Iptables_Rules`
遍历该数组逐个放行，探测不到就不写 SSH 放行规则（链策略为 accept，不影响
现有连接）。`Check_SSH_Port_Policy` 只保留提示：列出将放行的端口，监听 22 时
提示爆破风险并要求交互确认，非交互执行不追问。

| 文件 | 改动 |
|---|---|
| `lnmp.conf` | 删除 `SSH_Port` |
| `include/firewall.sh` | 新增 `SSH_Ports` 与 `Resolve_SSH_Ports`；`Check_SSH_Port_Policy` 去掉一致性比对与终止分支 |
| `include/end.sh` | `Add_Iptables_Rules` 遍历 `SSH_Ports` 放行 |
| `include/main.sh` | `Validate_Service_Ports` 去掉 `SSH_Port`；`Print_APP_Ver` 打印探测结果；`Confirm_LNMPConf_Reviewed` 文案 |
| `t/consistency.sh` | V8 端口清单与 V10 用例去掉 `SSH_Port` |
| `tests/test_install_confirm.sh` | 改测探测结果驱动的分支，新增 `Resolve_SSH_Ports` 用例 |

**行为变化**：`lnmp.conf` 不再有 `SSH_Port`，防火墙按系统实际监听放行，监听
多个端口时全部放行；端口与配置不一致不再终止安装。监听 22 时的交互确认保留。

**验证**（Debian 13 trixie 测试机，root）：

```bash
bash tests/test_install_confirm.sh   # 全部通过
bash t/lint.sh                       # 全部通过
bash t/consistency.sh                # 14 项全部通过
```

实机改 sshd 监听端口后执行 `Add_Iptables_Rules`：同时监听 22 与 52222 时两个
端口都出现 `accept`；只监听 52222 时规则只有 `tcp dport 52222 accept`，
`Print_APP_Ver` 输出 `SSH 端口（防火墙将放行）：52222`。

- **验证状态**：已实测（Debian 13，2026-08-17）。

## AUDIT-FW-003 卸载不清理防火墙持久化文件与单元

**位置**：`include/firewall.sh` 的 `Firewall_Purge`、`uninstall.sh`

卸载流程只 source `include/firewall.sh`，不移除 `inet lnmp` 表、
`/etc/nftables.d/lnmp.nft`、`lnmp-nftables.service` 及主配置中历史追加的
include 行。卸载后系统仍会随 nftables 加载本包规则。

新增 `Firewall_Purge`：停用并删除单元、`daemon-reload`、删除 `inet lnmp` 表与
规则文件、目录为空时移除、复用 `Firewall_Remove_Include` 清掉主配置里的
include 行。`Uninstall_LNMP`、`Uninstall_LNMPA`、`Uninstall_LAMP` 在
`Remove_Lnmp_Conf_Dir` 之后调用，三处待删清单同步列出这些内容。
firewalld 后端不自动撤销端口放行，只打印 `firewall-cmd` 的撤销命令。

**行为变化**：卸载后 `inet lnmp` 表、规则文件与单元不再残留，用户主配置的
其余内容不受影响。

**验证**（Debian 13 trixie 测试机，root）：`tests/test_firewall_unit.sh` 17 项
全部通过，其中清理部分覆盖：表已删除、规则文件已删除、单元文件已删除且
`is-enabled` 为假、`systemctl restart nftables` 后不再出现 `inet lnmp`、
用户主配置的 `inet filter` 保留、清理后重新执行 `Firewall_Save` 可再次生效。

- **验证状态**：已实测（Debian 13，2026-08-17）。

## CONF-011 移除 SSL 虚拟主机的 dhparam.pem 依赖

**位置**：`conf/lnmp`、`conf/lnmpa` 的 `Create_SSL_Config`，`conf/example/*.conf`

`Create_SSL_Config` 首次添加 SSL 时执行 `openssl dhparam -out ... 2048`，该命令
把素数搜索进度直接打到终端；生成的 `dhparam.pem` 只服务于套件列表末尾的
`DHE-RSA-AES128-GCM-SHA256`、`DHE-RSA-AES256-GCM-SHA384`。

删除生成步骤与 `ssl_dhparam` 指令，并从 `ssl_ciphers` 移除两个 DHE 套件，
只保留 ECDHE 套件（TLS 1.3 仍由 OpenSSL 默认套件控制）。`conf/example/` 下 8 个
Nginx 示例配置同步移除 `ssl_dhparam` 与相关注释。Apache 侧未涉及此文件。

**行为变化**：`lnmp ssl add` 不再生成 `dhparam.pem`，也不再输出 DH 参数生成过程；
TLS 1.2 只协商 ECDHE 套件，不再提供 DHE 回退。已安装环境中已有的
`dhparam.pem` 与已写入的 vhost 配置不受影响。

**验证**（Debian 13 trixie 测试机，root）：

```bash
bash tests/test_ssl_vhost_no_dhparam.sh   # 9 项全部通过
bash t/lint.sh                            # 全部通过
bash t/consistency.sh                     # 14 项全部通过
```

实机对 default 站执行 `lnmp ssl add`（自有证书路径）：输出中无 dhparam 相关内容，
`nginx -t` 通过并 reload 成功，写入的 443 段无 `ssl_dhparam`。握手验证：
TLS 1.3 得到 `TLS_AES_256_GCM_SHA384`，`-tls1_2` 得到
`ECDHE-RSA-AES256-GCM-SHA384`，指定 `-cipher DHE-RSA-AES256-GCM-SHA384` 时
handshake failure。

- **验证状态**：已实测（Debian 13，2026-08-17）。

## CONF-012 默认首页改为中性欢迎页

**位置**：`conf/index.html`（整页重写）、`include/php.sh` 的 `Creat_PHP_Tools`

原 `conf/index.html` 含项目标题、`author` / `keywords` / `description` 元信息、
`lnmp.gif` 徽标、组件功能介绍与署名，部署到站点根目录后可被外部识别出所用环境。

改为无标识欢迎页：仅保留 `Welcome` 标题与一句中英文说明，无图片、无站外链接、
无组件与配置信息，附 `noindex, nofollow`；内联 CSS，响应式并适配深浅色。
`Creat_PHP_Tools` 中 `\cp conf/lnmp.gif` 一行删除（页面已不引用），
`conf/index.html` 的部署行不变。`include/only.sh`（单独安装 Nginx）复制同一文件。

**行为变化**：新安装的默认首页不再包含项目标识，站点根目录不再出现 `lnmp.gif`。
已安装环境需重装对应组件或手工替换才会更新，旧 `lnmp.gif` 需自行删除。

**验证**（Debian 13 trixie 测试机，root）：

```bash
bash t/lint.sh          # 全部通过
bash t/consistency.sh   # 14 项全部通过
```

实机按 `Creat_PHP_Tools` 中的部署语句复制后经 nginx 访问：`HTTP/1.1 200`、
`Content-Length: 1525`；正文对 `lnmp|vpser|licess|一键安装|phpinfo|phpmyadmin`
及 `http(s)://` 均无匹配，无任何 `src=` / `href=` 外部资源引用；
`/lnmp.gif` 返回 404；重复执行复制语句返回码为 0，结果一致。

- **验证状态**：已实测（Debian 13，2026-08-17）。

## DOC-703 README 顶部引用 conf/lnmp.gif

**位置**：`README.md`（"每一处改动都逐条记录在随包的 `changelog.md`" 一句下方）

`conf/lnmp.gif`（GIF89a，400×50，5683 字节）在 `CONF-012` 后不再部署到站点根目录，
文件仍随包保留。在 README 顶部以相对路径引用，供仓库页面展示。

**行为变化**：仅文档展示变化，安装流程与部署文件不变，默认首页仍不含该图。

**验证**：`conf/lnmp.gif` 存在且路径相对仓库根有效；`README.md` 无其它图片引用，
未引入站外资源。

- **验证状态**：已验证（静态）。

## FIX-INSTALL-003 默认站点缺少 favicon.ico 导致错误日志反复记录 404

**位置**：`conf/favicon.ico`（新增）、`include/php.sh`（`Creat_PHP_Tools`）、
`include/only.sh`（`Install_Only_Nginx`）

安装只往 `${Default_Website_Dir}` 写入 `index.html`，浏览器自动请求 `/favicon.ico`
时命中不存在的路径，`/home/wwwlogs/default.error.log` 每次访问都记录一条
`open() "/home/wwwroot/default/favicon.ico" failed (2: No such file or directory)`。

随包新增 `conf/favicon.ico`（16×16 ICO 占位图标，可直接替换为自有图标，
路径与文件名不变，部署流程不受影响），并在两个部署 `index.html` 的位置之后各加一行
复制语句：`Creat_PHP_Tools` 覆盖 lnmp、lnmpa、lamp 三栈完整安装（含 OpenResty，
`install.sh` 的 `LNMP_Stack`、`LNMPA_Stack`、`LAMP_Stack` 均调用），
`Install_Only_Nginx` 覆盖独立安装 Nginx。favicon 非关键资源，复制失败时经
`Echo_Red` 明确降级提示，不改变函数返回码、不中断安装。权限沿用 `\cp` 结果
（root:root 644），Nginx 与 Apache 的 www worker 可读。

**行为变化**：新安装的默认站点根目录多一个 `favicon.ico`，`/favicon.ico` 返回 200，
默认站点错误日志不再出现该条 404。已安装环境需重装对应组件或手工复制该文件。
虚拟主机模板、静态缓存规则和管理命令均未改动。

**验证**（Debian 13 trixie 测试机，root）：

```bash
bash t/lint.sh                        # 全部通过
bash tests/test_default_favicon.sh    # 10 项全部通过
```

`tests/test_default_favicon.sh` 断言两个入口的函数体在 `index.html` 之后部署
`favicon.ico`，并执行源码中的复制语句：目标文件与源文件逐字节一致、返回码 0、
无多余提示；源文件缺失时返回码仍为 0 并输出降级提示。反向验证——移除
`Creat_PHP_Tools` 中的复制语句后该脚本报 FAIL。

实机按部署语句复制后经 nginx 访问 `/favicon.ico`：改动前 `HTTP/1.1 404` 且
`default.error.log` 新增一条 `open() ... failed`；改动后 `HTTP/1.1 200`、
`Content-Type: image/x-icon`、`Content-Length` 与占位文件大小一致（1150），
响应体与源文件逐字节一致，错误日志行数不变。

- **验证状态**：已实测（Debian 13，2026-08-17）。

## FIX-SSL-001 DNS 验证签发缺少 API 凭据交互与证书安装步骤

**位置**：`conf/lnmp`、`conf/lnmpa`、`conf/lamp`（`Add_Dns_SSL`、`Add_Dns_SSL_Only`、
`Add_SSL_Only_Info_Menu`、`Add_DNS_SSL_Only_Info_Menu`、`Function_Vhost` 的 SSL 提示）

`lnmp dnsssl` 与 `lnmp onlyssl` 存在四个问题：

1. **不索取 DNS 服务商 API 凭据**。签发命令直接调用 `acme.sh --dns dns_<服务商>`，
   凭据须由使用者事先 `export`，未设置时签发在 acme.sh 内部失败。
2. **缺少 `--install-cert`**。acme.sh 默认密钥类型为 EC-256，证书落在
   `<certhome>/<域名>_ecc/`，而两个函数按 `<certhome>/<域名>/fullchain.cer`
   判断结果并写入服务配置。HTTP 验证路径 `Add_SSL` 有该步骤，DNS 路径没有，
   结果是签发成功也会写出指向不存在文件的 443 配置。
3. **`dnsssl` 重复整套建站问答**。该函数调用 `Add_SSL_Info_Menu`，逐项询问网站目录、
   伪静态、访问日志、PHP、Pathinfo、IPv6，与 `lnmp vhost add` 重复，并在站点不存在时
   自行 `Add_VHost_Config` 建站。
4. **提示不区分验证方式**。`lnmp ssl add`、`lnmp dnsssl`、`lnmp onlyssl` 与
   `lnmp vhost add` 的证书提示文案相同，无法判断走 HTTP-01 还是 DNS-01。

改动：

- 新增 `Parse_DNS_API_Options` / `Prompt_DNS_API_Credentials`：从 acme.sh 插件头部的
  `dns_<服务商>_info` 元数据读取 `Options:` 与 `OptionsAlt:` 段，按声明逐项提示输入并
  `export`，变量名和说明来自插件本身，新增服务商无需改脚本。标注 `Optional.` 的可留空；
  存在两套凭据时（如 Cloudflare 的 `CF_Key`+`CF_Email` 与 `CF_Token`+`CF_Account_ID`）
  先选组；`account.conf` 中已有 `SAVED_<变量>` 时提示回车沿用，此时不导出，由 acme.sh
  读取自身保存值；元数据解析不到时降级为提示自行 `export`，不阻断流程。
  不带服务商参数的手工 TXT 模式不提示。
- 两个 DNS 函数在签发成功后执行 `--install-cert -d <主域名> --ecc`，
  与 `Add_SSL` 一致地把证书安装到 `<certhome>/<域名>/`。`onlyssl` 不写站点配置，
  该步骤不带 `--reloadcmd`。
- 拆出 `Load_Vhost_Params`（原 `Add_SSL_Only_Info_Menu` 的站点参数读取部分），
  `ssl add` 与 `dnsssl` 共用。新增 `Add_DNS_SSL_Site_Info_Menu`：`dnsssl` 只对已存在的
  站点签发，按**根域名**定位站点（`Get_Domain_Base` + `Find_Site_For_SSL`，先比对站点名，
  再比对配置内的 `server_name`/`ServerName`+`ServerAlias`，最后比对根域）。
  同根域唯一站点时直接采用并说明；同根域有多个站点时要求输入准确域名；一个都没有时提示
  先 `lnmp vhost add`，或改用 `lnmp onlyssl`。`dnsssl` 不再创建虚拟主机。
- 泛域名不需要单独建站：输入 `*.example.com` 按根域匹配到 `example.com`，
  泛域名并入证书域名列表。新增 `Filter_Cert_Domains` 去重并剔除已被泛域名覆盖的
  同级子域名（主域名始终保留，acme.sh 按第一个 `-d` 决定证书目录），
  替换原先「泛域名不能同时添加 www 子域名」的直接中止。
- 证书目录名对泛域名做转换（`*.` → `_wildcard.`），删除已有证书改为引号包裹的定路径，
  不再出现通配符参与的 `rm -rf`。
- 证书域名改用数组传给 acme.sh，拆分期间 `set -f`，泛域名的 `*` 不再参与路径展开。
- `dnsssl` 的附加域名做范围校验：与站点根域不同、且不在站点现有域名中的，
  列出后要求确认（`y/N`，默认 n，拒绝则重新输入）。这些域名既要 DNS 服务商能管理解析，
  又会被写入该站点的 HTTPS 配置，输错时签发必然失败。`onlyssl` 不写站点配置，
  跨根域是合法用法，只打印提示不拦截。
- 信息类提示补换行：`Echo_Yellow` 是 `echo -n`（供提示符使用），
  新增的多行提示原先会挤在一行并紧贴 shell 提示符。
- `lnmp ssl add` 同步三处：输入泛域名时明确拒绝并指向 `lnmp dnsssl`
  （HTTP-01 不能签发泛域名，原先会以「未找到网站 `*.example.com`」这种误导性提示退出）；
  站点定位改用 `Find_Site_For_SSL`，输入 `www.example.com` 能命中 `server_name`
  含该域名的站点 `example.com`，但**不做 dnsssl 那样的根域回退**——HTTP 验证要求该域名
  由现有网站直接服务，同根域的其它子域会被要求输入准确域名；站点不存在时补上
  `lnmp onlyssl` 这条出路。证书来源菜单上方增加一行 HTTP 验证前提说明
  （`default` 站点显示 IP 版本的措辞）。
- 提示文案：`ssl add` 为「HTTP 验证，请输入域名」，`dnsssl`/`onlyssl` 为
  「DNS 验证，请输入域名」，证书来源菜单各项标注验证方式，`vhost add` 的证书提示
  标注「HTTP 验证，需 80 端口可从公网访问」。
- `dnsssl`/`onlyssl` 输入 `default` 时明确拒绝：DNS-01 无法为 IP 地址签发，
  提示改用 `lnmp ssl add`。
- 用法与文档中的 `cx`（CloudXNS）移除：acme.sh 3.1.4 已删除 `dnsapi/dns_cx.sh`，
  传入该值只会得到「未找到 DNS 服务商插件」。用法补一行说明服务商参数取 acme.sh
  插件名（如 `nsone`）。

**行为变化**：`lnmp dnsssl` 不再询问建站参数、不再创建虚拟主机，站点不存在直接退出；
两个 DNS 命令会索取 API 凭据；签发成功后证书安装到 `<certhome>/<域名>/`；
泛域名与其覆盖的子域名同时出现时只申请泛域名（不再中止）。
`lnmp ssl add` 与 HTTP 验证流程的逻辑未改动，只改提示文案。

**验证**：

```bash
bash t/lint.sh                          # 全部通过
bash t/consistency.sh                   # 14 项通过
bash tests/test_dns_ssl_helpers.sh      # 70 项全部通过
```

`tests/test_dns_ssl_helpers.sh` 从 `conf/lnmp` 与 `conf/lamp` 抽取被测函数运行，
覆盖：插件元数据解析（单变量、双变量、两组凭据、可选项、插件缺失）；凭据交互
（提示含变量名与说明、必填留空重试、已保存回车沿用、选组后不索取另一组变量、
手工模式不提示、无元数据降级）；根域判定（二级域、三级域、四级域、泛域名、
`com.cn`/`co.uk` 二级后缀）；站点匹配（站点名命中、`server_name` 命中、
Apache `ServerAlias` 命中、子域按根域给候选、无关域无候选、目录不存在）；
证书域名过滤（泛域名覆盖子域、主域名不被剔除、去重、多级子域不被覆盖）；
域名菜单（子域按根域继续、无站点返回 1 并给出两条出路、拒绝 `default`、
泛域名并入证书域名、多站点要求准确域名）；`ssl add` 域名菜单（站点名命中、
`server_name` 命中并说明匹配到的站点、泛域名指向 `dnsssl`、子域不做根域回退、
无站点给出两条出路、`default` 直接放行）；附加域名范围校验（同根域、泛域名与子域、
站点现有域名均直接通过，跨根域默认拒绝并只列出越界的那个，确认 `y` 可继续，
`onlyssl` 同根域不提示、跨根域提示）。

Debian 13 测试机（LNMP，nginx 1.30.4）以桩 `acme.sh` 执行 `lnmp dnsssl nsone` 与
`lnmp onlyssl nsone`，不访问真实 CA：无站点域名与 `default` 均返回 1 并打印对应提示；
子域 `sub.node.test` 匹配到站点 `node.test` 并继续；`NS1_Key` 经交互输入后在
`acme.sh --dns dns_nsone` 调用中可见；桩返回成功时执行
`--install-cert -d node.test --ecc --key-file .../node.test.key --fullchain-file .../fullchain.cer`，
证书文件落到 `/usr/local/nginx/conf/ssl/node.test/`，追加的 443 配置指向该两个文件，
`server_name node.test www.node.test *.node.test`，`nginx -t` 通过，301 跳转按选择写入。
输入 `*.node.test` 时匹配到 `node.test` 站点，证书域名为 `node.test *.node.test`，
未要求存在带 `*` 的虚拟主机。

`lnmp ssl add` 用一次性站点与自有证书验证（不接触任何 CA）：站点不存在、重复添加、
泛域名三种情况均返回 1 并打印对应提示；输入 `www.ssltest.local` 命中站点
`ssltest.local` 并说明匹配关系；完整流程写入 443 配置后 `nginx -t` 通过；
证书路径输错时重新询问，配置测试未通过时回滚新增的虚拟主机配置。

- **验证状态**：已实测（Debian 13，2026-08-17）。真实 CA 签发与 DNS 服务商 API 调用
  受测试机 NAT 环境限制未验证；`conf/lnmpa`、`conf/lamp` 的同源改动只做静态检查。
