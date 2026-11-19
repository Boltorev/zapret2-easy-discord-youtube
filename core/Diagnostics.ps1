<#
  Diagnostics.ps1 - диагностика окружения.
  Dot-source после Common.ps1 / Preset.ps1 / Service.ps1.

  Только чтение. Ничего не меняет в системе: настройки, которые могли бы помочь
  (например, TCP timestamps), только показываются с пояснением.
#>

function Write-DiagOk   { param([string]$m) Write-EasyLog $m 'OK' }
function Write-DiagBad  { param([string]$m) Write-EasyLog $m 'ERR' }
function Write-DiagWarn { param([string]$m) Write-EasyLog $m 'WARN' }

<# Ищет процессы по имени и возвращает список путей. #>
function Get-ProcessPathsByName {
    param([string[]]$Names)
    $result = @()
    foreach ($n in $Names) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            $path = ''
            try { $path = $p.Path } catch { }
            $result += [PSCustomObject]@{ Name = $p.ProcessName; Id = $p.Id; Path = $path }
        }
    }
    return ,$result
}

function Invoke-EasyDiagnostics {
    Write-EasyBanner 'ДИАГНОСТИКА'

    # 1. права
    if (Test-EasyAdmin) { Write-DiagOk 'Права администратора: есть' }
    else { Write-DiagBad 'Нет прав администратора. Диагностика неполная, служба не заработает.' }

    # 2. путь
    $root = Get-EasyRoot
    Write-EasyLog ("Папка сборки: " + $root) 'INFO'
    $issues = @(Test-EasyPath)
    if ($issues.Count -eq 0) { Write-DiagOk 'Путь сборки: проблем нет (без кириллицы и пробелов)' }
    else { foreach ($i in $issues) { Write-DiagWarn ("Путь: " + $i) } }

    if ($root -match '(?i)onedrive') {
        Write-DiagWarn 'Папка внутри OneDrive: синхронизация может мешать службе и драйверу.'
    }
    if ($root.TrimEnd('\') -ne (Get-EasyCanonicalRoot)) {
        Write-DiagWarn ("Сборка не в каноническом пути " + (Get-EasyCanonicalRoot) + ". Служба привязана к текущему пути.")
    }

    # 3. файлы движка
    $missing = @(Test-EasyRuntime)
    if ($missing.Count -eq 0) { Write-DiagOk 'Файлы движка на месте' }
    else { Write-DiagBad ("Не хватает файлов: " + ($missing -join ', ')) }

    # 4. служба и драйвер
    Write-EasyLog ("Служба: " + (Get-EasyServiceStateText)) 'INFO'
    $bp = Get-EasyServiceBinaryPath
    if ($bp) {
        if ($bp -like ('*' + (Get-Winws2Path) + '*')) { Write-DiagOk 'binPath службы указывает на текущую папку' }
        else { Write-DiagBad 'binPath службы указывает на ДРУГУЮ папку. Папку переносили? Переустановите службу.' }
    }

    $drv = Invoke-ScExe 'query WinDivert'
    if ($drv.Code -eq 0) { Write-DiagOk 'Драйвер WinDivert зарегистрирован' }
    else { Write-DiagWarn 'Драйвер WinDivert не зарегистрирован (появится при первом запуске движка)' }

    # 5. Base Filtering Engine
    $bfe = Invoke-ScExe 'query BFE'
    if ($bfe.Out -match 'RUNNING') { Write-DiagOk 'Base Filtering Engine работает' }
    else { Write-DiagBad 'Base Filtering Engine не запущен — без него WinDivert не работает' }

    # 6. системный прокси
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $pe = $null; $ps = $null
    try {
        $pe = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).ProxyEnable
        $ps = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).ProxyServer
    } catch { }
    if ($null -ne $pe -and $pe -ne 0) {
        Write-DiagWarn ("Включён системный прокси: " + $ps + ". Если он не нужен — отключите, он мешает обходу.")
    } else {
        Write-DiagOk 'Системный прокси выключен'
    }

    # 7. TCP timestamps (для фулинга ts)
    try {
        $ts = (& netsh.exe interface tcp show global 2>&1) -join ' '
        if ($ts -match '(?i)timestamps.*enabled' -and $ts -notmatch '(?i)timestamps.*disabled') {
            Write-DiagOk 'TCP timestamps включены'
        } else {
            Write-DiagWarn 'TCP timestamps выключены. Фулинг по timestamp (tcp_ts) может не работать.'
            Write-DiagWarn 'Включить вручную: netsh interface tcp set global timestamps=enabled'
        }
    } catch {
        Write-DiagWarn 'Не удалось проверить TCP timestamps'
    }

    # 8. конфликтующее ПО
    $known = @(
        @{ Proc = 'AdguardSvc'; Text = 'AdGuard — конфликтует с Discord через WinDivert' },
        @{ Proc = 'goodbyedpi'; Text = 'GoodbyeDPI — второй перехватчик того же трафика' },
        @{ Proc = 'winws';      Text = 'другая сборка zapret (winws) — конфликт драйвера' }
    )
    $conflicts = 0
    foreach ($kitem in $known) {
        $found = @(Get-ProcessPathsByName -Names @($kitem.Proc))
        if ($found.Count -gt 0) {
            $conflicts++
            Write-DiagBad ($kitem.Text + " (процесс: " + $kitem.Proc + ")")
        }
    }

    # чужие winws2
    $foreign = @()
    $ourBin = Join-Path (Get-EasyRoot) 'bin'
    foreach ($p in @(Get-Process -Name 'winws2' -ErrorAction SilentlyContinue)) {
        $path = ''
        try { $path = $p.Path } catch { }
        if ($path -and -not $path.StartsWith($ourBin, [StringComparison]::OrdinalIgnoreCase)) {
            $foreign += $p
        }
    }
    if ($foreign.Count -gt 0) {
        $conflicts++
        Write-DiagBad ("Найден ЧУЖОЙ winws2 (" + $foreign.Count + " шт.) — второй перехватчик. Остановите его.")
    }

    # службы-конкуренты
    foreach ($svcName in @('zapret', 'WinDivert')) {
        $r = Invoke-ScExe ('query ' + $svcName)
        if ($svcName -eq 'zapret' -and $r.Code -eq 0) {
            $conflicts++
            Write-DiagBad 'Установлена служба "zapret" от другой сборки — два перехватчика одновременно не работают.'
        }
    }

    foreach ($svcPattern in @('Killer', 'SmartByte', 'TracSrvWrapper', 'EPWD')) {
        $all = (& sc.exe query type= service state= all 2>&1) -join ' '
        if ($all -match [regex]::Escape($svcPattern)) {
            $conflicts++
            Write-DiagWarn ("Найдена служба $svcPattern — известны конфликты с перехватом трафика.")
        }
    }

    if ($conflicts -eq 0) { Write-DiagOk 'Конфликтующего ПО не найдено' }

    # 9. наши процессы и осиротевшие
    $svcState = Get-EasyServiceState
    $ours     = @(Get-EasyWinws2Process)
    $orphans  = @(Find-EasyOrphanWinws2)

    if ($orphans.Count -gt 0) {
        Write-DiagBad ("Осиротевшие winws2: " + $orphans.Count + " (" + (($orphans | ForEach-Object { "#$($_.Id)" }) -join ', ') + ")")
        Write-DiagBad 'Служба не в состоянии Running, но процесс жив — остаток от удаления или падения.'
        if ($svcState -eq 'NotInstalled') {
            Write-DiagWarn 'Драйвер WinDivert при этом может быть уже снят: процесс мёртв, интернет не затронут.'
        }
        $ans = Read-Host '  Завершить осиротевшие процессы сейчас? (y/n)'
        if ($ans -match '^(y|Y|д|Д)') {
            [void](Remove-EasyOrphanWinws2)
        } else {
            Write-EasyLog 'Оставлены. Убрать можно здесь же при следующем запуске диагностики.' 'WARN'
        }
    } elseif ($svcState -eq 'Running' -and $ours.Count -gt 0) {
        Write-DiagOk ("Наш winws2 работает под службой: PID " + (($ours | ForEach-Object { $_.Id }) -join ', '))
    } elseif ($svcState -eq 'Running' -and $ours.Count -eq 0) {
        Write-DiagBad 'Служба RUNNING, но процесса winws2 нет — служба не выполняет работу.'
    } else {
        Write-DiagOk 'Наш winws2 не запущен, служба не установлена — состояние согласовано'
    }

    # 10. последние ошибки в логах
    $logDir = Get-EasyLogDir
    $errs = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $logDir -Filter '*.log' -File -ErrorAction SilentlyContinue)) {
        $tail = Get-Content -LiteralPath $f.FullName -Tail 200 -ErrorAction SilentlyContinue
        foreach ($line in @($tail)) {
            if ($line -match 'LUA ERROR:|LUA PANIC:|PANIC:|desync ERROR|load failed|this is fatal') {
                $errs += ("[" + $f.Name + "] " + $line.Trim())
            }
        }
    }
    if ($errs.Count -eq 0) { Write-DiagOk 'В логах ошибок движка не найдено' }
    else {
        Write-DiagBad ("В логах найдено ошибок: " + $errs.Count + " (последние 5):")
        foreach ($e in @($errs | Select-Object -Last 5)) { Write-EasyLog ("  " + $e) 'ERR' }
    }

    Write-Host ''
    Write-EasyLog 'Диагностика завершена.' 'INFO'
    Write-EasyLog ('Полный лог: ' + (Join-Path (Get-EasyLogDir) 'zapret-easy.log')) 'INFO'
}
