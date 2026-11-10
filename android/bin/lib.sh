#!/system/bin/sh
# CampusNetAutoLogin · Android 版公共函数库
# 被 bin/monitor.sh 与 bin/campusctl 复用。
# 只依赖 Android 自带的 sh / toybox；有 curl 时优先用 curl。

CN_HOME=${CN_HOME:-/data/adb/campusnet}
CN_CONFIG=$CN_HOME/config.conf
CN_LOG=$CN_HOME/campus-net.log
CN_PID=$CN_HOME/monitor.pid
CN_DISABLED=$CN_HOME/disabled
CN_UA="Mozilla/5.0 (Linux; Android 14; Mobile) CampusNetAutoLogin/1.0"

export PATH=/system/bin:/system/xbin:/system/sbin:/data/adb/magisk:$PATH

CN_CURL=$(command -v curl 2>/dev/null)
CN_BUSYBOX=$(command -v busybox 2>/dev/null)

# ---------------------------------------------------------------- 日志

cn_now() { date '+%Y-%m-%d %H:%M:%S'; }

# cn_log <消息> [级别]
cn_log() {
    _lvl=${2:-INFO}
    [ -d "$CN_HOME" ] || return 0
    if [ -f "$CN_LOG" ]; then
        _sz=$(wc -c < "$CN_LOG" 2>/dev/null)
        if [ "${_sz:-0}" -gt 2097152 ] 2>/dev/null; then
            mv -f "$CN_LOG" "$CN_LOG.old" 2>/dev/null
        fi
    fi
    printf '%s [%s] %s\n' "$(cn_now)" "$_lvl" "$1" >>"$CN_LOG" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------- 配置

# 写入一份配置模板（不含任何真实凭据）
cn_write_default_config() {
    mkdir -p "$CN_HOME" 2>/dev/null
    cat >"$CN_CONFIG" <<'EOF'
# ============ CampusNetAutoLogin 配置（修改后执行 campusctl restart 生效）============
# 校园网账号（学号/工号），不要带运营商后缀
username=''
# 校园网密码
password=''
# 运营商：unicom(联通) / cmcc(移动) / telecom(电信) / none(不加后缀) / custom(用下面的 account_suffix)
carrier='unicom'
# 仅 carrier='custom' 时需要，例如 '@unicom'
account_suffix=''
# ePortal 登录接口
portal_login_url='http://172.19.7.17:801/eportal/portal/login'
# 网关/重定向地址，留空表示自动探测（多数学校无需填）
gateway_url=''
# 外网探测：能拿到 expected 内容才认为已联网
probe_url='http://www.msftconnecttest.com/connecttest.txt'
probe_expected='Microsoft Connect Test'
# 检测间隔秒数，最低 15
interval='30'
# 强制指定 MAC（12 位十六进制，无分隔符）。留空表示自动读取当前联网网卡 MAC
mac_override=''
EOF
    chmod 600 "$CN_CONFIG" 2>/dev/null
}

# 加载配置到全局变量；返回 1 表示配置缺失或账号未填
cn_load_config() {
    [ -f "$CN_CONFIG" ] || return 1
    # shellcheck disable=SC1090
    . "$CN_CONFIG"

    USERNAME=${username:-}
    PASSWORD=${password:-}
    CARRIER=${carrier:-unicom}
    ACCOUNT_SUFFIX=${account_suffix:-}
    PORTAL_LOGIN_URL=${portal_login_url:-http://172.19.7.17:801/eportal/portal/login}
    GATEWAY_URL=${gateway_url:-}
    PROBE_URL=${probe_url:-http://www.msftconnecttest.com/connecttest.txt}
    PROBE_EXPECTED=${probe_expected:-Microsoft Connect Test}
    INTERVAL=${interval:-30}
    MAC_OVERRIDE=${mac_override:-}

    case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=30 ;; esac
    [ "$INTERVAL" -lt 15 ] && INTERVAL=15

    SUFFIX=$(cn_account_suffix)
    [ -n "$USERNAME" ] || return 1
    return 0
}

# 计算实际提交的后缀
cn_account_suffix() {
    if [ -n "${ACCOUNT_SUFFIX:-}" ]; then
        _sfx=$ACCOUNT_SUFFIX
    else
        case "${CARRIER:-unicom}" in
            telecom) _sfx='@telecom' ;;
            cmcc)    _sfx='@cmcc' ;;
            none)    _sfx='' ;;
            custom)  _sfx='' ;;
            *)       _sfx='@unicom' ;;
        esac
    fi
    _sfx=$(printf '%s' "$_sfx" | tr -d ' \t\r\n')
    case "$_sfx" in
        ''|@*) : ;;
        *) _sfx="@$_sfx" ;;
    esac
    printf '%s' "$_sfx"
}

# ---------------------------------------------------------------- HTTP

# cn_http_get <url> [超时秒] —— 只要正文
cn_http_get() {
    _g_url=$1
    _g_to=${2:-8}
    if [ -n "$CN_CURL" ]; then
        "$CN_CURL" -s -m "$_g_to" -A "$CN_UA" "$_g_url" 2>/dev/null
    elif [ -n "$CN_BUSYBOX" ]; then
        "$CN_BUSYBOX" wget -q -O - -T "$_g_to" -U "$CN_UA" "$_g_url" 2>/dev/null
    else
        wget -q -O - -T "$_g_to" "$_g_url" 2>/dev/null
    fi
}

# cn_http_get_i <url> [超时秒] —— 连响应头一起（用于读 302 Location）
cn_http_get_i() {
    _gi_url=$1
    _gi_to=${2:-8}
    if [ -n "$CN_CURL" ]; then
        "$CN_CURL" -s -i -m "$_gi_to" -A "$CN_UA" "$_gi_url" 2>/dev/null
    else
        cn_http_get "$_gi_url" "$_gi_to"
    fi
}

# cn_http_code <url> [超时秒] —— 输出状态码，失败为 000
cn_http_code() {
    _hc_url=$1
    _hc_to=${2:-6}
    if [ -n "$CN_CURL" ]; then
        "$CN_CURL" -s -m "$_hc_to" -o /dev/null -w '%{http_code}' "$_hc_url" 2>/dev/null
    else
        if [ -n "$(cn_http_get "$_hc_url" "$_hc_to")" ]; then
            printf '200'
        else
            printf '000'
        fi
    fi
}

# ---------------------------------------------------------------- 编码

# URL 编码（不依赖 python/perl，按字节处理，UTF-8 也能正确编码）
cn_urlencode() {
    printf '%s' "$1" | od -An -v -tx1 | awk '
        BEGIN { hexs = "0123456789ABCDEF" }
        {
            for (i = 1; i <= NF; i++) {
                h = toupper($i)
                hi = index(hexs, substr(h, 1, 1)) - 1
                lo = index(hexs, substr(h, 2, 1)) - 1
                v = hi * 16 + lo
                if ((v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 45 || v == 46 || v == 95 || v == 126) {
                    printf "%c", v
                } else {
                    printf "%%%02X", v
                }
            }
        }'
}

# ---------------------------------------------------------------- 网络状态

# 当前默认路由的网卡名（wlan0 / rmnet_data0 ...）
cn_active_if() {
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1
}

cn_if_ip() {
    ip -4 addr show "$1" 2>/dev/null | sed -n 's/.*inet \([0-9][0-9.]*\)\/.*/\1/p' | head -1
}

# 12 位小写十六进制 MAC
cn_if_mac() {
    cat "/sys/class/net/$1/address" 2>/dev/null | tr -d ':\r\n ' | tr 'A-Z' 'a-z'
}

cn_local_mac() {
    if [ -n "${MAC_OVERRIDE:-}" ]; then
        printf '%s' "$MAC_OVERRIDE" | tr -d ':\- ' | tr 'A-Z' 'a-z'
        return 0
    fi
    _lm_if=$(cn_campus_if)
    [ -n "$_lm_if" ] || return 1
    cn_if_mac "$_lm_if"
}

# 校园网侧网卡：优先按「到门户的路由」判定。
# 安卓在 Wi-Fi 无互联网时可能把默认路由留在移动数据上，那时用默认路由会取到蜂窝网的 IP/MAC，
# 认证必然失败，所以这里以能否到达门户为准。
cn_campus_if() {
    _ci_host=$(cn_portal_host)
    _ci_if=''
    if [ -n "$_ci_host" ]; then
        case "$_ci_host" in
            *[!0-9.]*) : ;;  # 不是纯 IP，跳过
            *)
                _ci_if=$(ip -4 route get "$_ci_host" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
                ;;
        esac
    fi
    [ -n "$_ci_if" ] || _ci_if=$(cn_active_if)
    case "$_ci_if" in
        rmnet*|ccmni*|pdp*|wwan*|v4-*)
            [ -n "$(cn_if_ip wlan0)" ] && _ci_if=wlan0
            ;;
    esac
    printf '%s' "$_ci_if"
}

# 门户主机（含端口），用于连通性判断与路由选择
cn_portal_host() {
    printf '%s' "${PORTAL_LOGIN_URL:-http://172.19.7.17:801/eportal/portal/login}" \
        | sed -e 's#^[A-Za-z][A-Za-z0-9+.-]*://##' -e 's#/.*$##'
}

# 是否已真正联网（探测页拿到预期内容；再退化为 https 探测）
cn_online() {
    _on_body=$(cn_http_get "$PROBE_URL?t=$$$RANDOM" 6)
    _on_text=$(printf '%s' "$_on_body" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ "$_on_text" = "$PROBE_EXPECTED" ] && return 0
    _on_code=$(cn_http_code "https://www.baidu.com/" 6)
    [ "$_on_code" = "200" ] && return 0
    return 1
}

# 门户是否可达 —— 用来判断「是不是在校园网里」，避免在移动数据上空转
cn_portal_reachable() {
    _pr_host=$(cn_portal_host)
    [ -n "$_pr_host" ] || return 1
    _pr_code=$(cn_http_code "http://$_pr_host/eportal" 4)
    [ -n "$_pr_code" ] && [ "$_pr_code" != "000" ]
}

# 解析认证参数，输出 "wlanuserip|wlanacip|wlanacname"
cn_portal_context() {
    _pc_ip=''
    _pc_acip=''
    _pc_acname=''

    for _pc_u in "$PROBE_URL" "$GATEWAY_URL" "http://captive.apple.com/"; do
        [ -n "$_pc_u" ] || continue
        _pc_resp=$(cn_http_get_i "$_pc_u" 8)
        [ -n "$_pc_resp" ] || continue
        [ -n "$_pc_ip" ] || _pc_ip=$(printf '%s' "$_pc_resp" | grep -o 'wlanuserip=[0-9][0-9.]*' | head -1 | sed 's/^wlanuserip=//')
        [ -n "$_pc_acip" ] || _pc_acip=$(printf '%s' "$_pc_resp" | grep -o 'wlanacip=[0-9][0-9.]*' | head -1 | sed 's/^wlanacip=//')
        [ -n "$_pc_acname" ] || _pc_acname=$(printf '%s' "$_pc_resp" | grep -o 'wlanacname=[A-Za-z0-9_.-]*' | head -1 | sed 's/^wlanacname=//')
        [ -n "$_pc_ip" ] && break
    done

    if [ -z "$_pc_ip" ]; then
        _pc_if=$(cn_campus_if)
        _pc_ip=$(cn_if_ip "$_pc_if")
    fi

    printf '%s|%s|%s\n' "$_pc_ip" "$_pc_acip" "$_pc_acname"
}

# ---------------------------------------------------------------- 认证

# cn_build_login_url <ip> <acip> <acname> <mac>
cn_build_login_url() {
    _bl_ip=$1
    _bl_acip=$2
    _bl_acname=$3
    _bl_mac=$4
    _bl_v=$(( (RANDOM % 9000) + 1000 ))

    _bl_url="${PORTAL_LOGIN_URL}?callback=dr1007&login_method=1"
    _bl_url="$_bl_url&user_account=$(cn_urlencode ",0,${USERNAME}${SUFFIX}")"
    _bl_url="$_bl_url&user_password=$(cn_urlencode "$PASSWORD")"
    _bl_url="$_bl_url&wlan_user_ip=$(cn_urlencode "$_bl_ip")"
    _bl_url="$_bl_url&wlan_user_ipv6="
    _bl_url="$_bl_url&wlan_user_mac=$(cn_urlencode "$_bl_mac")"
    _bl_url="$_bl_url&wlan_vlan_id=0"
    _bl_url="$_bl_url&wlan_ac_ip=$(cn_urlencode "$_bl_acip")"
    _bl_url="$_bl_url&wlan_ac_name=$(cn_urlencode "$_bl_acname")"
    _bl_url="$_bl_url&mac_type=0"
    _bl_url="$_bl_url&UA=$(cn_urlencode 'Mozilla/5.0 (Linux; Android)')"
    _bl_url="$_bl_url&jsVersion=4.2.2&terminal_type=1&lang=zh-cn&v=$_bl_v"
    printf '%s' "$_bl_url"
}

# 把日志里要打印的 URL 密码打码
cn_mask_url() {
    printf '%s' "$1" | sed 's/\(user_password=\)[^&]*/\1***/'
}

# 提交一次认证；成功返回 0
cn_do_login() {
    _dl_ctx=$(cn_portal_context)
    _dl_ip=$(printf '%s' "$_dl_ctx" | cut -d'|' -f1)
    _dl_acip=$(printf '%s' "$_dl_ctx" | cut -d'|' -f2)
    _dl_acname=$(printf '%s' "$_dl_ctx" | cut -d'|' -f3)

    if [ -z "$_dl_ip" ]; then
        cn_log "没有取到本机 IPv4（Wi-Fi 未连接？），本轮不提交认证。" ERROR
        CN_LAST_ERROR="no-ip"
        return 1
    fi

    _dl_mac=$(cn_local_mac 2>/dev/null)
    if [ -z "$_dl_mac" ] || [ "$_dl_mac" = "000000000000" ]; then
        _dl_mac=000000000000
        cn_log "未能读到网卡 MAC，退化为 000000000000 提交。" WARN
    fi

    CN_LAST_IP=$_dl_ip
    CN_LAST_MAC=$_dl_mac

    _dl_url=$(cn_build_login_url "$_dl_ip" "$_dl_acip" "$_dl_acname" "$_dl_mac")
    _dl_resp=$(cn_http_get "$_dl_url" 12)
    _dl_text=$(printf '%s' "$_dl_resp" | tr -d '\r\n' | cut -c1-300)

    if printf '%s' "$_dl_resp" | grep -Eq '"result"[[:space:]]*:[[:space:]]*"?1"?|认证成功|Portal协议认证成功|already online|已经在线|在线用户'; then
        cn_log "认证服务器已接受登录请求，IP：$_dl_ip，MAC：$_dl_mac。"
        CN_LAST_ERROR=""
        return 0
    fi

    cn_log "认证服务器未返回成功结果：${_dl_text:-（空响应）}" WARN
    CN_LAST_ERROR="portal-reject"
    return 1
}

# 完整一轮：掉线 → 登录 → 复检
cn_try_recover() {
    CN_LAST_IP=''
    CN_LAST_MAC=''
    CN_LAST_ERROR=''

    if ! cn_portal_reachable; then
        CN_LAST_ERROR="no-portal"
        return 2
    fi
    cn_do_login || return 1
    sleep 3
    if cn_online; then
        return 0
    fi
    CN_LAST_ERROR="verify-fail"
    return 1
}
