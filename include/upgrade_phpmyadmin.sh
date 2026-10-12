#!/usr/bin/env bash
# phpMyAdmin 升级入口：输入目标版本并确认，部署与恢复由 include/mod/phpmyadmin.sh 的 PhpMyAdmin_Upgrade 完成。

Upgrade_phpMyAdmin()
{
    local ver='' db_port rc

    echo "可在 https://www.phpmyadmin.net/downloads/ 查看可用版本号。"
    read -r -p "请输入目标 phpMyAdmin 版本（例如 5.2.2）：" ver
    if [ -z "${ver}" ]; then
        Echo_Red "错误：必须输入 phpMyAdmin 版本号！"
        return 1
    fi
    Check_Version_String "${ver}" "phpMyAdmin 版本号" || return 1
    Print_Banner "即将把 phpMyAdmin 升级到 ${ver}"
    Press_Start || return 1

    # 使用数据库实际监听端口，避免 lnmp.conf 默认值覆盖安装时的自定义端口。
    db_port=$(Db_Port /etc/my.cnf "${DB_Port}") || \
        Echo_Yellow "未能从 /etc/my.cnf 读到数据库端口，按 lnmp.conf 的 ${db_port} 写入。"
    [ "${db_port}" = "${DB_Port}" ] || \
        Echo_Yellow "数据库实际端口为 ${db_port}（lnmp.conf 记的是 ${DB_Port}），按实际端口写入。"
    PhpMyAdmin_Upgrade "${ver}" "${db_port}"
    rc=$?
    [ "${rc}" -eq 0 ] || return "${rc}"

    # 访问路径不变，地址由 lnmp-phpmyadmin 输出；升级入口未设置 Stack，先探测。
    if [ -x /bin/lnmp-phpmyadmin ] && Detect_PhpMyAdmin_Stack >/dev/null 2>&1; then
        Echo_Green "访问路径不变："
        /bin/lnmp-phpmyadmin "${Stack}" status
    else
        Echo_Green "访问路径不变：http://<服务器IP>/$(cat "${PhpMyAdmin_Url_File}")/"
    fi
    return 0
}
