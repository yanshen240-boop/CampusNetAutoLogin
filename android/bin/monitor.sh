#!/system/bin/sh
# CampusNetAutoLogin · 监控主循环（后台常驻）
# 用法：monitor.sh           正常常驻
#       monitor.sh --once    只跑一轮（排错用）

MODDIR=$(cd "${0%/*}/.." 2>/dev/null && pwd)
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/campusnet_autologin
. "$MODDIR/bin/lib.sh"

ONCE=0
[ "$1" = "--once" ] && ONCE=1

mkdir -p "$CN_HOME" 2>/dev/null

# ---------- 单实例 ----------
if [ "$ONCE" -eq 0 ]; then
    if [ -f "$CN_PID" ]; then
        _old=$(cat "$CN_PID" 2>/dev/null)
        if [ -n "$_old" ] && [ "$_old" != "$$" ] && kill -0 "$_old" 2>/dev/null; then
            cn_log "已有一个监控进程在运行（PID $_old），本进程退出。" WARN
            exit 0
        fi
    fi
    printf '%s\n' "$$" >"$CN_PID"
fi

_cleanup() {
    [ "$ONCE" -eq 0 ] && rm -f "$CN_PID" 2>/dev/null
    cn_log "自动重连监控已停止。"
}
trap _cleanup EXIT INT TERM

if ! cn_load_config; then
    # 还没填账号：不退出，等着配置出现（用户填完自动开始，不用重启）
    _cfg_warned=0
    while :; do
        if [ "$_cfg_warned" -eq 0 ]; then
            cn_log "配置缺失或账号为空：$CN_CONFIG，等填好账号后自动开始。" ERROR
            _cfg_warned=1
        fi
        [ "$ONCE" -eq 1 ] && exit 1
        sleep 30
        cn_load_config && break
    done
    cn_log "已读到账号配置，开始监控。"
fi

_sfx_log=${SUFFIX:-（无后缀）}
cn_log "自动重连监控已启动（Android v1.0.0），账号 ${USERNAME}，后缀 $_sfx_log，间隔 ${INTERVAL}s。"

_last_state=''
_fail=0

while :; do
    if [ -f "$CN_DISABLED" ]; then
        if [ "$_last_state" != "paused" ]; then
            cn_log "模块已被暂停（存在 disabled 文件），仅保留进程。"
            _last_state="paused"
        fi
        [ "$ONCE" -eq 1 ] && break
        sleep 60
        continue
    fi

    if cn_online; then
        if [ "$_last_state" != "online" ]; then
            cn_log "外网连接正常。"
        fi
        _last_state="online"
        _fail=0
    else
        if [ "$_last_state" != "offline" ]; then
            _if_now=$(cn_campus_if)
            cn_log "检测到外网不可用（网卡：${_if_now:-未知}），开始恢复连接。" WARN
        fi
        _last_state="offline"
        _fail=$((_fail + 1))

        cn_try_recover
        _rc=$?

        if [ "$_rc" -eq 0 ]; then
            cn_log "校园网已恢复。"
            _last_state="online"
            _fail=0
        elif [ "$_rc" -eq 2 ]; then
            if [ "$_fail" -le 1 ]; then
                cn_log "认证门户不可达：${CN_LAST_ERROR}（不在校园网内或网关地址已变更），本轮跳过。"
            fi
        else
            cn_log "本次恢复未成功（${CN_LAST_ERROR}），稍后重试。"
        fi
    fi

    [ "$ONCE" -eq 1 ] && break

    # 连续失败时逐步退避，最多 5 分钟一次，避免把学校认证服务器打爆
    _wait=$INTERVAL
    if [ "$_fail" -ge 3 ]; then
        _wait=$(( INTERVAL * _fail ))
        [ "$_wait" -gt 300 ] && _wait=300
        cn_log "已连续失败 ${_fail} 次，退避 ${_wait}s 后再试。" WARN
    fi
    sleep "$_wait"
done
