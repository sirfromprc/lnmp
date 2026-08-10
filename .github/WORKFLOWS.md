# GitHub Actions 说明

五个工作流，分工如下。全部可以在仓库页面的 **Actions** 标签页里手动触发
（选中左侧的工作流 → 右上角 **Run workflow**），不需要命令行 ——
用 GitHub Desktop 只管推代码，其余在网页上点。

| 工作流 | 何时跑 | 干什么 | 失败了会怎样 |
| --- | --- | --- | --- |
| `CI` | 每次 push / PR | 语法、ShellCheck、不变式、跨文件一致性、映射与升版自测 | PR 变红，几十秒出结果 |
| `Build Test` | 被其它工作流调用，也可手动 | **真编译真启动**，容器用 debian:12 | 调用它的工作流一并失败 |
| `上游版本检查` | 每月 8 号 03:00（北京时间），也可手动 | 查上游新版本 → 自动升 → 重算校验值 → 真编译 → 开 PR | 不开 PR，失败原因写进 Actions 摘要 |
| `下载源存活探测` | 每周二 03:00（北京时间），也可手动 | 探测所有下载 URL 是否还在 | 自动开 issue（同一个 issue 追加评论，不刷屏） |
| `发布` | 手动，或推 `v2.3-*` tag | 静态检查 → 真编译 → 打包 → 构建证明 → 发 Release | **不发布** |

---

## 关于版本号

产品版本固定是 **v2.3**，不随发布次数递增。

但 git tag 必须唯一 —— 同一个 tag 反复移动，会让已经下载过的人再次校验时
对不上（同名 tag、不同内容，是供应链上最难排查的一类问题）。所以：

```
tag        v2.3-20260908
Release 名 LNMP v2.3 (2026-09-08)
包名       lnmp-v2.3-20260908.tar.gz
```

日期只是「这一次发布」的标识，产品版本始终是 v2.3。

---

## 自动升级：哪些自动、哪些不自动

`t/check_upstream.sh` 把每个组件分成四类，**默认只自动应用 AUTO**。

**AUTO** —— 同分支内的点版本，无跨组件耦合。nginx（stable 分支内）、
OpenSSL（3.5 LTS 内）、PHP 各分支、MySQL 8.0/8.4、MariaDB 三个 LTS、
Apache 2.4、phpMyAdmin、Redis、Memcached、pure-ftpd、PECL 扩展等。

**COUPLED** —— Lua 全家桶。必须成组升，理由见下一节。
默认不自动应用，手动触发时可以在下拉框里选 `AUTO,COUPLED`。

**MANUAL** —— 只报告不动手。换 nginx stable 分支、OpenResty 大版本
（它自带的 nginx 会跟着变，且只有 PGP 签名没有 sha256）等。

**PINNED** —— 连查都不查，理由写在 `include/version.sh` 各自的注释里。
比如 `Pcre_Ver` 锁在 8.45（PCRE1 最终版）、`NgxBrotli_Commit` 锁在具体
commit（上游只有一个 2021 年的 rc tag，跟 master 会让 sha256 天天漂）。

---

## 为什么 Lua 全家桶不能各升各的

`lua-resty-core` 的 `lib/resty/core/base.lua` 里有一段硬断言：

```lua
or ngx.config.ngx_lua_version ~= 10031
...
error("ngx_http_lua_module 0.10.31 required but got " .. ver)
```

`10031` 是 `lua-nginx-module` 版本的编码：`major*1000000 + minor*1000 + patch`，
即 0.10.31。两者版本不匹配就必然报错。

麻烦的是**它在 Lua 运行时才触发**：

```
./configure  通过
make         通过
nginx -t     通过      ← 不加载 Lua 代码就不触发
nginx 启动   通过
第一次访问带 Lua 的 location  → 500
```

前面每一道都给绿灯。所以：

1. `t/check_upstream.sh` 先定 `lua-nginx-module` 的目标版本，
   再去 `lua-resty-core` 的历史 tag 里逐个拉 `base.lua`，
   找出**声明需要这个版本**的那一个，两个凑齐才提建议。
   凑不齐（新模块发布了但配套的 resty-core 还没出）就整组不动。
2. `lua-resty-core` 经常先出 rc —— 当前包里用的就是 `0.1.34rc3`。
   新模块发布后配套的往往只有 rc，这时用 rc 是对的，
   退回上一个正式版反而会因断言不匹配而起不来。
3. `t/build_test.sh lua` 最后一步是**真发一次请求**，
   curl 一个 `content_by_lua` 的 location 并比对响应体。少这一步拦不住。

---

## 发布前的编译验证

`Build Test` 有两档：

- `quick`（默认）：只验 Lua 全家桶。约 6–10 分钟。升级 PR 走这一档。
- `full`：再加 nginx 全模块（含自建 OpenSSL 3.5、ngx_brotli 系统库软链）
  和 PHP 默认分支编译。约 40–90 分钟。**正式发布强制走这一档**。

容器用 `debian:12`，与本项目的目标发行版一致 ——
在 ubuntu-latest 上编得过不代表在 Debian 12 上编得过。

---

## 签名

默认用 GitHub 原生的**构建证明**（build provenance attestation），
不需要管理任何密钥。使用者这样验：

```bash
sha256sum -c SHA256SUMS
gh attestation verify lnmp-v2.3-YYYYMMDD.tar.gz --repo <owner>/<repo>
```

如果想额外提供 GPG 分离签名，在仓库
**Settings → Secrets and variables → Actions** 里加两个 secret：

- `GPG_PRIVATE_KEY`：`gpg --armor --export-secret-keys <KEYID>` 的完整输出
- `GPG_PASSPHRASE`：该私钥的口令

配了才走，没配自动跳过，不影响发布。

---

## 首次启用要做的三件事

1. **仓库 Settings → Actions → General → Workflow permissions**
   选 **Read and write permissions**，并勾选
   **Allow GitHub Actions to create and approve pull requests** ——
   否则「上游版本检查」开不了 PR。
2. 建两个 label：`dependencies`、`url-health`（工作流会用到，
   不存在时打标签会失败）。
3. 手动跑一次 `CI` 和 `上游版本检查`（勾上 *只看报告，不开 PR*）确认环境正常。

---

## 本地也能跑

所有逻辑都在 `t/` 下的脚本里，工作流只是薄薄一层调用。
在 Linux 机器上可以直接跑：

```bash
bash t/consistency.sh          # 跨文件一致性（离线，秒级）
bash t/check_upstream.sh       # 查上游（联网，只读，不改文件）
bash t/bump_version.sh --dry-run
bash t/test_bump.sh            # 升版跨文件同步自测（离线，秒级）
bash t/build_test.sh lua       # 真编译，需 root
```
