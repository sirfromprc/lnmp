#!/usr/bin/env bash
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "错误：必须使用 root 用户运行此脚本。"
    exit 1
fi

cur_dir=$(cd "$(dirname "$0")/.." && pwd)
# 脚本被复制到源码目录之外执行时，上面推导出的 cur_dir 是错的，加载会失败。
# 不检查的话后面每个公共函数都会 command not found，却还继续往下跑。
if [ ! -f "${cur_dir}/include/main.sh" ]; then
    echo "错误：找不到 ${cur_dir}/include/main.sh。"
    echo "请在 LNMP 源码目录内执行本脚本，例如 ./tools/$(basename "$0")。"
    exit 1
fi
. "${cur_dir}/include/main.sh"

clear
Print_Banner \
    "LNMP PHP 禁用函数调整工具" \
    "修改 PHP 的 disable_functions 配置" \
    "用法：./remove_disable_function.sh"
        
    ver=""
    echo "1: 删除全部 PHP 禁用函数（默认）"
    echo "2: 仅从禁用列表中删除 scandir"
    echo "3: 仅从禁用列表中删除 exec"
    read -p "请选择 [1-3]（默认 1）: " ver
    if [ "$ver" = "" ]; then
        ver="1"
    fi

    if [ "$ver" = "1" ]; then
        echo "将删除全部 PHP 禁用函数。"
    elif [ "$ver" = "2" ]; then 
        echo "将允许 PHP 使用 scandir 函数。"
    elif [ "$ver" = "3" ]; then
        echo "将允许 PHP 使用 exec 函数。"
    fi

    get_char()
    {
    SAVEDSTTY=`stty -g`
    stty -echo
    stty cbreak
    dd if=/dev/tty bs=1 count=1 2> /dev/null
    stty -raw
    stty echo
    stty $SAVEDSTTY
    }
    echo ""
    echo "按任意键开始，或按 Ctrl+C 取消..."
    char=`get_char`


function remove_all_disable_function()
{
    sed -i 's/disable_functions =.*/disable_functions =/g' /usr/local/php/etc/php.ini
}

function remove_scandir_function() 
{
    sed -i 's/,scandir//g' /usr/local/php/etc/php.ini
}

function remove_exec_function()
{
    sed -i 's/,exec//g' /usr/local/php/etc/php.ini
}

if [ "$ver" = "1" ]; then
    remove_all_disable_function
elif [ "$ver" = "2" ]; then 
    remove_scandir_function
elif [ "$ver" = "3" ]; then
    remove_exec_function
fi

if [ -s /etc/init.d/httpd ] && [ -s /usr/local/apache ]; then
echo "正在重启 Apache..."
# init 脚本自己会把动作转成 `httpd -k <动作>`，这里再传一个 -k，
# case 就匹配不到任何分支，只打印一行用法 —— Apache 实际从未被重启。
/etc/init.d/httpd restart
else
echo "正在重启 PHP-FPM..."
/etc/init.d/php-fpm restart
fi

Print_Banner "PHP 禁用函数配置调整完成"
