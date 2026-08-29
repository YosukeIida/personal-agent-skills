---
name: wrap-up
description: >
  セッション終了時の知識抽出。「このセッションを終了しよう」「wrap-upして」「セッションを
  締めて」「今日の判断をまとめて」などで発動。また、経験知の索引に「未 wrap-up のセッションが
  N 件ある」という通知が出ていて user が「やる」と答えたときにも発動する。
  セッション中に user が下した判断を理由・前提つきで抽出し、user のレビューを経て
  experience/（$EXPERIENCE_DIR）へ昇格させる。project の HANDOVER.md 更新も担う。
---

# wrap-up — セッションの判断を経験知に昇格させる

前提: `$EXPERIENCE_DIR` が experience/ の正本を指す（未設定ならこの skill は
「experience が未設定」と伝えて HANDOVER 更新だけ行う）。
レコード規約は `$EXPERIENCE_DIR/CONVENTIONS.md` が正。**必ず先に読むこと。**

初期化（EXPERIENCE_DIR に CONVENTIONS.md / GROUPS.md がまだ無い場合）:
[references/conventions-template.md](references/conventions-template.md) と
[references/groups-template.md](references/groups-template.md) をコピーして
`global/ drafts/ archive/` を掘る。hook（experience-inject.sh / experience-queue.sh、
YosukeIida/dotfiles の claude/hooks/）と併せて、この skill だけで他環境にも導入できる。

## フロー

1. **HANDOVER.md**: 作業 repo に HANDOVER.md があれば、その repo の現行形式のまま更新する
2. **判断の抽出**: このセッション（未 wrap-up 分なら `.queue.tsv` の transcript）から、
   **user が下した判断**を抽出する。拾う対象:
   - 明示的な選択（「Aで」「その方向で」）とその理由
   - user からの訂正・却下（なぜ却下されたか）
   - 採用されなかった代替案と、採用案が勝った理由
   拾わない対象: agent が単独で行った実装判断、repo の記録（コミット・docs）で足りるもの
3. **draft 化**: 各判断を CONVENTIONS.md の書式（判断/Why/前提/確度）で
   `$EXPERIENCE_DIR/drafts/` に書く。frontmatter に `proposed: global | <dir名>` を付ける。
   **前提（drift trigger）が書けない判断はその旨を明示して user に問う**
4. **user レビュー**: draft を一覧表（名前・判断一行・提案宛先・確度）で提示し、
   accept / reject / edit を確認する。**無審査で正本に入れない**
   - 宛先は cwd から機械判定しない。横断的な判断は cwd と無関係に global を提案する
   - 昇格判定の目安: 横断2回以上・反例を知らない・一文で言語化できる。
     満たさない単発の学びは reject（捨てる）か、repo の docs/notes 行きを提案する
5. **格納**: accept された draft を定位置（`global/` または `<dir名>/`）へ **git mv 相当の
   ファイル移動**で昇格。reject は削除
6. **supersede 照合**: 新レコードが既存レコードと矛盾しないか grep で確認。矛盾したら
   旧レコードを `archive/` へ移し、新レコードの frontmatter に `supersedes:` を書く
7. **queue 消し込み**: 処理したセッションの行を `$EXPERIENCE_DIR/.queue.tsv` から削除する
8. **報告**: 昇格 N 件・reject N 件・supersede N 件を1行ずつ列挙する

## 規律

- レコードの Why・前提は user の言葉から書く。agent の推測で埋めない（分からなければ聞く）
- ファイル名は experience/ 全体でグローバル一意（kebab-case）
- 索引（~/.claude/experience-index.md）は触らない——SessionStart hook が再生成する
- 1回の wrap-up で大量の draft を作らない。このセッションの判断だけに絞る
