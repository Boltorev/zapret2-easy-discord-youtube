<#
  test-runner.ps1 - прогон проверок всех пресетов.

  ТРЕБУЕТ ПРАВ АДМИНИСТРАТОРА (манифест winws2.exe: requireAdministrator).

  Свойства:
    * идемпотентен - ничего не устанавливает и не меняет настройки, только читает и тестирует
      (единственное исключение - явный ключ -AddDefenderExclusion)
    * гасит ТОЛЬКО свои процессы winws2 (запущенные из нашей папки bin)
    * логи с таймстампами в logs\, сводка в конце
    * crash-safe: исключение внутри обработки одного пресета помечается ERROR и не обрывает прогон
    * различает "пресет сломан" и "нечем проверить" (нет подходящего трафика)

  Классификация результата Full-прогона:
    OK          - инстансы пресета реально отработали
    NO_TRAFFIC  - подходящего трафика не было (ни одно соединение с покрытым доменом
                  не установилось), проверить пресет этим прогоном НЕВОЗМОЖНО
    FAIL        - движок сообщил ошибку, упал на старте, ИЛИ соединение с покрытым
                  доменом установилось, но ни один инстанс не сработал (это уже поломка)

  Коды возврата: 0 - нет FAIL (NO_TRAFFIC не является провалом), 1 - есть FAIL, 2 - нет прав/файлов.
#>

[CmdletBinding()]
param(
    [ValidateSet('DryRun', 'Full')][string]$Mode = 'DryRun',
    [string[]]$Presets = @(),
    [int]$RunSeconds = 10,
    [string[]]$TargetDomains = @(),
    [switch]$IncludeIpset,
    [switch]$IncludeGameFilter,
    [switch]$AddDefenderExclusion
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Preset.ps1')

$stamp  = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
$runLog = Join-Path (Get-EasyLogDir) "test-runner-$stamp.log"

$script:ErrorMarkers = @(
    'LUA ERROR:', 'LUA PANIC:', 'PANIC:', 'LUA INIT ERROR', 'desync ERROR',
    'ERROR in finalizer', 'VM handler failed', 'load failed', 'this is fatal'
)
$script:InstanceNames = @('fake', 'multisplit', 'multidisorder', 'fakedsplit', 'hostfakesplit', 'syndata')

$script:LaunchFailureCodes = @(
    -1073741502,  # 0xC0000142 STATUS_DLL_INIT_FAILED
    -1073741515,  # 0xC0000135 STATUS_DLL_NOT_FOUND
    -1073741701   # 0xC000007B STATUS_INVALID_IMAGE_FORMAT
)

# домены, которые пробуем в первую очередь, если пресет их покрывает
$script:PreferredDomains = @(
    'www.youtube.com', 'youtube.com', 'youtu.be', 'ytimg.com',
    'discord.com', 'cdn.discordapp.com', 'discordapp.com',
    'www.google.com', 'google.com', 'www.gstatic.com',
    'googlevideo.com', 'rutracker.org', 'example.com'
)
$script:DefaultDomains = @('www.youtube.com', 'discord.com', 'www.google.com')

function Format-ExitCode {
    param([int]$Code)
    if ($Code -eq -1) { return 'n/a' }
    $u = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$Code), 0)
    return ("0x{0:X8} ({1})" -f $u, $Code)
}

function Test-LaunchFailure {
    param($Result)
    if ($null -eq $Result) { return $true }
    if ($Result.PSObject.Properties['StartError'] -and $Result.StartError) { return $true }
    if ($Result.PSObject.Properties['TimedOut'] -and $Result.TimedOut) { return $true }
    if ($Result.PSObject.Properties['LaunchFail'] -and $Result.LaunchFail) { return $true }
    if ($Result.PSObject.Properties['ExitCode'] -and ($script:LaunchFailureCodes -contains $Result.ExitCode)) { return $true }
    return $false
}

function Say {
    param([string]$msg, [string]$level = 'INFO')
    $line = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')) [$level] $msg"
    Add-Content -LiteralPath $runLog -Value $line -Encoding UTF8
    $color = 'Gray'
    if ($level -eq 'OK')    { $color = 'Green' }
    if ($level -eq 'WARN')  { $color = 'Yellow' }
    if ($level -eq 'FAIL')  { $color = 'Red' }
    if ($level -eq 'SKIP')  { $color = 'DarkYellow' }
    if ($level -eq 'HEAD')  { $color = 'Cyan' }
    Write-Host $line -ForegroundColor $color
}

function New-Results { return New-Object System.Collections.Generic.List[object] }

function Add-Result($list, $preset, $mode, $profiles, $status, $detail) {
    $list.Add([PSCustomObject]@{
        Preset = $preset; Mode = $mode; Profiles = $profiles; Status = $status; Detail = $detail
    })
}

# --------------------------------------------------------------- environment
function Test-Environment {
    Say '' 'HEAD'
    Say '--- 0. Проверка окружения ---' 'HEAD'

    $where = @()
    try { $where = @(& where.exe cygwin1.dll 2>$null) } catch { }
    if ($where.Count -gt 0) {
        Say ("В PATH найдена чужая cygwin1.dll: " + ($where -join '; ')) 'WARN'
    } else {
        Say 'where.exe cygwin1.dll: в PATH копий нет' 'OK'
    }

    $zombies = @(Get-Process -Name 'winws2', 'winws' -ErrorAction SilentlyContinue)
    if ($zombies.Count -gt 0) {
        Say ("Найдены процессы: " + (($zombies | ForEach-Object { "$($_.ProcessName)#$($_.Id)" }) -join ', ')) 'WARN'
        $null = Stop-EasyWinws2
        Start-Sleep -Milliseconds 700
    } else {
        Say 'зомби-процессов winws2/winws нет' 'OK'
    }

    $wd = (& sc.exe query WinDivert 2>&1) -join ' '
    if ($wd -match 'RUNNING') { Say 'драйвер WinDivert: RUNNING' 'INFO' }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) { Say ("curl.exe: " + $curl.Source) 'OK' }
    else { Say 'curl.exe не найден - генерация тестового трафика будет ограничена' 'WARN' }

    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $pe = $null
    try { $pe = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).ProxyEnable } catch { }
    if ($null -ne $pe -and $pe -ne 0) { Say 'ВНИМАНИЕ: включён системный прокси. Тестовый трафик идёт мимо него (curl --noproxy), поэтому ожидаемо не совпадёт с трафиком приложений.' 'WARN' }
}

# -------------------------------------------------- домены, которые покрывает пресет
function Get-PresetTargetDomains {
    param([string[]]$Arguments)

    $domains = New-Object System.Collections.Generic.List[string]
    $hasHostFilter = $false

    foreach ($a in $Arguments) {
        if ($a -match '^--hostlist-exclude') { continue }

        if ($a -match '^--hostlist-domains=(.+)$') {
            $hasHostFilter = $true
            foreach ($d in ($Matches[1] -split ',')) {
                $d = $d.Trim().TrimStart('!', '^').Trim()
                if ($d -ne '' -and -not $domains.Contains($d)) { $domains.Add($d) }
            }
            continue
        }
        if ($a -match '^--hostlist=(.+)$') {
            $hasHostFilter = $true
            $file = $Matches[1]
            if (Test-Path -LiteralPath $file) {
                foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
                    $d = $line.Trim()
                    if ($d -eq '' -or $d.StartsWith('#')) { continue }
                    $d = $d.TrimStart('!', '^').Trim()
                    $d = ($d -split '\s+')[0]
                    if ($d -ne '' -and -not $domains.Contains($d)) { $domains.Add($d) }
                }
            }
        }
    }

    if (-not $hasHostFilter) { return @() }   # профиль без хостлиста - подходит любой домен

    # приоритет: сначала те, что пресет покрывает И которые реально открываются браузером
    $picked = New-Object System.Collections.Generic.List[string]
    foreach ($p in $script:PreferredDomains) {
        if ($picked.Count -ge 3) { break }
        foreach ($d in $domains) {
            if ($d -eq $p -and -not $picked.Contains($d)) { $picked.Add($d) }
        }
    }
    foreach ($d in $domains) {
        if ($picked.Count -ge 3) { break }
        if (-not $picked.Contains($d)) { $picked.Add($d) }
    }
    return @($picked.ToArray())
}

# ------------------------------------------------------------------ traffic
function Invoke-CurlProbe {
    param([string]$Domain, [int]$TimeoutSec = 6)

    $url = "https://$Domain/"
    $out = @()
    try {
        $out = @(& curl.exe --noproxy '*' -sS -o NUL `
                    -w '%{http_code}|%{time_total}|%{remote_ip}' `
                    --max-time $TimeoutSec --connect-timeout 4 `
                    --retry 1 --retry-delay 1 $url 2>&1)
    } catch { $out = @("000|0|") }

    $probe = ($out -join ' ').Trim()
    $code = '000'; $t = '0'; $ip = ''
    if ($probe -match '^(\d{3})\|([\d\.]+)\|(\S*)') {
        $code = $Matches[1]; $t = $Matches[2]; $ip = $Matches[3]
    }
    return [PSCustomObject]@{
        Domain = $Domain
        Url    = $url
        Code   = $code
        Time   = $t
        Ip     = $ip
        Ok     = ($code -ne '000')
        Raw    = $probe
    }
}

function Send-TrafficRound {
    param([string[]]$Domains, [int]$TimeoutSec = 6)

    $probes = New-Object System.Collections.Generic.List[object]
    foreach ($d in $Domains) {
        $probes.Add((Invoke-CurlProbe -Domain $d -TimeoutSec $TimeoutSec))
    }

    # UDP: без реальных клиентов Discord сигнатурные фильтры могут не совпасть,
    # поэтому UDP-инстансы могут остаться неупражнёнными - это видно в отчёте.
    foreach ($t in @(@{ ip = '1.1.1.1'; port = 443 },
                     @{ ip = '1.1.1.1'; port = 50000 },
                     @{ ip = '1.1.1.1'; port = 19294 })) {
        try {
            $u = New-Object System.Net.Sockets.UdpClient
            $payload = New-Object byte[] 74
            (New-Object System.Random).NextBytes($payload)
            $payload[0] = 0xC0
            $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($t.ip)), $t.port
            [void]$u.Send($payload, $payload.Length, $ep)
            $u.Close()
        } catch { }
    }
    return @($probes.ToArray())
}

function Get-ExpectedInstances {
    param([string[]]$Arguments)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Arguments) {
        if ($a -match '^--lua-desync=([a-z0-9_]+)') {
            $n = $Matches[1]
            if ($script:InstanceNames -contains $n -and -not $names.Contains($n)) { $names.Add($n) }
        }
    }
    return @($names.ToArray())
}

function Find-EngineErrors {
    param([string]$Text)
    $found = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -eq '') { continue }
        foreach ($m in $script:ErrorMarkers) {
            if ($line.Contains($m)) { $found.Add($line.Trim()); break }
        }
    }
    return @($found.ToArray())
}

function Test-InstanceActivity {
    param([string]$Text, [string[]]$Expected)
    $active = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    foreach ($n in $Expected) {
        if ($Text -match ('(?m)^.*\b' + [regex]::Escape($n) + ': ')) { $active.Add($n) }
    }
    return @($active.ToArray())
}

# ------------------------------------------------------------------- runner
function Invoke-Winws2WithRetry {
    param([string[]]$Arguments, [int]$Attempts = 2, [int]$PauseMs = 1000, [int]$TimeoutSec = 25)

    $last = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        $r = Invoke-Winws2 -Arguments $Arguments -DryRun -TimeoutSec $TimeoutSec
        $last = $r
        if ($r.ExitCode -eq 0 -and -not $r.TimedOut) { return $r }
        if (-not (Test-LaunchFailure $r)) { return $r }
        if ($i -lt $Attempts) {
            Say ("      попытка $i/${Attempts}: сбой запуска exit=$(Format-ExitCode $r.ExitCode), повтор через ${PauseMs} мс") 'WARN'
            $null = Stop-EasyWinws2
            Start-Sleep -Milliseconds $PauseMs
        }
    }
    return $last
}

function Invoke-DebugRun {
    param([string]$Name, [string[]]$Arguments, [int]$Seconds, [string[]]$Domains)

    $dbgFile = Join-Path (Get-EasyLogDir) "winws2-$Name.log"
    if (Test-Path -LiteralPath $dbgFile) { Remove-Item -LiteralPath $dbgFile -Force }

    $argList = @("--debug=@$dbgFile") + $Arguments

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = (Get-Winws2Path)
    $psi.Arguments              = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.WorkingDirectory       = (Join-Path (Get-EasyRoot) 'bin')
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
    } catch {
        return [PSCustomObject]@{
            ExitedEarly = $true; EarlyCode = -1; StdOut = ''; StdErr = $_.Exception.Message
            LogText = ''; LaunchFail = $true; StartError = $true; Probes = @()
        }
    }

    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    Start-Sleep -Milliseconds 1500
    $exitedEarly = $proc.HasExited
    $earlyCode = -1
    if ($exitedEarly) { try { $earlyCode = $proc.ExitCode } catch { } }

    $probes = New-Object System.Collections.Generic.List[object]
    if (-not $exitedEarly) {
        # гарантированный трафик на протяжении всего окна наблюдения
        $deadline = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
            foreach ($pr in (Send-TrafficRound -Domains $Domains -TimeoutSec 4 -Deadline $deadline)) { $probes.Add($pr) }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Milliseconds 300
        }
    }

    if (-not $proc.HasExited) {
        try { $proc.Kill() } catch { }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    }

    $stdout = ''; $stderr = ''
    try { $tmp = $outTask.GetAwaiter().GetResult(); if ($null -ne $tmp) { $stdout = $tmp } } catch { }
    try { $tmp = $errTask.GetAwaiter().GetResult(); if ($null -ne $tmp) { $stderr = $tmp } } catch { }

    Start-Sleep -Milliseconds 800
    $null = Stop-EasyWinws2

    $logText = ''
    if (Test-Path -LiteralPath $dbgFile) {
        $tmp = Get-Content -LiteralPath $dbgFile -Raw -Encoding UTF8
        if ($null -ne $tmp) { $logText = [string]$tmp }
    }

    return [PSCustomObject]@{
        ExitedEarly = $exitedEarly
        EarlyCode   = $earlyCode
        StdOut      = $stdout
        StdErr      = $stderr
        LogText     = $logText
        LaunchFail  = ($exitedEarly -and ($script:LaunchFailureCodes -contains $earlyCode))
        StartError  = $false
        Probes      = @($probes.ToArray())
    }
}

# --------------------------------------------------------------------- start
Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host '  Zapret2 Easy - test runner' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan
Say "mode=$Mode  runSeconds=$RunSeconds  log=$runLog" 'HEAD'

if (-not (Test-EasyAdmin)) {
    Say 'НЕТ ПРАВ АДМИНИСТРАТОРА. winws2.exe не запустится (манифест requireAdministrator).' 'FAIL'
    Say 'Запустите из консоли, открытой от имени администратора.' 'FAIL'
    exit 2
}
$missing = @(Test-EasyRuntime)
if ($missing.Count -gt 0) { Say ("Отсутствуют файлы: " + ($missing -join ', ')) 'FAIL'; exit 2 }
foreach ($issue in @(Test-EasyPath)) { Say "ВНИМАНИЕ по пути: $issue" 'WARN' }

if ($AddDefenderExclusion) {
    try {
        Add-MpPreference -ExclusionPath (Get-EasyRoot) -ErrorAction Stop
        Say ("Добавлено исключение Defender для " + (Get-EasyRoot)) 'WARN'
        Say 'Убрать: Remove-MpPreference -ExclusionPath "<путь>"' 'WARN'
    } catch {
        Say ("Не удалось добавить исключение Defender: " + $_.Exception.Message) 'WARN'
    }
}

Test-Environment

$presetFilter = @($Presets | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$allPresets = @(Get-EasyPresetNames)
if ($presetFilter.Count -gt 0) { $allPresets = @($allPresets | Where-Object { $presetFilter -contains $_ }) }
if ($allPresets.Count -eq 0) { Say 'Не найдено ни одного пресета' 'FAIL'; exit 2 }
Say ("Пресетов к проверке: " + $allPresets.Count)

$manualDomains = @($TargetDomains | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
if ($manualDomains.Count -gt 0) { Say ("Домены для тестового трафика заданы вручную: " + ($manualDomains -join ', ')) 'INFO' }

$results = New-Results

# ============================== 1. DRY-RUN, матрица ipset x gamefilter
Say '' 'HEAD'; Say '--- 1. Матрица --dry-run  (ipset x gamefilter) ---' 'HEAD'
$combos = @(
    @{ ipset = $false; game = $false; label = 'ipset=none  game=off' },
    @{ ipset = $true;  game = $false; label = 'ipset=loaded game=off' },
    @{ ipset = $false; game = $true;  label = 'ipset=none  game=on'  },
    @{ ipset = $true;  game = $true;  label = 'ipset=loaded game=on'  }
)
foreach ($combo in $combos) {
    $settings = Get-EasyDefaultSettings
    $settings['IPSetFilter']   = $combo.ipset
    $settings['GameFilter']    = $combo.game
    $settings['GameFilterTCP'] = '50000-50100'
    $settings['GameFilterUDP'] = '50000-50100'
    Say ("  [комбинация] " + $combo.label) 'INFO'

    foreach ($name in $allPresets) {
        try {
            $p = Read-EasyPreset $name $settings

            $leak = @($p.Args | Where-Object { $_ -like '--easy-*' })
            if ($leak.Count -gt 0) {
                Say ("    {0,-20} FAIL утечка build-директив: {1}" -f $name, ($leak -join ' ')) 'FAIL'
                Add-Result $results $name $combo.label $p.Profiles 'FAIL' ("утечка: " + ($leak -join ' '))
                continue
            }
            $ph = @($p.Args | Where-Object { $_ -match '\{[A-Z_]+\}' })
            if ($ph.Count -gt 0) {
                Say ("    {0,-20} FAIL незаполненный плейсхолдер: {1}" -f $name, ($ph -join ' ')) 'FAIL'
                Add-Result $results $name $combo.label $p.Profiles 'FAIL' ("плейсхолдер: " + ($ph -join ' '))
                continue
            }
            $fileErr = @(Test-EasyPresetFiles $p)
            if ($fileErr.Count -gt 0) {
                Say ("    {0,-20} FAIL файлы: {1}" -f $name, ($fileErr[0])) 'FAIL'
                Add-Result $results $name $combo.label $p.Profiles 'FAIL' ("файлы: " + ($fileErr -join '; '))
                continue
            }
            $dupErr = @(Test-EasyPresetDuplicateLists $p)
            if ($dupErr.Count -gt 0) {
                Say ("    {0,-20} FAIL дубль листа: {1}" -f $name, ($dupErr[0])) 'FAIL'
                Add-Result $results $name $combo.label $p.Profiles 'FAIL' ("дубль: " + ($dupErr -join '; '))
                continue
            }

            $r = Invoke-Winws2WithRetry -Arguments $p.Args -Attempts 2 -PauseMs 1000
            if ($r.TimedOut) {
                Say ("    {0,-20} FAIL --dry-run завис" -f $name) 'FAIL'
                Add-Result $results $name $combo.label $p.Profiles 'FAIL' 'dry-run timeout'
                continue
            }
            if ($r.ExitCode -ne 0) {
                $msg = (($r.StdErr + ' ' + $r.StdOut).Trim())
                if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
                $kind = 'ошибка аргументов'
                if (Test-LaunchFailure $r) { $kind = 'СБОЙ ЗАПУСКА (не ошибка пресета)' }
                Say ("    {0,-20} FAIL --dry-run exit={1} [{2}] {3}" -f $name, (Format-ExitCode $r.ExitCode), $kind, $msg) 'FAIL'
                Add-Result $results $name $combo.label $p.Profiles 'FAIL' ("dry-run exit=" + (Format-ExitCode $r.ExitCode) + " [$kind] " + $msg)
                continue
            }
            Say ("    {0,-20} OK  профилей={1}" -f $name, $p.Profiles) 'OK'
            Add-Result $results $name $combo.label $p.Profiles 'OK' ''
        }
        catch {
            Say ("    {0,-20} ERROR {1}" -f $name, $_.Exception.Message) 'FAIL'
            Add-Result $results $name $combo.label 0 'FAIL' ("ERROR: " + $_.Exception.Message)
        }
    }
}

# ============================== 2. РЕАЛЬНЫЙ ЗАПУСК с --debug
if ($Mode -eq 'Full') {
    Say '' 'HEAD'; Say '--- 2. Реальный запуск с --debug ---' 'HEAD'
    $settings = Get-EasyDefaultSettings
    if ($IncludeIpset)      { $settings['IPSetFilter'] = $true }
    if ($IncludeGameFilter) {
        $settings['GameFilter']    = $true
        $settings['GameFilterTCP'] = '50000-50100'
        $settings['GameFilterUDP'] = '50000-50100'
    }
    $null = Stop-EasyWinws2
    Start-Sleep -Milliseconds 500

    foreach ($name in $allPresets) {
        try {
            $p = Read-EasyPreset $name $settings

            # какие домены этот пресет вообще может поймать
            if ($manualDomains.Count -gt 0) { $domains = $manualDomains }
            else {
                $domains = @(Get-PresetTargetDomains -Arguments $p.Args)
                if ($domains.Count -eq 0) { $domains = $script:DefaultDomains }
            }

            $run = $null
            $attempt = 0
            while ($attempt -lt 2) {
                $attempt++
                $run = Invoke-DebugRun -Name $name -Arguments $p.Args -Seconds $RunSeconds -Domains $domains
                if (-not $run.LaunchFail) { break }
                if ($attempt -lt 2) {
                    Say ("  {0,-20} сбой запуска exit={1}, повтор" -f $name, (Format-ExitCode $run.EarlyCode)) 'WARN'
                    Start-Sleep -Milliseconds 1000
                }
            }

            $detail = @()
            $status = 'OK'

            if ($run.LaunchFail) {
                $status = 'FAIL'
                $detail += "СБОЙ ЗАПУСКА движка exit=$(Format-ExitCode $run.EarlyCode) - не ошибка пресета"
                if ($run.StdErr.Trim().Length -gt 0) { $detail += ("stderr: " + $run.StdErr.Trim()) }
            } else {
                if ($run.ExitedEarly) {
                    $status = 'FAIL'
                    $detail += "процесс завершился сразу после старта exit=$(Format-ExitCode $run.EarlyCode)"
                }
                if ($run.StdErr.Trim().Length -gt 0) {
                    $status = 'FAIL'
                    $s = $run.StdErr.Trim(); if ($s.Length -gt 300) { $s = $s.Substring(0, 300) }
                    $detail += "stderr: $s"
                }

                $logText = [string]$run.LogText
                if ($logText.Length -lt 20) {
                    if ($status -eq 'OK') { $status = 'FAIL' }
                    $detail += 'debug-лог пуст или не создан'
                } else {
                    $errs = @(Find-EngineErrors $logText)
                    if ($errs.Count -gt 0) {
                        $status = 'FAIL'
                        $sample = ($errs | Select-Object -First 3) -join ' | '
                        if ($sample.Length -gt 400) { $sample = $sample.Substring(0, 400) }
                        $detail += "маркеры ошибок ($($errs.Count)): $sample"
                    }
                }

                $probes = @($run.Probes)
                $responded = @($probes | Where-Object { $_.Ok } | ForEach-Object { $_.Domain } | Sort-Object -Unique)
                $attempted = @($probes | ForEach-Object { $_.Domain } | Sort-Object -Unique)

                $expected = @(Get-ExpectedInstances -Arguments $p.Args)
                $active = @(Test-InstanceActivity -Text $logText -Expected $expected)
                $activityStr = "$($active.Count)/$($expected.Count)"

                if ($active.Count -gt 0) {
                    if ($active.Count -lt $expected.Count) {
                        $missingI = @($expected | Where-Object { $active -notcontains $_ })
                        $detail += "не упражнялись: $($missingI -join ',')"
                    }
                } else {
                    if ($status -eq 'OK') {
                        if ($responded.Count -gt 0) {
                            # соединение с покрытым доменом установилось, а инстансы молчат -> это поломка
                            $status = 'FAIL'
                            $detail += ("соединение установлено ($($responded -join ',')), но ни один инстанс не сработал")
                        } else {
                            $status = 'NO_TRAFFIC'
                            $detail += ("нет подходящего трафика: пробовали $($attempted -join ',') - ни одно соединение не установилось")
                        }
                    }
                }

                if ($status -eq 'OK' -or $status -eq 'NO_TRAFFIC') {
                    $detail += ("трафик: " + $(if ($responded.Count -gt 0) { "отвечали " + ($responded -join ',') } else { "не отвечал никто из " + ($attempted -join ',') }))
                }
            }

            switch ($status) {
                'OK'         { Say ("  {0,-20} OK          профилей={1} инстансы={2} {3}" -f $name, $p.Profiles, $activityStr, ($detail -join '; ')) 'OK' }
                'NO_TRAFFIC' { Say ("  {0,-20} NO_TRAFFIC  профилей={1} {2}" -f $name, $p.Profiles, ($detail -join '; ')) 'SKIP' }
                default      { Say ("  {0,-20} FAIL        {1}" -f $name, ($detail -join '; ')) 'FAIL' }
            }
            Add-Result $results $name 'debug-run' $p.Profiles $status ($detail -join '; ')
        }
        catch {
            Say ("  {0,-20} ERROR {1}" -f $name, $_.Exception.Message) 'FAIL'
            Add-Result $results $name 'debug-run' 0 'FAIL' ("ERROR: " + $_.Exception.Message)
            $null = Stop-EasyWinws2
        }
    }
}

# ============================== 3. СВОДКА
Say '' 'HEAD'; Say '--- СВОДКА ---' 'HEAD'
$allRes    = $results
$okRes     = @($results | Where-Object { $_.Status -eq 'OK' })
$failRes   = @($results | Where-Object { $_.Status -eq 'FAIL' })
$noTraffic = @($results | Where-Object { $_.Status -eq 'NO_TRAFFIC' })
$launchRes = @($failRes | Where-Object { $_.Detail -like '*СБОЙ ЗАПУСКА*' })

Say ("Всего проверок          : " + $allRes.Count)
Say ("OK (работает)           : " + $okRes.Count) 'OK'
Say ("FAIL (сломан)           : " + $failRes.Count) $(if ($failRes.Count -gt 0) { 'FAIL' } else { 'INFO' })
Say ("NO_TRAFFIC (не проверить): " + $noTraffic.Count) $(if ($noTraffic.Count -gt 0) { 'WARN' } else { 'INFO' })
Say ("  из FAIL - сбой запуска : " + $launchRes.Count) $(if ($launchRes.Count -gt 0) { 'WARN' } else { 'INFO' })

if ($failRes.Count -gt 0) {
    Say '' 'FAIL'
    Say 'FAIL (сломан):' 'FAIL'
    foreach ($f in $failRes) { Say ("  {0,-20} [{1}] {2}" -f $f.Preset, $f.Mode, $f.Detail) 'FAIL' }
}
if ($noTraffic.Count -gt 0) {
    Say '' 'WARN'
    Say 'NO_TRAFFIC (пресет НЕ проверен - не было подходящего трафика):' 'WARN'
    foreach ($f in $noTraffic) { Say ("  {0,-20} [{1}] {2}" -f $f.Preset, $f.Mode, $f.Detail) 'WARN' }
    Say '' 'WARN'
    Say 'Что делать: включите обход для этих доменов, либо прогоните с -TargetDomains <домены,' 'WARN'
    Say 'которые реально открываются в вашем окружении>. Иначе проверить пресет нечем.' 'WARN'
}

Say ''
Say ("Подробный лог: " + $runLog) 'INFO'
Say ("Логи движка  : " + (Get-EasyLogDir) + '\winws2-*.log') 'INFO'

$null = Stop-EasyWinws2
if ($failRes.Count -gt 0) { exit 1 } else { exit 0 }


