# Insight Rules — 拡張ガイド

`Build-AdminReport.ps1` のルールベース解析セクションを拡張する際のガイドです。

## `Add-Insight` のシグネチャ

```powershell
Add-Insight <Category> <Severity> <Title> <Finding> <Recommendation>
```

| 引数 | 役割 | 値の例 |
|---|---|---|
| Category | 観点 | `'ガバナンス'` / `'セキュリティ'` / `'信頼性'` / `'コスト最適化'` / `'運用'` |
| Severity | 重要度 (CSS と健康スコアに直結) | `'critical'` / `'warn'` / `'info'` |
| Title | 1 行サマリ | `'NSG が未構成'` |
| Finding | 観察事項 (定量値を含めること) | `"VNet が 5 件あるが NSG が 0 件"` |
| Recommendation | 推奨アクション | `'各サブネットに NSG を割当て、deny by default で...'` |

> Severity を `critical` / `warn` / `info` 以外にすると CSS (`sev-*`) と Health Score 計算 (`crit*20 + warn*7 + info*1`) が外れます。新しい段階を増やしたい場合は **Health Score 数式と CSS の両方を同時に**更新してください。

## 既存ルール一覧 (発火条件 → Severity)

| # | カテゴリ | 発火条件 | Severity |
|---|---|---|---|
| 1 | ガバナンス | タグ付与率 < 50% | critical |
| 1 | ガバナンス | タグ付与率 50–80% | warn |
| 1 | ガバナンス | タグ付与率 ≥ 80% | info |
| 2 | ガバナンス | `owner` タグ無しが過半数 | warn |
| 2 | ガバナンス | `owner` タグ無し少数 | info |
| 3 | 信頼性 | 非 global リージョン ≥ 3 | info |
| 3 | 信頼性 | 非 global リージョン = 1 | warn |
| 4 | セキュリティ | Public IP ≥ 1 件 | warn |
| 5 | セキュリティ | VNet あり & NSG = 0 | critical |
| 6 | 信頼性 | `Standard_LRS*` Storage が ≥ 1 件 | warn |
| 7 | コスト最適化 | 単一 ResourceType が全体の ≥ 30% | info |
| 8 | コスト最適化 | Disk ≥ 1 件 & VM = 0 件 (アンアタッチ可能性) | warn |
| 9 | 運用 | システム自動生成系の占有率 > 40% | info |
| 10 | 運用 | 単一 RG にリソース ≥ 10 件 | info |
| 11 | セキュリティ | Storage あり & Key Vault = 0 件 | info |

## 新規ルール追加のチェックリスト

- [ ] **観測対象を `$resources` から抽出** (`Where-Object` / `Group-Object`)。`@(...)` で必ず配列化 (1 件時のスカラー化を防ぐ)。
- [ ] **発火条件を定量化**。曖昧な条件は警告のノイズになる。
- [ ] **Severity を選定**:
  - `critical`: 即時対応が必要 (情報漏えい、データロス、コンプラ違反)
  - `warn`: ガバナンス上の改善要求、コスト/信頼性の劣化兆候
  - `info`: 棚卸し情報・参考値・良好状態の追認
- [ ] **Finding に数値を入れる** (件数・割合・対象名)。レポートが読まれる強度が変わる。
- [ ] **Recommendation はアクション形**で書く (「〇〇してください」「〇〇を検討してください」)。
- [ ] スクリプト内 `# Insights 構築` セクションの該当カテゴリ近くに追記する (順序は出力順そのまま)。
- [ ] 動作確認: `.\Build-AdminReport.ps1` を再実行し、`output/admin-report.html` でカード表示・Health Score の変化を確認。

## 追加例: 「診断設定が無い VM」を warn として検出する

```powershell
$vmsNoDiag = @($vms | Where-Object {
    # 例: 何らかの方法で diagnosticSettings の有無を判定
    -not (Get-AzDiagnosticSetting -ResourceId $_.ResourceId -ErrorAction SilentlyContinue)
})
if ($vmsNoDiag.Count -gt 0) {
    Add-Insight 'セキュリティ' 'warn' '診断設定が無い VM' `
        "VM $($vmsNoDiag.Count) 件で Diagnostic Settings が未構成です。" `
        'Azure Policy "Configure VMs to send diagnostic logs" を割り当て、Log Analytics へ転送してください。'
}
```

> 副作用 API 呼び出し (`Get-AzDiagnosticSetting` 等) を増やすと実行時間と Reader 以外のロール要求が増える可能性があります。**`Get-AzResource` の戻り値だけで判定できるなら優先**してください。

## カテゴリ追加について

カテゴリ (`'ガバナンス'` 等) は文字列のまま自由に増やせます。HTML 側ではフィルタしていないので CSS 変更不要。ただし「観点軸」を増やすと読み手の認知負荷が上がるので、既存 5 軸に収めることを推奨。
