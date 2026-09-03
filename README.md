# personal-agent-skills

Yosuke の汎用 Claude Code / Codex skills 集。

もともと [dotfiles](https://github.com/YosukeIida/dotfiles) の `agents/skills/` に
置いていた汎用 skill 群をこのリポジトリに分離した。個人ワークフロー専用・非公開の skill は
別の private overlay リポジトリに残しているため、ここにあるのは他者にも役立つ・公開できる
skill のみ。

## レイアウト

リポジトリ直下に `<skill-name>/SKILL.md` を置く root-level レイアウト。

```
personal-agent-skills/
├── browser-use/
│   └── SKILL.md
├── ...
└── README.md
```

## インストール方法

他者がこのリポジトリの skill を利用する場合は `gh skill` コマンドで個別にインストールできる。

```bash
gh skill install YosukeIida/personal-agent-skills <skill-name> --agent claude-code --scope user
```

例:

```bash
gh skill install YosukeIida/personal-agent-skills commit --agent claude-code --scope user
```

## skill 一覧

| skill | 概要 |
|---|---|
| [browser-use](browser-use/SKILL.md) | Direct browser control via CDP for web interaction: automation, scraping, testing, screenshots, and site/app work |
| [cc-launch-cmux-workspace](cc-launch-cmux-workspace/SKILL.md) | Launch Claude Code in a new cmux terminal workspace for a specified repository or path |
| [cmux](cmux/SKILL.md) | End-user control of cmux topology and routing (windows, workspaces, panes/surfaces, focus, moves, reorder, identify, trigger flash) |
| [cmux-browser](cmux-browser/SKILL.md) | End-user browser automation with cmux |
| [cmux-customization](cmux-customization/SKILL.md) | Customize cmux for an end user (actions, layouts, shortcuts, notifications, etc.) |
| [cmux-diagnostics](cmux-diagnostics/SKILL.md) | Run end-user cmux diagnostics (hooks, notifications, session restore, health check) |
| [cmux-markdown](cmux-markdown/SKILL.md) | Open markdown files in a formatted viewer panel with live reload |
| [cmux-md-katex](cmux-md-katex/SKILL.md) | 数式入り markdown ファイルを cmux のブラウザペインで KaTeX 描画してプレビューする |
| [cmux-settings](cmux-settings/SKILL.md) | View and edit cmux settings in `~/.config/cmux/cmux.json` |
| [cmux-workspace](cmux-workspace/SKILL.md) | Work inside the current cmux workspace and terminal |
| [codex-pr-review](codex-pr-review/SKILL.md) | GitHub PR を codex exec で系統的にレビューし、批判的トリアージを経て修正まで回す |
| [cognitive-pattern-extractor](cognitive-pattern-extractor/SKILL.md) | 他者の思考パターンを抽出し、再現可能な skill ファイルとして構造化するメタスキル |
| [commit](commit/SKILL.md) | 変更を conventional commits 規約でコミットする |
| [design-deliberation](design-deliberation/SKILL.md) | 妥当な答えが複数あり得る難しい決定のための Claude の進め方（設計選択・トレードオフの検討） |
| [devshell-setup](devshell-setup/SKILL.md) | Nix devshell を新しいリポジトリに追加・確認・保守する |
| [eval-audit-and-sweep](eval-audit-and-sweep/SKILL.md) | LLM 評価スイートの品質・信頼性を監査する、またはモデル/推論パラメータのスイープでコスト対品質を最適化する |
| [grant-figure-assets](grant-figure-assets/SKILL.md) | Create reusable monochrome figure assets for Japanese academic grant proposals such as JSPS DC1 |
| [herdr](herdr/SKILL.md) | Control herdr from inside it — manage workspaces, tabs, panes, agents via a local unix socket |
| [install-skill](install-skill/SKILL.md) | Install a Claude Code `.skill` file into dotfiles |
| [latex-devkit](latex-devkit/SKILL.md) | latex-devkit を使って LaTeX を Docker でビルドする |
| [math-study-note](math-study-note/SKILL.md) | 研究の数理（測定設計・定理・手法の破れ）を、数式を追って理解できる学習用ノート（md 正本 + KaTeX 図解 HTML）に再構成する |
| [overleaf-review-fetch](overleaf-review-fetch/SKILL.md) | Overleaf プロジェクトのレビューパネル（インラインコメント）を取得して Markdown として保存する |
| [research-study-guide](research-study-guide/SKILL.md) | 研究プロジェクトの成果物から、分野を知らない学生向けの学習用教材ドキュメント群を MD ファイルで生成する |
| [twscrape](twscrape/SKILL.md) | X（旧 Twitter）の GraphQL API をスクレイプして検索・ユーザー情報・タイムライン等を取得する |

各 skill の詳細なトリガー条件・使い方は各ディレクトリの `SKILL.md` を参照。
