# このスキルが持つもの / 持たないもの

## 持つもの（hc と herdr-app の機械的な操作）

| 領域 | 具体 |
|---|---|
| 席の端末 | 役割ごとに 1 端末。名前は `<team>-<role>`。どの kind / model / effort / account で起動するか |
| 席の置き場 | design のタブへ label で取り込み、横一列に並べる（focus は動かさない） |
| 親子関係 | 他の席は orchestrator の子。orchestrator は親を持たない（`--no-parent`）。design の端末は `up` が team 設定の `design` に書く |
| 仕事の受け渡し | 指示書ファイルのパスを1行で送る（`hc send`） |
| 待ち受け | `hc wait --children any` |
| 撤収 | このチームの名前の端末だけを終える |

## 持たないもの

| 領域 | 正本 |
|---|---|
| 何を委譲するか、どう分けるか、完了の判断 | design（人間）と orchestrator の判断 |
| packet / issue / PR / label / closeout | intent-cli を使う domain なら `intent-cli guide ...` |
| hc・Herdr app の一般操作 | `hc --skill`・`herdr-app --skill` |

## Orca 版（orca-agent-team）との違い

hc には Orca の Run・Task・Dispatch のような委譲の帳簿が無い。代わりに親子関係を使う。
子の turn の終わり・`blocked`・`error`・終了を core が親に知らせ、`hc wait --children any` で待てる。
このため、Orca 版の `delegate`・`settle`・`ack`・`doctor`・`watch`（画面の差分の見回り）は持たない。

## design のタブに並べる理由と幅

user が読み書きするのは design だけなので、design を一番広く（30%）取る。orchestrator は普段見ないが、
サイドバーの木の親になり、止まったときに画面を読むため、細く（20%）残す。残りの席は 50% を等分する。

席はペインの無い端末として起こし、`hc label <席> herdr.space=<design の space> herdr.tab=<design の tab>` で design のタブへ取り込む。
focus は動かず、親子と名前は保たれる。取り込まれた席は、そのタブの分割の木の最後の端末の右に、1 席ずつ足される
（開始時が design だけの row でも、縦に割られた形でも同じ。2026-11-22、Herdr app 0.1.16・herdr-core 0.1.21 で実測）。
取り込みは非同期なので、1 席ずつペインができるのを待ってから次を足す（続けて label すると足される順が入れ替わった）。
全席が木に載ってから、`layout.resize` で幅を決める。決めるのは、ルートの row の直下がすべて端末で、先頭が design・orchestrator のときだけである。

`terminal.keep --place right|down` は採らない。基準が focus 中のペインで、基準を指す引数が無い（`terminal.keep` の引数は `terminal` と `place` だけ）ため、
置くたびに focus が design のペインへ移り、user が別の space を見ていても画面が動いた。`terminal.show --pane` も focus を動かした。
`pane.split --pane` は focus を動かさないが、アプリが新しい端末を作るので、`hc run --parent` で起こした席を取り込めない（親が `null` になる）。
代わりに、implementation と review を縦に重ねる分割は作れない。上流では focus を動かさない指定が `space.new`・`tab.new` に入った
（herdrdev/herdr-app の PR #602）。`pane.split`・`terminal.open`・`terminal.keep` は未対応で、#883 が未解決である。

分割の木と重みは `hc connect` の `doc.get {name:"herdr-app"}` で読める。Herdr app が開いていなければ、席は動くがペインには出ない。

## 席のセッション

席は単位（design から来た 1 件の仕事）ごとに新しいセッションで始め、単位の中（実装 → レビューの指摘 → 修正）は同じセッションで続ける。
修正の往復では直前の文脈が効き、単位をまたぐと前の単位の文脈が雑音になり、トークンを使い、圧縮で古い指示と新しい指示が混ざるためである。
仕事の正しさは指示書が持ち、同じセッションを続けるのは読み直しを省く最適化に過ぎない。

`tell --envelope` が指示書の名前 `<unit>-<role>-<n>.md` から単位を取り、席ごとに最後の単位を `<team>/seats.json` に記録する。
単位が変わったとき（記録の無い `up` 直後の席も）だけ、送る前に席を切り替える。単位の worktree（`~/herdr/workspaces/<repo>/<unit>`）が
あればそこで `restart` し、無ければ `config/kind-flags.json` の `new_session` を行う。orchestrator のセッションは切らない（design との約束を持つ）。

## worktree と起動し直し

worktree は Orca と同じく専用の場所 `~/herdr/workspaces/<repo>/<unit>` に置き、席は単位ごとにその worktree で起動し直す。
作業ディレクトリが worktree になるので、Codex の sandbox がそこへ書け、`git`・相対パス・devshell（起動時の `.envrc` を agent-switch の shim が読む）がそのまま効く。
席を repo の隣の worktree で動かしていた ararat では、Codex が新しい worktree に書けず止まった（2026-11-06）。

- 初めてのフォルダでは claude も Codex も信頼の確認を出す。親のディレクトリを信頼しても、下の git の作業ツリーでは改めて出る。
  Codex は起動時の `-c projects."<path>".trust_level` でも消えない（2026-11-06 に確かめた）。そこで `restart` は、
  `~/herdr/workspaces` の下（skill が作った worktree）に限って、`kind-flags.json` の `trust` のキーで確認に答える。それ以外の場所の確認は design が判断する
- 席の端末は user のふだんの login zsh（`zsh -il`）で、`up` も `restart` もそこへ `cd <dir> && <agent>` を送って agent を起動する。
  zsh なので nix-darwin の環境・agent-switch の shim・direnv の hook が通り、agent には devshell と `__NIX_DARWIN_SET_ENVIRONMENT_DONE` が渡る。
  agent のコマンドの login zsh は PATH を初期化し直さず、devshell が残る（2026-11-08 に確かめた）。素の bash（`--norc`）で起動していた間は、
  この印が無く、agent のコマンドの zsh が PATH を戻して devshell が消えた。
- `restart` は端末を作り直さず、同じ端末の中で agent だけを起動し直す。agent を止めると zsh が残るので、そこへ起動の行を送る。
  端末を作り直す方式では、古いペインが閉じる処理と新しいペインを置く処理が
  Herdr app の中で競合し、新しいペインが後から消えた（数回再現。止める前の端末がペインを持っていたときだけ起きた）
- `up` の配置はペインの無い席だけを足す。幅は `doc.get` の木で目標とずれているときだけ直す
- `worktree rm` は、ブランチが repo の今のブランチ（main）に入っていて、commit していない変更が無く、どの席もその worktree にいないときだけ消す。ブランチは `git branch -d` で消す

kind ごとの操作（2026-11-06、claude 2.1.316・codex 0.166.0・opencode 2.2.5 で、切り替え後に前の指示を答えられないことを確かめた）:

- `hc send` は、送り手の端末 ID（`HC_TERMINAL_ID`）があると本文を `<hc from="…">…</hc>` で囲む。囲まれた `/clear`・`/new` は
  コマンドとして効かず、普通の文として届く。`new_session` の `send` は ID を外して送る
- claude: `/clear`
- codex: `/new`。git の作業ツリーでは「Where should the new conversation run?」が出るので Enter（今の worktree）を押す
- opencode: `ctrl+x` → `w` で今のタブを閉じる。最後のタブを閉じるとホーム画面に戻り、次の入力で新しいタブが 1 つできる。
  OpenCode は開いたセッションのタブを作業ディレクトリごとに `~/.local/state/opencode/latest/tui/tabs.json` に残し、起動のたびに開き直す。
  `/new`（`ctrl+x n`）はタブを足すので使わない。Orca 版のチームで仕事ごとに `/new` を送り、ararat のタブが 32 個に増えた

## kind の選び方（2026-11-05）

- **claude**・**codex**（0.166.0）・**opencode**（2.2.5）は、どれも OSC 7501 で状態（idle・working・done）を報告した。
  報告しない agent は `hc wait` で終わりを判定できないので、席にしない。
- codex のアカウントは `CODEX_HOME=$HOME/.codex-<account>` で渡す（`env CODEX_HOME=… codex` なので、zsh の関数 `cx`・`codex` ではなく
  PATH 上の agent-switch の shim が起動する）。claude は env を付けないので、席の zsh では agent-switch の関数 `claude` が起動する。
- opencode の model は `OPENCODE_CONFIG_CONTENT` で渡す。`#max` などの variant（effort）が効くかは確かめていない
  （`opencode debug config` で env 側の variant が落ちて見えた）。
