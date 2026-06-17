<#
.SYNOPSIS
    エクスポートした resources.json から閲覧用の HTML レポートを生成します。

.DESCRIPTION
    検索・フィルタ・ソート機能付きテーブル、リソース種類別/リージョン別/リソースグループ別の集計、
    Chart.js による可視化を含む自己完結型 HTML を出力します (CDN を使用)。
#>

[CmdletBinding()]
param(
    [string]$JsonPath = (Join-Path $PSScriptRoot 'output\resources.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'output\report.html')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $JsonPath)) {
    throw "JSON が見つかりません: $JsonPath  先に Export-AzResources.ps1 を実行してください。"
}

$data = Get-Content -Path $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$meta = $data.Metadata
$resources = $data.Resources

# 集計
$byType = $resources | Group-Object ResourceType | Sort-Object Count -Descending |
    ForEach-Object { [pscustomobject]@{ Key = $_.Name; Count = $_.Count } }
$byLocation = $resources | Group-Object Location | Sort-Object Count -Descending |
    ForEach-Object { [pscustomobject]@{ Key = $_.Name; Count = $_.Count } }
$byRg = $resources | Group-Object ResourceGroupName | Sort-Object Count -Descending |
    ForEach-Object { [pscustomobject]@{ Key = $_.Name; Count = $_.Count } }

# JSON 化 (HTML 埋め込み用)
$resourcesJson  = ($resources | ConvertTo-Json -Depth 4 -Compress)
$byTypeJson     = ($byType    | ConvertTo-Json -Depth 3 -Compress)
$byLocationJson = ($byLocation| ConvertTo-Json -Depth 3 -Compress)
$byRgJson       = ($byRg      | ConvertTo-Json -Depth 3 -Compress)

# 単一要素配列が JSON で配列にならないケースのガード
function Ensure-JsonArray([string]$json) {
    if ([string]::IsNullOrWhiteSpace($json)) { return '[]' }
    if ($json.TrimStart().StartsWith('[')) { return $json }
    return "[$json]"
}
$resourcesJson  = Ensure-JsonArray $resourcesJson
$byTypeJson     = Ensure-JsonArray $byTypeJson
$byLocationJson = Ensure-JsonArray $byLocationJson
$byRgJson       = Ensure-JsonArray $byRgJson

$generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')

$html = @"
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Azure リソースインベントリ - $($meta.Subscription)</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
  :root {
    --bg: #f5f7fb;
    --panel: #ffffff;
    --border: #e3e8ef;
    --text: #1f2937;
    --muted: #6b7280;
    --accent: #0078d4;
    --accent-2: #50e6ff;
    --shadow: 0 1px 3px rgba(0,0,0,0.06), 0 1px 2px rgba(0,0,0,0.04);
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: 'Segoe UI', 'Hiragino Kaku Gothic ProN', 'Yu Gothic UI', sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.5;
  }
  header {
    background: linear-gradient(135deg, #0078d4 0%, #005a9e 100%);
    color: #fff;
    padding: 24px 32px;
    box-shadow: var(--shadow);
  }
  header h1 { margin: 0 0 6px 0; font-size: 22px; font-weight: 600; }
  header .meta { font-size: 13px; opacity: 0.92; }
  header .meta span { margin-right: 16px; }
  main { padding: 24px 32px; max-width: 1400px; margin: 0 auto; }
  .kpi-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 16px;
    margin-bottom: 24px;
  }
  .card {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 16px 20px;
    box-shadow: var(--shadow);
  }
  .kpi .label { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; }
  .kpi .value { font-size: 28px; font-weight: 600; color: var(--accent); margin-top: 4px; }
  .charts { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 24px; }
  .chart-card h3 { margin: 0 0 12px 0; font-size: 14px; font-weight: 600; }
  .chart-card canvas { max-height: 280px; }
  .table-card h3 { margin: 0 0 12px 0; font-size: 14px; font-weight: 600; }
  .controls { display: flex; gap: 12px; margin-bottom: 12px; flex-wrap: wrap; }
  .controls input, .controls select {
    padding: 8px 12px;
    border: 1px solid var(--border);
    border-radius: 6px;
    font-size: 13px;
    font-family: inherit;
    background: #fff;
  }
  .controls input { flex: 1; min-width: 240px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  thead th {
    background: #f9fafb;
    text-align: left;
    padding: 10px 12px;
    border-bottom: 2px solid var(--border);
    font-weight: 600;
    cursor: pointer;
    user-select: none;
    white-space: nowrap;
  }
  thead th:hover { background: #eef2f6; }
  thead th .sort-indicator { color: var(--accent); font-size: 11px; margin-left: 4px; }
  tbody td { padding: 8px 12px; border-bottom: 1px solid var(--border); vertical-align: top; }
  tbody tr:hover { background: #f9fafb; }
  .badge {
    display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px;
    background: #e5f1fb; color: #005a9e; white-space: nowrap;
  }
  .badge-loc { background: #f0f9ff; color: #0369a1; }
  .badge-rg  { background: #f3f4f6; color: #374151; }
  .empty-tag { color: var(--muted); font-style: italic; font-size: 12px; }
  footer { padding: 16px 32px; color: var(--muted); font-size: 12px; text-align: center; }
  @media (max-width: 800px) { .charts { grid-template-columns: 1fr; } main { padding: 16px; } }
</style>
</head>
<body>
<header>
  <h1>Azure リソースインベントリレポート</h1>
  <div class="meta">
    <span><strong>Subscription:</strong> $($meta.Subscription)</span>
    <span><strong>Subscription ID:</strong> $($meta.SubscriptionId)</span>
    <span><strong>Tenant:</strong> $($meta.TenantId)</span>
  </div>
  <div class="meta" style="margin-top:4px;">
    <span><strong>取得時刻 (UTC):</strong> $($meta.ExportedAtUtc)</span>
    <span><strong>レポート生成:</strong> $generatedAt</span>
  </div>
</header>

<main>
  <section class="kpi-grid">
    <div class="card kpi"><div class="label">総リソース数</div><div class="value" id="kpi-total">0</div></div>
    <div class="card kpi"><div class="label">リソース種類</div><div class="value" id="kpi-types">0</div></div>
    <div class="card kpi"><div class="label">リージョン</div><div class="value" id="kpi-locations">0</div></div>
    <div class="card kpi"><div class="label">リソースグループ</div><div class="value" id="kpi-rgs">0</div></div>
    <div class="card kpi"><div class="label">タグ付与率</div><div class="value" id="kpi-tagged">0%</div></div>
  </section>

  <section class="charts">
    <div class="card chart-card">
      <h3>リソース種類別 (上位10)</h3>
      <canvas id="chart-type"></canvas>
    </div>
    <div class="card chart-card">
      <h3>リージョン別</h3>
      <canvas id="chart-location"></canvas>
    </div>
    <div class="card chart-card">
      <h3>リソースグループ別 (上位10)</h3>
      <canvas id="chart-rg"></canvas>
    </div>
    <div class="card chart-card">
      <h3>タグ付与状況</h3>
      <canvas id="chart-tag"></canvas>
    </div>
  </section>

  <section class="card table-card">
    <h3>リソース一覧</h3>
    <div class="controls">
      <input id="filter-text" type="text" placeholder="名前 / リソース種類 / RG / タグで検索..." />
      <select id="filter-location"><option value="">すべてのリージョン</option></select>
      <select id="filter-type"><option value="">すべての種類</option></select>
      <select id="filter-rg"><option value="">すべての RG</option></select>
    </div>
    <div style="overflow-x:auto;">
    <table id="resources-table">
      <thead>
        <tr>
          <th data-sort="Name">名前</th>
          <th data-sort="ResourceType">種類</th>
          <th data-sort="ResourceGroupName">リソースグループ</th>
          <th data-sort="Location">リージョン</th>
          <th data-sort="SkuName">SKU</th>
          <th data-sort="Tags">タグ</th>
        </tr>
      </thead>
      <tbody></tbody>
    </table>
    </div>
    <div id="row-count" style="margin-top:8px; color:var(--muted); font-size:12px;"></div>
  </section>
</main>

<footer>Generated by Build-Report.ps1 — Azure PowerShell インベントリデモ</footer>

<script>
  const RESOURCES   = $resourcesJson;
  const BY_TYPE     = $byTypeJson;
  const BY_LOCATION = $byLocationJson;
  const BY_RG       = $byRgJson;

  // KPI
  document.getElementById('kpi-total').textContent     = RESOURCES.length;
  document.getElementById('kpi-types').textContent     = new Set(RESOURCES.map(r => r.ResourceType)).size;
  document.getElementById('kpi-locations').textContent = new Set(RESOURCES.map(r => r.Location)).size;
  document.getElementById('kpi-rgs').textContent       = new Set(RESOURCES.map(r => r.ResourceGroupName)).size;
  const tagged = RESOURCES.filter(r => r.Tags && r.Tags.length > 0).length;
  const tagRate = RESOURCES.length === 0 ? 0 : Math.round(tagged / RESOURCES.length * 100);
  document.getElementById('kpi-tagged').textContent = tagRate + '%';

  // Charts
  const PALETTE = ['#0078d4','#50e6ff','#7fba00','#f7630c','#b4009e','#5c2d91','#e81123','#008272','#ffb900','#737373','#0099bc','#a4262c'];
  function shortType(t) { return t ? t.replace('Microsoft.','') : t; }

  function makeBar(id, labels, values, horizontal = false) {
    new Chart(document.getElementById(id), {
      type: 'bar',
      data: {
        labels: labels,
        datasets: [{ data: values, backgroundColor: PALETTE, borderWidth: 0 }]
      },
      options: {
        indexAxis: horizontal ? 'y' : 'x',
        plugins: { legend: { display: false } },
        scales: { x: { ticks: { autoSkip: false } } }
      }
    });
  }

  const topType = BY_TYPE.slice(0, 10);
  makeBar('chart-type', topType.map(x => shortType(x.Key)), topType.map(x => x.Count), true);
  makeBar('chart-location', BY_LOCATION.map(x => x.Key), BY_LOCATION.map(x => x.Count));
  const topRg = BY_RG.slice(0, 10);
  makeBar('chart-rg', topRg.map(x => x.Key), topRg.map(x => x.Count), true);

  new Chart(document.getElementById('chart-tag'), {
    type: 'doughnut',
    data: {
      labels: ['タグあり', 'タグなし'],
      datasets: [{ data: [tagged, RESOURCES.length - tagged], backgroundColor: ['#0078d4', '#e3e8ef'], borderWidth: 0 }]
    },
    options: { plugins: { legend: { position: 'bottom' } } }
  });

  // Filters
  const filterText = document.getElementById('filter-text');
  const filterLoc  = document.getElementById('filter-location');
  const filterType = document.getElementById('filter-type');
  const filterRg   = document.getElementById('filter-rg');

  function fillSelect(el, values) {
    Array.from(new Set(values)).filter(v => v).sort().forEach(v => {
      const opt = document.createElement('option');
      opt.value = v; opt.textContent = v;
      el.appendChild(opt);
    });
  }
  fillSelect(filterLoc,  RESOURCES.map(r => r.Location));
  fillSelect(filterType, RESOURCES.map(r => r.ResourceType));
  fillSelect(filterRg,   RESOURCES.map(r => r.ResourceGroupName));

  // Table render with sort
  let sortKey = null;
  let sortDir = 1;
  const tbody = document.querySelector('#resources-table tbody');

  function escapeHtml(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
  }

  function renderTags(tagStr) {
    if (!tagStr) return '<span class="empty-tag">(タグなし)</span>';
    return tagStr.split(';').map(function(t){ return '<span class="badge">' + escapeHtml(t) + '</span>'; }).join(' ');
  }

  function render() {
    const q = filterText.value.toLowerCase();
    const loc = filterLoc.value;
    const ty  = filterType.value;
    const rg  = filterRg.value;

    let rows = RESOURCES.filter(r => {
      if (loc && r.Location !== loc) return false;
      if (ty  && r.ResourceType !== ty) return false;
      if (rg  && r.ResourceGroupName !== rg) return false;
      if (q) {
        const hay = [r.Name, r.ResourceType, r.ResourceGroupName, r.Location, r.SkuName, r.Tags]
          .filter(Boolean).join(' ').toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });

    if (sortKey) {
      rows.sort((a, b) => {
        const av = (a[sortKey] || '').toString().toLowerCase();
        const bv = (b[sortKey] || '').toString().toLowerCase();
        if (av < bv) return -1 * sortDir;
        if (av > bv) return  1 * sortDir;
        return 0;
      });
    }

    tbody.innerHTML = rows.map(function(r) {
      return '<tr>'
        + '<td>' + escapeHtml(r.Name) + '</td>'
        + '<td>' + escapeHtml(shortType(r.ResourceType)) + '</td>'
        + '<td><span class="badge badge-rg">' + escapeHtml(r.ResourceGroupName) + '</span></td>'
        + '<td><span class="badge badge-loc">' + escapeHtml(r.Location) + '</span></td>'
        + '<td>' + escapeHtml(r.SkuName || '') + '</td>'
        + '<td>' + renderTags(r.Tags) + '</td>'
        + '</tr>';
    }).join('');

    document.getElementById('row-count').textContent = rows.length + ' 件 / 全 ' + RESOURCES.length + ' 件';

    document.querySelectorAll('thead th').forEach(th => {
      const ind = th.querySelector('.sort-indicator');
      if (ind) ind.remove();
      if (th.dataset.sort === sortKey) {
        const span = document.createElement('span');
        span.className = 'sort-indicator';
        span.textContent = sortDir === 1 ? '▲' : '▼';
        th.appendChild(span);
      }
    });
  }

  document.querySelectorAll('thead th').forEach(th => {
    th.addEventListener('click', () => {
      const k = th.dataset.sort;
      if (sortKey === k) { sortDir *= -1; } else { sortKey = k; sortDir = 1; }
      render();
    });
  });
  [filterText, filterLoc, filterType, filterRg].forEach(el => el.addEventListener('input', render));

  render();
</script>
</body>
</html>
"@

$html | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "HTML : $OutputPath" -ForegroundColor Green
