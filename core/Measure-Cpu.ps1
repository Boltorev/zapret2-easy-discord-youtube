<#
  Measure-Cpu.ps1 - замер нагрузки на процессор движком Zapret2 Easy.

  ТРЕБУЕТ ПРАВ АДМИНИСТРАТОРА (winws2.exe имеет манифест requireAdministrator).

  Зачем: убедиться, что фильтры WinDivert отсекают лишнее в ядре и процесс
  не гоняет весь трафик через себя. Замеряется в двух режимах IPSet Filter
  (none / loaded) и в двух сценариях (простой / воспроизведение видео).

  Видео должно играть ВЫ: скрипт не может сгенерировать реальный видеопоток
  с корректным SNI, а синтетика тут бессмысленна.

  Пример:
    powershell -NoProfile -ExecutionPolicy Bypass -File core\Measure-Cpu.ps1 -Seconds 20
#>

[CmdletBinding()]
param(
    [string]$Preset = 'AUTO',
    [int]$Seconds = 20,
    [ValidateSet('none', 'loaded', 'both')][string]$Ipset = 'both',
    [switch]$IdleOnly
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Preset.ps1')

if (-not (Test-EasyAdmin)) {
    Write-EasyLog 'Нет прав администратора — winws2 не запустится.' 'ERR'
    exit 2
}
$missing = @(Test-EasyRuntime)
if ($missing.Count -gt 0) { Write-EasyLog ("Не хватает файлов: " + ($missing -join ', ')) 'ERR'; exit 2 }

$cores = [Environment]::ProcessorCount

function Measure-OneMode {
    param([string]$ModeLabel, [bool]$IpsetOn, [bool]$WithVideo)

    $settings = Get-EasySettings
    $settings['IPSetFilter'] = $IpsetOn
    $p = Read-EasyPreset $Preset $settings

    $dbg = Join-Path (Get-EasyLogDir) ("cpu-" + $ModeLabel.Replace(' ', '_') + ".log")
    if (Test-Path -LiteralPath $dbg) { Remove-Item -LiteralPath $dbg -Force }

    $argList = @("--debug=@$dbg") + $p.Args

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
    try { [void]$proc.Start() }
    catch {
        Write-EasyLog ("Не удалось запустить движок: " + $_.Exception.Message) 'ERR'
        return $null
    }

    Start-Sleep -Milliseconds 2000
    if ($proc.HasExited) {
        Write-EasyLog 'Движок завершился сразу после старта — замер невозможен.' 'ERR'
        return $null
    }

    if ($WithVideo) {
        Write-Host ''
        Write-Host '  Откройте видео на YouTube (или включите Discord-трансляцию) и добейтесь' -ForegroundColor Yellow
        Write-Host '  воспроизведения. Замер начнётся после нажатия Enter.' -ForegroundColor Yellow
        [void](Read-Host '  Готово? Нажмите Enter')
        Start-Sleep -Seconds 2
    }

    $samples = New-Object System.Collections.Generic.List[double]
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prev = $proc.TotalProcessorTime
    while ($sw.Elapsed.TotalSeconds -lt $Seconds -and -not $proc.HasExited) {
        Start-Sleep -Milliseconds 1000
        $cur = $proc.TotalProcessorTime
        $d = ($cur - $prev).TotalSeconds
        $prev = $cur
        $samples.Add($d * 100.0)   # % одной ядра за ~1 с
    }
    [void]$sw.Stop()

    $cpuBeforeKill = $proc.TotalProcessorTime
    try { $proc.Kill() } catch { }
    try { [void]$proc.WaitForExit(5000) } catch { }
    $null = Stop-EasyWinws2

    if ($samples.Count -eq 0) { return $null }

    $sum = 0.0; $max = 0.0
    foreach ($x in $samples) { $sum += $x; if ($x -gt $max) { $max = $x } }
    $avg = $sum / $samples.Count

    return [PSCustomObject]@{
        Mode        = $ModeLabel
        Prosto      = (-not $WithVideo)
        AvgOneCore  = [Math]::Round($avg, 1)
        AvgAllCores = [Math]::Round($avg / $cores, 2)
        PeakCore    = [Math]::Round($max, 1)
        Cores       = $cores
        CpuTotalSec = [Math]::Round($cpuBeforeKill.TotalSeconds, 1)
        Samples     = $samples.Count
    }
}

# --------------------------------------------------------------------- main
Write-EasyBanner 'ЗАМЕР НАГРУЗКИ НА CPU'
Write-EasyLog ("Пресет: $Preset   длительность замера: $Seconds с   логических ядер: $cores") 'INFO'
Write-EasyLog 'Замер идёт по CPU-времени самого процесса winws2.' 'INFO'

$modes = @()
if ($Ipset -eq 'none')   { $modes = @(@{ L = 'ipset=none';  B = $false }) }
if ($Ipset -eq 'loaded') { $modes = @(@{ L = 'ipset=loaded'; B = $true }) }
if ($Ipset -eq 'both')   { $modes = @(@{ L = 'ipset=none'; B = $false }, @{ L = 'ipset=loaded'; B = $true }) }

$results = New-Object System.Collections.Generic.List[object]

foreach ($m in $modes) {
    Write-Host ''
    Write-EasyLog ("--- режим " + $m.L + " : ПРОСТОЙ ---") 'HEAD'
    $r = Measure-OneMode -ModeLabel ($m.L + ' / простой') -IpsetOn $m.B -WithVideo $false
    if ($r) { $results.Add($r); Write-EasyLog (("  среднее: {0}% одного ядра, {1}% всех ядер, пик {2}%" -f $r.AvgOneCore, $r.AvgAllCores, $r.PeakCore)) 'OK' }

    if (-not $IdleOnly) {
        Write-Host ''
        Write-EasyLog ("--- режим " + $m.L + " : ВИДЕО ---") 'HEAD'
        $r2 = Measure-OneMode -ModeLabel ($m.L + ' / видео') -IpsetOn $m.B -WithVideo $true
        if ($r2) { $results.Add($r2); Write-EasyLog (("  среднее: {0}% одного ядра, {1}% всех ядер, пик {2}%" -f $r2.AvgOneCore, $r2.AvgAllCores, $r2.PeakCore)) 'OK' }
    }
}

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor DarkCyan
Write-Host '  РЕЗУЛЬТАТЫ ЗАМЕРА' -ForegroundColor Cyan
Write-Host ('=' * 72) -ForegroundColor DarkCyan
Write-Host ("  {0,-26} {1,10} {2,12} {3,10}" -f 'Режим', '% 1 ядра', '% всех ядер', 'пик %')
Write-Host ('-' * 72) -ForegroundColor DarkGray
foreach ($r in $results) {
    Write-Host ("  {0,-26} {1,10} {2,12} {3,10}" -f $r.Mode, $r.AvgOneCore, $r.AvgAllCores, $r.PeakCore)
}
Write-Host ('-' * 72) -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Как читать:'
Write-Host '   * простой должен быть близок к 0% — иначе фильтры пропускают лишнее;'
Write-Host '   * видео: единицы процентов одного ядра — норма; десятки — фильтры слишком широкие;'
Write-Host '   * режим ipset=loaded заметно тяжелее по памяти, но не по CPU.'
Write-Host ''
Write-EasyLog ("Замер завершён. Результатов: " + $results.Count) 'INFO'
