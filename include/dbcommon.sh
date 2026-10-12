#!/usr/bin/env bash
#
# 数据库源码编译工具链与安全初始化结果；安装、升级与迁移在 include/mod/database.sh。

# EL9、EL10 和 Oracle 9 上的 MySQL 源码编译使用 gcc-toolset-12。
DB_Toolchain_EL9()
{
    if [ "${Bin}" = "y" ] || [ "${DB_Kind}" != "mysql" ]; then
        return 0
    fi
    dnf install gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ gcc-toolset-12-binutils gcc-toolset-12-annobin-annocheck gcc-toolset-12-annobin-plugin-gcc -y
}

# 数据库安全初始化任一步骤失败都会由 end.sh 汇总并使安装返回非零状态，由数据库模块写入。
DB_Init_Failed='n'
DB_Init_Errors=''
