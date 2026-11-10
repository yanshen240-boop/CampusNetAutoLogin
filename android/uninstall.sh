#!/system/bin/sh
# 卸载模块时：停掉后台监控。配置与日志故意保留在 /data/adb/campusnet

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/campusnet_autologin

if [ -f /data/adb/campusnet/monitor.pid ]; then
    _p=$(cat /data/adb/campusnet/monitor.pid 2>/dev/null)
    [ -n "$_p" ] && kill "$_p" 2>/dev/null
    sleep 1
    [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null
    rm -f /data/adb/campusnet/monitor.pid
fi

# 顺手清掉本模块可能残留的进程
for _pid in $(ps -A -o PID,ARGS 2>/dev/null | grep '[m]onitor.sh' | awk '{print $1}'); do
    kill "$_pid" 2>/dev/null
done

echo "CampusNetAutoLogin 已停止。配置与日志保留在 /data/adb/campusnet。"
