<?php
/**
 * phpMyAdmin 配置（适用于 phpMyAdmin 5.2.x）
 *
 * 本文件由 install.sh / upgrade.sh phpmyadmin 复制到
 * /usr/local/phpmyadmin/config.inc.php，并把下面的占位符换成随机值。
 * 程序目录不在网站根目录下，访问入口由 Web 服务器上的随机路径映射过去。
 *
 * 全部可用配置项见 https://docs.phpmyadmin.net/en/latest/config.html
 */

/**
 * Cookie 认证用它加密保存在浏览器里的数据库口令。
 *
 * 安装时会用 `head -c 32 /dev/urandom` 生成的随机值替换掉这里的占位符 ：
 * 一旦所有机器共用同一个密钥，任何人都能解开别人的登录 Cookie，
 * 所以手工部署时也必须自己换掉，phpMyAdmin 5.x 要求长度为 32 字节。
 */
$cfg['blowfish_secret'] = 'LNMPORG';

/**
 * 服务器配置。$i 是服务器编号，要连多台数据库就把下面这段整体复制一份，
 * 每份开头都写 $i++。
 */
$i = 0;

$i++;
/* cookie = 弹出登录框，口令加密存 Cookie。
 * 不要改成 config（把口令明文写进本文件、任何人打开 /phpmyadmin 都直接进库）。 */
$cfg['Servers'][$i]['auth_type'] = 'cookie';
/* 用 TCP 连接本机数据库，端口由 lnmp.conf 的 DB_Port 在安装时写入。
 * 不用 localhost：mysqli 遇到 localhost 会改走 UNIX socket，从而绕过自定义端口。 */
$cfg['Servers'][$i]['host'] = '127.0.0.1';
$cfg['Servers'][$i]['port'] = 'LNMP_DB_PORT';
/* 与数据库之间启用压缩协议。同机连接没有收益，保持 false。 */
$cfg['Servers'][$i]['compress'] = false;
/* 禁止空口令登录。数据库账号若真的没设口令，应该去补口令，而不是放开这里。 */
$cfg['Servers'][$i]['AllowNoPassword'] = false;
/* 是否允许用 root 登录 phpMyAdmin。
 * 建库建站用 lnmp database add 建的专用账号即可，日常不需要 root。
 * 面向公网的机器建议取消注释，把 root 挡在外面。 */
// $cfg['Servers'][$i]['AllowRoot'] = false;

/**
 * phpMyAdmin 配置存储（书签、SQL 历史、列注释、关系视图等高级功能）。
 * 需要先在库里建一个 phpmyadmin 库并导入 sql/create_tables.sql，
 * 再取消下面几行的注释。不用这些功能就保持注释状态，功能菜单会自动隐藏。
 */
// $cfg['Servers'][$i]['controluser'] = 'pma';
// $cfg['Servers'][$i]['controlpass'] = 'pmapass';
// $cfg['Servers'][$i]['pmadb'] = 'phpmyadmin';
// $cfg['Servers'][$i]['bookmarktable'] = 'pma__bookmark';
// $cfg['Servers'][$i]['relation'] = 'pma__relation';
// $cfg['Servers'][$i]['table_info'] = 'pma__table_info';
// $cfg['Servers'][$i]['table_coords'] = 'pma__table_coords';
// $cfg['Servers'][$i]['pdf_pages'] = 'pma__pdf_pages';
// $cfg['Servers'][$i]['column_info'] = 'pma__column_info';
// $cfg['Servers'][$i]['history'] = 'pma__history';
// $cfg['Servers'][$i]['table_uiprefs'] = 'pma__table_uiprefs';
// $cfg['Servers'][$i]['tracking'] = 'pma__tracking';
// $cfg['Servers'][$i]['userconfig'] = 'pma__userconfig';
// $cfg['Servers'][$i]['recent'] = 'pma__recent';
// $cfg['Servers'][$i]['favorite'] = 'pma__favorite';
// $cfg['Servers'][$i]['users'] = 'pma__users';
// $cfg['Servers'][$i]['usergroups'] = 'pma__usergroups';
// $cfg['Servers'][$i]['navigationhiding'] = 'pma__navigationhiding';
// $cfg['Servers'][$i]['savedsearches'] = 'pma__savedsearches';
// $cfg['Servers'][$i]['central_columns'] = 'pma__central_columns';
// $cfg['Servers'][$i]['designer_settings'] = 'pma__designer_settings';
// $cfg['Servers'][$i]['export_templates'] = 'pma__export_templates';

/**
 * 「导入：服务器上的文件」和「导出：保存到服务器」两个功能的目录。
 *
 * 留空 = 关闭这两个功能，这是默认选择。
 * 原因：导出到服务器写出的是完整的库转储，里面有全部业务数据。
 * 目录一旦落在网站根目录下（例如 phpmyadmin/save），任何人猜到文件名
 * 就能直接下载走整个数据库。日常导出请用浏览器下载，不要落地到服务器。
 *
 * 确实需要时（例如大型数据库不适合通过浏览器导入），必须指向网站根目录以外
 * 的路径，并把属主设为 PHP 运行用户 www：
 *   mkdir -p /var/lib/phpmyadmin/{upload,save}
 *   chown -R www:www /var/lib/phpmyadmin
 *   chmod 700 /var/lib/phpmyadmin/{upload,save}
 * 然后把下面两行改成对应的绝对路径。
 */
$cfg['UploadDir'] = '';
$cfg['SaveDir'] = '';

/**
 * 模板缓存目录。不设置的话 phpMyAdmin 每次请求都要重新编译模板，页面明显变慢。
 * 该目录由安装脚本创建（属主 www，权限 700），放在网站根目录之外。
 */
$cfg['TempDir'] = '/var/lib/phpmyadmin/tmp';

/**
 * 登录态有效期（秒）。1440 = 24 分钟无操作后需重新登录。
 * 注意：还受 php.ini 的 session.gc_maxlifetime 约束，取两者中较小的那个；
 * 想延长必须两边一起改。面向公网时不建议调大。
 */
$cfg['LoginCookieValidity'] = 1440;

/**
 * false = 首页不显示 MySQL 版本、协议版本、服务器主机名等信息。
 * 这些信息对攻击者挑选可用漏洞很有帮助，登录后自己想看可在「数据库服务器」页查。
 */
$cfg['ShowServerInfo'] = false;

/**
 * 关闭「检查有无新版本」。该功能会让服务器主动外连 phpmyadmin.net，
 * 内网或无外网的机器上会造成每次开页面卡几秒。升级请用 lnmp upgrade phpmyadmin。
 */
$cfg['VersionCheck'] = false;

/**
 * 出现 JS 报错时是否把错误报告发回官方。ask = 每次弹窗询问。
 * 报告里可能带上当前页面的 URL 和部分上下文，介意的话改成 'never'。
 */
$cfg['SendErrorReports'] = 'ask';

/**
 * 以下为常用的界面偏好，按需取消注释。
 */
/* 浏览数据时每页显示多少行，默认 25 */
// $cfg['MaxRows'] = 50;
/* 是否显示「显示全部记录」按钮。大表上点一下就可能把内存打满，默认关闭 */
// $cfg['ShowAll'] = true;
/* 二进制字段的编辑限制：false=可编辑, 'blob', 'noblob', 'all'=全部禁止编辑 */
// $cfg['ProtectBinary'] = 'blob';
/* 界面语言，不设则跟随浏览器 */
// $cfg['DefaultLang'] = 'zh_CN';
/* 数据库列表分几列显示，大于 1 会隐藏部分信息 */
// $cfg['PropertiesNumColumns'] = 2;
/* SQL 历史记录存进数据库（需先启用上面的配置存储），否则关页面即丢失 */
// $cfg['QueryHistoryDB'] = true;
// $cfg['QueryHistoryMax'] = 100;
