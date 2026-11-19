<#
  Update.ps1 - проверка наличия новой версии движка на GitHub.
  Только по нажатию кнопки. Ничего не скачивает и не устанавливает.

  Запрос идёт к официальному репозиторию bol-van/zapret2 (api.github.com).
  Никакой телеметрии: это единственное сетевое обращение в сборке,
  кроме явного обновления списков.
#>

function Get-EasyVersionInfo {
    $file = Join-Path (Get-EasyRoot) 'VERSION'
    $info = @{ easy = 'неизвестно'; engine = 'неизвестно' }
    if (Test-Path -LiteralPath $file) {
        foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
            if ($line -match '^\s*easy\s*=\s*(\S+)')   { $info['easy'] = $Matches[1] }
            if ($line -match '^\s*engine\s*=\s*(\S+)') { $info['engine'] = $Matches[1] }
        }
    }
    return $info
}

function Invoke-EasyUpdateCheck {
    Write-EasyBanner 'ПРОВЕРКА ОБНОВЛЕНИЙ'

    $v = Get-EasyVersionInfo
    Write-EasyLog ("Версия сборки : " + $v['easy']) 'INFO'
    Write-EasyLog ("Версия движка : zapret2 v" + $v['engine']) 'INFO'
    Write-EasyLog 'Запрашиваю GitHub (api.github.com, официальный репозиторий bol-van/zapret2)...' 'INFO'

    $url = 'https://api.github.com/repos/bol-van/zapret2/releases/latest'
    $tag = $null
    try {
        $headers = @{ 'User-Agent' = 'zapret2-easy' }
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        $j = $resp.Content | ConvertFrom-Json
        $tag = [string]$j.tag_name
    } catch {
        Write-EasyLog ("Не удалось проверить: " + $_.Exception.Message) 'ERR'
        Write-EasyLog 'Это не ошибка сборки. Проверьте интернет или повторите позже.' 'INFO'
        return
    }

    if ([string]::IsNullOrWhiteSpace($tag)) {
        Write-EasyLog 'GitHub вернул пустой тег — проверить не удалось.' 'ERR'
        return
    }

    Write-EasyLog ("Последний релиз движка: " + $tag) 'INFO'
    $latest = $tag.TrimStart('v', 'V')

    if ($latest -eq $v['engine']) {
        Write-EasyLog 'У вас актуальная версия движка.' 'OK'
    } else {
        Write-EasyLog ("Доступна другая версия движка: " + $tag + " (у вас " + $v['engine'] + ")") 'WARN'
        Write-EasyLog 'Скачивать и подменять движок автоматически сборка не будет: это ломает совместимость' 'WARN'
        Write-EasyLog 'пресетов. Новая версия сборки готовится отдельно.' 'WARN'
        Write-EasyLog 'Официальный релиз: https://github.com/bol-van/zapret2/releases' 'INFO'
    }

    Write-EasyLog 'Сборка не является официальным проектом bol-van или Flowseal. См. THIRD_PARTY_NOTICES.md' 'INFO'
}
