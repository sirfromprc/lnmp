#!/usr/bin/env bash

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin" "${work}/out"

cat > "${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${!#}"
case "${UPSTREAM_STUB_MODE:-ok}:${url}" in
error:*mysql*) exit 7 ;;
*:*/mysql-8.4.8.tar.gz|*:*/mysql-8.4.8-linux-glibc2.17-x86_64.tar.xz)
    printf '206'; exit 0 ;;
*:*/mysql-8.0.47.tar.gz)
    printf '206'; exit 0 ;;
*:*/mysql-*)
    printf '404'; exit 0 ;;
esac
exit 7
STUB
chmod +x "${work}/bin/curl"

if PATH="${work}/bin:${PATH}" OUT_DIR="${work}/out" \
   bash t/check_upstream.sh mysql >/dev/null 2>&1; then
    if grep -q $'^MySQL_8.4\t8.4.7\t8.4.8\tAUTO$' "${work}/out/bumps.tsv" &&
       ! grep -q '^MySQL_8.0' "${work}/out/bumps.tsv"; then
        ok 'MySQL 只有源码、没有二进制时不提议升级'
    else
        bad 'MySQL 源码与二进制必须同时存在'
    fi
else
    bad 'MySQL 正常探测不应失败'
fi

rm -rf "${work}/out"; mkdir -p "${work}/out"
if PATH="${work}/bin:${PATH}" OUT_DIR="${work}/out" UPSTREAM_STUB_MODE=error \
   bash t/check_upstream.sh mysql >/dev/null 2>&1; then
    bad '上游取数失败仍返回 0'
else
    ok '上游取数失败返回非零'
fi

# lua 全家桶：resty-core 侧取数失败不能被写成"上游还没有配套版本"这个结论。
# 两者都表现为找不到匹配版本，但取数失败是检查没做成，必须让退出码非零。
cat > "${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${!#}"
echo "${url}" >> "${CURLLOG}"
case "${LUA_STUB_MODE:-tags_fail}:${url}" in
*:*lua-nginx-module/tags*)  printf '[{"name":"v0.10.32"},{"name":"v0.10.31"}]'; exit 0 ;;
tags_fail:*lua-resty-core/tags*) exit 7 ;;
base_fail:*lua-resty-core/tags*) printf '[{"name":"v0.1.34"}]'; exit 0 ;;
base_fail:*base.lua*) exit 7 ;;
esac
exit 7
STUB
chmod +x "${work}/bin/curl"

for mode in tags_fail base_fail; do
    rm -rf "${work}/out"; mkdir -p "${work}/out"
    : > "${work}/curl.log"
    if PATH="${work}/bin:${PATH}" OUT_DIR="${work}/out" CURLLOG="${work}/curl.log" \
       LUA_STUB_MODE="${mode}" bash t/check_upstream.sh lua >/dev/null 2>&1; then
        bad "lua 组 ${mode}：取数失败仍返回 0"
    else
        ok "lua 组 ${mode}：取数失败返回非零"
    fi
    if grep -q '尚未找到声明配套的 lua-resty-core' "${work}/out/report.md" 2>/dev/null; then
        bad "lua 组 ${mode}：取数失败被写成了'上游没有配套版本'的结论"
    else
        ok "lua 组 ${mode}：未把取数失败写成上游结论"
    fi
done

# check_misc 内各组件互不阻断：前一个取数失败时后一个必须照样发请求，
# 否则报告里区分不出"没有新版"和"根本没查"。
cat > "${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${!#}"
echo "${url}" >> "${CURLLOG}"
case "${url}" in
*downloads.apache.org*)     exit 7 ;;
*redis/redis/tags*)         printf '[{"name":"8.10.0"}]'; exit 0 ;;
*memcached/memcached/tags*) printf '[{"name":"1.6.39"}]'; exit 0 ;;
esac
exit 7
STUB
chmod +x "${work}/bin/curl"
rm -rf "${work}/out"; mkdir -p "${work}/out"; : > "${work}/curl.log"
if PATH="${work}/bin:${PATH}" OUT_DIR="${work}/out" CURLLOG="${work}/curl.log" \
   bash t/check_upstream.sh apache redis memcached >/dev/null 2>&1; then
    bad 'check_misc：Apache 取数失败仍返回 0'
else
    if grep -q 'redis/redis' "${work}/curl.log" &&
       grep -q 'memcached/memcached' "${work}/curl.log"; then
        ok 'check_misc：前一个组件失败不影响后续组件的检查'
    else
        bad 'check_misc：Apache 失败后 redis/memcached 根本没被检查'
    fi
fi

pinned=$(sed -n '/^### 故意不查的（PINNED）/,$p' t/check_upstream.sh)
for key in APR_Ver APR_Util_Ver Freetype_New_Ver Libiconv_Ver Libzip_Ver \
           NgxDevelKit NgxFancyIndex_Ver NgxBrotli_Ver PHP8Memcache_Ver \
           PHPSodium_Ver PHPApcu_Bc_Ver PHPMemcache_Ver PHPMemcached_Ver \
           LuaCjson LuaRestyLock LuaRestyString LuaRestyRedis LuaRestyMysql \
           LuaRestyUpload LuaRestyWebsocket LuaRestyDns LuaRestyMemcached \
           LuaRestyLimitTraffic; do
    grep -q "${key}" <<< "${pinned}" || bad "${key} 未列入 PINNED"
done
[ ${fail} -eq 0 ] && ok '原未覆盖版本变量均已列入 PINNED'

if grep -q "gh_latest gperftools/gperftools '\^gperftools-" t/check_upstream.sh &&
   grep -q 'latest="${latest#gperftools-}"' t/check_upstream.sh; then
    ok 'gperftools 使用实际 tag 前缀取数'
else
    bad 'gperftools tag 解析仍与上游命名不符'
fi

if grep -Fq "gh_latest libunwind/libunwind '^1\\.[0-9]+" t/check_upstream.sh; then
    ok 'libunwind 只跟踪 1.x 发布线'
else
    bad 'libunwind 仍可能跨主版本自动升级'
fi

exit ${fail}
