# CampusNetAutoLogin · Android 面具模块

重庆交通大学 ePortal 校园网的**掉线自动重认证**，Android 版。
Magisk / KernelSU 模块，开机自启、后台常驻、无需打开浏览器。

适配接口：`http://172.19.7.17:801/eportal/portal/login`（锐捷 ePortal，WISP 重定向带 `wlanuserip / wlanacip / wlanacname`）

> 这是 Windows 版的 Android 移植：`AutoReconnect.ps1` 的逻辑按 ePortal 协议用 sh 重写了一版，不是把脚本塞进手机跑（Android 没有 PowerShell）。构建与目录说明见文末「九、源码与构建」。

---

## 一、和 Windows 版的区别

| 项目 | Windows 版 | Android 版（本模块） |
| --- | --- | --- |
| 运行环境 | PowerShell 5.1 | Magisk / KernelSU + sh |
| 密码存储 | DPAPI 加密（仅本机当前用户可解） | `/data/adb/campusnet/config.conf`，权限 600，仅 root 可读 |
| MAC 来源 | 有线网卡真实 MAC | 手机当前联网网卡（wlan0）MAC |
| 联网判断 | 探测页内容校验 | 同左（探测页拿不到预期内容 → 认为需认证） |
| 触发条件 | 网线 IPv4 存在 | **门户可达**（`portal_login_url` 的 host 能连上），所以在移动数据上不会空转 |
| 检测间隔 | 30s，下限 15s | 同左，且连续失败自动退避到最长 5 分钟 |
| 开机自启 | 启动文件夹快捷方式 | `service.sh`（Magisk late_start service） |

> ⚠️ **关于 MAC**：Android 默认对每个 Wi-Fi 使用随机 MAC。模块上报的是手机**当前**的 wlan0 MAC，这通常就是网关看到的地址，能正常认证。如果学校做了 MAC 绑定 / 换机就掉线，请在系统设置里把该校园网 Wi-Fi 的「隐私 / MAC 地址类型」改为**使用设备 MAC**，或在配置里用 `mac_override` 指定。

---

## 二、安装

前提：手机已 root（Magisk ≥ 20.4 或 KernelSU），并且**已经连上校园网 Wi-Fi**（此时还不能上网是正常的，本模块就是来解决它的）。

1. 从 [Releases](../../releases) 下载 `CampusNetAutoLogin-Magisk-v*.zip`（也可以自己 `python3 android/build.py` 打包），传到手机。
2. Magisk App →「模块」→「从本地安装」→ 选择 zip → 重启。
3. 重启后配置账号：

```bash
su
campusctl set username 20230000000     # 学号/工号，不带后缀
campusctl set password 你的密码
campusctl set carrier unicom            # 联通 unicom / 移动 cmcc / 电信 telecom / 不加后缀 none
campusctl restart
campusctl status
```

模块通过 `system/bin` 把 `campusctl` 挂进系统，所以重启后 `su` 里直接敲就行。如果提示找不到（还没重启，或被其他模块的 overlay 覆盖），用全路径：

```bash
su -c '/data/adb/modules/campusnet_autologin/bin/campusctl status'
```

也可以直接编辑 `/data/adb/campusnet/config.conf`（改完 `campusctl restart`）。

---

## 三、常用命令

| 命令 | 作用 |
| --- | --- |
| `campusctl status` | 环境自检：网卡 / IP / MAC / 门户是否可达 / 是否已联网 / 认证参数 / 进程状态 |
| `campusctl login` | 立刻认证一次并复检（Magisk 模块页的「操作」按钮做的就是这件事） |
| `campusctl log 50` | 看最近 50 行日志 |
| `campusctl show` | 打印配置（密码不回显） |
| `campusctl set <键> <值>` | 改配置项 |
| `campusctl restart` | 重启后台监控（改完配置用这个，不用重启手机） |
| `campusctl off` / `on` | 暂停 / 恢复自动重连（暂停后进程仍在，只是不认证） |
| `campusctl watch` | 前台跑监控看实时输出，排错用 |

日志：`/data/adb/campusnet/campus-net.log`（超过 2 MB 自动轮转为 `.log.old`）

---

## 四、配置项

`/data/adb/campusnet/config.conf`

| 字段 | 含义 |
| --- | --- |
| `username` | 校园网账号，不含运营商后缀 |
| `password` | 密码（明文，靠文件权限 600 保护） |
| `carrier` | `unicom` / `cmcc` / `telecom` / `none` / `custom` |
| `account_suffix` | `custom` 时填写，如 `@unicom` |
| `portal_login_url` | ePortal 登录接口 |
| `gateway_url` | 额外用于取重定向参数的地址，留空即可（自动用探测页 + captive.apple.com） |
| `probe_url` / `probe_expected` | 外网探测地址与期望返回内容 |
| `interval` | 检测间隔秒数，最低 15 |
| `mac_override` | 强制指定 12 位 MAC，留空自动读取 |

---

## 五、工作原理

每 `interval` 秒：

1. 请求 `probe_url`，内容不等于 `probe_expected` → 判定为认证失效（返回 WISP XML 或 302 都是这个信号）。
2. 追加一次 HTTPS 兜底探测（`https://www.baidu.com/` 返回 200 才算真在线）。
3. 检查门户是否可达（`http://172.19.7.17:801/eportal`），不可达说明不在校园网内，**只记日志不发请求**，避免半夜用流量打学校服务器。
4. 解析认证参数：从探测页响应头 `Location`、WISP XML 的 `NextURL`、页面正文里抓 `wlanuserip / wlanacip / wlanacname`；都取不到时退化为本机 wlan0 IPv4。
5. 提交认证：`GET /eportal/portal/login?callback=dr1007&login_method=1&user_account=,0,账号+后缀&user_password=...&wlan_user_ip=...&wlan_user_mac=...&wlan_ac_ip=...&wlan_ac_name=...`
6. 3 秒后复检，通了记 `校园网已恢复。`，不通等下一轮；连续失败 3 次后按 3×/4×/… 退避，最长 5 分钟一次。

---

## 六、排错

**`status` 显示门户不可达**
不在校园网里（或连的是别的 SSID），先确认 Wi-Fi 已连上校园网。

**`login` 返回「学号\/工号不存在」**
账号写错，或把后缀也填进了 `username`（后缀应交给 `carrier` 处理）。

**返回「密码错误」**
先确认运营商后缀：三网在 ePortal 上是同一页面不同出口，后缀错了会直接判密码错。

**返回「认证服务器未返回成功结果」且没有 msg**
学校换了 portal 接口或加了验证码/MAC 绑定。用浏览器开发者工具抓一次登录请求，比对 `portal_login_url` 与参数名。

**能认证成功但几秒后又掉**
同账号在别的设备（另一台手机、路由器）上在线，ePortal 常常后登录踢前登录。

**息屏一段时间后掉线**
系统层面在关 Wi-Fi，模块救不回来。设置里把该 Wi-Fi 的「休眠时保持连接」打开，并关掉「自动切换到移动数据 / 智能切换网络」。模块能保证的是：Wi-Fi 一回来就立刻重新认证。

**Magisk 里显示模块已启用但不工作**
看 `campusctl status` 的进程状态与日志；`campusctl start` 手动拉起；必要时 `campusctl watch` 前台观察。

---

## 七、安全说明

- 密码以**明文**保存在 `/data/adb/campusnet/config.conf`，权限 600、目录 700，只有 root 可读。Android 上没有 DPAPI 这类「绑定当前用户」的加密，所以安全边界就是 root 权限本身。**不要把该文件发到群里或提交进仓库。**
- 明文密码出现在 `portal/login` 的 GET 参数里，这是 ePortal 协议本身决定的（Windows 版同理）。
- 模块不上报、不外发任何数据，只与学校认证服务器通信。

## 八、卸载

Magisk App 里移除模块即可（`uninstall.sh` 会先杀掉后台进程）。配置与日志故意保留在 `/data/adb/campusnet`，确认不需要后手动删除。

## 九、源码与构建

```
android/
├── module.prop              # 模块信息（version / versionCode，发版前改这里）
├── customize.sh             # 安装脚本：权限、生成配置模板
├── service.sh               # 开机拉起后台监控（late_start service）
├── action.sh                # Magisk「操作」按钮：立即认证一次
├── uninstall.sh             # 卸载时停进程，保留配置与日志
├── bin/
│   ├── lib.sh               # 公共库：日志、HTTP、URL 编码、参数解析、认证
│   ├── monitor.sh           # 监控主循环
│   └── campusctl            # 命令行工具
├── system/bin/campusctl     # 包装器，让 root shell 直接敲 campusctl
├── tools/                   # PC 端辅助：adb 写配置 + 试登录
│   ├── 配置校园网.cmd
│   └── setup-campusnet.ps1
└── build.py                 # 打包脚本
```

打 zip（需要 Python 3）：

```bash
python3 android/build.py
# -> android/dist/CampusNetAutoLogin-Magisk-v1.0.0.zip
```

或者推一个 `android-v*` 的 tag，GitHub Actions 会自动构建 zip 并挂到 Release：

```bash
git tag android-v1.0.0 && git push origin android-v1.0.0
```

发版顺序（别漏了版本号）：改 `module.prop` 的 `version` 与 `versionCode` → 提交 → 打 tag 推送。
Release 正文取自 `android/RELEASE_NOTES.md`，改这个文件就能改下次 Release 的说明。

目录 `tools/` 里的 PC 端助手只负责通过 adb 把账号写进手机配置并试一次登录，不进模块 zip。

## 十、更新记录

**v1.0.0**
- Android 首发：Magisk 模块化，开机自启 + 后台常驻。
- 门户可达性门控，非校园网环境不发认证请求。
- 三网后缀、认证参数多路解析、失败退避、日志轮转、单实例保护。
- `campusctl` 命令行 + Magisk「操作」按钮一键重认证。
- PC 端配置助手（adb + base64 写配置，写完自动重启监控）。

## License

MIT，随主仓库一致。
