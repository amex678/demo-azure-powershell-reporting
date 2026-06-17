<#
.SYNOPSIS
    管理者向けの AI インサイト付き HTML レポートを生成します。

.DESCRIPTION
    resources.json を解析し、ガバナンス / コスト / セキュリティ / 信頼性 の観点から
    観察事項と推奨アクションを自動生成して、エグゼクティブサマリ付き HTML を出力します。
    (AI インサイトはルールベース解析により決定的に生成されます)
#>

[CmdletBinding()]
param(
    [string]$JsonPath = (Join-Path $PSScriptRoot 'output\resources.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'output\admin-report.html')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $JsonPath)) {
    throw "JSON が見つかりません: $JsonPath  先に Export-AzResources.ps1 を実行してください。"
}

$data = Get-Content -Path $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$meta = $data.Metadata
$resources = @($data.Resources)
$total = $resources.Count

# ===== 解析 =====
$tagged   = @($resources | Where-Object { $_.Tags -and $_.Tags.Length -gt 0 })
$untagged = @($resources | Where-Object { -not $_.Tags -or $_.Tags.Length -eq 0 })
$tagRate  = if ($total -eq 0) { 0 } else { [math]::Round($tagged.Count / $total * 100, 1) }

$locations = $resources | Group-Object Location | Sort-Object Count -Descending
$types     = $resources | Group-Object ResourceType | Sort-Object Count -Descending
$rgs       = $resources | Group-Object ResourceGroupName | Sort-Object Count -Descending

# 推定: managed / system / 自動生成系のリソースタイプ
$systemTypes = @(
    'Microsoft.Network/networkWatchers',
    'Microsoft.Insights/actiongroups',
    'Microsoft.Insights/activityLogAlerts',
    'Microsoft.EventGrid/systemTopics',
    'Microsoft.OperationalInsights/workspaces',
    'Microsoft.OperationsManagement/solutions'
)

# セキュリティ関連シグナル
$publicIps  = @($resources | Where-Object { $_.ResourceType -eq 'Microsoft.Network/publicIPAddresses' })
$nsgs       = @($resources | Where-Object { $_.ResourceType -eq 'Microsoft.Network/networkSecurityGroups' })
$storage    = @($resources | Where-Object { $_.ResourceType -eq 'Microsoft.Storage/storageAccounts' })
$keyvaults  = @($resources | Where-Object { $_.ResourceType -eq 'Microsoft.KeyVault/vaults' })
$vms        = @($resources | Where-Object { $_.ResourceType -eq 'Microsoft.Compute/virtualMachines' })
$disks      = @($resources | Where-Object { $_.ResourceType -eq 'Microsoft.Compute/disks' })
$vnets      = @($resources | Where-Object { $_.ResourceType -eq 'Microsoft.Network/virtualNetworks' })

# Insights 構築
$insights = New-Object System.Collections.Generic.List[object]

function Add-Insight($category, $severity, $title, $finding, $recommendation) {
    $insights.Add([pscustomobject]@{
        Category       = $category
        Severity       = $severity   # info / warn / critical
        Title          = $title
        Finding        = $finding
        Recommendation = $recommendation
    })
}

# ガバナンス: タグ付与率
if ($total -gt 0) {
    if ($tagRate -lt 50) {
        Add-Insight 'ガバナンス' 'critical' 'タグ付与率が低い' `
            "タグが付与されているリソースは $($tagged.Count) / $total 件 (${tagRate}%) です。コストオーナー特定や課金分割が困難になります。" `
            'Azure Policy の "Require a tag and its value on resources" を適用し、最低でも owner / env / costcenter の 3 タグを必須化してください。'
    } elseif ($tagRate -lt 80) {
        Add-Insight 'ガバナンス' 'warn' 'タグ付与率に改善余地あり' `
            "タグ付与率は ${tagRate}% です。一部リソースで所有者・用途が追跡できていません。" `
            '未タグ付けリソースを棚卸しし、Resource Graph で抽出 → bulk update で補完してください。'
    } else {
        Add-Insight 'ガバナンス' 'info' '良好なタグ付与率' `
            "タグ付与率は ${tagRate}% で良好です。" `
            'タグキーの命名規則を継続的に Azure Policy で監査してください。'
    }
}

# ガバナンス: 所有者タグの欠落
$noOwner = @($resources | Where-Object {
    -not $_.Tags -or ($_.Tags -notmatch '(?i)(^|;)\s*owner\s*=')
})
if ($noOwner.Count -gt 0) {
    $sev = if ($noOwner.Count / [math]::Max($total,1) -gt 0.5) { 'warn' } else { 'info' }
    Add-Insight 'ガバナンス' $sev 'owner タグが未設定のリソース' `
        "owner タグがないリソースが $($noOwner.Count) 件あります。" `
        'リソース所有者を特定し、owner タグを必須化する Policy を適用してください。'
}

# 信頼性: リージョン分散
$nonGlobal = @($locations | Where-Object { $_.Name -ne 'global' })
if ($nonGlobal.Count -ge 3) {
    $top = $nonGlobal | Select-Object -First 1
    $share = if ($total -gt 0) { [math]::Round($top.Count / $total * 100, 1) } else { 0 }
    Add-Insight '信頼性' 'info' 'マルチリージョン構成を検出' `
        "$($nonGlobal.Count) 個のリージョンにリソースが分散しています。最多は $($top.Name) (${share}%) です。" `
        'リージョン間のレイテンシーと DR 戦略 (RTO/RPO) を再確認し、ペアリージョン構成を検討してください。'
} elseif ($nonGlobal.Count -eq 1) {
    Add-Insight '信頼性' 'warn' '単一リージョンへの集中' `
        "リソースは $($nonGlobal[0].Name) の 1 リージョンに集中しています。" `
        'ビジネスクリティカルなワークロードは Azure Site Recovery / Geo-Redundant Storage を活用しペアリージョン構成を検討してください。'
}

# セキュリティ: パブリック IP
if ($publicIps.Count -gt 0) {
    Add-Insight 'セキュリティ' 'warn' 'パブリック IP が存在' `
        "Public IP が $($publicIps.Count) 件あります。インターネットに直接公開されている可能性があります。" `
        'Azure Bastion / Private Link / Front Door 経由のアクセスへ移行し、不要な Public IP は削除してください。NSG で受信元を最小限に絞り込みます。'
}

# セキュリティ: NSG が無いネットワーク環境
if ($vnets.Count -gt 0 -and $nsgs.Count -eq 0) {
    Add-Insight 'セキュリティ' 'critical' 'NSG が未構成' `
        "VNet が $($vnets.Count) 件存在しますが Network Security Group が 1 件もありません。" `
        '各サブネットに NSG を割り当て、最小権限原則 (deny by default) でルールを設計してください。'
}

# セキュリティ: ストレージアカウントの Standard_LRS
$lrsStorage = @($storage | Where-Object { $_.SkuName -like 'Standard_LRS*' })
if ($lrsStorage.Count -gt 0) {
    Add-Insight '信頼性' 'warn' 'LRS ストレージアカウント' `
        "Standard_LRS のストレージが $($lrsStorage.Count) 件あります。LRS は単一データセンター内のみで冗長化されます。" `
        '本番ワークロードでは ZRS / GRS / GZRS への変更を検討してください (データの重要度に応じて選定)。'
}

# コスト: 種類別の偏り (上位 1 種類が 30% 以上)
if ($total -gt 0 -and $types.Count -gt 0) {
    $topType = $types | Select-Object -First 1
    $topShare = [math]::Round($topType.Count / $total * 100, 1)
    if ($topShare -ge 30) {
        Add-Insight 'コスト最適化' 'info' 'リソース種類の偏り' `
            "$($topType.Name) が全リソースの ${topShare}% を占めています ($($topType.Count) 件)。" `
            '同一種類リソースの統合可能性 (例: 複数ストレージアカウントの統合、共有 App Service Plan) を検討してください。'
    }
}

# コスト: アタッチされていない可能性のあるディスク (シグナル: Disk が VM 数より多い)
if ($disks.Count -gt 0 -and $vms.Count -eq 0) {
    Add-Insight 'コスト最適化' 'warn' 'アンアタッチディスクの可能性' `
        "Managed Disk が $($disks.Count) 件ありますが VM は 0 件です。アタッチされていないディスクはコストが発生し続けます。" `
        'Get-AzDisk で DiskState=Unattached を確認し、不要であれば削除またはスナップショット化してください。'
}

# 運用: システムが自動生成したリソースの占有率
$systemCount = @($resources | Where-Object { $systemTypes -contains $_.ResourceType }).Count
if ($total -gt 0 -and $systemCount / $total -gt 0.4) {
    Add-Insight '運用' 'info' 'システム生成リソースが多い' `
        "監視/ガバナンス系のシステム生成リソースが $systemCount 件 (全体の $([math]::Round($systemCount/$total*100,1))%) を占めています。" `
        'ユーザワークロードが少ない可能性があります。デモ/サンドボックス環境であれば想定通りです。'
}

# RG: 大量リソースを抱える RG
if ($rgs.Count -gt 0) {
    $bigRg = $rgs | Where-Object { $_.Count -ge 10 } | Select-Object -First 1
    if ($bigRg) {
        Add-Insight '運用' 'info' '大規模リソースグループ' `
            "リソースグループ '$($bigRg.Name)' に $($bigRg.Count) 件のリソースが集中しています。" `
            'ライフサイクルが異なるリソースは別 RG に分離すると、削除/権限管理が容易になります。'
    }
}

# Key Vault のチェック
if ($keyvaults.Count -eq 0 -and $storage.Count -gt 0) {
    Add-Insight 'セキュリティ' 'info' 'Key Vault が未配置' `
        "Storage Account が $($storage.Count) 件ありますが Key Vault は 0 件です。" `
        '接続文字列・SAS・暗号化キーを Key Vault に集約し、CMK (Customer-Managed Key) を検討してください。'
}

# Severity スコア (エグゼクティブサマリ用)
$crit = @($insights | Where-Object Severity -eq 'critical').Count
$warn = @($insights | Where-Object Severity -eq 'warn').Count
$info = @($insights | Where-Object Severity -eq 'info').Count

$healthScore = 100 - ($crit * 20) - ($warn * 7) - ($info * 1)
if ($healthScore -lt 0) { $healthScore = 0 }
$healthLabel = if ($healthScore -ge 80) { '良好' } elseif ($healthScore -ge 60) { '要注意' } else { '改善が必要' }
$healthColor = if ($healthScore -ge 80) { '#107c10' } elseif ($healthScore -ge 60) { '#ca5010' } else { '#a4262c' }

# 上位の偏り情報をエグゼクティブサマリ用にテキスト化
$topTypesText = (($types | Select-Object -First 3 | ForEach-Object { "$($_.Name.Replace('Microsoft.','')) ($($_.Count))" }) -join ' / ')
$topLocsText  = (($locations | Select-Object -First 3 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ' / ')

# JSON 化
$insightsJson = ($insights | ConvertTo-Json -Depth 4 -Compress)
$resourcesJson = ($resources | ConvertTo-Json -Depth 4 -Compress)
$byTypeJson = ($types | ForEach-Object { [pscustomobject]@{ Key = $_.Name; Count = $_.Count } } | ConvertTo-Json -Depth 3 -Compress)
$byLocJson  = ($locations | ForEach-Object { [pscustomobject]@{ Key = $_.Name; Count = $_.Count } } | ConvertTo-Json -Depth 3 -Compress)
$byRgJson   = ($rgs | ForEach-Object { [pscustomobject]@{ Key = $_.Name; Count = $_.Count } } | ConvertTo-Json -Depth 3 -Compress)

function Ensure-JsonArray([string]$json) {
    if ([string]::IsNullOrWhiteSpace($json)) { return '[]' }
    if ($json.TrimStart().StartsWith('[')) { return $json }
    return "[$json]"
}
$insightsJson  = Ensure-JsonArray $insightsJson
$resourcesJson = Ensure-JsonArray $resourcesJson
$byTypeJson    = Ensure-JsonArray $byTypeJson
$byLocJson     = Ensure-JsonArray $byLocJson
$byRgJson      = Ensure-JsonArray $byRgJson

$generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')

$html = @"
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>管理者向け Azure リソースレポート - $($meta.Subscription)</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
  :root {
    --bg: #0f1320;
    --panel: #1a2030;
    --panel-2: #232a3d;
    --border: #2d3550;
    --text: #e8ecf3;
    --muted: #9aa3b8;
    --accent: #50e6ff;
    --accent-2: #0078d4;
    --crit: #f25c54;
    --warn: #ffb900;
    --info: #50e6ff;
    --good: #7fba00;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: 'Segoe UI', 'Hiragino Kaku Gothic ProN', 'Yu Gothic UI', sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.55;
  }
  header {
    background: linear-gradient(135deg, #1a2030 0%, #2d3550 60%, #0078d4 140%);
    padding: 28px 36px;
    border-bottom: 1px solid var(--border);
  }
  header .eyebrow { font-size: 11px; letter-spacing: 0.18em; color: var(--accent); text-transform: uppercase; margin-bottom: 4px; }
  header h1 { margin: 0 0 8px 0; font-size: 26px; font-weight: 600; }
  header .meta { font-size: 13px; color: var(--muted); }
  header .meta span { margin-right: 18px; }
  main { padding: 28px 36px; max-width: 1400px; margin: 0 auto; }
  section { margin-bottom: 28px; }
  h2 { font-size: 16px; font-weight: 600; margin: 0 0 14px 0; color: var(--accent); letter-spacing: 0.04em; text-transform: uppercase; }

  .card {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 20px;
  }
  .summary-grid { display: grid; grid-template-columns: 1.2fr 1fr 1fr; gap: 16px; }
  .summary-grid .health .score { font-size: 56px; font-weight: 700; line-height: 1; margin-top: 8px; }
  .summary-grid .health .label { font-size: 14px; color: var(--muted); margin-top: 6px; }
  .summary-grid .signal-row { display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px dashed var(--border); }
  .summary-grid .signal-row:last-child { border-bottom: none; }
  .summary-grid .signal-row .v { font-weight: 600; color: var(--accent); }

  .sev-pill { display: inline-block; padding: 2px 10px; border-radius: 10px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; }
  .sev-critical { background: rgba(242,92,84,0.15); color: var(--crit); }
  .sev-warn     { background: rgba(255,185,0,0.15); color: var(--warn); }
  .sev-info     { background: rgba(80,230,255,0.15); color: var(--info); }

  .insights { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  .insight {
    background: var(--panel);
    border: 1px solid var(--border);
    border-left: 4px solid var(--info);
    border-radius: 10px;
    padding: 16px 20px;
  }
  .insight.sev-critical { border-left-color: var(--crit); }
  .insight.sev-warn     { border-left-color: var(--warn); }
  .insight.sev-info     { border-left-color: var(--info); }
  .insight h3 { margin: 0 0 6px 0; font-size: 15px; }
  .insight .cat { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.1em; margin-bottom: 4px; }
  .insight .finding { font-size: 13px; color: var(--text); margin: 8px 0; }
  .insight .recommendation { font-size: 13px; color: var(--muted); padding: 10px 12px; background: var(--panel-2); border-radius: 6px; }
  .insight .recommendation::before { content: "推奨アクション: "; color: var(--accent); font-weight: 600; }

  .charts { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  .chart-card h3 { margin: 0 0 12px 0; font-size: 14px; font-weight: 600; color: var(--text); }
  .chart-card canvas { max-height: 260px; }

  .ai-banner {
    background: linear-gradient(90deg, rgba(80,230,255,0.10), rgba(0,120,212,0.10));
    border: 1px solid rgba(80,230,255,0.3);
    border-radius: 10px;
    padding: 14px 18px;
    font-size: 13px;
    color: var(--text);
    margin-bottom: 22px;
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .ai-banner .icon {
    width: 28px; height: 28px; flex-shrink: 0;
    background: var(--accent); color: var(--bg);
    border-radius: 50%; display: flex; align-items: center; justify-content: center;
    font-weight: 700; font-size: 14px;
  }

  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  thead th {
    background: var(--panel-2); color: var(--muted);
    text-align: left; padding: 10px 12px;
    border-bottom: 1px solid var(--border); font-weight: 600;
    text-transform: uppercase; font-size: 11px; letter-spacing: 0.06em;
  }
  tbody td { padding: 9px 12px; border-bottom: 1px solid var(--border); }
  tbody tr:hover { background: var(--panel-2); }

  footer { padding: 20px 36px; color: var(--muted); font-size: 12px; text-align: center; border-top: 1px solid var(--border); }

  @media (max-width: 900px) {
    .summary-grid, .insights, .charts { grid-template-columns: 1fr; }
    main { padding: 20px; }
  }
</style>
</head>
<body>
<header>
  <div class="eyebrow">Executive Briefing — Azure Inventory</div>
  <h1>管理者向け Azure リソースレポート</h1>
  <div class="meta">
    <span><strong>Subscription:</strong> $($meta.Subscription)</span>
    <span><strong>Subscription ID:</strong> $($meta.SubscriptionId)</span>
  </div>
  <div class="meta" style="margin-top:4px;">
    <span><strong>取得時刻 (UTC):</strong> $($meta.ExportedAtUtc)</span>
    <span><strong>レポート生成:</strong> $generatedAt</span>
  </div>
</header>

<main>

  <div class="ai-banner">
    <div class="icon">AI</div>
    <div>
      本レポートはエクスポート済みインベントリデータを <strong>ルールベース解析</strong>で評価し、ガバナンス・セキュリティ・信頼性・コスト最適化の観点から
      観察事項と推奨アクションを自動生成しています。詳細な対応はクラウドソリューションアーキテクトと協議して進めてください。
    </div>
  </div>

  <section>
    <h2>エグゼクティブサマリ</h2>
    <div class="summary-grid">
      <div class="card health">
        <div style="font-size:11px; color:var(--muted); letter-spacing:0.1em; text-transform:uppercase;">Inventory Health Score</div>
        <div class="score" style="color: $healthColor;">$healthScore</div>
        <div class="label" style="color: $healthColor;">$healthLabel</div>
        <div style="margin-top:14px; display:flex; gap:8px;">
          <span class="sev-pill sev-critical">Critical $crit</span>
          <span class="sev-pill sev-warn">Warning $warn</span>
          <span class="sev-pill sev-info">Info $info</span>
        </div>
      </div>
      <div class="card">
        <div style="font-size:11px; color:var(--muted); letter-spacing:0.1em; text-transform:uppercase; margin-bottom:8px;">主要シグナル</div>
        <div class="signal-row"><span>総リソース数</span><span class="v">$total</span></div>
        <div class="signal-row"><span>リソース種類</span><span class="v">$($types.Count)</span></div>
        <div class="signal-row"><span>リージョン数</span><span class="v">$($locations.Count)</span></div>
        <div class="signal-row"><span>リソースグループ</span><span class="v">$($rgs.Count)</span></div>
        <div class="signal-row"><span>タグ付与率</span><span class="v">${tagRate}%</span></div>
      </div>
      <div class="card">
        <div style="font-size:11px; color:var(--muted); letter-spacing:0.1em; text-transform:uppercase; margin-bottom:8px;">構成プロファイル</div>
        <div style="font-size:12px; color:var(--muted);">主要リソース種類</div>
        <div style="font-size:13px; margin-bottom:10px;">$topTypesText</div>
        <div style="font-size:12px; color:var(--muted);">主要リージョン</div>
        <div style="font-size:13px;">$topLocsText</div>
      </div>
    </div>
  </section>

  <section>
    <h2>AI インサイト ($($insights.Count) 件)</h2>
    <div class="insights" id="insights"></div>
  </section>

  <section>
    <h2>分布の可視化</h2>
    <div class="charts">
      <div class="card chart-card"><h3>リソース種類別 (上位10)</h3><canvas id="chart-type"></canvas></div>
      <div class="card chart-card"><h3>リージョン別</h3><canvas id="chart-location"></canvas></div>
      <div class="card chart-card"><h3>リソースグループ別 (上位10)</h3><canvas id="chart-rg"></canvas></div>
      <div class="card chart-card"><h3>タグ付与状況</h3><canvas id="chart-tag"></canvas></div>
    </div>
  </section>

  <section>
    <h2>付録: リソース一覧 (タグなし)</h2>
    <div class="card">
      <table>
        <thead><tr><th>名前</th><th>種類</th><th>リソースグループ</th><th>リージョン</th></tr></thead>
        <tbody id="untagged-tbody"></tbody>
      </table>
      <div id="untagged-empty" style="color:var(--muted); font-size:12px; margin-top:8px; display:none;">タグなしリソースはありません。</div>
    </div>
  </section>

</main>

<footer>Generated by Build-AdminReport.ps1 — ルールベース AI インサイト</footer>

<script>
  const INSIGHTS  = $insightsJson;
  const RESOURCES = $resourcesJson;
  const BY_TYPE   = $byTypeJson;
  const BY_LOC    = $byLocJson;
  const BY_RG     = $byRgJson;

  function escapeHtml(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
  }
  function shortType(t) { return t ? t.replace('Microsoft.','') : t; }

  // Insights render (severity 順)
  const order = { 'critical':0, 'warn':1, 'info':2 };
  const sorted = INSIGHTS.slice().sort((a,b) => (order[a.Severity] ?? 9) - (order[b.Severity] ?? 9));
  document.getElementById('insights').innerHTML = sorted.map(function(i) {
    return '<div class="insight sev-' + escapeHtml(i.Severity) + '">'
      + '<div class="cat">' + escapeHtml(i.Category) + ' <span class="sev-pill sev-' + escapeHtml(i.Severity) + '">' + escapeHtml(i.Severity) + '</span></div>'
      + '<h3>' + escapeHtml(i.Title) + '</h3>'
      + '<div class="finding">' + escapeHtml(i.Finding) + '</div>'
      + '<div class="recommendation">' + escapeHtml(i.Recommendation) + '</div>'
      + '</div>';
  }).join('');

  // Untagged appendix
  const untagged = RESOURCES.filter(r => !r.Tags || r.Tags.length === 0);
  const tbody = document.getElementById('untagged-tbody');
  if (untagged.length === 0) {
    document.getElementById('untagged-empty').style.display = 'block';
  } else {
    tbody.innerHTML = untagged.map(function(r) {
      return '<tr>'
        + '<td>' + escapeHtml(r.Name) + '</td>'
        + '<td>' + escapeHtml(shortType(r.ResourceType)) + '</td>'
        + '<td>' + escapeHtml(r.ResourceGroupName) + '</td>'
        + '<td>' + escapeHtml(r.Location) + '</td>'
        + '</tr>';
    }).join('');
  }

  // Charts (dark theme)
  Chart.defaults.color = '#9aa3b8';
  Chart.defaults.borderColor = '#2d3550';
  const PALETTE = ['#50e6ff','#0078d4','#7fba00','#ffb900','#f25c54','#b4009e','#5c2d91','#0099bc','#a4262c','#737373'];

  function makeBar(id, labels, values, horizontal = false) {
    new Chart(document.getElementById(id), {
      type: 'bar',
      data: { labels: labels, datasets: [{ data: values, backgroundColor: PALETTE, borderWidth: 0 }] },
      options: { indexAxis: horizontal ? 'y' : 'x', plugins: { legend: { display: false } } }
    });
  }

  const topType = BY_TYPE.slice(0, 10);
  makeBar('chart-type', topType.map(x => shortType(x.Key)), topType.map(x => x.Count), true);
  makeBar('chart-location', BY_LOC.map(x => x.Key), BY_LOC.map(x => x.Count));
  const topRg = BY_RG.slice(0, 10);
  makeBar('chart-rg', topRg.map(x => x.Key), topRg.map(x => x.Count), true);

  const tagged = RESOURCES.filter(r => r.Tags && r.Tags.length > 0).length;
  new Chart(document.getElementById('chart-tag'), {
    type: 'doughnut',
    data: { labels: ['タグあり', 'タグなし'], datasets: [{ data: [tagged, RESOURCES.length - tagged], backgroundColor: ['#50e6ff','#2d3550'], borderWidth: 0 }] },
    options: { plugins: { legend: { position: 'bottom' } } }
  });
</script>
</body>
</html>
"@

$html | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Admin Report: $OutputPath" -ForegroundColor Green
Write-Host ("Insights: critical={0}, warn={1}, info={2}, healthScore={3}" -f $crit, $warn, $info, $healthScore)
