#Requires -RunAsAdministrator
<#
.SYNOPSIS
    各PCで実行し、システム情報を収集して Result.csv に追記します。
.DESCRIPTION
    出力先: C:\work\01.server\Result.csv
    実行方法: 各PCで管理者権限のPowerShellで実行してください。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$OutputPath = "C:\work\01.server"
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# システム情報
$cs   = Get-WmiObject Win32_ComputerSystem
$bios = Get-WmiObject Win32_BIOS
$memMB = [math]::Round($cs.TotalPhysicalMemory / 1MB)

# ネットワーク設定（IPv4有効アダプタ）
$netConfigs = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled }
$mainNic = $netConfigs | Where-Object { $_.MACAddress -and $_.MACAddress -ne '00:00:00:00:00:00' } | Select-Object -First 1

$ip      = if ($mainNic.IPAddress)            { ($mainNic.IPAddress  | Where-Object { $_ -match '^\d' })[0] } else { '' }
$subnet  = if ($mainNic.IPSubnet)             { ($mainNic.IPSubnet   | Where-Object { $_ -match '^\d' })[0] } else { '' }
$gateway = if ($mainNic.DefaultIPGateway)     { $mainNic.DefaultIPGateway[0] }  else { '' }
$dns1    = if ($mainNic.DNSServerSearchOrder -and $mainNic.DNSServerSearchOrder.Count -ge 1) { $mainNic.DNSServerSearchOrder[0] } else { '' }
$dns2    = if ($mainNic.DNSServerSearchOrder -and $mainNic.DNSServerSearchOrder.Count -ge 2) { $mainNic.DNSServerSearchOrder[1] } else { '' }
$mac     = if ($mainNic.MACAddress)           { $mainNic.MACAddress } else { '' }

$row = [PSCustomObject]@{
    コンピュータ名          = $env:COMPUTERNAME
    型番                   = $cs.Model
    製造番号               = ($bios.SerialNumber).Trim()
    IPアドレス             = $ip
    サブネットマスク        = $subnet
    ゲートウェイ           = $gateway
    DNS1                   = $dns1
    DNS2                   = $dns2
    物理メモリ             = "${memMB}MB"
    PointSec               = ''
    フォルダ確認           = ''
    イーサネットMacアドレス = "イーサネットMacアドレス: $mac"
}

$OutputFile = Join-Path $OutputPath "Result.csv"
$utf8bom = New-Object System.Text.UTF8Encoding $true

if (-not (Test-Path $OutputFile)) {
    $header = 'コンピュータ名,型番,製造番号,IPアドレス,サブネットマスク,ゲートウェイ,DNS1,DNS2,物理メモリ,PointSec,フォルダ確認,イーサネットMacアドレス'
    [System.IO.File]::WriteAllText($OutputFile, $header + "`r`n", $utf8bom)
}

$line = '"{0}","{1}","{2}","{3}","{4}","{5}","{6}","{7}","{8}","{9}","{10}","{11}"' -f `
    $row.コンピュータ名, $row.型番, $row.製造番号, $row.IPアドレス, $row.サブネットマスク,
    $row.ゲートウェイ, $row.DNS1, $row.DNS2, $row.物理メモリ, $row.PointSec,
    $row.フォルダ確認, $row.イーサネットMacアドレス

[System.IO.File]::AppendAllText($OutputFile, $line + "`r`n", $utf8bom)

Write-Host "完了: $OutputFile"
