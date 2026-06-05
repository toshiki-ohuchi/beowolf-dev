#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows システム情報収集スクリプト（サーバー / PC クライアント共通）
.DESCRIPTION
    実行対象を起動直後に選択し、対象に応じた出力先へ CSV ファイルを生成します。
        1: サーバー       → C:\work\01.server\{HOSTNAME}-01〜10-*.csv
        2: 先生PC         → C:\work\02.teacher\{HOSTNAME}-01〜10-*.csv
        3: 生徒PC         → C:\work\03.student\{HOSTNAME}-01〜10-*.csv

    生成ファイル:
        {HOSTNAME}-01-設定.csv
        {HOSTNAME}-02-役割・機能.csv  ※PC環境では Get-WindowsFeature が失敗しても続行
        {HOSTNAME}-03-アプリケーション.csv
        {HOSTNAME}-04-ファイアウォール.csv
        {HOSTNAME}-05-共有フォルダ.csv
        {HOSTNAME}-06-フォルダ.csv
        {HOSTNAME}-07-ユーザ一覧.csv
        {HOSTNAME}-08-グループ一覧.csv
        {HOSTNAME}-09-サービス.csv
        {HOSTNAME}-10-プリンタ.csv
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

# -----------------------------------------------------------------------
# 実行対象の選択（起動直後）
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "実行対象を選択してください:" -ForegroundColor Cyan
Write-Host "  1: サーバー        (出力先: C:\work\01.server\)"
Write-Host "  2: 先生PC          (出力先: C:\work\02.teacher\)"
Write-Host "  3: 生徒PC          (出力先: C:\work\03.student\)"
Write-Host ""

do {
    $choice = Read-Host "番号を入力 (1, 2 または 3)"
} while ($choice -ne '1' -and $choice -ne '2' -and $choice -ne '3')

$IsServer = ($choice -eq '1')
$OutputPath = switch ($choice) {
    '1' { 'C:\work\01.server' }
    '2' { 'C:\work\02.teacher' }
    '3' { 'C:\work\03.student' }
}

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
# 共通ヘルパー関数
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
    param($v)
    if ($v) { '有効' } else { '無効' }
}

function Convert-Profile {
    param($p)
    $items = $p.ToString() -split ',\s*'
    $mapped = $items | ForEach-Object {
        switch ($_.Trim()) {
            'Any'     { 'すべて' }   'Domain'  { 'ドメイン' }
            'Private' { 'プライベート' } 'Public' { 'パブリック' }
            default   { $_ }
        }
    }
    if ($mapped -contains 'すべて') { return 'すべて' }
    return $mapped -join ', '
}

function Convert-AnyJp { param($v); if ($v -eq 'Any') { '任意' } else { $v } }

function Convert-Protocol {
    param($p)
    switch ($p) {
        'Any'    { '任意' } 'TCP'    { 'TCP' }   'UDP'    { 'UDP' }
        'ICMPv4' { 'ICMPv4' } 'ICMPv6' { 'ICMPv6' } default { $p }
    }
}

function Get-AppliesTo {
    param(
        [System.Security.AccessControl.InheritanceFlags]$iFlags,
        [System.Security.AccessControl.PropagationFlags]$pFlags
    )
    $ci     = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit
    $oi     = [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $ioOnly = [System.Security.AccessControl.PropagationFlags]::InheritOnly
    $hasCI  = ($iFlags -band $ci) -ne 0
    $hasOI  = ($iFlags -band $oi) -ne 0
    $isIO   = ($pFlags -band $ioOnly) -ne 0

    if ($hasCI -and $hasOI -and -not $isIO) { return 'このフォルダ、サブフォルダ、 ファイル' }
    if ($hasCI -and $hasOI -and $isIO)      { return 'サブフォルダ、 ファイル' }
    if ($hasCI -and -not $hasOI -and -not $isIO) { return 'このフォルダ、サブフォルダ' }
    if (-not $hasCI -and $hasOI -and -not $isIO) { return 'このフォルダ、ファイル' }
    if ($hasCI -and -not $hasOI -and $isIO)      { return 'サブフォルダ' }
    if (-not $hasCI -and $hasOI -and $isIO)      { return 'ファイル' }
    return 'このフォルダ、'
}

function Convert-Rights {
    param([System.Security.AccessControl.FileSystemRights]$r)
    $v = [int]$r
    if ($v -eq 2032127 -or $r.HasFlag([System.Security.AccessControl.FileSystemRights]::FullControl)) { return 'フル コントロール' }
    if ($r.HasFlag([System.Security.AccessControl.FileSystemRights]::Modify) -and
       -not $r.HasFlag([System.Security.AccessControl.FileSystemRights]::FullControl)) { return '変更' }
    $rs = $r.ToString()
    if ($rs -match 'ReadAndExecute' -and $rs -notmatch 'Write' -and $rs -notmatch 'Modify') { return '読み取りと実行' }
    if ($rs -eq 'Read')  { return '読み取り' }
    if ($rs -eq 'Write') { return '書き込み' }
    return $rs
}

# -----------------------------------------------------------------------
# -01-設定.csv
# -----------------------------------------------------------------------
Write-Host "[-01-設定.csv] 収集中..."
$File01 = Join-Path $OutputPath "$HostName-01-設定.csv"
New-OutputFile $File01

$cs    = Get-WmiObject Win32_ComputerSystem
$bios  = Get-WmiObject Win32_BIOS
$os    = Get-WmiObject Win32_OperatingSystem
$cpu   = Get-WmiObject Win32_Processor | Select-Object -First 1
$memGB = [math]::Round($cs.TotalPhysicalMemory / 1GB)
$hwp   = Get-WmiObject Win32_ComputerSystemProduct -ErrorAction SilentlyContinue

# システム情報
$role = switch ($cs.DomainRole) {
    4 { 'ドメインコントローラー' } 5 { 'ドメインコントローラー' }
    2 { 'ドメインメンバーサーバー' } 3 { 'ドメインメンバーサーバー' }
    default { if ($cs.PartOfDomain) { 'ドメインメンバー' } else { 'ワークグループ' } }
}
Write-CsvLine $File01 @('システム情報', 'システム', 'コンピュータ名',           $HostName)
Write-CsvLine $File01 @('システム情報', 'システム', 'フルコンピュータ名',       "$HostName.$($cs.Domain)")
Write-CsvLine $File01 @('システム情報', 'システム', 'ワークグループ/ドメイン名', $cs.Domain)
Write-CsvLine $File01 @('システム情報', 'システム', '役割',                     $role)

# ハードウェア情報
Write-CsvLine $File01 @('機器情報', 'ハードウェア', '機種',         $cs.Model)
Write-CsvLine $File01 @('機器情報', 'ハードウェア', 'CPU数',        $cs.NumberOfProcessors.ToString())
Write-CsvLine $File01 @('機器情報', 'ハードウェア', '型番',         if ($hwp) { $hwp.Name } else { '' })
Write-CsvLine $File01 @('機器情報', 'ハードウェア', 'シリアル番号', if ($hwp) { $hwp.IdentifyingNumber.Trim() } else { $bios.SerialNumber.Trim() })
Write-CsvLine $File01 @('機器情報', 'ハードウェア', 'BIOSバージョン', $bios.SMBIOSBIOSVersion)
Write-CsvLine $File01 @('機器情報', 'ハードウェア', 'CPU',          $cpu.Name.Trim())
Write-CsvLine $File01 @('機器情報', 'ハードウェア', 'メモリ容量',   "${memGB}GB")

# OS情報
Write-CsvLine $File01 @('システム情報', 'OS', 'OS',           $os.Caption)
Write-CsvLine $File01 @('システム情報', 'OS', 'アーキテクチャ', $os.OSArchitecture)
Write-CsvLine $File01 @('システム情報', 'OS', 'バージョン',    $os.Version)
Write-CsvLine $File01 @('システム情報', 'OS', 'ビルド',        $os.BuildNumber)

# リモートデスクトップ
$rdpEnabled = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections -eq 0
$nlaEnabled = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -ErrorAction SilentlyContinue).UserAuthentication -eq 1
Write-CsvLine $File01 @('システム情報', 'リモート', 'リモートデスクトップ',  (Bool-ToJp $rdpEnabled))
Write-CsvLine $File01 @('システム情報', 'リモート', 'ネットワークレベル認証', (Bool-ToJp $nlaEnabled))

# ディスク構成
$disks = Get-Disk | Sort-Object Number
foreach ($disk in $disks) {
    $diskLabel = "ディスク $($disk.Number)"
    $busType   = switch ($disk.BusType) {
        'USB'  { 'USB' } 'RAID' { 'RAID' } 'SAS'  { 'SAS' }
        'SATA' { 'SATA' } 'NVMe' { 'NVMe' } 'SCSI' { 'SCSI' }
        default { $disk.BusType }
    }
    Write-CsvLine $File01 @('ディスク構成', $diskLabel, 'ディスク名',    $disk.FriendlyName)
    Write-CsvLine $File01 @('ディスク構成', $diskLabel, 'ディスク種別',  $disk.PartitionStyle)
    Write-CsvLine $File01 @('ディスク構成', $diskLabel, 'ディスクサイズ', "$([math]::Round($disk.Size / 1GB, 2)) GB")
    Write-CsvLine $File01 @('ディスク構成', $diskLabel, '接続種別',      $busType)

    $pIdx = 1
    foreach ($part in (Get-Partition -DiskNumber $disk.Number | Sort-Object PartitionNumber)) {
        $vol    = Get-Volume -Partition $part -ErrorAction SilentlyContinue
        $pLabel = "パーティション $pIdx"
        Write-CsvLine $File01 @("ディスク $($disk.Number)", $pLabel, 'ドライブタイプ',   $part.Type)
        Write-CsvLine $File01 @("ディスク $($disk.Number)", $pLabel, 'ドライブ文字',     if ($part.DriveLetter) { $part.DriveLetter } else { ' ' })
        Write-CsvLine $File01 @("ディスク $($disk.Number)", $pLabel, '容量',             "$([math]::Round($part.Size / 1GB, 2)) GB")
        Write-CsvLine $File01 @("ディスク $($disk.Number)", $pLabel, 'ファイルシステム', if ($vol) { $vol.FileSystem } else { '' })
        Write-CsvLine $File01 @("ディスク $($disk.Number)", $pLabel, 'ボリューム名',     if ($vol) { $vol.FileSystemLabel } else { '' })
        $pIdx++
    }
}

# CD/DVDドライブ
foreach ($cd in (Get-WmiObject Win32_CDROMDrive -ErrorAction SilentlyContinue)) {
    Write-CsvLine $File01 @('ディスク構成', 'CD/DVDドライブ', 'ドライブ文字', $cd.Drive -replace ':', '')
}

# ネットワークアダプタ
$aNdx = 1
foreach ($a in (Get-NetAdapter | Sort-Object InterfaceIndex)) {
    $label  = "ネットワーク アダプタ$aNdx"
    $status = if ($a.Status -eq 'Up') { '有効' } else { '無効' }
    Write-CsvLine $File01 @('ネットワーク', $label, '名前',       $a.Name)
    Write-CsvLine $File01 @('ネットワーク', $label, 'ステータス', $status)
    Write-CsvLine $File01 @('ネットワーク', $label, '速度',       ($a.LinkSpeed -replace '[^\d]', ''))
    Write-CsvLine $File01 @('ネットワーク', $label, 'デバイス名', $a.InterfaceDescription)
    Write-CsvLine $File01 @('ネットワーク', $label, 'MACアドレス', $a.MacAddress)

    $ipCfg = Get-NetIPConfiguration -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
    if ($ipCfg -and $ipCfg.IPv4Address) {
        $dhcp   = Bool-ToJp (($a | Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp -eq 'Enabled')
        $prefix = $ipCfg.IPv4Address.PrefixLength
        $subnet = [System.Net.IPAddress]::Parse(([System.Convert]::ToInt64('1' * $prefix + '0' * (32 - $prefix), 2)).ToString()).ToString()
        $gw     = if ($ipCfg.IPv4DefaultGateway) { $ipCfg.IPv4DefaultGateway.NextHop } else { '' }
        $dns    = $ipCfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | Select-Object -ExpandProperty ServerAddresses
        Write-CsvLine $File01 @('ネットワーク', $label, 'DHCP',               $dhcp)
        Write-CsvLine $File01 @('ネットワーク', $label, 'IPv4アドレス',       $ipCfg.IPv4Address.IPAddress)
        Write-CsvLine $File01 @('ネットワーク', $label, 'サブネットマスク',   $subnet)
        Write-CsvLine $File01 @('ネットワーク', $label, 'デフォルトゲートウェイ', $gw)
        Write-CsvLine $File01 @('ネットワーク', $label, 'DNS 1', if ($dns -and $dns.Count -ge 1) { $dns[0] } else { '' })
        Write-CsvLine $File01 @('ネットワーク', $label, 'DNS 2', if ($dns -and $dns.Count -ge 2) { $dns[1] } else { '' })
    }
    foreach ($b in (Get-NetAdapterBinding -Name $a.Name -ErrorAction SilentlyContinue)) {
        Write-CsvLine $File01 @('ネットワーク', $label, $b.DisplayName, (if ($b.Enabled) { '有効' } else { '無効' }))
    }
    $aNdx++
}

# NICチーミング（サーバーのみ存在する場合が多いが、PC でも失敗なく実行）
$tNdx = 1
foreach ($t in (Get-NetLbfoTeam -ErrorAction SilentlyContinue)) {
    $label = "ネットワーク チーミング$tNdx"
    Write-CsvLine $File01 @('ネットワーク', $label, 'チーム名',      $t.Name)
    Write-CsvLine $File01 @('ネットワーク', $label, 'メンバー',      ($t.Members -join ','))
    Write-CsvLine $File01 @('ネットワーク', $label, 'チーミングモード', $t.TeamingMode.ToString())
    Write-CsvLine $File01 @('ネットワーク', $label, '負荷分散モード', $t.LoadBalancingAlgorithm.ToString())
    $tNdx++
}

# ネットワークオフロード設定
$offload = Get-NetOffloadGlobalSetting -ErrorAction SilentlyContinue
if ($offload) {
    Write-CsvLine $File01 @('ネットワーク', 'ネットワーク オフロード設定', 'ReceiveSideScaling',       $offload.ReceiveSideScaling.ToString())
    Write-CsvLine $File01 @('ネットワーク', 'ネットワーク オフロード設定', 'ReceiveSegmentCoalescing', $offload.ReceiveSegmentCoalescing.ToString())
    Write-CsvLine $File01 @('ネットワーク', 'ネットワーク オフロード設定', 'Chimney',                  $offload.Chimney.ToString())
    Write-CsvLine $File01 @('ネットワーク', 'ネットワーク オフロード設定', 'TaskOffload',              $offload.TaskOffload.ToString())
}

# Windows Update設定
$wuKey    = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
$auOption = switch ($wuKey.AUOptions) {
    2 { '更新プログラムを確認しない' } 3 { 'ダウンロードのみ行う' }
    4 { '自動的にダウンロードしてインストールする' } 5 { '更新をインストールする前に通知する' }
    default { '更新プログラムを確認しない' }
}
Write-CsvLine $File01 @('コントロールパネル', 'Windows Update', '重要な更新プログラム',   $auOption)
Write-CsvLine $File01 @('コントロールパネル', 'Windows Update', '推奨する更新プログラム', (if ($wuKey.IncludeRecommendedUpdates -eq 1) { '有効' } else { '無効' }))

# 時刻設定
$ntpServer = '-'
$w32status = & w32tm /query /status 2>$null
if ($w32status) {
    $srcLine = $w32status | Where-Object { $_ -match '時刻ソース|Source' }
    if ($srcLine) { $ntpServer = ($srcLine -split ':', 2)[1].Trim() }
}
Write-CsvLine $File01 @('コントロールパネル', '時刻設定', 'NTPタイプ', if ($IsServer) { 'ドメインの階層と同期' } else { 'クライアント' })
Write-CsvLine $File01 @('コントロールパネル', '時刻設定', 'NTPサーバ', $ntpServer)

# ファイアウォールプロファイル
foreach ($p in (Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
    $profileName = switch ($p.Name) {
        'Domain'  { 'ドメイン プロファイル' }
        'Private' { 'プライベート プロファイル' }
        'Public'  { 'パブリック プロファイル' }
    }
    Write-CsvLine $File01 @('コントロールパネル', 'ファイアウォール', $profileName, (Bool-ToJp $p.Enabled))
}

# SNMP
$snmpSvc = Get-Service -Name SNMP -ErrorAction SilentlyContinue
Write-CsvLine $File01 @('SNMP', 'SNMP', 'SNMPサービス', if ($snmpSvc) { Bool-ToJp ($snmpSvc.StartType -ne 'Disabled') } else { '無効' })

# 管理ユーザー（Administratorアカウント）
$adminUser = Get-LocalUser -Name Administrator -ErrorAction SilentlyContinue
if ($adminUser) {
    $opts = @()
    if ($adminUser.PasswordNeverExpires) { $opts += 'パスワードを無期限にする' }
    if (-not $adminUser.Enabled)         { $opts += 'アカウントを無効にする' }
    Write-CsvLine $File01 @('管理ユーザー', ' ', 'ユーザ名', $adminUser.Name)
    Write-CsvLine $File01 @('管理ユーザー', ' ', 'オプション', ($opts -join '/'))
}

Write-Host "  -> $File01"

# -----------------------------------------------------------------------
# -02-役割・機能.csv（PC環境では Get-WindowsFeature が失敗しても続行）
# -----------------------------------------------------------------------
Write-Host "[-02-役割・機能.csv] 収集中..."
$File02 = Join-Path $OutputPath "$HostName-02-役割・機能.csv"
New-OutputFile $File02

try {
    Import-Module ServerManager -ErrorAction Stop
    $features = Get-WindowsFeature | Sort-Object Path
    foreach ($f in $features) {
        $status = if ($f.InstallState -eq 'Installed') { '■' } else { '□' }
        $depth  = if ($f.PSObject.Properties['Depth']) {
            $f.Depth
        } else {
            ($f.Path -split '\\').Count - 1
        }
        $commas = ',' * $depth
        Write-RawLine $File02 "$status$commas,$($f.DisplayName)"
    }
} catch {
    Write-RawLine $File02 "# Get-WindowsFeature は実行できませんでした ($($_.Exception.Message))"
}

Write-Host "  -> $File02"

# -----------------------------------------------------------------------
# -03-アプリケーション.csv
# -----------------------------------------------------------------------
Write-Host "[-03-アプリケーション.csv] 収集中..."
$File03 = Join-Path $OutputPath "$HostName-03-アプリケーション.csv"
New-OutputFile $File03
Write-RawLine $File03 '"DisplayName","Publisher","DisplayVersion","InstallLocation"'

$regPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$apps = ($regPaths | ForEach-Object {
    Get-ItemProperty $_ -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
} | Select-Object DisplayName, Publisher, DisplayVersion, InstallLocation | Sort-Object DisplayName -Unique)

foreach ($app in $apps) {
    Write-CsvLine $File03 @(
        ($app.DisplayName    ?? ''),
        ($app.Publisher      ?? ''),
        ($app.DisplayVersion ?? ''),
        ($app.InstallLocation ?? '')
    )
}
Write-Host "  -> $File03"

# -----------------------------------------------------------------------
# -04-ファイアウォール.csv
# -----------------------------------------------------------------------
Write-Host "[-04-ファイアウォール.csv] 収集中..."
$File04 = Join-Path $OutputPath "$HostName-04-ファイアウォール.csv"
New-OutputFile $File04
Write-RawLine $File04 '名前,グループ,プロファイル,有効,規則,操作,プログラム,ローカルIP,リモートIP,ローカルアドレス,リモートアドレス,プロトコル,ローカルポート,リモートポート'

foreach ($rule in (Get-NetFirewallRule | Sort-Object Direction, DisplayName)) {
    $pf   = Get-NetFirewallPortFilter        -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
    $af   = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
    $addr = Get-NetFirewallAddressFilter     -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue

    $profile    = Convert-Profile $rule.Profile
    $enabled    = if ($rule.Enabled -eq 'True') { '有効' } else { '無効' }
    $direction  = if ($rule.Direction -eq 'Inbound') { '受信' } else { '送信' }
    $action     = if ($rule.Action -eq 'Allow') { '許可' } else { 'ブロック' }
    $program    = if ($af -and $af.Program -and $af.Program -ne 'Any') { $af.Program } else { '任意' }
    $localIP    = Convert-AnyJp ($addr.LocalAddress  ?? 'Any')
    $remoteIP   = Convert-AnyJp ($addr.RemoteAddress ?? 'Any')
    $proto      = Convert-Protocol ($pf.Protocol ?? 'Any')
    $localPort  = Convert-AnyJp (if ($pf.LocalPort)  { $pf.LocalPort  -join ' ' } else { 'Any' })
    $remotePort = Convert-AnyJp (if ($pf.RemotePort) { $pf.RemotePort -join ' ' } else { 'Any' })

    Write-CsvLine $File04 @(
        $rule.DisplayName, $rule.Group, $profile, $enabled, $direction, $action,
        $program, $localIP, $remoteIP, $localIP, $remoteIP, $proto, $localPort, $remotePort
    )
}
Write-Host "  -> $File04"

# -----------------------------------------------------------------------
# -05-共有フォルダ.csv
# -----------------------------------------------------------------------
Write-Host "[-05-共有フォルダ.csv] 収集中..."
$File05 = Join-Path $OutputPath "$HostName-05-共有フォルダ.csv"
New-OutputFile $File05
Write-RawLine $File05 '共有名,パス,説明,アカウント名,アクセス権,アクセス許可'

foreach ($share in (Get-SmbShare | Sort-Object Name)) {
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
Write-Host "  -> $File05"

# -----------------------------------------------------------------------
# -06-フォルダ.csv
# -----------------------------------------------------------------------
Write-Host "[-06-フォルダ.csv] 収集中..."
$File06 = Join-Path $OutputPath "$HostName-06-フォルダ.csv"
New-OutputFile $File06
Write-RawLine $File06 'パス,名前,種類,アクセス許可,継承,適用先'

$fixedDisks = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
foreach ($disk in $fixedDisks) {
    foreach ($folder in (Get-ChildItem -Path "$($disk.DeviceID)\" -Directory -ErrorAction SilentlyContinue)) {
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
}
Write-Host "  -> $File06"

# -----------------------------------------------------------------------
# -07-ユーザ一覧.csv
# サーバー: ADユーザーを優先、失敗時はローカルユーザー（フォールバック）
# PC:       ローカルユーザーのみ（"ユーザーはパスワードを変更できない" オプションを含む）
# -----------------------------------------------------------------------
Write-Host "[-07-ユーザ一覧.csv] 収集中..."
$File07 = Join-Path $OutputPath "$HostName-07-ユーザ一覧.csv"
New-OutputFile $File07
Write-RawLine $File07 '名前,フルネーム,説明,オプション'

if ($IsServer) {
    # サーバー: ADユーザー優先
    $adLoaded = $false
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $adLoaded = $true
    } catch {}

    if ($adLoaded) {
        $users = Get-ADUser -Filter * -Properties DisplayName, Description, PasswordNeverExpires, Enabled | Sort-Object SamAccountName
        foreach ($u in $users) {
            $opts = @()
            if ($u.PasswordNeverExpires) { $opts += 'パスワードを無期限にする' }
            if (-not $u.Enabled)         { $opts += 'アカウントを無効にする' }
            Write-CsvLine $File07 @($u.SamAccountName, ($u.DisplayName ?? ''), ($u.Description ?? ''), ($opts -join '/'))
        }
    } else {
        # ADモジュール非使用環境ではローカルユーザーを出力
        foreach ($u in (Get-LocalUser | Sort-Object Name)) {
            $opts = @()
            if ($u.PasswordNeverExpires) { $opts += 'パスワードを無期限にする' }
            if (-not $u.Enabled)         { $opts += 'アカウントを無効にする' }
            Write-CsvLine $File07 @($u.Name, ($u.FullName ?? ''), ($u.Description ?? ''), ($opts -join '/'))
        }
    }
} else {
    # PC: ローカルユーザーのみ（"ユーザーはパスワードを変更できない" を含む）
    foreach ($u in (Get-LocalUser | Sort-Object Name)) {
        $opts = @()
        if ($u.PasswordNeverExpires)       { $opts += 'パスワードを無期限にする' }
        if (-not $u.UserMayChangePassword) { $opts += 'ユーザーはパスワードを変更できない' }
        if (-not $u.Enabled)               { $opts += 'アカウントを無効にする' }
        Write-CsvLine $File07 @($u.Name, ($u.FullName ?? ''), ($u.Description ?? ''), ($opts -join '/'))
    }
}
Write-Host "  -> $File07"

# -----------------------------------------------------------------------
# -08-グループ一覧.csv
# サーバー: ADグループを優先、失敗時はローカルグループ（フォールバック）
# PC:       ローカルグループのみ
# -----------------------------------------------------------------------
Write-Host "[-08-グループ一覧.csv] 収集中..."
$File08 = Join-Path $OutputPath "$HostName-08-グループ一覧.csv"
New-OutputFile $File08
Write-RawLine $File08 '名前,メンバー,説明'

if ($IsServer) {
    $adLoaded = $false
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $adLoaded = $true
    } catch {}

    if ($adLoaded) {
        foreach ($g in (Get-ADGroup -Filter * -Properties Description | Sort-Object Name)) {
            $members    = Get-ADGroupMember -Identity $g -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName
            $membersStr = if ($members) { $members -join ';' } else { '' }
            Write-CsvLine $File08 @($g.Name, $membersStr, ($g.Description ?? ''))
        }
    } else {
        foreach ($g in (Get-LocalGroup | Sort-Object Name)) {
            $members    = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            $membersStr = if ($members) { $members -join ';' } else { '' }
            Write-CsvLine $File08 @($g.Name, $membersStr, ($g.Description ?? ''))
        }
    }
} else {
    # PC: ローカルグループのみ
    foreach ($g in (Get-LocalGroup | Sort-Object Name)) {
        $members    = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        $membersStr = if ($members) { $members -join ';' } else { '' }
        Write-CsvLine $File08 @($g.Name, $membersStr, ($g.Description ?? ''))
    }
}
Write-Host "  -> $File08"

# -----------------------------------------------------------------------
# -09-サービス.csv
# -----------------------------------------------------------------------
Write-Host "[-09-サービス.csv] 収集中..."
$File09 = Join-Path $OutputPath "$HostName-09-サービス.csv"
New-OutputFile $File09
Write-RawLine $File09 '"DisplayName","StartMode","StartName","Description"'

foreach ($svc in (Get-WmiObject Win32_Service | Sort-Object DisplayName)) {
    Write-CsvLine $File09 @(
        $svc.DisplayName,
        $svc.StartMode,
        ($svc.StartName    ?? ''),
        ($svc.Description  ?? '')
    )
}
Write-Host "  -> $File09"

# -----------------------------------------------------------------------
# -10-プリンタ.csv
# -----------------------------------------------------------------------
Write-Host "[-10-プリンタ.csv] 収集中..."
$File10 = Join-Path $OutputPath "$HostName-10-プリンタ.csv"
New-OutputFile $File10
Write-RawLine $File10 '名前,ドライバ名,共有名,ポート名,IP,ポート,プロトコル,LPRキュー名,SNMP,コミュニティ,SNMPデバイスインデックス'

foreach ($pr in (Get-Printer -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $port       = Get-PrinterPort -Name $pr.PortName -ErrorAction SilentlyContinue
    $ip         = $port.PrinterHostAddress ?? ''
    $portNum    = if ($port.PortNumber)    { $port.PortNumber.ToString() }    else { '' }
    $protocol   = if ($port.Protocol -eq 1) { 'RAW' } elseif ($port.Protocol -eq 2) { 'LPR' } else { '' }
    $lprQueue   = $port.LprQueueName     ?? ''
    $snmpEn     = if ($port -and $port.PSObject.Properties['SNMPEnabled']) { Bool-ToJp $port.SNMPEnabled } else { '' }
    $community  = $port.SNMPCommunity    ?? ''
    $snmpIndex  = if ($port.SNMPDevIndex) { $port.SNMPDevIndex.ToString() } else { '' }

    Write-CsvLine $File10 @(
        $pr.Name, $pr.DriverName, ($pr.ShareName ?? ''), $pr.PortName,
        $ip, $portNum, $protocol, $lprQueue, $snmpEn, $community, $snmpIndex
    )
}
Write-Host "  -> $File10"

# -----------------------------------------------------------------------
# 完了
# -----------------------------------------------------------------------
Write-Host ""
Write-Host "======================================" -ForegroundColor Green
Write-Host "情報収集が完了しました。" -ForegroundColor Green
Write-Host "出力先: $OutputPath" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
