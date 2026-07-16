---
name: overleaf-review-fetch
description: >
  Overleafプロジェクトのレビューパネル（インラインコメント）を Chrome Canary 専用プロファイル + browser-use で
  開き、指導教員などのコメントを全件取得して、リポジトリの慣習に合わせた notes ディレクトリに日付付き
  Markdown として保存する。特定のリポジトリ構成に依存しない汎用skill。
  「先生のコメント取って」「overleafのレビュー確認して」「supervisor commentをまとめて」
  「査読コメントを取得して」などで起動。
  ※対応方針の検討・修正の実装は範囲外（取得〜md化まで）。修正計画のドラフトは既存の academic-paper 系
  skill や通常の対話で行う。
---

# Overleaf Review Fetch

OverleafのReviewパネルに溜まったインラインコメント（指導教員のレビュー等）を、ブラウザ操作で
取得してMarkdownにまとめるskill。DOM操作の手順・座標・JSセレクタは前回の実地検証で確定済みのものを
そのまま使うので、毎回ゼロから探索し直さない。

**スコープ**: コメント取得 → Markdown作成まで。対応方針の検討・修正の実装はこのskillの範囲外。

## Prerequisites（初回のみ、手動セットアップが必要）

以下は一度だけ人間の手で行う必要がある。ネイティブOSダイアログやログイン画面を伴うため、CDP経由での
完全自動化はできない。

1. `~/.chrome-claude-profile` という専用Chromeプロファイルを用意する（初回は自動生成される。既存の
   ふだん使いのブラウザとは完全に分離される）
2. そのプロファイルで Overleaf に一度ログインしておく。**セッションはプロファイルに永続化されるので、
   次回以降は自動でログイン済みになる**（このskillの通常運用ではログインは発生しない）。ログイン手段は
   問わず、以下のいずれでもよい:
   - **手動入力** — 最もシンプルで、どの環境でも動く。パスワードマネージャは不要
   - **ブラウザ内蔵のパスワード保存**（Chrome のパスワードマネージャ）
   - **パスワードマネージャ拡張**（Bitwarden / 1Password 等）。拡張を使う場合のみ、インストール確認
     ポップアップ（「拡張機能を追加しますか？」）や vault のアンロックが Chrome のネイティブUIで出る。
     これらはページのDOM外にありCDP/JS経由では操作できない → 人間に操作してもらう
3. （パスワードマネージャ拡張のオートフィルを使う場合のみ）その vault に対象Overleafアカウントの
   ログイン情報が保存されていること

上記が未セットアップの場合、Step 1でChromeを起動した後、この手順を案内してユーザーの操作を待つ。

## Step 1: Chrome Canary起動 + 接続確認

```bash
open -a "Google Chrome Canary" --args --remote-debugging-port=9222 --user-data-dir="$HOME/.chrome-claude-profile"
curl -s http://127.0.0.1:9222/json/version   # 起動確認。JSONが返れば成功
```

- **既知の摩擦点**: `open -a` によるGUIアプリ起動と、localhostへの `curl`/CDP通信は、多くのプロジェクトの
  Bashサンドボックス設定でブロックされる（"Operation not permitted" や接続エラーになる）。これは
  Bashツール自体が案内する通常の手順（サンドボックス起因のエラーだと判断できる場合に限りユーザーへの
  説明とともに `dangerouslyDisableSandbox: true` で再試行する、通常の許可フローに従う）で対処すればよい
  ——このskill固有の特別な指示ではなく、単に「この2箇所で毎回同じ摩擦が起きる」という既知情報として
  記録しておくだけである。
- 以後、このskill内の全ての `browser-use` 呼び出しは次の形式に統一する:
  ```bash
  BU_CDP_URL="http://127.0.0.1:9222" uvx --from browser-use browser-use <<'PY'
  # ここにPythonコード（ensure_real_tab(), page_info(), new_tab(url), wait_for_load(),
  # click_at_xy(x, y), capture_screenshot(path), js(code) などが事前importされている）
  PY
  ```
  （同様にサンドボックス起因のエラーが出うる）
- **既知の落とし穴**: `--user-data-dir` にカスタムパスを使っているため、`browser-use --doctor` の
  自動検出（既定プロファイルパスのみ走査）は失敗し続ける。`--doctor` の結果は無視してよく、常に
  `BU_CDP_URL` を明示指定して直接操作すること。

## Step 2: 対象Overleafプロジェクトの解決

引数の与えられ方によって3通りに分岐する。

**(a) 引数がOverleaf project ID（24桁hex）またはプロジェクトURL**
そのままIDとして採用し、Step 3へ。

**(b) 引数がプロジェクトタイトルの文字列**
IDが分からないので一覧検索が必要。Step 3bへ。

**(c) 引数なし → 現在のリポジトリから自動推測**

```bash
git remote -v | grep overleaf | grep fetch
# 例: overleaf-ieee-access-2026  https://git.overleaf.com/6a258a3a94bf244aa9a7e4f1 (fetch)
git branch --show-current
```

各 `overleaf-<slug>` remoteについて、`<slug>` のハイフンをアンダースコアに置換した文字列が現在の
ブランチ名の部分文字列になっているかを判定する。一意に決まればそのremote URL末尾の24桁IDを採用して
Step 3へ進む。

- `overleaf-*` remoteが1件もない（Overleaf git連携を使っていない、またはこのskillを初めて使う
  リポジトリ）→ 自動的に0件になる。エラーで止めず、下記のAskUserQuestionにフォールバックする。
- 0件または複数件で一意に決まらない場合は **AskUserQuestion** で候補を提示して選んでもらう
  （remoteが1件もない場合は「プロジェクト名かURLを教えてください」と聞く）。

**参考情報**: ここで解決した slug は、Step 8 で出力先（論文ディレクトリ）を特定するのにも使う。

## Step 3: プロジェクトを直接開く（IDが分かっている場合。最優先）

```python
new_tab("https://www.overleaf.com/project/<ID>")
wait_for_load()
print(page_info())
```

`page_info()` のURLが `/login` にリダイレクトされていたら未ログイン状態 → Step 4へ。
そうでなければログイン済みなのでStep 4をスキップしてStep 5へ。

## Step 3b: タイトル文字列しか分からない場合の一覧検索フォールバック

IDを得る手段がない場合のみ使う経路。座標の決め打ちクリックは画面レイアウト（プロモーションバナーの
有無等）でズレるため使わない。Reviewパネル探索と同じ「JSでテキスト一致要素を探してbounding boxを
取得 → `click_at_xy`」方式に統一する。

```python
new_tab("https://www.overleaf.com/project")
wait_for_load()
```

```js
(() => {
  const TITLE = "対象のプロジェクトタイトルをここに埋め込む";
  const rows = Array.from(document.querySelectorAll('a, [role="row"], td, span'));
  const hits = rows.filter(el => el.children.length === 0 && el.textContent.trim() === TITLE);
  // 完全一致が複数ある場合は Last modified が最新の行を優先する（DOM順序が新しい順のことが多い）
  const hit = hits[0];
  if (!hit) return null;
  const link = hit.closest('a') || hit;
  const r = link.getBoundingClientRect();
  return JSON.stringify({x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2)});
})()
```

返ってきた座標で `click_at_xy(x, y)` → `wait_for_load()`。

## Step 4: 未ログイン時のみログイン

事前ログイン済み（Prerequisites 2）なら通常この Step は発生しない。発生した場合はログイン手段に応じて分岐する。

```python
new_tab("https://www.overleaf.com/login")
wait_for_load()
```

1. スクリーンショットを撮り、Email欄の位置を確認して `click_at_xy` でクリックする
2. 認証情報を入力する。利用可能な手段を使う:
   - **パスワードマネージャのオートフィル**（Bitwarden / 1Password 等の拡張、またはブラウザ内蔵）:
     `overleaf.com` の候補がフィールド下やツールバーに表示されるので、スクリーンショットで位置を確認し、
     クリックしてオートフィルする
   - **オートフィルが使えない場合**: skill 側でパスワードを保持・入力することはしない。ユーザーに手動での
     入力を依頼して待つ
3. 「Log in」ボタンをクリック
4. `page_info()` のURLが `/project/...` に変わっていればログイン成功

オートフィル候補が出ない、パスワードマネージャがロックされている、またはそもそも自動入力手段が無い場合は
自動化を諦め、ユーザーに手動でのログイン（必要ならアンロック）を依頼して停止する。

## Step 5: Reviewパネルを開く

検証済みのJSスニペットで「review」を含むボタン/リンクを探す（`invert_colors`（PDFプレビューの色反転
ボタン）などの誤検出が混ざるので、テキストで絞り込む）。

```js
(() => {
  const candidates = Array.from(document.querySelectorAll('button, [role="button"], a'));
  const found = candidates.filter(el =>
    (el.getAttribute('aria-label')||el.title||el.textContent||'').toLowerCase().includes('review')
  ).map(el => {
    const r = el.getBoundingClientRect();
    return {text: el.textContent.trim().slice(0,40), x: Math.round(r.x+r.width/2), y: Math.round(r.y+r.height/2)};
  });
  return JSON.stringify(found);
})()
```

結果の中から `"rate_reviewReview panel"` のようなテキストを含む項目を選び `click_at_xy(x, y)`。

## Step 6: Overviewタブに切り替え

Reviewパネル下部に "Current file" / "Overview" の2タブがある。"Overview"側は文書全体のコメントを
ファイルごとにまとめて表示する。スクリーンショットで位置を確認して `click_at_xy` でクリックする。

## Step 7: コメント抽出

**確実に動く方法（これを基本線にする）**: `capture_screenshot()` でReviewパネルを含む画面を撮り、
`Read` ツールで画像を読んでコメントカード（投稿者・日時・本文）を書き起こす。

```python
capture_screenshot("<スクラッチパス>/review_overview.png")
```

その後 `Read` ツールでスクリーンショットを読み、表示されている各コメントカードから投稿者名・日時・
本文テキストを転記する。パネルが長い場合はスクロールしながら複数回撮る。

JSのみでの一括抽出は保証しない：Overleafはコメントカードのクラス名を動的にハッシュ化しており、
`closest('[class*="entry"]')` のような汎用セレクタでは本文までまとめて取れないことを確認済み
（タイムスタンプ単体は拾えるが、カード全体の構造化抽出はDOMごとに個別確認が必要）。もし将来
JS抽出を作り込みたい場合は、まず `get_html()` でパネルのコンテナ要素を直接読んで実際のクラス名
・構造を確認してから専用セレクタを書くこと。

## Step 8: Markdown出力

**出力先ディレクトリの解決**:

まず対象論文のローカル作業ディレクトリ（**論文ディレクトリ** = その Overleaf プロジェクトの `.tex` が
置かれているディレクトリ）を特定する。Step 2 で得た slug（remote 名から `overleaf-` を除き、ハイフンを
アンダースコアに正規化したもの。slug が無ければ Overleaf プロジェクトタイトルを英数字スラッグ化した
文字列で代用）を使い、`research/docs/papers/` → `papers/` → `docs/papers/` → リポジトリルート の順に、
slug 正規化文字列を含みかつ直下に `.tex` を持つディレクトリを探す。

- **論文ディレクトリが特定できた場合（デフォルト経路）** — 出力先は `<論文dir>/notes/`。
  - `<論文dir>/notes/` が **既に存在する** → 確認せずそこへ出力する。
  - まだ存在しない → **AskUserQuestion** で「`<論文dir>/notes/` を作成してそこに保存してよいか」を
    確認してから作成する（候補: そのまま作成 / `docs/notes/` にする / 別のパスを指定）。
- **論文ディレクトリが特定できない場合**（Overleaf git 連携をしていない、ローカルに該当 dir が無い等） —
  決め打ちせず **AskUserQuestion** で保存先を尋ねる（候補: `docs/notes/` / リポジトリルート直下の
  `notes/` / 任意パスを指定）。

採用した `notes/` ディレクトリの下に `<YYYYMMDD>/`（取得実行日）を作成する。

**ファイル名**: `<YYYYMMDD>_<slug>_supervisor_review_comments.md`

- `<slug>` はStep 2で解決したOverleafプロジェクトのslug（remote名から`overleaf-`を除いたもの、
  または見つかった論文ディレクトリ名）。どちらも得られない場合はOverleafプロジェクトタイトルを
  英数字スラッグ化したものを使う。同じ日に複数プロジェクトのコメントを取得してもファイルが
  衝突しないようにするため。

**フォーマット**:

```markdown
# Overleaf 査読コメント取得（<YYYY-MM-DD>）

- プロジェクト: <Overleaf project title> (`<project id>`)
- 対応する論文ディレクトリ: `<見つかった場合のみ。見つからなければこの行ごと省略>`
- 取得元: Reviewパネル > Overview

| # | 対象ファイル | 日時 | コメント本文 | 対応 |
|---|---|---|---|---|
| 1 | v1.tex | 2026-07-06 11:19am | ... | |
```

「対応」列は空欄のまま出力する（対応方針の検討はこのskillの範囲外。書き終えたら書き込んだ実際の
パスをユーザーに報告する）。

## Troubleshooting

| 症状 | 原因・対処 |
|---|---|
| `open -a` が `kLSUnknownErr` で失敗する | サンドボックス制限が原因の可能性が高い。Bashツールの通常の許可フローに従って対処する |
| `curl`/browser-use呼び出しが接続エラーになる | 同上 |
| `DevToolsActivePort not found` | `chrome://inspect/#remote-debugging` 未有効化、またはカスタム`--user-data-dir`を`--doctor`の自動検出が見つけられていない（`--doctor`は無視して`BU_CDP_URL`を直接指定する） |
| 拡張機能インストール確認ダイアログが操作できない | ネイティブOS UIのため自動化不可。人間にクリックを依頼する（パスワードマネージャ拡張を入れる場合のみ発生） |
| オートフィル候補が出ない/ログインできない | パスワードマネージャ未使用・ロック中・未ログインのいずれか。人間に手動ログイン（必要ならアンロック）を依頼する |
| `overleaf-*` remoteが存在しないリポジトリで引数なし実行 | 自動推測を諦め、即座にAskUserQuestionでプロジェクト名/URLを聞く（エラー終了しない） |

## ファイル配置

```
~/.chrome-claude-profile/          # Chrome Canary専用プロファイル（ログイン状態を保持。パスワードマネージャ拡張を使う場合はそれも）
~/.claude/skills/overleaf-review-fetch/   # このSKILL.mdへのシンボリックリンク
<論文dir>/notes/<date>/<date>_<slug>_supervisor_review_comments.md   # 出力（デフォルト: 論文dirを特定できた場合）
<repo>/docs/notes/<date>/...       # 出力（論文dirが特定できず docs/notes を選んだ場合）
<repo>/notes/<date>/...            # 出力（同上・notes/ を選んだ場合）
```
