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
check '数据库端口由 lnmp.conf 的 DB_Port 写入' \
    "grep -Fq 's/LNMP_DB_PORT/\${DB_Port}/g' include/php.sh && \
     grep -Fq 's/LNMP_DB_PORT/\${DB_Port}/g' include/upgrade_phpmyadmin.sh"
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
