# 責務境界

## なぜ境界が要るか

intent-cli 自身のルールが「ワークフローを再記述するローカル skill ファイル」を禁じている
（CLI 所有の dispatcher skill だけが carve-out）。この skill は **orca という端末ツールの
操作**に限定することでその禁止に触れない。ロールという語は使うが、**ロールが何をするかは
書かない**。

herdr-agent-team が同じ設計で運用されており、その境界定義をそのまま引き継いでいる。

## 持つもの

- 常設チェックアウト（host / impl）への席の割り当て
- タブとペインの構成（host は1タブに split、impl は別タブ）
- 各席の agent 起動（どの worktree でどの kind を、どの model / effort で）
- role → worktree / 端末ハンドル / kind のマッピングの保持
- orchestration Run の確保と run-id の配布
- intent-cli への topology の**値の受け渡し**（`record` / `update-residence` /
  `update-field` / `record-host-state` に引数を渡すだけ。JSON は組まない）
- 生存確認（`status` / `doctor`）
- 撤収（自分が作った端末だけ閉じる。caller 席は閉じない）

## 持たないもの

| 領域 | 取りに行く先 |
|---|---|
| 委譲の作法・タスクブロックの形 | `intent-cli guide orchestrator-thread` / `notify delegate --help` |
| 完了判定（marker / artifact / canonical facts の複合条件） | 同上 |
| wake 源の設計 | 同上 |
| READY 判定の基準（settle delay、ping/ack） | 同上 G556 節 |
| 承認ダイアログに答えてよい範囲 | 同上 G550 節 |
| ロールの権限境界（誰が何を書いてよいか） | `intent-cli guide host-ownership` |
| packet / issue / PR / label / closeout | `intent-cli guide ...` / `automation summary` |
| session transport の選択 | `intent-cli session-layer show` / `set` |
| ユニットごとの worktree の作成・削除 | intent-cli の host-state ロール |
| orca の worktree / 端末 / ブラウザの一般操作 | orca 公式 skill `orca-cli` |
| orca の task DAG / dispatch / gate | orca 公式 skill `orchestration` |

### 配送トポロジーの形式は intent-cli が正本

herdr-agent-team はかつて `.intent-cli/role-pane-mapping.json` を直接書いていたが、
これを越境と自認して CLI に返した経緯がある。実測で2件踏んでいる：

1. 手で組んだ形は validate を通ったが、CLI の正式形（マルチチーム構造）と違った
2. external ロールに pane 情報を混ぜて `record` に拒否された

この skill も同じ方針で、`topology record` に引数を渡すだけにする。JSON の構造は
一切組み立てない。

なお 0.31.0 は `role-pane-mapping.json` の互換読み取りを**削除**しており、
このファイルが残っていると domain 内の全チームが invalid になる。
`topology retire-legacy` で退役させること。

## 判断の指針（機能を足したくなったとき）

**「これは orca に何かを *させる* 機能か、intent-cli の *作法を説明する* 機能か」**
で切り分ける。後者は足さず、`guide` を呼ぶよう促すだけにする。

- 足してよい例
  - 端末を読んで agent が落ちていないか確認する
  - ロールごとの cwd にディレクトリを用意する
  - 承認待ちらしき表示を検出して報告する（応答はしない）
- 足さない例
  - 「レビューではこの順で確認する」という手順
  - 委譲メッセージの雛形
  - 完了判定の条件

`doctor` の承認待ち検出が境界内である理由：**検出して報告するだけ**で、何を答えるかには
関与しない。「どのロールに何を送るか」を決める機能を足したくなったら、それは境界の外側。

## 運用上の安全規定

- `--terminal <handle>` を必ず明示する（省略すると「現在アクティブな端末」が対象になる）
- マッピングが解決できなければ実行しない（fail-closed）
- 自分が作っていない端末を閉じない（`created_by_skill` で判定）
- caller 席は閉じない
- 承認ダイアログを勝手に answer しない
- 稼働中の席で agent を起動し直さない（入れ替えは端末を作り直す）
