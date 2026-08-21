#!/usr/bin/env bash
#
# Nginx 日志切割，安装为 /bin/lnmp-cutlogs，由 lnmp-cutlogs.timer 每天 0 点执行。
#
# 日志按年和月归档，例如 /home/wwwlogs/2026/08/default_20260810.log。
#
# 可选配置文件 /etc/lnmp/cutlogs.conf 可覆盖下列变量，管理命令同步时
# 不会改动该文件。

# Nginx 日志目录。
log_files_path="/home/wwwlogs/"

# 需要切割的日志名，每个名字同时处理 `<名字>.log` 和 `<名字>.error.log`。
# 留空表示自动处理日志目录下的全部一级日志，新建站点无需手工登记；
# 显式列出时只切割列出的日志。
log_files_name=()

# Nginx 可执行文件路径。
nginx_sbin="/usr/local/nginx/sbin/nginx"

# 日志保留天数。
save_days=30

[ -r /etc/lnmp/cutlogs.conf ] && . /etc/lnmp/cutlogs.conf

############################################
# 以下为日志切割逻辑，无需修改。       #
############################################

case "${log_files_path}" in
    */) ;;
    *) log_files_path="${log_files_path}/" ;;
esac
[ -d "${log_files_path}" ] || exit 0

# 未指定日志名时按现有日志文件推导，去掉 .error 后缀避免重复处理。
if [ ${#log_files_name[@]} -eq 0 ]; then
    for src in "${log_files_path}"*.log; do
        [ -f "${src}" ] || continue
        name="${src##*/}"
        name="${name%.log}"
        name="${name%.error}"
        case " ${log_files_name[*]} " in
            *" ${name} "*) continue ;;
        esac
        log_files_name+=("${name}")
    done
fi
[ ${#log_files_name[@]} -eq 0 ] && exit 0

yesterday=$(date -d "yesterday" +"%Y%m%d")
log_files_dir="${log_files_path}$(date -d "yesterday" +"%Y")/$(date -d "yesterday" +"%m")"

mkdir -p "${log_files_dir}" || exit 1

# 移动前一天的日志到归档目录，访问日志和错误日志一并处理。
for name in "${log_files_name[@]}"; do
    logfile="${name##*/}"
    for suffix in "" ".error"; do
        src="${log_files_path}${name}${suffix}.log"
        # 未生成日志的站点无需归档。
        [ -f "${src}" ] || continue
        mv "${src}" "${log_files_dir}/${logfile}${suffix}_${yesterday}.log"
    done
done

find "${log_files_path}" -mindepth 1 -type f -name '*.log' \
     -mtime +"${save_days}" -delete

# 只删除已清空的年、月目录，`-empty` 保护仍有内容的目录。
find "${log_files_path}" -mindepth 1 -type d -empty -delete 2>/dev/null

# 重新打开日志文件，避免 worker 继续通过旧 inode 写入归档文件。
# 没有 Nginx 时归档已经完成，不能让退出码把定时任务标成失败。
[ -x "${nginx_sbin}" ] || exit 0
"${nginx_sbin}" -s reload
