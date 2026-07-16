---
name: cmux-md-katex
description: Markdown ファイル（数式入り）を cmux のブラウザペインで KaTeX 描画してプレビューするスキル。VSCode の Markdown プレビュー相当を cmux 上で再現し、保存ごとに自動更新できる。ターミナル（TUI）には数式を描画できないため別ペインの実ブラウザで表示する。「数式をプレビューして」「この md をブラウザで表示して」「KaTeX で見せて」「数式付き markdown を確認したい」「mdkatex で開いて」などでトリガー。Claude Code 専用。
---

# cmux-md-katex

## 概要

`.md` ファイルを cmux のブラウザペイン（WKWebView）で **数式込みプレビュー**するツール
`mdkatex` を Claude から駆動するスキル。`markdown-it` + KaTeX で VSCode の Markdown
プレビューと同じ描画を行い、保存のたびに再レンダリングされる。

ツール本体は dotfiles に同梱済み：

- 起動スクリプト: `~/workspace/github.com/YosukeIida/dotfiles/cmux/md-katex/cmux-md-katex`
- zsh 関数: `mdkatex`（`zsh/zshrc` で定義）
- 詳細: `cmux/md-katex/README.md`

## 重要な前提：cmux ソケット到達性

`cmux browser` 系コマンドは cmux アプリの Unix ソケット（と `$CMUX_WORKSPACE_ID`）を
必要とする。**Claude Code の Bash シェルがソケットに届くかはセッション依存**：

- cmux ペイン内で起動された Claude（例: cc-launch-workspace 経由）→ 届く・`$CMUX_WORKSPACE_ID` も継承され、直接実行できる。
- cmux の外で起動された Claude → 届かない（`cmux ping` が `Broken pipe`、`$CMUX_WORKSPACE_ID` が空）。この場合は **ユーザーに実行を依頼する**。

## ワークフロー

1. **対象ファイルを特定**し、絶対パスにする。ユーザーが対象を示していなければ、直近で
   編集・言及した `.md` を候補として確認する。

2. **到達性を確認**する：

   ```bash
   echo "WS=$CMUX_WORKSPACE_ID"; cmux ping 2>&1
   ```

   - `pong` 相当が返り `$CMUX_WORKSPACE_ID` が非空 → **手順 3（直接実行）へ**。
   - `Broken pipe` などで失敗、または `$CMUX_WORKSPACE_ID` が空 → **手順 4（ユーザー依頼）へ**。

3. **直接実行（ソケット到達時）**。一度だけ描画する（`--no-watch` で非ブロッキング）：

   ```bash
   ~/workspace/github.com/YosukeIida/dotfiles/cmux/md-katex/cmux-md-katex <絶対パス.md> --no-watch
   ```

   - `previewing ... -> surface:N` が出れば成功。ブラウザペインに描画されたと伝える。
   - その後 Claude がファイルを編集したら、同じコマンドを再実行して更新を反映する。
   - 初回のみ `generating viewer.html ...` が数秒走る（KaTeX を nix から解決）。2 回目以降は一瞬。
   - `failed to open cmux browser surface` 等で失敗したら手順 4 にフォールバックする。

4. **ユーザーに実行を依頼（ソケット不達時）**。次をそのまま案内する：

   > この Claude セッションは cmux ソケットに届かないため、お手元の cmux ターミナルで
   > 実行してください：
   > ```
   > mdkatex <絶対パス.md>
   > ```
   > （保存ごとに自動更新されます。終了は Ctrl-C。）

## 補足

- **継続的なライブ更新**が欲しい場合は、ウォッチ版 `mdkatex <file>`（`--no-watch` なし）を
  専用ペインで動かす。これは前面で mtime を監視し続けるので、Claude から `cmux send` で
  他人のターミナルに流し込まず、ユーザー自身が実行するのが安全。
- Claude が一回ごとに最新状態を見せたいだけなら手順 3 の `--no-watch` で十分。
- 同じ `.md` を再実行すると前に開いたペインを再利用する（surface ref をキャッシュ）。
- KaTeX を更新したい / 描画が崩れたら `--regen` を付けて viewer.html を作り直す。
- これは cmux 専用。tmux やその他ターミナルには適用しない（TUI に数式は描画できない）。
