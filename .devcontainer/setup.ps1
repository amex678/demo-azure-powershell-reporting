<#
.SYNOPSIS
    Dev Container 初期化スクリプト。Az.Accounts と Az.Resources を最小構成で導入する。
.NOTES
    - 進捗バーで stdout が詰まらないよう ProgressPreference を抑止
    - 高速な PSResourceGet (Install-PSResource) を優先し、未導入なら Install-Module にフォールバック
    - Az.Resources は Az.Accounts に依存するため、Az.Accounts を個別インストールしない
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$InformationPreference = 'Continue'

Write-Host "==> PowerShell version: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan

# Bootstrap NuGet provider (Install-Module 経路で必要)
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Write-Host "==> Bootstrap NuGet provider" -ForegroundColor Cyan
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
}

Write-Host "==> Trust PSGallery" -ForegroundColor Cyan
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

# Install-PSResource (PSResourceGet) があれば高速経路を優先
$useResourceGet = Get-Command Install-PSResource -ErrorAction SilentlyContinue

Write-Host "==> Install Az.Resources (+ Az.Accounts as dependency)" -ForegroundColor Cyan
if ($useResourceGet) {
    Install-PSResource -Name Az.Resources -Scope CurrentUser -TrustRepository -Reinstall:$false
} else {
    Install-Module -Name Az.Resources -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck
}

Write-Host ""
Write-Host "Installed modules:" -ForegroundColor Green
Get-Module -ListAvailable Az.Accounts, Az.Resources |
    Select-Object Name, Version |
    Sort-Object Name -Unique |
    Format-Table -AutoSize | Out-String | Write-Host

Write-Host "Setup complete." -ForegroundColor Green
Write-Host "次の手順: PowerShell ターミナルで以下を実行して Azure にサインインしてください。" -ForegroundColor Yellow
Write-Host "  Connect-AzAccount -UseDeviceAuthentication" -ForegroundColor Yellow
