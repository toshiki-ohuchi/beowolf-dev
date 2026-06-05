#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows Server 2022でサーバー情報を収集します。
.DESCRIPTION
    出力ファイル (SERVERNAMEは実行サーバーのホスト名に自動置換):
        C:\work\01.server\{SERVERNAME}-01-設定.csv
        C:\work\01.server\{SERVERNAME}-02-役割・機能.csv
        C:\work\01.server\{SERVERNAME}-03-アプリケーション.csv
        C:\work\01.server\{SERVERNAME}-04-ファイアウォール.csv
        C:\work\01.server\{SERVERNAME}-05-共有フォルダ.csv
        C:\work\01.server\{SERVERNAME}-06-フォルダ.csv
        C:\work\01.server\{SERVERNAME}-07-ユーザ一覧.csv
        C:\work\01.server\{SERVERNAME}-08-グループ一覧.csv
        C:\work\01.server\{SERVERNAME}-09-サービス.csv
        C:\work\01.server\{SERVERNAME}-10-プリンタ.csv
    実行条件: ServerManager / ActiveDirectory モジュールが必要です（DCまたはRSAT）。
    実行方法: サーバーで管理者権限のPowerShellで実行してください。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$ServerName = $env:COMPUTERNAME
$OutputPath = "C:\work\01.server"
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$utf8bom = New-Object System.Text.UTF8Encoding $true

function Write-CsvLine {
    param([string]$Path, [string[]]$Values)
    $escaped = $Values | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }
    [System.IO.File]::AppendAllText($Path, ($escaped -join ',') + "`r`n", $utf8bom)
}

function Write-RawLine {
    param([string]$Path, [string]$Line)
    [System.IO.File]::AppendAllText($Path, $Line + "`r`n", $utf8bom)
}

function New-OutputFile {
    param([string]$Path)
    [System.IO.File]::WriteAllText($Path, '', $utf8bom)
}

function Bool-ToJp {
    param($v)
    if ($v) { '有効' } else { '無効' }
}

#region SERVER-01-設定.csv
$File01 = Join-Path $OutputPath "${ServerName}-01-設定.csv"
New-OutputFile $File01

$cs     = Get-WmiObject Win32_ComputerSystem
$bios   = Get-WmiObject Win32_BIOS
$os     = Get-WmiObject Win32_OperatingSystem
$cpu    = Get-WmiObject Win32_Processor | Select-Object -First 1
$memGB  = [math]::Round($cs.TotalPhysicalMemory / 1GB)
$domain = try { (Get-WmiObject Win32_ComputerSystem).Domain } catch { '' }

# システム情報
$role = switch ($cs.DomainRole) {
    4 { 'ドメインコントローラー' } 5 { 'ドメインコントローラー' }
    2 { 'ドメインメンバーサーバー' } 3 { 'ドメインメンバーサーバー' }
    default { 'ワークグループ' }
}
Write-CsvLine $File01 @('システム情報', 'システム', 'コンピュータ名',         $env:COMPUTERNAME)
Write-CsvLine $File01 @('システム情報', 'システム', 'フルコンピュータ名',     "$($env:COMPUTERNAME).$domain")
Write-CsvLine $File01 @('システム情報', 'システム', 'ワークグループ/ドメイン名', $domain)
Write-CsvLine $File01 @('システム情報', 'システム', '役割',                   $role)

# ハードウェア情報
$hwProduct = Get-WmiObject Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
Write-CsvLine $File01 @('機器情報', 'ハードウェア', '機種',         $cs.Model)
Write-CsvLine $File01 @('機器情報', 'ハードウェア', 'CPU数',        ($cs.NumberOfProcessors).ToString())
Write-CsvLine $File01 @('機器情報', 'ハードウェア', '型番',         if ($hwProduct) { $hwProduct.Name } else { '' })
Write-CsvLine $File01 @('機器情報', 'ハードウェア', 'シリアル番号', if ($hwProduct) { $hwProduct.IdentifyingNumber.Trim() } else { $bios.SerialNumber.Trim() })
Write-CsvLine $File01 @('機器情報', 'ハードウェア', 'BIOSバージョン', $bios.SMBIOSBIOSVersion)
Write-CsvLine $File01 @('機器情報', 'ハードウェア', 'CPU',          $cpu.Name.Trim())
Write-CsvLine $File01 @('機器情報', 'ハードウェア', 'メモリ容量',   "${memGB}GB")

# OS情報
Write-CsvLine $File01 @('システム情報', 'OS', 'OS',           $os.Caption)
Write-CsvLine $File01 @('システム情報', 'OS', 'アーキテクチャ', $os.OSArchitecture)
Write-CsvLine $File01 @('システム情報', 'OS', 'バージョン',    $os.Version.Split('.')[2])
Write-CsvLine $File01 @('システム情報', 'OS', 'ビルド',        $os.BuildNumber)

# リモートデスクトップ
$rdpEnabled = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections -eq 0
$nlaEnabled = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -ErrorAction SilentlyContinue).UserAuthentication -eq 1
Write-CsvLine $File01 @('システム情報', 'リモート', 'リモートデスクトップ',    (Bool-ToJp $rdpEnabled))
Write-CsvLine $File01 @('システム情報', 'リモート', 'ネットワークレベル認証',   (Bool-ToJp $nlaEnabled))

# ディスク構成
$disks = Get-Disk | Sort-Object Number
$diskIndex = 0
foreach ($disk in $disks) {
    $diskLabel = "ディスク $($disk.Number)"
    Write-CsvLine $File01 @('ディスク構成', $diskLabel, 'ディスク番号', $disk.Number.ToString())
    Write-CsvLine $File01 @('ディスク構成', $diskLabel, 'ディスク名',   $disk.FriendlyName)
    Write-CsvLine $File01 @('ディスク構成', $diskLabel, 'ディスク種別', $disk.PartitionStyle)
    $sizeGB = [math]::Round($disk.Size / 1GB, 2)
    Write-CsvLine $File01 @('ディスク構成', $diskLabel, 'ディスクサイズ', "$sizeGB GB")
    $busType = switch ($disk.BusType) {
        'USB'    { 'USB' } 'RAID' { 'RAID' } 'SAS'  { 'SAS' }
        'SATA'   { 'SATA' } 'NVMe' { 'NVMe' } 'SCSI' { 'SCSI' }
        default  { $disk.BusType }
    }
    Write-CsvLine $File01 @('ディスク構成', $diskLabel, '接続種別', $busType)
    $diskIndex++
}

# パーティション情報
foreach ($disk in $disks) {
    $partitions = Get-Partition -DiskNumber $disk.Number | Sort-Object PartitionNumber
    $pIdx = 1
    foreach ($part in $partitions) {
        $vol = Get-Volume -Partition $part -ErrorAction SilentlyContinue
        $driveType = switch ($part.Type) {
            'System'   { 'System' } 'Reserved' { 'Reserved' }
            'Recovery' { 'Recovery' } 'Basic' { 'Basic' }
            'IFS'      { 'IFS' } default { $part.Type }
        }
        $driveLetter = if ($part.DriveLetter) { $part.DriveLetter } else { ' ' }
        $sizeGB = [math]::Round($part.Size / 1GB, 2)
        $fs = if ($vol) { $vol.FileSystem } else { '' }
        $volName = if ($vol) { $vol.FileSystemLabel } else { '' }

        $partLabel = "パーティション $pIdx"
        Write-CsvLine $File01 @("ディスク $($disk.Number)", $partLabel, 'ドライブタイプ', $driveType)
        Write-CsvLine $File01 @("ディスク $($disk.Number)", $partLabel, 'ドライブ文字',   $driveLetter)
        Write-CsvLine $File01 @("ディスク $($disk.Number)", $partLabel, '容量',           "$sizeGB GB")
        Write-CsvLine $File01 @("ディスク $($disk.Number)", $partLabel, 'ファイルシステム', $fs)
        Write-CsvLine $File01 @("ディスク $($disk.Number)", $partLabel, 'ボリューム名',   $volName)
        $pIdx++
    }
}

# CD/DVDドライブ
$cdDrives = Get-WmiObject Win32_CDROMDrive -ErrorAction SilentlyContinue
foreach ($cd in $cdDrives) {
    Write-CsvLine $File01 @('ディスク構成', 'CD/DVDドライブ', 'CD/DVDドライブ文字', $cd.Drive -replace ':', '')
}

# ネットワークアダプタ
$adapters = Get-NetAdapter | Sort-Object InterfaceIndex
$aNdx = 1
foreach ($a in $adapters) {
    $label = "ネットワーク アダプタ$aNdx"
    $speed = if ($a.LinkSpeed -match '(\d+)') { [math]::Round([int64]$Matches[1]) } else { 0 }
    $status = if ($a.Status -eq 'Up') { '有効' } else { '無効' }
    Write-CsvLine $File01 @('ネットワーク', $label, '名前',       $a.Name)
    Write-CsvLine $File01 @('ネットワーク', $label, 'ステータス', $status)
    Write-CsvLine $File01 @('ネットワーク', $label, '速度',       $a.LinkSpeed -replace '[^\d]', '')
    Write-CsvLine $File01 @('ネットワーク', $label, 'デバイス名', $a.InterfaceDescription)
    Write-CsvLine $File01 @('ネットワーク', $label, 'MACアドレス', $a.MacAddress)

    $ipCfg = Get-NetIPConfiguration -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
    if ($ipCfg -and $ipCfg.IPv4Address) {
        Write-CsvLine $File01 @('ネットワーク', $label, 'DHCP',          (Bool-ToJp (($a | Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp -eq 'Enabled')))
        Write-CsvLine $File01 @('ネットワーク', $label, 'IPv4アドレス',  $ipCfg.IPv4Address.IPAddress)
        $prefix = $ipCfg.IPv4Address.PrefixLength
        $subnet = [System.Net.IPAddress]::Parse(([System.Convert]::ToInt64('1' * $prefix + '0' * (32 - $prefix), 2)).ToString()).ToString()
        Write-CsvLine $File01 @('ネットワーク', $label, 'サブネットマスク',      $subnet)
        $gw = if ($ipCfg.IPv4DefaultGateway) { $ipCfg.IPv4DefaultGateway.NextHop } else { '' }
        Write-CsvLine $File01 @('ネットワーク', $label, 'デフォルトゲートウェイ', $gw)
        $dns = $ipCfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | Select-Object -ExpandProperty ServerAddresses
        Write-CsvLine $File01 @('ネットワーク', $label, 'DNS 1', if ($dns -and $dns.Count -ge 1) { $dns[0] } else { '' })
        Write-CsvLine $File01 @('ネットワーク', $label, 'DNS 2', if ($dns -and $dns.Count -ge 2) { $dns[1] } else { '' })
    }

    # プロトコルバインド
    $bindings = Get-NetAdapterBinding -Name $a.Name -ErrorAction SilentlyContinue
    foreach ($b in $bindings) {
        $en = if ($b.Enabled) { '有効' } else { '無効' }
        Write-CsvLine $File01 @('ネットワーク', $label, $b.DisplayName, $en)
    }
    $aNdx++
}

# NICチーミング
$teams = Get-NetLbfoTeam -ErrorAction SilentlyContinue
$tNdx = 1
foreach ($t in $teams) {
    $label = "ネットワーク チーミング$tNdx"
    Write-CsvLine $File01 @('ネットワーク', $label, 'チーム名',     $t.Name)
    Write-CsvLine $File01 @('ネットワーク', $label, 'メンバー',     ($t.Members -join ','))
    Write-CsvLine $File01 @('ネットワーク', $label, 'チーミングモード', $t.TeamingMode.ToString())
    Write-CsvLine $File01 @('ネットワーク', $label, '負荷分散モード',  $t.LoadBalancingAlgorithm.ToString())
    $tNdx++
}

# オフロード設定
$offload = Get-NetOffloadGlobalSetting -ErrorAction SilentlyContinue
if ($offload) {
    Write-CsvLine $File01 @('ネットワーク', 'ネットワーク オフロード設定', 'ReceiveSideScaling',    $offload.ReceiveSideScaling.ToString())
    Write-CsvLine $File01 @('ネットワーク', 'ネットワーク オフロード設定', 'ReceiveSegmentCoalescing', $offload.ReceiveSegmentCoalescing.ToString())
    Write-CsvLine $File01 @('ネットワーク', 'ネットワーク オフロード設定', 'Chimney',               $offload.Chimney.ToString())
    Write-CsvLine $File01 @('ネットワーク', 'ネットワーク オフロード設定', 'TaskOffload',           $offload.TaskOffload.ToString())
}

# Windows Update設定
$wuAU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$wuKey = Get-ItemProperty $wuAU -ErrorAction SilentlyContinue
$auOption = switch ($wuKey.AUOptions) {
    2 { '更新プログラムを確認しない' } 3 { 'ダウンロードのみ行う' }
    4 { '自動的にダウンロードしてインストールする' } 5 { '更新をインストールする前に通知する' }
    default { '更新プログラムを確認しない' }
}
Write-CsvLine $File01 @('コントロールパネル', 'Windows Update', '重要な更新プログラム',       $auOption)
Write-CsvLine $File01 @('コントロールパネル', 'Windows Update', '推奨する更新プログラム',     (if ($wuKey.IncludeRecommendedUpdates -eq 1) { '有効' } else { '無効' }))

# 時刻設定
$w32status = & w32tm /query /status 2>$null
$ntpType = 'ドメインの階層と同期'
$ntpServer = '-'
if ($w32status) {
    $srcLine = $w32status | Where-Object { $_ -match '時刻ソース|Source' }
    if ($srcLine) { $ntpServer = ($srcLine -split ':',2)[1].Trim() }
}
Write-CsvLine $File01 @('コントロールパネル', '時刻設定', 'NTPタイプ',   $ntpType)
Write-CsvLine $File01 @('コントロールパネル', '時刻設定', 'NTPサーバ',   $ntpServer)

# ファイアウォール プロファイル
$fwProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
foreach ($p in $fwProfiles) {
    $profileName = switch ($p.Name) {
        'Domain'  { 'ドメイン プロファイル' } 'Private' { 'プライベート プロファイル' } 'Public' { 'パブリック プロファイル' }
    }
    Write-CsvLine $File01 @('コントロールパネル', 'ファイアウォール', $profileName, (Bool-ToJp $p.Enabled))
}

# SNMP
$snmpSvc = Get-Service -Name SNMP -ErrorAction SilentlyContinue
Write-CsvLine $File01 @('SNMP', 'SNMP', 'SNMPサービス', if ($snmpSvc) { (Bool-ToJp ($snmpSvc.StartType -ne 'Disabled')) } else { '無効' })

# 管理ユーザー（Administratorアカウント）
$adminUser = Get-LocalUser -Name Administrator -ErrorAction SilentlyContinue
if ($adminUser) {
    Write-CsvLine $File01 @('管理ユーザー', ' ', 'ユーザ名', $adminUser.Name)
    $opts = @()
    if ($adminUser.PasswordNeverExpires) { $opts += 'パスワードを無期限にする' }
    if (-not $adminUser.Enabled)         { $opts += 'アカウントを無効にする' }
    Write-CsvLine $File01 @('管理ユーザー', ' ', 'オプション', ($opts -join '/'))
}

Write-Host "完了: $File01"
#endregion

#region SERVER-02-役割・機能.csv
$File02 = Join-Path $OutputPath "${ServerName}-02-役割・機能.csv"
New-OutputFile $File02

Import-Module ServerManager -ErrorAction SilentlyContinue
$features = Get-WindowsFeature | Sort-Object Path

foreach ($f in $features) {
    $status = if ($f.InstallState -eq 'Installed') { '■' } else { '□' }
    $depth  = if ($f.PSObject.Properties['Depth']) { $f.Depth } else {
        # Pathから深さを計算 (例: "Web-Server\Web-Common-Http" → 深さ1)
        ($f.Path -split '\\').Count - 1
    }
    $commas = ',' * $depth
    Write-RawLine $File02 "$status$commas,$($f.DisplayName)"
}

Write-Host "完了: $File02"
#endregion

#region SERVER-03-アプリケーション.csv
$File03 = Join-Path $OutputPath "${ServerName}-03-アプリケーション.csv"
New-OutputFile $File03

Write-RawLine $File03 '"DisplayName","Publisher","DisplayVersion","InstallLocation"'

$regPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$apps = foreach ($path in $regPaths) {
    Get-ItemProperty $path -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, Publisher, DisplayVersion, InstallLocation
}
$apps = $apps | Sort-Object DisplayName -Unique

foreach ($app in $apps) {
    Write-CsvLine $File03 @(
        $app.DisplayName,
        ($app.Publisher        ?? ''),
        ($app.DisplayVersion   ?? ''),
        ($app.InstallLocation  ?? '')
    )
}

Write-Host "完了: $File03"
#endregion

#region SERVER-04-ファイアウォール.csv
$File04 = Join-Path $OutputPath "${ServerName}-04-ファイアウォール.csv"
New-OutputFile $File04

Write-RawLine $File04 '名前,グループ,プロファイル,有効,規則,操作,プログラム,ローカルIP,リモートIP,ローカルアドレス,リモートアドレス,プロトコル,ローカルポート,リモートポート'

function Convert-Profile {
    param($p)
    $items = $p.ToString() -split ',\s*'
    $mapped = $items | ForEach-Object {
        switch ($_.Trim()) {
            'Any'     { 'すべて' } 'Domain'  { 'ドメイン' }
            'Private' { 'プライベート' } 'Public' { 'パブリック' }
            default   { $_ }
        }
    }
    # 'すべて'が含まれる場合は'すべて'のみ返す
    if ($mapped -contains 'すべて') { return 'すべて' }
    return $mapped -join ', '
}

function Convert-AnyJp { param($v); if ($v -eq 'Any') { '任意' } else { $v } }
function Convert-Protocol {
    param($p)
    switch ($p) { 'Any' { '任意' } 'TCP' { 'TCP' } 'UDP' { 'UDP' }
        'ICMPv4' { 'ICMPv4' } 'ICMPv6' { 'ICMPv6' } default { $p } }
}

$rules = Get-NetFirewallRule | Sort-Object Direction, DisplayName

foreach ($rule in $rules) {
    $pf   = Get-NetFirewallPortFilter        -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
    $af   = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
    $addr = Get-NetFirewallAddressFilter     -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue

    $profile   = Convert-Profile $rule.Profile
    $enabled   = if ($rule.Enabled -eq 'True') { '有効' } else { '無効' }
    $direction = if ($rule.Direction -eq 'Inbound') { '受信' } else { '送信' }
    $action    = if ($rule.Action -eq 'Allow') { '許可' } else { 'ブロック' }
    $program   = if ($af -and $af.Program -and $af.Program -ne 'Any') { $af.Program } else { '任意' }
    $localIP   = Convert-AnyJp ($addr.LocalAddress  ?? 'Any')
    $remoteIP  = Convert-AnyJp ($addr.RemoteAddress ?? 'Any')
    $proto     = Convert-Protocol ($pf.Protocol ?? 'Any')
    $localPort = Convert-AnyJp (if ($pf.LocalPort)  { $pf.LocalPort  -join ' ' } else { 'Any' })
    $remotePort= Convert-AnyJp (if ($pf.RemotePort) { $pf.RemotePort -join ' ' } else { 'Any' })

    Write-CsvLine $File04 @(
        $rule.DisplayName, $rule.Group, $profile, $enabled, $direction, $action,
        $program, $localIP, $remoteIP, $localIP, $remoteIP, $proto, $localPort, $remotePort
    )
}

Write-Host "完了: $File04"
#endregion

#region SERVER-05-共有フォルダ.csv
$File05 = Join-Path $OutputPath "${ServerName}-05-共有フォルダ.csv"
New-OutputFile $File05

Write-RawLine $File05 '共有名,パス,説明,アカウント名,アクセス権,アクセス許可'

$shares = Get-SmbShare | Sort-Object Name
foreach ($share in $shares) {
    $accesses = Get-SmbShareAccess -Name $share.Name -ErrorAction SilentlyContinue
    if ($accesses) {
        foreach ($acc in $accesses) {
            $accessRight = switch ($acc.AccessRight) {
                'Full'   { 'フルコントロール' } 'Change' { '変更' }
                'Read'   { '読み取り' } default { $acc.AccessRight }
            }
            $accessType = if ($acc.AccessControlType -eq 'Allow') { '許可' } else { '拒否' }
            Write-CsvLine $File05 @($share.Name, $share.Path, $share.Description, $acc.AccountName, $accessType, $accessRight)
        }
    } else {
        Write-CsvLine $File05 @($share.Name, $share.Path, $share.Description, '', '', '')
    }
}

Write-Host "完了: $File05"
#endregion

#region SERVER-06-フォルダ.csv
$File06 = Join-Path $OutputPath "${ServerName}-06-フォルダ.csv"
New-OutputFile $File06

Write-RawLine $File06 'パス,名前,種類,アクセス許可,継承,適用先'

function Get-AppliesTo {
    param([System.Security.AccessControl.InheritanceFlags]$iFlags, [System.Security.AccessControl.PropagationFlags]$pFlags)
    $container = $iFlags -band [System.Security.AccessControl.InheritanceFlags]::ContainerInherit
    $object    = $iFlags -band [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $inherit   = $pFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly

    if ($container -and $object -and -not $inherit) { return 'このフォルダ、サブフォルダ、 ファイル' }
    if ($container -and $object -and $inherit)       { return 'サブフォルダ、 ファイル' }
    if ($container -and -not $object -and -not $inherit) { return 'このフォルダ、サブフォルダ' }
    if (-not $container -and $object -and -not $inherit) { return 'このフォルダ、ファイル' }
    if ($container -and -not $object -and $inherit)      { return 'サブフォルダ' }
    if (-not $container -and $object -and $inherit)      { return 'ファイル' }
    return 'このフォルダ、'
}

function Convert-Rights {
    param([System.Security.AccessControl.FileSystemRights]$r)
    $v = [int]$r
    if ($v -eq 2032127 -or $r.HasFlag([System.Security.AccessControl.FileSystemRights]::FullControl)) { return 'フル コントロール' }
    if ($r.HasFlag([System.Security.AccessControl.FileSystemRights]::Modify) -and -not $r.HasFlag([System.Security.AccessControl.FileSystemRights]::FullControl)) { return '変更' }
    $rs = $r.ToString()
    if ($rs -match 'ReadAndExecute' -and $rs -notmatch 'Write' -and $rs -notmatch 'Modify') { return '読み取りと実行' }
    if ($rs -eq 'Read') { return '読み取り' }
    if ($rs -eq 'Write') { return '書き込み' }
    return $rs
}

# 各固定ドライブの第1レベルフォルダを対象とする
$fixedDisks = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
$targetFolders = foreach ($disk in $fixedDisks) {
    $root = $disk.DeviceID + '\'
    Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue
}

foreach ($folder in $targetFolders) {
    $acl = Get-Acl -Path $folder.FullName -ErrorAction SilentlyContinue
    if (-not $acl) { continue }
    foreach ($ace in $acl.Access) {
        $rights      = Convert-Rights $ace.FileSystemRights
        $accessType  = if ($ace.AccessControlType -eq 'Allow') { '許可' } else { '拒否' }
        $isInherited = $ace.IsInherited.ToString()
        $appliesTo   = Get-AppliesTo $ace.InheritanceFlags $ace.PropagationFlags
        Write-CsvLine $File06 @($folder.FullName, $ace.IdentityReference.Value, $rights, $accessType, $isInherited, $appliesTo)
    }
}

Write-Host "完了: $File06"
#endregion

#region SERVER-07-ユーザ一覧.csv
$File07 = Join-Path $OutputPath "${ServerName}-07-ユーザ一覧.csv"
New-OutputFile $File07

Write-RawLine $File07 '名前,フルネーム,説明,オプション'

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $users = Get-ADUser -Filter * -Properties DisplayName, Description, PasswordNeverExpires, Enabled | Sort-Object SamAccountName
    foreach ($u in $users) {
        $opts = @()
        if ($u.PasswordNeverExpires) { $opts += 'パスワードを無期限にする' }
        if (-not $u.Enabled)         { $opts += 'アカウントを無効にする' }
        Write-CsvLine $File07 @($u.SamAccountName, ($u.DisplayName ?? ''), ($u.Description ?? ''), ($opts -join '/'))
    }
} catch {
    # ADモジュール非使用環境ではローカルユーザーを出力
    $users = Get-LocalUser | Sort-Object Name
    foreach ($u in $users) {
        $opts = @()
        if ($u.PasswordNeverExpires) { $opts += 'パスワードを無期限にする' }
        if (-not $u.Enabled)         { $opts += 'アカウントを無効にする' }
        Write-CsvLine $File07 @($u.Name, ($u.FullName ?? ''), ($u.Description ?? ''), ($opts -join '/'))
    }
}

Write-Host "完了: $File07"
#endregion

#region SERVER-08-グループ一覧.csv
$File08 = Join-Path $OutputPath "${ServerName}-08-グループ一覧.csv"
New-OutputFile $File08

Write-RawLine $File08 '名前,メンバー,説明'

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $groups = Get-ADGroup -Filter * -Properties Description | Sort-Object Name
    foreach ($g in $groups) {
        $members = Get-ADGroupMember -Identity $g -ErrorAction SilentlyContinue |
                   Select-Object -ExpandProperty SamAccountName
        $membersStr = if ($members) { $members -join ';' } else { '' }
        Write-CsvLine $File08 @($g.Name, $membersStr, ($g.Description ?? ''))
    }
} catch {
    $groups = Get-LocalGroup | Sort-Object Name
    foreach ($g in $groups) {
        $members = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue |
                   Select-Object -ExpandProperty Name
        $membersStr = if ($members) { $members -join ';' } else { '' }
        Write-CsvLine $File08 @($g.Name, $membersStr, ($g.Description ?? ''))
    }
}

Write-Host "完了: $File08"
#endregion

#region SERVER-09-サービス.csv
$File09 = Join-Path $OutputPath "${ServerName}-09-サービス.csv"
New-OutputFile $File09

Write-RawLine $File09 '"DisplayName","StartMode","StartName","Description"'

$services = Get-WmiObject Win32_Service | Sort-Object DisplayName
foreach ($svc in $services) {
    Write-CsvLine $File09 @(
        $svc.DisplayName,
        $svc.StartMode,
        ($svc.StartName ?? ''),
        ($svc.Description ?? '')
    )
}

Write-Host "完了: $File09"
#endregion

#region SERVER-10-プリンタ.csv
$File10 = Join-Path $OutputPath "${ServerName}-10-プリンタ.csv"
New-OutputFile $File10

Write-RawLine $File10 '名前,ドライバ名,共有名,ポート名,IP,ポート,プロトコル,LPRキュー名,SNMP,コミュニティ,SNMPデバイスインデックス'

$printers = Get-Printer -ErrorAction SilentlyContinue | Sort-Object Name
foreach ($p in $printers) {
    $portName = $p.PortName
    $ip = ''
    $portNum = ''
    $protocol = ''
    $lprQueue = ''
    $snmpEnabled = ''
    $community = ''
    $snmpIndex = ''

    $port = Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue
    if ($port) {
        $ip       = $port.PrinterHostAddress ?? ''
        $portNum  = $port.PortNumber         ?? ''
        $protocol = if ($port.Protocol -eq 1) { 'RAW' } elseif ($port.Protocol -eq 2) { 'LPR' } else { '' }
        $lprQueue = $port.LprQueueName       ?? ''
        $snmpEnabled = if ($port.SNMPEnabled) { '有効' } else { '' }
        $community   = $port.SNMPCommunity   ?? ''
        $snmpIndex   = $port.SNMPDevIndex    ?? ''
    }

    Write-CsvLine $File10 @(
        $p.Name, $p.DriverName, ($p.ShareName ?? ''), $portName,
        $ip, $portNum.ToString(), $protocol, $lprQueue,
        $snmpEnabled, $community, $snmpIndex.ToString()
    )
}

Write-Host "完了: $File10"
#endregion

Write-Host ""
Write-Host "全ファイルの出力が完了しました。出力先: $OutputPath"
