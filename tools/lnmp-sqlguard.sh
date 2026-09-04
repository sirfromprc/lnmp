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
# - 逐字符维护词法状态：字符串、反引号标识符、行注释和块注释里的内容不参与
#   关键字判断，因此注释、换行和字符串都不能用来藏关键字。
# - 可执行注释 /*!...*/ 内的语句会被 MySQL 执行，只去掉包裹符，内容照常检查。
# - 注释和空白折叠成一个分隔空格，跨行语句按当前分隔符切分，支持 DELIMITER。
# - 跨库限定名同时判断反引号形式和裸写形式；只做保守匹配，命中即报告。
# - 文件在字符串或注释中意外结束时按无法解析处理，直接判为不通过。
Guard_Awk=$(cat <<'LNMP_SQLGUARD_AWK'
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

function note(ln, kind, text,   shown) {
    shown = trim(text)
    gsub(/[\n\r\t]+/, " ", shown)
    if (length(shown) > 120) shown = substr(shown, 1, 120) "..."
    printf "%d\t%s\t%s\n", ln, kind, shown
}

# 注释和空白都是词法分隔符，规范串里统一折叠成一个空格。
function addsep(   last) {
    if (canon == "") return
    last = substr(canon, length(canon), 1)
    if (last != " ") canon = canon " "
}

function addcanon(c) {
    if (start_nr == 0) start_nr = NR
    canon = canon c
}

function addraw(c) { raw = raw c }

# 把规范串切成记号：I=标识符（含反引号形式，取引号内的名字），D=点，P=其它单字符。
function tokenize(c,   i, n, ch, k, cnt) {
    cnt = 0
    n = length(c)
    i = 1
    while (i <= n) {
        ch = substr(c, i, 1)
        if (ch == " ") { i++; continue }
        if (ch == "`") {
            k = i + 1
            while (k <= n && substr(c, k, 1) != "`") k++
            cnt++; tk[cnt] = substr(c, i + 1, k - i - 1); tt[cnt] = "I"
            i = k + 1
            continue
        }
        if (ch ~ /[A-Za-z_$]/) {
            k = i
            while (k <= n && substr(c, k, 1) ~ /[A-Za-z0-9_$]/) k++
            cnt++; tk[cnt] = substr(c, i, k - i); tt[cnt] = "I"
            i = k
            continue
        }
        if (ch ~ /[0-9]/) {
            k = i
            while (k <= n && substr(c, k, 1) ~ /[0-9]/) k++
            cnt++; tk[cnt] = substr(c, i, k - i); tt[cnt] = "N"
            i = k
            continue
        }
        cnt++; tk[cnt] = ch; tt[cnt] = (ch == ".") ? "D" : "P"
        i++
    }
    return cnt
}

# 能紧跟在表引用之后的关键字，出现在别名位置时不算别名。
function is_kw(w,   u) {
    u = toupper(w)
    return (u in KW)
}

# 跳过一处表引用（`(子查询)` 或 `[库.]表`），返回其后的记号下标；不是表引用返回 0。
function skip_table_ref(j, n,   depth) {
    if (j > n) return 0
    if (tt[j] == "P" && tk[j] == "(") {
        depth = 1
        j++
        while (j <= n && depth > 0) {
            if (tt[j] == "P" && tk[j] == "(") depth++
            else if (tt[j] == "P" && tk[j] == ")") depth--
            j++
        }
        return (depth == 0) ? j : 0
    }
    if (tt[j] != "I" || is_kw(tk[j])) return 0
    j++
    if (j + 1 <= n && tt[j] == "D" && tt[j + 1] == "I") j += 2
    return j
}

# 表引用之后的标识符（可带 AS）是别名。
function take_alias(j, n) {
    if (j > n) return
    if (tt[j] == "I" && toupper(tk[j]) == "AS") j++
    if (j <= n && tt[j] == "I" && !is_kw(tk[j])) ALIAS[tk[j]] = 1
}

# 收集本条语句里声明的别名。别名位置上的名字由 MySQL 解析为别名而不是库名，
# 因此跨库判断必须跳过它们，否则视图、连接查询里的 `a`.`col` 会被误判。
function collect_aliases(n,   i, j, u) {
    delete ALIAS
    for (i = 1; i <= n; i++) {
        if (tt[i] == "I") {
            u = toupper(tk[i])
            if (u == "FROM" || u == "JOIN" || u == "UPDATE" || u == "INTO") {
                j = skip_table_ref(i + 1, n)
                if (j > 0) take_alias(j, n)
            }
        } else if (tt[i] == "P" && tk[i] == ",") {
            j = skip_table_ref(i + 1, n)
            if (j > 0) take_alias(j, n)
        }
    }
}

# 跨库限定名：反引号形式和裸写形式都要判断。规范串里字符串字面量已被清空，
# 因此不会把字符串内容误当标识符。
function qual_check(c, s, ln,   n, i, name) {
    n = tokenize(c)
    collect_aliases(n)
    for (i = 2; i <= n; i++) {
        if (tt[i] != "D") continue
        if (tt[i - 1] != "I") continue
        # db.tbl.col 的第二段不是库限定。
        if (i >= 3 && tt[i - 2] == "D") continue
        name = tk[i - 1]
        # NEW/OLD 是触发器的行别名，不是库名。
        if (toupper(name) == "NEW" || toupper(name) == "OLD") continue
        if (name in ALIAS) continue
        if (name != "" && name != target) {
            note(ln, "跨库对象引用", s)
            return
        }
    }
}

function check_stmt(   s, c, u, ln, db) {
    s = trim(raw)
    c = trim(canon)
    ln = start_nr
    raw = ""; canon = ""; start_nr = 0
    if (c == "") return
    u = toupper(c)

    if (u ~ /^(CREATE|DROP|ALTER)[ \t]+(DATABASE|SCHEMA)([ \t]|$)/) { note(ln, "库级语句", s); return }
    if (u ~ /^(CREATE|DROP|ALTER|RENAME)[ \t]+USER([ \t]|$)/)       { note(ln, "账号语句", s); return }
    if (u ~ /^(GRANT|REVOKE)[ \t]/)                                 { note(ln, "授权语句", s); return }
    if (u ~ /^SET[ \t]+PASSWORD([ \t]|$)/)                          { note(ln, "改口令语句", s); return }
    if (u ~ /^(CREATE|DROP|ALTER)[ \t]+TABLESPACE([ \t]|$)/)        { note(ln, "表空间语句", s); return }
    if (u ~ /^(INSTALL|UNINSTALL)[ \t]+(PLUGIN|COMPONENT)([ \t]|$)/) { note(ln, "插件语句", s); return }
    if (u ~ /^(SHUTDOWN|RESET[ \t]+(MASTER|SLAVE|REPLICA)|(CHANGE|START|STOP)[ \t]+(MASTER|SLAVE|REPLICA))([ \t]|$)/) { note(ln, "实例控制语句", s); return }
    if (u ~ /^LOAD[ \t]+DATA([ \t]|$)/)                             { note(ln, "读服务器文件", s); return }
    if (u ~ /INTO[ \t]+(OUTFILE|DUMPFILE)([ \t]|$)/)                { note(ln, "写服务器文件", s); return }
    # mysql 客户端命令：source/\. 会引入另一个文件，system/\! 会执行 shell。
    if (u ~ /^(SOURCE|SYSTEM|DELIMITER)([ \t]|$)/ || c ~ /^\\[.!]/)  { note(ln, "客户端命令", s); return }

    if (u ~ /^USE([ \t]|`|$)/) {
        db = c
        sub(/^[Uu][Ss][Ee][ \t]*/, "", db)
        gsub(/`/, "", db)
        db = trim(db)
        if (db != target) note(ln, "切到其它库", s)
        return
    }

    qual_check(c, s, ln)
}

# 逐字符扫描，跨行维护状态：字符串、反引号标识符、行注释和块注释里的内容
# 不参与关键字判断，语句以当前分隔符结束。
function scan(line,   i, n, c, c2) {
    n = length(line)
    for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        c2 = substr(line, i + 1, 1)

        if (state == "L") { if (c == "\n") state = "N"; continue }

        if (state == "C") {
            addraw(c)
            if (c == "*" && c2 == "/") { i++; addraw(c2); state = "N"; addsep() }
            continue
        }

        if (state == "S" || state == "D" || state == "B") {
            addraw(c)
            # 反斜杠转义只在字符串里生效，反引号标识符按 `` 成对处理。
            if ((state == "S" || state == "D") && c == "\\") {
                i++
                if (i <= n) addraw(substr(line, i, 1))
                continue
            }
            if (state == "S" && c == "'") {
                if (c2 == "'") { i++; addraw(c2); continue }
                state = "N"; addcanon("'")
            } else if (state == "D" && c == "\"") {
                if (c2 == "\"") { i++; addraw(c2); continue }
                state = "N"; addcanon("\"")
            } else if (state == "B" && c == "`") {
                if (c2 == "`") { i++; addraw(c2); addcanon("`"); continue }
                state = "N"; addcanon("`")
            } else if (state == "B") {
                addcanon(c)
            }
            continue
        }

        # 以下为普通状态
        if (c == "-" && c2 == "-" && (substr(line, i + 2, 1) ~ /[ \t\r\n]/ || i + 2 > n)) {
            state = "L"; addsep(); continue
        }
        if (c == "#") { state = "L"; addsep(); continue }
        if (c == "/" && c2 == "*") {
            # 可执行注释的内容会被 MySQL 执行，只去掉包裹符。
            if (substr(line, i + 2, 1) == "!") {
                i += 2
                while (i + 1 <= n && substr(line, i + 1, 1) ~ /[0-9]/) i++
                exec_depth++
                addraw("/*!"); addsep()
                continue
            }
            i++; state = "C"; addraw(c); addraw(c2); continue
        }
        if (c == "*" && c2 == "/") {
            if (exec_depth > 0) exec_depth--
            i++; addraw(c); addraw(c2); addsep(); continue
        }

        if (c == "'") { state = "S"; addraw(c); addcanon("'"); continue }
        if (c == "\"") { state = "D"; addraw(c); addcanon("\""); continue }
        if (c == "`") { state = "B"; addraw(c); addcanon("`"); continue }

        if (c == " " || c == "\t" || c == "\n" || c == "\r") { addraw(" "); addsep(); continue }

        if (substr(line, i, dlen) == delim) {
            i += dlen - 1
            check_stmt()
            continue
        }

        addraw(c); addcanon(c)
    }
}

BEGIN {
    state = "N"; canon = ""; raw = ""; delim = ";"; dlen = 1; exec_depth = 0; start_nr = 0
    split("WHERE ON USING SET GROUP ORDER LIMIT HAVING UNION INNER LEFT RIGHT FULL " \
          "CROSS JOIN STRAIGHT_JOIN NATURAL VALUES SELECT FOR LOCK PARTITION IGNORE " \
          "FORCE USE WITH AND OR NOT IS NULL AS INTO FROM UPDATE DELETE INSERT REPLACE " \
          "OUTER WINDOW PROCEDURE INTERVAL DUPLICATE KEY", KWLIST, " ")
    for (i in KWLIST) KW[KWLIST[i]] = 1
}

{
    # DELIMITER 是客户端命令，必须独占一行；识别它才能正确切分存储程序。
    if (state == "N" && trim(canon) == "" && $0 ~ /^[ \t]*[Dd][Ee][Ll][Ii][Mm][Ii][Tt][Ee][Rr][ \t]+[^ \t]/) {
        canon = ""; raw = ""; start_nr = 0
        delim = $0
        sub(/^[ \t]*[Dd][Ee][Ll][Ii][Mm][Ii][Tt][Ee][Rr][ \t]+/, "", delim)
        sub(/[ \t].*$/, "", delim)
        dlen = length(delim)
        next
    }
    scan($0 "\n")
}

END {
    check_stmt()
    if (state == "S" || state == "D" || state == "B" || state == "C" || exec_depth > 0) {
        note(NR, "无法解析", "文件在字符串或注释中意外结束，语句边界无法确认")
    }
    exit 0
}
LNMP_SQLGUARD_AWK
)

Findings=$("${Reader[@]}" 2>/dev/null | awk -v target="${Target}" "${Guard_Awk}")

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
