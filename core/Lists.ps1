<#
  Lists.ps1 - работа со списками, IPSet Filter и Game Filter.
  Dot-source после Common.ps1 / Preset.ps1.

  Сетевые обращения: ТОЛЬКО по явному подтверждению пользователя (обновление списков).
  Пользовательские файлы *-user.txt не изменяются никогда.
#>

$script:EasyUpdateSourcesFile = Join-Path (Join-Path (Get-EasyRoot) 'lists') 'update-sources.json'

function Get-EasyListSources {
    if (Test-Path -LiteralPath $script:EasyUpdateSourcesFile) {
        try {
            return Get-Content -LiteralPath $script:EasyUpdateSourcesFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-EasyLog ("Не удалось прочитать update-sources.json: " + $_.Exception.Message) 'WARN'
        }
    }
    return [PSCustomObject]@{
        ipset     = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt'
        hostlists = ''
    }
}

<# Переключатель IPSet Filter. #>
function Set-EasyIPSetFilter {
    param([bool]$Enabled)
    $s = Get-EasySettings
    $s['IPSetFilter'] = $Enabled
    Save-EasySettings $s
    if ($Enabled) {
        Write-EasyLog 'IPSet Filter ВКЛЮЧЁН: профили по ipset станут активны.' 'WARN'
        Write-EasyLog ('Размер списка: ' + (Get-Item (Join-Path (Get-EasyRoot) 'lists\ipset-all.txt')).Length + ' байт, ~33k записей.') 'INFO'
        Write-EasyLog 'Движок будет читать этот файл при старте — старт станет чуть дольше.' 'INFO'
    } else {
        Write-EasyLog 'IPSet Filter выключен: 33k записей не читаются, профили по ipset неактивны.' 'OK'
    }
}

<# Переключатель Game Filter. #>
function Set-EasyGameFilter {
    param([bool]$Enabled, [string]$TcpPorts = '', [string]$UdpPorts = '')
    $s = Get-EasySettings
    $s['GameFilter'] = $Enabled
    if ($TcpPorts -ne '') { $s['GameFilterTCP'] = $TcpPorts }
    if ($UdpPorts -ne '') { $s['GameFilterUDP'] = $UdpPorts }
    Save-EasySettings $s
    if ($Enabled) {
        Write-EasyLog ("Game Filter ВКЛЮЧЁН. TCP: '" + $s['GameFilterTCP'] + "', UDP: '" + $s['GameFilterUDP'] + "'") 'WARN'
        Write-EasyLog 'Игровые профили используют ipset — не забудьте про IPSet Filter.' 'WARN'
    } else {
        Write-EasyLog 'Game Filter выключен: игровые профили не создаются.' 'OK'
    }
}

<# Проверка правдоподобности скачанного списка. #>
function Test-EasyListContent {
    param([string]$Path, [string]$Kind)

    if (-not (Test-Path -LiteralPath $Path)) { return @('файл не создан') }

    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -eq 0) { return @('файл пустой') }
    if ($size -gt 20MB) { return @("файл слишком большой: $size байт") }

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue |
               Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') })
    if ($lines.Count -lt 1) { return @('нет ни одной значимой строки') }

    $errors = @()
    if ($Kind -eq 'ipset') {
        $bad = @($lines | Where-Object { $_ -notmatch '^[0-9a-fA-F\.\:]+(/[0-9]{1,3})?$' })
        if ($bad.Count -gt 0) { $errors += ("строк, не похожих на IP/подсеть: " + $bad.Count) }
    } else {
        $bad = @($lines | Where-Object { $_ -notmatch '^[!^]?[A-Za-z0-9_\.\-]+$' })
        if ($bad.Count -gt 0) { $errors += ("строк, не похожих на домены: " + $bad.Count) }
    }
    return $errors
}

<# Обновление списка ipset по кнопке, с подтверждением, бэкапом и отчётом. #>
function Invoke-EasyListUpdate {
    Write-EasyBanner 'ОБНОВЛЕНИЕ СПИСКОВ'

    $src = Get-EasyListSources
    $url = [string]$src.ipset
    if ($url -eq '') {
        Write-EasyLog 'URL для обновления не задан в lists\update-sources.json' 'ERR'
        return
    }

    Write-EasyLog ("Источник: " + $url) 'INFO'
    Write-EasyLog 'Сейчас будет одно сетевое обращение (только по вашему подтверждению).' 'WARN'
    $ans = Read-Host 'Скачать и заменить lists\ipset-all.txt? (y/n)'
    if ($ans -notmatch '^(y|Y|д|Д)') { Write-EasyLog 'Отменено.' 'INFO'; return }

    $target = Join-Path (Get-EasyRoot) 'lists\ipset-all.txt'
    $tmp = Join-Path $env:TEMP ('ipset-new-' + [guid]::NewGuid().ToString('N') + '.txt')

    Write-EasyLog 'Скачиваю...' 'INFO'
    $ok = $false
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -OutFile $tmp -ErrorAction Stop
        $ok = Test-Path -LiteralPath $tmp
    } catch {
        Write-EasyLog ("Ошибка загрузки: " + $_.Exception.Message) 'ERR'
    }
    if (-not $ok) {
        Write-EasyLog 'Загрузка не удалась. Список не изменён.' 'ERR'
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return
    }

    $errors = @(Test-EasyListContent -Path $tmp -Kind 'ipset')
    if ($errors.Count -gt 0) {
        Write-EasyLog ('Скачанный файл не похож на список ipset: ' + ($errors -join '; ')) 'ERR'
        Write-EasyLog 'Замена отменена, старый список цел.' 'ERR'
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return
    }

    $old = @()
    if (Test-Path -LiteralPath $target) {
        $old = @(Get-Content -LiteralPath $target -ErrorAction SilentlyContinue |
                 Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') })
    }
    $new = @(Get-Content -LiteralPath $tmp | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') })

    $oldSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($x in $old) { [void]$oldSet.Add($x) }
    $newSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($x in $new) { [void]$newSet.Add($x) }

    $added = @($newSet | Where-Object { -not $oldSet.Contains($_) })
    $removed = @($oldSet | Where-Object { -not $newSet.Contains($_) })

    $backup = $target + '.backup'
    if (Test-Path -LiteralPath $target) { Copy-Item -LiteralPath $target -Destination $backup -Force }

    Move-Item -LiteralPath $tmp -Destination $target -Force

    Write-EasyLog ("Список обновлён. Было " + $old.Count + ", стало " + $new.Count + " записей.") 'OK'
    Write-EasyLog ("Добавлено: " + $added.Count + ", убрано: " + $removed.Count) 'INFO'
    Write-EasyLog ("Резервная копия: " + $backup) 'INFO'
    Write-EasyLog 'Файлы *-user.txt не тронуты.' 'OK'

    if ((Get-EasyServiceState) -eq 'Running') {
        Write-EasyLog 'Служба работает: перечитайте списки перезапуском службы (пункт «Сменить пресет» или переустановка).' 'WARN'
    }
}

<# Показать состояние фильтров и открыть папку списков. #>
function Show-EasyLists {
    Write-EasyBanner 'СПИСКИ И ИСКЛЮЧЕНИЯ'
    $s = Get-EasySettings
    Write-EasyLog ("IPSet Filter: " + $(if ($s['IPSetFilter']) { 'включён' } else { 'выключен' })) 'INFO'
    Write-EasyLog ("Game Filter : " + $(if ($s['GameFilter']) { 'включён' } else { 'выключен' })) 'INFO'

    $listDir = Join-Path (Get-EasyRoot) 'lists'
    foreach ($f in @(Get-ChildItem -LiteralPath $listDir -Filter '*.txt' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $n = @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue |
               Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') }).Count
        $kind = 'общий'
        if ($f.Name -like '*user*') { $kind = 'ВАШ (не обновляется)' }
        Write-EasyLog ("  {0,-26} {1,7} записей   [{2}]" -f $f.Name, $n, $kind) 'INFO'
    }

    Write-Host ''
    Write-Host '  Ваши файлы:                 что класть'
    Write-Host '   list-general-user.txt  - домены, которым нужен обход'
    Write-Host '   list-exclude-user.txt  - домены, которым обход НЕ нужен (банки, корп. VPN)'
    Write-Host '   ipset-exclude-user.txt - IP/подсети, которые не трогать'
    Write-Host ''
    $ans = Read-Host 'Открыть папку lists в проводнике? (y/n)'
    if ($ans -match '^(y|Y|д|Д)') { Start-Process -FilePath 'explorer.exe' -ArgumentList @($listDir) }
}

<# Ввод портов игрового фильтра. #>
function Read-EasyGamePorts {
    $s = Get-EasySettings
    Write-Host ''
    Write-Host ("  Текущие порты TCP: '" + $s['GameFilterTCP'] + "'")
    $tcp = Read-Host '  Новые TCP-порты (например 50000-50100,27015), пусто = не менять'
    Write-Host ("  Текущие порты UDP: '" + $s['GameFilterUDP'] + "'")
    $udp = Read-Host '  Новые UDP-порты (например 50000-50100,27015), пусто = не менять'

    foreach ($v in @(@{n='TCP';v=$tcp}, @{n='UDP';v=$udp})) {
        if ($v.v -eq '') { continue }
        if ($v.v -notmatch '^\d+([\-,]\d+)*$') {
            Write-EasyLog ("Некорректный список портов " + $v.n + ": '" + $v.v + "'") 'ERR'
            return $null
        }
    }
    return [PSCustomObject]@{
        Tcp = $(if ($tcp -ne '') { $tcp } else { $s['GameFilterTCP'] })
        Udp = $(if ($udp -ne '') { $udp } else { $s['GameFilterUDP'] })
    }
}
