---
name: azure-resource-report
description: "Use this skill whenever the user wants to inventory Azure resources and produce reports in this workspace. Triggers include: 'Azure リソースレポート', 'リソース一覧を出して', 'インベントリ作って', 'サブスクリプションの棚卸し', 'admin report', 'AI インサイト HTML', or any request to run Export-AzResources.ps1 / Build-Report.ps1 / Build-AdminReport.ps1, or to extend their insight rules / chart layouts. Also use when the user wants to add a new Severity rule, swap rule-based insights for an LLM (Azure OpenAI), or onboard a new subscription/customer with the same reporting flow. Do NOT use for unrelated PowerShell tasks, Azure deployment (ARM/Bicep/Terraform), or non-Azure inventory."
---

# Azure リソースインベントリ＆レポーティング Skill

このワークスペースで定義された 3 本の PowerShell スクリプトを使い、
Azure サブスクリプションのリソース情報から CSV / JSON / 2 種類の HTML レポートを生成するためのワークフロー Skill です。

## このスキルの責務

- スクリプトの **正しい実行順序** と前提条件を伝える
- 既存スクリプトの **拡張ポイント** (新しい Severity ルール、追加チャート、LLM 連携) を案内する
- 出力先・命名規約・Dev Container 経由の実行方法を統一する

## 構成ファイル (このワークスペース直下)

| ファイル | 役割 | 出力 |
|---|---|---|
| `Export-AzResources.ps1` | サインイン中サブスクリプションのリソースを取得しエクスポート | `output/resources.csv`, `output/resources.json` |
| `Build-Report.ps1` | 検索/フィルタ/ソート可能な閲覧用 HTML レポート生成 | `output/report.html` |
| `Build-AdminReport.ps1` | ガバナンス/セキュリティ/信頼性/コスト視点のルールベース AI インサイト HTML 生成 | `output/admin-report.html` |
| `.devcontainer/devcontainer.json`, `setup.ps1` | PowerShell 7 + Az モジュールが揃った再現可能な実行環境 | — |

データフローは [README.md](../../../README.md) の Mermaid 図を参照。

## 標準フロー (まずこの順で確認)

1. **環境確認**
   - PowerShell 7+ で実行されているか (`$PSVersionTable.PSVersion`)
   - `Az.Accounts` / `Az.Resources` が import 済みか
   - `Get-AzContext` で対象サブスクリプションがアクティブか
2. **未サインインなら案内**
   - ホスト実行: `Connect-AzAccount`
   - Dev Container 内: `Connect-AzAccount -UseDeviceAuthentication`
3. **CSV / JSON のエクスポート**: `./Export-AzResources.ps1`
4. **閲覧用 HTML**: `./Build-Report.ps1` (依存: `output/resources.json`)
5. **管理者向け HTML**: `./Build-AdminReport.ps1` (依存: `output/resources.json`)
6. **プレビュー**: `output/*.html` を Live Server (ポート 5500) で開く

> 既に `output/resources.json` がある場合、エクスポートを再実行するか「既存 JSON を使うか」をユーザーに確認すること。スクリプトは上書き挙動。

## ユーザーが何を求めているかの判別

| ユーザー発話例 | 取るべき行動 |
|---|---|
| 「リソースの一覧出して」「CSV 化して」 | `Export-AzResources.ps1` のみ実行 |
| 「閲覧用レポート作って」「テーブルと円グラフで見たい」 | Export → `Build-Report.ps1` |
| 「管理者向けの分析レポート」「Severity 付きで」「Health Score」 | Export → `Build-AdminReport.ps1` |
| 「全部作って」 | 3 本順番に実行 |
| 「ルール追加して: 〇〇な場合は warn」 | [insight-rules.md](insight-rules.md) を読み込み、`Build-AdminReport.ps1` の `Add-Insight` 呼び出しを追加 |
| 「LLM で要約 / インサイト生成して」 | 既存ルールベース部はそのまま残し、Azure OpenAI 呼び出しを **追加** する形で拡張 (差し替えではない) |
| 「他の顧客向けに移植したい」 | スクリプト 3 本 + `.devcontainer/` + `.github/skills/azure-resource-report/` をコピーすれば成立 |

## 実装上の規約

- **出力先**: 必ず `output/` 配下。新規成果物を追加する場合も同様。
- **エンコード**: CSV は UTF-8 BOM 付き (Excel 文字化け回避)、JSON は UTF-8。
- **JSON 構造**: ルート直下に `Metadata` (Subscription/Tenant/Account/ExportedAtUtc/ResourceCount) と `Resources` (フラット配列) を持つ。下流スクリプトはこの形を前提にしているので、互換を壊さないこと。
- **CSV のフラット化**: `Tags` は `key=value;key=value` 形式の単一文字列に畳み込む (Build スクリプト側でも `;` 区切り前提)。
- **JSON 単一要素配列対応**: `ConvertTo-Json` で 1 件の場合に配列にならない問題があるため、HTML 埋め込み時は `Ensure-JsonArray` のようなガードを必ず通す (既存スクリプトの実装に倣う)。
- **HTML テーマ**:
  - `Build-Report.ps1` は **ライトテーマ** (Microsoft 公式系のブルー)
  - `Build-AdminReport.ps1` は **ダークテーマ** + Severity カラー (critical=#f25c54 / warn=#ffb900 / info=#50e6ff)
- **Chart.js**: CDN 4.4.x を `script` タグで読み込み。オフライン化要件が出たら別途相談。
- **Severity スコア計算**: `100 - critical*20 - warn*7 - info*1` (下限 0)。閾値 80 / 60 で「良好 / 要注意 / 改善が必要」。閾値変更要望があったら数式と表示色 (`$healthColor`) も同時に直す。

## 拡張パターン

### 1. Severity ルールを追加する

→ [insight-rules.md](insight-rules.md) を参照 (`Add-Insight` のシグネチャと既存ルール一覧)。

### 2. 新しいチャートを増やす

`Build-Report.ps1` の場合:
1. PowerShell 側で `$by<Dim>` を `Group-Object` で集計 → `ConvertTo-Json` → `Ensure-JsonArray`
2. HTML の `.charts` セクションに `<canvas id="chart-xxx">` を追加
3. JS 側で `makeBar('chart-xxx', labels, values, horizontal?)` を呼ぶ

### 3. LLM (Azure OpenAI) でインサイトを生成する

- 既存の `$insights` リストを **入力データ** として LLM に渡し、要約・優先度付けだけを任せる構成を推奨。
- 認証は **Managed Identity** か `AzureCliCredential` を優先。API キーは Key Vault 経由。
- ルールベース結果は決定的なので残し、LLM 出力は別セクション (例: 「Executive Narrative」) として併記する。

### 4. 別サブスクリプションへの切替

`Set-AzContext -Subscription "<名前 or ID>"` を `Export-AzResources.ps1` の前に挟む。複数サブスクリプション横断が要望されたら、ループ + サブスク別 `output/<sub>/` ディレクトリ構成に拡張する。

## 実行例 (コピペ用)

```powershell
# 環境チェック
$PSVersionTable.PSVersion
Get-AzContext

# 未サインインの場合
Connect-AzAccount -UseDeviceAuthentication

# 一括実行
.\Export-AzResources.ps1
.\Build-Report.ps1
.\Build-AdminReport.ps1
```

## アンチパターン (やってはいけない)

- ❌ 出力 HTML を `output/` 以外 (リポジトリ直下など) に書き出す
- ❌ `resources.json` の `Metadata` / `Resources` のキー名を変更する (下流が壊れる)
- ❌ Severity を `critical` / `warn` / `info` 以外の文字列にする (CSS クラス・ヘルススコア計算が `sev-*` 前提)
- ❌ `Build-AdminReport.ps1` のルールベース解析を LLM 呼び出しに **置換** する (再現性とプライバシーが失われる。**追加** に留める)
- ❌ Az モジュールをホスト PowerShell に勝手に Install-Module する (Dev Container がある)

## 関連ドキュメント

- [README.md](../../../README.md) — ワークスペース全体の概要・Dev Container セットアップ
- [insight-rules.md](insight-rules.md) — Severity ルールの拡張ガイド
