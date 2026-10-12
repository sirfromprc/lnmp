#!/usr/bin/env bash

Upgrade_MariaDB()
{
    local config_bin mode

    Check_DB
    if [ "${Is_MySQL}" = "y" ]; then
        Echo_Red "当前数据库是 MySQL，不能运行 MariaDB 升级脚本。"
        exit 1
    fi

    Verify_DB_Password

    config_bin=$(First_Executable /usr/local/mariadb/bin/mariadb_config /usr/local/mariadb/bin/mysql_config) || exit 1
    cur_mariadb_version=$("${config_bin}" --version)
    mariadb_version=""
    echo "当前 MariaDB 版本：${cur_mariadb_version}"
    echo "可在 https://downloads.mariadb.org/ 查看可用版本号。"
    Echo_Yellow "请输入目标 MariaDB 版本（10.11.x / 11.4.x / 11.8.x / 12.3.x）。"
    read -p "版本号（例如 11.8.8）：" mariadb_version
    if [ "${mariadb_version}" = "" ]; then
        echo "错误：必须输入 MariaDB 版本号！"
        exit 1
    fi
    Check_Version_String "${mariadb_version}" "MariaDB 版本号" || exit 1

    mariadb_short_version=$(echo "${mariadb_version}" | cut -d. -f1-2)
    case "${mariadb_short_version}" in
    10.11|11.4|11.8|12.3)
        ;;
    *)
        Echo_Red "不支持升级到 MariaDB ${mariadb_version}。"
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
    echo "即将把 MariaDB ${cur_mariadb_version} 升级到 ${mariadb_version}"
    echo "====================================================================="

    if [ -s /usr/local/include/jemalloc/jemalloc.h ] && lsof -n|grep "libjemalloc.so"|grep -q "mysqld"; then
        MariaDBMAOpt=''
    elif [ -s /usr/local/include/gperftools/tcmalloc.h ] && lsof -n|grep "libtcmalloc.so"|grep -q "mysqld"; then
        MariaDBMAOpt="-DCMAKE_EXE_LINKER_FLAGS='-ltcmalloc' -DWITH_SAFEMALLOC=OFF"
    else
        MariaDBMAOpt=''
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

    Database_Upgrade mariadb "${mariadb_version}" "${mode}"
}
