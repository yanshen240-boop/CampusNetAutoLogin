## 校园网自动重连 · Android 面具模块

重庆交通大学 ePortal 校园网的**掉线自动重认证**，Magisk / KernelSU 模块。
开机自启、后台常驻，掉线自动重新提交认证，不用打开浏览器、不用手输账号。

### 适用条件

- 已 root（Magisk ≥ 20.4 或 KernelSU）
- 安卓 10 及以上，arm64 或 arm
- 已经连上校园网 Wi-Fi（此时还上不了网是正常的，模块就是来解决它的）

### 安装

1. 下载下面的 `CampusNetAutoLogin-Magisk-v*.zip`，传到手机
2. Magisk App → 模块 → 从本地安装 → 选 zip → 重启
3. 重启后填账号（任选一种）：
   - 手机终端：`su` 然后 `campusctl set username 学号`、`campusctl set password 密码`、`campusctl restart`
   - 电脑：用仓库 `android/tools/配置校园网.cmd`，插线双击，按提示输入

### 装完怎么确认

```bash
su -c 'campusctl status'   # 网卡 / IP / MAC / 门户可达 / 是否已联网 / 进程状态
su -c 'campusctl log 30'   # 看日志
```

Magisk 模块页的「操作」按钮 = 立即重认证一次。

### 注意

- 密码以明文存在 `/data/adb/campusnet/config.conf`（权限 600，仅 root 可读），卸载模块不会删除该文件
- 安卓对每个 Wi-Fi 默认使用随机 MAC。若学校做了 MAC 绑定导致反复掉线，把该 Wi-Fi 的「MAC 地址类型」改成**使用设备 MAC**
- 运营商后缀选错会提示密码错误：联通 `@unicom`、移动 `@cmcc`、电信 `@telecom`

详细说明、配置项、排错表见 [android/README.md](https://github.com/yanshen240-boop/CampusNetAutoLogin/blob/main/android/README.md)。
