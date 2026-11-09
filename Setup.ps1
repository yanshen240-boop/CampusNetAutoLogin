$ErrorActionPreference = "Stop"

$SourceDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDirectory = Join-Path $env:LOCALAPPDATA "CampusNetAutoLogin"
$StartupDirectory = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupDirectory "CampusNetAutoLogin.lnk"

Write-Host "重庆交通大学校园网自动重连安装程序 v1.1.0（有线 / 三网版）" -ForegroundColor Cyan
Write-Host "密码由 Windows DPAPI 加密后保存在本机，只能由当前 Windows 用户解密。" -ForegroundColor Gray
Write-Host "本机为网线连接，不需要 Wi-Fi 配置，脚本会自动使用有线网卡 IP + 真实 MAC 认证。" -ForegroundColor Gray
Write-Host ""

$username = Read-Host "校园网账号"
if ([string]::IsNullOrWhiteSpace($username)) { throw "账号不能为空。" }

$securePassword = Read-Host "校园网新密码（输入时不会显示）" -AsSecureString
if ($securePassword.Length -eq 0) { throw "密码不能为空。" }
$encryptedPassword = ConvertFrom-SecureString $securePassword

# 三网（电信/联通/移动）在 ePortal 上靠账号后缀区分出口，选错会提示密码错误或账号不存在。
Write-Host ""
Write-Host "请选择运营商（校园网账号后缀）：" -ForegroundColor Cyan
Write-Host "  1) 中国联通  @unicom（默认）"
Write-Host "  2) 中国移动  @cmcc"
Write-Host "  3) 中国电信  @telecom"
Write-Host "  4) 不接后缀，或手动输入其它后缀"
$carrierChoice = (Read-Host "请输入序号（直接 Enter 使用联通）").Trim()
switch ($carrierChoice) {
    "2" { $carrier = "cmcc";    $accountSuffix = "@cmcc" }
    "3" { $carrier = "telecom"; $accountSuffix = "@telecom" }
    "4" {
        $carrier = "custom"
        $custom = (Read-Host "请输入后缀（如 @cmcc；直接 Enter 表示不加后缀）").Trim()
        if ($custom -ne "" -and -not $custom.StartsWith("@")) { $custom = "@$custom" }
        $accountSuffix = $custom
    }
    default { $carrier = "unicom"; $accountSuffix = "@unicom" }
}
if ($accountSuffix -eq "") {
    Write-Host "已选择：不加后缀，登录账号即为 $username" -ForegroundColor Gray
} else {
    Write-Host "已选择：$carrier，登录账号为 $username$accountSuffix" -ForegroundColor Gray
}

# 有线本机一般不需要 Wi-Fi 重连。只有当你把这份脚本拿回笔记本用、且 Wi-Fi 自身
# 也会断开时，才需要填。台式机直接按 Enter 留空即可。
$wifiProfile = ""
try {
    $wlan = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.MediaType -match "802.11" -or $_.InterfaceDescription -match "Wi-Fi|WLAN|Wireless" }
    if ($wlan -and ($wlan.Status -ne "Disabled" -or ($wlan | Where-Object { $_.Status -eq "Up" }))) {
        Write-Host ""
        Write-Host "检测到本机有可用无线网卡。如果 Wi-Fi 自身也会断开，请输入 Windows 中保存的 Wi-Fi 配置名称。" -ForegroundColor Gray
        Write-Host "如果只是网页认证掉线（有线台式机常见情况），直接按 Enter 留空。" -ForegroundColor Gray
        $wifiProfile = Read-Host "Wi-Fi 配置名称（可选，有线请留空）"
    } else {
        Write-Host ""
        Write-Host "未检测到启用的无线网卡，已按有线模式安装（跳过 Wi-Fi 配置）。" -ForegroundColor Gray
    }
} catch {
    Write-Host ""
    $wifiProfile = Read-Host "Wi-Fi 配置名称（可选，有线请直接 Enter）"
}

New-Item -ItemType Directory -Force -Path $InstallDirectory | Out-Null
Copy-Item -LiteralPath (Join-Path $SourceDirectory "AutoReconnect.ps1") -Destination $InstallDirectory -Force
Copy-Item -LiteralPath (Join-Path $SourceDirectory "Uninstall.ps1") -Destination $InstallDirectory -Force

$config = [ordered]@{
    username = $username.Trim()
    encrypted_password = $encryptedPassword
    carrier = $carrier
    account_suffix = $accountSuffix
    wifi_profile = $wifiProfile.Trim()
    gateway_url = "http://172.18.1.17/"
    portal_login_url = "http://172.19.7.17:801/eportal/portal/login"
    probe_url = "http://www.msftconnecttest.com/connecttest.txt"
    probe_expected = "Microsoft Connect Test"
}
$config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallDirectory "config.json") -Encoding UTF8

$powershellPath = (Get-Command powershell.exe).Source
$arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $InstallDirectory "AutoReconnect.ps1")
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = $powershellPath
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $InstallDirectory
$shortcut.WindowStyle = 7
$shortcut.Description = "校园网掉线后自动重新认证"
$shortcut.Save()

$pidPath = Join-Path $InstallDirectory "monitor.pid"
$monitorPath = Join-Path $InstallDirectory "AutoReconnect.ps1"
if (Test-Path -LiteralPath $pidPath) {
    $monitorPid = 0
    [void][int]::TryParse((Get-Content -Raw -LiteralPath $pidPath).Trim(), [ref]$monitorPid)
    if ($monitorPid -gt 0) {
        $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $monitorPid" -ErrorAction SilentlyContinue
        if ($processInfo -and $processInfo.CommandLine -like "*$monitorPath*") {
            Stop-Process -Id $monitorPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }
}

Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden

Write-Host ""
Write-Host "安装完成，监控程序已经启动，并将在登录 Windows 后自动运行。" -ForegroundColor Green
Write-Host "安装目录：$InstallDirectory"
Write-Host "日志文件：$(Join-Path $InstallDirectory 'campus-net.log')"
Write-Host ""
Read-Host "按 Enter 关闭"
