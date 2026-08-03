---
name: herdr-agent-team
description: "herdr の1タブに複数ロールのエージェントチーム（design / orchestrator / implementation / review など）を宣言的に配備する。role ごとの cwd・agent kind（claude / codex 等）・pane 幅比率を JSON で持ち、up / status / swap / ratio / doctor / down で操作する。「エージェントチームを起動して」「4 pane 構成を作って」「implement を codex に切り替えて」「pane の幅を戻して」「チームの状態を見せて」「agent が落ちてる」などで使う。※intent-cli の委譲・レビュー・publish の作法は一切扱わない（それは intent-cli guide が正）。herdr の一般操作は vendored の herdr skill が担当。"
allowed-tools: Bash(scripts/herdr-team.sh:*), Bash(herdr:*), Bash(jq:*), Bash(git:*), Bash(command:*)
---

# herdr-agent-team

herdr の1タブに、ロールごとの pane を宣言的に配備してエージェントを起動する。

## このスキルの境界（重要）

**持つもの**: pane の分割・幅比率・どの pane でどの agent kind を起動するか・
role→pane マッピングの記録・生存確認・撤収。**機械的な配備だけ**。

**持たないもの**: intent-cli のワークフロー（委譲・レビュー・publish・closeout・ラベル遷移）。
これらは `intent-cli guide ...` が唯一の正本であり、**ここに書き写してはならない**。
intent-cli 自身のルールがローカル skill によるワークフロー再記述を禁じている
（書き写すと guidance が古くなって食い違う）。ワークフローの話が出たら
`intent-cli guide orchestrator-thread --domain <d> --team <t> --target-repo <r> --agent <a>`
に取りに行くこと。

詳細は [references/boundaries.md](references/boundaries.md)。

## 前提

- herdr 内で動いていること（`HERDR_ENV=1`）。外からは操作しない。
- `jq` が必要。

## Workflow

1. 対象チームの設定を作る（初回のみ）。**リポジトリ非依存**で、どのリポジトリでも同じ手順。

   ```bash
   # cwd が git リポジトリなら --host-repo は省略できる（推定される）
   scripts/herdr-team.sh init --team <name> --dry-run

   # 役割ごとにディレクトリを分ける場合（推奨）
   scripts/herdr-team.sh init --team <name> \
     --host-repo <host> --impl-repo <impl> --review-repo <review> \
     --kind implementation=codex --kind review=codex
   ```

2. 状態を見る（読み取りのみ、いつでも安全）。

   ```bash
   scripts/herdr-team.sh status --team dotfiles-dev
   ```

3. 配備する。既にある pane は再利用し、無いロールだけ作る（冪等）。

   ```bash
   scripts/herdr-team.sh up --team dotfiles-dev
   scripts/herdr-team.sh up --team dotfiles-dev --dry-run   # 何をするか出すだけ
   ```

4. 起動後、生存を確認する。`up` は最後にこれを自動で走らせる。

   ```bash
   scripts/herdr-team.sh doctor --team dotfiles-dev
   ```

5. 必要に応じて調整する。

   ```bash
   scripts/herdr-team.sh swap  --team dotfiles-dev --role implementation --kind codex
   scripts/herdr-team.sh ratio --team dotfiles-dev      # ウィンドウ/モニタ変更後に幅を再適用
   scripts/herdr-team.sh down  --team dotfiles-dev      # 自分が作った pane だけ閉じる
   ```

結果は role / pane / kind / 状態 / cwd を簡潔に報告する。pane id を推測して報告しない
（必ずスクリプトの出力を使う）。

## 設定は2層に分かれている

**このスキルはリポジトリ固有の値を持たない。** 公開 skill にローカルパスを持ち込まないため。

| 層 | 場所 | 内容 |
|---|---|---|
| 全リポジトリ共通の既定値 | `config/defaults.json`（skill 内） | ロール構成・kind・比率・`cwd_from`。パスは持たない |
| リポジトリ固有の解決済み設定 | `${HERDR_TEAM_CONFIG_DIR:-~/.config/herdr-agent-team}/<team>.json` | `init` が生成。実パス入り |

`defaults.json` を編集すると、以後 `init` する**全チーム**に効く。特定チームだけ変えたいときは
`init` のオプション（`--kind` / `--ratio`）か、生成された設定を直接編集する。

`cwd_from` は `host` / `implementation` / `review` のどれを使うかの指定で、`init` が
`--host-repo` / `--impl-repo` / `--review-repo` の実パスに解決する。
既定は intent-cli guide の割り当てに合わせてある（design と orchestrator は host、
implementation は実装リポジトリ、review は独立した review の cwd）。

生成される設定の形:

```json
{
  "team": "<name>",
  "host_repo": "/abs/path",
  "repos": { "host": "/abs", "implementation": "/abs", "review": "/abs" },
  "roles": [
    { "role": "design", "kind": "claude", "cwd": "/abs", "ratio": 0.40, "caller": true },
    { "role": "orchestrator", "kind": "claude", "cwd": "/abs", "ratio": 0.24 },
    { "role": "implementation", "kind": "codex", "cwd": "/abs", "ratio": 0.18 },
    { "role": "review", "kind": "codex", "cwd": "/abs", "ratio": 0.18 }
  ]
}
```

`ratio` の合計は 1.0（`init` が検証して外れていれば拒否する）。

- `caller: true` のロールは**このセッション自身が居る pane**に割り当てられ、agent は起動しない
  （自分を起動し直さない）。通常は `design` に付ける。caller pane の cwd は起動時に決まって
  いて変えられないので、config と食い違っても `doctor` は「注意」に留める。
- `kind` は herdr がサポートするもの（`herdr agent --help` の kinds 行で確認）。
  ロールごとに別 kind を混在させてよい。
- `launch_flags`（任意・配列）は `herdr agent start ... -- <flags>` に渡される。
  権限モードは**起動フラグで指定する**こと。起動後に修飾キー送信で切り替えるのは
  信頼できない（shift+tab 等の修飾キー和音は忠実に届かない）。
- `ratio` はこのモニタ・このフォントサイズ前提の値。変わったら `ratio` サブコマンドで
  測り直して再適用する。

## 幅を決めるときの基準

**worker pane を細くしすぎない。実用下限はおよそ 48 桁。** エージェントの承認・信頼・選択
ダイアログは pane に見える形で出て人間が答える設計なので、本文が折り返すと判断できなくなる。

同じ理由で**ロールを別タブに分けない**。非アクティブなタブの裏に承認待ちが隠れると
誰も気づかない。1タブに全ロールを並べて同時に見える状態を保つ。

## 安全規定（スクリプトが強制する）

- **`--pane <id>` を必ず明示する。** 省略すると herdr は**UI でフォーカス中の pane** を使い、
  別チーム・別ワークスペースを壊しうる。pane id は必ず JSON レスポンスから取る。
- **mapping が解決できなければ実行しない**（fail-closed）。空の id でコマンドを投げない。
- **記録済み workspace 外の pane を触らない。**
- **自分が作っていない pane / tab を閉じない。** `down` は mapping に
  `created_by_skill: true` がある pane だけを閉じる。
- **承認ダイアログを勝手に answer しない。** 読めない・破壊的・認証/権限に関わるものは
  必ず operator に上げる。判断の境界は intent-cli guide の G550 節が正本。

## Helper Behavior

`scripts/herdr-team.sh` が担うこと。

- `init` — `defaults.json` の `cwd_from` を実パスに解決し、`--kind role=kind` /
  `--ratio role=n` の上書きを適用して team 設定を生成する。`--host-repo` 省略時は
  cwd の git トップレベルを使う。review と implementation が同じディレクトリなら警告する
  （ロール分離が弱くなるため）。
- `adopt` — 手で組んだ既存レイアウトを取り込む。caller と同じタブの pane を x 昇順に並べ、
  config の roles の順に対応づけて mapping に記録する。pane 数と role 数が合わなければ拒否。
  取り込んだ pane は `created_by_skill: false` なので `down` では閉じない。
- `status` — config と実機の突き合わせ。role / pane / kind / agent_status / cwd / 齟齬を表で出す。
- `up` — 冪等。caller pane を design に割り当て、足りないロールを右方向に split（cwd 指定）、
  pane に role 名を rename、`ratio` を適用、`caller` 以外に `herdr agent start` を実行、
  `<host_repo>/.intent-cli/role-pane-mapping.json` を書き出し、最後に `doctor` を走らせる。
- `swap` — 指定ロールの kind を入れ替える。**agent が生きている pane では実行を拒否する**
  （作業中のセッションを殺さないため）。先に operator がその pane で終了させること。
- `ratio` — 実測 → 目標との差分を境界ごとに resize して収束させる。
  `pane resize --direction` は**指定した pane がその方向に伸びて広くなる**（縮まない）ので、
  スクリプトが符号を扱う。
- `doctor` — `agent-absent`（agent が居るべき pane にシェルプロンプト = 落ちている）、
  cwd 不一致、kind 不一致、mapping が実機と食い違っている、承認待ちで停止、を検出する。
  検出しても自動修復しない（報告のみ）。
- `down` — `created_by_skill: true` の pane だけ閉じる。caller pane は絶対に閉じない。

## 生存確認について

**起動報告は生存の証明ではない。** agent は報告の数秒後に死ぬことがある（実例が
intent-cli guide に記録されている）。`doctor` は pane を実際に読んで agent の TUI が
まだそこにあるかを確認する。シェルプロンプトが見えたら、どれだけ直前に起動成功して
いても落ちている。

正本の READY 判定基準（settle delay の長さ、ping/ack の要否など）は
`intent-cli guide orchestrator-thread` の G556 節を参照すること。ここには書き写さない。
