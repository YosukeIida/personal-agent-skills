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

## 配置：2席1組。1組が1つのタブ領域を等分する

```
タブ領域1（1:1）              タブ領域2（1:1）
┌──────────┬──────────┐      ┌──────────────┬────────────────┐
│  design  │  review  │      │ orchestrator │ implementation │
└──────────┴──────────┘      └──────────────┴────────────────┘
```

`config/defaults.json` の `split_from` が組を決める。review は design の端末から、
implementation は orchestrator の端末から split する。

**2席1組に限るのが要点。** orca の split は常に現ペインを半分に割り、比率を指定する
手段が無い（`pane resize` 相当のコマンドも存在しない）。2分割なら必ず 1:1 になるが、
3席を1タブに入れると 1/2・1/4・1/4 になって使いものにならない（2026-09-15 実測）。

組み合わせの根拠：

- **design ↔ review** — G789 が「review 席は design の出力もレビューする」と規定
- **orchestrator ↔ implementation** — 委譲する側と受ける側

タブ領域そのものは2つ必要で、これは人間が初回に UI で用意する（下記）。

design が host-state ロール（`.git` を触る作業を担う非サンドボックス席）。

**review を host に置く**のは、review の実作業が委譲で渡される
`.intent-cli/worktrees/review-<unit>` で行われ、impl のチェックアウトに常駐する
必要がないため。**implementation だけ分ける**のはサンドボックス境界のため
（実装席は host routing-root への書き込み権限を持たない）。

### 3席以上を1タブに入れない理由（2026-09-15 の実測）

`orca terminal split` に比率指定が無く、`pane resize` 相当のコマンドも存在しない
（全234コマンドを確認）。分割は常に現ペインを半分に割るので、3回割ると
1/2・1/4・1/8 になる。分割後の自動均等化すら未実装
（[#18077](https://github.com/stablyai/orca/issues/18077) は open・コメント0）。
herdr 版が `ratio` サブコマンドと `min_pane_cols` を持てたのは
`pane split --ratio` / `pane resize --amount` があったからで、orca にはその層が無い。

2分割に限れば比率制御が不要になる、というのがこの設計の要。

### agent の状態は領域ごとに1つしか見えない

orca は agent の状態をタブ名に出す（`✳` `◐` や `Working` の接頭辞）。
`orca terminal show` は `connected` / `lastOutputAt` / `preview` しか返さず、
`agentStatus` に相当するフィールドを持たない
（[#12844](https://github.com/stablyai/orca/issues/12844) は open・反応ゼロ）。

2席1組なので、タブ名から読めるのは各領域の片方だけになる。もう片方の状態は
`doctor` が画面を読んで判定する（承認待ち・利用上限の検出は実測済み）。

### タブ領域の左右分割は CLI から作れない

複数のタブ領域を横に並べる操作は UI 専用で、試した手段はすべて失敗した：

| 手段 | 結果 |
|---|---|
| CLI にタブ領域の分割コマンド | 存在しない（全234コマンド確認済み） |
| `computer click --element-index`（`Split Terminal Right` / `Pane Actions`） | `ok: true` を返すが作動しない |
| `computer drag`（タブを右端へ、座標指定） | `ok: true` を返すが作動しない |
| `computer press-key` / `hotkey` | **作動する**（キー入力だけは効く） |

Electron の web content に対して AXPress も合成ドラッグも通らない。
キー入力は効くので、[#10055](https://github.com/stablyai/orca/issues/10055)
（tab-level split のショートカット、実装済み PR #10076 がマージ待ち）が入れば
`computer hotkey` で自動化できる。

人間が UI で並べた場合は `adopt` で取り込む。**タブをドラッグしてもハンドルは
変わらない**ので、一度並べれば `up` は既存席を再利用し、レイアウトは維持される。

### レイアウトを壊さずに agent を入れ替える

claude / codex の更新を取り込むには agent の再起動で足りる。端末を閉じると
タブ領域が消えて CLI では作り直せないため、**既定の `down` は agent だけを終了し
端末は残す**。`/exit` を送り、応じなければ interrupt を2回送る。

```bash
bash $S down --team <name>    # agent のみ終了。端末とレイアウトは残る
bash $S up   --team <name>    # 同じ端末に agent を起動し直す（更新はここで入る）
```

端末ごと閉じたいときだけ `--close-terminals` を渡す。レイアウトは失われる。

`up` は端末の生存と agent の稼働を別々に見る。端末が生きていて agent だけ
止まっていれば、その端末で起動し直す。`status` もこの2つを区別して表示する。

### ブラウザ経由で UI を操作できる（2026-09-15 の発見）

Orca はランタイムサーバ（既定 6768 番）で web UI を配信しており、
**ブラウザ自動化なら UI のボタンが実際に作動する**。`Split Terminal Right` の
クリックで端末が増えることを実測した。

合成入力が効かない経路との対比：

| 経路 | 結果 |
|---|---|
| `orca computer` の click / drag / hotkey / type-text | **Orca に届かない**（`ok:true` は発行の意味） |
| AppleScript の `keystroke` | 届かない |
| AppleScript の System Events 読み取り | 動くが、対象要素が間欠的にしか現れない |
| **ブラウザ自動化（agent-browser）** | **作動する** |

ただし web UI にタブ領域の分割は見当たらない（タブに `draggable` が無く、
`New tab` メニューは New Terminal / New Browser Tab のみ）。ペイン分割までは
ブラウザ経由でも可能。

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

# 2'. intent-cli 側の記録だけ作る（端末も agent も触らない）
#     旧 role-pane-mapping.json からの移行に使う。retire-legacy は
#     新形式の記録が先に存在することを要求するため。
bash $S up --team <name> --topology-only

# 2''. 人間が UI で並べた端末を席として取り込む
bash $S adopt --team <name> --map <role>=<handle> [--map ...]

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
