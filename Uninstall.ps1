$ErrorActionPreference = "Stop"

$InstallDirectory = Join-Path $env:LOCALAPPDATA "CampusNetAutoLogin"
$ShortcutPath = Join-Path ([Environment]::GetFolderPath("Startup")) "CampusNetAutoLogin.lnk"
$PidPath = Join-Path $InstallDirectory "monitor.pid"
$MonitorPath = Join-Path $InstallDirectory "AutoReconnect.ps1"

if (Test-Path -LiteralPath $PidPath) {
    $monitorPid = 0
    [void][int]::TryParse((Get-Content -Raw -LiteralPath $PidPath).Trim(), [ref]$monitorPid)
    if ($monitorPid -gt 0) {
        $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $monitorPid" -ErrorAction SilentlyContinue
        if ($processInfo -and $processInfo.CommandLine -like "*$MonitorPath*") {
            Stop-Process -Id $monitorPid -Force -ErrorAction SilentlyContinue
        }
    }
}

Remove-Item -LiteralPath $ShortcutPath -Force -ErrorAction SilentlyContinue
Write-Host "已停止自动重连并移除开机启动。" -ForegroundColor Green
Write-Host "为了保留日志和便于恢复，配置目录未自动删除：$InstallDirectory"
Write-Host "如需彻底删除，可在确认后手动删除该目录。"
Read-Host "按 Enter 关闭"
