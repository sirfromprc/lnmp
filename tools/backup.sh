#!/usr/bin/env bash
#
# 【已废弃】本模板已由正式的运维命令 `lnmp backup` 取代。
#
# 原模板存在几处会让人误以为备份成功的问题，都已在新实现里修掉：
#
#   * 只取 mysqldump 的退出码，gzip 和写盘失败被忽略 —— 磁盘写满时会留下
#     一个截断的 .sql.gz，脚本却报告成功；
#   * Keep_Days 只删除“正好 N 天前”那一天的文件，某天没跑，更早的备份就
#     永远留在磁盘上；
#   * 远端先删旧备份再上传新的，删成功而传失败就直接少一个恢复点；
#   * 上传直接用最终文件名，连接中断会在远端留下看着正常的残缺文件；
#   * 没有并发锁、没有校验清单、没有试恢复，网站与数据库之间也没有对应关系。
#
# 新实现见 tools/lnmp-backup.sh，安装后即 /bin/lnmp-backup：
#
#   lnmp backup init      生成 /etc/lnmp/backup.conf 与 systemd timer
#   lnmp backup run       执行备份（timer 会自动调用）
#   lnmp backup status    查看上次结果
#   lnmp backup test      试恢复验证
#
# 这个文件保留下来只做一件事：把老的 cron 条目转发到新实现，
# 免得有人的定时备份在升级后悄无声息地停掉。
#

set -u

echo "注意：tools/backup.sh 已废弃，请改用 lnmp backup。" >&2

if [ -x /bin/lnmp-backup ]; then
    echo "本次执行已转发到 /bin/lnmp-backup run all。" >&2
    echo "请把 cron 或 timer 里的路径改成：/bin/lnmp-backup run" >&2
    exec /bin/lnmp-backup run all
fi

echo "错误：找不到 /bin/lnmp-backup，无法转发。" >&2
echo "补装：cp tools/lnmp-backup.sh /bin/lnmp-backup && chmod +x /bin/lnmp-backup" >&2
echo "然后执行：lnmp backup init" >&2
exit 1
