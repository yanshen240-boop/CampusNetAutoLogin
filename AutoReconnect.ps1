param(
    [switch]$Once,
    [int]$IntervalSeconds = 30,
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA "CampusNetAutoLogin\config.json")
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$AppDirectory = Split-Path -Parent $ConfigPath
$LogPath = Join-Path $AppDirectory "campus-net.log"
$PidPath = Join-Path $AppDirectory "monitor.pid"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")

    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 2MB) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.old" -Force
        }
        $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
        # Logging must never stop reconnection.
    }
}

function New-HttpClient {
    param([bool]$AllowRedirect = $false)

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $AllowRedirect
    $handler.UseCookies = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(8)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) CampusNetAutoLogin/1.0")
    return $client
}

function Invoke-HttpGet {
    param([string]$Url, [bool]$AllowRedirect = $false)

    $client = New-HttpClient -AllowRedirect $AllowRedirect
    try {
        $response = $client.GetAsync($Url).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Content = $content
            Location = if ($null -ne $response.Headers.Location) { $response.Headers.Location.ToString() } else { $null }
        }
    } finally {
        $client.Dispose()
    }
}

function Test-Internet {
    param($Config)

    try {
        $probe = Invoke-HttpGet -Url $Config.probe_url -AllowRedirect $false
        if ($probe.StatusCode -eq 200 -and $probe.Content.Trim() -eq $Config.probe_expected) {
            return $true
        }
    } catch {
        # Try the HTTPS backup below.
    }

    try {
        $backup = Invoke-HttpGet -Url "https://www.baidu.com/" -AllowRedirect $true
        return $backup.StatusCode -ge 200 -and $backup.StatusCode -lt 400
    } catch {
        return $false
    }
}

function ConvertFrom-QueryString {
    param([string]$Url)

    $result = @{}
    try {
        $uri = [Uri]$Url
        $query = $uri.Query.TrimStart('?')
        foreach ($part in $query.Split('&', [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $pair = $part.Split('=', 2)
            $key = [Uri]::UnescapeDataString($pair[0].Replace('+', ' ')).ToLower()
            $value = if ($pair.Count -gt 1) { [Uri]::UnescapeDataString($pair[1].Replace('+', ' ')) } else { "" }
            $result[$key] = $value
        }
        # 有些 Portal 把参数放在 fragment (#...) 里，这里也解析一下。
        $frag = $uri.Fragment.TrimStart('#')
        if ($frag -match "=") {
            foreach ($part in $frag.Split('&', [System.StringSplitOptions]::RemoveEmptyEntries)) {
                $pair = $part.Split('=', 2)
                $key = [Uri]::UnescapeDataString($pair[0].Replace('+', ' ')).ToLower()
                $value = if ($pair.Count -gt 1) { [Uri]::UnescapeDataString($pair[1].Replace('+', ' ')) } else { "" }
                if (-not $result.ContainsKey($key)) { $result[$key] = $value }
            }
        }
    } catch {
        Write-Log "无法解析认证重定向地址。" "WARN"
    }
    return $result
}

function Extract-PortalParamsFromText {
    param([string]$Text)

    $found = @{}
    if ([string]::IsNullOrEmpty($Text)) { return $found }
    foreach ($m in [regex]::Matches($Text, "(?i)(wlanuserip|wlanacip|wlanacname|wlanuseripv6|wlanusermac|wlanvlanid)\s*=\s*([^&'""\s<>;]+)")) {
        $k = $m.Groups[1].Value.ToLower()
        try { $v = [Uri]::UnescapeDataString($m.Groups[2].Value.Trim()) } catch { $v = $m.Groups[2].Value.Trim() }
        if (-not $found.ContainsKey($k)) { $found[$k] = $v }
    }
    return $found
}

function Get-WiredEndpoint {
    # 有线优先：取有默认网关、状态 Up 的网卡，优先以太网，返回本机 IP + 真实 MAC。
    try {
        $configs = Get-NetIPConfiguration |
            Where-Object { $_.NetAdapter.Status -eq "Up" -and $null -ne $_.IPv4DefaultGateway }
        if (-not $configs) { return @{ Ip = ""; Mac = "000000000000"; Alias = "" } }

        $ordered = $configs | Sort-Object {
            $alias = [string]$_.InterfaceAlias
            $desc = [string]$_.NetAdapter.InterfaceDescription
            if ($alias -match "以太|Ethernet|本地连接|有线" -or $desc -match "Ethernet|Realtek|Intel.*Ethernet|GbE") { 0 } else { 1 }
        }, { $_.NetIPv4Interface.RouteMetric }

        foreach ($c in $ordered) {
            $ip = $c.IPv4Address |
                Where-Object { $_.IPAddress -and $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
                Select-Object -ExpandProperty IPAddress -First 1
            if ($ip) {
                $mac = ""
                try { $mac = ([string]$c.NetAdapter.MacAddress -replace "[-:]", "").ToLower() } catch { }
                if ([string]::IsNullOrWhiteSpace($mac)) { $mac = "000000000000" }
                return @{ Ip = [string]$ip; Mac = $mac; Alias = [string]$c.InterfaceAlias }
            }
        }
    } catch {
    }
    return @{ Ip = ""; Mac = "000000000000"; Alias = "" }
}

function Get-PortalContext {
    param($Config)

    $context = @{ wlanuserip = ""; wlanacip = ""; wlanacname = "" }

    # 有线和 Wi-Fi 共用同一套 ePortal，但有线环境下重定向可能是 302，也可能是
    # 200 + 页面内 JS 跳转，所以 Location 和 Body 都要解析。多试几个探测地址。
    $candidates = @()
    if ($Config.gateway_url) { $candidates += [string]$Config.gateway_url }
    if ($Config.probe_url) { $candidates += [string]$Config.probe_url }
    $candidates += "http://captive.apple.com/"
    $candidates += "http://connect.rom.miui.com/generate_204"
    $candidates = $candidates | Select-Object -Unique

    foreach ($url in $candidates) {
        try {
            $response = Invoke-HttpGet -Url $url -AllowRedirect $false
            $merged = @{}
            if ($response.Location) {
                foreach ($kv in (ConvertFrom-QueryString -Url $response.Location).GetEnumerator()) {
                    $merged[$kv.Key] = $kv.Value
                }
                # Location 可能是相对路径，里面也可能直接带参数。
                foreach ($kv in (Extract-PortalParamsFromText -Text $response.Location).GetEnumerator()) {
                    if (-not $merged.ContainsKey($kv.Key)) { $merged[$kv.Key] = $kv.Value }
                }
            }
            foreach ($kv in (Extract-PortalParamsFromText -Text $response.Content).GetEnumerator()) {
                if (-not $merged.ContainsKey($kv.Key)) { $merged[$kv.Key] = $kv.Value }
            }
            foreach ($key in @("wlanuserip", "wlanacip", "wlanacname")) {
                if ([string]::IsNullOrWhiteSpace($context[$key]) -and $merged.ContainsKey($key)) {
                    $context[$key] = [string]$merged[$key]
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($context.wlanuserip)) { break }
        } catch {
            continue
        }
    }

    if ([string]::IsNullOrWhiteSpace($context.wlanuserip)) {
        $endpoint = Get-WiredEndpoint
        if (-not [string]::IsNullOrWhiteSpace($endpoint.Ip)) {
            $context.wlanuserip = $endpoint.Ip
            Write-Log "未从网关读到重定向参数，使用本机有线 IPv4：$($endpoint.Ip)（$($endpoint.Alias)）。"
        } else {
            Write-Log "无法从网关读取重定向参数，且未找到可用 IPv4。" "WARN"
        }
    }
    return $context
}

function ConvertTo-QueryString {
    param([System.Collections.IDictionary]$Values)

    $pairs = foreach ($entry in $Values.GetEnumerator()) {
        "{0}={1}" -f [Uri]::EscapeDataString([string]$entry.Key), [Uri]::EscapeDataString([string]$entry.Value)
    }
    return $pairs -join "&"
}

function Get-PlainPassword {
    param([string]$EncryptedPassword)

    $secure = ConvertTo-SecureString $EncryptedPassword
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Get-AccountSuffix {
    param($Config)

    # 校园网三网（电信/联通/移动）在 ePortal 上靠账号后缀区分出口：
    #   @telecom 电信   @unicom 联通   @cmcc 移动   空字符串表示不接后缀。
    # 新配置直接写 account_suffix；老配置（只有 username）沿用旧版默认的联通后缀。
    if ($null -ne $Config.PSObject.Properties["account_suffix"]) {
        $suffix = [string]$Config.account_suffix
    } else {
        switch ([string]$Config.carrier) {
            "telecom" { $suffix = "@telecom" }
            "cmcc"    { $suffix = "@cmcc" }
            "none"    { $suffix = "" }
            default   { $suffix = "@unicom" }
        }
    }

    $suffix = $suffix.Trim()
    if ($suffix -ne "" -and -not $suffix.StartsWith("@")) { $suffix = "@$suffix" }
    return $suffix
}

function Invoke-PortalLogin {
    param($Config)

    $context = Get-PortalContext -Config $Config
    $endpoint = Get-WiredEndpoint
    if ([string]::IsNullOrWhiteSpace($context.wlanuserip)) {
        Write-Log "没有获取到当前 IPv4，暂不提交认证。" "ERROR"
        return $false
    }
    # 有线必须上报真实网卡 MAC（去分隔符小写），原来写死的 000000000000 在
    # 部分有线 Portal 上会被拒绝或记为异常。
    $macToSend = $endpoint.Mac
    if ([string]::IsNullOrWhiteSpace($macToSend)) { $macToSend = "000000000000" }

    $plainPassword = Get-PlainPassword -EncryptedPassword $Config.encrypted_password
    try {
        $accountSuffix = Get-AccountSuffix -Config $Config
        $parameters = [ordered]@{
            callback = "dr1007"
            login_method = "1"
            user_account = ",0,$($Config.username)$accountSuffix"
            user_password = $plainPassword
            wlan_user_ip = $context.wlanuserip
            wlan_user_ipv6 = ""
            wlan_user_mac = $macToSend
            wlan_vlan_id = "0"
            wlan_ac_ip = $context.wlanacip
            wlan_ac_name = $context.wlanacname
            mac_type = "0"
            UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
            jsVersion = "4.2.2"
            terminal_type = "1"
            lang = "zh-cn"
            v = [string](Get-Random -Minimum 1000 -Maximum 9999)
        }
        $url = "$($Config.portal_login_url)?$(ConvertTo-QueryString -Values $parameters)"
        $response = Invoke-HttpGet -Url $url -AllowRedirect $false
        $safeText = ($response.Content -replace "[\r\n]+", " ")
        if ($safeText.Length -gt 300) { $safeText = $safeText.Substring(0, 300) }

        if ($response.StatusCode -eq 200 -and $response.Content -match '("result"\s*:\s*"?1"?|认证成功|Portal协议认证成功|already online|已经在线|在线用户)') {
            Write-Log "认证服务器已接受登录请求，当前 IP：$($context.wlanuserip)，MAC：$macToSend。"
            return $true
        }

        Write-Log "认证服务器未返回成功结果：$safeText" "WARN"
        return $false
    } catch {
        Write-Log "登录请求失败：$($_.Exception.Message)" "ERROR"
        return $false
    } finally {
        $plainPassword = $null
    }
}

function Restore-NetworkLink {
    param($Config)

    # 兼容旧笔记本配置：如果配了 Wi-Fi 名称，仍然尝试重连 Wi-Fi。
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.wifi_profile)) {
        try {
            & netsh.exe wlan connect "name=$($Config.wifi_profile)" | Out-Null
            Write-Log "已请求连接 Wi-Fi 配置：$($Config.wifi_profile)。"
            Start-Sleep -Seconds 6
        } catch {
            Write-Log "请求重连 Wi-Fi 失败：$($_.Exception.Message)" "WARN"
        }
        return
    }

    # 有线本机：网线不会像 Wi-Fi 那样“重连”，这里只检查链路状态。
    # 如果网卡显示断开，登录必然失败，直接提示查网线，避免空转打爆 Portal。
    try {
        $endpoint = Get-WiredEndpoint
        if ([string]::IsNullOrWhiteSpace($endpoint.Ip)) {
            $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceDescription -match "Ethernet|Realtek|Intel|GbE" -or $_.Name -match "以太|Ethernet" }
            $status = ($adapters | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ", "
            if ([string]::IsNullOrWhiteSpace($status)) { $status = "未找到以太网网卡" }
            Write-Log "有线网卡无可用 IPv4（$status），请检查网线/网口指示灯，暂不提交认证。" "WARN"
        }
    } catch {
        # 状态检查失败不阻断后续登录尝试。
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "找不到配置文件：$ConfigPath。请先运行 Setup.ps1。"
}

if ($IntervalSeconds -lt 15) { $IntervalSeconds = 15 }
$config = Get-Content -Raw -LiteralPath $ConfigPath -Encoding UTF8 | ConvertFrom-Json
$mutexName = "Local\CampusNetAutoLogin-$([Environment]::UserName)"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0, $false)) {
    Write-Log "已有一个监控进程正在运行，本进程退出。" "WARN"
    exit 0
}

Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
$suffixForLog = Get-AccountSuffix -Config $config
if ($suffixForLog -eq "") { $suffixForLog = "(无后缀)" }
Write-Log "自动重连监控已启动（有线/三网版 v1.1.0），账号后缀：$suffixForLog。"
$lastState = ""

try {
    do {
        if (Test-Internet -Config $config) {
            if ($lastState -ne "online") { Write-Log "外网连接正常。" }
            $lastState = "online"
        } else {
            if ($lastState -ne "offline") { Write-Log "检测到外网不可用，开始恢复连接。" "WARN" }
            $lastState = "offline"
            Restore-NetworkLink -Config $config

            if (-not (Test-Internet -Config $config)) {
                [void](Invoke-PortalLogin -Config $config)
                Start-Sleep -Seconds 3
                if (Test-Internet -Config $config) {
                    Write-Log "校园网已恢复。"
                    $lastState = "online"
                } else {
                    Write-Log "本次恢复后仍无法访问外网，稍后重试。" "WARN"
                }
            }
        }

        if (-not $Once) { Start-Sleep -Seconds $IntervalSeconds }
    } while (-not $Once)
} finally {
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
    Write-Log "自动重连监控已停止。"
}
