---
name: twscrape
description: >
  X（旧 Twitter）の GraphQL API をスクレイプして検索・ユーザー情報・タイムライン等を取得するスキル。
  twscrape は Nix でグローバルにインストール済み（darwin-switch 後）。
  「X を検索して」「ツイートを集めて」「ユーザーのタイムラインを取得して」などの場面で発動。
  アカウント登録が必要なため、初回は setup セクションを確認すること。
allowed-tools: Bash(twscrape:*), Bash(python3:*)
---

# twscrape スキル

X（旧 Twitter）の内部 GraphQL API を使って検索・収集を行う。

## 前提

- `twscrape` コマンドは Nix でグローバルインストール済み（`darwin-switch` 後に有効）
- X アカウントが少なくとも1つ必要（専用サブアカウント推奨）
- アカウント DB は SQLite で `~/.local/share/twscrape/accounts.db` に保存される

## アカウントのセットアップ（初回のみ）

```bash
# アカウントを追加（メール認証なし設定推奨）
twscrape add_accounts - <<'EOF'
username:password:email@example.com:emailpassword
EOF

# ログイン（セッション確立）
twscrape login_all
```

ログイン済みアカウントを確認：
```bash
twscrape accounts
```

## よく使うコマンド

### 検索

```bash
# キーワード検索（最新順）
twscrape search "検索キーワード" --limit=50

# Top タブ（エンゲージメント順）
twscrape search "キーワード" --limit=50 --tabs=Top

# メディア付きツイートのみ
twscrape search "キーワード" --limit=50 --tabs=Media
```

### ユーザー情報

```bash
# ユーザー名からプロフィール取得
twscrape user_by_login elonmusk

# ユーザーのタイムライン取得（最大 3200 件）
twscrape user_tweets <user_id> --limit=100
```

### ツイート詳細

```bash
# ツイート ID から詳細取得
twscrape tweet_details <tweet_id>

# リプライツリー
twscrape tweet_replies <tweet_id> --limit=50
```

### トレンド

```bash
twscrape trends news
twscrape trends trending
```

## Python API として使う場合

```python
import asyncio
from twscrape import API

async def main():
    api = API()  # accounts.db を自動参照
    async for tweet in api.search("機械学習", limit=20):
        print(tweet.id, tweet.user.username, tweet.rawContent)

asyncio.run(main())
```

## 出力形式

デフォルトは JSON（1行1ツイート）。パースして使う：

```bash
twscrape search "AI" --limit=10 | python3 -c "
import sys, json
for line in sys.stdin:
    t = json.loads(line)
    print(t['user']['username'], t['rawContent'][:80])
"
```

## 注意事項

- レート制限: 15分ごとにリセット。`user_tweets` は最大 3200 件まで
- アカウントは専用のサブアカウントを使う（BAN リスク軽減）
- X の ToS 上はグレーゾーン。研究・個人利用の範囲で使う
- アカウントがレート制限に引っかかると twscrape が自動で次のアカウントに切り替える
