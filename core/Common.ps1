<#
  Common.ps1 - общие функции Zapret2 Easy.
  Dot-source:  . "$PSScriptRoot\Common.ps1"

  Никакой телеметрии и сетевых обращений здесь нет.
#>

$ErrorActionPreference = 'Stop'

# Корень сборки = родитель папки core
$script:EasyRoot = Split-Path -Parent $PSScriptRoot
$script:LogsDir  = Join-Path $script:EasyRoot 'logs'
$script:LogFile  = Join-Path $script:LogsDir  'zapret-easy.log'

if (-not (Test-Path $script:LogsDir)) {
    New-Item -ItemType Directory -Path $script:LogsDir -Force | Out-Null
}

# Консоль в UTF-8, чтобы русский текст не превращался в кракозябры
try {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [Console]::OutputEncoding = $utf8
    [Console]::InputEncoding  = $utf8
} catch { }

function Get-EasyRoot   { return $script:EasyRoot }
function Get-EasyLogDir { return $script:LogsDir }

<#
<#
  Единая точка логирования: пишет и в консоль, и в logs\zapret-easy.log.
  Level: INFO OK WARN ERR DBG
#>
function Write-EasyLog {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Message,
        [Parameter(Position = 1)]
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'DBG', 'HEAD', 'SKIP')][string]$Level = 'INFO'
    )

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $tag   = switch ($Level) {
        'OK'   { '[ OK ]' }
        'WARN' { '[WARN]' }
        'ERR'  { '[FAIL]' }
        'DBG'  { '[DBG ]' }
        'HEAD' { '[--]  ' }
        'SKIP' { '[SKIP]' }
        default { '[INFO]' }
    }
    $line = "$stamp $tag $Message"

    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }

    $color = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red' }
        'DBG'  { 'DarkGray' }
        'HEAD' { 'Cyan' }
        'SKIP' { 'DarkYellow' }
        default { 'Gray' }
    }
    # не роняем программу, если консоль недоступна
    try { Write-Host $line -ForegroundColor $color } catch { }
}

function Write-EasyBanner {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host ("  $Text") -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
}

<# Запущено ли с правами администратора (нужно для WinDivert и службы). #>
function Test-EasyAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

<# Прерывает выполнение с понятным сообщением, если прав нет. #>
function Assert-EasyAdmin {
    if (-not (Test-EasyAdmin)) {
        Write-EasyLog 'Требуются права администратора. Закройте и запустите service.bat -> "Запуск от имени администратора".' 'ERR'
        throw 'Требуются права администратора'
    }
}

<#
  Проверка пути установки. Возвращает массив проблем (пустой = всё хорошо).
  Проблемы: не-ASCII (кириллица), пробелы, слишком длинный путь.
#>
function Test-EasyPath {
    param([string]$Path = $script:EasyRoot)

    $issues = New-Object System.Collections.ArrayList

    if ($Path -match '[^\x20-\x7E]') {
        [void]$issues.Add('путь содержит не-ASCII символы (кириллица). WinDivert и cygwin это переживают не всегда.')
    }
    if ($Path -match '\s') {
        [void]$issues.Add('путь содержит пробелы. Кавычки в аргументах службы Windows могут сломаться.')
    }
    if ($Path.Length -gt 120) {
        [void]$issues.Add("путь слишком длинный ($($Path.Length) символов).")
    }
    return $issues.ToArray()
}

<# Проверяет, что все обязательные файлы движка на месте. #>
function Test-EasyRuntime {
    $required = @(
        'bin\winws2.exe',
        'bin\cygwin1.dll',
        'bin\WinDivert.dll',
        'bin\WinDivert64.sys',
        'lua\zapret-lib.lua',
        'lua\zapret-antidpi.lua',
        'lua\zapret-auto.lua'
    )
    $missing = @()
    foreach ($rel in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:EasyRoot $rel))) {
            $missing += $rel
        }
    }
    return $missing
}

function Get-Winws2Path { return (Join-Path $script:EasyRoot 'bin\winws2.exe') }

<#
  Останавливает ТОЛЬКО наши процессы winws2 (из нашей папки bin). Чужие сборки не трогаем.
  kill -> wait -> проверка -> при необходимости taskkill /F -> повтор.
  Возвращает: Killed, Remaining, Gone.
#>
function Stop-EasyWinws2 {
    param([int]$Attempts = 3)

    $killed = 0
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $procs = @(Get-EasyWinws2Process)
        if ($procs.Count -eq 0) { break }

        foreach ($p in $procs) {
            $id = $p.Id
            try {
                if (-not $p.HasExited) { $p.Kill() }
                [void]$p.WaitForExit(3000)
            } catch { }

            $alive = $true
            try { $alive = -not $p.HasExited } catch { $alive = $false }

            if ($alive) {
                try { & "$env:SystemRoot\System32\taskkill.exe" /F /PID $id 2>&1 | Out-Null } catch { }
                Start-Sleep -Milliseconds 600
                try { $alive = -not $p.HasExited } catch { $alive = $false }
            }

            if (-not $alive) {
                $killed++
                Write-EasyLog "Остановлен процесс winws2 PID=$id" 'INFO'
            } else {
                Write-EasyLog "winws2 PID=$id не завершился с попытки $attempt" 'WARN'
            }
        }
        Start-Sleep -Milliseconds 400
    }

    $remaining = @(Get-EasyWinws2Process)
    if ($remaining.Count -gt 0) {
        Write-EasyLog ("Не удалось завершить winws2: " + (($remaining | ForEach-Object { $_.Id }) -join ', ')) 'ERR'
    } elseif ($killed -eq 0) {
        Write-EasyLog 'Наших запущенных процессов winws2 нет.' 'DBG'
    }

    return [PSCustomObject]@{
        Killed    = $killed
        Remaining = $remaining.Count
        Gone      = ($remaining.Count -eq 0)
    }
}

<# Проверка, что наших winws2 не осталось. #>
function Test-EasyWinws2Gone {
    return (@(Get-EasyWinws2Process).Count -eq 0)
}

<# Список наших процессов winws2 (по пути), не трогая чужие. #>
function Get-EasyWinws2Process {
    $binDir = Join-Path $script:EasyRoot 'bin'
    $result = @()
    foreach ($p in @(Get-Process -Name 'winws2' -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $p.Path } catch { }
        if ($path -and $path.StartsWith($binDir, [StringComparison]::OrdinalIgnoreCase)) {
            $result += $p
        }
    }
    # без унарной запятой: пустой результат должен давать 0 элементов,
    # иначе @() вокруг вызова завернёт пустой массив в один фантомный элемент
    return $result
}


