#!/usr/bin/env bash
#
# t/test_dispatch.sh - 派发可达性测试
#
# source 全部 include 但不执行任何安装动作，逐个编号验证：
#   1. DB_Install / PHP_Install / MPHP_Install 指向的函数真实存在
#   2. Enable_PHP_Config 指向的配置文件真实存在
#
# 使用 bash 函数表（declare -f）确认映射目标是否存在。

cd "$(dirname "$0")/.." || exit 1

. lnmp.conf 2>/dev/null

for f in include/main.sh include/profile.sh include/dbcommon.sh include/init.sh \
         include/mysql.sh include/mariadb.sh include/php.sh include/nginx.sh \
         include/apache.sh include/end.sh include/only.sh include/multiplephp.sh; do
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

echo "=== 数据库安装函数可达性 ==="
i=1
while [ ${i} -le ${DB_Count} ]; do
    Set_DB_Profile "${i}"
    if declare -f "${DB_Install}" >/dev/null 2>&1; then
        printf 'ok   db%-2s -> %s\n' "${i}" "${DB_Install}"
    else
        printf 'FAIL db%-2s -> %s 未定义\n' "${i}" "${DB_Install}"
        fail=1
    fi
    i=$((i+1))
done

echo
echo "=== PHP 安装函数可达性 ==="
i=1
while [ ${i} -le ${PHP_Count} ]; do
    Set_PHP_Profile "${i}"
    if declare -f "${PHP_Install}" >/dev/null 2>&1; then
        printf 'ok   php%-2s -> %s\n' "${i}" "${PHP_Install}"
    else
        printf 'FAIL php%-2s -> %s 未定义\n' "${i}" "${PHP_Install}"
        fail=1
    fi
    i=$((i+1))
done

echo
echo "=== 多版本 PHP 安装函数可达性 ==="
i=1
while [ ${i} -le ${PHP_Count} ]; do
    Set_PHP_Profile "${i}"
    if declare -f "${MPHP_Install}" >/dev/null 2>&1; then
        printf 'ok   mphp%-2s -> %s\n' "${i}" "${MPHP_Install}"
    else
        printf 'WARN mphp%-2s -> %s 未定义（多版本 PHP 未覆盖该版本）\n' "${i}" "${MPHP_Install}"
    fi
    i=$((i+1))
done

echo
echo "=== Apache 安装函数可达性 ==="
i=1
while [ ${i} -le ${Apache_Count} ]; do
    Set_Apache_Profile "${i}"
    if declare -f "${Apache_Install}" >/dev/null 2>&1; then
        printf 'ok   apache%-2s -> %s\n' "${i}" "${Apache_Install}"
    else
        printf 'FAIL apache%-2s -> %s 未定义\n' "${i}" "${Apache_Install}"
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
for fn in Dispatch Set_DB_Profile Set_PHP_Profile Set_Apache_Profile \
          Version_GE Invalid_Selection Print_DB_Menu Print_PHP_Menu \
          Select_DB_Bin DB_Bin_Available DB_Download_Files Require_File \
          DB_Toolchain_EL9 Startup_DB Cur_PHP_Branch MySQL_Branch MariaDB_Branch; do
    if declare -f "${fn}" >/dev/null 2>&1; then
        printf 'ok   %s\n' "${fn}"
    else
        printf 'FAIL %s 未定义\n' "${fn}"
        fail=1
    fi
done

echo
echo "=== Dispatch 守卫行为 ==="
if ( Dispatch "Definitely_Not_A_Function_12345" ) >/dev/null 2>&1; then
    echo "FAIL Dispatch 对不存在的函数应当退出非零"
    fail=1
else
    echo "ok   Dispatch 拒绝不存在的函数"
fi
if ( Dispatch "" ) >/dev/null 2>&1; then
    echo "FAIL Dispatch 对空函数名应当退出非零"
    fail=1
else
    echo "ok   Dispatch 拒绝空函数名"
fi

echo
if [ ${fail} -eq 0 ]; then
    echo "全部通过"
else
    echo "有检查未通过"
fi
exit ${fail}
