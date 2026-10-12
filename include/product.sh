#!/usr/bin/env bash
# 产品版本，唯一来源。格式 MAJOR.MINOR.PATCH.BUILD，BUILD 为至少三位的十进制序号。
# 前三段由维护者决定，BUILD 随可独立验收的功能修改递增；组件版本在 version.sh 与 profile.sh。
# 入口脚本、横幅、发布流程均从这里取值，不得另写副本。
LNMP_Ver='3.0.3.000'
