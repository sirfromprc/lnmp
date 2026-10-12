#!/usr/bin/env bash
#
# t/test_dispatch.sh - 派发可达性测试
#
# source 全部 include 但不执行任何安装动作，逐个编号验证：
#   1. 各数据库版本与安装方式可交给数据库模块，PHP 各版本可交给 PHP 模块
#   2. Enable_PHP_Config 指向的配置文件真实存在
#
# 使用 bash 函数表（declare -f）确认映射目标是否存在。

cd "$(dirname "$0")/.." || exit 1

. lnmp.conf 2>/dev/null

for f in include/main.sh include/profile.sh include/dbcommon.sh include/init.sh \
         include/mod/database.sh include/php.sh include/mod/nginx.sh \
         include/mod/apache.sh include/end.sh include/only.sh include/multiplephp.sh \
         include/mod/php.sh; do
    if [ ! -s "$f" ]; then
        echo "SKIP  $f (不存在)"
        continue
    fi
    if ! . "$f" 2>/dev/null; then
        echo "FAIL  source $f"
        exit 1
    fi
done

fail=0

echo "=== 数据库版本可交给数据库模块 ==="
DB_ARCH=${DB_ARCH:-x86_64}
i=1
while [ ${i} -le ${DB_Count} ]; do
    Set_DB_Profile "${i}"
    if [ -n "$(Database_Sources "${DB_Kind}" "${DB_Ver#*-}" bin)" ] &&
       [ -n "$(Database_Sources "${DB_Kind}" "${DB_Ver#*-}" source)" ]; then
        printf 'ok   db%-2s -> %s\n' "${i}" "${DB_Ver}"
    else
        printf 'FAIL db%-2s -> %s 无法生成下载清单\n' "${i}" "${DB_Ver}"
        fail=1
    fi
    i=$((i+1))
done

echo
echo "=== PHP 版本可交给 PHP 模块 ==="
i=1
while [ ${i} -le ${PHP_Count} ]; do
    Set_PHP_Profile "${i}"
    if PHP_Sources /usr/local/php fpm "${Php_Ver#php-}" >/dev/null &&
       PHP_Sources "${MPHP_Path}" fpm "${Php_Ver#php-}" >/dev/null; then
        printf 'ok   php%-2s -> %s %s\n' "${i}" "${Php_Ver}" "${MPHP_Path}"
    else
        printf 'FAIL php%-2s -> %s %s 无法生成下载清单\n' "${i}" "${Php_Ver}" "${MPHP_Path}"
        fail=1
    fi
    i=$((i+1))
done

echo
echo "=== Apache 版本可交给 Apache 模块 ==="
i=1
while [ ${i} -le ${Apache_Count} ]; do
    Set_Apache_Profile "${i}"
    if [ -n "$(Apache_Sources "${Apache_Ver#httpd-}" lamp)" ] &&
       [ -n "$(Apache_Sources "${Apache_Ver#httpd-}" lnmpa)" ]; then
        printf 'ok   apache%-2s -> %s\n' "${i}" "${Apache_Ver}"
    else
        printf 'FAIL apache%-2s -> %s 无法生成下载清单\n' "${i}" "${Apache_Ver}"
        fail=1
    fi
    i=$((i+1))
done

echo
echo "=== enable-php 配置文件存在性 ==="
i=1
while [ ${i} -le ${PHP_Count} ]; do
    Set_PHP_Profile "${i}"
    if [ -s "conf/${Enable_PHP_Config}" ]; then
        printf 'ok   php%-2s -> conf/%s\n' "${i}" "${Enable_PHP_Config}"
    else
        printf 'FAIL php%-2s -> conf/%s 缺失\n' "${i}" "${Enable_PHP_Config}"
        fail=1
    fi
    i=$((i+1))
done

echo
echo "=== 关键辅助函数存在性 ==="
for fn in Set_DB_Profile Set_PHP_Profile Set_Apache_Profile \
          Version_GE Invalid_Selection Print_DB_Menu Print_PHP_Menu \
          Select_DB_Bin DB_Bin_Available DB_Install_Mode Download_DB_Sources Require_File \
          DB_Toolchain_EL9 Startup_DB Database_Install Database_Check Apache_Install Apache_Check; do
    if declare -f "${fn}" >/dev/null 2>&1; then
        printf 'ok   %s\n' "${fn}"
    else
        printf 'FAIL %s 未定义\n' "${fn}"
        fail=1
    fi
done

echo
if [ ${fail} -eq 0 ]; then
    echo "全部通过"
else
    echo "有检查未通过"
fi
exit ${fail}
