#!/usr/bin/env bash

# 日志目录
log_files_path="/home/wwwlogs/"

# 指定需要切割的日志名，留空：自动从 Nginx/Apache 配置获取所有日志
# 例如：log_files_name=(default www.example.com abc/123)
log_files_name=()

# Nginx 可执行文件路径
nginx_sbin="/usr/local/nginx/sbin/nginx"

# Apache 可执行文件路径（编译安装，非发行版 apache2 包）
httpd_bin="/usr/local/apache/bin/httpd"

# 日志保留天数
save_days=30

# 用户配置
[ -r /etc/lnmp/cutlogs.conf ] && . /etc/lnmp/cutlogs.conf

# 以下内容无需修改

log_files_path="${log_files_path%/}/"
[ -d "$log_files_path" ] || exit 0

# 目标已存在时追加序号，避免同日重复执行覆盖已有归档
Archive_Log()
{
    local src="$1" dest="$2" n=1

    while [ -e "$dest" ]; do
        dest="${2%.log}_${n}.log"
        n=$((n + 1))
    done
    mv "$src" "$dest"
}

# 获取昨天的日期
yesterday=$(date -d yesterday +"%Y%m%d")

# 昨天对应的归档目录
log_files_dir="${log_files_path}$(date -d yesterday +"%Y")/$(date -d yesterday +"%m")"


# --------------------------------------------------
# 获取 Nginx 配置中的日志文件,只处理 log_files_path 目录下的绝对路径日志。
# access_log 和 error_log 均会处理。
# --------------------------------------------------

logs=()

if [ -x "$nginx_sbin" ]; then
    while IFS= read -r file; do
        [ -n "$file" ] || continue

        # 只保留日志目录下的 .log 文件
        case "$file" in
            "${log_files_path}"*.log)

                # 去重
                case " ${logs[*]} " in
                    *" ${file} "*) ;;
                    *) logs+=("$file") ;;
                esac

                ;;
        esac
    done < <(
        "$nginx_sbin" -T 2>/dev/null |
        awk '
            {
                sub(/\r$/, "")
                sub(/#.*/, "")
                # 按 ; { } 拆分，兼容 "error_log x.log;}" 与一行多条指令
                n = split($0, stmts, /[;{}]/)
                for (i = 1; i <= n; i++) {
                    if (split(stmts[i], w, " ") < 2)
                        continue
                    if (w[1] != "access_log" && w[1] != "error_log")
                        continue
                    path = w[2]
                    gsub(/["\047]/, "", path)
                    if (path ~ /^\// && path ~ /\.log$/)
                        print path
                }
            }
        '
    )
fi

# --------------------------------------------------
# 获取 Apache 配置中的日志文件。Apache 路径习惯带引号，且不带 .log 后缀
# （access_log/error_log/xxx-access_log），跟 Nginx 命名习惯不一样。
# DUMP_CONFIG 由 mod_info 提供，默认配置未加载该模块：仅在本次配置检查中经 -C 加载，
# 不配置 server-info 处理器，不影响运行中的 Apache。无输出视为发现失败。
# --------------------------------------------------

apache_rc=0
if [ -x "$httpd_bin" ]; then
    info_args=()
    info_mod="${httpd_bin%/bin/*}/modules/mod_info.so"
    [ -f "$info_mod" ] && info_args=(-C "LoadModule info_module ${info_mod}")
    apache_dump=$("$httpd_bin" "${info_args[@]}" -t -D DUMP_CONFIG 2>/dev/null) || apache_dump=""
    if [ -z "$apache_dump" ]; then
        apache_rc=1
        echo "无法从 Apache 配置获取日志路径（${httpd_bin} -t -D DUMP_CONFIG 无输出），未切割 Apache 日志。" >&2
    fi
    while IFS= read -r file; do
        [ -n "$file" ] || continue

        case "$file" in
            "${log_files_path}"*)
                case " ${logs[*]} " in
                    *" ${file} "*) ;;
                    *) logs+=("$file") ;;
                esac
                ;;
        esac
    done < <(
        printf '%s\n' "$apache_dump" |
        awk '
            $1 == "CustomLog" || $1 == "ErrorLog" {
                path = $2
                gsub(/"/, "", path)
                if (path ~ /^\//)
                    print path
            }
        '
    )
fi

# --------------------------------------------------
# 未指定日志名时，按照 Nginx/Apache 配置自动切割
# --------------------------------------------------

if [ ${#log_files_name[@]} -eq 0 ]; then
    [ ${#logs[@]} -gt 0 ] || exit "$apache_rc"

    mkdir -p "$log_files_dir" || exit 1

    for file in "${logs[@]}"; do
        relative="${file#"$log_files_path"}"

        dir="${relative%/*}"

        if [ "$dir" = "$relative" ]; then
            dir=""
        fi

        name="${relative##*/}"

        if [ -n "$dir" ]; then
            mkdir -p "${log_files_dir}/${dir}" || exit 1
            target="${log_files_dir}/${dir}/${name%.log}_${yesterday}.log"
        else
            target="${log_files_dir}/${name%.log}_${yesterday}.log"
        fi

        # 空文件不归档，避免每天为无访问的站点生成空归档。
        [ -s "$file" ] || continue

        Archive_Log "$file" "$target" || exit 1
    done

else

    mkdir -p "$log_files_dir" || exit 1

    for name in "${log_files_name[@]}"; do
        logfile="${name##*/}"
        dir="${name%/*}"
        [ "$dir" = "$name" ] && dir=""

        if [ -n "$dir" ]; then
            mkdir -p "${log_files_dir}/${dir}" || exit 1
            dest="${log_files_dir}/${dir}"
        else
            dest="${log_files_dir}"
        fi

        file="${log_files_path}${name}.log"
        if [ -s "$file" ]; then
            Archive_Log "$file" "${dest}/${logfile}_${yesterday}.log" || exit 1
        fi

        file="${log_files_path}${name}.error.log"
        if [ -s "$file" ]; then
            Archive_Log "$file" "${dest}/${logfile}.error_${yesterday}.log" || exit 1
        fi
    done
fi

# --------------------------------------------------
# 删除超过保留时间的日志
# --------------------------------------------------

find "$log_files_path" \
    -type f \
    -name '*.log' \
    -mtime +"$save_days" \
    -delete

# --------------------------------------------------
# 删除归档目录中的空目录,只处理按年份创建的归档目录，不删除日志根目录下的源目录。
# --------------------------------------------------

for year_dir in "${log_files_path}"[0-9][0-9][0-9][0-9]; do
    [ -d "$year_dir" ] || continue

    find "$year_dir" \
        -depth \
        -type d \
        -empty \
        -delete 2>/dev/null
done

# --------------------------------------------------
# 重新打开日志文件
# --------------------------------------------------

if [ -x "$nginx_sbin" ]; then
    lnmp nginx reload || "$nginx_sbin" -s reload
fi

if [ -x "$httpd_bin" ] && pgrep -f "$httpd_bin" >/dev/null 2>&1; then
    "$httpd_bin" -k graceful
fi

# 自动发现模式下 Apache 日志发现失败时返回非零，定时任务记录为失败。
[ ${#log_files_name[@]} -gt 0 ] && exit 0
exit "$apache_rc"
