<#
.SYNOPSIS
    現在の Azure サブスクリプションのリソース一覧を取得し、CSV/JSON にエクスポートします。

.DESCRIPTION
    Azure PowerShell (Az モジュール) を使用してサブスクリプション内の全リソースを取得し、
    output\resources.csv および output\resources.json として出力します。
#>

[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'output')
)

$ErrorActionPreference = 'Stop'

# 出力フォルダ準備
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

# サインイン確認
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if ($null -eq $ctx -or $null -eq $ctx.Account) {
    throw 'Azure にサインインしていません。Connect-AzAccount を実行してください。'
}

Write-Host "Subscription : $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
Write-Host "Tenant       : $($ctx.Tenant.Id)"
Write-Host "Account      : $($ctx.Account.Id)"

# リソース一覧取得
Write-Host "`nリソースを取得中..." -ForegroundColor Cyan
$resources = Get-AzResource

Write-Host ("取得件数: {0}" -f $resources.Count) -ForegroundColor Green

# 整形 (CSV 用にフラット化)
$flat = $resources | ForEach-Object {
    [pscustomobject]@{
        Name              = $_.Name
        ResourceGroupName = $_.ResourceGroupName
        ResourceType      = $_.ResourceType
        Location          = $_.Location
        Kind              = $_.Kind
        SkuName           = $_.Sku.Name
        SkuTier           = $_.Sku.Tier
        Tags              = if ($_.Tags) { ($_.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';' } else { '' }
        SubscriptionId    = $_.SubscriptionId
        ResourceId        = $_.ResourceId
    }
}

# CSV エクスポート (UTF-8 BOM 付きで Excel でも文字化けしないように)
$csvPath = Join-Path $OutputDir 'resources.csv'
$flat | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "CSV  : $csvPath" -ForegroundColor Green

# JSON エクスポート (メタデータ + リソース)
$jsonPath = Join-Path $OutputDir 'resources.json'
$payload = [pscustomobject]@{
    Metadata = [pscustomobject]@{
        Subscription   = $ctx.Subscription.Name
        SubscriptionId = $ctx.Subscription.Id
        TenantId       = $ctx.Tenant.Id
        Account        = $ctx.Account.Id
        ExportedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
        ResourceCount  = $resources.Count
    }
    Resources = $flat
}
$payload | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8
Write-Host "JSON : $jsonPath" -ForegroundColor Green

Write-Host "`n完了しました。" -ForegroundColor Cyan
