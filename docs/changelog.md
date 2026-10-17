# LNMP V3 变更摘要

归总修改及验证结论。

## 3.0.3

### 新增功能

- Node.js 运行时：`addons.sh install|uninstall nodejs [22|24]`（菜单 14），官方二进制按主版本装到 `/usr/local/nodejs/<主版本>/`，下载经静态清单与上游签名双重校验；有应用引用时拒绝卸载。
- PM2：`addons.sh install|uninstall pm2 [主版本]`（菜单 15）；`lnmp app add` 识别 `pm2-runtime` 启动命令并为应用建立独立 `PM2_HOME`，新增 `lnmp app reload <应用名>`。PM2 取 npm 最新版，不固定版本。
- 单站点启停：`lnmp vhost start|stop <域名>`，停用后除 ACME 验证路径外返回 503，`lnmp vhost list` 标注 `[已停用]`。
- 请求验收：安装收尾与 `lnmp vhost add` 经本机 80 端口实际请求站点，核对 PHP 执行与版本；反代站点区分上游未启动与超时。
- 建站类型与预设：`lnmp vhost add` 先选 PHP、静态、反代，PHP 站点可选 WordPress、Laravel 预设；非交互变量 `VHOST_TYPE`、`VHOST_PRESET`。
- PHP 默认扩展 zstd（开关 `Enable_PHP_Default_Zstd`，默认 `y`）；phpredis 支持 zstd 压缩。
- Nginx HTTPS 站点默认启用 HTTP/3，安装期防火墙放行 UDP 443；OpenResty 源码编译按 OpenSSL 版本启用 http_v3。
- 异地备份一键配置与备份机守护：生产机 `lnmp backup remote-setup` 生成专用密钥、核对备份机指纹、试连试写通过后才写入配置；备份机运行随包的 `tools/lnmp-backup-vault.sh setup <账号>` 创建 chroot 专用账号与 sshd 配置，定时把收到的批次移出生产机可访问的范围、校验 `SHA256SUMS` 后归档，生产机被入侵时无法删除或改写已归档的备份。
- 异地备份支持 S3 兼容对象存储：`lnmp backup remote-setup s3` 按需安装固定版本 rclone（官方包，SHA-256 校验），试写通过后才写入配置；上传后逐个核对大小与 MD5 再写入提交清单，访问密钥可不含删除权限，过期由桶生命周期规则执行；`lnmp backup list` 列出远端批次并标注未提交的上传。
- MySQL 与 MariaDB 导出文件互相转换：`bash tools/convert_db_dump.sh mysql|mariadb <输入> <输出>`，改写排序规则、表选项、默认值写法等不兼容语法，数据内容不变；含账号授权等无法等价转换的内容时不生成输出。

### 行为变化

- LNMPA/LAMP 新装改用 Apache event MPM + PHP-FPM，可为站点选择附加 PHP 版本；`.htaccess` 中的 `php_value` 不再生效，须改用 `.user.ini`。存量 mod_php 机器不迁移。
- 非交互建站：静态与反代站点不再询问伪静态，以管道喂入答案的旧脚本须删除对应行。
- 站点模板删除 WordPress 上传目录 PHP 与 `wp-config*` 的拒绝规则（改为按 HowtoGuides 10.3 手工加入），PHP 与静态站点默认启用静态资源缓存。
- 整栈 `lnmp start|stop|reload|restart` 中任一服务或附加 PHP 实例失败时返回 1。
- `upgrade.sh M2M` 可用，`m2Y` 按无效选项处理。
- 版本号、tag 与发布包名改为三段，如 `v3.0.3-<日期>`、`lnmp-v3.0.3.tar.gz`，四段格式的 tag 不再触发发布。
- 发布包新增无版本号的 `lnmp.tar.gz`，固定下载地址为 `releases/latest/download/lnmp.tar.gz`；CI 镜像改为 Debian 13。

### 缺陷修复

- `upgrade.sh phpa` 未识别栈、mod_php 与 FPM 并存时静默按 FPM 构建。
- Node.js 补丁升级删除已装的 PM2 与其它全局包。
- PHP 升级后 OPcache、session 等自定义 ini 设置被重置。
- 应用目录以不同写法（结尾斜杠、`.`、父子目录）可重复占用。
- Apache 日志自动切割找不到日志。
- 建站验收在 Apache graceful 重载期间误报失败，反代站点误报通过。
- FPM 形态下 `tools/remove_disable_function.sh` 只重启 Apache，修改不生效。

### 验证结论

各项均有离线用例；Node.js、PM2、单站点启停、请求验收、建站预设、zstd、LNMPA/LAMP FPM 形态已在测试机实测。待实机复验：LNMP/LNMPA 整栈下的站点启停、HTTP/3 完整签发流程、mod_php 形态的 `upgrade.sh phpa`、arm64。

## 3.0.2（2026-10-11）

### 新增功能

- 单项入口 `install.sh apache [lnmpa|lamp]`、`install.sh php [lnmp|lnmpa|lamp]`：只安装或补齐对应组件，已就绪时不重新编译。
- 已完成安装重跑 `install.sh <栈>` 改为只读体检，逐组件报告状态、服务、HTTP、FPM 与数据库连通性并给出处理命令，不再提示清理重装。

### 行为变化

- 组件安装、升级、卸载统一经模块接口（Nginx、OpenResty、Apache、PHP、数据库、phpMyAdmin、Pure-FTPd），失败返回非零并清理本次写入，不再直接退出。
- 卸载时两种数据库均检查，数据目录先移到 `/root/databases_backup_<时间>`；数据库仍在运行时中止且不删除文件；Web 站点配置、证书与 acme.sh 删除前复制到 `/root/lnmp-preserved-<时间>/`。
- 移除 PHP imap 扩展的安装与 `Enable_PHP_Imap`：c-client 无上游维护，Debian 13 无开发包，PHP 8.4 起源码不含 `ext/imap`，PECL imap 同样依赖 c-client。保留 `addons.sh uninstall imap`。
- MySQL 源码编译不再构建 MySQL Router；`upgrade.sh m2m` 只迁移业务库与账号，`caching_sha2_password` 账号需确认重置口令。

### 缺陷修复

- `upgrade.sh phpa`、`upgrade.sh m2m`、MySQL 源码安装、无 nghttp2 时 LAMP 安装必然失败。
- 数据库升级在无 `~/.my.cnf` 时被误判失败并回滚；数据目录非空检查晚于写入。
- 整栈卸载残留 Pure-FTPd 与 nft 规则；卸载后进度标记残留。
- OpenResty 源码升级在 nginx 运行时返回 2；发布包文件属主为打包者。
- PHP 升级误撤普通 `conf.d` 配置；多版本 PHP 回滚忽略启动失败。
- LNMPA/LAMP 的 `lnmp ssl add default` 不可用。

### 验证结论

全量离线 141 个用例 0 失败；测试机实测数据库二进制与源码安装、升级、迁移与故障回滚，LNMP/LNMPA/LAMP 整栈安装、重跑、卸载，并与改动前代码比对产物一致。

## 3.0.1（2026-10-09）

### 新增功能

- 维护任务互斥锁：安装、升级、扩展、卸载、`bumpversion.sh` 同时只允许一个运行，残留锁自动回收。
- 管理命令成组部署：`/bin/lnmp` 与 `/bin/lnmp-*` 带统一构建 ID，部署失败整组恢复。
- 多版本 PHP 实例按默认扩展开关安装 igbinary、phpredis、imagick。

### 行为变化

- 产品版本唯一来源 `include/product.sh`，安装、升级、卸载入口与横幅从该文件取值。
- PHP 扩展统一经扩展模块构建，产物可加载后才写 ini，失败恢复原有文件；`addons.sh uninstall` 只删除本包写入的文件。
- `addons.sh install redis|memcached` 先装服务端，扩展失败时保留服务端并返回 1。

### 验证结论

全量离线 129 个用例 0 失败；测试机纯净 Debian 13.6 非交互安装 LNMP 返回 0，锁占用期间各入口返回 2 且系统未改动。
