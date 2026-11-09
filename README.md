# CampusNetAutoLogin 校园网自动重连

**重庆交通大学 ePortal 校园网的掉线自动重认证脚本 —— Windows 有线、纯 PowerShell、常驻后台。**

适配的认证接口：

```text
http://172.19.7.17:801/eportal/portal/login
```

程序每 30 秒探测一次外网。一旦发现网页认证失效，它会自动重新提交 ePortal 认证，把网接回来。全程不需要打开浏览器、不需要手动输入账号。

支持三网账号后缀：中国联通 `@unicom`、中国移动 `@cmcc`、中国电信 `@telecom`，也可自定义或完全不接后缀。

| 项目 | 说明 |
| :--- | :--- |
| 系统要求 | Windows 10 / 11，PowerShell 5.1（系统自带） |
| 依赖 | 无，不需要安装任何运行库 |
| 密码存储 | Windows DPAPI 加密，仅当前 Windows 用户可解密 |
| 检测间隔 | 默认 30 秒，最低限制 15 秒 |
| 版本 | v1.1.0 |

---

## 一、它解决什么问题

校园网 ePortal 认证有时效，长时间挂机、休眠唤醒、交换机端口重置之后，网页认证会静默失效：网卡上 IPv4 还在，微信也能收消息，但打不开网页——这就是典型的"链路正常、认证掉了"。

手动处理要重新打开任意网页、等它跳转到认证页、再输一次账号密码。挂机下载、远程桌面、跑长任务时非常难受。

本脚本把这件事自动化：后台常驻，掉线即重认证，成功后写一条日志，然后再继续探测。

## 二、工作原理

一轮检测的流程：

1. **探测外网**：请求 `http://www.msftconnecttest.com/connecttest.txt`，校验返回内容是否等于 `Microsoft Connect Test`。失败则再用 `https://www.baidu.com/` 兜底。
2. **判断链路**：如果配置了 Wi-Fi 名称，尝试 `netsh wlan connect` 重连；有线模式下只检查网卡状态——没有可用 IPv4（网线松了、被 802.1X 踢下线）就只写日志，不空转打认证服务器。
3. **取认证参数**：向网关与几个 captive 探测地址发请求，从 302 的 `Location`、页面正文里的 JS 脚本、`#` fragment 中解析 `wlanuserip` / `wlanacip` / `wlanacname`。都取不到时退化为使用本机有线网卡 IPv4。
4. **提交认证**：以本机真实 MAC（去分隔符小写）和解析到的参数请求 `/eportal/portal/login`，账号为 `,0,账号+运营商后缀`。
5. **复检**：3 秒后再探测一次外网，通了就记为恢复，没通就等下一轮。

进程使用互斥锁 `Local\CampusNetAutoLogin-<用户名>`，同一用户不会同时跑多个副本。日志超过 2 MB 自动轮转为 `.log.old`。

## 三、安装

1. 下载仓库（`Code → Download ZIP`）并解压。
2. 双击 `Install.cmd`。如果被执行策略拦截，在该目录的 PowerShell 中执行：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1
   ```

3. 按提示输入：
   - **校园网账号**：学生/工号，不带后缀；
   - **密码**：输入时不回显；
   - **运营商**：`1` 联通 / `2` 移动 / `3` 电信 / `4` 自定义或不加后缀，直接 Enter 为联通；
   - **Wi-Fi 配置名称**：有线台式机直接 Enter 留空。

安装过程会：

- 把脚本复制到 `%LOCALAPPDATA%\CampusNetAutoLogin\`；
- 写入加密后的 `config.json`；
- 在启动文件夹创建 `CampusNetAutoLogin.lnk` 快捷方式（开机自启）；
- 立即静默启动监控进程。

## 四、配置项

配置文件：`%LOCALAPPDATA%\CampusNetAutoLogin\config.json`

| 字段 | 含义 |
| :--- | :--- |
| `username` | 校园网账号，不含运营商后缀 |
| `encrypted_password` | DPAPI 加密后的密码，**不要手改** |
| `carrier` | `unicom` / `cmcc` / `telecom` / `none` / `custom` |
| `account_suffix` | 实际提交的后缀，如 `@cmcc`；空字符串表示不加后缀 |
| `wifi_profile` | 可选，Windows 中保存的 Wi-Fi 配置名，有线留空 |
| `gateway_url` | 网关地址，用于取重定向参数 |
| `portal_login_url` | ePortal 登录接口 |
| `probe_url` / `probe_expected` | 外网探测地址与期望返回内容 |

修改账号、密码或运营商：重新运行 `Setup.ps1`，会覆盖旧配置并重启监控进程。

## 五、查看运行情况

日志：`%LOCALAPPDATA%\CampusNetAutoLogin\campus-net.log`

手动跑一次检测（前台，便于排错）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CampusNetAutoLogin\AutoReconnect.ps1" -Once
```

常用日志关键字：

- `外网连接正常。` —— 在线，无事发生；
- `认证服务器已接受登录请求` —— 重认证成功，日志里会带当时的 IP 与 MAC；
- `有线网卡无可用 IPv4` —— 物理链路问题，先查网线和网口灯；
- `认证服务器未返回成功结果` —— 多半是运营商后缀选错，或密码已改。

## 六、卸载

双击 `Uninstall.cmd`，或运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CampusNetAutoLogin\Uninstall.ps1"
```

会停止监控并删除开机启动项。配置与日志目录**故意保留**，避免误删；确认不再需要后手动删除 `%LOCALAPPDATA%\CampusNetAutoLogin\`。

## 七、常见问题

**认证返回失败 / 提示密码错误**

先确认运营商后缀。三网在 ePortal 上是同一个页面、不同出口，后缀选错会直接判为账号或密码错误。联通 `@unicom`、移动 `@cmcc`、电信 `@telecom`；部分账号本身不带后缀，选 `4` 后直接 Enter。

**日志显示有 IPv4，但一直认证不成功**

学校可能更换了 Portal 接口、加了验证码或做了 MAC 绑定。用浏览器开发者工具抓一次登录请求，比对 `portal_login_url` 和参数名，再改 `config.json`。

**能认证成功但几秒后又掉**

检查是否有其他设备（手机、路由器）用同一账号在线，ePortal 常常是同账号后登录踢前登录。

**可以改成 5 秒一次吗**

不行，脚本把下限锁在 15 秒，避免高频请求把学校认证服务器打成异常。改间隔用 `-IntervalSeconds` 参数。

**笔记本 Wi-Fi 也能用吗**

可以。安装时填入 Windows 保存的 Wi-Fi 配置名，脚本会先尝试重连 Wi-Fi 再认证；不填则按有线逻辑只检查 IPv4。

## 八、安全说明

- 密码用 `ConvertFrom-SecureString`（DPAPI）加密后存入 `config.json`，只有加密时的那个 Windows 用户、在那台机器上能解开。把文件发给别人也解不出明文。
- 仓库 `.gitignore` 已排除 `config.json`、`*.log`、`monitor.pid`。**提交代码前请确认没有把自己的配置或日志带进仓库。**
- 账号密码只在本机与学校认证服务器之间传递，脚本不上报、不外发任何数据。
- 明文密码会在 `Invoke-PortalLogin` 的请求参数里出现，这是 ePortal 协议本身的要求；请勿在公共电脑上安装。

## 九、免责声明

本项目仅用于自动化**你自己的**校园网账号认证，请遵守重庆交通大学网络使用规定。使用脚本造成的账号异常、被限速或封禁等后果由使用者自负。学校调整认证协议后脚本可能失效，届时需要按第七节自行适配。

## 十、仓库结构

```text
CampusNetAutoLogin/
├── Install.cmd             # 安装入口（双击）
├── Setup.ps1               # 交互式安装：账号/密码/运营商/自启
├── AutoReconnect.ps1       # 监控主程序：探测 + 重认证
├── Uninstall.cmd           # 卸载入口（双击）
├── Uninstall.ps1           # 停止监控、移除自启
├── config.example.json     # 配置样例（不含任何真实凭据）
└── README.md
```

## 更新记录

**v1.1.0**

- 新增三网运营商后缀选择（`@unicom` / `@cmcc` / `@telecom` / 自定义 / 无后缀），安装时不再默认写死联通。
- 启动日志记录当前生效的账号后缀，便于排查"密码错误"。
- 兼容旧版配置：缺少 `account_suffix` 时按 `carrier` 推断，再退化到联通。

**v1.0.0**

- 有线版首发：真实网卡 MAC 认证、Portal 参数多路解析、链路状态检查、日志轮转、互斥锁防多开。

## License

[MIT](LICENSE)
