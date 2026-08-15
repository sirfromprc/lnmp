<?php
/**
 * phpMyAdmin 配置（适用于 phpMyAdmin 5.2.x）
 *
 * 本文件由安装或升级流程复制到 /usr/local/phpmyadmin/config.inc.php，
 * 占位符会替换为随机值。
 * 程序目录不在网站根目录下，访问入口由 Web 服务器上的随机路径映射过去。
 *
 * 全部可用配置项见 https://docs.phpmyadmin.net/en/latest/config.html
 */

/**
 * blowfish_secret 用于加密 Cookie 中的数据库口令。
 * 安装时会替换为 32 字节随机值；手工部署也必须使用独立随机值。
 */
$cfg['blowfish_secret'] = 'LNMPORG';

/**
 * $i 为服务器编号；连接多台数据库时复制服务器配置并递增 $i。
 */
$i = 0;

$i++;
/* cookie 模式要求登录，不在配置文件中保存数据库口令。 */
$cfg['Servers'][$i]['auth_type'] = 'cookie';
/* 使用 TCP 和 DB_Port；localhost 会改用 UNIX socket。 */
$cfg['Servers'][$i]['host'] = '127.0.0.1';
$cfg['Servers'][$i]['port'] = 'LNMP_DB_PORT';
/* 与数据库之间启用压缩协议。同机连接没有收益，保持 false。 */
$cfg['Servers'][$i]['compress'] = false;
/* 禁止空口令登录。 */
$cfg['Servers'][$i]['AllowNoPassword'] = false;
/* 公网环境建议禁用 root 登录，日常管理使用专用数据库账号。 */
// $cfg['Servers'][$i]['AllowRoot'] = false;

/**
 * phpMyAdmin 配置存储（书签、SQL 历史、列注释、关系视图等高级功能）。
 * 启用前需创建 phpmyadmin 库并导入 sql/create_tables.sql；不需要时保持注释。
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
 * 服务器端导入和导出目录。留空表示关闭，避免数据库转储落入 Web 可访问目录。
 * 大型数据库需要此功能时，应使用网站根目录之外、仅 www 可访问的目录：
 *   mkdir -p /var/lib/phpmyadmin/{upload,save}
 *   chown -R www:www /var/lib/phpmyadmin
 *   chmod 700 /var/lib/phpmyadmin/{upload,save}
 * 将 UploadDir 和 SaveDir 设置为对应的绝对路径。
 */
$cfg['UploadDir'] = '';
$cfg['SaveDir'] = '';

/**
 * 模板缓存目录由安装脚本创建，属主 www、权限 700，且位于网站根目录之外。
 */
$cfg['TempDir'] = '/var/lib/phpmyadmin/tmp';

/**
 * 登录态有效期（秒）。1440 = 24 分钟无操作后需重新登录。
 * 实际时长还受 session.gc_maxlifetime 限制，取两者较小值；公网环境不建议延长。
 */
$cfg['LoginCookieValidity'] = 1440;

/**
 * false 表示首页不显示 MySQL 版本、协议版本和服务器主机名。
 */
$cfg['ShowServerInfo'] = false;

/**
 * 关闭在线版本检查，避免页面请求主动连接 phpmyadmin.net；升级使用 LNMP 升级入口。
 */
$cfg['VersionCheck'] = false;

/**
 * JS 错误报告可能包含页面 URL 和上下文；ask 表示每次询问。
 */
$cfg['SendErrorReports'] = 'ask';

/**
 * 常用界面选项，按需取消注释。
 */
/* 浏览数据时每页显示多少行，默认 25 */
// $cfg['MaxRows'] = 50;
/* 是否显示「显示全部记录」按钮；大表可能占用大量内存，默认关闭 */
// $cfg['ShowAll'] = true;
/* 二进制字段的编辑限制：false=可编辑, 'blob', 'noblob', 'all'=全部禁止编辑 */
// $cfg['ProtectBinary'] = 'blob';
/* 界面语言；未设置时跟随浏览器 */
// $cfg['DefaultLang'] = 'zh_CN';
/* 数据库列表分几列显示，大于 1 会隐藏部分信息 */
// $cfg['PropertiesNumColumns'] = 2;
/* SQL 历史写入数据库，需先启用配置存储 */
// $cfg['QueryHistoryDB'] = true;
// $cfg['QueryHistoryMax'] = 100;
