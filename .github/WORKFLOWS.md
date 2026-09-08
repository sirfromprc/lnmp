# GitHub Actions 使用说明

仓库目前有六个工作流。除自动触发外，都可以在仓库的 **Actions** 页面手动运行：
选择左侧工作流，点击右上角 **Run workflow**。

| 工作流 | 自动触发 | 用途 | 失败结果 |
| --- | --- | --- | --- |
| `CI` | push、PR | Bash 语法、ShellCheck、lint、一致性和定向自测 | 当前提交或 PR 检查失败 |
| `Build Test` | 由其它工作流调用 | 在 Debian 12 容器内编译并启动验证 | 调用方中止 |
| `上游版本检查` | 每月 8 日 03:00（北京时间） | 检查版本、更新校验值、full 编译、推升级分支并发布 | 不推分支也不发布，详情写入 Actions 摘要 |
| `同步组件版本到主分支` | 无，手动触发 | 把升级分支的组件版本并入主分支 | 不提交 |
| `下载源存活探测` | 每周二 03:00（北京时间） | 检查当前版本的下载地址 | 创建或更新 `url-health` issue |
| `发布` | 推送版本 tag、被上游版本检查调用 | 检查、编译，打两个包并发布 Release | 不发布 |

## 两条版本线

组件版本有两条线，互不覆盖：

- **主分支**（按产品版本命名，如 `v2.3`）的组件版本由维护者手工确认，
  自动升级不会改动它。在主分支上改源码不会覆盖已经升级过的版本号。
- **`auto-<日期>` 分支**由上游版本检查每月重建，等于「主分支最新源码 + 最新组件版本」。
  它不合并回主分支，只保留日期最新的一个。

发布时两条线各出一个包，放在同一个 Release 里。需要让主分支也用上新组件版本时，
手动触发 `同步组件版本到主分支`。

## CI

`CI` 通常几十秒完成，依次运行：

```text
bash -n
t/shellcheck.sh
t/lint.sh
t/consistency.sh
t/test_profile.sh
t/test_dispatch.sh
t/test_bump.sh
t/test_upstream.sh
```

CI 同时检查单个脚本，以及版本号、配置映射和下载清单之间的一致性。

ShellCheck 的检查范围与排除规则只写在 `t/shellcheck.sh` 一处，工作流不再自带一份
参数；`t/lint.sh` 的 T2 调用的是同一个脚本。本机未装 shellcheck 时该脚本跳过并
返回 0，CI 里先装再调用。

## 上游版本检查

工作流文件是 `.github/workflows/upstream-check.yml`，执行顺序如下：

```text
t/check_upstream.sh
  -> t/bump_version.sh
  -> t/refresh_checksums.sh
  -> t/consistency.sh
  -> t/probe_urls.sh
  -> Build Test (full)
  -> 推送 auto-<日期> 分支
  -> 发布（调用 release.yml）
  -> t/cleanup_branches.sh
```

任一步失败都会停止，未验证的改动不会推上分支，也不会发布。手动运行时有两个选项：

- `kinds`：默认 `AUTO`；需要检查 Lua 配套升级时选 `AUTO,COUPLED`。
- `dry_run`：启用后只生成报告，不推分支、不发布，编译验证降为 quick。

升级结果会自动发布，所以这里的编译验证跑 full 而不是 quick：升级包里的组件版本
必须经过 nginx 全模块与 PHP 的真编译，不能只验 Lua 全家桶。`dry_run` 不发布，
用 quick 省时间。

**每月 8 日会自动产生一个 Release**（有 AUTO 类更新时）。没有 AUTO 类更新时
`push` 与 `release` 都跳过，不会产生空 Release。

整条链有两次编译，验证的是两个不同的包：

| 位置 | 编译内容 | 深度 | 对应包 |
| --- | --- | --- | --- |
| 上游版本检查的 Build Test | 主分支源码 + 新组件版本 | `full` | 带日期的升级包 |
| 发布工作流内部的 Build Test | 主分支源码 + 旧组件版本 | `quick` | 不带日期的主分支包 |

第二次只做 Lua 冒烟：主分支的组件版本上次发布已经过 full，源码又与升级分支同一份，
再跑一遍 nginx 与 PHP 的完整编译约多花 90 分钟而新信息很少。手动触发发布工作流时
仍固定 full，因为那条路径没有前置的 full 验证。

分支每轮从触发时的主分支重建，只提交版本与校验相关的 6 个文件，因此它同时含有
最新源码和最新组件版本。同一天重跑会覆盖当天的分支。

升级分支不合并，也就没有天然的回收时机，所以每轮跑完由 `t/cleanup_branches.sh`
删除其余的 `auto-<日期>` 分支，只留最新一个。该脚本只认 8 位日期结尾的分支名，
手工建的同前缀分支（如 `auto-manual-fix`）不受影响。`DRY_RUN=1` 可先看要删哪些。

`t/bump_version.sh` 生成的 `.upstream/changed.tsv` 每行记录组件键、旧值和新值，
`t/refresh_checksums.sh` 据此只重算该组件的校验条目。

组件分为四类：

| 类别 | 处理方式 |
| --- | --- |
| `AUTO` | 同一稳定分支内的常规点版本更新，默认自动应用 |
| `COUPLED` | 有配套关系的 Lua 组件，只在手动选择后应用 |
| `MANUAL` | 只报告，例如切换 nginx stable 分支或 OpenResty 大版本 |
| `PINNED` | 固定版本，不检查更新；固定原因列在检查报告的 PINNED 表中 |

Lua 组件不能拆开升级。`lua-resty-core` 会在运行时核对
`lua-nginx-module` 版本，因此 quick 构建除了编译和启动，还会访问一个 Lua location
并检查响应。

## 下载源存活探测

`url-health.yml` 每周检查当前配置中的下载地址。它与上游版本检查的区别是：

- 上游版本检查关注有没有新版本；
- 下载源存活探测关注当前版本是否仍能下载。

MySQL 探测与安装器使用相同顺序：先查 `Downloads`，再查 `archives`。两处都不可用
才算失败。失败时工作流会查找现有的 `url-health` issue；有则追加评论，没有则新建，
避免每周生成重复 issue。

## Build Test

`Build Test` 使用 `debian:12` 容器，有两档：

| 级别 | 内容 | 使用位置 |
| --- | --- | --- |
| `quick` | Lua 组件编译、启动和请求验证 | 上游版本检查的 `dry_run`、手动检查 |
| `full` | quick 加 nginx 全模块和 PHP 默认分支编译 | 升级分支验证、发布前检查 |

上游升级尚未提交时，`upstream-check.yml` 会把修改后的文件作为 artifact 传给
`Build Test`，确保编译的是待推送内容。

## 同步组件版本到主分支

`sync-versions.yml` 只能手动触发，把升级分支上的 6 个版本相关文件取到主分支：

```text
include/version.sh   include/profile.sh   src/checksums.sha256
t/probe_urls.sh      t/gen_checksums.sh   t/test_profile.sh
```

取完先跑 `t/consistency.sh`、`t/test_profile.sh` 和 `t/probe_urls.sh`，
全部通过才提交到主分支。版本号进主分支后安装流程就会照它下载，所以这里必须确认
下载地址仍然可达。

两个选项：

- `branch`：留空取日期最新的升级分支，也可指定某一个 `auto-<日期>`。
- `dry_run`：只看 diff 和回检结果，不提交。

主分支若开启了分支保护，推送会被拒绝，这时需要在本地手工合并。

## 发布

产品版本取自 `install.sh` 的 `LNMP_Ver`，由 `t/product_version.sh` 提取，
工作流内不写死；分支叫什么名字不参与取值。升到 2.4 时只改 `install.sh`
和 `uninstall.sh` 两处，工作流、tag 和包名都会跟着变。

一次发布产出两个包，同属一个 Release。三种触发方式（手动、tag、每月自动）
产出结构完全相同，走的是同一段代码：

```text
tag         v2.3-20260908                每次发布唯一
Release     LNMP v2.3 (20260908)
压缩包      lnmp-v2.3.tar.gz             主分支，不含自动升级
            lnmp-v2.3-20260908.tar.gz    最新升级分支，含自动升级
```

两个包的脚本源码相同，差别只在组件版本号。没有 `auto-<日期>` 分支时只发前一个。

包名和 tag 里的日期是**发布当天**，不是升级分支的日期。每月自动发布时两者是同一天；
手动发布一个更早的升级分支时，两者会不同，发布说明里会写明包来自哪个分支。

不要移动或重复使用已有 tag。同名 tag 指向不同内容后，已经下载的文件将无法稳定校验。
需要固定下载地址时用 GitHub 的 latest 转发，不要动 tag：

```text
https://github.com/<owner>/<repo>/releases/latest/download/lnmp-v2.3.tar.gz
```

发布工作流有三种触发方式：

| 触发 | 主分支包构建深度 | prerelease |
| --- | --- | --- |
| 推送版本 tag | 固定 full | 否 |
| 网页手动运行 | 默认 full，可选 quick | 可选 |
| 被上游版本检查调用（每月自动） | quick，见上一节 | 否 |

这里的深度只作用于主分支包。升级包的编译验证在上游版本检查里完成，固定 full，
发布说明会按包分别写明各自过了哪些验证。

tag 触发时会核对 tag 前缀与源码里的产品版本，不符即中止。检查全部通过后才会：

1. 打包两个发布文件（`t/pack.sh`，排除规则只写在这一处）；
2. 生成 `SHA256SUMS`，覆盖两个包；
3. 生成 GitHub build provenance attestation；
4. 生成发布说明（`t/release_notes.sh`），说明里写清楚哪个包不含自动升级；
5. 创建 Release。

升级分支的真编译在上游版本检查里已经做过，发布时不重复跑，只回检跨文件一致性
和编号映射，防止分支推出后主分支又改了映射导致两边对不上。

使用者可这样校验：

```bash
sha256sum -c SHA256SUMS
gh attestation verify lnmp-v2.3.tar.gz --repo <owner>/<repo>
gh attestation verify lnmp-v2.3-YYYYMMDD.tar.gz --repo <owner>/<repo>
```

GPG 分离签名是可选项。仓库配置了 `GPG_PRIVATE_KEY` 和 `GPG_PASSPHRASE` 后，
发布工作流会额外生成 `.asc`；未配置时跳过，不影响构建证明和发布。

## 维护版本号

数据库、PHP、Apache 和 phpMyAdmin 的菜单版本在 `include/profile.sh`，其它大部分版本
在 `include/version.sh`。相关列表还会出现在：

- `t/probe_urls.sh`
- `t/gen_checksums.sh`
- `t/test_profile.sh`
- `src/checksums.sha256`

修改版本时应同步这些位置，并运行一致性检查。`Boost_Ver`、`Boost_New_Ver` 是下载探测
和校验清单使用的版本；MySQL 安装所需的 Boost 仍从源码树的 `cmake/boost.cmake`
动态读取，两者不要混用。

`t/refresh_checksums.sh` 只更新当前升版涉及的条目。不要用全量生成脚本替代日常增量
更新，否则会下载所有数据库二进制包，并改动无关组件的校验值。

## 仓库设置

首次启用前确认：

1. **Settings -> Actions -> General -> Workflow permissions** 设为
   **Read and write permissions**。工作流需要推送 `auto-<日期>` 分支和删除旧分支。
2. 创建 `url-health` 和 `bug` 标签。自动升级不再开 PR，`dependencies`、`automated`
   两个标签已不再使用。
3. 主分支若开启保护规则，`同步组件版本到主分支` 的推送会被拒绝，
   需要为 `github-actions[bot]` 放行，或改在本地手工合并。
4. 手动运行一次 `CI`；再以 `dry_run` 方式运行一次 `上游版本检查`。

## 本地检查

以下命令在 Linux 环境运行：

```bash
bash -n include/version.sh t/probe_urls.sh t/gen_checksums.sh
bash t/lint.sh
bash t/consistency.sh
bash t/test_profile.sh
bash t/test_bump.sh
bash t/test_upstream.sh
LIST_ONLY=1 bash t/gen_checksums.sh
bash t/product_version.sh          # 产品版本，两处不一致时报错
```

打包和发布说明可以脱离 Actions 单独跑，用于确认包内容和说明措辞：

```bash
bash t/pack.sh . lnmp-v2.3 /tmp/dist
tar -tzf /tmp/dist/lnmp-v2.3.tar.gz | head

PRODUCT=v2.3 STAMP=20260908 REPO=<owner>/<repo> LEVEL=full \
BASE_DIR=. BASE_PKG=lnmp-v2.3 bash t/release_notes.sh
```

分支清理可以先看不删：

```bash
GITHUB_REPOSITORY=<owner>/<repo> DRY_RUN=1 bash t/cleanup_branches.sh
```

联网检查和编译验证：

```bash
bash t/check_upstream.sh
bash t/probe_urls.sh
bash t/build_test.sh lua
```
