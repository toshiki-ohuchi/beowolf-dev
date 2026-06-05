#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows 11 PC クライアント情報収集スクリプト
.DESCRIPTION
    PC クライアントの各種設定情報を CSV ファイルに出力します。
    出力先フォルダ (02.teacher / 03.student) をスクリプト起動直後に選択します。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# -----------------------------------------------------------------------
# 出力先フォルダ選択（起動直後）
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "出力先フォルダを選択してください:" -ForegroundColor Cyan
Write-Host "  1: C:\work\02.teacher\"
Write-Host "  2: C:\work\03.student\"
Write-Host ""

do {
    $choice = Read-Host "番号を入力 (1 または 2)"
} while ($choice -ne '1' -and $choice -ne '2')

$OutputPath = if ($choice -eq '1') { 'C:\work\02.teacher' } else { 'C:\work\03.student' }

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Host "フォルダを作成しました: $OutputPath" -ForegroundColor Green
}

$HostName = $env:COMPUTERNAME
Write-Host ""
Write-Host "情報収集を開始します。ホスト名: $HostName" -ForegroundColor Cyan
Write-Host "出力先: $OutputPath" -ForegroundColor Cyan
Write-Host ""

# -----------------------------------------------------------------------
# 共通ヘルパー
# -----------------------------------------------------------------------
$utf8bom = New-Object System.Text.UTF8Encoding $true

function New-OutputFile {
    param([string]$Path)
    [System.IO.File]::WriteAllText($Path, '', $utf8bom)
}

function Write-CsvLine {
    param([string]$Path, [string[]]$Values)
    $escaped = $Values | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }
    [System.IO.File]::AppendAllText($Path, ($escaped -join ',') + "`r`n", $utf8bom)
}

function Write-RawLine {
    param([string]$Path, [string]$Line)
    [System.IO.File]::AppendAllText($Path, $Line + "`r`n", $utf8bom)
}

function Bool-ToJp {
    param($val)
    if ($val) { return '有効' } else { return '無効' }
}

function Convert-Rights {
    param([System.Security.AccessControl.FileSystemRights]$rights)
    $r = [int]$rights
    if (($r -band 0x1F01FF) -eq 0x1F01FF) { return 'フル コントロール' }
    if (($r -band 0x1301BF) -eq 0x1301BF) { return '変更' }
    if (($r -band 0x1200A9) -eq 0x1200A9) { return '読み取りと実行' }
    if (($r -band 0x00116) -eq 0x00116)   { return '書き込み' }
    if (($r -band 0x20089) -eq 0x20089)   { return '読み取り' }
    return $rights.ToString()
}

function Get-AppliesTo {
    param(
        [System.Security.AccessControl.InheritanceFlags]$iFlags,
        [System.Security.AccessControl.PropagationFlags]$pFlags
    )
    $ci      = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit
    $oi      = [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $inherit = [System.Security.AccessControl.PropagationFlags]::InheritOnly
    $hasCI = ($iFlags -band $ci) -ne 0
    $hasOI = ($iFlags -band $oi) -ne 0
    $ioOnly = ($pFlags -band $inherit) -ne 0
    if ($hasCI -and $hasOI -and -not $ioOnly) { return 'このフォルダ、サブフォルダ、 ファイル' }
    if ($hasCI -and $hasOI -and $ioOnly)      { return 'サブフォルダ、 ファイル' }
    if ($hasCI -and -not $hasOI -and -not $ioOnly) { return 'このフォルダ、サブフォルダ' }
    if (-not $hasCI -and $hasOI -and -not $ioOnly) { return 'このフォルダ、ファイル' }
    if ($hasCI -and -not $hasOI -and $ioOnly)      { return 'サブフォルダ' }
    if (-not $hasCI -and $hasOI -and $ioOnly)      { return 'ファイル' }
    return 'このフォルダ、'
}

# -----------------------------------------------------------------------
# {HOSTNAME}-01-設定.csv
# -----------------------------------------------------------------------
Write-Host "[-01-設定.csv] 収集中..."
$f01 = Join-Path $OutputPath "$HostName-01-設定.csv"
New-OutputFile $f01

function W01 { param([string]$a, [string]$b, [string]$c, [string]$d)
    Write-CsvLine $f01 @($a, $b, $c, $d) }

# システム情報
$cs   = Get-WmiObject Win32_ComputerSystem
$os   = Get-WmiObject Win32_OperatingSystem
$bios = Get-WmiObject Win32_BIOS
$cpu  = Get-WmiObject Win32_Processor | Select-Object -First 1
$mem  = [math]::Round($cs.TotalPhysicalMemory / 1GB)

W01 'コンピュータ名'  $HostName                             '' ''
W01 'OS'             $os.Caption                            '' ''
W01 'OSバージョン'   $os.Version                            '' ''
W01 'OSビルド'       $os.BuildNumber                        '' ''
W01 'OSアーキテクチャ' $os.OSArchitecture                   '' ''
W01 'ドメイン/ワークグループ' $cs.Domain                    '' ''
W01 'メンバー種別'   $(if ($cs.PartOfDomain) { 'ドメインメンバー' } else { 'ワークグループ' }) '' ''
W01 'プロセッサ'     $cpu.Name                              '' ''
W01 'コア数'         $cpu.NumberOfCores.ToString()          '' ''
W01 '論理プロセッサ数' $cpu.NumberOfLogicalProcessors.ToString() '' ''
W01 'メモリ (GB)'    "$mem GB"                              '' ''
W01 'メーカー'       $cs.Manufacturer                      '' ''
W01 'モデル'         $cs.Model                              '' ''
W01 'シリアル番号'   $bios.SerialNumber                     '' ''
W01 'BIOSバージョン' $bios.SMBIOSBIOSVersion                '' ''

# ディスク情報
W01 '' '' '' ''
W01 'ディスク情報' '' '' ''
try {
    $disks = Get-Disk
    foreach ($disk in $disks) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 2)
        $busType = $disk.BusType
        $ptStyle = $disk.PartitionStyle
        W01 "ディスク $($disk.Number)" "$sizeGB GB" $busType $ptStyle
        $parts = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
        foreach ($part in $parts) {
            $vol = Get-Volume -Partition $part -ErrorAction SilentlyContinue
            $driveLetter = if ($part.DriveLetter) { "$($part.DriveLetter):" } else { '(なし)' }
            $volSizeGB = if ($vol) { [math]::Round($vol.Size / 1GB, 2).ToString() + ' GB' } else { '' }
            $volLabel = if ($vol) { $vol.FileSystemLabel } else { '' }
            $volFs = if ($vol) { $vol.FileSystem } else { '' }
            $partType = $part.Type
            W01 "  パーティション $($part.PartitionNumber)" $driveLetter "$volSizeGB $volLabel" "$volFs ($partType)"
        }
    }
} catch {
    W01 'ディスク情報取得エラー' $_.Exception.Message '' ''
}

# ネットワーク情報
W01 '' '' '' ''
W01 'ネットワーク情報' '' '' ''
$nics = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -or $_.InterfaceOperationalStatus -eq 1 }
foreach ($nic in $nics) {
    $ipCfg = Get-NetIPConfiguration -InterfaceIndex $nic.InterfaceIndex -ErrorAction SilentlyContinue
    $ipAddr   = ($ipCfg.IPv4Address | Select-Object -First 1).IPAddress
    $prefix   = ($ipCfg.IPv4Address | Select-Object -First 1).PrefixLength
    $gw       = ($ipCfg.IPv4DefaultGateway | Select-Object -First 1).NextHop
    $dnsAddrs = $ipCfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | Select-Object -ExpandProperty ServerAddresses
    $subnetMask = ''
    if ($prefix) {
        $maskInt = [convert]::ToInt64(('1' * $prefix + '0' * (32 - $prefix)), 2)
        $subnetMask = ('{0}.{1}.{2}.{3}' -f (($maskInt -shr 24) -band 255),(($maskInt -shr 16) -band 255),(($maskInt -shr 8) -band 255),($maskInt -band 255))
    }
    W01 "NIC: $($nic.Name)" $nic.InterfaceDescription '' ''
    W01 '  MACアドレス'   $nic.MacAddress            '' ''
    W01 '  IPアドレス'    ($ipAddr  -join ', ')       '' ''
    W01 '  サブネットマスク' $subnetMask              '' ''
    W01 '  デフォルトGW'  ($gw      -join ', ')       '' ''
    W01 '  DNS1'          ($dnsAddrs | Select-Object -First 1) '' ''
    W01 '  DNS2'          ($dnsAddrs | Select-Object -Skip 1 -First 1) '' ''
    W01 '  リンク速度'    $nic.LinkSpeed.ToString()   '' ''
}

# ネットワークオフロード設定
W01 '' '' '' ''
W01 'ネットワークオフロード' '' '' ''
try {
    $offload = Get-NetOffloadGlobalSetting
    W01 'ReceiveSideScaling'       (Bool-ToJp ($offload.ReceiveSideScaling -eq 'Enabled'))   '' ''
    W01 'ChimneyOffload'           $offload.Chimney.ToString()                                '' ''
    W01 'TaskOffload'              (Bool-ToJp ($offload.TaskOffload -eq 'Enabled'))            '' ''
    W01 'NetworkDirect'            (Bool-ToJp ($offload.NetworkDirect -eq 'Enabled'))          '' ''
    W01 'PacketCoalescingFilter'   (Bool-ToJp ($offload.PacketCoalescingFilter -eq 'Enabled')) '' ''
} catch {
    W01 'オフロード情報取得エラー' $_.Exception.Message '' ''
}

# Windows Update 設定
W01 '' '' '' ''
W01 'Windows Update設定' '' '' ''
try {
    $wuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if (Test-Path $wuKey) {
        $wu = Get-ItemProperty -Path $wuKey -ErrorAction SilentlyContinue
        W01 'NoAutoUpdate'      ($wu.NoAutoUpdate -as [string])      '' ''
        W01 'AUOptions'         ($wu.AUOptions -as [string])         '' ''
        W01 'ScheduledInstallDay'  ($wu.ScheduledInstallDay -as [string])  '' ''
        W01 'ScheduledInstallTime' ($wu.ScheduledInstallTime -as [string]) '' ''
    } else {
        W01 'Windows Update設定' '(グループポリシー設定なし)' '' ''
    }
} catch {
    W01 'WU情報取得エラー' $_.Exception.Message '' ''
}

# NTP 設定
W01 '' '' '' ''
W01 'NTP設定' '' '' ''
try {
    $ntpOutput = w32tm /query /peers 2>&1
    $ntpServer = ($ntpOutput | Where-Object { $_ -match 'ピア' -or $_ -match 'Peer' }) -join '; '
    if (-not $ntpServer) { $ntpServer = ($ntpOutput -join ' ').Trim() }
    W01 'NTPサーバー' $ntpServer '' ''
} catch {
    W01 'NTP情報取得エラー' $_.Exception.Message '' ''
}

# ファイアウォールプロファイル
W01 '' '' '' ''
W01 'ファイアウォールプロファイル' '' '' ''
try {
    $fwProfiles = Get-NetFirewallProfile
    foreach ($p in $fwProfiles) {
        W01 "$($p.Name) プロファイル" (Bool-ToJp ($p.Enabled -eq $true)) '' ''
    }
} catch {
    W01 'FW設定取得エラー' $_.Exception.Message '' ''
}

# RDP / NLA 設定
W01 '' '' '' ''
W01 'リモートデスクトップ設定' '' '' ''
try {
    $rdpKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $fDenyTSConn = (Get-ItemProperty -Path $rdpKey -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections
    W01 'リモートデスクトップ' $(if ($fDenyTSConn -eq 0) { '有効' } else { '無効' }) '' ''
    $nlaKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    $nla = (Get-ItemProperty -Path $nlaKey -Name 'UserAuthentication' -ErrorAction SilentlyContinue).UserAuthentication
    W01 'NLA (ネットワークレベル認証)' $(if ($nla -eq 1) { '有効' } else { '無効' }) '' ''
} catch {
    W01 'RDP設定取得エラー' $_.Exception.Message '' ''
}

# SNMP
W01 '' '' '' ''
W01 'SNMP設定' '' '' ''
try {
    $snmpSvc = Get-Service -Name 'SNMP' -ErrorAction SilentlyContinue
    if ($snmpSvc) {
        W01 'SNMPサービス' (Bool-ToJp ($snmpSvc.Status -eq 'Running')) '' ''
        W01 'SNMPスタートアップ' $snmpSvc.StartType.ToString() '' ''
    } else {
        W01 'SNMPサービス' '無効 (インストールなし)' '' ''
    }
} catch {
    W01 'SNMP情報取得エラー' $_.Exception.Message '' ''
}

Write-Host "  -> $f01"

# -----------------------------------------------------------------------
# {HOSTNAME}-03-アプリケーション.csv
# -----------------------------------------------------------------------
Write-Host "[-03-アプリケーション.csv] 収集中..."
$f03 = Join-Path $OutputPath "$HostName-03-アプリケーション.csv"
New-OutputFile $f03
Write-CsvLine $f03 @('DisplayName', 'Publisher', 'DisplayVersion', 'InstallLocation')

$regPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$apps = $regPaths | ForEach-Object {
    Get-ItemProperty -Path $_ -ErrorAction SilentlyContinue
} | Where-Object { $_.DisplayName } |
    Select-Object DisplayName, Publisher, DisplayVersion, InstallLocation |
    Sort-Object DisplayName

foreach ($app in $apps) {
    Write-CsvLine $f03 @(
        ($app.DisplayName    -as [string]),
        ($app.Publisher      -as [string]),
        ($app.DisplayVersion -as [string]),
        ($app.InstallLocation -as [string])
    )
}
Write-Host "  -> $f03"

# -----------------------------------------------------------------------
# {HOSTNAME}-04-ファイアウォール.csv
# -----------------------------------------------------------------------
Write-Host "[-04-ファイアウォール.csv] 収集中..."
$f04 = Join-Path $OutputPath "$HostName-04-ファイアウォール.csv"
New-OutputFile $f04
Write-CsvLine $f04 @('名前','グループ','プロファイル','有効','規則','操作','プログラム','ローカルIP','リモートIP','ローカルアドレス','リモートアドレス','プロトコル','ローカルポート','リモートポート')

try {
    $fwRules = Get-NetFirewallRule -All -ErrorAction Stop
    foreach ($rule in $fwRules) {
        $portFilter    = $rule | Get-NetFirewallPortFilter    -ErrorAction SilentlyContinue
        $appFilter     = $rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
        $addrFilter    = $rule | Get-NetFirewallAddressFilter  -ErrorAction SilentlyContinue

        $direction = switch ($rule.Direction) {
            'Inbound'  { '受信' }
            'Outbound' { '送信' }
            default    { $rule.Direction.ToString() }
        }
        $action = switch ($rule.Action) {
            'Allow' { '許可' }
            'Block' { 'ブロック' }
            default { $rule.Action.ToString() }
        }
        $profile = $rule.Profile.ToString() -replace 'Any','すべてのプロファイル'

        Write-CsvLine $f04 @(
            $rule.DisplayName,
            ($rule.Group          -as [string]),
            $profile,
            (Bool-ToJp ($rule.Enabled -eq $true)),
            $direction,
            $action,
            ($appFilter.Program   -as [string]),
            ($addrFilter.LocalAddress  -as [string]),
            ($addrFilter.RemoteAddress -as [string]),
            ($addrFilter.LocalAddress  -as [string]),
            ($addrFilter.RemoteAddress -as [string]),
            ($portFilter.Protocol -as [string]),
            ($portFilter.LocalPort  -as [string]),
            ($portFilter.RemotePort -as [string])
        )
    }
} catch {
    Write-Warning "FWルール取得エラー: $_"
}
Write-Host "  -> $f04"

# -----------------------------------------------------------------------
# {HOSTNAME}-05-共有フォルダ.csv
# -----------------------------------------------------------------------
Write-Host "[-05-共有フォルダ.csv] 収集中..."
$f05 = Join-Path $OutputPath "$HostName-05-共有フォルダ.csv"
New-OutputFile $f05
Write-CsvLine $f05 @('共有名','パス','説明','アカウント名','アクセス権','アクセス許可')

try {
    $shares = Get-SmbShare -ErrorAction Stop
    foreach ($share in $shares) {
        $accesses = Get-SmbShareAccess -Name $share.Name -ErrorAction SilentlyContinue
        if ($accesses) {
            foreach ($acc in $accesses) {
                $permType = switch ($acc.AccessControlType) {
                    'Allow' { '許可' }
                    'Deny'  { '拒否' }
                    default { $acc.AccessControlType.ToString() }
                }
                $accessRight = switch ($acc.AccessRight) {
                    'Full'   { 'フルコントロール' }
                    'Change' { '変更' }
                    'Read'   { '読み取り' }
                    default  { $acc.AccessRight.ToString() }
                }
                Write-CsvLine $f05 @(
                    $share.Name,
                    ($share.Path        -as [string]),
                    ($share.Description -as [string]),
                    $acc.AccountName,
                    $accessRight,
                    $permType
                )
            }
        } else {
            Write-CsvLine $f05 @($share.Name, ($share.Path -as [string]), ($share.Description -as [string]), '', '', '')
        }
    }
} catch {
    Write-Warning "共有フォルダ取得エラー: $_"
}
Write-Host "  -> $f05"

# -----------------------------------------------------------------------
# {HOSTNAME}-06-フォルダ.csv
# -----------------------------------------------------------------------
Write-Host "[-06-フォルダ.csv] 収集中..."
$f06 = Join-Path $OutputPath "$HostName-06-フォルダ.csv"
New-OutputFile $f06
Write-CsvLine $f06 @('パス','名前','種類','アクセス許可','継承','適用先')

try {
    $fixedDrives = Get-WmiObject Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object -ExpandProperty DeviceID
    foreach ($drive in $fixedDrives) {
        $topDirs = Get-ChildItem -Path "$drive\" -ErrorAction SilentlyContinue
        foreach ($item in $topDirs) {
            try {
                $acl = Get-Acl -Path $item.FullName -ErrorAction SilentlyContinue
                $kind = if ($item.PSIsContainer) { 'フォルダ' } else { 'ファイル' }
                if ($acl -and $acl.Access) {
                    foreach ($ace in $acl.Access) {
                        $inherited = if ($ace.IsInherited) { '有効' } else { '無効' }
                        $appliesTo = Get-AppliesTo -iFlags $ace.InheritanceFlags -pFlags $ace.PropagationFlags
                        Write-CsvLine $f06 @(
                            $item.FullName,
                            $item.Name,
                            $kind,
                            $ace.IdentityReference.ToString(),
                            (Convert-Rights $ace.FileSystemRights),
                            $inherited,
                            $appliesTo
                        )
                    }
                } else {
                    Write-CsvLine $f06 @($item.FullName, $item.Name, $kind, '', '', '', '')
                }
            } catch {
                Write-CsvLine $f06 @($item.FullName, $item.Name, 'エラー', $_.Exception.Message, '', '', '')
            }
        }
    }
} catch {
    Write-Warning "フォルダ情報取得エラー: $_"
}
Write-Host "  -> $f06"

# -----------------------------------------------------------------------
# {HOSTNAME}-07-ユーザ一覧.csv
# -----------------------------------------------------------------------
Write-Host "[-07-ユーザ一覧.csv] 収集中..."
$f07 = Join-Path $OutputPath "$HostName-07-ユーザ一覧.csv"
New-OutputFile $f07
Write-CsvLine $f07 @('名前','フルネーム','説明','オプション')

try {
    $localUsers = Get-LocalUser -ErrorAction Stop | Sort-Object Name
    foreach ($u in $localUsers) {
        $opts = [System.Collections.Generic.List[string]]::new()
        if ($u.PasswordNeverExpires)           { $opts.Add('パスワードを無期限にする') }
        if (-not $u.UserMayChangePassword)     { $opts.Add('ユーザーはパスワードを変更できない') }
        if (-not $u.Enabled)                   { $opts.Add('アカウントを無効にする') }
        $optStr = $opts -join '/'
        Write-CsvLine $f07 @(
            $u.Name,
            ($u.FullName    -as [string]),
            ($u.Description -as [string]),
            $optStr
        )
    }
} catch {
    Write-Warning "ローカルユーザー取得エラー: $_"
}
Write-Host "  -> $f07"

# -----------------------------------------------------------------------
# {HOSTNAME}-08-グループ一覧.csv
# -----------------------------------------------------------------------
Write-Host "[-08-グループ一覧.csv] 収集中..."
$f08 = Join-Path $OutputPath "$HostName-08-グループ一覧.csv"
New-OutputFile $f08
Write-CsvLine $f08 @('名前','メンバー','説明')

try {
    $localGroups = Get-LocalGroup -ErrorAction Stop | Sort-Object Name
    foreach ($grp in $localGroups) {
        $members = @()
        try {
            $members = Get-LocalGroupMember -Group $grp.Name -ErrorAction SilentlyContinue |
                       ForEach-Object { $_.Name }
        } catch {}
        Write-CsvLine $f08 @(
            $grp.Name,
            ($members -join ';'),
            ($grp.Description -as [string])
        )
    }
} catch {
    Write-Warning "ローカルグループ取得エラー: $_"
}
Write-Host "  -> $f08"

# -----------------------------------------------------------------------
# {HOSTNAME}-09-サービス.csv
# -----------------------------------------------------------------------
Write-Host "[-09-サービス.csv] 収集中..."
$f09 = Join-Path $OutputPath "$HostName-09-サービス.csv"
New-OutputFile $f09
Write-CsvLine $f09 @('DisplayName','StartMode','StartName','Description')

try {
    $services = Get-WmiObject Win32_Service | Sort-Object DisplayName
    foreach ($svc in $services) {
        Write-CsvLine $f09 @(
            ($svc.DisplayName  -as [string]),
            ($svc.StartMode    -as [string]),
            ($svc.StartName    -as [string]),
            ($svc.Description  -as [string])
        )
    }
} catch {
    Write-Warning "サービス取得エラー: $_"
}
Write-Host "  -> $f09"

# -----------------------------------------------------------------------
# {HOSTNAME}-10-プリンタ.csv
# -----------------------------------------------------------------------
Write-Host "[-10-プリンタ.csv] 収集中..."
$f10 = Join-Path $OutputPath "$HostName-10-プリンタ.csv"
New-OutputFile $f10
Write-CsvLine $f10 @('名前','ドライバ名','共有名','ポート名','IP','ポート','プロトコル','LPRキュー名','SNMP','コミュニティ','SNMPデバイスインデックス')

try {
    $printers  = Get-Printer  -ErrorAction Stop
    $portObjs  = Get-PrinterPort -ErrorAction SilentlyContinue

    foreach ($pr in $printers) {
        $port = $portObjs | Where-Object { $_.Name -eq $pr.PortName } | Select-Object -First 1

        $ip          = ''
        $portNum     = ''
        $protocol    = ''
        $lprQueue    = ''
        $snmpEnabled = ''
        $community   = ''
        $snmpIndex   = ''

        if ($port) {
            if ($port.PSObject.Properties['PrinterHostAddress']) { $ip       = $port.PrinterHostAddress -as [string] }
            if ($port.PSObject.Properties['PortNumber'])         { $portNum  = $port.PortNumber -as [string] }
            if ($port.PSObject.Properties['Protocol']) {
                $protocol = switch ($port.Protocol) {
                    1 { 'Raw' }
                    2 { 'LPR' }
                    default { $port.Protocol.ToString() }
                }
            }
            if ($port.PSObject.Properties['Queue'])              { $lprQueue = $port.Queue -as [string] }
            if ($port.PSObject.Properties['SNMPEnabled']) {
                $snmpEnabled = Bool-ToJp ($port.SNMPEnabled)
            }
            if ($port.PSObject.Properties['SNMPCommunity'])      { $community  = $port.SNMPCommunity -as [string] }
            if ($port.PSObject.Properties['SNMPDevIndex'])       { $snmpIndex  = $port.SNMPDevIndex -as [string] }
        }

        Write-CsvLine $f10 @(
            $pr.Name,
            ($pr.DriverName   -as [string]),
            ($pr.ShareName    -as [string]),
            ($pr.PortName     -as [string]),
            $ip,
            $portNum,
            $protocol,
            $lprQueue,
            $snmpEnabled,
            $community,
            $snmpIndex
        )
    }
} catch {
    Write-Warning "プリンター取得エラー: $_"
}
Write-Host "  -> $f10"

# -----------------------------------------------------------------------
# 完了
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "======================================" -ForegroundColor Green
Write-Host "情報収集が完了しました。" -ForegroundColor Green
Write-Host "出力先: $OutputPath" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
