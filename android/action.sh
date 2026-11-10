#!/system/bin/sh
# 模块「操作」按钮：立即检测并尝试认证一次，输出直接显示在 Magisk 弹窗里

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/campusnet_autologin
. "$MODDIR/bin/lib.sh"

if ! cn_load_config; then
    echo "尚未配置账号/密码。"
    echo "执行：su -c 'campusctl set username 学号'"
    echo "      su -c 'campusctl set password 密码'"
    exit 1
fi

if cn_online; then
    echo "外网正常（账号 ${USERNAME}${SUFFIX}），无需重认证。"
    exit 0
fi

"$MODDIR/bin/campusctl" login 2>&1
