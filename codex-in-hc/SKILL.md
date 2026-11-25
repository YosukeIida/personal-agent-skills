---
name: codex-in-hc
description: >-
  Codex への 1 件の委譲（調査・診断・review・実装）を、herdr-core（hc）の端末として起動し、
  Herdr app で呼び出し元の行の下に出して peek で見られるようにする。結果は hc wait と hc read で受け取る。
  「Codex で調べて」「Codex に調査させて」「Codex に実装させて」「Codex に見てもらって」などで使う。
  hc の端末の中（HC_TERMINAL_ID がある）で動くセッションでは、codex plugin の codex:rescue の代わりにこちらを使う。
  ※役割ごとの席を並べるチームは herdr-agent-team が担当する。hc の一般操作は `hc --skill` が担当する。
---

# codex-in-hc

Codex を呼び出し元の子の端末として起動する。core が呼び出し元を `parent` として記録するので、Herdr app の Agents では呼び出し元の行の下に出て、押すと peek の小窓で Codex の画面が見え、keep で tab にできる。

## 前提

- `HC_TERMINAL_ID` が無い（hc の端末の外の）セッションでは使わず、codex plugin の `codex:rescue` を使う。
- アカウントは personal を既定にする。labteam は user に頼まれたときだけ使う。`cx` は zsh の関数で `hc run`（sh 経由）から呼べないので、`CODEX_HOME` で指定する。

| アカウント | `CODEX_HOME` |
|---|---|
| personal | `$HOME/.codex-personal` |
| labteam | `$HOME/.codex-labteam` |

## 手順

1. 依頼文をファイルに書く。引用符や改行を `hc run` の文字列に直接入れない。
   ```sh
   f=$(mktemp -t codex-task); cat > "$f" <<'EOF'
   <依頼文>
   EOF
   ```
2. 「閉じる時機」の規則で、前の Codex を片付ける。そのうえで作業ディレクトリ（対象の repo）で起動する。sandbox は依頼の種類で選ぶ。
   - 調査・診断・review: `-s read-only`
   - 実装（ファイルの書き換えを伴う）: `-s workspace-write`
   ```sh
   cd <repo> && hc run --bg --label codex-in-hc=1 "CODEX_HOME=\$HOME/.codex-personal codex -s read-only \"\$(cat $f)\""
   ```
   label `codex-in-hc=1` は、セッションの終了時に閉じる対象の目印である（「閉じる時機」）。外さない。
   出力の JSON の `address`（例: `t1bg`）が Codex の端末で、`parent` が呼び出し元である。user に端末の番号と、Agents の呼び出し元の行の下で peek できることを伝える。
3. 終わりを待つ。Bash の `run_in_background` で次を起動し、完了の通知を受ける。ポーリングはしない。`hc wait` は timeout のほか、呼び出し元への message でも返るので、Codex が `working` を報告している間だけ待ち直す。
   ```sh
   while r=$(hc wait <t> --timeout 600 --json); [ "$(hc get <t> --json | jq -r '.status.state // empty')" = working ]; do :; done; echo "$r"
   ```
4. `hc get <t> --json` の `.status.state` で分ける。
   - `done` / `idle`: `hc read <t> --lines 400` で最終報告を読み、全文を確かめて返答に書く。
   - `blocked`: 承認・質問で止まっている。`hc read <t>` で画面を読み、何を求めているかを user に伝える。承認は user が peek から行う。
   - 空（一度も状態を報告していない）: 起動直後の確認の画面（フォルダの信頼、「Hooks need review」）で止まっている。Codex はこの画面で状態を報告しない。`hc read <t>` で画面を読み、user に peek から選んでもらう。hook やフォルダを信頼するかは user が決めるので、agent が `hc keys` で選ばない。選ばれたら手順 3 から待ち直す。
5. 端末は残す。user が peek から続けて話しかけられる。

## 続きを頼む

同じ Codex に追加の指示を送るときは、新しく起動せず `hc send <t> -- "<指示>"` で送り、手順 3 から繰り返す。

## 閉じる時機

Codex の会話は `CODEX_HOME` の state DB にスレッドとして残り、`CODEX_HOME=<アカウントの CODEX_HOME> codex resume <thread>` で再開できる。`idle` の端末を閉じても失うものは無いので、次のときは user に聞かずに `hc kill <t>` で閉じる。

- 同じ親から次の Codex を起動する前（手順 2 の前）
- wrap-up やセッションを締めるとき

閉じるのは、親（`$HC_TERMINAL_ID`）の子のうち、`.status.state` が `idle` か `done` で、結果を報告済みのものだけにする。`working`・`blocked`・状態が空のものは残す。user に頼まれたときは、状態によらず閉じる。

```sh
hc ls --json | jq -r --arg p "$HC_TERMINAL_ID" '.terminals[] | select(.parent == $p) | .address'
```

閉じたら、閉じた端末と、再開に使うスレッド ID を返答に書く。スレッド ID は `<CODEX_HOME>/state_5.sqlite` の `threads` 表から、cwd と作成時刻で引く。

子は呼び出し元の Claude Code ではなく、呼び出し元の端末に属する。端末の program は Claude Code を起動した zsh なので、`hc run` の既定（`die_with_parent`）は Claude Code の終了では効かない。そのため、Claude Code の SessionEnd hook（dotfiles の `claude/hooks/codex-in-hc-cleanup.sh`）が、セッションの終了時（ctrl-c、`/exit`、`/clear`）に、その端末の子のうち label `codex-in-hc=1` の Codex を状態によらず閉じる。作業中の Codex も閉じるが、会話は上の `codex resume` で再開できる。
