#!/usr/bin/env bash
#
# Nginx 日志切割，通常由 crontab 在每天 0 点执行。
#
# 日志按年和月归档，例如 /home/wwwlogs/2026/08/default_20260810.log。

# Nginx 日志目录。
log_files_path="/home/wwwlogs/"

# 需要切割的日志名，可在数组中添加虚拟主机日志名。
#
# 默认处理 default 站点和本机管理端口的 access 日志。`lnmp vhost add`
# 创建的站点使用域名作为日志名，需手动加入数组才会定期切割。
log_files_name=(default access)

# Nginx 可执行文件路径。
nginx_sbin="/usr/local/nginx/sbin/nginx"

# 日志保留天数。
save_days=30

############################################
# 以下为日志切割逻辑，无需修改。       #
############################################

yesterday=$(date -d "yesterday" +"%Y%m%d")
log_files_dir="${log_files_path}$(date -d "yesterday" +"%Y")/$(date -d "yesterday" +"%m")"

mkdir -p "${log_files_dir}" || exit 1

# 移动前一天的日志到归档目录。
for name in "${log_files_name[@]}"; do
    src="${log_files_path}${name}.log"
    # 未生成日志的站点无需归档。
    [ -f "${src}" ] || continue
    logfile="${name##*/}"
    mv "${src}" "${log_files_dir}/${logfile}_${yesterday}.log"
done

find "${log_files_path}" -mindepth 1 -type f -name '*.log' \
     -mtime +"${save_days}" -delete

# 只删除已清空的年、月目录，`-empty` 保护仍有内容的目录。
find "${log_files_path}" -mindepth 1 -type d -empty -delete 2>/dev/null

# 重新打开日志文件，避免 worker 继续通过旧 inode 写入归档文件。
"${nginx_sbin}" -s reload
