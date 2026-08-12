#!/usr/bin/env bash
#
# t/test_db_port.sh - Get_Actual_DB_Port 的取值与退回行为
#
# 背景：lnmp.conf 写的是 DB_Port="${DB_Port:-3306}"，装主栈时可以用环境变量
# 指定别的端口，该值只进 /etc/my.cnf，不回写 lnmp.conf。事后补装或升级
# phpMyAdmin 时环境变量已不在，照抄 lnmp.conf 会把端口写错，而 config.inc.php
# 走 127.0.0.1 的 TCP 连接，端口错了直接连不上库。
#
# 本测试用替身配置文件覆盖各种取值情形，不读也不改真实的 /etc/my.cnf。

cd "$(dirname "$0")/.." || exit 1

# 只取 Get_Actual_DB_Port 的定义，避免加载 main.sh 的其余部分
eval "$(sed -n '/^Get_Actual_DB_Port()/,/^}/p' include/main.sh)"
if ! declare -f Get_Actual_DB_Port >/dev/null; then
    echo "FAIL 未能从 include/main.sh 取到 Get_Actual_DB_Port 定义"
    exit 1
fi

DB_Port='3306'      # 模拟 lnmp.conf 的默认值
fail=0
work=$(mktemp -d) || exit 1
trap 'rm -rf "${work}"' EXIT

# run <用例> <期望端口> <期望返回码> <配置文件内容；- 表示不建文件>
run()
{
    local desc="$1" want_port="$2" want_rc="$3" content="$4"
    local conf="${work}/my.cnf" got rc
    rm -f "${conf}"
    [ "${content}" = '-' ] || printf '%b' "${content}" > "${conf}"
    got=$(Get_Actual_DB_Port "${conf}")
    rc=$?
    if [ "${got}" = "${want_port}" ] && [ "${rc}" -eq "${want_rc}" ]; then
        printf 'ok   %-44s -> %s (rc=%s)\n' "${desc}" "${got}" "${rc}"
    else
        printf 'FAIL %-44s -> %s (rc=%s)，期望 %s (rc=%s)\n' \
            "${desc}" "${got}" "${rc}" "${want_port}" "${want_rc}"
        fail=1
    fi
}

run '[mysqld] 与 [client] 不同时取 [mysqld]' 3307 0 \
    '[client]\nport        = 3306\nsocket      = /tmp/mysql.sock\n\n[mysqld]\nport        = 3307\nsocket      = /tmp/mysql.sock\n'
run '只有 [client] 段时退回 lnmp.conf'       3306 1 '[client]\nport = 3399\n'
run '值后带行内注释'                          3307 0 '[mysqld]\nport = 3307  # 自定义\n'
run '等号两侧多余空白'                        3308 0 '[mysqld]\nport\t=\t3308\n'
run '段名带空白'                              3309 0 '[ mysqld ]\nport = 3309\n'
run '同段内重复出现时取最后一条'              3310 0 '[mysqld]\nport = 3305\nport = 3310\n'
run '[mysqld] 之后的其它段不干扰'             3311 0 '[mysqld]\nport = 3311\n\n[mysqldump]\nport = 3399\n'
run '配置文件不存在时退回 lnmp.conf'          3306 1 '-'
run '空文件退回 lnmp.conf'                    3306 1 ''
run '非数字端口退回 lnmp.conf'                3306 1 '[mysqld]\nport = abc\n'
run '越界端口退回 lnmp.conf'                  3306 1 '[mysqld]\nport = 99999\n'
run '端口为 0 退回 lnmp.conf'                 3306 1 '[mysqld]\nport = 0\n'
run 'port 只是别的选项的前缀时不误取'         3306 1 '[mysqld]\nreport_host = 10.0.0.1\n'

exit ${fail}
