# CONVENTIONS — experience/ のレコード規約

設計の正: artifact「experience/」＋ `docs/experience-migration-plan-2026-08-28.md`。

## 構造

- `global/` — 全作業に共通する判断レシピ
- `<dir名>/` — 作業 dir 単位。dir 名は claude-memory の manifest.tsv の短名に従う
- `drafts/` — 自動抽出の下書き。**場所＝状態**（ここにあるものが未承認）。承認＝定位置への移動
- `archive/` — supersede された旧レコードの退避先
- `GROUPS.md` — dir 結合の宣言（対称）。分類はここだけが持つ

## レコードの書式

```markdown
---
type: decision        # decision / lens / user / feedback / project / reference
last-verified: 2026-08-28
supersedes:           # 置き換えた旧レコード名（あれば）
---
**判断**: <一文で>
**Why**: <なぜそう決めるのか>
**前提**（これが変わったら疑う）: <drift trigger>
**確度**: S / A / B
関連: [[別レコード名]]
```

- **確度**: S＝実測・データ裏付き / A＝複数回の経験・複数ソース一致 / B＝1回の判断
- drafts/ のレコードのみ `proposed: global | <dir名>` を frontmatter に追加する

## 規律

- **ファイル名はグローバル一意**（experience/ 全体で重複させない。kebab-case）。
  リンク解決の互換性（Obsidian / Foam / grep）の要
- **内容タグは書かない**。検索は grep、スコープは置き場所、関係は GROUPS.md
- **Dataview 記法（`key:: value`・クエリ）は書かない**。Obsidian 外で意味を持たない唯一の記法
- 見出し・ブロックへのリンク（`[[note#section]]`）は当面使わない。ファイル単位のみ
- supersede: 旧レコードは本文から消さず `archive/` へ移動し、新レコードに `supersedes:` を書く。
  履歴の完全性は git が持つ
- 昇格判定の目安: 横断2回以上・反例を知らない・一文で言語化できる
- machine 軸は設けない。機体固有の話は本文に書く（例:「Mac Studio では〜」）

## 索引（機械生成・このリポジトリには無い）

`~/.claude/experience-index.md` は SessionStart hook（dotfiles/claude/hooks/experience-inject.sh）
が毎セッション生成するキャッシュ。手で編集しない。1行形式:

```
- [decision/S] permission-rules-as-wildcards — allow はコマンド単位ワイルドカードで書く
```

上限60行。超えたら警告が出るので棚卸し（archive 送り・supersede）する。
