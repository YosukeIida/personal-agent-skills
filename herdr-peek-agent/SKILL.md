---
name: herdr-peek-agent
description: >-
  hc の端末の中（HC_TERMINAL_ID がある）で動くセッションでは、Codex への委譲（調査・診断・review・実装）を
  codex plugin の codex:rescue ではなくこの skill で行う。Codex（または頼まれたときは別の Claude Code）を
  herdr-core（hc）の端末として起動し、Herdr app で呼び出し元の行の下に出して peek で見られるようにする。
  結果は hc wait と hc read で受け取る。
  「Codex で調べて」「Codex に調査させて」「Codex に実装させて」「Codex に見てもらって」
  「バックグラウンドで Codex に頼んで」「peek で見られるように動かして」「別の Claude Code に頼んで」などで使う。
  ※役割ごとの席を並べるチームは herdr-agent-team が担当する。hc の一般操作は `hc --skill` が担当する。
---

# herdr-peek-agent

agent（Codex か Claude Code）を呼び出し元の子の端末として起動する。core が呼び出し元を `parent` として記録するので、Herdr app の Agents では呼び出し元の行の下に出て、押すと peek の小窓で agent の画面が見え、keep で tab にできる。

## 前提

- `HC_TERMINAL_ID` が無い（hc の端末の外の）セッションでは使わず、codex plugin の `codex:rescue` を使う。
- 起動する agent は Codex を既定にする。Claude Code は、user が別の Claude Code での作業を頼んだとき（「別の Claude Code に」「peek で見られるように Claude で」など）だけ起動する。Claude Code の通常の subagent は Task tool のまま使う。
- Codex のアカウントは personal を既定にする。labteam は user に頼まれたときだけ使う。`cx` は zsh の関数で `hc run`（sh 経由）から呼べないので、`CODEX_HOME` で指定する。

| アカウント | `CODEX_HOME` |
|---|---|
| personal | `$HOME/.codex-personal` |
| labteam | `$HOME/.codex-labteam` |

## 手順

1. 依頼文をファイルに書く。引用符や改行を `hc run` の文字列に直接入れない。
   ```sh
   f=$(mktemp -t peek-task); cat > "$f" <<'EOF'
   <依頼文>
   EOF
   ```
2. 「閉じる時機」の規則で、前の agent を片付ける。そのうえで作業ディレクトリ（対象の repo）で起動する。権限は依頼の種類で選ぶ。

   | 依頼 | Codex | Claude Code |
   |---|---|---|
   | 調査・診断・review | `-s read-only` | 指定なし（承認は user が peek から行う） |
   | 実装（ファイルの書き換えを伴う） | `-s workspace-write` | `--permission-mode acceptEdits` |

   ```sh
   # Codex
   cd <repo> && hc run --bg --label herdr-peek-agent=1 "CODEX_HOME=\$HOME/.codex-personal codex -s read-only \"\$(cat $f)\""
   # Claude Code
   cd <repo> && hc run --bg --label herdr-peek-agent=1 "claude \"\$(cat $f)\""
   ```
   label `herdr-peek-agent=1` は、セッションの終了時に閉じる対象の目印である（「閉じる時機」）。外さない。
   出力の JSON の `address`（例: `t1bg`）が agent の端末で、`parent` が呼び出し元である。user に端末の番号と、Agents の呼び出し元の行の下で peek できることを伝える。
3. 終わりを待つ。Bash の `run_in_background` で次を起動し、完了の通知を受ける。ポーリングはしない。`hc wait` は timeout のほか、呼び出し元への message でも返るので、agent が `working` を報告している間だけ待ち直す。
   ```sh
   while r=$(hc wait <t> --timeout 600 --json); [ "$(hc get <t> --json | jq -r '.status.state // empty')" = working ]; do :; done; echo "$r"
   ```
4. `hc get <t> --json` の `.status.state` で分ける。
   - `done` / `idle`: `hc read <t> --lines 400` で最終報告を読み、全文を確かめて返答に書く。
   - `blocked`: 承認・質問で止まっている。`hc read <t>` で画面を読み、何を求めているかを user に伝える。承認は user が peek から行う。
   - 空（一度も状態を報告していない）: 起動直後の確認の画面（フォルダの信頼、Codex の「Hooks need review」）で止まっている。この画面では状態が報告されない。`hc read <t>` で画面を読み、user に peek から選んでもらう。hook やフォルダを信頼するかは user が決めるので、agent が `hc keys` で選ばない。選ばれたら手順 3 から待ち直す。
5. 端末は残す。user が peek から続けて話しかけられる。

## 続きを頼む

同じ agent に追加の指示を送るときは、新しく起動せず `hc send <t> -- "<指示>"` で送り、手順 3 から繰り返す。

## 閉じる時機

会話は agent 側に残り、再開できる。

- Codex: `CODEX_HOME` の state DB にスレッドとして残り、`CODEX_HOME=<アカウントの CODEX_HOME> codex resume <thread>` で再開できる。スレッド ID は `<CODEX_HOME>/state_5.sqlite` の `threads` 表から、cwd と作成時刻で引く。
- Claude Code: `~/.claude/projects/` に transcript が残り、作業ディレクトリで `claude --resume` から選んで再開できる。

`idle` の端末を閉じても失うものは無いので、次のときは user に聞かずに `hc kill <t>` で閉じる。

- 同じ親から次の agent を起動する前（手順 2 の前）
- wrap-up やセッションを締めるとき

閉じるのは、親（`$HC_TERMINAL_ID`）の子のうち、`.status.state` が `idle` か `done` で、結果を報告済みのものだけにする。`working`・`blocked`・状態が空のものは残す。user に頼まれたときは、状態によらず閉じる。

```sh
hc ls --json | jq -r --arg p "$HC_TERMINAL_ID" '.terminals[] | select(.parent == $p) | .address'
```

閉じたら、閉じた端末と、再開に使う ID（Codex はスレッド ID）を返答に書く。

子は呼び出し元の Claude Code ではなく、呼び出し元の端末に属する。端末の program は Claude Code を起動した zsh なので、`hc run` の既定（`die_with_parent`）は Claude Code の終了では効かない。そのため、Claude Code の SessionEnd hook（dotfiles の `claude/hooks/herdr-peek-agent-cleanup.sh`）が、セッションの終了時（ctrl-c、`/exit`、`/clear`）に、その端末の子のうち label `herdr-peek-agent=1` の agent を状態によらず閉じる。作業中の agent も閉じるが、会話は上の方法で再開できる。
