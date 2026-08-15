#!/usr/bin/env bash
#
# nginx 日志切割（配合 crontab 使用，通常每天 0 点跑一次）
#
# 切完的日志按 年/月 归档到 /home/wwwlogs/2026/08/default_20260810.log

#set the path to nginx log files
log_files_path="/home/wwwlogs/"

#set nginx log files you want to cut (add your own vhost log names here)
#
# 默认切 default 兜底站点和本机管理端口的 access。用 lnmp vhost add 建的站点，日志名是各自的域名
# （/home/wwwlogs/example.com.log），不会自动加入列表。新建站点后
# 要手工把名字加进这个数组，否则那些日志会一直长下去。
log_files_name=(default access)

#set the path to nginx.
nginx_sbin="/usr/local/nginx/sbin/nginx"

#Set how long you want to save
save_days=30

############################################
#Please do not modify the following script #
############################################

yesterday=$(date -d "yesterday" +"%Y%m%d")
log_files_dir="${log_files_path}$(date -d "yesterday" +"%Y")/$(date -d "yesterday" +"%m")"

mkdir -p "${log_files_dir}" || exit 1

#cut nginx log files
for name in "${log_files_name[@]}"; do
    src="${log_files_path}${name}.log"
    # 站点还没产生日志时 mv 会报错刷屏，跳过即可
    [ -f "${src}" ] || continue
    logfile="${name##*/}"
    mv "${src}" "${log_files_dir}/${logfile}_${yesterday}.log"
done

find "${log_files_path}" -mindepth 1 -type f -name '*.log' \
     -mtime +"${save_days}" -delete

# 删掉因为上面清理而变空的年/月目录（-empty 保证不会误删还有内容的）
find "${log_files_path}" -mindepth 1 -type d -empty -delete 2>/dev/null

# 让 nginx 重新打开日志文件。日志已经被 mv 走，不做这一步的话
# worker 仍持有旧 inode，继续往归档文件里写。
"${nginx_sbin}" -s reload
