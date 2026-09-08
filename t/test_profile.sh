#!/usr/bin/env bash
#
# t/test_profile.sh - 映射表单元测试
#
# profile.sh 仅包含赋值操作且无副作用，可直接加载并验证，无需模拟依赖。
# 本测试可在 Windows/Git Bash 环境中验证编号映射。
#
# 覆盖：
#   1. 每个编号 → DB_Kind / DB_Ver / DB_Install / MySQL_Dir
#   2. 非法编号必须返回非零（不能静默回退到默认值）
#   3. 菜单文本与映射表一致

cd "$(dirname "$0")/.." || exit 1

# profile.sh 里的 Echo_Red 来自 main.sh
. lnmp.conf 2>/dev/null
. include/main.sh
. include/profile.sh

fail=0

check()
{
    # check <标签> <期望> <实际>
    if [ "$2" = "$3" ]; then
        printf 'ok   %-26s = %s\n' "$1" "$3"
    else
        printf 'FAIL %-26s expected=[%s] actual=[%s]\n' "$1" "$2" "$3"
        fail=1
    fi
}

echo "=== 数据库映射 ==="
expect_db()
{
    # expect_db <编号> <kind> <ver> <install> <dir>
    if ! Set_DB_Profile "$1"; then
        echo "FAIL Set_DB_Profile $1 返回非零"
        fail=1
        return
    fi
    check "db$1.kind"    "$2" "${DB_Kind}"
    check "db$1.ver"     "$3" "${DB_Ver}"
    check "db$1.install" "$4" "${DB_Install}"
    check "db$1.dir"     "$5" "${MySQL_Dir}"
}

expect_db 1 mysql   mysql-8.0.46     Install_MySQL_80     /usr/local/mysql
expect_db 2 mysql   mysql-8.4.10      Install_MySQL_84     /usr/local/mysql
expect_db 3 mariadb mariadb-10.11.19 Install_MariaDB_1011 /usr/local/mariadb
expect_db 4 mariadb mariadb-11.4.13  Install_MariaDB_114  /usr/local/mariadb
expect_db 5 mariadb mariadb-11.8.9   Install_MariaDB_118  /usr/local/mariadb

Set_DB_Profile 0
check "db0.kind" "none" "${DB_Kind}"

echo
echo "=== PHP 映射 ==="
expect_php()
{
    # expect_php <编号> <branch> <ver> <install> <apache_module>
    if ! Set_PHP_Profile "$1"; then
        echo "FAIL Set_PHP_Profile $1 返回非零"
        fail=1
        return
    fi
    check "php$1.branch" "$2" "${PHP_Branch}"
    check "php$1.ver"    "$3" "${Php_Ver}"
    check "php$1.install" "$4" "${PHP_Install}"
    check "php$1.module" "$5" "${PHP_Apache_Module}"
}

expect_php 1 8.0 php-8.0.30 Install_PHP_80 libphp.so
expect_php 2 8.1 php-8.1.34 Install_PHP_81 libphp.so
expect_php 3 8.2 php-8.2.33 Install_PHP_82 libphp.so
expect_php 4 8.3 php-8.3.33 Install_PHP_83 libphp.so
expect_php 5 8.4 php-8.4.25 Install_PHP_84 libphp.so
expect_php 6 8.5 php-8.5.10  Install_PHP_85 libphp.so

echo
echo "=== Apache 映射 ==="
if Set_Apache_Profile 1; then
    check "apache1.branch"  "2.4"              "${Apache_Branch}"
    check "apache1.ver"     "httpd-2.4.68"     "${Apache_Ver}"
    check "apache1.install" "Install_Apache_24" "${Apache_Install}"
else
    echo "FAIL Set_Apache_Profile 1 返回非零"; fail=1
fi

echo
echo "=== 旧编号必须被拒绝（重编号后最易踩的坑） ==="
# 旧 DB 编号 6..13 与旧 PHP 编号 7..16 在新表中已越界
for n in 6 11 12 13 99 -1 abc ''; do
    if Set_DB_Profile "${n}" 2>/dev/null; then
        echo "FAIL Set_DB_Profile('${n}') 应当失败却返回成功"
        fail=1
    else
        printf 'ok   db reject [%s]\n' "${n}"
    fi
done
for n in 0 7 14 16 99 abc ''; do
    if Set_PHP_Profile "${n}" 2>/dev/null; then
        echo "FAIL Set_PHP_Profile('${n}') 应当失败却返回成功"
        fail=1
    else
        printf 'ok   php reject [%s]\n' "${n}"
    fi
done

echo
echo "=== 菜单文本与映射表一致 ==="
# DB_Info[i-1] 必须包含 DB_Ver 里的版本号
i=1
while [ ${i} -le ${DB_Count} ]; do
    Set_DB_Profile "${i}"
    v="${DB_Ver#*-}"
    case "${DB_Info[$((i-1))]}" in
        *"${v}"*) printf 'ok   db%-2s menu/table 一致 (%s)\n' "${i}" "${v}" ;;
        *) printf 'FAIL db%-2s menu=[%s] table=[%s]\n' "${i}" "${DB_Info[$((i-1))]}" "${DB_Ver}"; fail=1 ;;
    esac
    i=$((i+1))
done

i=1
while [ ${i} -le ${PHP_Count} ]; do
    Set_PHP_Profile "${i}"
    v="${Php_Ver#php-}"
    case "${PHP_Info[$((i-1))]}" in
        *"${v}"*) printf 'ok   php%-2s menu/table 一致 (%s)\n' "${i}" "${v}" ;;
        *) printf 'FAIL php%-2s menu=[%s] table=[%s]\n' "${i}" "${PHP_Info[$((i-1))]}" "${Php_Ver}"; fail=1 ;;
    esac
    i=$((i+1))
done

echo
echo "=== 默认值有效 ==="
Set_DB_Profile "${DB_Default}"   && printf 'ok   DB_Default=%s -> %s\n'  "${DB_Default}" "${DB_Ver}"  || { echo "FAIL DB_Default 无效"; fail=1; }
Set_PHP_Profile "${PHP_Default}" && printf 'ok   PHP_Default=%s -> %s\n' "${PHP_Default}" "${Php_Ver}" || { echo "FAIL PHP_Default 无效"; fail=1; }

echo
echo "=== Version_GE 语义 ==="
Version_GE 8.4 8.0  && echo "ok   8.4 >= 8.0"   || { echo "FAIL 8.4 >= 8.0"; fail=1; }
Version_GE 8.0 8.0  && echo "ok   8.0 >= 8.0"   || { echo "FAIL 8.0 >= 8.0"; fail=1; }
Version_GE 7.4 8.0  && { echo "FAIL 7.4 >= 8.0 应为假"; fail=1; } || echo "ok   7.4 < 8.0"
Version_GE 10.11 8.0 && echo "ok   10.11 >= 8.0" || { echo "FAIL 10.11 >= 8.0 (字典序陷阱)"; fail=1; }
Version_GE 5.6 7.2  && { echo "FAIL 5.6 >= 7.2 应为假"; fail=1; } || echo "ok   5.6 < 7.2"
Version_GE '' 8.0   && { echo "FAIL 空版本应为假"; fail=1; } || echo "ok   空版本返回假"

echo
if [ ${fail} -eq 0 ]; then
    echo "全部通过"
else
    echo "有断言失败"
fi
exit ${fail}
