---
name: orca-agent-team
description: >-
  orca で、役割ごとの agent の席（design / orchestrator / implementation / review）を1役割1タブで立て、
  orchestrator が orca の orchestration で implementation / review に仕事を渡して結果を受け取る。
  席ごとに kind（claude / codex / omp）・model・effort・アカウント（personal / labteam）を設定で選ぶ。
  「orca でエージェントチームを起動して」「orca でタスクを回して」「orchestrator を立てて」
  「席の状態を見せて」「チームを畳んで」などで使う。
  ※herdr で動かすチームは herdr-agent-team が、orca の一般操作は orca-cli / orchestration が担当する。
---

# orca-agent-team

design（このセッション）が orchestrator のタブを立て、orchestrator が implementation / review の席を立てて
仕事を渡す。**1役割1タブ**で、タブの名前は役割名（`plan` / `orchestration` / `implementation` / `review`）。

```
design（このセッション、タブ plan）
  └─ up → orchestrator（タブ orchestration。自分の Run の coordinator）
            ├─ delegate → implementation（タブ implementation。仕事ごとに worker）
            └─ delegate → review（タブ review。仕事ごとに worker）
```

## 使い方（design 側）

```bash
S=~/.claude/skills/orca-agent-team/scripts/orca-team.sh

bash $S init --team <T> --repo <repo>          # 既定の席で設定を作る
bash $S init --team <T> --repo <repo> --set review.account=personal --set orchestrator.kind=omp
bash $S up --team <T>                          # orchestrator のタブを立てる（冪等）

# 仕事を渡す: 指示をファイルに書き、パスだけを送る
bash $S tell --team <T> --role orchestrator --envelope ~/.config/orca-agent-team/<T>/envelopes/<file>.md

bash $S status --team <T>
bash $S doctor --team <T>                      # 承認待ち・利用上限を拾う
bash $S down --team <T>                        # この skill が作ったタブを閉じる
```

orchestrator は起動時に `references/orchestrator.md` を読み、その手順（`run` → `delegate` → `wait` → `settle`）で動く。
orchestrator からの報告は、design のこのセッションに1行で届く（`tell --role design`）。

## 既定の席（`config/defaults.json`）

| role | タブ | kind | model | effort | account |
|---|---|---|---|---|---|
| design | plan | （このセッション） | | | |
| orchestrator | orchestration | claude | opus | high | |
| implementation | implementation | codex | gpt-6.1-sol | max | labteam |
| review | review | codex | gpt-6.1-sol | max | labteam |

codex の席は `tier=fast` で Fast（`-c service_tier`）にできる。変更は `init --set <role>.<key>=<value>` か、生成された `~/.config/orca-agent-team/<T>.json` を直接編集する。
kind ごとの起動フラグは `config/kind-flags.json`（**`<kind> --help` で確かめてから足す**）。

## 知らないと踏むこと

1. **長い指示は必ずファイルにする。** 端末に送るのは `Read and execute the task envelope at <path>` の1行だけ。
2. **omp は席にしない（18.4.x）。** Orca 1.4.218 が omp の状態をつかめず、起動待ちの判定が時間切れになる。
   codex の席は、ダイアログを端末で取り消すと Orca の入力待ちの印が残り、以後の送信が断られる
   （`references/boundaries.md`）。
3. **orchestrator は worker にしない。** 入れ子の worker は既定で1段まで。
4. **`check --wait --types ...` でも heartbeat は届く。** `wait` サブコマンドが読み飛ばす。意味のある配達は
   処理してから `ack` する。
5. **orca を再起動すると handle は変わる。** タブの位置（paneKey）は保たれるので、記録から引き直す。
6. **ダイアログが出ている端末には送れない。** orca が `agent_prompt_blocked` で止める。回り道はしない。
7. **非アクティブなタブの承認待ちは見えない。** `doctor` で拾う。承認に自動では答えない。

## この skill が持たないもの

何を委譲するか・どう判断するか・intent-cli のワークフロー。委譲の帳簿は orca の Run で、intent-cli の
`notify` / topology は使わない（2026-09-28 の決定。理由と経緯は `references/boundaries.md`）。
