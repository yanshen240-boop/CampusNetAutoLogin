#!/system/bin/sh
# Magisk / KernelSU 安装脚本

ui_print "- CampusNet 校园网自动重连（Android 版）"
ui_print "- 版本：v1.0.0"

# 统一权限：脚本可执行，其余只读
set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in "$MODPATH/bin/campusctl" "$MODPATH/bin/monitor.sh" "$MODPATH/service.sh" "$MODPATH/action.sh" "$MODPATH/uninstall.sh" "$MODPATH/system/bin/campusctl"; do
    [ -f "$f" ] && set_perm "$f" 0 0 0755
done

# 配置目录（与模块目录分开，卸载模块不会丢配置）
mkdir -p /data/adb/campusnet
chmod 700 /data/adb/campusnet

. "$MODPATH/bin/lib.sh" 2>/dev/null
if [ ! -f /data/adb/campusnet/config.conf ]; then
    cn_write_default_config
    ui_print "- 已生成配置模板：/data/adb/campusnet/config.conf"
    ui_print "- 首次使用请填写账号密码（任选其一）："
    ui_print "    su -c 'campusctl set username 你的学号'"
    ui_print "    su -c 'campusctl set password 你的密码'"
    ui_print "  或直接编辑 /data/adb/campusnet/config.conf 后重启"
else
    ui_print "- 检测到已有配置，保留不变"
fi

ui_print "- 安装完成。重启后自动生效，重启后可直接运行："
ui_print "    su -c 'campusctl status'"
ui_print "    su -c 'campusctl login'"
