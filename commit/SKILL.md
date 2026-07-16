---
name: commit
description: >
  変更を conventional commits 規約でコミットする skill。「commitして」「コミットして」
  「commit, pushして」「pushも」「それで commitして」などの指示、または /commit で発動。
  差分を意味単位に分割し、リポジトリ既存のコミットスタイル（type/scope の使い方）を
  踏襲したメッセージを生成する。指示に「push」が含まれれば push まで行う。
allowed-tools: Bash(git:*)
---

# commit — 規約準拠コミット

## 手順

1. `git status --porcelain` と `git diff` / `git diff --staged` で変更の全体を把握する
2. `git log --format='%s' -15` で当該リポジトリの type/scope 慣習を確認し、それを踏襲する
   （例: dotfiles は `feat(skills):` `chore(claude):`、llm-kie は `fix(scripts):` `docs(paper):`）
3. 変更が複数の関心事にまたがる場合は意味単位に分割して複数コミットにする
4. メッセージは conventional commits 形式 `type(scope): 要旨`。本文には「何を」ではなく
   「なぜ」を書く（差分を見れば分かることは書かない）
5. ユーザーが push を求めた場合のみ push する
   （`git push`。上流未設定なら `git push -u origin <branch>`）

## 守ること

- main / master への force push はしない
- 無関係な untracked ファイルを勝手に含めない（明らかな残骸なら指摘だけする）
- pre-commit フック等が失敗したら、勝手に迂回（--no-verify）せず報告する
- diff に secrets らしきもの（.env、*.pem、credentials、API キー文字列）が含まれていたら
  コミットせず停止して確認する
- 別セッション・別作業由来と思われる変更が混ざっていたら、自分の変更だけを選んで stage する
