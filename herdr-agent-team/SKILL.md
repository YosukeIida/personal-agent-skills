---
name: herdr-agent-team
description: >-
  herdr-core（hc）と Herdr app で、役割ごとの agent の席（design / orchestrator / implementation / review）を
  design のタブに分割して並べ、orchestrator が hc send / hc wait で implementation / review に仕事を渡して結果を受け取る。
  席ごとに kind（claude / codex / opencode）・model・effort・アカウント（personal / labteam）を設定で選ぶ。
  「herdr でエージェントチームを起動して」「チームを立てて」「orchestrator を立てて」
  「席の状態を見せて」「チームを畳んで」などで使う。
  ※hc・Herdr app の一般操作は `hc --skill`・`herdr-app --skill` が担当する。
---

# herdr-agent-team

design（このセッション）が `up` で、design のタブを割って orchestrator・implementation・review のペインを並べる。
席は orchestrator の子の端末になる。orchestrator は親を持たず、design の端末は team 設定の `design` に記録する。

```
design のタブ:  design 45% | orchestrator 20% | implementation / review（上下）35%
<team>-2 のタブ: implementation-2 / review-2（上下）   ← レーン 2 以降は 1 レーン 1 タブ
```

役割の末尾の `-N` がレーンの番号で（無ければ 1）、1 レーンに置けるのは 2 席まで。
各席には label の `herdr-team.role=<role>` を付け、Herdr app のサイドバー（dotfiles の paddock・agents-tree）はこれを行の名前に出す。

## 使い方（design 側）

Herdr app のペインの中の端末（`HC_TERMINAL_ID` がある）から実行する。design のタブには design のペインだけがある状態で `up` する。

```bash
S=~/.claude/skills/herdr-agent-team/scripts/herdr-team.sh

bash $S init --team <T> --repo <repo>          # 既定の席で設定を作る
bash $S init --team <T> --repo <repo> --set implementation.model=gpt-6.1-terra --set implementation.effort=high \
  --set implementation-2.kind=opencode --set implementation-2.model=opencode-go/glm-5.3-flash
bash $S up --team <T>                          # 席を起動してペインに並べる（冪等。ペインの無い席だけを正しい位置に足す）
bash $S restart --team <T> --role <role> [--cwd <dir>]   # 席の agent を同じ端末・同じペインの中で起動し直す
bash $S worktree add --team <T> --unit <unit> --branch <b>   # ~/herdr/workspaces/<repo>/<unit> に作る
bash $S worktree rm --team <T> --unit <unit>   # main に入っていて変更が無く、席がいなければ消す

# 仕事を渡す: 指示をファイルに書き、パスだけを送る
bash $S tell --team <T> --role orchestrator --envelope ~/.config/herdr-agent-team/<T>/envelopes/<file>.md

bash $S status --team <T>
bash $S down --team <T>                        # このチームの端末だけを終える
```

orchestrator は起動時の最初の入力で `references/orchestrator.md` を読み、その手順（`tell` → `wait` → 確かめる → design に返す）で動く。
orchestrator からの報告は、design のこのセッションに `<hc from="…">` 付きの1行で届く。

## 既定の席（`config/defaults.json`）

| role | 端末の名前 | kind | model | effort | account |
|---|---|---|---|---|---|
| design | （このセッション） | | | | |
| orchestrator | `<T>-orchestrator` | claude | opus | medium | |
| implementation | `<T>-implementation` | codex | gpt-6.1-sol | medium | labteam |
| review | `<T>-review` | claude | opus | medium | |

設計とスコープは Claude（Opus）、実装は Codex、レビューは Claude（Opus）が受け持つ。実装の model は、公式の Codex の推奨（コードには Sol）に従う。
`--set <role>.<key>=<value>` で、無い役割（`implementation-2` など）を足すこともできる。
codex の席は `tier=fast` で Fast（`-c service_tier`）にできる。kind ごとの起動フラグは `config/kind-flags.json`（**`<kind> --help` で確かめてから足す**）。

## 知らないと踏むこと

1. **長い指示は必ずファイルにする。** 端末に送るのは `Read and execute the task envelope at <path>` の1行だけ。`tell` は 400 文字を超える行を断る。
2. **`up` は Herdr app のペインの中で実行する。** design のペインが見えないと、席はペインの無い端末のまま動く（サイドバーの木にも出ない）。
   design のタブに他のペインがあると、幅の比（45 / 20 / 35）が崩れる。
3. **design を閉じても orchestrator は残る**（`--no-parent`）。design への報告先は team 設定の `design` なので、
   design を別の端末で起こし直したら、その端末で `up` を実行する（動いている席はそのまま残り、報告先だけ変わる）。
4. **orchestrator を終えると席も終わる。** 席は orchestrator の子である。
5. **席のセッションは単位ごとに新しくなる。** `tell --envelope` は指示書の名前 `<unit>-<role>-<n>.md` の `<unit>` が前と変わると、
   送る前に席のセッションを新しくする（`references/boundaries.md` の「席のセッション」）。名前がこの形でない指示書は断る。
6. **ダイアログが出ている（blocked の）端末には送れない。** hc が断る。回り道はせず、画面を読んで design が判断する。
7. **worker は報告せずに止まることがある**（GLM、2026-11-04）。turn の終わりは core が orchestrator に知らせるので、
   orchestrator が画面を読んで促す。

## 置き場所

チームの設定・指示書・報告は `~/.config/herdr-agent-team/`（`<T>.json` と `<T>/envelopes/`）に置く。
skill 自体を試すときは、`HERDR_TEAM_CONFIG_DIR` を scratchpad に向けて `init` から `down` までを流し、`~/.config` に残さない。

## この skill が持たないもの

何を委譲するか・どう判断するか・intent-cli のワークフロー（`references/boundaries.md`）。
