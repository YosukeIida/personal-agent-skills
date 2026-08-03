# ロールごとの作業ディレクトリを worktree で用意する

ロールは互いに別ディレクトリで動く（`intent-cli guide orchestrator-thread` の role-folder 規則。
`One role = one folder`）。このファイルは**そのディレクトリをどう用意するか**だけを扱う。
ロールが何をするかは扱わない（[boundaries.md](boundaries.md)）。

## 公式は clone、ここでは worktree

公式ガイドが手順として書いているのは clone である。

```bash
git clone https://github.com/<owner/host-repo>.git <workspace-root>/<Project>Orchestrator
git clone https://github.com/<owner/host-repo>.git <workspace-root>/<Project>Review
git clone https://github.com/<owner/repo>.git      <workspace-root>/<Project>Implementation
```

ただし実体としては worktree も明示的に許容されている。

> host / orchestrator / implementation / review paths — each role runs from
> its own folder, clone, **or worktree**

**host metadata と実装コードが同じ repo にある構成なら worktree で用意できる。**
clone だとプロジェクト数 × ロール数だけ clone が増えるが、worktree なら新規 clone はゼロになる。
公式が worktree について詳しく書いているのは *unit ごとの一時 worktree* の文脈だけなので、
role folder を worktree にする場合の注意点は以下を自分で担保する必要がある。

## レイアウト規約

```
<teams-root>/<project>/host     metadata ブランチ。metadata を読むロールの cwd
<teams-root>/<project>/impl     実装の起点。detached HEAD。実装ロールの cwd
```

- `<teams-root>` は**普段の作業ディレクトリの外**に置く（例: `~/.intent-teams`）。
  元 checkout の隣に置くと、プロジェクトを増やすたびに作業ディレクトリに兄弟 dir が生える。
- 構造は公式の `<workspace-root>/<Project><Role>` と同じで、実体を clone から worktree に、
  命名を `<project>/<role>` の階層に変えただけ。

作り方:

```bash
git -C <main-checkout> worktree add          <teams-root>/<project>/host <metadata-branch>
git -C <main-checkout> worktree add --detach <teams-root>/<project>/impl <base-branch>
```

## impl を detached にするのは必須

git は**同一ブランチを複数の worktree に checkout できない**。base ブランチ（`main` 等）は
元の checkout が持っているので、impl worktree で同じブランチを checkout しようとすると失敗する。
detached なら制約に当たらず、そこから作業ブランチを切れる。

detached での注意が1つ: `git pull` が使えない。代わりに

```bash
git fetch origin <base-branch> && git reset --hard origin/<base-branch>
```

これは公式の child-loop 手順（`git fetch --all --prune` → dirty なら `reset --hard`）と一致する。
公式が automation worktree を前提に書いているためで、偶然ではない。

## 同一ブランチ衝突（worktree 構成で必ず踏む1箇所）

実装ロールが作業ブランチを impl worktree に持っている間、**そのブランチ名**を別の worktree に
出すと失敗する。公式のコマンド形（`git worktree add <path> <branch>`）にローカルブランチ名を
渡した場合がこれに当たる。

```
$ git worktree add <path> <branch>
fatal: '<branch>' is already used by worktree at '<impl>'
```

**一時 worktree には remote-tracking ref を渡す。** ローカルブランチ名ではない。

```bash
git worktree add --detach <path> origin/<branch>   # 成功する
```

実測（2026-08）: `worktree.guessRemote` が未設定（既定 false）なら、`origin/<branch>` 指定で
`--detach` を書かなくても自動的に detached になる。ただし `guessRemote=true` な環境でも
安全なので明示しておく。

- **`gh pr checkout` は使わない。** ローカルブランチを作るので、まさにこの衝突を起こす。
- remote ref から出すのは制約回避ではなく本来の姿でもある。見るべきは origin に push された
  内容で、ローカルブランチは未 push の commit を含みうる別物である。

## 一時 worktree の置き場所はこの skill が決めない

unit ごとの一時 worktree の root は intent-cli 側の設定（`[project] worktree_root`）が正本。
skill はそこを触らない。担保すべきことが1つだけある:

**managed root は git-ignored でなければならない。** 追跡されていると、worktree を1本切った
だけで各 cwd の `git status` に untracked が現れ、Preflight の「全 cwd が clean」が落ちる。

## 配備前に確認すること

**リポジトリ外を指す相対参照。** worktree を元 checkout と違う階層に置くと壊れる。

```bash
grep -rn --exclude-dir=.git -E '\.\./[a-z-]+/' <repo> | head
```

壊れた参照が見つかったら、(a) `<teams-root>/<project>/` に対象への symlink を1本張る、
または (b) その参照を必要としない前提で運用する（実装ロールが参照先を必要とするなら、
そもそもタスクの切り方が間違っている可能性を先に疑う）。

**絶対パスの埋め込み。** 壊れないが、元 checkout を指し続ける。ビルド・適用コマンドが
絶対パスで元 checkout を指す場合、**worktree では実機検証ができない**（編集は worktree、
コマンドが読むのは元 checkout）。その分担を受け入れるか、検証を別ロールに寄せるかを
配備前に決めておくこと。

```bash
grep -rln --exclude-dir=.git '<absolute-path-prefix>' <repo> | head
```

## metadata を読むロールをまとめる場合

metadata を読むロール（設計・調整・レビュー）は同じ metadata ブランチを要求する。
git は同一ブランチを複数 worktree に出せないので、**worktree 構成では原理的に1つの
`host` を共有することになる**（別々にしたければ clone に戻すしかない）。

`init` の `--review-repo` の既定は `--impl-repo` なので、host に寄せるなら明示すること:

```bash
scripts/herdr-team.sh init --team <name> \
  --host-repo <teams-root>/<project>/host \
  --impl-repo <teams-root>/<project>/impl \
  --review-repo <teams-root>/<project>/host
```

同一ディレクトリを複数ロールで共有できるかは session transport に依存する。
herdr-only なら identity は pane 単位なので共有できるが、agmsg では identity が
folder-scoped で衝突する。どちらのモードかは `intent-cli session-layer show` が正本。
