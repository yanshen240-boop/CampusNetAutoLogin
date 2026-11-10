<#
  CampusNetAutoLogin · PC 端配置工具
  作用：通过 adb 把校园网账号写进手机模块配置，并立刻试一次登录。
  用法：双击 配置校园网.cmd，或
        powershell -NoProfile -ExecutionPolicy Bypass -File setup-campusnet.ps1
#>
param(
    [string]$Adb,
    [string]$Account,
    [string]$Password,
    [ValidateSet('unicom', 'cmcc', 'telecom', 'none')]
    [string]$Carrier,
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'

# adb shell 输出是 UTF-8，控制台默认是 GBK，不设这个中文会乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Info($m) { Write-Host "  $m" -ForegroundColor Gray }
function Ok($m) { Write-Host "  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Fail($m) {
    Write-Host "  $m" -ForegroundColor Red
    if (-not $NoPause) { Read-Host "按回车退出" | Out-Null }
    exit 1
}

Write-Host ""
Write-Host " === CampusNet 校园网自动重连 · 配置助手 ===" -ForegroundColor Cyan
Write-Host ""

# ---------- 1. 找 adb ----------
$candidates = @(
    $Adb,
    $env:ADB,
    (Get-Command adb -ErrorAction SilentlyContinue).Source,
    'C:\ruanjian\MuMuPlayer\nx_main\adb.exe',
    "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
    'C:\platform-tools\adb.exe'
)
$adbPath = $null
foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { $adbPath = $c; break }
}
if (-not $adbPath) {
    Fail "找不到 adb.exe。请安装 platform-tools，或把 adb 目录加到 PATH。"
}
Info "adb: $adbPath"

# ---------- 2. 选设备 ----------
& $adbPath start-server 2>&1 | Out-Null
$devOut = (& $adbPath devices 2>&1 | Out-String)
$serials = @()
foreach ($line in ($devOut -split "`r?`n")) {
    if ($line -match '^(\S+)\s+device') {
        $sn = $Matches[1]
        if ($sn -and $sn -notlike 'emulator-*' -and $serials -notcontains $sn) { $serials += $sn }
    }
}
if ($serials.Count -eq 0) {
    Fail "没有检测到手机。请确认：数据线已连接、已开启「USB 调试」、手机上点了「允许调试」。"
}
$serial = $serials[0]
if ($serials.Count -gt 1) {
    Write-Host "  检测到多台设备：" -ForegroundColor Yellow
    for ($i = 0; $i -lt $serials.Count; $i++) { Write-Host ("    [{0}] {1}" -f ($i + 1), $serials[$i]) }
    $pick = Read-Host "  选择手机序号"
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $serials.Count) { Fail "序号无效" }
    $serial = $serials[$idx - 1]
}
Info "设备: $serial"

function Run-Sh([string]$Cmd) {
    return (& $adbPath -s $serial shell "su -c '$Cmd'" 2>&1) -join "`n"
}

# ---------- 3. root 检查 ----------
$idOut = Run-Sh "id"
if ($idOut -notmatch 'uid=0') {
    Fail "手机没有 root 权限（su 不可用）。本模块需要 Magisk / KernelSU 环境。"
}
Info "root: 正常"

# ---------- 4. 模块是否已装 ----------
$ctl = ''
foreach ($p in @('/data/adb/modules/campusnet_autologin/bin/campusctl', '/data/adb/modules_update/campusnet_autologin/bin/campusctl')) {
    $r = Run-Sh ("[ -x $p ] && echo YES")
    if ($r -match 'YES') { $ctl = $p; break }
}
if (-not $ctl) {
    $zip = $null
    foreach ($d in @($PSScriptRoot, (Join-Path $PSScriptRoot '..'), (Join-Path $PSScriptRoot '..\dist'), (Join-Path $PSScriptRoot 'dist'))) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $hit = Get-ChildItem -LiteralPath $d -Filter 'CampusNetAutoLogin-Magisk-v*.zip' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($hit) { $zip = $hit.FullName; break }
    }
    if (-not $zip) {
        Fail "手机上还没安装模块，且找不到 CampusNetAutoLogin-Magisk-v*.zip。请先把 zip 放到本脚本同一目录（或在 Magisk 里刷入）。"
    }
    Warn "未检测到已安装模块，正在通过 Magisk 安装…"
    Info "上传 zip 到手机…"
    & $adbPath -s $serial push $zip /data/local/tmp/cn-module.zip | Out-Null
    $inst = Run-Sh "magisk --install-module /data/local/tmp/cn-module.zip"
    Write-Host $inst -ForegroundColor DarkGray
    if ($inst -notmatch 'Done') { Fail "模块安装失败，请在 Magisk App 里手动刷入 zip。" }
    $ctl = '/data/adb/modules_update/campusnet_autologin/bin/campusctl'
    $script:needReboot = $true
    Ok "模块已安装（重启后正式生效，现在先写入配置）"
}

# ---------- 5. 账号信息 ----------
if (-not $Account) {
    Write-Host ""
    $Account = Read-Host "  校园网账号（学号/工号，不要带 @unicom 这类后缀）"
}
if (-not $Account) { Fail "账号不能为空" }

if (-not $Password) {
    $sec = Read-Host "  校园网密码（输入不回显）" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
if (-not $Password) { Fail "密码不能为空" }

if (-not $Carrier) {
    Write-Host ""
    Write-Host "  运营商（决定账号后缀，选错会提示密码错误）：" -ForegroundColor Gray
    Write-Host "    [1] 联通 @unicom（默认）"
    Write-Host "    [2] 移动 @cmcc"
    Write-Host "    [3] 电信 @telecom"
    Write-Host "    [4] 不加后缀"
    $c = Read-Host "  选择 [1-4]"
    switch ($c) {
        '2' { $Carrier = 'cmcc' }
        '3' { $Carrier = 'telecom' }
        '4' { $Carrier = 'none' }
        default { $Carrier = 'unicom' }
    }
}

$suffixMap = @{ unicom = '@unicom'; cmcc = '@cmcc'; telecom = '@telecom'; none = '' }
$suffix = $suffixMap[$Carrier]
Info "账号: $Account$suffix"

# ---------- 6. 写配置 ----------
# 配置按 sh 源码读取，值用单引号包裹，内部的 ' 写成 '\''
$pwEsc = $Password.Replace("'", "'\''")
$cfg = @"
# ============ CampusNetAutoLogin 配置（由 PC 助手生成）============
username='$Account'
password='$pwEsc'
carrier='$Carrier'
account_suffix=''
portal_login_url='http://172.19.7.17:801/eportal/portal/login'
gateway_url=''
probe_url='http://www.msftconnecttest.com/connecttest.txt'
probe_expected='Microsoft Connect Test'
interval='30'
mac_override=''
"@

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cfg))
$writeOut = Run-Sh "mkdir -p /data/adb/campusnet; echo $b64 | base64 -d > /data/adb/campusnet/config.conf; chmod 600 /data/adb/campusnet/config.conf; echo WROTE"
if ($writeOut -notmatch 'WROTE') { Fail "写入配置失败：$writeOut" }
Ok "配置已写入 /data/adb/campusnet/config.conf"

# 让后台监控按新配置重启（不重启手机也能立刻生效）
Run-Sh "$ctl restart" | Out-Null

# ---------- 7. 立刻试一次 ----------
Write-Host ""
Write-Host "  正在测试认证…" -ForegroundColor Cyan
$test = Run-Sh "$ctl login"
Write-Host $test

if ($test -match '已恢复联网') {
    Write-Host ""
    Ok "登录成功，现在应该可以正常上网了。"
    if ($script:needReboot) {
        Warn "模块还没正式挂载（system/bin/campusctl 不会出现在 PATH），建议重启手机完成安装。"
    }
}
elseif ($test -match '学号|不存在') {
    Warn "账号不存在——检查学号是否输错，或是否把运营商后缀也填进了账号。"
}
elseif ($test -match '密码') {
    Warn "密码相关错误——先确认运营商后缀选对了没（联通/移动/电信是不同出口）。"
}
else {
    Warn "没有成功。把上面的提示和手机里的日志（campusctl log 30）一起看。"
}

if (-not $NoPause) {
    Write-Host ""
    $rb = Read-Host "  是否现在重启手机让模块开始自动运行？(y/N)"
    if ($rb -match '^[Yy]') {
        & $adbPath -s $serial reboot
        Ok "已发送重启命令。重启后模块会自动在后台重连。"
    } else {
        Info "已跳过重启。随时可以重跑本工具，或在 Magisk 里重启。"
    }
    Write-Host ""
}
