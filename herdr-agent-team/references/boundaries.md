# このスキルが持つもの / 持たないもの

## なぜ境界を明示するか

intent-cli は、ワークフローの正本を「インストール済み CLI が返す guidance」に一元化している。
ローカルのファイルに書き写すと、CLI が更新されたときに古い作法が残って食い違う。
そのため intent-cli 自身のルールが、ローカル skill によるワークフロー再記述を禁じている。

> Routine collaboration uses `intent-cli guide ...`. Do NOT read `intents/rules/**`,
> copied prompt files, or **local skill files that restate workflow** for routine operation.
>
> CARVE-OUT: the CLI-owned `intent-cli` dispatcher skill installed by
> `intent-cli skill install` is PERMITTED — it restates no workflow and carries no host state.
> **Local skill files that restate workflow (`gh-issue-to-pr`, `gh-fix-pr-comment`,
> copied runbooks) remain forbidden.**

このスキルは **herdr という端末多重化ツールの操作**に限定することで、この禁止に触れない。
ロールという語を使うが、ロールが何をするかは書かない。

## 持つもの（herdr の機械的操作）

| 領域 | 具体 |
|---|---|
| pane の位相 | 1タブに何 pane、どの順で並べるか、分割方向 |
| pane の幅 | 比率の適用、resize の符号の扱い、可読性の下限 |
| pane の cwd | ロールごとに別ディレクトリを開く |
| agent の起動 | どの pane でどの kind（claude / codex / …）を起動するか、起動フラグ |
| マッピング | role → workspace / pane / cwd / kind の記録と読み出し |
| 生存確認 | pane を読んで agent の TUI がまだあるか、cwd と kind が一致しているか |
| 撤収 | 自分が作った pane だけを閉じる |

## 持たないもの（intent-cli guide が正本）

| 領域 | 取りに行く先 |
|---|---|
| 委譲の作法・タスクブロックの形 | `intent-cli guide orchestrator-thread` / `intent-cli notify delegate --help` |
| 完了判定（marker / artifact / canonical facts の複合条件） | 同上 |
| wake 源の設計 | 同上 |
| READY 判定の基準（settle delay、ping/ack） | 同上（G556 節） |
| 承認ダイアログに答えてよい範囲 | 同上（G550 節） |
| ロールの権限境界（誰が何を書いてよいか） | `intent-cli guide host-ownership` |
| packet / issue / PR / label / closeout | `intent-cli guide ...` および `intent-cli automation summary` |
| session transport の選択（agmsg / herdr-only） | `intent-cli session-layer show` / `set` |

## 判断の指針

スクリプトに機能を足したくなったとき、「これは herdr に何かを**させる**機能か、
それとも intent-cli の**作法を説明する**機能か」で切り分ける。
後者なら、ここには足さず `intent-cli guide ...` を呼ぶよう促すだけにする。

例:
- ✅ 足してよい: pane を読んで agent が落ちていないか確認する
- ✅ 足してよい: ロールごとの cwd に worktree を用意する（ディレクトリ操作）
- ❌ 足さない: 「レビューではこの順で確認する」という手順
- ❌ 足さない: 委譲メッセージの雛形（`notify delegate` が生成するのが正）
