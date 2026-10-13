#!/usr/bin/env bash
#
# convert_db_dump - MySQL 与 MariaDB 之间的 SQL 导出文件转换
#
# 用法：
#   bash tools/convert_db_dump.sh mysql   <输入.sql|.sql.gz> <输出.sql|.sql.gz>
#   bash tools/convert_db_dump.sh mariadb <输入.sql|.sql.gz> <输出.sql|.sql.gz>
# 第一个参数是导入目标；输出文件名以 .gz 结尾时按 gzip 写出。
#
# 返回码：
#   0  转换完成
#   1  含无法等价转换的内容，未生成输出文件
#   2  参数、文件或读写错误

set -u

Self="convert_db_dump.sh"

Err() { printf '%s\n' "$*" >&2; }

# 报告行：BAD<TAB>起始行<TAB>类别<TAB>语句摘要
Print_Bad()
{
    local tag line kind text
    while IFS=$'\t' read -r tag line kind text; do
        [ "${tag}" = "BAD" ] || continue
        case "${kind}" in
            coll) printf '  第 %s 行起  目标库没有对应的排序规则：%s\n' "${line}" "${text}" ;;
            account) printf '  第 %s 行起  账号或授权语句，需在目标库重新创建账号：%s\n' "${line}" "${text}" ;;
            sysdb) printf '  第 %s 行起  含 mysql 系统库，只能转换业务库：%s\n' "${line}" "${text}" ;;
            sequence) printf '  第 %s 行起  MariaDB SEQUENCE 对象：%s\n' "${line}" "${text}" ;;
            versioning) printf '  第 %s 行起  MariaDB 系统版本表：%s\n' "${line}" "${text}" ;;
            mtype) printf '  第 %s 行起  MariaDB 专有列类型（UUID/INET4/INET6/VECTOR）：%s\n' "${line}" "${text}" ;;
            funcidx) printf '  第 %s 行起  MySQL 函数索引：%s\n' "${line}" "${text}" ;;
            sqlmode) printf '  第 %s 行起  目标库不支持的 sql_mode：%s\n' "${line}" "${text}" ;;
            parse) printf '  第 %s 行  文件在字符串或注释中意外结束\n' "${line}" ;;
            *) printf '  第 %s 行起  %s：%s\n' "${line}" "${kind}" "${text}" ;;
        esac
    done
}

# 报告行：STAT<TAB>次数<TAB>类别<TAB>明细
Print_Stat()
{
    local tag count kind detail
    while IFS=$'\t' read -r tag count kind detail; do
        [ "${tag}" = "STAT" ] || continue
        case "${kind}" in
            coll) printf '  排序规则 %s：%s 处\n' "${detail}" "${count}" ;;
            sandbox) printf '  删除 MariaDB sandbox 注释行：%s 处\n' "${count}" ;;
            textdef) printf '  TEXT/BLOB 字面默认值改为表达式默认值：%s 处\n' "${count}" ;;
            exec8) printf '  MySQL %s 版本注释改为普通注释：%s 处\n' "${detail}" "${count}" ;;
            gtid) printf '  删除 GTID_PURGED 语句：%s 处\n' "${count}" ;;
            sqlmode) printf '  sql_mode 去掉 %s：%s 处\n' "${detail}" "${count}" ;;
            invcol) printf '  隐藏列改为 MariaDB INVISIBLE：%s 处\n' "${count}" ;;
            invidx) printf '  隐藏索引改为 MariaDB IGNORED：%s 处\n' "${count}" ;;
            ignidx) printf '  IGNORED 索引改为 MySQL INVISIBLE：%s 处\n' "${count}" ;;
            exprdef) printf '  函数默认值加括号：%s 处\n' "${count}" ;;
            *) printf '  %s %s：%s 处\n' "${kind}" "${detail}" "${count}" ;;
        esac
    done
}

Usage()
{
    cat <<EOF
用法：bash tools/${Self} mysql|mariadb <输入.sql 或 .sql.gz> <输出.sql 或 .sql.gz>
  mysql    把 MariaDB 导出文件转换为可导入 MySQL 8.0/8.4 的文件
  mariadb  把 MySQL 导出文件转换为可导入 MariaDB 10.11 及以上的文件
EOF
}

Target="${1:-}"
In_File="${2:-}"
Out_File="${3:-}"

case "${Target}" in
    mysql|mariadb) ;;
    *) Usage; exit 2 ;;
esac

if [ -z "${In_File}" ] || [ -z "${Out_File}" ] || [ $# -ne 3 ]; then
    Usage
    exit 2
fi

if [ ! -f "${In_File}" ] || [ ! -r "${In_File}" ] || [ ! -s "${In_File}" ]; then
    Err "输入文件不存在、不可读或为空：${In_File}"
    exit 2
fi

if [ -e "${Out_File}" ] || [ -L "${Out_File}" ]; then
    Err "输出文件已存在，不覆盖：${Out_File}"
    exit 2
fi

Out_Dir=$(dirname -- "${Out_File}")
if [ ! -d "${Out_Dir}" ] || [ ! -w "${Out_Dir}" ]; then
    Err "输出目录不存在或不可写：${Out_Dir}"
    exit 2
fi

if gzip -t "${In_File}" 2>/dev/null; then
    Reader=(gzip -dc -- "${In_File}")
else
    Reader=(cat -- "${In_File}")
fi

case "${Out_File}" in
    *.gz) Writer=(gzip -c) ;;
    *) Writer=(cat) ;;
esac

Tmp_Out=$(mktemp "${Out_Dir}/.$(basename -- "${Out_File}").XXXXXX") || { Err "无法在 ${Out_Dir} 创建临时文件"; exit 2; }
Tmp_Rpt=$(mktemp) || { rm -f -- "${Tmp_Out}"; Err "无法创建临时报告文件"; exit 2; }
trap 'rm -f -- "${Tmp_Out}" "${Tmp_Rpt}"' EXIT
trap 'exit 130' INT TERM HUP

# 转换规则：
# - 逐行维护词法状态，只改写代码部分；字符串、反引号标识符和普通注释原样输出，
#   数据内容不会被替换。可执行注释 /*!...*/ 的内容按代码处理。
# - mysqldump 风格的单行 INSERT/REPLACE 在引号配对完整时整行直通。
# - 无法等价转换的内容记录到报告，退出码 1，调用方不生成输出文件。
Conv_Awk=$(cat <<'LNMP_CONVDB_AWK'
function trim(s) { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s); return s }

function bad(kind, text,   shown) {
    shown = trim(text)
    gsub(/[\t\r\n ]+/, " ", shown)
    if (length(shown) > 120) shown = substr(shown, 1, 120) "..."
    printf "BAD\t%d\t%s\t%s\n", stmt_nr, kind, shown > rpt
    bad_count++
}

function stat(kind, detail) { STAT[kind "\t" detail]++ }

# 不区分大小写替换，re 为小写正则。
function isub(s, re, rep,   out, low) {
    out = ""
    low = tolower(s)
    while (match(low, re)) {
        out = out substr(s, 1, RSTART - 1) rep
        s = substr(s, RSTART + RLENGTH)
        low = substr(low, RSTART + RLENGTH)
    }
    return out s
}

function map_coll(c) {
    if (target == "mysql") {
        if (c !~ /uca1400|nopad/) return ""
        if (c == "utf8mb4_uca1400_ai_ci" || c == "utf8mb4_uca1400_nopad_ai_ci") return "utf8mb4_0900_ai_ci"
        if (c == "utf8mb4_uca1400_as_ci" || c == "utf8mb4_uca1400_nopad_as_ci") return "utf8mb4_0900_as_ci"
        if (c == "utf8mb4_uca1400_as_cs" || c == "utf8mb4_uca1400_nopad_as_cs") return "utf8mb4_0900_as_cs"
        if (c == "utf8mb4_nopad_bin") return "utf8mb4_0900_bin"
        return "!"
    }
    if (c !~ /0900/) return ""
    if (c == "utf8mb4_0900_ai_ci") return "utf8mb4_uca1400_nopad_ai_ci"
    if (c == "utf8mb4_0900_as_ci") return "utf8mb4_uca1400_nopad_as_ci"
    if (c == "utf8mb4_0900_as_cs") return "utf8mb4_uca1400_nopad_as_cs"
    if (c == "utf8mb4_0900_bin") return "utf8mb4_nopad_bin"
    return "!"
}

# 替换代码片段中的排序规则名，记号边界为非 [A-Za-z0-9_] 字符。
function conv_coll(s,   out, low, tok, m) {
    low = tolower(s)
    if (low !~ /uca1400|nopad|0900/) return s
    out = ""
    while (match(low, /[a-z0-9_]+/)) {
        tok = substr(low, RSTART, RLENGTH)
        out = out substr(s, 1, RSTART - 1)
        m = ""
        if (tok ~ /^(utf8mb4|utf8mb3|utf8|ucs2|utf16|utf16le|utf32)_/) m = map_coll(tok)
        if (m == "!") {
            bad("coll", tok)
            out = out substr(s, RSTART, RLENGTH)
        } else if (m != "") {
            out = out m
            stat("coll", tok " -> " m)
        } else {
            out = out substr(s, RSTART, RLENGTH)
        }
        s = substr(s, RSTART + RLENGTH)
        low = substr(low, RSTART + RLENGTH)
    }
    return out s
}

# 表达式默认值的括号配对；字符串不进入代码片段，其中的括号不计数。
function track(s,   i, n, ch) {
    n = length(s)
    for (i = 1; i <= n; i++) {
        ch = substr(s, i, 1)
        if (ch == "(") depth++
        else if (ch == ")" && --depth == 0) {
            dexpr = 0
            return substr(s, 1, i) ")" substr(s, i + 1)
        }
    }
    return s
}

# MariaDB 输出的函数默认值不带括号，MySQL 只对 CURRENT_TIMESTAMP 一类允许这种写法。
function wrap_default(t,   low, nm, pos) {
    if (dexpr) return track(t)
    low = tolower(t)
    if (!match(low, /default[ \t]+[a-z_][a-z0-9_]*\(/)) return t
    nm = substr(low, RSTART, RLENGTH - 1)
    sub(/^default[ \t]+/, "", nm)
    if (nm ~ /^(current_timestamp|now|localtime|localtimestamp)$/) return t
    pos = RSTART + RLENGTH - 1 - length(nm)
    stat("exprdef", "")
    dexpr = 1; depth = 0
    return substr(t, 1, pos - 1) "(" track(substr(t, pos))
}

function emit(t) {
    if (direct) printf "%s", t
    else ob = ob t
}

function canon_add(t) {
    if (keep_canon || length(canon) < 64) canon = canon t
}

# 语句开头确定后决定是否继续缓存：只有需要整句丢弃的语句才缓存到语句结束。
function decide_head(   h) {
    if (head_done) return
    h = trim(canon)
    gsub(/[ \t\r\n]+/, " ", h)
    if (length(h) < 32 && !stmt_end) return
    head_done = 1
    h = tolower(h)
    head = h
    if (h ~ /^(create|alter)[ ]/) keep_canon = 1
    if (h ~ /^create[ ]+table[ ]/) in_create = 1
    if (target == "mariadb" && h ~ /^set[ ]+@@(global\.)?gtid_purged/) { drop_stmt = 1; return }
    printf "%s", ob
    ob = ""
    direct = 1
}

function code(t,   u) {
    if (t == "") return
    t = conv_coll(t)
    if (in_create && target == "mysql") {
        t = isub(t, "engine=aria", "ENGINE=InnoDB")
        t = isub(t, "[ ]+(page_checksum|transactional)=[01]", "")
        t = isub(t, "[ ]+row_format=page", "")
        u = isub(t, "[ ]ignored", " INVISIBLE")
        if (u != t) { stat("ignidx", ""); t = u }
        t = wrap_default(t)
    }
    emit(t)
    cbuf = cbuf t
    if (t ~ /[^ \t\r\n]/) has_code = 1
    canon_add(tolower(t))
    decide_head()
}

function check_stmt(   c) {
    c = canon
    gsub(/[ \t\r\n]+/, " ", c)
    c = trim(c)
    if (c ~ /^(create|alter|drop|rename)[ ]+user[ ]/ || c ~ /^(grant|revoke)[ ]/ || c ~ /^set[ ]+password[ ]/) {
        bad("account", c)
        return
    }
    if (c ~ /^use[ ]+`?mysql`?$/ || c ~ /^create[ ]+database[ ].*`mysql`/) {
        bad("sysdb", c)
        return
    }
    if (target == "mysql") {
        if (c ~ /^create[ ]+(or[ ]+replace[ ]+)?sequence[ ]/) bad("sequence", c)
        if (c ~ /with[ ]+system[ ]+versioning/) bad("versioning", c)
        if (in_create && c ~ /`[^`]*`[ ]+(uuid|inet4|inet6|vector)([ (,)]|$)/) bad("mtype", c)
    } else {
        if (in_create && c ~ /(key|index)[ ]+`[^`]*`[ ]*\([ ]*\(/) bad("funcidx", c)
    }
}

function end_stmt() {
    stmt_end = 1
    decide_head()
    check_stmt()
    if (drop_stmt) { stat("gtid", ""); ob = "" }
    else if (ob != "") { printf "%s", ob; ob = "" }
    reset_stmt()
}

function reset_stmt() {
    ob = ""; canon = ""; cbuf = ""; head = ""
    head_done = 0; keep_canon = 0; in_create = 0; drop_stmt = 0; direct = 0; stmt_end = 0; has_code = 0; dexpr = 0
    stmt_nr = NR
}

function set_special(   fc) {
    fc = substr(delim, 1, 1)
    if (fc ~ /[\]\\^-]/) fc = "\\" fc
    special = "['\"`#/*" fc "-]"
}

# 改写 SET sql_mode 的取值：去掉目标库没有且不改变行为的模式，其余目标库没有的模式报告。
function fix_mode(s,   n, i, a, u, out) {
    n = split(s, a, ",")
    out = ""
    for (i = 1; i <= n; i++) {
        u = toupper(trim(a[i]))
        if (target == "mysql" && (u == "NO_AUTO_CREATE_USER" || u == "TIME_ROUND_FRACTIONAL") || \
            target == "mariadb" && u == "TIME_TRUNCATE_FRACTIONAL") {
            stat("sqlmode", u)
            continue
        }
        if (target == "mysql" && u ~ /^(SIMULTANEOUS_ASSIGNMENT|EMPTY_STRING_IS_NULL|ORACLE|MSSQL|DB2|POSTGRESQL|MAXDB|NO_FIELD_OPTIONS|NO_KEY_OPTIONS|NO_TABLE_OPTIONS)$/)
            bad("sqlmode", u)
        out = (out == "") ? a[i] : out "," a[i]
    }
    return out
}

function semit(t) {
    if (smode) sbuf = sbuf t
    else emit(t)
}

# 字符串开始前判断是否需要给 TEXT/BLOB 的字面默认值加括号，以及是否为 sql_mode 取值。
function str_open(q,   h) {
    wrap = 0
    h = canon
    gsub(/[ \t\r\n]+/, " ", h)
    h = trim(h)
    if (q == "'" && h ~ /^set (@@(session\.)?)?sql_mode ?=$/) { smode = 1; sbuf = "" }
    if (target == "mysql" && in_create && q == "'" && \
        tolower(cbuf) ~ /^[ \t]+(tiny|medium|long)?(text|blob)([ \t].*)?[ \t]default[ \t]+$/) {
        wrap = 1
        emit("(")
        stat("textdef", "")
    }
    cbuf = ""
    canon_add(q q)
}

function scan(line,   rest, c, c2, ver, n, m, p, body, e) {
    rest = line
    while (rest != "") {
        if (state == "C") {
            if (match(rest, /\*\//)) {
                if (!skip_cmt) emit(substr(rest, 1, RSTART + 1))
                rest = substr(rest, RSTART + 2)
                state = "N"; skip_cmt = 0
                canon_add(" ")
            } else {
                if (!skip_cmt) emit(rest)
                rest = ""
            }
            continue
        }
        if (state == "S" || state == "D") {
            m = (state == "S") ? "['\\\\]" : "[\"\\\\]"
            if (!match(rest, m)) { semit(rest); rest = ""; continue }
            c = substr(rest, RSTART, 1)
            c2 = substr(rest, RSTART + 1, 1)
            if (c == "\\") {
                semit(substr(rest, 1, RSTART + 1))
                rest = substr(rest, RSTART + 2)
                continue
            }
            if (c2 == c) {
                semit(substr(rest, 1, RSTART + 1))
                rest = substr(rest, RSTART + 2)
                continue
            }
            semit(substr(rest, 1, RSTART - 1))
            if (smode) { smode = 0; emit(fix_mode(sbuf)) }
            emit(c)
            rest = substr(rest, RSTART + 1)
            state = "N"
            if (wrap) { emit(")"); wrap = 0 }
            continue
        }
        if (state == "B") {
            if (!match(rest, /`/)) { emit(rest); canon_add(tolower(rest)); rest = ""; continue }
            if (substr(rest, RSTART + 1, 1) == "`") {
                emit(substr(rest, 1, RSTART + 1)); canon_add(tolower(substr(rest, 1, RSTART + 1)))
                rest = substr(rest, RSTART + 2)
                continue
            }
            emit(substr(rest, 1, RSTART)); canon_add(tolower(substr(rest, 1, RSTART)))
            rest = substr(rest, RSTART + 1)
            state = "N"
            decide_head()
            continue
        }

        # 普通代码状态
        if (!match(rest, special)) { code(rest); rest = ""; continue }
        p = RSTART
        code(substr(rest, 1, p - 1))
        rest = substr(rest, p)
        c = substr(rest, 1, 1)
        c2 = substr(rest, 2, 1)

        if (substr(rest, 1, length(delim)) == delim) {
            emit(delim)
            rest = substr(rest, length(delim) + 1)
            end_stmt()
            continue
        }
        if (c == "'" || c == "\"") {
            state = (c == "'") ? "S" : "D"
            str_open(c)
            emit(c); rest = substr(rest, 2); has_code = 1; decide_head()
            continue
        }
        if (c == "`") {
            state = "B"; cbuf = ""; has_code = 1
            emit(c); canon_add("`"); rest = substr(rest, 2)
            continue
        }
        if (c == "#" || (c == "-" && c2 == "-" && (length(rest) == 2 || substr(rest, 3, 1) ~ /[ \t\r]/))) {
            emit(rest); rest = ""
            continue
        }
        if (c == "/" && c2 == "*") {
            if (target == "mysql" && (substr(rest, 1, 11) == "/*!999999\\-" || substr(rest, 1, 12) == "/*M!999999\\-")) {
                state = "C"; skip_cmt = 1; rest = substr(rest, 3)
                stat("sandbox", "")
                continue
            }
            if (substr(rest, 3, 1) == "!") {
                ver = ""
                n = 4
                while (substr(rest, n, 1) ~ /[0-9]/) { ver = ver substr(rest, n, 1); n++ }
                if (target == "mariadb" && length(ver) == 5 && ver + 0 >= 80000) {
                    # 隐藏列和隐藏索引按 MariaDB 写法改写，其余改为普通注释。
                    e = index(substr(rest, n), "*/")
                    body = (e > 0) ? toupper(trim(substr(rest, n, e - 1))) : ""
                    if (in_create && body == "INVISIBLE" && (ver == "80023" || ver == "80000")) {
                        if (ver == "80023") { emit("INVISIBLE"); stat("invcol", "") }
                        else { emit("IGNORED"); stat("invidx", "") }
                        rest = substr(rest, n + e + 1)
                        continue
                    }
                    emit("/*" ver); rest = substr(rest, n)
                    state = "C"
                    stat("exec8", ver)
                    continue
                }
                emit(substr(rest, 1, n - 1)); rest = substr(rest, n)
                inexec++
                canon_add(" ")
                continue
            }
            emit("/*"); rest = substr(rest, 3); state = "C"
            continue
        }
        if (c == "*" && c2 == "/" && inexec > 0) {
            emit("*/"); rest = substr(rest, 3); inexec--
            canon_add(" ")
            continue
        }
        code(c)
        rest = substr(rest, 2)
    }
}

# 单行完整 INSERT/REPLACE：去掉反斜杠转义后单引号成对即视为语句在本行结束。
function fast_line(line,   t, q) {
    if (state != "N" || inexec || has_code || delim != ";") return 0
    if (line !~ /^(INSERT|REPLACE) INTO `/) return 0
    if (line !~ /\);\r?$/) return 0
    t = line
    gsub(/\\./, "", t)
    q = gsub(/'/, "", t)
    if (q % 2) return 0
    printf "%s%s\n", ob, line
    reset_stmt()
    return 1
}

BEGIN {
    state = "N"; delim = ";"; inexec = 0; skip_cmt = 0; wrap = 0; smode = 0; bad_count = 0
    set_special()
    reset_stmt()
    stmt_nr = 1
}

{
    if (fast_line($0)) next
    if (state == "N" && !inexec && !has_code && $0 ~ /^[ \t]*[Dd][Ee][Ll][Ii][Mm][Ii][Tt][Ee][Rr][ \t]+[^ \t]/) {
        printf "%s%s\n", ob, $0
        ob = ""
        delim = $0
        sub(/^[ \t]*[Dd][Ee][Ll][Ii][Mm][Ii][Tt][Ee][Rr][ \t]+/, "", delim)
        sub(/[ \t\r].*$/, "", delim)
        set_special()
        reset_stmt()
        next
    }
    if (!has_code && ob == "") stmt_nr = NR
    scan($0)
    emit("\n")
    if (state == "N") { cbuf = cbuf "\n"; canon_add(" ") }
}

END {
    if (has_code) end_stmt()
    else if (ob != "") printf "%s", ob
    if (state != "N" || inexec > 0) {
        printf "BAD\t%d\tparse\t\n", NR > rpt
        bad_count++
    }
    for (k in STAT) printf "STAT\t%d\t%s\n", STAT[k], k > rpt
    exit (bad_count > 0) ? 1 : 0
}
LNMP_CONVDB_AWK
)

"${Reader[@]}" 2>/dev/null | LC_ALL=C awk -v target="${Target}" -v rpt="${Tmp_Rpt}" "${Conv_Awk}" | "${Writer[@]}" > "${Tmp_Out}"
Pipe_Rc=("${PIPESTATUS[@]}")

if [ "${Pipe_Rc[0]}" -ne 0 ]; then
    Err "读取输入文件失败：${In_File}"
    exit 2
fi

if [ "${Pipe_Rc[1]}" -eq 1 ]; then
    printf '%s\n' "${In_File} 含无法转换为 ${Target} 的内容，未生成输出文件："
    Print_Bad < "${Tmp_Rpt}" | head -n 20
    Count=$(grep -c '^BAD' "${Tmp_Rpt}")
    [ "${Count}" -gt 20 ] && printf '%s\n' "  ...共 ${Count} 条，只显示前 20 条。"
    exit 1
fi

if [ "${Pipe_Rc[1]}" -ne 0 ] || [ "${Pipe_Rc[2]}" -ne 0 ]; then
    Err "转换或写出失败：${Out_File}"
    exit 2
fi

if [ "${Writer[0]}" = "gzip" ] && ! gzip -t "${Tmp_Out}" 2>/dev/null; then
    Err "输出文件压缩校验失败：${Out_File}"
    exit 2
fi

if [ -e "${Out_File}" ] || [ -L "${Out_File}" ]; then
    Err "输出文件在转换期间被创建，不覆盖：${Out_File}"
    exit 2
fi

if ! mv -- "${Tmp_Out}" "${Out_File}"; then
    Err "写入输出文件失败：${Out_File}"
    exit 2
fi

printf '%s\n' "已转换为 ${Target} 格式：${Out_File}"
if grep -q '^STAT' "${Tmp_Rpt}"; then
    sort -t $'\t' -k3,4 "${Tmp_Rpt}" | Print_Stat
else
    printf '%s\n' "  未发现需要改写的内容。"
fi
exit 0
