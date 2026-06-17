# Workspace Skills

このフォルダにはこのワークスペース専用の **Skill** を配置します。各 Skill は単一フォルダで、`SKILL.md` をエントリーポイントとして持ちます。

## 規約

- **配置**: `.github/skills/<skill-name>/SKILL.md`
- **frontmatter**: `name` / `description` を必須。`description` には「いつ使うか」の判定基準を具体的に書く (発動条件)。
- **付随ファイル**: ルール表・テンプレート HTML・サブガイドなどを同フォルダ配下に分割可能 (例: `insight-rules.md`)。
- **スコープ**: グローバル (`~/.copilot/skills/`) ではなく、このリポジトリ内に閉じる。共有はリポジトリの clone / fork で行う。

## 使い方 (エージェント向け)

1. ユーザー要求が `description` の発動条件に合致するか判定する。
2. 合致したら `SKILL.md` を `read_file` で全文読み込む。
3. SKILL.md の手順に従って実装する。SKILL.md がサブファイルを参照していたら、必要なタイミングでそれらも読み込む。

## 一覧

| Skill | 用途 |
|---|---|
| [azure-resource-report](azure-resource-report/SKILL.md) | Azure サブスクリプションのリソースインベントリと HTML レポート生成 |
