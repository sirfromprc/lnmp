#!/usr/bin/env bash
#
# 【已废弃】请使用正式运维命令 `lnmp backup`。
#
# `lnmp backup` 提供完整的备份结果校验：
#
#   * 同时检查数据库导出、压缩和写盘结果，避免把截断文件记为成功；
#   * 按保留天数清理所有过期备份，避免因计划任务中断积累旧文件；
#   * 远端上传完成后再生效最终文件名，上传失败时保留可用恢复点；
#   * 通过并发锁、校验清单和试恢复确认备份可用性。
#
# 脚本位于 tools/lnmp-backup.sh，安装后的路径为 /bin/lnmp-backup：
#
#   lnmp backup init      生成 /etc/lnmp/backup.conf 与 systemd timer
#   lnmp backup run       执行备份（timer 会自动调用）
#   lnmp backup status    查看上次结果
#   lnmp backup test      试恢复验证
#
# 本兼容入口会把现有 cron 调用转发到 `lnmp backup`，防止升级后定时备份中断。
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
