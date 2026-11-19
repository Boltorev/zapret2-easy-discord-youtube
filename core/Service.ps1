<#
  Service.ps1 - установка, удаление и статус службы Windows Zapret2 Easy.
  Dot-source:  . "$PSScriptRoot\Common.ps1"; . "$PSScriptRoot\Preset.ps1"; . "$PSScriptRoot\Service.ps1"

  Имя службы: zapret2easy (не конфликтует с zapret/WinDivert от других сборок).
  Канонический путь: C:\zapret2-easy — служба привязывается к пути в binPath.
#>

$script:EasyServiceName        = 'zapret2easy'
$script:EasyServiceDisplayName = 'Zapret2 Easy DPI bypass'
$script:EasyServiceDescription = 'Zapret2 Easy - DPI bypass for Windows. Independent build, not affiliated with bol-van or Flowseal.'
$script:EasyCanonicalRoot      = 'C:\zapret2-easy'

function Get-EasyServiceName { return $script:EasyServiceName }
function Get-EasyCanonicalRoot { return $script:EasyCanonicalRoot }

<# Обёртка над sc.exe с полным контролем строки аргументов. #>
function Invoke-ScExe {
    param([Parameter(Mandatory = $true)][string]$Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = Join-Path $env:SystemRoot 'System32\sc.exe'
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    [void]$proc.WaitForExit(30000)
    $code = -1
    try { $code = $proc.ExitCode } catch { }
    return [PSCustomObject]@{ Code = $code; Out = $out; Err = $err }
}

<# Состояние службы: NotInstalled / Stopped / Running / Unknown #>
function Get-EasyServiceState {
    $r = Invoke-ScExe ("query " + $script:EasyServiceName)
    if ($r.Out -match '1060' -or $r.Err -match '1060') { return 'NotInstalled' }
    if ($r.Code -ne 0) { return 'Unknown' }
    if ($r.Out -match 'RUNNING') { return 'Running' }
    if ($r.Out -match 'STOPPED' -or $r.Out -match 'STOP_PENDING') { return 'Stopped' }
    return 'Unknown'
}

<# Текст состояния для меню. #>
function Get-EasyServiceStateText {
    switch (Get-EasyServiceState) {
        'NotInstalled' { return 'не установлена' }
        'Running'      { return 'установлена, РАБОТАЕТ' }
        'Stopped'      { return 'установлена, ОСТАНОВЛЕНА' }
        default        { return 'состояние неизвестно' }
    }
}

<# Путь из binPath службы — чтобы поймать перенос папки. #>
function Get-EasyServiceBinaryPath {
    $r = Invoke-ScExe ("qc " + $script:EasyServiceName)
    if ($r.Code -ne 0) { return $null }
    $m = [regex]::Match($r.Out, 'BINARY_PATH_NAME\s*:\s*(.+)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

<# Предлагает перенести сборку в канонический путь. Возвращает $true если путь канонический. #>
function Test-EasyCanonicalPath {
    param([switch]$OfferMove)

    $root = Get-EasyRoot
    if ($root.TrimEnd('\') -eq $script:EasyCanonicalRoot.TrimEnd('\')) { return $true }

    Write-EasyLog "Сборка запущена не из канонического пути: $root" 'WARN'
    Write-EasyLog "Канонический путь: $($script:EasyCanonicalRoot)" 'WARN'
    Write-EasyLog 'Служба Windows привязывается к пути в binPath: если папку потом перенести или' 'WARN'
    Write-EasyLog 'переименовать, служба перестанет запускаться.' 'WARN'

    if (-not $OfferMove) { return $false }

    Write-Host ''
    Write-Host ("Перенести сборку в " + $script:EasyCanonicalRoot + " сейчас?") -ForegroundColor Yellow
    Write-Host '  Рекомендуется: путь без кириллицы, пробелов и синхронизации OneDrive.'
    $ans = Read-Host '  Переносить? (y/n)'
    if ($ans -notmatch '^(y|Y|д|Д)') { return $false }

    if (Test-Path -LiteralPath $script:EasyCanonicalRoot) {
        Write-EasyLog ("Папка уже существует: " + $script:EasyCanonicalRoot + " — перенос отменён, чтобы не затереть данные.") 'ERR'
        return $false
    }

    Write-EasyLog ("Копирую сборку в " + $script:EasyCanonicalRoot + " ...") 'INFO'
    $rc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\robocopy.exe') `
        -ArgumentList @("`"$root`"", "`"$($script:EasyCanonicalRoot)`"", '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') `
        -Wait -PassThru -NoNewWindow
    if ($rc.ExitCode -ge 8) {
        Write-EasyLog ("robocopy вернул код " + $rc.ExitCode + " — перенос не удался.") 'ERR'
        return $false
    }

    Write-EasyLog ("Сборка скопирована в " + $script:EasyCanonicalRoot) 'OK'
    Write-EasyLog 'Теперь запустите service.bat ИЗ НОВОЙ ПАПКИ и установите службу оттуда.' 'WARN'
    return $false
}

<# Установка службы с указанным пресетом. #>
function Install-EasyService {
    param([Parameter(Mandatory = $true)][string]$Preset)

    Assert-EasyAdmin

    $issues = @(Test-EasyPath)
    foreach ($i in $issues) { Write-EasyLog "Путь: $i" 'WARN' }

    $missing = @(Test-EasyRuntime)
    if ($missing.Count -gt 0) { throw ("Не хватает файлов движка: " + ($missing -join ', ')) }

    $p = Read-EasyPreset $Preset
    $exe = Get-Winws2Path
    $svc = $script:EasyServiceName
    $q = [char]34

    # binPath: путь к exe в кавычках + аргументы; вся строка тоже в кавычках
    $binPath = $q + $exe + $q + ' ' + ($p.Args -join ' ')
    $state = Get-EasyServiceState
    if ($state -ne 'NotInstalled') {
        Write-EasyLog "Служба $svc уже существует — переустанавливаю." 'WARN'
        [void](Invoke-ScExe ("stop " + $svc))
        Start-Sleep -Milliseconds 1200
        [void](Invoke-ScExe ("delete " + $svc))
        Start-Sleep -Milliseconds 800
    }

    Write-EasyLog ("Устанавливаю службу $svc с пресетом '$Preset'") 'INFO'
    $createArgs = 'create ' + $svc + ' binPath= ' + $q + $binPath + $q +
                  ' DisplayName= ' + $q + $script:EasyServiceDisplayName + $q +
                  ' start= auto'
    $r = Invoke-ScExe $createArgs
    if ($r.Code -ne 0) {
        throw ("sc create не удался (код " + $r.Code + "): " + ($r.Out + ' ' + $r.Err).Trim())
    }
    [void](Invoke-ScExe ('description ' + $svc + ' ' + $q + $script:EasyServiceDescription + $q))

    # запоминаем пресет, чтобы показывать в статусе
    $s = Get-EasySettings
    $s['Preset'] = $Preset
    Save-EasySettings $s

    Write-EasyLog 'Запускаю службу...' 'INFO'
    $st = Invoke-ScExe ("start " + $svc)
    Start-Sleep -Milliseconds 2000

    $state = Get-EasyServiceState
    if ($state -eq 'Running') {
        Write-EasyLog ("Служба установлена и работает. Пресет: $Preset") 'OK'
        return $true
    }

    Write-EasyLog ("Служба создана, но не запустилась (состояние: $state).") 'ERR'
    if ($st.Out -match '1053|1054|1066|1058') {
        Write-EasyLog 'Код 1053/1054/1066 — движок не удержался в службе. Смотрите logs\winws2-*.log' 'ERR'
    }
    Write-EasyLog ('Вывод sc: ' + ($st.Out + ' ' + $st.Err).Trim()) 'ERR'
    return $false
}

<# Удаление службы. Драйвер WinDivert — по флагу (он разделяемый с другими инструментами). #>
function Remove-EasyService {
    param([switch]$WithDriver)

    Assert-EasyAdmin
    $svc = $script:EasyServiceName

    $state = Get-EasyServiceState
    if ($state -eq 'NotInstalled') {
        Write-EasyLog "Служба $svc не установлена." 'INFO'
    } else {
        Write-EasyLog "Останавливаю службу $svc" 'INFO'
        [void](Invoke-ScExe ("stop " + $svc))
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if ((Get-EasyServiceState) -ne 'Running') { break }
        }
        [void](Stop-EasyWinws2)
        Write-EasyLog "Удаляю службу $svc" 'INFO'
        $r = Invoke-ScExe ("delete " + $svc)
        if ($r.Code -ne 0 -and $r.Out -notmatch '1060') {
            Write-EasyLog ("sc delete: " + ($r.Out + ' ' + $r.Err).Trim()) 'WARN'
        }
        Start-Sleep -Milliseconds 800
        if ((Get-EasyServiceState) -eq 'NotInstalled') {
            Write-EasyLog 'Служба удалена.' 'OK'
        } else {
            Write-EasyLog 'Служба всё ещё видна в системе — возможно, требуется перезагрузка.' 'WARN'
        }
    }

    # Служба удалена. Процесс, который она породила, мог пережить удаление —
    # добиваем и ПРОВЕРЯЕМ, иначе удаление не считается завершённым.
    $kill = Stop-EasyWinws2
    if (-not $kill.Gone) {
        Write-EasyLog 'Удаление НЕ завершено: процесс winws2 не завершился.' 'ERR'
        Write-EasyLog 'Завершите его вручную (Диспетчер задач -> winws2) и повторите удаление.' 'ERR'
        return $false
    }
    Write-EasyLog 'Процесс winws2 завершён, проверено.' 'OK'

    if ($WithDriver) {
        $d = Invoke-ScExe 'query WinDivert'
        if ($d.Code -eq 0) {
            Write-EasyLog 'Останавливаю и удаляю драйвер WinDivert (разделяемый с другими инструментами).' 'WARN'
            [void](Invoke-ScExe 'stop WinDivert')
            Start-Sleep -Milliseconds 800
            [void](Invoke-ScExe 'delete WinDivert')
            Write-EasyLog 'Драйвер WinDivert удалён.' 'OK'
        } else {
            Write-EasyLog 'Драйвер WinDivert не зарегистрирован — чистить нечего.' 'INFO'
        }
    } else {
        $d = Invoke-ScExe 'query WinDivert'
        if ($d.Code -eq 0) {
            Write-EasyLog 'Драйвер WinDivert оставлен (он разделяемый). Убрать: пункт удаления с очисткой драйвера.' 'INFO'
        }
    }

    return $true
}

<# Подробный статус для меню. #>
function Show-EasyServiceStatus {
    $svc = $script:EasyServiceName
    Write-EasyLog ("Путь сборки : " + (Get-EasyRoot)) 'INFO'
    Write-EasyLog ("Состояние   : " + (Get-EasyServiceStateText)) 'INFO'

    $bp = Get-EasyServiceBinaryPath
    if ($bp) {
        Write-EasyLog ("binPath     : " + $bp) 'INFO'
        $exe = Get-Winws2Path
        if ($bp -notlike ("*" + $exe + "*")) {
            Write-EasyLog 'ВНИМАНИЕ: путь в службе НЕ совпадает с текущей папкой сборки.' 'ERR'
            Write-EasyLog 'Папку переносили? Переустановите службу (пункт меню «Установить»).' 'ERR'
        }
    }

    $s = Get-EasySettings
    Write-EasyLog ("Пресет      : " + $s['Preset']) 'INFO'
    Write-EasyLog ("IPSet Filter: " + $(if ($s['IPSetFilter']) { 'включён' } else { 'выключен' })) 'INFO'
    Write-EasyLog ("Game Filter : " + $(if ($s['GameFilter']) { 'включён' } else { 'выключен' })) 'INFO'

    $state = Get-EasyServiceState
    $procs = @(Get-EasyWinws2Process)
    if ($state -eq 'Running' -and $procs.Count -gt 0) {
        Write-EasyLog ("Процессы    : " + (($procs | ForEach-Object { "winws2#$($_.Id)" }) -join ', ')) 'OK'
    } elseif ($state -eq 'Running' -and $procs.Count -eq 0) {
        Write-EasyLog 'Процессы    : служба RUNNING, но процесса winws2 НЕТ — служба не работает.' 'ERR'
    } elseif ($procs.Count -gt 0) {
        Write-EasyLog ("Процессы    : ОСИРОТЕВШИЙ winws2 (" + (($procs | ForEach-Object { "#$($_.Id)" }) -join ', ') + "), службы нет.") 'WARN'
        Write-EasyLog '              Процесс не связан со службой. Убрать: Диагностика -> «убить осиротевшие winws2».' 'WARN'
    } else {
        Write-EasyLog 'Процессы    : наших winws2 не запущено (согласовано с состоянием службы)' 'OK'
    }

    $drv = Invoke-ScExe 'query WinDivert'
    if ($drv.Code -eq 0) {
        if ($drv.Out -match 'RUNNING') { Write-EasyLog 'Драйвер     : WinDivert RUNNING' 'INFO' }
        else { Write-EasyLog 'Драйвер     : WinDivert зарегистрирован, не запущен' 'INFO' }
    } else {
        Write-EasyLog 'Драйвер     : WinDivert не зарегистрирован' 'INFO'
    }
}

<#
  Осиротевшие winws2: наш процесс есть, но служба не в состоянии Running.
  Такие процессы не связаны с менеджером служб и должны быть убраны.
#>
function Find-EasyOrphanWinws2 {
    $state = Get-EasyServiceState
    if ($state -eq 'Running') { return @() }
    return @(Get-EasyWinws2Process)
}

<# Убивает осиротевшие процессы. Возвращает объект Stop-EasyWinws2 или $null, если их не было. #>
function Remove-EasyOrphanWinws2 {
    $orphans = @(Find-EasyOrphanWinws2)
    if ($orphans.Count -eq 0) {
        Write-EasyLog 'Осиротевших winws2 не найдено.' 'OK'
        return $null
    }
    Write-EasyLog ("Найдено осиротевших winws2: " + (($orphans | ForEach-Object { "#$($_.Id)" }) -join ', ')) 'WARN'
    $r = Stop-EasyWinws2
    if ($r.Gone) { Write-EasyLog 'Осиротевшие процессы убраны, проверено.' 'OK' }
    else { Write-EasyLog 'Часть процессов не удалось убрать.' 'ERR' }
    return $r
}
