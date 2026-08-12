#!/usr/bin/env bash

cd "$(dirname "$0")/.." || exit 1

fail=0

check()
{
    if eval "$2"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n' "$1"
        fail=1
    fi
}

check '新装默认值仍由 lnmp.conf 控制且默认关闭' \
    "bash -c 'unset Enable_PhpMyAdmin; . ./lnmp.conf; [ \"\$Enable_PhpMyAdmin\" = n ]' && \
     bash -c 'Enable_PhpMyAdmin=y; . ./lnmp.conf; [ \"\$Enable_PhpMyAdmin\" = y ]'"
check 'install.sh 提供显式 phpmyadmin 入口' \
    "grep -A3 '^[[:space:]]*phpmyadmin)' install.sh | grep -q 'Install_Only_phpMyAdmin'"
check '入口传出管道左侧真实退出码' \
    "grep -A3 '^[[:space:]]*phpmyadmin)' install.sh | grep -q 'PIPESTATUS\[0\]'"
check '独立安装先识别现有主栈' \
    "grep -A20 '^Install_Only_phpMyAdmin()' include/php.sh | grep -q 'Detect_PhpMyAdmin_Stack || return 1'"
check '重复安装不会覆盖现有目录' \
    "grep -A60 '^Install_Only_phpMyAdmin()' include/php.sh | grep -q '\[ -e \"\${PhpMyAdmin_Dir}\" \]'"
check '遗留的停用映射也会阻止重复安装覆盖' \
    "grep -A65 '^Install_Only_phpMyAdmin()' include/php.sh | grep -q '.phpmyadmin.enable.conf.disabled'"
check 'Web 配置失败会回滚' \
    "grep -A150 '^Install_Only_phpMyAdmin()' include/php.sh | grep -q 'Rollback_PhpMyAdmin_Install'"
check '成功前检查安装产物' \
    "grep -A170 '^Install_Only_phpMyAdmin()' include/php.sh | grep -q '\[ ! -s \"\${PhpMyAdmin_Dir}/index.php\" \]'"
check '成功前执行本机 HTTP 冒烟验证' \
    "grep -A190 '^Install_Only_phpMyAdmin()' include/php.sh | grep -q 'Smoke_Test_PhpMyAdmin_HTTP'"
check 'HTTP 冒烟允许 Web reload 的短暂切换窗口' \
    "grep -A20 '^Smoke_Test_PhpMyAdmin_HTTP()' include/php.sh | grep -q 'for attempt in 1 2 3 4 5' && \
     grep -A20 '^Smoke_Test_PhpMyAdmin_HTTP()' include/php.sh | grep -q 'sleep 1'"
check '补装只在进程内启用且不改 lnmp.conf' \
    "grep -A170 '^Install_Only_phpMyAdmin()' include/php.sh | grep -q \"Enable_PhpMyAdmin='y'\" && \
     ! grep -A190 '^Install_Only_phpMyAdmin()' include/php.sh | grep -q 'sed.*lnmp.conf'"
check '补装与升级按本机实际数据库端口写入' \
    "grep -q '^Get_Actual_DB_Port()' include/main.sh && \
     grep -Fq 's/LNMP_DB_PORT/\${db_port}/g' include/php.sh && \
     grep -Fq 's/LNMP_DB_PORT/\${db_port}/g' include/upgrade_phpmyadmin.sh && \
     ! grep -Fq 's/LNMP_DB_PORT/\${DB_Port}/g' include/upgrade_phpmyadmin.sh"
check '完整安装仍用本次安装选定的 DB_Port' \
    "sed -n '/^Creat_PHP_Tools()/,/^}/p' include/php.sh | \
       grep -Fq 's/LNMP_DB_PORT/\${DB_Port}/g'"
check 'Get_Actual_DB_Port 取 [mysqld] 段、忽略 [client]、非法值退回' \
    "bash t/test_db_port.sh"
check '升级路径替换后核对占位符已清空' \
    "grep -A6 's/LNMP_DB_PORT/\${db_port}/g' include/upgrade_phpmyadmin.sh | \
       grep -q \"grep -qE 'LNMPORG|LNMP_DB_PORT'\""
check '配置入口锚定 default_server 块的 root 指令而非具体目录' \
    "sed -n '/^Ensure_PhpMyAdmin_Config_Hooks()/,/^}/p' include/php.sh | \
       grep -q 'line ~ /\^root\[\[:space:\]\]/' && \
     ! sed -n '/^Ensure_PhpMyAdmin_Config_Hooks()/,/^}/p' include/php.sh | \
       grep -q 'website_root'"
check 'HTTP 冒烟读取现有监听端口' \
    "grep -q '^Get_PhpMyAdmin_HTTP_Port()' include/php.sh && \
     ! grep -A190 '^Install_Only_phpMyAdmin()' include/php.sh | grep -q '127.0.0.1/\${access_url}'"
check '旧安装缺少入口时补入主配置且可回滚' \
    "grep -q '^Ensure_PhpMyAdmin_Config_Hooks()' include/php.sh && \
     grep -A15 '^Rollback_PhpMyAdmin_Install()' include/php.sh | grep -q 'PMA_Nginx_Main_Backup'"
check '三种管理脚本均可启用、关闭和查看 phpMyAdmin 入口' \
    "grep -q '/bin/lnmp-phpmyadmin lnmp ' conf/lnmp && \
     grep -q '/bin/lnmp-phpmyadmin lnmpa ' conf/lnmpa && \
     grep -q '/bin/lnmp-phpmyadmin lamp ' conf/lamp"
check '源码安装入口复用已安装的访问管理脚本' \
    "! grep -q '^Set_PhpMyAdmin_Access()' include/php.sh && \
     grep -A25 '^Install_Only_phpMyAdmin()' include/php.sh | grep -q '/bin/lnmp-phpmyadmin \"\${Stack}\" \"\${action}\"'"
check '完整安装的 phpMyAdmin 使用临时目录并传播失败' \
    "grep -A130 '^Creat_PHP_Tools()' include/php.sh | grep -q 'phpmyadmin-full-install' && \
     grep -A130 '^Creat_PHP_Tools()' include/php.sh | grep -q 'tar Jxf.*-C' && \
     grep -A130 '^Creat_PHP_Tools()' include/php.sh | grep -q 'return 1' && \
     [ \"$(grep -c 'Creat_PHP_Tools || return 1' install.sh)\" -eq 3 ]"
check '完整安装遇到损坏归档时返回非零且不部署正式目录' \
    "( work=\$(mktemp -d) && \
     mkdir -p \"\$work/src\" \"\$work/conf\" \"\$work/web\" && \
     cp conf/index.html conf/lnmp.gif conf/config.inc.php \"\$work/conf/\" && \
     : > \"\$work/src/phpMyAdmin-bad.tar.xz\" && \
     bash -c '. include/php.sh; Echo_Red(){ :; }; \
       cur_dir=\"\$1\"; Default_Website_Dir=\"\$1/web\"; Enable_PHPInfo_Page=n; \
       Enable_PhpMyAdmin=y; PhpMyAdmin_Ver=phpMyAdmin-bad; \
       PhpMyAdmin_Dir=\"\$1/deployed\"; PhpMyAdmin_Url_File=\"\$1/deployed/.access_url\"; \
       DB_Port=3306; Stack=lnmp; ! Creat_PHP_Tools && [ ! -e \"\$1/deployed\" ]' _ \"\$work\"; \
     rc=\$?; rm -rf \"\$work\"; [ \$rc -eq 0 ] )"
check '三份默认站点模板都带 phpMyAdmin 入口钩子' \
    "[ \"\$(grep -c 'include phpmyadmin\.\*\.conf;' conf/nginx.conf)\" -ge 1 ] && \
     [ \"\$(grep -c 'include phpmyadmin\.\*\.conf;' conf/nginx_a.conf)\" -ge 1 ] && \
     [ \"\$(grep -c 'include phpmyadmin\.\*\.conf;' conf/openresty.conf)\" -ge 1 ] && \
     [ \"\$(grep -c 'IncludeOptional conf/extra/phpmyadmin\.\*\.conf' conf/httpd24-lamp.conf)\" -ge 1 ] && \
     [ \"\$(grep -c 'IncludeOptional conf/extra/phpmyadmin\.\*\.conf' conf/httpd24-lnmpa.conf)\" -ge 1 ]"
check '重建入口时清理遗留的停用片段' \
    "grep -A20 '^Config_PhpMyAdmin_Access()' include/php.sh | \
     grep -q 'rm -f \"\${nginx_saved}\" \"\${apache_saved}\"'"
check '一个片段都没写出来时不报成功' \
    "sed -n '/^Config_PhpMyAdmin_Access()/,/^}/p' include/php.sh | \
       grep -q '\${written}\" -eq 0'"
check '删除程序目录前拒绝空值和根目录' \
    "grep -q '^Remove_PhpMyAdmin_Dir()' include/php.sh && \
     sed -n '/^Remove_PhpMyAdmin_Dir()/,/^}/p' include/php.sh | \
       grep -q '\[ \"\${PhpMyAdmin_Dir}\" != .\/. \]' && \
     ! sed -n '/^Creat_PHP_Tools()/,/^}/p' include/php.sh | grep -q 'rm -rf \${PhpMyAdmin_Dir}'"
check '关闭只移动 Web 映射且不删除程序目录' \
    "grep -A100 'case \"\${action}\" in' tools/lnmp-phpmyadmin.sh | grep -q 'mv \"\${nginx_live}\" \"\${nginx_saved}\"' && \
     ! grep -A100 'case \"\${action}\" in' tools/lnmp-phpmyadmin.sh | grep -Eq 'rm .*pma_dir|rm .*phpmyadmin'"
check '访问状态切换失败会恢复原映射' \
    "grep -A35 '^if ! web_test' tools/lnmp-phpmyadmin.sh | grep -q 'mv \"\${nginx_saved}\" \"\${nginx_live}\"'"
check '旧环境补装后会事务式补齐 lnmp 管理子命令' \
    "grep -q '^Install_PhpMyAdmin_Manager_Command()' include/php.sh && \
     grep -A30 '^Install_PhpMyAdmin_Manager_Command()' include/php.sh | grep -q 'lnmp-phpmyadmin' && \
     grep -A30 '^Rollback_PhpMyAdmin_Install()' include/php.sh | grep -q 'PMA_Manager_Backup'"

exit ${fail}
