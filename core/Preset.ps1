<#
  Preset.ps1 - чтение пресетов, применение настроек, запуск движка.
  Dot-source:  . "$PSScriptRoot\Common.ps1"; . "$PSScriptRoot\Preset.ps1"

  Формат пресета - см. presets\_FORMAT.md.

  Build-директивы (НЕ передаются в winws2):
    --easy-require=ipset        профиль нужен только при включённом IPSet Filter
    --easy-require=gamefilter   профиль нужен только при включённом Game Filter
  Если требование не выполнено, профиль выбрасывается целиком.
  Ни один токен --easy-* не должен попасть в аргументы движка (проверяется тестом).
#>

$script:EasySettingsFile = Join-Path (Get-EasyRoot) 'easy.settings.json'

$script:EasyFileOptions = @(
    '--hostlist', '--hostlist-exclude', '--hostlist-auto',
    '--ipset', '--ipset-exclude',
    '--lua-init', '--wf-raw-part', '--wf-raw-filter', '--wf-raw', '--wf-save'
)

# ------------------------------------------------------------------ settings
function Get-EasyDefaultSettings {
    return [ordered]@{
        Preset         = 'AUTO'
        IPSetFilter    = $false
        GameFilter     = $false
        GameFilterTCP  = ''
        GameFilterUDP  = ''
    }
}

function Get-EasySettings {
    $s = Get-EasyDefaultSettings
    if (Test-Path -LiteralPath $script:EasySettingsFile) {
        try {
            $j = Get-Content -LiteralPath $script:EasySettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($s.Keys)) {
                if ($null -ne $j.PSObject.Properties[$k]) { $s[$k] = $j.$k }
            }
        } catch {
            Write-EasyLog "Не удалось прочитать easy.settings.json: $($_.Exception.Message). Использую значения по умолчанию." 'WARN'
        }
    }
    return $s
}

function Save-EasySettings {
    param($Settings)
    $json = $Settings | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($script:EasySettingsFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# --------------------------------------------------------------------- presets
function Get-EasyPresetFile {
    param([string]$Name)
    if ($Name -match '\.txt$') { $Name = [IO.Path]::GetFileNameWithoutExtension($Name) }
    return (Join-Path (Join-Path (Get-EasyRoot) 'presets') "$Name.txt")
}

function Get-EasyPresetNames {
    $dir = Join-Path (Get-EasyRoot) 'presets'
    if (-not (Test-Path $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.txt' -File |
             Sort-Object Name |
             ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } |
             Where-Object { -not $_.StartsWith('_') })
}

<# Убирает висячие запятые после подстановки пустых плейсхолдеров. #>
function Optimize-PortList {
    param([string]$Value)
    $v = $Value
    $v = $v -replace ',+', ','
    $v = $v -replace '^,', ''
    $v = $v -replace ',$', ''
    return $v
}

<# Подставляет {GAMEFILTERTCP}/{GAMEFILTERUDP} и чистит списки портов. #>
function Expand-EasyPlaceholders {
    param([string[]]$Tokens, $Settings)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($t in $Tokens) {
        $x = $t
        if ($x.Contains('{GAMEFILTERTCP}')) {
            $x = $x.Replace('{GAMEFILTERTCP}', [string]$Settings['GameFilterTCP'])
            if ($x -match '^(--wf-tcp-(in|out)|--filter-tcp)=(.*)$') { $x = "$($Matches[1])=$(Optimize-PortList $Matches[3])" }
        }
        if ($x.Contains('{GAMEFILTERUDP}')) {
            $x = $x.Replace('{GAMEFILTERUDP}', [string]$Settings['GameFilterUDP'])
            if ($x -match '^(--wf-udp-(in|out)|--filter-udp)=(.*)$') { $x = "$($Matches[1])=$(Optimize-PortList $Matches[3])" }
        }
        # пустой список портов -> опцию выкидываем
        if ($x -match '^(--wf-tcp-(in|out)|--wf-udp-(in|out))=$') { continue }
        $out.Add($x)
    }
    return $out.ToArray()
}

<#
  Читает и ГОТОВИТ пресет к запуску: разбирает профили, выбрасывает неактуальные
  по --easy-require, убирает build-директивы, подставляет настройки.
  Возвращает: Name, File, Meta, Args (готовые аргументы), Profiles (инфо), Dropped
#>
function Read-EasyPreset {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $Settings
    )

    if (-not $Settings) { $Settings = Get-EasySettings }

    $file = Get-EasyPresetFile $Name
    if (-not (Test-Path -LiteralPath $file)) { throw "Пресет не найден: $file" }

    $root = Get-EasyRoot
    $meta = @{}
    $blocks = New-Object System.Collections.Generic.List[object]
    $current = $null
    $section = 'none'
    $lineNo = 0

    foreach ($raw in (Get-Content -LiteralPath $file -Encoding UTF8)) {
        $lineNo++
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -eq '[meta]')  { $section = 'meta'; continue }
        if ($line -eq '[args]')  { $section = 'args'; $current = New-Object System.Collections.Generic.List[string]; $blocks.Add($current); continue }
        if ($line -match '^\[.*\]$') { throw "${file}:${lineNo}: неизвестная секция '$line'" }

        if ($section -eq 'meta') {
            if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { $meta[$Matches[1].ToLowerInvariant()] = $Matches[2] }
            else { throw "${file}:${lineNo}: ожидается 'ключ = значение'" }
            continue
        }
        if ($section -eq 'args') {
            foreach ($t0 in ($line -split '\s+')) {
                if ($t0 -eq '') { continue }
                $t = $t0.Replace('{ROOT}', $root)
                if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) { $t = $t.Substring(1, $t.Length - 2) }
                $current.Add($t)
            }
            continue
        }
        throw "${file}:${lineNo}: аргументы вне секции [args]"
    }

    # ---- разбиваем на профили по --new, фильтруем по --easy-require
    # имя профиля задаётся формой --new=NAME и относится к НАЧИНАЕМОМУ профилю,
    # поэтому его надо сохранить и вернуть в аргументы, иначе winws2 покажет (noname)
    $buf = New-Object System.Collections.Generic.List[string]
    $bufName = ''
    $buffers = New-Object System.Collections.Generic.List[object]
    foreach ($t in $blocks[0]) {
        if ($t -eq '--new') {
            $buffers.Add([PSCustomObject]@{ Name = $bufName; Args = $buf.ToArray() })
            $buf = New-Object System.Collections.Generic.List[string]
            $bufName = ''
            continue
        }
        if ($t -like '--new=*') {
            $buffers.Add([PSCustomObject]@{ Name = $bufName; Args = $buf.ToArray() })
            $bufName = $t.Substring(6)
            $buf = New-Object System.Collections.Generic.List[string]
            continue
        }
        $buf.Add($t)
    }
    $buffers.Add([PSCustomObject]@{ Name = $bufName; Args = $buf.ToArray() })

    $dropped = @()
    $kept = @()
    $idx = 0
    foreach ($b in $buffers) {
        $idx++
        if (@($b.Args).Count -eq 0) { continue }

        $requires = @()
        $clean = New-Object System.Collections.Generic.List[string]
        foreach ($t in $b.Args) {
            if ($t -match '^--easy-require=(.+)$') { $requires += $Matches[1]; continue }
            $clean.Add($t)
        }

        $active = $true
        foreach ($r in $requires) {
            switch ($r) {
                'ipset'      { if (-not [bool]$Settings['IPSetFilter']) { $active = $false } }
                'gamefilter' { if (-not [bool]$Settings['GameFilter'])  { $active = $false } }
                default      { Write-EasyLog "Пресет ${Name}: неизвестное требование --easy-require=$r, профиль пропущен" 'WARN'; $active = $false }
            }
        }
        if (-not $active) {
            $dropped += "профиль $idx ($($requires -join ','))"
            continue
        }
        $kept += ,([PSCustomObject]@{ Name = $b.Name; Args = $clean.ToArray() })
    }

    # ---- глобальная часть: первый профиль несёт --wf-*; если он выброшен,
    #      нужно сохранить общие опции (lua-init/blob), иначе движок не стартует
    $globalTokens = New-Object System.Collections.Generic.List[string]
    if ($kept.Count -eq 0) {
        throw "Пресет ${Name}: после применения настроек не осталось ни одного профиля"
    }

    # общие опции (lua-init/blob/wf) живут в первом буфере независимо от того,
    # уцелел ли первый профиль после фильтрации по --easy-require
    $globalTokens = New-Object System.Collections.Generic.List[string]
    foreach ($t in $buffers[0].Args) {
        if ($t -match '^--(lua-init|blob|wf-)') { $globalTokens.Add($t) }
    }

    $args_ = New-Object System.Collections.Generic.List[string]
    foreach ($t in (Expand-EasyPlaceholders $globalTokens.ToArray() $Settings)) { $args_.Add($t) }

    $firstOut = $true
    foreach ($b in $kept) {
        if (-not $firstOut) {
            if ($b.Name) { $args_.Add("--new=$($b.Name)") } else { $args_.Add('--new') }
        }
        $firstOut = $false
        # из первого блока уже забрали lua-init/blob/wf - остальное оставляем
        $body = New-Object System.Collections.Generic.List[string]
        foreach ($t in $b.Args) {
            if ($t -match '^--(lua-init|blob|wf-)=?') { continue }
            if ($t -match '^--wf-') { continue }
            $body.Add($t)
        }
        foreach ($t in (Expand-EasyPlaceholders $body.ToArray() $Settings)) { $args_.Add($t) }
    }

    $final = $args_.ToArray()
    $leak = @($final | Where-Object { $_ -like '--easy-*' })
    if ($leak.Count -gt 0) { throw "Пресет ${Name}: build-директивы просочились в аргументы: $($leak -join ' ')" }

    return [PSCustomObject]@{
        Name     = [IO.Path]::GetFileNameWithoutExtension($file)
        File     = $file
        Meta     = $meta
        Args     = $final
        Profiles = $kept.Count
        Dropped  = $dropped
    }
}

# ------------------------------------------------------------------- checks
function Test-EasyPresetFiles {
    param([Parameter(Mandatory = $true)]$Preset)
    $errors = @()
    foreach ($a in $Preset.Args) {
        foreach ($opt in $script:EasyFileOptions) {
            if ($a -like "$opt=*") {
                $val = $a.Substring($opt.Length + 1)
                if ($val.StartsWith('@')) { $val = $val.Substring(1) }
                if ($val -eq '') { $errors += "$($Preset.Name): $opt= пустое значение" }
                elseif (-not (Test-Path -LiteralPath $val)) { $errors += "$($Preset.Name): $opt -> файл не найден: $val" }
            }
        }
        if ($a -match '^(--blob|--lua-init)=.*@(.+)$') {
            $f = $Matches[2]
            if (-not (Test-Path -LiteralPath $f)) { $errors += "$($Preset.Name): $($Matches[1]) -> файл не найден: $f" }
        }
    }
    return $errors
}

function Test-EasyPresetDuplicateLists {
    param([Parameter(Mandatory = $true)]$Preset)
    $errors = @()
    $profileNo = 1
    $seen = @{}
    foreach ($a in $Preset.Args) {
        if ($a -eq '--new' -or $a -like '--new=*') { $profileNo++; $seen = @{}; continue }
        if ($a -match '^(--hostlist|--hostlist-exclude|--hostlist-auto|--ipset|--ipset-exclude)=(.+)$') {
            $key = "$($Matches[1])|$($Matches[2].ToLowerInvariant())"
            if ($seen.ContainsKey($key)) { $errors += "$($Preset.Name): профиль $profileNo повторно указывает $($Matches[1])=$($Matches[2])" }
            else { $seen[$key] = $true }
        }
    }
    return $errors
}

# --------------------------------------------------------------------- run
function Invoke-Winws2 {
    param(
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 30,
        [switch]$DryRun
    )
    $exe = Get-Winws2Path
    if (-not (Test-Path -LiteralPath $exe)) { throw "winws2.exe не найден: $exe" }

    $argList = @()
    if ($DryRun) { $argList += '--dry-run' }
    $argList += $Arguments

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $exe
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
        # например "The requested operation requires elevation" (нет прав)
        return [PSCustomObject]@{
            ExitCode   = -1
            StdOut     = ''
            StdErr     = $_.Exception.Message
            TimedOut   = $false
            StartError = $true
        }
    }

    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $finished = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        try { $proc.Kill() } catch { }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    }
    $stdout = ''; $stderr = ''
    try { $stdout = $outTask.GetAwaiter().GetResult() } catch { }
    try { $stderr = $errTask.GetAwaiter().GetResult() } catch { }
    $code = -1
    try { $code = $proc.ExitCode } catch { }

    return [PSCustomObject]@{ ExitCode = $code; StdOut = $stdout; StdErr = $stderr; TimedOut = (-not $finished) }
}

function ConvertTo-EasyServiceBinPath {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $exe = Get-Winws2Path
    $parts = @('"' + $exe + '"')
    foreach ($a in $Arguments) { if ($a -match '\s') { $parts += '"' + $a + '"' } else { $parts += $a } }
    return ($parts -join ' ')
}

<#
  Список пресетов с названиями для меню.
  Возвращает объекты: Name, Title, Desc. Метку берём из [meta] самого пресета,
  поэтому список всегда соответствует файлам на диске.
#>
function Get-EasyPresetChoices {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($n in @(Get-EasyPresetNames)) {
        $title = ''
        $desc  = ''
        try {
            $p = Read-EasyPreset $n
            if ($p.Meta.ContainsKey('title')) { $title = [string]$p.Meta['title'] }
            if ($p.Meta.ContainsKey('desc'))  { $desc  = [string]$p.Meta['desc'] }
        } catch { }
        $list.Add([PSCustomObject]@{ Name = $n; Title = $title; Desc = $desc })
    }
    return $list
}
