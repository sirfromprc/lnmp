# shellcheck shell=bash
# 管理命令 Nginx 适配层：按 Nginx 配置语法读写站点、证书与反向代理配置。
# cli_assemble.sh 把本文件并入 lnmp、lnmpa 的 Nginx 适配层标记行；lamp 的同名函数按 Apache 语法实现，在 conf/lamp。
# 本文件只含函数定义，不含顶层语句；站点目录等变量由栈入口定义。

Add_Dns_SSL()
{
    provider=$1
    if [ "${provider}" != "" ]; then
        dns_provider="dns_${provider}"
        # acme.sh 已安装时先核对插件，免得走完交互才报错。
        if [ -d /usr/local/acme.sh/dnsapi ] \
            && [ ! -s "/usr/local/acme.sh/dnsapi/dns_${provider}.sh" ]; then
            echo "未找到 DNS 服务商插件：${provider}。"
            exit 1
        fi
    else
        Echo_Red "DNS 手工验证模式无法自动续期，证书到期前必须手动续期。"
    fi

    Add_DNS_SSL_Site_Info_Menu
    info_rc=$?
    # 返回 2 表示已复用现有证书写完配置，本次不需要签发。
    [ "${info_rc}" = "2" ] && return 0
    [ "${info_rc}" = "0" ] || exit 1
    Add_DNS_SSL_Select_Menu
    Return_301_Menu

    Install_Check_Acme.sh || exit 1

    if [[ ! -s /usr/local/acme.sh/dnsapi/dns_${provider}.sh && "${provider}" != "" ]]; then
        echo "未找到 DNS 服务商插件：${provider}。"
        exit 1
    fi
    Acme_DNS_Cred_Block_Sync "${provider}"
    Acme_DNS_Cred_Snapshot "${provider}"
    Prompt_DNS_API_Credentials "${provider}" || exit 1

    # 泛域名已覆盖同级子域名，重复申请只会多一次 TXT 验证。
    cert_domains=$(Filter_Cert_Domains "${domain}" "${moredomain}")
    # acme.sh 按第一个 -d 建证书目录，主域名被泛域名取代时随之改变。
    cert_main="${cert_domains%% *}"
    # 泛域名不能直接做目录名，避免路径被通配符展开。
    cert_dir_name="${cert_main/#\*./_wildcard.}"
    cert_dir="/usr/local/nginx/conf/ssl/${cert_dir_name}"
    Backup_Cert_Dir "${cert_dir}" || return 1
    Note_Acme_Workdir "/usr/local/nginx/conf/ssl" "${cert_main}"
    # 泛域名带 *，拆分和传参期间关闭路径展开。
    local -a dns_domain_args=()
    set -f
    for i in ${cert_domains};do
        dns_domain_args+=(-d "${i}")
    done
    set +f
    echo "证书域名：${cert_domains}"

    if [ "${dns_ssl_choice}" == "1" ]; then
        ca_server="letsencrypt"
    elif [ "${dns_ssl_choice}" == "2" ]; then
        ca_server="zerossl"
    fi

    echo "正在使用 ${ca_server} 签发 SSL 证书..."
    if [ "${provider}" != "" ]; then
        /usr/local/acme.sh/acme.sh ${acme_sh_sudo} --server ${ca_server} --issue "${dns_domain_args[@]}" --dns ${dns_provider} --reloadcmd "/etc/init.d/nginx reload"
        lets_status=$?
    else
        /usr/local/acme.sh/acme.sh ${acme_sh_sudo} --server ${ca_server} --issue "${dns_domain_args[@]}" --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please
        Echo_Yellow "请按上方显示的内容添加 TXT 记录。CA 只在验证时查询一次，"
        echo
        Echo_Yellow "记录尚未传播就继续会验证失败，可先用 dig TXT _acme-challenge.<域名> 自查。"
        echo
        # 固定倒计时既可能不够用，也可能白等；交互执行时由用户决定何时继续。
        if [ -t 0 ]; then
            Press_Any_Key_Or_Line "记录已生效后按任意键继续验证，按 Ctrl+C 取消..." || return 1
        else
            Echo_Yellow "非交互执行，等待 120 秒后继续验证。"
            echo
            Sleep_Sec 120
        fi
        /usr/local/acme.sh/acme.sh ${acme_sh_sudo} --renew "${dns_domain_args[@]}" --yes-I-know-dns-manual-mode-enough-go-ahead-please
        lets_status=$?
    fi

    # acme.sh 默认签发 ECC 证书，须显式安装到站点证书目录。
    if [ "${lets_status}" = 0 ]; then
        Acme_DNS_Cred_Save "${cert_main}" "${provider}"
        mkdir -p "${cert_dir}" || { Restore_Cert_Dir; return 1; }
        /usr/local/acme.sh/acme.sh ${acme_sh_sudo} --install-cert -d "${cert_main}" --ecc \
            --key-file "${cert_dir}/${cert_dir_name}.key" \
            --fullchain-file "${cert_dir}/fullchain.cer" \
            --reloadcmd "/etc/init.d/nginx reload"
        lets_status=$?
    fi

    if [ "${lets_status}" != 0 ]; then
        Restore_Cert_Dir
        Cleanup_Failed_Acme_Workdir
        Echo_Red "SSL 证书签发失败。"
        return 1
    fi

    ssl_certificate="${cert_dir}/fullchain.cer"
    ssl_certificate_key="${cert_dir}/${cert_dir_name}.key"
    if [ "${Wildcard_Mode}" = "y" ]; then
        # 证书已签发成功，个别站点写配置失败不回滚证书目录；但一个站点都没写
        # 成功时本次目标未达成，必须返回失败，否则自动化会以为 HTTPS 已上线。
        if ! Install_Cert_To_Sites "${Wildcard_Site_List}"; then
            Discard_Cert_Backup
            Echo_Red "证书已签发并保存在 ${cert_dir}，但没有任何站点写入 HTTPS 配置。"
            Echo_Yellow "修正站点配置后重新执行 lnmp dnsssl ${provider}，输入同一个域名并选择复用现有证书。"
            echo
            return 1
        fi
    else
        Create_SSL_Config || { Restore_Cert_Dir; return 1; }
    fi
    Discard_Cert_Backup
    Print_Banner \
        "SSL 证书信息" \
        "域名：${cert_domains}" \
        "证书：${cert_dir}/fullchain.cer" \
        "私钥：${cert_dir}/${cert_dir_name}.key"
    Echo_Green "SSL 证书签发成功。"
}

Add_Dns_SSL_Only()
{
    provider=$1
    if [ "${provider}" != "" ]; then
        dns_provider="dns_${provider}"
        # acme.sh 已安装时先核对插件，免得走完交互才报错。
        if [ -d /usr/local/acme.sh/dnsapi ] \
            && [ ! -s "/usr/local/acme.sh/dnsapi/dns_${provider}.sh" ]; then
            echo "未找到 DNS 服务商插件：${provider}。"
            exit 1
        fi
    else
        Echo_Red "DNS 手工验证模式无法自动续期，证书到期前必须手动续期。"
    fi

    Add_DNS_SSL_Only_Info_Menu
    info_rc=$?
    # 返回 2 表示已有可用证书且用户选择不重签。
    [ "${info_rc}" = "2" ] && return 0
    [ "${info_rc}" = "0" ] || exit 1

    Install_Check_Acme.sh || exit 1

    if [[ ! -s /usr/local/acme.sh/dnsapi/dns_${provider}.sh && "${provider}" != "" ]]; then
        echo "未找到 DNS 服务商插件：${provider}。"
        exit 1
    fi
    Acme_DNS_Cred_Block_Sync "${provider}"
    Acme_DNS_Cred_Snapshot "${provider}"
    Prompt_DNS_API_Credentials "${provider}" || exit 1

    # 泛域名已覆盖同级子域名，重复申请只会多一次 TXT 验证。
    cert_domains=$(Filter_Cert_Domains "${domain}" "${moredomain}")
    # acme.sh 按第一个 -d 建证书目录，主域名被泛域名取代时随之改变。
    cert_main="${cert_domains%% *}"
    # 泛域名不能直接做目录名，避免路径被通配符展开。
    cert_dir_name="${cert_main/#\*./_wildcard.}"
    cert_dir="/usr/local/nginx/conf/ssl/${cert_dir_name}"
    Backup_Cert_Dir "${cert_dir}" || return 1
    Note_Acme_Workdir "/usr/local/nginx/conf/ssl" "${cert_main}"
    # 泛域名带 *，拆分和传参期间关闭路径展开。
    local -a dns_domain_args=()
    set -f
    for i in ${cert_domains};do
        dns_domain_args+=(-d "${i}")
    done
    set +f
    echo "证书域名：${cert_domains}"

    if [ "${dns_ssl_choice}" == "1" ]; then
        ca_server="letsencrypt"
    elif [ "${dns_ssl_choice}" == "2" ]; then
        ca_server="zerossl"
    fi

    echo "正在使用 ${ca_server} 签发 SSL 证书..."
    if [ "${provider}" != "" ]; then
        # onlyssl 不写站点配置，签发与续期都不重载 Web 服务。
        /usr/local/acme.sh/acme.sh ${acme_sh_sudo} --server ${ca_server} --issue "${dns_domain_args[@]}" --dns ${dns_provider}
        lets_status=$?
    else
        /usr/local/acme.sh/acme.sh ${acme_sh_sudo} --server ${ca_server} --issue "${dns_domain_args[@]}" --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please
        Echo_Yellow "请按上方显示的内容添加 TXT 记录。CA 只在验证时查询一次，"
        echo
        Echo_Yellow "记录尚未传播就继续会验证失败，可先用 dig TXT _acme-challenge.<域名> 自查。"
        echo
        # 固定倒计时既可能不够用，也可能白等；交互执行时由用户决定何时继续。
        if [ -t 0 ]; then
            Press_Any_Key_Or_Line "记录已生效后按任意键继续验证，按 Ctrl+C 取消..." || return 1
        else
            Echo_Yellow "非交互执行，等待 120 秒后继续验证。"
            echo
            Sleep_Sec 120
        fi
        /usr/local/acme.sh/acme.sh ${acme_sh_sudo} --renew "${dns_domain_args[@]}" --yes-I-know-dns-manual-mode-enough-go-ahead-please
        lets_status=$?
    fi

    # acme.sh 默认签发 ECC 证书，须显式安装到站点证书目录。
    if [ "${lets_status}" = 0 ]; then
        Acme_DNS_Cred_Save "${cert_main}" "${provider}"
        mkdir -p "${cert_dir}" || { Restore_Cert_Dir; return 1; }
        /usr/local/acme.sh/acme.sh ${acme_sh_sudo} --install-cert -d "${cert_main}" --ecc \
            --key-file "${cert_dir}/${cert_dir_name}.key" \
            --fullchain-file "${cert_dir}/fullchain.cer"
        lets_status=$?
    fi

    if [ "${lets_status}" != 0 ]; then
        Restore_Cert_Dir
        Cleanup_Failed_Acme_Workdir
        Echo_Red "SSL 证书签发失败。"
        return 1
    fi

    Discard_Cert_Backup
    Print_Banner \
        "SSL 证书信息" \
        "域名：${cert_domains}" \
        "证书：${cert_dir}/fullchain.cer" \
        "私钥：${cert_dir}/${cert_dir_name}.key" \
        "证书未写入任何站点配置，需要时自行引用。"
    Echo_Green "SSL 证书签发成功。"
}

Add_SSL_Menu()
{
    if [ "${info:-}" == "n" ]; then
        Add_SSL_Only_Info_Menu || return 1
    fi
    if [ "${domain}" = "default" ]; then
        echo "HTTP 验证要求本机公网 IPv4 的 80 端口可从公网访问。"
    else
        echo "HTTP 验证要求域名已解析到本机，且 80 端口可从公网访问。"
    fi
    echo "1: 使用自有 SSL 证书和私钥"
    echo "2: 使用 Let's Encrypt 签发 SSL 证书（HTTP 验证）"
    if [ "${domain}" != "default" ]; then
        echo "3: 使用 ZeroSSL 签发 SSL 证书（HTTP 验证）"
    fi
    while :;do
        if [ "${domain}" = "default" ]; then
            Echo_Yellow "请选择 [1-2]："
        else
            Echo_Yellow "请选择 [1-3]："
        fi
        Read_Input ssl_choice "证书来源选项"
        if [ "${ssl_choice}" == "1" ]; then
            while :;do
                Echo_Yellow "请输入 SSL 证书文件的完整路径: "
                Read_Input ssl_certificate "SSL 证书路径"
                if Check_Config_File_Path "${ssl_certificate}" "SSL 证书文件"; then
                    break
                fi
            done
            while :;do
                Echo_Yellow "请输入 SSL 私钥文件的完整路径: "
                Read_Input ssl_certificate_key "SSL 私钥路径"
                if Check_Config_File_Path "${ssl_certificate_key}" "SSL 私钥文件"; then
                    break
                fi
            done
            break
        elif [ "${ssl_choice}" == "2" ]; then
            Check_Acme_EMail
            break
        elif [[ "${domain}" != "default" && "${ssl_choice}" == "3" ]]; then
            if ! Check_ZeroSSL_Endpoint; then
                Read_YN use_le "是否改用 Let's Encrypt 签发 [Y/n]（默认 y）: " y "改用 Let's Encrypt"
                [ "${use_le}" = "y" ] && ssl_choice=2
            fi
            if [ "${ssl_choice}" = "3" ]; then
                Check_ZeroSSL_EMail
            else
                Check_Acme_EMail
            fi
            break
        else
            if [ "${domain}" = "default" ]; then
                Echo_Red "default 站点只支持自有证书或 Let's Encrypt IP 证书，请输入 1 或 2！"
            else
                Echo_Red "请输入 1、2 或 3。"
            fi
        fi
    done

    Return_301_Menu
}

# 证书目录是否仍被现存站点引用。泛域名证书常被多个站点共用，且各站点未必
# 引用目录里同一个文件，因此按目录而不是按文件路径判断。
Cert_Dir_In_Use()
{
    local dir="$1" f

    for f in "${Vhost_Conf_Dir}"/*.conf; do
        [ -s "${f}" ] || continue
        awk -v d="${dir}/" '
            ($1 == "ssl_certificate" || $1 == "ssl_certificate_key") {
                v = $2
                sub(/;$/, "", v)
                if (substr(v, 1, length(d)) == d) hit = 1
            }
            END { exit hit ? 0 : 1 }
        ' "${f}" && return 0
    done
    return 1
}

# 新站点声明的域名不能已被其它虚拟主机使用：重复的 server_name 不会让配置
# 测试失败，但请求仍由先加载的站点处理，新站点实际访问不到。
Check_Domain_Not_Taken()
{
    local names="$1" f taken=0 d

    [ -d "${Vhost_Conf_Dir}" ] || return 0
    for f in "${Vhost_Conf_Dir}"/*.conf; do
        [ -s "${f}" ] || continue
        for d in ${names}; do
            Vhost_Has_Domain "${f}" "${d}" || continue
            [ "${taken}" -eq 0 ] && Echo_Red "以下域名已被现有站点声明："
            Echo_Red "  ${d} -> ${f}"
            taken=1
        done
    done
    [ "${taken}" -eq 0 ] && return 0
    Echo_Yellow "请换一个域名，或先用 lnmp vhost del 删除占用它的站点。"
    echo
    return 1
}

# 反代后端地址：接受 主机:端口，缺少 scheme 时按 http 补全。校验通过后把
# 规范化结果写回 $1 指定的变量。字符集按 nginx proxy_pass 可接受的范围收紧，
# 挡住空格、分号和 $，避免输入改变指令边界或引入变量展开。
Check_Proxy_Backend()
{
    # 局部变量统一加前缀：调用方传进来的变量名不能被本函数的局部名遮蔽。
    local __var="$1" __val="${!1}" __port

    if [ -z "${__val}" ]; then
        Echo_Red "后端地址不能为空。"
        return 1
    fi
    case "${__val}" in
        http://*|https://*) ;;
        *) __val="http://${__val}" ;;
    esac
    if ! printf '%s' "${__val}" | grep -Eq \
         '^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'; then
        Echo_Red "后端地址格式不对，示例：127.0.0.1:3000 或 http://127.0.0.1:3000/api/"
        return 1
    fi
    __port=$(printf '%s' "${__val}" | sed -nE 's#^https?://[^/:]+:([0-9]+).*$#\1#p')
    if [ -n "${__port}" ] && { [ "${__port}" -lt 1 ] || [ "${__port}" -gt 65535 ]; }; then
        Echo_Red "端口不合法：${__port}"
        return 1
    fi
    printf -v "${__var}" '%s' "${__val}"
    return 0
}

# nginx 编译了 http_v3 模块时返回 0。
Nginx_Has_HTTP3()
{
    local v

    v=$(/usr/local/nginx/sbin/nginx -V 2>&1) || return 1
    [[ "${v}" == *--with-http_v3_module* ]]
}

# Default_Has_Quic <4|6>：default.conf 已启用对应协议族 443 的 quic reuseport 监听时返回 0。
# reuseport 在同一地址端口上只能声明一次，由 default 承担，业务站点只写 quic。
Default_Has_Quic()
{
    local addr='443'

    [ "$1" = 6 ] && addr='\[::\]:443'
    grep -Eq "^[[:space:]]*listen[[:space:]]+${addr}[[:space:]]+quic[[:space:]]+reuseport" \
        /usr/local/nginx/conf/vhost/default.conf 2>/dev/null
}

# HTTPS 与 HTTP 共用同一个 server 块：证书签发后把 443 监听和 SSL 指令插入
# 站点已有的 80 端口块，站点级规则只保留一份。
Create_SSL_Config()
{
    local vhost_conf="/usr/local/nginx/conf/vhost/${domain}.conf" backup
    local listen_frag ssl_frag insert_rc
    local ssl_listen='listen 443 ssl;' ssl_ipv6_listen='#listen [::]:443 ssl;'
    local quic_listen='' quic_ipv6_listen=''

    Check_Config_File_Path "${ssl_certificate}" "SSL 证书文件" || return 1
    Check_Config_File_Path "${ssl_certificate_key}" "SSL 私钥文件" || return 1
    if [ ! -s "${vhost_conf}" ]; then
        Echo_Red "未找到网站 ${domain} 的虚拟主机配置：${vhost_conf}"
        return 1
    fi
    if [ "${domain}" = "default" ]; then
        ssl_listen='listen 443 ssl default_server;'
        ssl_ipv6_listen='#listen [::]:443 ssl default_server ipv6only=on;'
    fi
    if [ "${enable_ipv6}" = "y" ]; then
        if [ "${domain}" = "default" ]; then
            ssl_ipv6_listen='listen [::]:443 ssl default_server ipv6only=on;'
        else
            ssl_ipv6_listen='listen [::]:443 ssl;'
        fi
    fi
    if ! Nginx_Has_HTTP3; then
        Echo_Yellow "当前 Nginx 未编译 http_v3 模块，本站点只启用 HTTP/2。"
    elif [ "${domain}" = "default" ]; then
        quic_listen='listen 443 quic reuseport default_server;'
        quic_ipv6_listen='#listen [::]:443 quic reuseport default_server ipv6only=on;'
        [ "${enable_ipv6}" = "y" ] && quic_ipv6_listen='listen [::]:443 quic reuseport default_server ipv6only=on;'
    elif Default_Has_Quic 4; then
        quic_listen='listen 443 quic;'
        quic_ipv6_listen='#listen [::]:443 quic;'
        [ "${enable_ipv6}" = "y" ] && Default_Has_Quic 6 && quic_ipv6_listen='listen [::]:443 quic;'
    else
        Echo_Yellow "default.conf 没有 443 的 quic reuseport 监听，本站点只启用 HTTP/2。"
    fi

    LNMP_Tmp_Init || return 1
    listen_frag=$(LNMP_Mktemp ssl-listen) || return 1
    ssl_frag=$(LNMP_Mktemp ssl-frag) || { rm -f "${listen_frag}"; return 1; }
    backup=$(LNMP_Mktemp ssl-vhost) || { rm -f "${listen_frag}" "${ssl_frag}"; return 1; }

    printf '    %s\n' "${ssl_listen}" "${ssl_ipv6_listen}" ${quic_listen:+"${quic_listen}" "${quic_ipv6_listen}"} \
        >"${listen_frag}"

    cat >"${ssl_frag}"<<EOF

    # SSL 配置--开始
    # Nginx 1.25.1 及以上使用独立的 http2 指令。明文端口的 h2c 由该端口默认
    # server 决定，default 站点配证书后 80 端口接受 h2c，浏览器不使用该方式。
    http2 on;

    ssl_certificate ${ssl_certificate};
    ssl_certificate_key ${ssl_certificate_key};
    # TLS 1.0 和 1.1 已被 RFC 8996 弃用。
    ssl_protocols TLSv1.2 TLSv1.3;
    # 仅保留基于 ECDHE 的 AEAD 套件，排除 3DES、静态 RSA、CBC 和需要 DH 参数的 DHE。
    # TLS 1.3 使用 OpenSSL 独立的默认套件配置。
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    # 由客户端选择套件，可优先使用设备具备硬件加速的算法。
    ssl_prefer_server_ciphers off;
    # 10 MB 会话缓存约可保存 4 万个握手结果，减少重复完整握手。
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 5m;
    # 关闭 session ticket，避免长期票据密钥泄露影响历史会话的前向保密。
    ssl_session_tickets off;

    # HSTS 会在有效期内强制浏览器使用 HTTPS。启用前须确认主域名和所有
    # 子域名均可持续提供有效证书，否则浏览器无法回退到 HTTP。
    #add_header Strict-Transport-Security "max-age=31536000" always;
EOF
    if [ -n "${quic_listen}" ]; then
        cat >>"${ssl_frag}"<<'EOF'

    # 浏览器先经 TCP 访问，按 Alt-Svc 改用 UDP 443 的 HTTP/3。
    # location 内另有 add_header 时不继承本行，需在该 location 中重复。
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
EOF
    fi

    if [ "${using_301}" = "y" ]; then
        cat >>"${ssl_frag}"<<EOF

    # HTTP 跳转到 HTTPS。判断放在 server 级，覆盖本站全部 location；
    # ACME 验证路径保留在 HTTP 上，否则续期无法完成。
    set \$to_https 0;
    if (\$scheme = http) { set \$to_https 1; }
    if (\$request_uri ~ "^/\\.well-known/") { set \$to_https 0; }
    if (\$to_https = 1) {
        return 301 https://\$host\$request_uri;
    }
EOF
    fi
    printf '    # SSL 配置--结束\n' >>"${ssl_frag}"

    if ! \cp -p "${vhost_conf}" "${backup}"; then
        rm -f "${listen_frag}" "${ssl_frag}" "${backup}"
        return 1
    fi
    if [ "${domain}" = "default" ] && ! Remove_SSL_Reject_Block "${vhost_conf}"; then
        Echo_Red "移除 default 的未知 SNI 拒绝块失败，未写入 HTTPS 配置。"
        \cp -p "${backup}" "${vhost_conf}"
        rm -f "${listen_frag}" "${ssl_frag}" "${backup}"
        return 1
    fi
    Insert_SSL_Into_VHost "${vhost_conf}" "${domain}" "${listen_frag}" "${ssl_frag}"
    insert_rc=$?
    rm -f "${listen_frag}" "${ssl_frag}"
    if [ "${insert_rc}" != 0 ]; then
        case "${insert_rc}" in
        2)
            Echo_Red "${vhost_conf} 中没有唯一匹配的 80 端口 server 块，未写入 HTTPS 配置。"
            if [ "${domain}" = "default" ]; then
                Echo_Yellow "该文件需要有且只有一个带 default_server 的 80 端口 server 块。"
            else
                Echo_Yellow "该文件需要有且只有一个 server_name 含 ${domain} 的 80 端口 server 块。"
            fi
            ;;
        3)
            Echo_Red "${vhost_conf} 的 80 端口 server 块缺少 server_name 或 root，未写入 HTTPS 配置。"
            ;;
        4)
            Echo_Red "${vhost_conf} 的 server 块已有 443 监听，未重复写入 HTTPS 配置。"
            Echo_Yellow "如需更换证书，请直接修改该块中 # SSL 配置 区间内的证书路径。"
            ;;
        *)
            Echo_Red "写入 ${vhost_conf} 失败。"
            ;;
        esac
        \cp -p "${backup}" "${vhost_conf}"
        rm -f "${backup}"
        return 1
    fi

    echo "正在检查 Nginx 配置......"
    if ! /usr/local/nginx/sbin/nginx -t; then
        Echo_Red "Nginx 配置测试未通过，已撤销本次写入的 HTTPS 配置。"
        \cp -p "${backup}" "${vhost_conf}"
        rm -f "${backup}"
        return 1
    fi
    echo "正在重载 Nginx......"
    if ! /usr/local/nginx/sbin/nginx -s reload; then
        Echo_Red "Nginx 重载失败，已恢复添加 SSL 前的虚拟主机配置。"
        \cp -p "${backup}" "${vhost_conf}"
        /usr/local/nginx/sbin/nginx -s reload
        rm -f "${backup}"
        return 1
    fi
    rm -f "${backup}"
    return 0
}

# 在现有虚拟主机中定位域名对应的站点，命中的站点名写入 Site_Match_Name。
# 未命中时把同根域的站点写入 Site_Match_Hints，供提示用户改正输入。
Find_Site_For_SSL()
{
    local input="${1#\*.}" base name f

    Site_Match_Name=""
    Site_Match_Hints=""
    [ -d "${Vhost_Conf_Dir}" ] || return 1

    for f in "${Vhost_Conf_Dir}"/*.conf; do
        [ -s "${f}" ] || continue
        name=$(basename "${f}" .conf)
        if [ "${name}" = "${input}" ]; then
            Site_Match_Name="${name}"
            return 0
        fi
    done

    # 站点名不匹配时再比对配置内声明的全部域名。
    for f in "${Vhost_Conf_Dir}"/*.conf; do
        [ -s "${f}" ] || continue
        if Vhost_Has_Domain "${f}" "${input}"; then
            Site_Match_Name=$(basename "${f}" .conf)
            return 0
        fi
    done

    base=$(Get_Domain_Base "${input}")
    for f in "${Vhost_Conf_Dir}"/*.conf; do
        [ -s "${f}" ] || continue
        name=$(basename "${f}" .conf)
        [ "${name}" = "default" ] && continue
        if [ "$(Get_Domain_Base "${name}")" = "${base}" ]; then
            Site_Match_Hints="${Site_Match_Hints:+${Site_Match_Hints} }${name}"
        fi
    done
    return 1
}

# 后端为域名时确定 Host 头策略并提示解析状态；IP 后端不需要这一步。
# 非交互执行读 VHOST_PROXY_HOST：n 向后端传递访问者的域名，其余按后端域名。
Site_Proxy_Backend_Detail()
{
    proxy_backend_host="$(Proxy_Backend_Host "${proxy_backend}")"
    proxy_use_backend_host="n"
    proxy_backend_resolvable="y"

    Proxy_Backend_Is_IP "${proxy_backend_host}" && return 0

    # 解析状态决定 proxy_pass 的写法：能解析就直连（getaddrinfo 会读 /etc/hosts
    # 与内网 DNS），解析不到才改用 resolver，避免 nginx 在配置解析阶段就失败。
    proxy_backend_resolvable="y"
    if command -v getent >/dev/null 2>&1 \
       && ! getent hosts "${proxy_backend_host}" >/dev/null 2>&1; then
        proxy_backend_resolvable="n"
        Echo_Yellow "后端域名 ${proxy_backend_host} 当前解析不到。"
        echo "配置仍会写入，域名改由 resolver ${Proxy_Resolver} 在运行时解析；"
        echo "该 resolver 只查 DNS，不读 /etc/hosts，届时仍解析不到会返回 502。"
    fi

    if [ ! -t 0 ]; then
        case "${VHOST_PROXY_HOST:-}" in
            [nN])
                proxy_use_backend_host="n"
                echo "非交互执行，按 VHOST_PROXY_HOST=n 向后端传递访问者的域名。"
                ;;
            *)
                proxy_use_backend_host="y"
                echo "非交互执行，向后端发送的 Host 头为 ${proxy_backend_host}。"
                ;;
        esac
        return 0
    fi

    Read_YN proxy_use_backend_host \
        "发给后端的 Host 头用后端域名 ${proxy_backend_host} 吗? (Y/n，默认 y，选 n 传递访问者的域名) " \
        y "后端 Host 头开关"
    if [ "${proxy_use_backend_host}" = "y" ]; then
        echo "后端将收到 Host: ${proxy_backend_host}。"
    else
        echo "后端将收到访问者请求中的域名。"
    fi
    return 0
}

# 站点类型为反向代理时调用：整站请求转给后端，本地不解析。
# 非交互执行读 VHOST_PROXY=<后端地址>，未设置时不配置反代。
Site_Proxy_Menu()
{
    enable_proxy="n"
    proxy_backend=""
    proxy_backend_host=""
    proxy_use_backend_host="n"
    proxy_backend_resolvable="y"

    if [ ! -t 0 ]; then
        [ -n "${VHOST_PROXY:-}" ] || return 0
        proxy_backend="${VHOST_PROXY:-}"
        if ! Check_Proxy_Backend proxy_backend; then
            proxy_backend=""
            Echo_Red "非交互执行，VHOST_PROXY 不合法，已放弃建站。"
            return 1
        fi
        enable_proxy="y"
        echo "非交互执行，按 VHOST_PROXY 配置反向代理：${proxy_backend}"
        Site_Proxy_Backend_Detail
        return 0
    fi

    enable_proxy="y"

    while :;do
        Echo_Yellow "请输入后端地址(示例: 127.0.0.1:3000，默认 http://127.0.0.1:3000): "
        Read_Input proxy_backend "后端地址"
        [ -n "${proxy_backend}" ] || proxy_backend="http://127.0.0.1:3000"
        Check_Proxy_Backend proxy_backend && break
    done
    echo "反向代理后端：${proxy_backend}"
    echo "站点目录仍会创建，用于 /.well-known/ 证书验证，其余请求全部转给后端。"
    Site_Proxy_Backend_Detail
    return 0
}

# 指向已有证书目录中的证书与私钥，供复用已签发证书时写站点配置。
Use_Existing_Cert()
{
    local dir="$1" name

    name=$(basename "${dir}")
    ssl_certificate="${dir}/fullchain.cer"
    ssl_certificate_key="${dir}/${name}.key"
    Check_Config_File_Path "${ssl_certificate}" "SSL 证书文件" || return 1
    Check_Config_File_Path "${ssl_certificate_key}" "SSL 私钥文件" || return 1
    [ -s "${ssl_certificate}" ] && [ -s "${ssl_certificate_key}" ] || {
        Echo_Red "证书目录 ${dir} 缺少证书或私钥文件。"
        echo
        return 1
    }
    return 0
}

# 站点配置中引用的证书与私钥路径。
Vhost_Cert_Paths()
{
    awk '($1 == "ssl_certificate" || $1 == "ssl_certificate_key") {
             v = $2
             sub(/;$/, "", v)
             if (substr(v, 1, 1) == "/") print v
         }' "$1" | sort -u
}

# 枚举被泛域名覆盖的现有站点，结果写入 Wildcard_Site_List。
# 列出 vhost 配置中声明的全部域名，供泛域名覆盖判定使用。
Vhost_Domains()
{
    awk '$1 == "server_name" {
            for (i = 2; i <= NF; i++) { v = $i; sub(/;$/, "", v); if (v != "_") print v }
         }' "$1" | sort -u
}

# 判断 Nginx 虚拟主机配置中是否声明了该域名。
Vhost_Has_Domain()
{
    # 配置文件不存在时直接判否：交给 awk 会让它转去读标准输入。
    [ -s "$1" ] || return 1
    awk -v d="$2" '
        $1 == "server_name" {
            for (i=2; i<=NF; i++) { v=$i; sub(/;$/, "", v); if (v == d) f=1 }
        }
        END { exit f ? 0 : 1 }
    ' "$1"
}

# 站点已有 HTTPS/443 配置时返回 0。按 server 块判断：default 的未知 SNI
# 拒绝块也监听 443，但它不承载站点，不能算作已配置 HTTPS。
Vhost_Has_HTTPS()
{
    [ -s "$1" ] || return 1
    awk '
        {
            t = $0
            sub(/#.*/, "", t)
            if (!inb && t ~ /^[[:space:]]*server[[:space:]]*\{/) {
                inb = 1; depth = 0; ssl443 = 0; reject = 0
            }
            if (!inb) next
            if (t ~ /^[[:space:]]*listen[[:space:]]/ && t ~ /443/ \
                && t ~ /[[:space:]]ssl([[:space:];]|$)/) ssl443 = 1
            if (t ~ /ssl_reject_handshake/) reject = 1
            depth += gsub(/\{/, "", t) - gsub(/\}/, "", t)
            if (depth <= 0) {
                inb = 0
                if (ssl443 && !reject) { found = 1; exit }
            }
        }
        END { exit found ? 0 : 1 }
    ' "$1"
}

# 回滚 Enable_Default_IPv6_Listen 的改动。
Disable_Default_IPv6_Listen()
{
    local conf=/usr/local/nginx/conf/vhost/default.conf port

    [ -s "${conf}" ] || return 0
    for port in ${Default_IPv6_Enabled_Ports}; do
        case "${port}" in
            80)
                sed -i 's/^\([[:space:]]*\)listen \[::\]:80 default_server/\1#listen [::]:80 default_server/' "${conf}"
                ;;
            443)
                sed -i 's/^\([[:space:]]*\)listen \[::\]:443 \(ssl\|quic reuseport\) default_server/\1#listen [::]:443 \2 default_server/' "${conf}"
                ;;
        esac
    done
    Default_IPv6_Enabled_Ports=''
    return 0
}

Enable_Default_IPv6_Listen()
{
    local conf=/usr/local/nginx/conf/vhost/default.conf

    Default_IPv6_Enabled_Ports=''
    [ -s "${conf}" ] || return 1
    if grep -q '^[[:space:]]*#listen \[::\]:80 default_server' "${conf}"; then
        sed -i 's/#listen \[::\]:80 default_server/listen [::]:80 default_server/' "${conf}" || return 1
        Default_IPv6_Enabled_Ports='80'
    fi
    # 443 的兜底块同理：站点开了 IPv6 而 default 没开，[::]:443 上就没有
    # default_server，未知 SNI 会落到业务站点。
    if grep -q '^[[:space:]]*#listen \[::\]:443 ssl default_server' "${conf}"; then
        if sed -i 's/#listen \[::\]:443 \(ssl\|quic reuseport\) default_server/listen [::]:443 \1 default_server/' "${conf}"; then
            Default_IPv6_Enabled_Ports="${Default_IPv6_Enabled_Ports:+${Default_IPv6_Enabled_Ports} }443"
        fi
    fi
    [ -n "${Default_IPv6_Enabled_Ports}" ] || return 1
    echo "已同步启用 default 站点的 IPv6 监听。"
    return 0
}

# 把 HTTPS 监听和 SSL 指令插入站点现有的 80 端口 server 块。
# 参数：配置文件 站点名（default 按 default_server 匹配） listen 片段文件 SSL 片段文件
# 返回：0 成功；2 目标 server 块不唯一；3 块内缺少 server_name 或 root；
#       4 目标块已有 443 监听；1 写入失败
Insert_SSL_Into_VHost()
{
    local conf="$1" target="$2" listen_frag="$3" ssl_frag="$4" tmp rc

    tmp=$(mktemp "${conf}.XXXXXXXX") || return 1
    awk -v target="${target}" -v lf="${listen_frag}" -v sf="${ssl_frag}" '
        function load(file, arr,   n, line) {
            n = 0
            while ((getline line < file) > 0) arr[++n] = line
            close(file)
            return n
        }
        BEGIN {
            ln = load(lf, ins_listen)
            sn = load(sf, ins_ssl)
        }
        {
            rec[NR] = $0
            # 注释不参与花括号计数和指令匹配。
            t = $0
            sub(/#.*/, "", t)
            if (!inb && t ~ /^[[:space:]]*server[[:space:]]*\{/) {
                inb = 1
                nb++
            }
            if (!inb) next
            if (t ~ /^[[:space:]]*listen[[:space:]]/) {
                v = t
                sub(/^[[:space:]]*listen[[:space:]]+/, "", v)
                sub(/[[:space:];].*$/, "", v)
                sub(/.*:/, "", v)
                if (v == "80") has80[nb] = 1
                if (v == "443" && t ~ /[[:space:]]ssl([[:space:];]|$)/) has443[nb] = 1
                if (t ~ /default_server/) isdef[nb] = 1
            }
            if (t ~ /^[[:space:]]*server_name[[:space:]]/) {
                if (!at_name[nb]) at_name[nb] = NR
                v = t
                sub(/^[[:space:]]*server_name[[:space:]]+/, "", v)
                sub(/;.*$/, "", v)
                c = split(v, names, /[[:space:]]+/)
                for (i = 1; i <= c; i++) if (names[i] == target) named[nb] = 1
            }
            if (t ~ /^[[:space:]]*root[[:space:]]/ && !at_root[nb]) at_root[nb] = NR
            depth += gsub(/\{/, "", t) - gsub(/\}/, "", t)
            if (depth <= 0) { inb = 0; depth = 0 }
        }
        END {
            for (i = 1; i <= nb; i++) {
                if (!has80[i]) continue
                if (target == "default") { if (!isdef[i]) continue }
                else if (!named[i]) continue
                hits++
                blk = i
            }
            if (hits != 1) exit 2
            if (!at_name[blk] || !at_root[blk]) exit 3
            if (has443[blk]) exit 4
            for (r = 1; r <= NR; r++) {
                if (r == at_name[blk]) for (i = 1; i <= ln; i++) print ins_listen[i]
                print rec[r]
                if (r == at_root[blk]) for (i = 1; i <= sn; i++) print ins_ssl[i]
            }
        }
    ' "${conf}" >"${tmp}"
    rc=$?
    if [ "${rc}" != 0 ]; then
        rm -f "${tmp}"
        return "${rc}"
    fi
    chmod --reference="${conf}" "${tmp}" 2>/dev/null || chmod 644 "${tmp}"
    if ! mv "${tmp}" "${conf}"; then
        rm -f "${tmp}"
        return 1
    fi
    return 0
}

# 在 vhost 文件中定位目标域名的 80 端口 server 块，输出三行：
# 网站根目录、该块声明的其它域名、是否监听 IPv6。
# 返回 2 表示目标块不唯一，3 表示块内缺少 root。
# 一个文件里可能有多个 server 块，按文件取首个 root 会读到别的站点的参数。
Parse_Vhost_Block()
{
    local conf="$1" target="$2"

    awk -v target="${target}" '
        {
            t = $0
            sub(/#.*/, "", t)
            if (!inb && t ~ /^[[:space:]]*server[[:space:]]*\{/) { inb = 1; nb++ }
            if (!inb) next
            if (t ~ /^[[:space:]]*listen[[:space:]]/) {
                v = t
                sub(/^[[:space:]]*listen[[:space:]]+/, "", v)
                sub(/[[:space:];].*$/, "", v)
                if (v ~ /^\[::\]/) ipv6[nb] = 1
                sub(/.*:/, "", v)
                if (v == "80") has80[nb] = 1
                if (t ~ /default_server/) isdef[nb] = 1
            }
            if (t ~ /^[[:space:]]*server_name[[:space:]]/) {
                v = t
                sub(/^[[:space:]]*server_name[[:space:]]+/, "", v)
                sub(/;.*$/, "", v)
                c = split(v, names, /[[:space:]]+/)
                for (i = 1; i <= c; i++) {
                    if (names[i] == "") continue
                    if (names[i] == target) named[nb] = 1
                    else if (names[i] != "_")
                        more[nb] = (more[nb] == "" ? names[i] : more[nb] " " names[i])
                }
            }
            if (t ~ /^[[:space:]]*root[[:space:]]/ && root[nb] == "") {
                v = t
                sub(/^[[:space:]]*root[[:space:]]+/, "", v)
                sub(/;.*$/, "", v)
                gsub(/[[:space:]]/, "", v)
                root[nb] = v
            }
            depth += gsub(/\{/, "", t) - gsub(/\}/, "", t)
            if (depth <= 0) { inb = 0; depth = 0 }
        }
        END {
            for (i = 1; i <= nb; i++) {
                if (!has80[i]) continue
                if (target == "default") { if (!isdef[i]) continue }
                else if (!named[i]) continue
                hits++
                blk = i
            }
            if (hits != 1) exit 2
            if (root[blk] == "") exit 3
            print root[blk]
            print more[blk]
            print (ipv6[blk] ? "y" : "n")
        }
    ' "${conf}"
}

# 删除 default 配置中拒绝未知 SNI 的兜底 server 块。
# default 自己配上证书后由它提供 443 default_server，两者不能同时存在。
Remove_SSL_Reject_Block()
{
    local conf="$1" tmp

    grep -q 'ssl_reject_handshake' "${conf}" || return 0
    tmp=$(mktemp "${conf}.XXXXXXXX") || return 1
    awk '
        {
            t = $0
            sub(/#.*/, "", t)
            if (!inb && t ~ /^[[:space:]]*server[[:space:]]*\{/) {
                inb = 1; n = 0; depth = 0; reject = 0
            }
            if (!inb) { print; next }
            buf[++n] = $0
            if (t ~ /ssl_reject_handshake/) reject = 1
            depth += gsub(/\{/, "", t) - gsub(/\}/, "", t)
            if (depth <= 0) {
                inb = 0
                if (!reject) { for (i = 1; i <= n; i++) print buf[i] }
                n = 0
            }
        }
    ' "${conf}" >"${tmp}" || { rm -f "${tmp}"; return 1; }
    chmod --reference="${conf}" "${tmp}" 2>/dev/null || chmod 644 "${tmp}"
    mv "${tmp}" "${conf}" || { rm -f "${tmp}"; return 1; }
    echo "已移除 default 的未知 SNI 拒绝块，改由本次证书提供 443 默认站点。"
    return 0
}

# Site_Static_Cache_Block <变量名>：静态资源缓存规则写入该变量。反代站点为空：
# 正则 location 优先于 location /，会把静态请求截在本地 root。
Site_Static_Cache_Block()
{
    printf -v "$1" '%s' ''
    [ "${site_type}" = "proxy" ] && return 0
    printf -v "$1" '\n%s\n%s\n' \
        '    location ~ .*\.(gif|jpg|jpeg|png|bmp|swf)$ { expires 30d; }' \
        '    location ~ .*\.(js|css)$ { expires 12h; }'
}

# 未开启 PHP 时，首页候选不包含 PHP 文件。
Site_Index_Line()
{
    if [ "${enable_site_php}" = "n" ]; then
        echo "index index.html index.htm default.html default.htm;"
    else
        echo "index index.html index.htm index.php default.html default.htm default.php;"
    fi
}

# HTTP 与 HTTPS 共用以下规则，防止未解析的 .php 文件作为静态内容泄露。
Site_PHP_Off_Block()
{
    cat <<'EOF'
# 本站点未开启 PHP，.php 及其 PATH_INFO 请求统一返回 404，防止源码泄露。
    # 整站反向代理需要由后端处理 .php 路径时，可删除此 location。
    location ~ [^/]\.php(/|$) {
        return 404;
    }
EOF
}

# 整站反代块，与 PHP 互斥。不写 .php 返回 404 的规则，.php 路径由后端处理。
# IP 后端直接写 proxy_pass；域名后端改用变量加 resolver —— proxy_pass 里直接写
# 域名时 nginx 在配置解析阶段就要查 DNS，解析不到连 nginx -t 都过不去。
Site_Proxy_Block()
{
    local host_line='$host' upstream

    [ "${proxy_use_backend_host}" = "y" ] && host_line="${proxy_backend_host}"

    printf '%s\n' "# 整站反向代理到 ${proxy_backend}，本地 root 只用于 /.well-known/ 验证。"
    if [ "${proxy_backend_resolvable}" = "n" ]; then
        # proxy_pass 用变量时不带 location 匹配剩余部分，URI 由 $request_uri 显式补上。
        upstream="${proxy_backend%/}"
        printf '%s\n' "    # 建站时后端域名解析不到，改用变量加 resolver 让它在运行时解析："
        printf '%s\n' "    # proxy_pass 直接写域名时 nginx 在配置解析阶段就要查 DNS，查不到起不来。"
        printf '%s\n' "    # 该 resolver 只查 DNS，写在 /etc/hosts 里的域名解析不到，"
        printf '%s\n' "    # 这类后端请改回 proxy_pass ${proxy_backend%/}\$request_uri 的直连写法。"
        printf '%s\n' "    # 解析到 IPv6 但本机没有 IPv6 出口时会 502，可在下一行末尾加 ipv6=off。"
        printf '%s\n' "    resolver ${Proxy_Resolver} valid=30s;"
        printf '%s\n' "    location / {"
        printf '%s\n' "        set \$lnmp_upstream \"${upstream}\";"
        printf '%s\n' "        proxy_pass \$lnmp_upstream\$request_uri;"
    else
        printf '%s\n' "    location / {"
        printf '%s\n' "        proxy_pass ${proxy_backend};"
    fi
    case "${proxy_backend}" in
        https://*)
            # 后端是 HTTPS，握手要带 SNI，否则共享 IP 的后端取不到正确证书。
            printf '%s\n' "        proxy_ssl_server_name on;"
            ;;
    esac
    printf '%s\n' "        proxy_http_version    1.1;"
    printf '%s\n' "        proxy_cache_bypass    \$http_upgrade;"
    cat <<'EOF'
        proxy_set_header Upgrade            $http_upgrade;
        proxy_set_header Connection         "upgrade";
EOF
    printf '%s\n' "        proxy_set_header Host               ${host_line};"
    cat <<'EOF'
        proxy_set_header X-Real-IP          $remote_addr;
        proxy_set_header X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto  $scheme;
        proxy_set_header X-Forwarded-Host   $host;
        proxy_set_header X-Forwarded-Port   $server_port;
    }
EOF
}
