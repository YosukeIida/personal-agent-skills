---
name: orca-agent-team
description: >-
  intent-cli の四ロール席（design / orchestrator / implementation / review）を orca 上に
  宣言的に配備する。全席を intent-cli の external resident として記録し、herdr も agmsg も
  使わずに委譲を成立させる。「エージェントチームを起動して」「orca でチームを立てて」
  「4ロール構成を作って」「席の状態を見せて」「チームを畳んで」などで使う。
  ※委譲・レビュー・publish の作法は一切扱わない（`intent-cli guide` が正本）。
  orca の一般操作は orca 公式の orca-cli / orchestration skill が担当する。
---

# orca-agent-team

intent-cli の四ロール席を orca に配備する。**席を立てるところまで**が責務で、
そこで何をするかは `intent-cli guide ...` に従う。

## 配置

```
host worktree（1タブ・3ペイン）              impl チェックアウト（別タブ）
┌──────────┬──────────────┬──────────┐      ┌────────────────┐
│  design  │ orchestrator │  review  │      │ implementation │
└──────────┴──────────────┴──────────┘      └────────────────┘
   ↑ caller（このセッション自身）
   ↑ host-state ロール（.git を触る作業を担う非サンドボックス席）
```

- **review を host に置く**のは、review の実作業が委譲で渡される
  `.intent-cli/worktrees/review-<unit>` で行われ、impl のチェックアウトに常駐する
  必要がないため。design の出力もレビューする（G789）ので同じ画面にある方がよい。
- **implementation だけ分ける**のはサンドボックス境界のため。実装席は host
  routing-root への書き込み権限を持たない。
- orca ではタブが worktree スコープなので、2つの worktree を1画面には並べられない。

## 配送

全席を **external resident** として記録し、session-layer は **herdr-only**。
herdr も agmsg も介在しない。

| 層 | 担い手 |
|---|---|
| 耐久記録 | intent-cli（`notify delegate/report --write` が routing root に書く） |
| 受信 | 各席が `intent-cli notify collect --role <r> --since <cursor> --wait` を回す |
| 起床 | `wake_command` に記録した `orca orchestration send`（courtesy のみ） |

**受信ループを回すのは各席の責務であって、この skill は関与しない。**

## 使い方

```bash
S=~/.claude/skills/orca-agent-team/scripts/orca-team.sh

# 1. チームを定義する（リポジトリ固有の解決済み設定を作る）
bash $S init --team <name> --domain <domain> \
  --host-repo <host-worktree> --impl-repo <impl-checkout> \
  [--kind <role>=<kind>] [--model <role>=<v>] [--effort <role>=<v>]

# 2. 配備する（冪等。2回目以降は生きている席を再利用する）
bash $S up --team <name> [--dry-run]

# 3. 状態を見る
bash $S status --team <name>

# 4. 健全性を調べる（自動修復はしない）
bash $S doctor --team <name>

# 5. 畳む（この skill が作った端末だけ閉じる。caller 席は閉じない）
bash $S down --team <name>
```

`up` が実行する順序：Run の確保 → 端末の作成と agent 起動 → topology の記録 →
wake_command の設定 → host-state ロールの宣言 → session-layer の設定 → validate。

## 知らないと踏むこと

**① `session-layer set` を省くと agmsg に落ちる。**
記録が無いときの既定は `agmsg`。`up` が毎回明示的に `herdr-only` を設定する。

**② 全席をいきなり external で記録すると validate が落ちる。**
`workspace_id` は herdr 由来の概念で、herdr 席がゼロだと導出されない。
`up` は1席を herdr で記録して `workspace_id` を確立してから external に変換する。
この placeholder は herdr 席がゼロなら参照されない（`session-layer inspect` は
`live_query_attempted: false`、`validate --live` は herdr 接続が失敗しても skipped）。

**③ `--routing-root` を各席が毎回明示しないと、成功を装って壊れる。**
guide の規定：「A wrong root strands notify records outside canonical state while the
sender still returns `delivered: true`」。orca は worktree ごとに cwd が違うので、
notify を打つときは常に `--routing-root <host-repo>` を付ける。

**④ 端末出力の保持は 2,000 行。** 超えた分は回復できない（実測）。設定で変えられない。
長文の成果物はファイルに書かせ、`notify delegate --expected-artifact` で行き先を
宣言しておく。出力させてから読めるか判断するのでは手遅れになる。

**⑤ legacy topology が残っていると domain 内の全チームが invalid になる。**
`.intent-cli/role-pane-mapping.json` があると 0.31.0 は互換読み取りを拒否する。
`intent-cli session-layer topology retire-legacy --domain <d> --team <t>
--evidence <text> --confirm-retire-legacy --write` で退役させる。

## 設定

| ファイル | 内容 |
|---|---|
| `config/defaults.json` | ロール構成・kind・worktree の割り当て・host-state ロール |
| `config/kind-flags.json` | kind ごとの model / effort の実 CLI フラグ（`--help` で確認してから書く） |
| `${ORCA_TEAM_CONFIG_DIR:-~/.config/orca-agent-team}/<team>.json` | `init` が作る解決済み設定。`run_id` もここに持つ |
| `${ORCA_TEAM_CONFIG_DIR}/<team>.terminals.json` | role → 端末ハンドルの対応 |

Run は**永続1本**。`up` のたびに作り直すと4席ぶんの `wake_command` を書き換える
ことになるため、`run_id` を team 設定に保存して `run-use` で bind する。
Run が消えてもメッセージは失われない（耐久記録は無事で、起床が止まるだけ）。

## この skill が持たないもの

| 領域 | 正本 |
|---|---|
| 委譲の作法・完了判定・wake 源の設計 | `intent-cli guide orchestrator-thread` |
| 配送トポロジーの形式 | `intent-cli session-layer topology`（値を渡すだけで JSON は組まない） |
| packet / issue / PR / label / closeout | `intent-cli guide ...` |
| ユニットごとの worktree の作成・削除 | intent-cli の host-state ロール |
| orca の一般操作 | orca 公式 skill の `orca-cli` / `orchestration` |

判断の指針は「これは orca に何かを**させる**機能か、intent-cli の**作法を説明する**
機能か」。後者は足さず `guide` を呼ぶよう促すだけにする。詳細は
`references/boundaries.md`。
