#!/usr/bin/env bash
#
# 组件删除的共享实现。由 uninstall.sh 的完整卸载和 install.sh 的残留清理共用。
# 本文件只提供函数，不执行任何删除动作。

# 把非空数据目录整体移出删除范围。失败返回非零，调用方必须据此中止后续删除。
Backup_DB_Data()
{
    local src="$1" dst n=1

    if [ ! -d "${src}" ]; then
        echo "数据目录 ${src} 不存在，跳过备份。"
        return 0
    fi

    # 空数据目录无需备份，也不应阻止卸载未完成的安装。
    if [ -z "$(ls -A "${src}" 2>/dev/null)" ]; then
        echo "数据目录 ${src} 为空，无需备份。"
        return 0
    fi

    # 同一秒内备份多个数据目录时目标名会重复，重复则追加序号。
    dst="/root/databases_backup_$(date +"%Y%m%d%H%M%S")"
    while [ -e "${dst}" ]; do
        dst="/root/databases_backup_$(date +"%Y%m%d%H%M%S")_${n}"
        n=$((n + 1))
    done

    echo "正在将数据目录 ${src} 备份到 ${dst}"
    if ! mv "${src}" "${dst}"; then
        Echo_Red "致命错误：数据目录备份失败：${src} -> ${dst}"
        Echo_Red "为避免连同数据一起删除，已中止。**没有删除任何文件。**"
        Echo_Red "请先手工把数据目录搬到安全位置，再重新执行。"
        return 1
    fi

    # 删除程序前必须确认备份目录存在且包含数据。
    if [ ! -d "${dst}" ] || [ -z "$(ls -A "${dst}" 2>/dev/null)" ]; then
        Echo_Red "致命错误：备份目录 ${dst} 不存在或为空，无法确认数据已安全转移。"
        Echo_Red "已中止，**没有删除任何文件。**"
        return 1
    fi

    # 备份目录必须位于删除范围之外。
    case "${dst}" in
    /usr/local/*)
        Echo_Red "致命错误：备份路径 ${dst} 仍在 /usr/local 下，会被后续删除。已中止。"
        return 1
        ;;
    esac

    Echo_Green "数据目录已备份到 ${dst}"
    return 0
}

# 处理 /etc/lnmp 下的备份配置与凭据。
#
# lnmp backup init 会生成 backup.conf（站点清单、异地上传设置）与
# backup-mysql.cnf（以 0600 保存数据库 root 口令）。卸载删掉了数据库实例和
# /bin/lnmp-backup，口令文件留下只剩风险，且重装后会被误当成新实例的凭据，
# 因此删除该凭据；其余配置移到 /root 并显示目标路径。
#
# 配置转移失败时保留原目录并提示使用者手工处理。
Remove_Lnmp_Conf_Dir()
{
    local dir='/etc/lnmp'
    local dst
    dst="/root/lnmp_conf_backup_$(date +"%Y%m%d%H%M%S")"

    [ -d "${dir}" ] || return 0

    if [ -f "${dir}/backup-mysql.cnf" ]; then
        rm -f "${dir}/backup-mysql.cnf"
        echo "已删除含数据库口令的 ${dir}/backup-mysql.cnf。"
    fi

    if [ -n "$(ls -A "${dir}" 2>/dev/null)" ]; then
        if mkdir -p "${dst}" &&
            find "${dir}" -mindepth 1 -maxdepth 1 -exec mv -f {} "${dst}/" \; &&
            [ -z "$(ls -A "${dir}" 2>/dev/null)" ]; then
            Echo_Green "${dir} 下的其余配置已移到 ${dst}"
        else
            Echo_Red "无法转移 ${dir} 下的配置，已原样保留：${dir}"
            Echo_Red "该目录可能仍有含敏感信息的文件，请自行检查并处理。"
            return 0
        fi
    fi

    rmdir "${dir}" 2>/dev/null
    return 0
}

# DB_Name 为空时 rm -rf /usr/local/${DB_Name} 会删掉整个 /usr/local，
# 因此空值与 None 一并提前返回。
Remove_DB_Files()
{
    [ -n "${DB_Name}" ] || return 0
    [ "${DB_Name}" = "None" ] && return 0
    Remove_DB_Command_Links
    Remove_DB_Dev_Links
    # 空值已在函数开头拦截。
    # shellcheck disable=SC2115
    rm -rf "/usr/local/${DB_Name}"
    rm -f /etc/my.cnf
    rm -f "/etc/init.d/${DB_Name}"
    Remove_Libaio_Compat_Link
}

# 清理本包建立的头文件与库链接和动态库搜索路径配置。
# 只处理仍指向 /usr/local/mysql 或 /usr/local/mariadb 的链接，
# 留下的悬空链接会让下次安装的 ln 建出自指链接。
Remove_DB_Dev_Links()
{
    local link target conf changed='n'

    for link in /usr/include/mysql /usr/lib/mysql \
                /usr/include/mariadb /usr/lib/mariadb; do
        [ -L "${link}" ] || continue
        target=$(readlink "${link}" 2>/dev/null)
        case "${target}" in
            /usr/local/mysql/*|/usr/local/mariadb/*)
                rm -f "${link}"
                changed='y'
                ;;
        esac
    done

    for conf in /etc/ld.so.conf.d/mysql.conf /etc/ld.so.conf.d/mariadb.conf; do
        [ -f "${conf}" ] || continue
        grep -Eq '^[[:space:]]*/usr/local/(mysql|mariadb)/lib' "${conf}" || continue
        rm -f "${conf}"
        changed='y'
    done

    [ "${changed}" = 'y' ] && ldconfig 2>/dev/null
    return 0
}

# 仅清理本包为数据库通用二进制包建立的 libaio.so.1 兼容链接：必须是符号链接，
# 且指向 libaio.so.1t64*。发行版自带的实体库或指向别处的链接一律不动。
Remove_Libaio_Compat_Link()
{
    local link target

    for link in $(ldconfig -p 2>/dev/null | awk '$1 == "libaio.so.1t64" {print $NF}' \
                  | xargs -r -n1 dirname | sort -u | sed 's:$:/libaio.so.1:'); do
        [ -L "${link}" ] || continue
        target=$(readlink "${link}")
        case "${target##*/}" in
        libaio.so.1t64*)
            rm -f "${link}"
            ldconfig
            ;;
        esac
    done
}

# 只删除仍指向本包数据库目录的软链接，以及带 LNMP 标记的 MariaDB 包装器。
# 非本包安装的同名系统客户端不在清理范围内。
Remove_DB_Command_Links()
{
    local command path target first second

    for command in mysql mysqldump mysqladmin mysqlcheck mysql_upgrade mysqld_safe \
                   mariadb mariadb-dump mariadb-admin mariadb-check mariadb-upgrade mariadbd-safe \
                   myisamchk; do
        path="/usr/bin/${command}"
        if [ -L "${path}" ]; then
            target=$(readlink "${path}" 2>/dev/null)
            case "${target}" in
                /usr/local/mysql/*|/usr/local/mariadb/*) rm -f "${path}" ;;
            esac
        elif [ -f "${path}" ]; then
            first=$(sed -n '1p' "${path}")
            second=$(sed -n '2p' "${path}")
            if [ "${first}" = '#!/bin/sh' ] \
                && [ "${second}" = '# LNMP MariaDB compatibility wrapper' ]; then
                rm -f "${path}"
            fi
        fi
    done
}


MPHP_Supported_Vers='8.0 8.1 8.2 8.3 8.4 8.5'

Remove_Multiple_PHP()
{
    local v mphp
    for v in ${MPHP_Supported_Vers}; do
        mphp="/usr/local/php${v}"
        [ -d "${mphp}" ] || continue
        echo "正在删除多版本 PHP ${v} ..."
        # 模板 unit 实例优先，未安装 unit 的存量环境仍走 SysV。
        if [ -s /etc/systemd/system/php-fpm@.service ] && command -v systemctl >/dev/null 2>&1; then
            systemctl disable --now php-fpm@${v}.service >/dev/null 2>&1
        fi
        if [ -s /etc/init.d/php-fpm${v} ]; then
            /etc/init.d/php-fpm${v} stop
            Remove_StartUp php-fpm${v}
            rm -f /etc/init.d/php-fpm${v}
        fi
        rm -f /usr/local/nginx/conf/enable-php${v}.conf
        rm -rf "${mphp}"
    done

    # 模板 unit 由所有版本共用，全部清理完毕后再删除。
    if [ -e /etc/systemd/system/php-fpm@.service ]; then
        rm -f /etc/systemd/system/php-fpm@.service
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    fi
}

# 清理 lnmp app 托管的应用：实例 unit、元数据与专属账号。
# 应用目录不动，由用户自行处置。
Remove_App_Hosting()
{
    local env_file name user

    if [ -d /etc/lnmp/apps ]; then
        for env_file in /etc/lnmp/apps/*.env; do
            [ -s "${env_file}" ] || continue
            name=$(basename "${env_file}" .env)
            user="lnmp-app-${name}"
            echo "正在取消托管应用 ${name} ..."
            if command -v systemctl >/dev/null 2>&1; then
                systemctl disable --now "lnmp-app@${name}.service" >/dev/null 2>&1
                systemctl reset-failed "lnmp-app@${name}.service" >/dev/null 2>&1
            fi
            rm -f "${env_file}"
            id -u "${user}" >/dev/null 2>&1 && userdel "${user}" >/dev/null 2>&1
        done
        rmdir /etc/lnmp/apps 2>/dev/null
    fi

    # 模板 unit 由所有应用共用，全部清理完毕后再删除。
    if [ -e /etc/systemd/system/lnmp-app@.service ]; then
        rm -f /etc/systemd/system/lnmp-app@.service
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    fi
}

# 清理 lnmp health init 写入的定时探测任务。
Remove_Health_Schedule()
{
    local timer='/etc/systemd/system/lnmp-health.timer'
    local service='/etc/systemd/system/lnmp-health.service'
    # 本工具不安装 cron，该路径仅用于清理手工写入的任务。
    local cron='/etc/cron.d/lnmp-health'

    if [ -x /bin/lnmp-health ]; then
        /bin/lnmp-health uninit >/dev/null 2>&1
    fi
    if [ -e "${timer}" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now lnmp-health.timer >/dev/null 2>&1
    fi
    if [ -e "${timer}" ] || [ -e "${service}" ]; then
        rm -f "${timer}" "${service}"
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    fi
    rm -f "${cron}" /etc/lnmp/health-state
    return 0
}

# 清理日志切割定时任务，不动已归档的日志。
Remove_Cutlogs_Schedule()
{
    local timer='/etc/systemd/system/lnmp-cutlogs.timer'
    local service='/etc/systemd/system/lnmp-cutlogs.service'

    if [ -e "${timer}" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now lnmp-cutlogs.timer >/dev/null 2>&1
    fi
    if [ -e "${timer}" ] || [ -e "${service}" ]; then
        rm -f "${timer}" "${service}"
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    fi
    return 0
}

# 清理 lnmp backup init 写入的定时任务，不动已有备份数据。
Remove_Backup_Schedule()
{
    local timer='/etc/systemd/system/lnmp-backup.timer'
    local service='/etc/systemd/system/lnmp-backup.service'
    local cron='/etc/cron.d/lnmp-backup'

    if [ -e "${timer}" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now lnmp-backup.timer >/dev/null 2>&1
    fi
    if [ -e "${timer}" ] || [ -e "${service}" ]; then
        rm -f "${timer}" "${service}"
        command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    fi
    rm -f "${cron}"
    return 0
}

# 剥离各服务 unit 中的权限校验钩子，移除诊断单元与定期核对任务。
# 必须在删除 /bin/lnmp-perm 之前调用，避免 unit 残留指向已删除的命令。
Remove_Perm_Hooks()
{
    local unit path
    local diagnose='/etc/systemd/system/lnmp-perm-diagnose@.service'
    local timer='/etc/systemd/system/lnmp-perm.timer'
    local service='/etc/systemd/system/lnmp-perm.service'
    local cron='/etc/cron.d/lnmp-perm'

    if [ -x /bin/lnmp-perm ]; then
        /bin/lnmp-perm uninit >/dev/null 2>&1
    else
        for unit in mysql mariadb nginx httpd php-fpm redis pureftpd; do
            path="/etc/systemd/system/${unit}.service"
            [ -f "${path}" ] || continue
            grep -q '^# LNMP perm hooks$' "${path}" || continue
            sed -i '/^# LNMP perm hooks$/,+1{/^# LNMP perm hooks$/d;/^\(ExecStartPre\|ExecStopPost\|OnFailure\)=/d}' "${path}"
        done
    fi
    if [ -e "${timer}" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now lnmp-perm.timer >/dev/null 2>&1
    fi
    rm -f "${diagnose}" "${timer}" "${service}" "${cron}"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1
    return 0
}

# 卸载同样要显式指定 home：acme.sh 只认环境变量，不加载 acme.sh.env 时会去
# 操作默认目录，装在 /usr/local/acme.sh 的这套 cron 与账户都清不掉。
Remove_Acme()
{
    local default_home="${HOME:-/root}/.acme.sh" rc=0

    if [ -s /usr/local/acme.sh/acme.sh ]; then
        if ! ( export LE_WORKING_DIR=/usr/local/acme.sh
               export LE_CONFIG_HOME=/usr/local/acme.sh
               /usr/local/acme.sh/acme.sh --uninstall ); then
            Echo_Red "acme.sh --uninstall 返回失败，继续删除程序目录并清理定时任务。"
        fi
        rm -rf /usr/local/acme.sh
        if [ -e /usr/local/acme.sh ]; then
            Echo_Red "删除 /usr/local/acme.sh 失败。"
            rc=1
        fi
    fi

    # --uninstall 已移除自身 cron，这里兜底清理仍指向该目录的任务。
    if crontab -l 2>/dev/null | grep -qF "/usr/local/acme.sh"; then
        if ! crontab -l 2>/dev/null | grep -vF "/usr/local/acme.sh" | crontab -; then
            Echo_Red "清理 acme.sh 定时任务失败，请执行 crontab -e 手工删除。"
            rc=1
        fi
    fi

    # 旧版本未加载环境时会另建一套 home，其中含账户私钥；该目录也可能是用户
    # 自建的实例，因此只提示不删除。
    if [ -d "${default_home}" ]; then
        Echo_Yellow "检测到另一套 acme.sh 工作目录：${default_home}"
        Echo_Yellow "其中可能保留账户私钥与证书，确认不再使用后执行：rm -rf ${default_home}"
    fi
    return ${rc}
}
