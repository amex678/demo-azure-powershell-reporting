# Workspace Copilot Instructions

このワークスペースは **Azure PowerShell インベントリ＆レポーティング** のデモ資産です。

## Skills

このワークスペースには `.github/skills/` 配下にローカル Skill が定義されています。
ユーザー要求が下記 Skill の `description` に該当する場合は、SKILL.md を `read_file` で読み込んでから、その手順に従って作業してください。

- [azure-resource-report](skills/azure-resource-report/SKILL.md) — Azure サブスクリプションのリソース一覧から CSV / JSON / 閲覧用 HTML / 管理者向け AI インサイト HTML を生成するワークフロー。

詳細は [.github/skills/README.md](skills/README.md) を参照。

## 一般ルール

- PowerShell スクリプトは PowerShell 7+ (pwsh) を前提とする。
- 出力ファイルは `output/` 配下に書き出す。
- HTML レポート内の Chart.js は CDN 参照 (オフライン化が必要なら別途指示があるはず)。
- Azure へのサインインはコンテナ実行時 `Connect-AzAccount -UseDeviceAuthentication` を推奨。
- 「AI インサイト」は既定でルールベース解析。LLM 連携は明示要求があるときのみ追加する。
