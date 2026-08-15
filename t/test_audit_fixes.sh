#!/usr/bin/env bash

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0
fail=0
tmp=$(mktemp -d) || exit 1

ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
check()
{
    local name="$1"; shift
    if "$@"; then ok "${name}"; else bad "${name}"; fi
}

cleanup() { rm -rf "${tmp}"; }

# 加载备份函数但不执行命令行入口；随后覆盖它注册的 EXIT trap。
# shellcheck disable=SC1090
. <(sed '/^Main "\$@"$/d' tools/lnmp-backup.sh)
trap cleanup EXIT
Log_File="${tmp}/backup.log"

if Tar_Dir "${tmp}/missing-site" "${tmp}/missing.tar.gz" >/dev/null 2>&1; then
    bad "缺失网站目录必须让备份失败"
else
    ok "缺失网站目录必须让备份失败"
fi

Remote_Dir=backup
Remote_Port=22
Remote_Host=example.invalid
Remote_User=test
Remote_Protocol=ftp
Curl_Ftp() { printf '20260811-010101\n20260811-020202\n'; }
Sftp_Run() { return 91; }
out=$(List_Remote_Batches db)
check "FTP list 使用 Curl_Ftp" test "${out}" = $'20260811-010101\n20260811-020202'

Remote_Protocol=ftps
Curl_Ftp() { printf '20260811-025252\n'; }
out=$(List_Remote_Batches db)
check "FTPS list 使用 Curl_Ftp" test "${out}" = '20260811-025252'

Remote_Protocol=sftp
Curl_Ftp() { return 92; }
Sftp_Run() { cat >/dev/null; printf 'backup/db/20260811-030303\n'; }
out=$(List_Remote_Batches db)
check "SFTP list 使用 Sftp_Run" test "${out}" = '20260811-030303'

if grep -q -- '--defaults-extra-file' tools/lnmp-backup.sh; then
    bad "备份不得读取会被 ~/.my.cnf 覆盖的 defaults-extra-file"
else
    ok "备份使用独占 defaults-file"
fi

# 错误凭据必须在写 backup.conf 和启用 timer 之前失败；即使 HOME 下另有
# 有效 .my.cnf，也不能覆盖本次待校验的专用文件。
Conf_Dir="${tmp}/etc"
Conf_File="${Conf_Dir}/backup.conf"
My_Cnf="${Conf_Dir}/backup-mysql.cnf"
State_Dir="${tmp}/state"
State_File="${State_Dir}/state"
Systemd_Service="${tmp}/lnmp-backup.service"
Systemd_Timer="${tmp}/lnmp-backup.timer"
Cron_File="${tmp}/lnmp-backup.cron"
mkdir -p "${tmp}/home"
HOME="${tmp}/home"
printf '[client]\npassword=valid\n' > "${HOME}/.my.cnf"
chmod 600 "${HOME}/.my.cnf"
cat > "${tmp}/mysql" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --defaults-file=*) cfg=${1#*=} ;;
    *) exit 90 ;;
esac
grep -q "password='bad'" "${cfg}" && exit 1
exit 0
EOF
chmod +x "${tmp}/mysql"
id() { printf '0\n'; }
Discover_Sites() { return 0; }
Find_Mysql_Client() { printf '%s' "${tmp}/mysql"; }
Write_Systemd_Unit() { : > "${Systemd_Timer}"; }

if printf 'y\nbad\n3\n' | Cmd_Init >/dev/null 2>&1; then
    bad "错误数据库凭据必须让 backup init 返回失败"
elif [ -e "${Conf_File}" ] || [ -e "${My_Cnf}" ] || [ -e "${Systemd_Timer}" ]; then
    bad "错误数据库凭据不得留下配置或 timer"
else
    ok "错误数据库凭据 fail-fast 且无副作用"
fi

restore_block=$(sed -n '/^Cmd_Restore()/,/^}/p' tools/lnmp-backup.sh)
test_block=$(sed -n '/^Cmd_Test()/,/^}/p' tools/lnmp-backup.sh)
if printf '%s' "${restore_block}" | grep -q 'pipe_st=("${PIPESTATUS\[@\]}")' \
   && printf '%s' "${restore_block}" | grep -q 'gz_rc=' \
   && printf '%s' "${test_block}" | grep -q 'pipe_st=("${PIPESTATUS\[@\]}")' \
   && printf '%s' "${test_block}" | grep -q 'gz_rc='; then
    ok "恢复与试恢复同时检查 gzip/mysql 管道状态"
else
    bad "恢复或试恢复缺少完整管道状态检查"
fi

# OpenResty 显式配置判断与动态模块清理。
cur_dir="${tmp}"
OpenResty_Custom_Modules=()
OpenResty_Modules_Options=""
OpenResty_Custom_Lualib=""
OpenResty_Opm_Packages=()
OpenResty_Luarocks_Packages=()
Echo_Red() { :; }
# shellcheck disable=SC1091
. include/openresty_modules.sh

OpenResty_Custom_Lualib="${tmp}/lualib"
check "自定义 Lua 路径算显式配置" OR_Modules_Configured
OpenResty_Custom_Lualib=""
OpenResty_Opm_Packages=(ledgetech/lua-resty-http)
check "opm 包算显式配置" OR_Modules_Configured
OpenResty_Opm_Packages=()
OpenResty_Luarocks_Packages=(luafilesystem)
check "luarocks 包算显式配置" OR_Modules_Configured

OR_Build_Conf="${tmp}/openresty-build.conf"
cat > "${OR_Build_Conf}" <<'EOF'
OpenResty_Custom_Lualib=/persisted/lualib
OpenResty_Custom_Modules=()
OpenResty_Opm_Packages=(persisted/package)
OpenResty_Luarocks_Packages=()
OpenResty_Modules_Options=''
EOF
OpenResty_Custom_Lualib="${tmp}/current-lualib"
OpenResty_Opm_Packages=()
OpenResty_Luarocks_Packages=()
if OR_Modules_Load_Persisted >/dev/null \
   && [ "${OpenResty_Custom_Lualib}" = "${tmp}/current-lualib" ] \
   && [ "${#OpenResty_Opm_Packages[@]}" -eq 0 ]; then
    ok "当前显式 Lua 配置不被持久化旧值覆盖"
else
    bad "当前显式 Lua 配置被持久化旧值覆盖"
fi

persist_blocker="${tmp}/persist-blocker"
touch "${persist_blocker}"
OR_Build_Conf="${persist_blocker}/openresty-build.conf"
if OR_Modules_Persist >/dev/null 2>&1; then
    bad "OpenResty 配置持久化失败必须返回非零"
else
    ok "OpenResty 配置持久化失败返回非零"
fi

OR_Prefix="${tmp}/openresty"
OR_Built_Modules_File="${tmp}/built-modules"
mkdir -p "${OR_Prefix}/nginx/conf" "${OR_Prefix}/nginx/modules"
touch "${OR_Prefix}/nginx/modules/old.so" \
      "${OR_Prefix}/nginx/modules/new.so" \
      "${OR_Prefix}/nginx/modules/manual.so"
printf 'load_module modules/old.so;\n' > "${OR_Prefix}/nginx/conf/load_modules.conf"
printf 'new.so\n' > "${OR_Built_Modules_File}"
if OR_Write_Load_Modules_Conf \
   && [ ! -e "${OR_Prefix}/nginx/modules/old.so" ] \
   && [ -e "${OR_Prefix}/nginx/modules/manual.so" ] \
   && grep -q '^load_module modules/new.so;' "${OR_Prefix}/nginx/conf/load_modules.conf" \
   && ! grep -q 'manual.so' "${OR_Prefix}/nginx/conf/load_modules.conf"; then
    ok "只加载本次动态模块并清理旧受管 .so"
else
    bad "动态模块清单或旧 .so 清理错误"
fi

if grep -q 'if ! OR_Modules_Persist' include/openresty.sh \
   && grep -q 'if ! OR_Modules_Persist' include/upgrade_openresty.sh; then
    ok "OpenResty 安装与升级检查持久化返回码"
else
    bad "OpenResty 持久化失败仍可能报告成功"
fi
check "opm 示例使用真实包名" grep -q 'ledgetech/lua-resty-http' lnmp.conf

# Telegram 配置权限和 Token 读取方式。
# shellcheck disable=SC1091
. tools/lnmp-tgnotice.sh
TG_Conf_File="${tmp}/notify.conf"
printf 'TG_Enable=0\n' > "${TG_Conf_File}"
chmod 644 "${TG_Conf_File}"
if _tg_load_conf >/dev/null 2>&1; then
    bad "Telegram 必须拒绝 644 配置"
else
    ok "Telegram 拒绝 644 配置"
fi
chmod 600 "${TG_Conf_File}"
unset TG_Enable TG_Bot_Token TG_Chat_Id TG_Parse_Mode TG_Timeout TG_Retry TG_Disable_Preview
check "Telegram 接受 600 配置" _tg_load_conf
check "Bot Token 无回显读取" grep -q 'read -r -s token' tools/lnmp-tgnotice.sh

if grep -q 'kill -TERM "${Tmp_Mysqld_Pid}"' tools/reset_mysql_root_password.sh \
   && ! grep -q 'mysqladmin --socket="${Tmp_Sock}" shutdown' tools/reset_mysql_root_password.sh; then
    ok "数据库密码重置用已核验 PID 正常关闭临时实例"
else
    bad "数据库密码重置仍可能用无凭据 mysqladmin 关闭临时实例"
fi

echo
echo "通过 ${pass} 项，失败 ${fail} 项。"
[ "${fail}" -eq 0 ]
