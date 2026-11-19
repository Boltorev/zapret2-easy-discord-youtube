<#
  Menu.ps1 - главное меню Zapret2 Easy.
  Запускается из service.bat. Требует прав администратора.

  Никакого chcp: консоль переводится в UTF-8 средствами .NET (см. Common.ps1).
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Preset.ps1')
. (Join-Path $PSScriptRoot 'Service.ps1')
. (Join-Path $PSScriptRoot 'Diagnostics.ps1')
. (Join-Path $PSScriptRoot 'Lists.ps1')
. (Join-Path $PSScriptRoot 'Update.ps1')

# ---------------------------------------------------------------- elevation
if (-not (Test-EasyAdmin)) {
    Write-Host 'Требуются права администратора. Запрашиваю повышение...' -ForegroundColor Yellow
    try {
        $psi = "`"$PSCommandPath`""
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $psi
        ) | Out-Null
    } catch {
        Write-Host 'Не удалось повысить права. Запустите service.bat от имени администратора.' -ForegroundColor Red
        Read-Host 'Нажмите Enter для выхода'
    }
    exit
}

# ------------------------------------------------------------------ helpers
function Select-EasyPreset {
    param([string]$Current = '')

    # единый список из Preset.ps1, без дублирования логики
    $choices = @(Get-EasyPresetChoices)
    if ($choices.Count -eq 0) {
        Write-EasyLog 'Пресеты не найдены в папке presets\.' 'ERR'
        return $null
    }

    Write-Host ''
    Write-Host '  Доступные пресеты:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $mark = ' '
        if ($choices[$i].Name -eq $Current) { $mark = '*' }
        Write-Host ("  {0}{1,3}. {2,-22} {3}" -f $mark, ($i + 1), $choices[$i].Name, $choices[$i].Title)
    }
    Write-Host ''

    $def = 1
    for ($k = 0; $k -lt $choices.Count; $k++) { if ($choices[$k].Name -eq 'AUTO') { $def = $k + 1 } }
    if ($Current -ne '') {
        for ($k = 0; $k -lt $choices.Count; $k++) { if ($choices[$k].Name -eq $Current) { $def = $k + 1 } }
    }

    $ans = Read-Host ("  Выберите номер (Enter = " + $choices[$def - 1].Name + ")")
    if ($ans -eq '') { return $choices[$def - 1].Name }
    $num = 0
    if (-not [int]::TryParse($ans, [ref]$num)) { Write-EasyLog 'Нужно ввести номер.' 'ERR'; return $null }
    if ($num -lt 1 -or $num -gt $choices.Count) { Write-EasyLog 'Нет такого номера.' 'ERR'; return $null }
    return $choices[$num - 1].Name
}

function Invoke-EasyChildScript {
    param([string]$Script, [string[]]$Arguments = @())

    $path = Join-Path $PSScriptRoot $Script
    if (-not (Test-Path -LiteralPath $path)) { Write-EasyLog "Не найден $path" 'ERR'; return }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path) + $Arguments
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -eq 0) { Write-EasyLog ("$Script завершён успешно.") 'OK' }
    else { Write-EasyLog ("$Script завершён с кодом " + $p.ExitCode) 'WARN' }
}

function Show-EasyHeader {
    Clear-Host
    $v = Get-EasyVersionInfo
    $s = Get-EasySettings
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host ("  ЗАПРЕТ2 EASY  v" + $v['easy'] + "   (движок zapret2 v" + $v['engine'] + ")") -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host ("  Папка   : " + (Get-EasyRoot))
    Write-Host ("  Служба  : " + (Get-EasyServiceStateText)) -ForegroundColor $(
        if ((Get-EasyServiceState) -eq 'Running') { 'Green' } else { 'Yellow' })
    Write-Host ("  Пресет  : " + $s['Preset'])
    $ip = if ($s['IPSetFilter']) { 'включён' } else { 'выключен' }
    $gm = if ($s['GameFilter'])  { 'включён' } else { 'выключен' }
    Write-Host ("  Фильтры : IPSet " + $ip + "   Game " + $gm)
    Write-Host ('-' * 66) -ForegroundColor DarkGray
}

# --------------------------------------------------------------------- menu
$running = $true
while ($running) {

    Show-EasyHeader
    Write-Host '   1. Установить (выбрать пресет, по умолчанию AUTO)'
    Write-Host '   2. Удалить'
    Write-Host '   3. Статус'
    Write-Host '   4. Сменить пресет'
    Write-Host '   5. Тесты пресетов'
    Write-Host '   6. Диагностика'
    Write-Host '   7. Списки и исключения'
    Write-Host '   8. Game Filter'
    Write-Host '   9. IPSet Filter'
    Write-Host '  10. Обновить списки'
    Write-Host '  11. Проверить обновления'
    Write-Host '  12. Выход'
    Write-Host ''

    $choice = Read-Host '  Выберите пункт (1-12)'

    switch ($choice) {

        '1' {
            Write-EasyBanner 'УСТАНОВКА'
            $null = Test-EasyCanonicalPath -OfferMove
            if ((Get-EasyRoot).TrimEnd('\') -ne (Get-EasyCanonicalRoot).TrimEnd('\')) {
                Write-Host ''
                Write-Host '  Установка из текущей папки возможна, но служба привяжется к этому пути.' -ForegroundColor Yellow
                $cont = Read-Host '  Продолжить установку из текущей папки? (y/n)'
                if ($cont -notmatch '^(y|Y|д|Д)') { continue }
            }

            $s = Get-EasySettings
            $preset = Select-EasyPreset -Current $s['Preset']
            if ($null -eq $preset) { continue }

            Write-EasyLog ("Выбран пресет: " + $preset) 'INFO'
            try {
                [void](Install-EasyService -Preset $preset)
            } catch {
                Write-EasyLog ("Установка не удалась: " + $_.Exception.Message) 'ERR'
            }
            Read-Host 'Нажмите Enter'
        }

        '2' {
            Write-EasyBanner 'УДАЛЕНИЕ'
            $ans = Read-Host '  Удалить службу? (y/n)'
            if ($ans -notmatch '^(y|Y|д|Д)') { continue }
            $drv = Read-Host '  Также удалить драйвер WinDivert? Он разделяемый с другими инструментами (y/n)'
            $withDriver = ($drv -match '^(y|Y|д|Д)')
            try {
                [void](Remove-EasyService -WithDriver:$withDriver)
            } catch {
                Write-EasyLog ("Удаление не удалось: " + $_.Exception.Message) 'ERR'
            }
            Read-Host 'Нажмите Enter'
        }

        '3' {
            Show-EasyServiceStatus
            Read-Host 'Нажмите Enter'
        }

        '4' {
            Write-EasyBanner 'СМЕНА ПРЕСЕТА'
            $s = Get-EasySettings
            $preset = Select-EasyPreset -Current $s['Preset']
            if ($null -eq $preset) { continue }

            if ((Get-EasyServiceState) -eq 'NotInstalled') {
                $s['Preset'] = $preset
                Save-EasySettings $s
                Write-EasyLog ("Пресет сохранён: " + $preset + ". Служба не установлена — применится при установке.") 'OK'
            } else {
                try { [void](Install-EasyService -Preset $preset) }
                catch { Write-EasyLog ("Смена пресета не удалась: " + $_.Exception.Message) 'ERR' }
            }
            Read-Host 'Нажмите Enter'
        }

        '5' {
            Write-EasyBanner 'ТЕСТЫ ПРЕСЕТОВ'
            Write-Host '  1. Быстрая проверка аргументов (--dry-run, 2-4 минуты)'
            Write-Host '  2. Полная проверка с реальным запуском (--debug, дольше)'
            Write-Host '  3. Замер нагрузки на CPU (простой и воспроизведение видео)'
            Write-Host '  0. Отмена'
            $m = Read-Host '  Выберите режим'
            if ($m -eq '1') { Invoke-EasyChildScript -Script 'test-runner.ps1' -Arguments @('-Mode', 'DryRun') }
            elseif ($m -eq '2') {
                Write-EasyLog 'Полный тест на время включает перехват — сеть может замедлиться.' 'WARN'
                $ok = Read-Host '  Продолжить? (y/n)'
                if ($ok -match '^(y|Y|д|Д)') { Invoke-EasyChildScript -Script 'test-runner.ps1' -Arguments @('-Mode', 'Full') }
            }
            elseif ($m -eq '3') { Invoke-EasyChildScript -Script 'Measure-Cpu.ps1' -Arguments @('-Seconds', '20') }
            Read-Host 'Нажмите Enter'
        }

        '6' {
            Invoke-EasyDiagnostics
            Read-Host 'Нажмите Enter'
        }

        '7' { Show-EasyLists; }

        '8' {
            Write-EasyBanner 'GAME FILTER'
            $s = Get-EasySettings
            if ($s['GameFilter']) {
                Write-Host '  Сейчас: включён'
                $a = Read-Host '  Выключить? (y/n), Enter = изменить порты'
                if ($a -match '^(y|Y|д|Д)') { Set-EasyGameFilter -Enabled $false; Read-Host 'Enter'; continue }
            } else {
                Write-Host '  Сейчас: выключен'
                $a = Read-Host '  Включить? (y/n)'
                if ($a -notmatch '^(y|Y|д|Д)') { continue }
            }
            $ports = Read-EasyGamePorts
            if ($null -eq $ports) { Read-Host 'Enter'; continue }
            Set-EasyGameFilter -Enabled $true -TcpPorts $ports.Tcp -UdpPorts $ports.Udp
            Write-EasyLog 'Чтобы изменения применились к работающей службе, смените/переустановите пресет.' 'WARN'
            Read-Host 'Нажмите Enter'
        }

        '9' {
            Write-EasyBanner 'IPSET FILTER'
            $s = Get-EasySettings
            if ($s['IPSetFilter']) {
                Write-Host '  Сейчас: включён (33k записей читаются движком)'
                $a = Read-Host '  Выключить? (y/n)'
                if ($a -match '^(y|Y|д|Д)') { Set-EasyIPSetFilter -Enabled $false }
            } else {
                Write-Host '  Сейчас: выключен (список в 33k записей не читается)'
                Write-Host '  Включение добавляет профили по ipset: обход для сайтов вне хостлистов.'
                $a = Read-Host '  Включить? (y/n)'
                if ($a -match '^(y|Y|д|Д)') { Set-EasyIPSetFilter -Enabled $true }
            }
            Write-EasyLog 'Чтобы изменения применились к работающей службе, смените/переустановите пресет.' 'WARN'
            Read-Host 'Нажмите Enter'
        }

        '10' { Invoke-EasyListUpdate; Read-Host 'Нажмите Enter' }

        '11' { Invoke-EasyUpdateCheck; Read-Host 'Нажмите Enter' }

        '12' { $running = $false }

        default {
            Write-Host '  Нет такого пункта.' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 800
        }
    }
}

Write-Host ''
Write-EasyLog 'Выход из меню.' 'INFO'

