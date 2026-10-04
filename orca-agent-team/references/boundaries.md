# このスキルが持つもの / 持たないもの

## 持つもの（orca の機械的な操作）

| 領域 | 具体 |
|---|---|
| 席のタブ | 1役割1タブ。タブの名前、どの kind / model / effort / account で起動するか |
| 席の記録 | role → handle / paneKey。orca の再起動で handle が変わっても paneKey から引き直す |
| Run | orchestrator の端末を coordinator にした Run の作成と再利用 |
| 仕事の受け渡し | 指示書ファイルのパスを1行で渡す（`delegate` = worker-start --terminal、`tell` = terminal send） |
| 待ち受け | worker_done / question / escalation の待ち受け（heartbeat の読み飛ばし）、ack、release |
| 点検 | 承認待ち・利用上限を画面から拾う（自動では答えない） |
| 撤収 | この skill が作ったタブだけを閉じる |

## 持たないもの

| 領域 | 正本 |
|---|---|
| 何を委譲するか、どう分けるか、完了の判断 | design（人間）と orchestrator の判断 |
| packet / issue / PR / label / closeout | intent-cli を使う domain なら `intent-cli guide ...` |
| orca の一般操作 | orca 公式 skill の `orca-cli` / `orchestration` |

## intent-cli との関係（2026-09-28 の決定）

**委譲の帳簿は orca の Run（Task / Dispatch）が持つ。intent-cli の `notify` / `session-layer topology` /
READY 判定は使わない。**

intent-cli の配送（session layer）は `herdr-only` と `agmsg` しか無く、orca の席に届ける正規の経路が無い
（intent-system #1771 は open、G813 は not planned として分解）。2026-09 には、この理由で orca 版を
herdr に戻した（dotfiles `docs/orca-agent-team-design.md` §10）。今回は user の決定で、配送だけを orca の
orchestration に置き換える。intent-cli の guide は「notify を迂回しない」と定めているので、これは意図した逸脱。
intent-cli の状態（packet・queue・ラベル）を使う domain では、その更新は intent-cli の手順で別に行う。

## 1席1タブにする理由

orca の `terminal split` は比率を指定できず、3席以上を1タブに入れると幅が 1/2・1/4・1/4 になる。
タブ領域を並べる操作も CLI から作れない（2026-09-15 実測。前回の orca-agent-team が行き詰まった点）。
herdr で別のペインにしていた役割を、orca では別のタブにする。

非アクティブなタブの裏で承認待ちが出ても人間は気づけないので、orchestrator が `doctor` で拾って知らせる。

## kind の選び方（2026-10-04 実測、Orca 1.4.218）

- **codex**（codex-cli 0.160.0）: `terminal create --command "cx <account> && codex -m <m> -c model_reasoning_effort=\"<e>\""`
  → `worker-start --terminal` が `ready` になる。Orca が Codex を共有 server なしで起動する既定に変わり、
  9 月の「`-c` で embedded mode になって起動待ちが時間切れ」は起きなくなった。`worktree ps` に `working` / `done`、
  ダイアログで `waiting` と `agentWait` が出る。**ダイアログを Esc で取り消すと `agentWait` が残り、
  以後の `terminal send` が `agent_prompt_blocked` になる**（承認で閉じれば消える）。その席は閉じて立て直す。
  `--agent codex` で Orca に起動させる形は `cx` を挟めないので使っていない。
- **claude**: 同じ経路で動く（orchestrator 席で使う）。
- **omp は使わない**（omp 18.4.11）: Orca は状態送信の拡張を付けて起動するが、`worktree ps` に出ず、
  `tui-idle` も時間切れになる。9 月（Orca 1.4.215）は 18.3.4 なら worker として動いた。
- **orchestrator を worker にしない**: orca の入れ子の worker は既定で1段まで。worker が worker を作ると
  `nested_worker_depth_exceeded` になる。
