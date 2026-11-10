#!/system/bin/sh
# 开机启动：等系统起来后拉起后台监控（late_start service 阶段执行）

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/campusnet_autologin

# 等 boot 完成，最多等 4 分钟
_i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$_i" -lt 120 ]; do
    sleep 2
    _i=$((_i + 1))
done
sleep 5

"$MODDIR/bin/campusctl" start >/dev/null 2>&1
