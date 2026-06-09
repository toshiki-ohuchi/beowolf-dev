#Requires -RunAsAdministrator
<#
.SYNOPSIS
    ドメインコントローラーでActive Directory情報を収集します。
.DESCRIPTION
    出力ファイル:
        C:\work\01.server\CALL-01-設定.csv
        C:\work\01.server\CALL-02-OU.csv
        C:\work\01.server\CALL-03-Group.csv
    実行条件: ActiveDirectory / GroupPolicy PowerShellモジュールが必要です。
    実行方法: DCで管理者権限のPowerShellで実行してください。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module ActiveDirectory -ErrorAction Stop
Import-Module GroupPolicy     -ErrorAction SilentlyContinue

$OutputPath = "C:\work\01.server"
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$utf8bom = New-Object System.Text.UTF8Encoding $true

function Write-CsvRow {
    param([string]$Path, [string[]]$Values)
    $escaped = $Values | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }
    [System.IO.File]::AppendAllText($Path, ($escaped -join ',') + "`r`n", $utf8bom)
}

#region CALL-01-設定.csv
$File01 = Join-Path $OutputPath "CALL-01-設定.csv"
[System.IO.File]::WriteAllText($File01, '', $utf8bom)

$domain  = Get-ADDomain
$forest  = Get-ADForest
$pwdPolicy = Get-ADDefaultDomainPasswordPolicy

# ドメイン基本情報
Write-CsvRow $File01 @('Active Directory', 'ドメイン', 'ドメイン名', $domain.DNSRoot)
Write-CsvRow $File01 @('Active Directory', 'ドメイン', 'NETBIOS名', $domain.NetBIOSName)
Write-CsvRow $File01 @('Active Directory', 'ドメイン', 'グローバルカタログ', ($domain.GlobalCatalogs -join '; '))

# FSMO
Write-CsvRow $File01 @('Active Directory', 'FSMO', 'スキーママスタ',            $forest.SchemaMaster)
Write-CsvRow $File01 @('Active Directory', 'FSMO', 'ドメイン名前付けマスタ',   $forest.DomainNamingMaster)
Write-CsvRow $File01 @('Active Directory', 'FSMO', 'RIDマスタ',                $domain.RIDMaster)
Write-CsvRow $File01 @('Active Directory', 'FSMO', 'PDCエミュレータ',          $domain.PDCEmulator)
Write-CsvRow $File01 @('Active Directory', 'FSMO', 'インフラストラクチャマスタ', $domain.InfrastructureMaster)

# 機能レベル
Write-CsvRow $File01 @('Active Directory', '機能レベル', 'フォレストモード', $forest.ForestMode.ToString())
Write-CsvRow $File01 @('Active Directory', '機能レベル', 'ドメインモード',   $domain.DomainMode.ToString())

# パスワードポリシー
$maxAge = if ($pwdPolicy.MaxPasswordAge.TotalDays -eq 0) { '00:00:00' } else { $pwdPolicy.MaxPasswordAge.ToString() }
Write-CsvRow $File01 @('Active Directory', 'デフォルトパスワードポリシー', 'パスワードの長さ',                      $pwdPolicy.MinPasswordLength.ToString())
Write-CsvRow $File01 @('Active Directory', 'デフォルトパスワードポリシー', 'パスワードの変更禁止期間',              $pwdPolicy.MinPasswordAge.Days.ToString())
Write-CsvRow $File01 @('Active Directory', 'デフォルトパスワードポリシー', 'パスワードの有効期間',                  $maxAge)
Write-CsvRow $File01 @('Active Directory', 'デフォルトパスワードポリシー', 'パスワードの履歴を記録する',            $pwdPolicy.PasswordHistoryCount.ToString())
Write-CsvRow $File01 @('Active Directory', 'デフォルトパスワードポリシー', '暗号化をもとに戻せる状態',              (if ($pwdPolicy.ReversibleEncryptionEnabled) { '有効' } else { '無効' }))
Write-CsvRow $File01 @('Active Directory', 'デフォルトパスワードポリシー', '複雑さの要件を満たす必要があるパスワード', (if ($pwdPolicy.ComplexityEnabled) { '有効' } else { '無効' }))

# ドメインコントローラー一覧
$dcList = Get-ADDomainController -Filter * | Sort-Object Name
$i = 0
foreach ($dc in $dcList) {
    $prefix = "ドメインコントローラ$i"
    Write-CsvRow $File01 @('Active Directory', $prefix, 'ホスト名',        $dc.Name)
    Write-CsvRow $File01 @('Active Directory', $prefix, 'IPv4アドレス',    $dc.IPv4Address)
    Write-CsvRow $File01 @('Active Directory', $prefix, 'グローバルカタログ', (if ($dc.IsGlobalCatalog) { '有効' } else { '無効' }))
    Write-CsvRow $File01 @('Active Directory', $prefix, '読み取り専用',    (if ($dc.IsReadOnly) { '有効' } else { '無効' }))
    Write-CsvRow $File01 @('Active Directory', $prefix, 'OS',              $dc.OperatingSystem)
    Write-CsvRow $File01 @('Active Directory', $prefix, 'サイト',          $dc.Site)
    $i++
}

Write-Host "完了: $File01"
#endregion

#region CALL-02-OU.csv
$File02 = Join-Path $OutputPath "CALL-02-OU.csv"
[System.IO.File]::WriteAllText($File02, '', $utf8bom)

$domainDN = $domain.DistinguishedName
$ous = Get-ADOrganizationalUnit -Filter * | Sort-Object DistinguishedName

foreach ($ou in $ous) {
    $ouName = $ou.Name
    try {
        $inheritance = Get-GPInheritance -Target $ou.DistinguishedName -ErrorAction SilentlyContinue
        if ($inheritance -and $inheritance.GpoLinks) {
            foreach ($link in $inheritance.GpoLinks) {
                Write-CsvRow $File02 @($domain.DNSRoot, $ouName, $link.DisplayName)
            }
        }
    }
    catch {
        Write-CsvRow $File02 @($domain.DNSRoot, $ouName, '')
    }
}

Write-Host "完了: $File02"
#endregion

#region CALL-03-Group.csv
$File03 = Join-Path $OutputPath "CALL-03-Group.csv"
[System.IO.File]::WriteAllText($File03, '', $utf8bom)

$groups = Get-ADGroup -Filter * -Properties Description | Sort-Object DistinguishedName

foreach ($g in $groups) {
    # コンテナ名（OU名またはCN名）を取得
    $dn = $g.DistinguishedName
    $parentDN = $dn -replace '^CN=[^,]+,', ''
    $container = ($parentDN -split ',')[0] -replace '^(OU|CN)=', ''

    $groupType = switch ($g.GroupScope) {
        'DomainLocal' { 'ドメインローカル' }
        'Global'      { 'グローバル' }
        'Universal'   { 'ユニバーサル' }
        default       { $g.GroupScope.ToString() }
    }
    $groupCategory = switch ($g.GroupCategory) {
        'Security'     { 'セキュリティ' }
        'Distribution' { 'ディストリビューション' }
        default        { $g.GroupCategory.ToString() }
    }
    $desc = if ($g.Description) { $g.Description } else { '' }

    Write-CsvRow $File03 @($domain.DNSRoot, $container, $g.Name, $groupType, $groupCategory, $desc)
}

Write-Host "完了: $File03"
#endregion
