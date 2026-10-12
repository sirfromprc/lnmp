#!/usr/bin/env bash

Upgrade_MySQL2MariaDB()
{
    local mode accounts incompat reset ans


    Check_DB
    if [ "${Is_MySQL}" = "n" ]; then
        Echo_Red "当前数据库已经是 MariaDB，不能运行 MySQL 到 MariaDB 的迁移脚本。"
        exit 1
    fi
    Verify_DB_Password

    cur_mysql_version=`/usr/local/mysql/bin/mysql_config --version`
    mariadb_version=""
    echo "当前 MySQL 版本：${cur_mysql_version}"
    echo "可在 https://downloads.mariadb.org/ 查看可用版本号。"
    Echo_Yellow "请输入目标 MariaDB 版本（10.11.x / 11.4.x / 11.8.x / 12.3.x）。"
    read -p "版本号（例如 11.8.8）：" mariadb_version
    if [ "${mariadb_version}" = "" ]; then
        echo "错误：必须输入 MariaDB 版本号！"
        exit 1
    fi
    Check_Version_String "${mariadb_version}" "MariaDB 版本号" || exit 1

    # 停止或移动 MySQL 前校验目标 MariaDB 分支，避免无效版本影响现有实例。
    mariadb_short_version=$(echo "${mariadb_version}" | cut -d. -f1-2)
    case "${mariadb_short_version}" in
    10.11|11.4|11.8|12.3)
        ;;
    *)
        Echo_Red "不支持迁移到 MariaDB ${mariadb_version}。"
        Echo_Red "本包只保留 10.11 / 11.4 / 11.8 / 12.3 四条 LTS 线，与安装侧一致。"
        Echo_Red "数据库未做任何改动。"
        exit 1
        ;;
    esac

    if [[ "${DB_ARCH}" = "x86_64" || "${DB_ARCH}" = "aarch64" ]]; then
        read -p "是否使用官方通用二进制包 [Y/n]（默认 y，推荐）：" Bin
        case "${Bin}" in
        [nN][oO]|[nN])
            echo "将使用源码安装 MariaDB ${mariadb_version}。"
            Bin="n"
            ;;
        *)
            echo "将使用官方通用二进制包安装 MariaDB ${mariadb_version}。"
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
    esac

    echo "====================================================================="
    echo "即将把 MySQL ${cur_mysql_version} 迁移到 MariaDB ${mariadb_version}"
    echo "====================================================================="

    if [ -s /usr/local/include/jemalloc/jemalloc.h ] && lsof -n|grep "libjemalloc.so"|grep -q "mysqld"; then
        MariaDBMAOpt=''
    elif [ -s /usr/local/include/gperftools/tcmalloc.h ] && lsof -n|grep "libtcmalloc.so"|grep -q "mysqld"; then
        MariaDBMAOpt="-DCMAKE_EXE_LINKER_FLAGS='-ltcmalloc' -DWITH_SAFEMALLOC=OFF"
    else
        MariaDBMAOpt=''
    fi

    if ! accounts=$(Database_Migrate_Accounts /usr/local/mysql/bin/mysql); then
        Echo_Red "读取 MySQL 账号失败，数据库未做任何改动。"
        exit 1
    fi
    reset=''
    incompat=$(printf '%s\n' "${accounts}" | awk -F'\t' 'NF && $3 != "mysql_native_password" {print "  " $1 "@" $2 "（" $3 "）"}')
    if [ -n "${incompat}" ]; then
        Echo_Yellow "以下账号的口令哈希 MariaDB 无法识别，迁移后将改为随机口令："
        printf '%s\n' "${incompat}"
        Echo_Yellow "新口令写入 /root/mysql2mariadb_passwords<时间>.txt（仅 root 可读），迁移后需同步修改站点的数据库配置。"
        if [ "${LNMP_M2M_Reset_Passwords:-}" != yes ]; then
            ans=''
            read -r -p "确认改为随机口令并继续迁移 [y/N]：" ans || ans=''
            case "${ans}" in
            [yY]|[yY][eE][sS]) ;;
            *)
                Echo_Red "未确认，数据库未做任何改动。非交互执行可设置 LNMP_M2M_Reset_Passwords=yes。"
                exit 1
                ;;
            esac
        fi
        reset='reset-passwords'
    fi

    Press_Start || exit 1

    echo "============================ 检查文件 ============================"
    cd "${cur_dir}/src" || return 1
    mode=source
    [ "${Bin}" = "y" ] && mode=bin
    # Download_Verified 对新下载和本地缓存统一核对上游公布的 SHA256。
    if ! Download_DB_Verified mariadb "${mariadb_version}" "${mode}"; then
        echo "输入的 MariaDB 版本为：${mariadb_version}"
        Echo_Red "错误！版本号不正确或无法从 MariaDB 镜像下载，请检查！"
        sleep 5
        exit 1
    fi
    echo "============================ 文件检查结束 ========================"

    Database_Migrate "${mariadb_version}" "${mode}" "${reset}"
}

