# GitHub Actions 使用说明

仓库目前有五个工作流。除自动触发外，都可以在仓库的 **Actions** 页面手动运行：
选择左侧工作流，点击右上角 **Run workflow**。

| 工作流 | 自动触发 | 用途 | 失败结果 |
| --- | --- | --- | --- |
| `CI` | push、PR | Bash 语法、ShellCheck、lint、一致性和定向自测 | 当前提交或 PR 检查失败 |
| `Build Test` | 由其它工作流调用 | 在 Debian 12 容器内编译并启动验证 | 调用方中止 |
| `上游版本检查` | 每月 8 日 03:00（北京时间） | 检查版本、更新校验值、编译并创建 PR | 不创建 PR，详情写入 Actions 摘要 |
| `下载源存活探测` | 每周二 03:00（北京时间） | 检查当前版本的下载地址 | 创建或更新 `url-health` issue |
| `发布` | 推送 `v2.3-*` tag | 检查、编译、打包并发布 Release | 不发布 |

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
  -> Build Test (quick)
  -> 创建 PR
```

任一步失败都会停止，未验证的改动不会进入 PR。手动运行时有两个选项：

- `kinds`：默认 `AUTO`；需要检查 Lua 配套升级时选 `AUTO,COUPLED`。
- `dry_run`：启用后只生成报告，不创建 PR。

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
| `quick` | Lua 组件编译、启动和请求验证 | 上游版本 PR、手动检查 |
| `full` | quick 加 nginx 全模块和 PHP 默认分支编译 | 发布前检查 |

上游升级尚未提交时，`upstream-check.yml` 会把修改后的文件作为 artifact 传给
`Build Test`，确保编译的是待提交内容。

## 发布

产品版本固定为 `v2.3`，每次发布用日期区分：

```text
tag         v2.3-20260908
Release     LNMP v2.3 (20260908)
压缩包      lnmp-v2.3-20260908.tar.gz
```

不要移动或重复使用已有 tag。同名 tag 指向不同内容后，已经下载的文件将无法稳定校验。

推送 `v2.3-*` tag 时，发布工作流固定执行 full 构建。网页手动运行默认也是 full，
可选择 quick 和是否标记为 prerelease。检查全部通过后才会：

1. 打包发布文件；
2. 生成 `SHA256SUMS`；
3. 生成 GitHub build provenance attestation；
4. 创建 Release。

使用者可这样校验：

```bash
sha256sum -c SHA256SUMS
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
   **Read and write permissions**，并允许 Actions 创建和批准 PR。
2. 创建 `dependencies`、`automated`、`url-health` 和 `bug` 标签。
3. 手动运行一次 `CI`；再以 `dry_run` 方式运行一次 `上游版本检查`。

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
```

联网检查和编译验证：

```bash
bash t/check_upstream.sh
bash t/probe_urls.sh
bash t/build_test.sh lua
```
