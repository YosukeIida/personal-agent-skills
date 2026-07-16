# Nix の保守

## Nix GC（ガベージコレクション）

```bash
nix-collect-garbage -d   # 古い世代も含めて全削除
```

`-d` を付けると darwin-rebuild のロールバックはできなくなる（問題なければ OK）。

## nixpkgs にパッケージが存在するか確認する方法

`nix search nixpkgs <package>` はレジストリのキャッシュを参照するため、
flake.lock でピンしたバージョンと一致しないことがある。正確に確認するには：

```bash
# Web（確実・手軽）
# https://search.nixos.org/packages → チャンネルを "unstable" にして検索

# CLI（flake.lock のピンに対して確認）
nix eval nixpkgs#<attribute>.pname   # 例: nix eval nixpkgs#python3Packages.twscrape.pname
```
