# ============================================================
#  WinLoginAlert.ps1   (single-file edition)
#  Emails you on Windows login/unlock AND on failed (wrong-password) attempts.
#
#  USAGE (run in an elevated / Administrator PowerShell):
#     powershell -NoProfile -ExecutionPolicy Bypass -File ".\WinLoginAlert.ps1" -Install
#     powershell -NoProfile -ExecutionPolicy Bypass -File ".\WinLoginAlert.ps1" -Uninstall
#  (No switch = it just sends one alert; the scheduled tasks call it that way.)
# ============================================================

param(
    [ValidateSet('Success','Failed')]
    [string]$Mode = 'Success',
    [switch]$Install,
    [switch]$Uninstall
)

# ===================== CONFIG (edit these) =====================
# Put YOUR OWN Resend API key and YOUR OWN email here before installing.
# The onboarding@resend.dev sender only delivers to your Resend account email.
$RESEND_API_KEY = 're_YOUR_RESEND_API_KEY_HERE'
$ALERT_EMAIL    = 'your-resend-account@example.com'
# ==============================================================

$InstallDir   = 'C:\ProgramData\WinLoginAlert'
$InstalledPs1 = Join-Path $InstallDir 'WinLoginAlert.ps1'
$TaskSuccess  = 'Windows Login Email Alert (Resend)'
$TaskFailed   = 'Windows Login FAIL Alert (Resend)'

# Runtime state/logs -> per-user writable location (works for both the logged-on
# user and SYSTEM; the InstallDir is locked read-only for standard users).
$RunDir = Join-Path $env:LOCALAPPDATA 'WinLoginAlert'
try { if (-not (Test-Path $RunDir)) { New-Item -ItemType Directory -Path $RunDir -Force | Out-Null } } catch { $RunDir = $env:TEMP }

function Write-ErrLog([string]$msg) {
    try { Add-Content -Path (Join-Path $RunDir 'last_error.log') -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8 } catch { }
}

# ------------------------------------------------------------------
#  SEND AN ALERT
# ------------------------------------------------------------------
function Send-Alert([string]$Kind) {
    try {
        if ([string]::IsNullOrWhiteSpace($RESEND_API_KEY) -or [string]::IsNullOrWhiteSpace($ALERT_EMAIL)) {
            throw 'RESEND_API_KEY or ALERT_EMAIL not set in the script config.'
        }

        # ---- Throttle (one email per 120s, per kind) ----
        $stateFile = Join-Path $RunDir ("last_send_{0}.txt" -f $Kind.ToLower())
        $nowTicks  = (Get-Date).Ticks
        if (Test-Path $stateFile) {
            try {
                $lastTicks = [long]((Get-Content $stateFile -Raw).Trim())
                if ([timespan]::FromTicks($nowTicks - $lastTicks).TotalSeconds -lt 120) { return }
            } catch { }
        }

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        # ---- Wait for network (up to 30s) ----
        $online = $false
        for ($i = 0; $i -lt 10; $i++) {
            try { if (Test-Connection -ComputerName '1.1.1.1' -Count 1 -Quiet -ErrorAction Stop) { $online = $true; break } } catch { }
            Start-Sleep -Seconds 3
        }

        $pcName    = $env:COMPUTERNAME
        $timestamp = Get-Date -Format 'yyyy-MM-dd hh:mm:ss tt'

        # ---- Who? ----
        if ($Kind -eq 'Failed') {
            # Running as SYSTEM: pull the attempted account from the latest 4625 event.
            $who = 'Unknown'; $logonType = ''
            try {
                $e   = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625 } -MaxEvents 1 -ErrorAction Stop
                $xml = [xml]$e.ToXml()
                $who       = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'
                $logonType = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'LogonType' }).'#text'
            } catch { }
            # Only alert on interactive(2) / unlock(7) / RDP(10) failures; ignore service/network noise.
            if ($logonType -and @('2','7','10') -notcontains $logonType) { return }
        } else {
            $who = $env:USERNAME
        }

        # ---- Local IPv4 ----
        $localIp = 'Unknown'
        try {
            $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                  Select-Object -First 1 -ExpandProperty IPAddress
            if ($ip) { $localIp = $ip }
        } catch { }

        # ---- Wi-Fi SSID ----
        $ssid = 'Ethernet/Unknown'
        try {
            $line = (netsh wlan show interfaces 2>$null) | Select-String -Pattern '^\s*SSID\s*:' | Select-Object -First 1
            if ($line) { $v = ($line.ToString() -split ':', 2)[1].Trim(); if ($v) { $ssid = $v } }
        } catch { }

        # ---- Public IP ----
        $publicIp = 'Unavailable'
        if ($online) { try { $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 3 -UseBasicParsing).ToString().Trim() } catch { } }

        # ---- Compose ----
        function Enc([object]$s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }
        if ($Kind -eq 'Failed') {
            $title = '&#9888;&#65039; Failed Unlock / Login Attempt'
            $subj  = "ALERT: Failed login attempt on $pcName"
            $accent = '#c0392b'
        } else {
            $title = '&#128275; Windows Login / Unlock'
            $subj  = "Windows Login Alert: $who on $pcName"
            $accent = '#1e8449'
        }
        $html = @"
<div style="font-family:Segoe UI,Arial,sans-serif;color:#222;">
  <h2 style="margin:0 0 12px 0;color:$accent;">$title</h2>
  <table cellpadding="8" cellspacing="0" style="border-collapse:collapse;border:1px solid #ddd;font-size:14px;">
    <tr><td style="background:#f4f4f4;border:1px solid #ddd;"><b>Account</b></td><td style="border:1px solid #ddd;">$(Enc $who)</td></tr>
    <tr><td style="background:#f4f4f4;border:1px solid #ddd;"><b>PC Name</b></td><td style="border:1px solid #ddd;">$(Enc $pcName)</td></tr>
    <tr><td style="background:#f4f4f4;border:1px solid #ddd;"><b>Timestamp</b></td><td style="border:1px solid #ddd;">$(Enc $timestamp)</td></tr>
    <tr><td style="background:#f4f4f4;border:1px solid #ddd;"><b>Wi-Fi SSID</b></td><td style="border:1px solid #ddd;">$(Enc $ssid)</td></tr>
    <tr><td style="background:#f4f4f4;border:1px solid #ddd;"><b>Local IP</b></td><td style="border:1px solid #ddd;">$(Enc $localIp)</td></tr>
    <tr><td style="background:#f4f4f4;border:1px solid #ddd;"><b>Public IP</b></td><td style="border:1px solid #ddd;">$(Enc $publicIp)</td></tr>
  </table>
</div>
"@
        $body = @{
            from    = 'Windows Security Monitor <onboarding@resend.dev>'
            to      = @($ALERT_EMAIL)
            subject = $subj
            html    = $html
        } | ConvertTo-Json -Depth 4

        $headers = @{ 'Authorization' = "Bearer $RESEND_API_KEY"; 'Content-Type' = 'application/json'; 'User-Agent' = 'WinLoginAlert/1.0' }
        Invoke-RestMethod -Uri 'https://api.resend.com/emails' -Method Post -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 | Out-Null

        (Get-Date).Ticks.ToString() | Set-Content -Path $stateFile -Encoding ASCII
    }
    catch { Write-ErrLog ($_.Exception.Message + ' | ' + $_.ScriptStackTrace) }
}

# ------------------------------------------------------------------
#  INSTALL
# ------------------------------------------------------------------
function Do-Install {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    if (-not $isAdmin) { Write-Error 'Run -Install in an elevated (Administrator) PowerShell.'; return }

    Write-Host 'Preparing install folder...' -ForegroundColor Cyan
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

    # Remove legacy multi-file layout if present
    'Send-LoginAlert.ps1','Install-Task.ps1','Uninstall-Task.ps1','.env' | ForEach-Object {
        $old = Join-Path $InstallDir $_; if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
    }
    Get-ScheduledTask -TaskName $TaskSuccess -ErrorAction SilentlyContinue | ForEach-Object { Unregister-ScheduledTask -TaskName $TaskSuccess -Confirm:$false }

    # Deploy this script into the install folder
    if ($PSCommandPath -and ((Resolve-Path $PSCommandPath).Path -ne $InstalledPs1)) {
        Copy-Item $PSCommandPath $InstalledPs1 -Force
    }

    Write-Host 'Locking folder permissions...' -ForegroundColor Cyan
    icacls $InstallDir /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' 'Users:(OI)(CI)RX' | Out-Null

    Write-Host 'Enabling logon-failure auditing (for wrong-password alerts)...' -ForegroundColor Cyan
    auditpol /set /subcategory:"Logon" /failure:enable | Out-Null

    $exec = 'conhost.exe'
    $base = "--headless powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$InstalledPs1`""

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

    # ---- Task 1: SUCCESS (logon + unlock), runs as the logged-on user ----
    Write-Host 'Registering success task (logon + unlock)...' -ForegroundColor Cyan
    $aSucc  = New-ScheduledTaskAction -Execute $exec -Argument "$base -Mode Success"
    $tLogon = New-ScheduledTaskTrigger -AtLogOn
    $stClass = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger'
    $tUnlock = New-CimInstance -CimClass $stClass -ClientOnly
    $tUnlock.Enabled = $true; $tUnlock.StateChange = 8   # SessionUnlock
    $pUser = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskSuccess -Action $aSucc -Trigger @($tLogon, $tUnlock) -Principal $pUser -Settings $settings -Description 'Email alert on Windows logon/unlock.' -Force | Out-Null

    # ---- Task 2: FAILED (Security event 4625), runs as SYSTEM ----
    Write-Host 'Registering failed-attempt task (event 4625)...' -ForegroundColor Cyan
    $aFail = New-ScheduledTaskAction -Execute $exec -Argument "$base -Mode Failed"
    $evClass = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
    $tEvent  = New-CimInstance -CimClass $evClass -ClientOnly
    $tEvent.Enabled = $true
    $tEvent.Subscription = '<QueryList><Query Id="0" Path="Security"><Select Path="Security">*[System[EventID=4625]]</Select></Query></QueryList>'
    $pSystem = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskFailed -Action $aFail -Trigger $tEvent -Principal $pSystem -Settings $settings -Description 'Email alert on failed Windows login/unlock.' -Force | Out-Null

    # ---- Test the success send ----
    Write-Host 'Sending a test alert...' -ForegroundColor Cyan
    Remove-Item (Join-Path $RunDir 'last_send_success.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $RunDir 'last_error.log')        -Force -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $TaskSuccess
    Start-Sleep -Seconds 18
    if (Test-Path (Join-Path $RunDir 'last_error.log')) {
        Write-Host "[!] Errors logged:" -ForegroundColor Red; Get-Content (Join-Path $RunDir 'last_error.log')
    } else {
        Write-Host "[OK] No errors. Check your inbox." -ForegroundColor Green
    }
    Write-Host "`nInstalled. Tasks: '$TaskSuccess' and '$TaskFailed'." -ForegroundColor Green
}

# ------------------------------------------------------------------
#  UNINSTALL
# ------------------------------------------------------------------
function Do-Uninstall {
    foreach ($n in @($TaskSuccess, $TaskFailed)) {
        if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $n -Confirm:$false
            Write-Host "Removed task: $n" -ForegroundColor Green
        }
    }
    Write-Host "Note: logon-failure auditing was left enabled; folder $InstallDir left in place." -ForegroundColor Yellow
    Write-Host "To remove fully: Remove-Item '$InstallDir' -Recurse -Force" -ForegroundColor DarkGray
}

# ------------------------------------------------------------------
#  ENTRY POINT
# ------------------------------------------------------------------
if     ($Install)   { Do-Install }
elseif ($Uninstall) { Do-Uninstall }
else                { Send-Alert -Kind $Mode }
