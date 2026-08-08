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
- ロールごとの cwd が用意されていること。**同一 repo に metadata ブランチを持つ構成なら、
  clone ではなく worktree で用意できる**（新規 clone を増やさずに済む）。レイアウト規約・
  `detached` が必須な理由・同一ブランチ衝突の回避・配備前に確認することは
  [references/worktree-layout.md](references/worktree-layout.md)。

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
   scripts/herdr-team.sh nudge --team dotfiles-dev      # 貼られたまま止まった pane に enter
   scripts/herdr-team.sh down  --team dotfiles-dev      # 自分が作った pane だけ閉じる
   ```

6. 外部から pane に送られたプロンプトが着火していないときは `nudge`。
   詳細は下の「配送が submit されないことがある」を読むこと。

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

**`--review-repo` の既定は `--impl-repo` なので注意。** review は metadata を読む側なので、
metadata を持たない実装用ディレクトリに置くと成立しない。worktree 構成では
`--review-repo` に host と同じパスを明示する（理由と可否の条件は
[references/worktree-layout.md](references/worktree-layout.md)）。

生成される設定の形:

```json
{
  "team": "<name>",
  "host_repo": "/abs/path",
  "repos": { "host": "/abs", "implementation": "/abs", "review": "/abs" },
  "roles": [
    { "role": "design", "kind": "claude", "cwd": "/abs", "ratio": 0.35, "caller": true },
    { "role": "orchestrator", "kind": "claude", "cwd": "/abs", "ratio": 0.35 },
    { "role": "implementation", "kind": "codex", "cwd": "/abs", "ratio": 0.30 },
    { "role": "review", "kind": "codex", "cwd": "/abs", "ratio": 0.30, "stack_below": "implementation", "stack_ratio": 0.5 }
  ]
}
```

既定レイアウトは3列: design | orchestrator | 右列（implementation 上・review 下、縦積み）。
`stack_below` は「このロールを親ロールの真下に縦積みする」指定。指定されたロールは横方向の
境界調整（`ratio` サブコマンド）の対象から外れ、親ロールと同じ列の幅を共有する。`stack_ratio`
は縦split時の親:子の比率（省略時 0.5＝50/50）。

`ratio` の合計は 1.0（`init` が検証して外れていれば拒否する）。**`stack_below` を持つロールの
`ratio` はこの合計に含めない**（親と同じ列の幅を共有するだけなので、含めると二重計上になる）。

- `caller: true` のロールは**このセッション自身が居る pane**に割り当てられ、agent は起動しない
  （自分を起動し直さない）。通常は `design` に付ける。caller pane の cwd は起動時に決まって
  いて変えられないので、config と食い違っても `doctor` は「注意」に留める。
- `kind` は herdr がサポートするもの（`herdr agent --help` の kinds 行で確認）。
  ロールごとに別 kind を混在させてよい。
- `model` / `effort` は省略可。省略するとその agent の既定に従う。**kind ごとに実フラグへ変換される**
  （実測で確認、2026-08）:

  | kind | model | effort |
  |---|---|---|
  | `claude` | `--model <m>` | `--effort <level>` |
  | `codex` | `--model <m>` | `-c model_reasoning_effort=<level>` |

  codex の effort は引用符なしで `--strict-config` が受理するので、シェル経由でも安全。
  対応表を持たない kind では警告して無視する（`launch_flags` に直接書くこと）。
  **`effort` の段階の意味は kind をまたいで揃っていない。** 同じ `medium` と書いても
  claude と codex で同じ深さになる保証はないので、ロール単位で調整する前提で扱う。
- **これらは「そのセッションだけ」の設定で、agent の設定ファイルを書き換えない。**
  `claude --model` / `--effort` はどちらも "for the current session"（`claude --help` で確認）、
  codex の `-c` も起動時の config 上書き。`~/.claude/settings.json` や
  `~/.codex/config.toml` は変更されないので、他の用途の起動には影響しない。
- **起動後に config の model / effort を変えても、稼働中の agent には反映されない。**
  `up` は稼働中の agent を起動し直さない（作業を殺さないため）。`doctor` が乖離を検出するので、
  `swap --role <role> --kind <kind> --force` で入れ替える。
- `launch_flags`（任意・配列）は `herdr agent start ... -- <flags>` に渡される。
  権限モードは**起動フラグで指定する**こと。起動後に修飾キー送信で切り替えるのは
  信頼できない（shift+tab 等の修飾キー和音は忠実に届かない）。
- `ratio` は相対値なのでモニタ幅に依らないが、絶対桁数は変わる。既定の 0.35 / 0.35 / 0.30 は
  195桁の領域で design 68 / orchestrator 68 / 右列 59 になる（実測 2026-08）。承認ダイアログが
  読める下限はおよそ50桁なので、狭いモニタでは右列から先に破綻する。モニタやフォントサイズを
  変えたら `ratio` サブコマンドで測り直して再適用する。
- **design と orchestrator を同幅にしているのは意図的**。人が実際に指示を打つのはこの2つで、
  特に orchestrator は permission classifier に止められた操作の代行や escalation の受け口に
  なる。右列（implementation / review）は基本的に見るだけなので狭くてよい。

## 配送が submit されないことがある（実測 2026-08）

外部から pane にプロンプトを送る仕組みは、**入力欄に貼るところまでで submit を保証しない**。
実測では次のように分かれた。

| pane の kind | 挙動 |
|---|---|
| `claude` | 貼られたまま **submit されず不着火**（2回再現）。送信側の戻り値は成功を返す |
| `codex` | 正常に着火した |

**pane は `idle` に見えるので生存確認では気づけない。** `doctor` も「agent は生きている」と
報告する。着火していないことは pane を読んで `[Pasted text …]` が入力欄に残っているかで判る。

対処は3層で、上から順に試す。

1. **送信側が送信直後に enter を送る** — 送った側がそのまま
   `herdr agent send-keys <role> enter` を打つのが最も確実。取りこぼしが出ない。
2. **`nudge` で拾う** — 取りこぼしたものを後から拾う。全ロールを走査して、貼られたまま
   止まっている pane にだけ enter を送る（`--role` で1つに絞れる）。
3. **配送する側の実装に報告する** — herdr には `agent prompt --wait` と
   `agent_prompt_stalled` があるので、submit 確認は呼び出し側で取れる。
   確認を持たない実装は想定漏れとして報告するのが筋。

**この問題は kind の選択に影響する。** 受け取り専用のロールを `codex` にすると着火の
取りこぼしが起きない。逆に `claude` のロールは誰かが enter を送る前提で運用設計すること。

## 状態は2つに分かれている（持ち主が違う）

| 状態 | 持ち主 | 場所 | 中身 |
|---|---|---|---|
| **pane 状態** | このスキル | `${HERDR_TEAM_CONFIG_DIR:-~/.config/herdr-agent-team}/<team>.panes.json` | role → pane_id / cwd / kind / 誰が作ったか。`down` / `doctor` / `ratio` が使う |
| **配送トポロジー** | **intent-cli** | `intent-cli` が決める（`session-layer topology` が正本） | 誰にどう届けるか（`resident` / pane / reader） |

**このスキルは配送トポロジーの JSON を組まない。** `session-layer topology record` に値を
渡すだけで、形式を知らない。CLI が形を変えても追随できる。実際、CLI は
`{"teams": {"<team>": {...}}}` というマルチチーム構造を書くが、それを知る必要がない。

- `up` / `adopt` は pane 状態を書いたあと `topology record` をロールごとに呼ぶ。
- `doctor` は形式の妥当性を自分で判定せず `topology validate` に聞く。
- **intent-cli が無い環境ではトポロジーの記録をスキップする**（警告のみ）。このスキルは
  herdr の配備だけで成立し、intent-cli は利用者の1人にすぎない。
- CLI は食い違う記録を fail closed で拒否する。勝手に直さず operator に上げる。

> **`topology` は host repo の cwd から実行する必要がある。** `.intent-cli` を持たない
> ディレクトリから呼ぶと `missing-host-state` で落ちる。このスキルは任意の cwd から
> 呼ばれるので、内部で config の `host_repo` に移って実行している（実測で踏んだ）。

### 宛先の受け取り方（`resident`）

ロールには2通りの受け取り方がある。`resident` で指定し、既定は `herdr`。

| `resident` | 受け取り方 | CLI に渡す値 |
|---|---|---|
| `herdr`（既定） | pane にプロンプトが送られる | `--workspace-id` / `--pane-id` / `--cwd` / `--kind` |
| `external` | **ファイルへの追記**で受け取る | `--reader`（routing-root 相対パス）のみ |

**`external` は上の submit 問題を受けない**（pane に送らないので enter が要らない）。
人間が読むロール（設計・意思決定を担うロール）は `external` が向いている。
`reader` は `init` がチーム名から実体化するので、既定値側に書く必要はない。

`external` のロールも pane を持てる（このスキルは pane 状態として持ち続ける）。
ただし **CLI に渡すのは `--reader` だけ**で、pane 情報は渡さない。混ぜると CLI が
矛盾した記録として拒否する（実測で踏んだ）。

> **pane 状態を失った場合は `up` ではなく `adopt`。** `up` は pane 状態に載っていない
> ロールを「pane が無い」と見なして新しく作る。設定ディレクトリを移した・消した後に
> `up` を打つと、生きている pane の隣に空の pane が生える（実測で踏んだ）。
> 既存レイアウトを取り込むのは `adopt` の仕事。

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
- `adopt` — 手で組んだ既存レイアウトを取り込む。caller と同じタブの pane を x 昇順、
  同じ列内（同じ x）は y 昇順に並べ、config の roles の順（親ロールの直後に子ロールを
  書く前提）に対応づけて mapping に記録する。pane 数と role 数が合わなければ拒否。
  取り込んだ pane は `created_by_skill: false` なので `down` では閉じない。
- `status` — config と実機の突き合わせ。role / pane / kind / agent_status / cwd / 齟齬を表で出す。
- `up` — 冪等。caller pane を design に割り当て、足りないロールを右方向に split（cwd 指定）。
  `stack_below` を持つロールは横方向ではなく、親ロールの pane の真下に `--direction down`
  で split する（横方向の連結には加わらない）。pane に role 名を rename、`ratio` を適用、
  `caller` 以外に `herdr agent start` を実行、`<host_repo>/.intent-cli/role-pane-mapping.json`
  を書き出し、最後に `doctor` を走らせる。
- `swap` — 指定ロールの kind を入れ替える。**agent が生きている pane では実行を拒否する**
  （作業中のセッションを殺さないため）。先に operator がその pane で終了させること。
- `ratio` — 実測 → 目標との差分を境界ごとに resize して収束させる。`stack_below` を持つ
  ロールは横方向の境界調整の対象から外れる（親と同じ列の幅を共有するだけなので、縦split時の
  50/50 はそのまま維持される）。`pane resize --direction` は**指定した pane がその方向に
  伸びて広くなる**（縮まない）ので、スクリプトが符号を扱う。
- `nudge` — 貼られたまま submit されずに止まっている pane に enter を送る。`--role` で
  1ロールに絞れる。判定は pane を読んで `[Pasted text …]` が入力欄に残っているかで行い、
  残っていない pane には何も送らない（空 enter を撒かない）。何を送るかには関与しない。
- `doctor` — `agent-absent`（agent が居るべき pane にシェルプロンプト = 落ちている）、
  cwd 不一致、kind 不一致、**model / effort 不一致**、**logical role 名が付いていない**、
  mapping が実機と食い違っている、承認待ちで停止、を検出する。検出しても自動修復しない（報告のみ）。
  logical role 名は `herdr agent start <role>` が付けるもので、pane で直接 `claude` /
  `codex` と打って起動した agent には付かない。**名前が無い agent は宛先解決から漏れ、
  pane が生きていても配送されない**（fail closed。実測で踏んだ）。修復は
  `herdr agent rename <pane> <role>`。
  model / effort は pane の表示から読んで config と突き合わせる（agent が自分の設定を表示するため）。
  表記の違い（config `opus` / 表示 `Opus 5`）を吸収するため大小無視の部分一致で判定する。
- `down` — `created_by_skill: true` の pane だけ閉じる。caller pane は絶対に閉じない。

## 生存確認について

**起動報告は生存の証明ではない。** agent は報告の数秒後に死ぬことがある（実例が
intent-cli guide に記録されている）。`doctor` は pane を実際に読んで agent の TUI が
まだそこにあるかを確認する。シェルプロンプトが見えたら、どれだけ直前に起動成功して
いても落ちている。

### 生存していても「配送先になれない」ことがある

**起動直後の agent は、検出されていても外部からの配送の宛先候補にならない。**
`running` が false のままで、**1回プロンプトを受けるまで**宛先解決から漏れる（実測 2026-08）。
cwd も kind も一致し生存確認も通るので、ping を送るまで見分けられない。

`up` は agent を起動したあと **READY ping** を送り、`working` への遷移を確認してから
`[ready]` と報告する。遷移しなければ `[not-ready]` として原因の手がかりを出す。
`doctor` も `interactive_ready` を見て同じ状態を検出する。

これは公式の READY 判定（`intent-cli guide orchestrator-thread` の G556）が挙げる4条件
（agent 検出 / cwd 一致 / kind 一致 / **ping して ack を確認**）のうち、最後の1つに対応する。

### 利用上限は「model 不一致」として現れる

**利用上限に達した agent は READY ping を通してしまう。** 指定した model が使えず
fallback model で起動し、ping には応答するためである（実測 2026-08: `gpt-5.6-sol high`
を指定した codex が `gpt-5.6-luna medium` で動いていた）。

このとき唯一の手がかりが `doctor` の **`[model不一致?]`** になる。`doctor` は pane に
利用上限の表示があるかを併せて見て、その場合は「別アカウントに切り替えてから起動し直す」
よう案内する。**pane を作り直すだけでは直らない** — シェルの環境（アカウント切替）から
変える必要がある。

逆に言えば、`[model不一致?]` が出たら「config を変えたのに反映されていない」だけでなく
「上限に当たっている」可能性も疑うこと。

正本の READY 判定基準（settle delay の長さ、ping/ack の要否など）は
`intent-cli guide orchestrator-thread` の G556 節を参照すること。ここには書き写さない。
