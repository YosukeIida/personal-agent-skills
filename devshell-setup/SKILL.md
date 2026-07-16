---
name: devshell-setup
description: >
  Nix devshell を新しいリポジトリに追加・確認・保守するスキル。
  「devshell 追加して」「.envrc 作って」「direnv 設定して」「devshell が効いていない」
  「nix の python / uv が使われているか確認して」「nixpkgs にパッケージがあるか確認して」
  「nix GC して」などの場面で使う。テンプレートは dotfiles/templates/（python-uv / node）。
allowed-tools: Bash(cp:*), Bash(mkdir:*), Bash(direnv:*), Bash(which:*), Bash(echo:*)
---

# Nix devshell のセットアップと確認

## 新しい repo に devshell を追加する

### 標準テンプレート（uv + Node.js）

Claude Code を使う repo はこれを使う。Python (uv) と Node.js (npm) の両方が入る。

```bash
cd ~/workspace/github.com/<org>/<repo>
mkdir -p nix
cp ~/workspace/github.com/YosukeIida/dotfiles/templates/python-uv/nix/flake.nix nix/
cp ~/workspace/github.com/YosukeIida/dotfiles/templates/python-uv/nix/flake.lock nix/
echo 'use flake ./nix' > .envrc
direnv allow
```

`nix flake init -t` は使わない（`~/.config/nix-darwin` が存在しないため手動コピーで対応）。

### テンプレートの場所

`~/workspace/github.com/YosukeIida/dotfiles/templates/`
- `python-uv/` : Python 3.13 + uv + Node.js 22
- `node/`      : Python 3.13 + uv + Node.js 22（同じ内容）

### 生成されるファイル構成

```
<repo>/
├── nix/
│   ├── flake.nix    # devshell の定義（git 管理する）
│   └── flake.lock   # nixpkgs のバージョン固定（git 管理する）
└── .envrc           # "use flake nix" の1行
```

`cd` するだけで direnv が自動的に devshell を有効化する。

### devshell に含まれるもの

| ツール | バージョン |
|---|---|
| Python | 3.13 |
| uv | latest |
| Node.js | 22 |
| npm | Node.js に付属 |

`UV_PYTHON_DOWNLOADS = "never"` が設定されているので、uv は nix の Python を使う。

### flake を nix/ サブディレクトリに置く理由

`use flake path:.`（リポジトリ全体）だと git tree が dirty のとき毎回全ファイルを
nix store にコピーするため起動が遅くなる。`nix/` に置くことで対象が2ファイルだけになり高速化される。

## devshell が有効かを確認する手順

プロジェクトに `.envrc` がある場合、作業前に以下を確認する：

```bash
# direnv の状態を確認
direnv status
# "Found RC" かつ "Loaded" になっていれば有効

# nix の python / uv が使われているか確認
which python3   # /nix/store/... → OK
which uv        # /nix/store/... → OK
```

有効でない場合は `direnv allow` を実行してから作業を開始する：

```bash
direnv allow
```

devshell が起動していない状態でパッケージが必要な場合は `uvx` を使う。

## Nix の保守（GC・nixpkgs 確認）

Nix GC（世代の掃除）と nixpkgs にパッケージが存在するかの確認方法は
[references/nix-maintenance.md](references/nix-maintenance.md) を参照。

## CI / pre-commit の雛形

新規リポジトリに CI やコミット前チェックを入れる場合は dotfiles のテンプレートを使う:

- GitHub Actions（lint + test 最小構成）:
  `dotfiles/templates/github-workflows/ci-python-uv.yml` → `<repo>/.github/workflows/ci.yml`
- lefthook（ruff チェック + conventional commits 検査）:
  `dotfiles/templates/lefthook.yml` → `<repo>/lefthook.yml` にコピーして `lefthook install`
