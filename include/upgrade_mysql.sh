#!/usr/bin/env bash


Upgrade_MySQL()
{
    local glibc_ver mode
    Check_DB
    if [ "${Is_MySQL}" = "n" ]; then
        Echo_Red "当前数据库是 MariaDB，不能运行 MySQL 升级脚本。"
        exit 1
    fi

    Verify_DB_Password

    cur_mysql_version=`/usr/local/mysql/bin/mysql_config --version`
    mysql_version=""
    echo "当前 MySQL 版本：${cur_mysql_version}"
    echo "可在 https://dev.mysql.com/downloads/mysql/ 查看可用版本号。"
    Echo_Yellow "请输入目标 MySQL 版本（仅支持 8.0.x 或 8.4.x）。"
    read -p "版本号（例如 8.4.7）：" mysql_version
    if [ "${mysql_version}" = "" ]; then
        echo "错误：必须输入 MySQL 版本号！"
        exit 1
    fi
    Check_Version_String "${mysql_version}" "MySQL 版本号" || exit 1

    if [ "${mysql_version}" == "${cur_mysql_version}" ]; then
        echo "错误：目标 MySQL 版本与当前版本相同！"
        exit 1
    fi

    mysql_short_version=$(echo "${mysql_version}" | cut -d. -f1-2)
    if [ "${mysql_short_version}" != "8.0" ] && [ "${mysql_short_version}" != "8.4" ]; then
        Echo_Red "不支持升级到 MySQL ${mysql_version}。"
        Echo_Red "本包只保留 8.0 与 8.4（LTS）两条线：5.x 系列上游已 EOL，"
        Echo_Red "对应的升级函数已随版本裁剪移除。"
        Echo_Red "数据库未做任何改动。"
        exit 1
    fi

    glibc_ver=$(Get_Glibc_Version)
    if [[ "${DB_ARCH}" = "x86_64" || "${DB_ARCH}" = "aarch64" ]] && ! Version_GE "${glibc_ver}" 2.28; then
        Echo_Yellow "系统 glibc ${glibc_ver:-未知} 低于官方二进制包要求的 2.28，将使用源码编译（需要 4GB 以上内存，耗时数小时）。"
        Bin="n"
    elif [[ "${DB_ARCH}" = "x86_64" || "${DB_ARCH}" = "aarch64" ]]; then
        read -p "是否使用官方通用二进制包 [Y/n]（默认 y，推荐）：" Bin
        case "${Bin}" in
        [yY][eE][sS]|[yY])
            echo "将使用官方通用二进制包安装 MySQL ${mysql_version}。"
            Bin="y"
            ;;
        [nN][oO]|[nN])
            echo "将使用源码安装 MySQL ${mysql_version}。"
            Bin="n"
            ;;
        *)
            echo "使用默认项：官方通用二进制包安装 MySQL ${mysql_version}。"
            Bin="y"
            ;;
        esac
    else
        Bin="n"
    fi

    # 选择是否启用 InnoDB 存储引擎。
    echo "==========================="

    InstallInnodb="y"
    Echo_Yellow "是否启用 InnoDB 存储引擎？"
    read -p "请输入 y 或 n [默认 y]：" InstallInnodb

    case "${InstallInnodb}" in
    [yY][eE][sS]|[yY])
        echo "将启用 InnoDB 存储引擎。"
        InstallInnodb="y"
        ;;
    [nN][oO]|[nN])
        echo "将不启用 InnoDB 存储引擎！"
        InstallInnodb="n"
        ;;
    *)
        echo "使用默认项：启用 InnoDB 存储引擎。"
        InstallInnodb="y"
        ;;
    esac

    # 后续下载和安装使用已验证的目标分支。

    echo "=================================================="
    echo "即将把 MySQL 升级到 ${mysql_version}"
    echo "=================================================="

    Press_Start || exit 1

    echo "============================ 检查文件 ============================"
    cd "${cur_dir}/src" || return 1

    mode=source
    [ "${Bin}" = "y" ] && mode=bin
    # MySQL 未提供机器可读的官方校验文件，因此使用静态 SHA256 清单。
    # Download_Verified 对新下载和本地缓存均执行校验，清单缺失时停止升级。
    if ! Download_DB_Verified mysql "${mysql_version}" "${mode}"; then
        echo "输入的 MySQL 版本为：${mysql_version}"
        Echo_Red "错误！MySQL ${mysql_version} 下载或校验失败。"
        sleep 5
        exit 1
    fi
    Check_Openssl
    if [ "${Bin}" != "y" ]; then
        Echo_Blue "正在安装依赖包..."
        . ${cur_dir}/include/only.sh
        DB_Dependent
    fi
    echo "============================ 文件检查结束 ========================"

    Database_Upgrade mysql "${mysql_version}" "${mode}"
}
