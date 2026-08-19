#!/usr/bin/env bash
#
# lnmp-sqlguard - 导入前的 SQL 边界检查
#
# 用途：确认一个 dump 只会改动指定的目标库，不含跨库或管理级语句。
# 导入、备份恢复和试恢复都用 root 客户端执行 SQL，文件里的
# DROP DATABASE、DROP USER、跨库 USE 等语句会越过目标库边界。
#
# 用法：
#   lnmp-sqlguard check <目标库名> <文件.sql|文件.sql.gz>
#   lnmp-sqlguard report <目标库名> <文件>     # 只报告，始终返回 0
#
# 返回码：
#   0  未发现越界语句（report 模式恒为 0）
#   1  发现越界语句
#   2  参数、文件或解压错误

set -u

Self="lnmp-sqlguard"

Err() { printf '%s\n' "$*" >&2; }

Usage()
{
    cat <<EOF
用法：${Self} check|report <目标库名> <文件.sql 或 .sql.gz>
  check   发现越界语句时返回 1
  report  只列出发现的问题，返回 0
EOF
}

Mode="${1:-}"
Target="${2:-}"
File="${3:-}"

case "${Mode}" in
    check|report) ;;
    *) Usage; exit 2 ;;
esac

if [ -z "${Target}" ] || [ -z "${File}" ]; then
    Usage
    exit 2
fi

case "${Target}" in
    *[!A-Za-z0-9_]*|'') Err "目标库名不合法：${Target}"; exit 2 ;;
esac

if [ ! -f "${File}" ] || [ ! -r "${File}" ] || [ ! -s "${File}" ]; then
    Err "文件不存在、不可读或为空：${File}"
    exit 2
fi

# gzip 内容按压缩流读取，其余按纯文本读取。
if gzip -t "${File}" 2>/dev/null; then
    Reader=(gzip -dc "${File}")
else
    Reader=(cat "${File}")
fi

# 扫描规则说明：
# - 可执行注释 /*!...*/ 内的语句会被 MySQL 执行，因此先剥掉 /*! 与 */ 再判断，
#   不能把它当普通注释跳过。
# - 只做保守的关键字与跨库限定名匹配，命中即报告；不做完整 SQL 解析。
# - 单行内可能有多条语句，按分号拆开逐条判断，避免只看行首漏判。
Findings=$("${Reader[@]}" 2>/dev/null | awk -v target="${Target}" '
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function note(kind, text,   shown) {
    shown = trim(text)
    if (length(shown) > 120) shown = substr(shown, 1, 120) "..."
    printf "%d\t%s\t%s\n", NR, kind, shown
    found = 1
}
{
    line = $0
    # 行注释与空行不参与判断；-- 与 # 之后的内容不会被执行。
    sub(/^[ \t]*--.*$/, "", line)
    sub(/^[ \t]*#.*$/, "", line)
    if (trim(line) == "") next

    # 可执行注释的包裹符去掉，内部语句照常检查。
    gsub(/\/\*![0-9]*/, " ", line)
    gsub(/\*\//, " ", line)

    n = split(line, stmts, ";")
    for (i = 1; i <= n; i++) {
        s = trim(stmts[i])
        if (s == "") continue
        u = toupper(s)

        if (u ~ /^(CREATE|DROP|ALTER)[ \t]+(DATABASE|SCHEMA)([ \t]|$)/) { note("库级语句", s); continue }
        if (u ~ /^(CREATE|DROP|ALTER|RENAME)[ \t]+USER([ \t]|$)/)       { note("账号语句", s); continue }
        if (u ~ /^(GRANT|REVOKE)[ \t]/)                                 { note("授权语句", s); continue }
        if (u ~ /^SET[ \t]+PASSWORD([ \t]|$)/)                          { note("改口令语句", s); continue }
        if (u ~ /^(CREATE|DROP|ALTER)[ \t]+TABLESPACE([ \t]|$)/)        { note("表空间语句", s); continue }
        if (u ~ /^(INSTALL|UNINSTALL)[ \t]+(PLUGIN|COMPONENT)([ \t]|$)/) { note("插件语句", s); continue }
        if (u ~ /^(SHUTDOWN|RESET[ \t]+(MASTER|SLAVE|REPLICA)|(CHANGE|START|STOP)[ \t]+(MASTER|SLAVE|REPLICA))([ \t]|$)/) { note("实例控制语句", s); continue }
        if (u ~ /^LOAD[ \t]+DATA([ \t]|$)/)                             { note("读服务器文件", s); continue }
        if (u ~ /INTO[ \t]+(OUTFILE|DUMPFILE)([ \t]|$)/)                { note("写服务器文件", s); continue }
        # mysql 客户端命令：source/\. 会引入另一个文件，system/\! 会执行 shell。
        if (u ~ /^(SOURCE|SYSTEM)[ \t]/ || s ~ /^\\[.!]/)               { note("客户端命令", s); continue }

        if (u ~ /^USE([ \t]|`)/) {
            db = s
            sub(/^[Uu][Ss][Ee][ \t]*/, "", db)
            gsub(/[`"'"'"';]/, "", db)
            db = trim(db)
            if (db != target) note("切到其它库", s)
            continue
        }

        # 跨库限定名：`其它库`.`对象`。目标库自身的限定写法照常放行。
        tmp = s
        while (match(tmp, /`[^`]+`[ \t]*\./)) {
            qualified = substr(tmp, RSTART + 1, RLENGTH - 1)
            sub(/`[ \t]*\.$/, "", qualified)
            if (qualified != target) {
                note("跨库对象引用", s)
                break
            }
            tmp = substr(tmp, RSTART + RLENGTH)
        }
    }
}
END { exit 0 }
')

Reader_Rc=$?
if [ "${Reader_Rc}" -ne 0 ]; then
    Err "读取 SQL 内容失败：${File}"
    exit 2
fi

if [ -z "${Findings}" ]; then
    [ "${Mode}" = "report" ] && printf '%s\n' "SQL 边界检查通过：只涉及数据库 ${Target}。"
    exit 0
fi

printf '%s\n' "在 ${File} 中发现越出目标库 ${Target} 的语句："
printf '%s\n' "${Findings}" | awk -F'\t' '{ printf "  第 %s 行  [%s]  %s\n", $1, $2, $3 }' | head -n 20
Count=$(printf '%s\n' "${Findings}" | wc -l)
[ "${Count}" -gt 20 ] && printf '%s\n' "  ...共 ${Count} 条，只显示前 20 条。"

[ "${Mode}" = "report" ] && exit 0
exit 1
