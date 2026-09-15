#!/usr/bin/env bash
# herdr の1タブに宣言的なエージェントチームを配備する。
#
# このスクリプトは herdr の操作だけを行う。intent-cli のワークフロー（委譲・レビュー・
# publish 等）は一切扱わない — それは `intent-cli guide ...` が正本。
# 詳細は ../references/boundaries.md
#
# 使い方: herdr-team.sh <up|status|swap|ratio|doctor|down> --team <name> [...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# スキルが持つのは全リポジトリ共通の既定値だけ。リポジトリ固有の解決済み設定は
# ユーザーの設定ディレクトリに置く（公開 skill にローカルパスを持ち込まないため）。
DEFAULTS_FILE="$SCRIPT_DIR/../config/defaults.json"
# kind ごとの model/effort フラグ対応表（ツールの語彙。ロールの好みは defaults.json 側）
KIND_FLAGS_FILE="$SCRIPT_DIR/../config/kind-flags.json"
CONFIG_DIR="${HERDR_TEAM_CONFIG_DIR:-$HOME/.config/herdr-agent-team}"

# ---------- 基本ガード -------------------------------------------------------

die() { printf 'herdr-team: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

# herdr の agent 名はワークスペース非依存でグローバルに一意（実測で確認、2026-08）。
# bare role 名（"orchestrator" 等）だけでは複数チームが同居すると agent_name_taken で
# 衝突する。herdr 向けの識別子はチーム名で名前空間を切る。intent-cli 側の topology は
# --team/--role/--pane-id で識別するのでこれとは無関係（herdr 内の名前は渡していない）。
agent_ident() { printf '%s-%s' "$TEAM" "$1"; }

require_env() {
  [ "${HERDR_ENV:-}" = 1 ] || die "herdr の外では操作しない（HERDR_ENV=1 が必要）"
  command -v herdr >/dev/null || die "herdr が PATH にない"
  command -v jq >/dev/null || die "jq が必要"
  [ -n "${HERDR_PANE_ID:-}" ] || die "HERDR_PANE_ID が空。caller pane を特定できない"
  [ -n "${HERDR_WORKSPACE_ID:-}" ] || die "HERDR_WORKSPACE_ID が空"
}

# 空 id でコマンドを投げない。herdr は target 省略時にフォーカス中の pane を使うため、
# 別チームの pane を壊しうる（fail-closed）。
require_id() {
  local label="$1" value="${2:-}"
  case "$value" in
    ""|null) die "$label が解決できない。空の id でコマンドを投げない（fail-closed）" ;;
  esac
}

# 記録済み workspace 外の pane を触らない。
assert_same_workspace() {
  local pane_id="$1" ws="$2"
  case "$pane_id" in
    "$ws":*) : ;;
    *) die "pane $pane_id は workspace $ws の外。別チームを壊す恐れがあるので中止" ;;
  esac
}

# ---------- config -----------------------------------------------------------

CFG=""
TEAM=""
DRY_RUN=0
FORCE=0

load_config() {
  [ -n "$TEAM" ] || die "--team <name> が必要"
  CFG="$CONFIG_DIR/$TEAM.json"
  [ -f "$CFG" ] || die "team '$TEAM' の設定が無い: $CFG
  先に init で作ること:
    herdr-team.sh init --team $TEAM --host-repo <path> [--impl-repo <path>] [--review-repo <path>]"
  jq -e . "$CFG" >/dev/null 2>&1 || die "config が JSON として不正: $CFG"

  local sum
  # stack_below のあるロール（縦積みの子）は親と同じ列の幅を共有するので、
  # 横方向の ratio 合計には含めない（二重計上を避ける）。
  sum="$(jq '[.roles[] | select(.stack_below == null) | .ratio] | add' "$CFG")"
  # 合計が 1.0 から大きく外れていたら誤設定
  awk -v s="$sum" 'BEGIN{ if (s < 0.95 || s > 1.05) exit 1 }' \
    || die "ratio の合計が 1.0 から外れている（現在 ${sum}、stack_below の子ロールは除く）"
}

cfg_host_repo() { jq -r '.host_repo' "$CFG"; }
# intent-cli 0.31.0 は session-layer 系の全サブコマンドで --domain を要求する。
# 値の正本は host repo の .intent-cli/config.toml なので、init がそこから読んで
# team 設定に焼き込む（read_domain_from_host 参照）。
cfg_domain()    { jq -r '.domain // empty' "$CFG"; }
cfg_roles()     { jq -r '.roles[].role' "$CFG"; }
cfg_role_field() { jq -r --arg r "$1" --arg f "$2" '.roles[] | select(.role==$r) | .[$f] // empty' "$CFG"; }
cfg_caller_role() { jq -r '.roles[] | select(.caller==true) | .role' "$CFG"; }
cfg_launch_flags() { jq -r --arg r "$1" '.roles[] | select(.role==$r) | (.launch_flags // []) | join(" ")' "$CFG"; }

# このスキルが所有する pane 状態。down / doctor / ratio が pane を特定するために使う。
# 配送トポロジー（誰にどう届けるか）は持ち主が別で、intent-cli の
# `session-layer topology` が正本（record_topology 参照）。
panes_path() { printf '%s/%s.panes.json' "$CONFIG_DIR" "$TEAM"; }

# role の model / effort / launch_flags を、その kind の実フラグに変換して
# LAUNCH_ARGS 配列に入れる（`herdr agent start ... -- <ここ>` に渡す）。
#
# どの kind がどのフラグを取るかは config/kind-flags.json が持つ（ハードコードしない）。
# 新しい agent に乗り換えるときは、その表に1行足すだけでスクリプトは触らない。
# 権限モードは launch_flags に書く。起動後に修飾キーで切り替えるのは信頼できない。

# kind-flags.json に載っている kind か
kind_flags_known() {
  jq -e --arg k "$1" '.kinds | has($k)' "$KIND_FLAGS_FILE" >/dev/null 2>&1
}

# <kind> <model|effort> <model値> <effort値> → argv トークンを1行ずつ出す
kind_flag_tokens() {
  jq -r --arg k "$1" --arg f "$2" --arg m "$3" --arg e "$4" \
    '(.kinds[$k][$f] // [])
     | map(gsub("\\{model\\}"; $m) | gsub("\\{effort\\}"; $e))
     | .[]' "$KIND_FLAGS_FILE"
}

# トークンを LAUNCH_ARGS に積む（配列要素のまま積むので値に空白が入っても割れない）
append_kind_flags() {
  local kind="$1" field="$2" model="$3" effort="$4" tok
  while IFS= read -r tok; do
    [ -n "$tok" ] && LAUNCH_ARGS+=("$tok")
  done < <(kind_flag_tokens "$kind" "$field" "$model" "$effort")
}

build_launch_args() {
  local role="$1" kind="$2"
  local model effort flags
  model="$(cfg_role_field "$role" model)"
  effort="$(cfg_role_field "$role" effort)"
  flags="$(cfg_launch_flags "$role")"

  LAUNCH_ARGS=()
  if kind_flags_known "$kind"; then
    [ -n "$model" ]  && append_kind_flags "$kind" model  "$model" "$effort"
    [ -n "$effort" ] && append_kind_flags "$kind" effort "$model" "$effort"
  elif [ -n "$model$effort" ]; then
    note "! $role: kind '$kind' の model/effort フラグが config/kind-flags.json に無いので無視した。"
    note "  '$kind --help' で実フラグを確認して表に足すか、launch_flags に直接書くこと"
  fi
  # launch_flags はそのまま後ろに足す（空白区切り）
  if [ -n "$flags" ]; then
    local f
    for f in $flags; do LAUNCH_ARGS+=("$f"); done
  fi
}

# ---------- herdr 読み取り ---------------------------------------------------

pane_json() { herdr pane list --workspace "$HERDR_WORKSPACE_ID" 2>/dev/null; }

pane_field() { # pane_id field
  pane_json | jq -r --arg p "$1" --arg f "$2" '.result.panes[] | select(.pane_id==$p) | .[$f] // "-"'
}

layout_json() { herdr pane layout --pane "$HERDR_PANE_ID" 2>/dev/null; }

area_width() { layout_json | jq -r '.result.layout.area.width'; }

# caller と同じタブに属する pane を x 昇順、同じ列内（同じ x）は y 昇順で返す。
# 縦積み（stack_below）した列では、config の roles 配列も「親ロールの直後に
# 子ロールを書く」順になっているので、この順で cmd_adopt が対応づけられる。
tab_panes_ordered() {
  layout_json | jq -r '.result.layout.panes | sort_by([.rect.x, .rect.y]) | .[].pane_id'
}

pane_width() { layout_json | jq -r --arg p "$1" '.result.layout.panes[] | select(.pane_id==$p) | .rect.width'; }

# ---------- mapping ----------------------------------------------------------

# 既存 mapping からロールの pane を引く（無ければ空）
mapped_pane() {
  local mp; mp="$(panes_path)"
  [ -f "$mp" ] || return 0
  jq -r --arg r "$1" '.roles[$r].pane_id // empty' "$mp" 2>/dev/null || true
}

# mapping に記録された pane が実機にまだ存在するか
pane_exists() {
  [ -n "${1:-}" ] || return 1
  pane_json | jq -e --arg p "$1" 'any(.result.panes[]; .pane_id==$p)' >/dev/null 2>&1
}

# このスキルが所有する pane 状態を書き出す。role → pane / cwd / kind / 誰が作ったか。
# 「誰にどう届けるか」（resident / reader）は書かない — それは配送トポロジーであり
# 持ち主が別（record_topology）。ここに混ぜると同じ事実が2箇所に載る。
write_panes_state() { # role|pane_id|created の行を stdin で受ける
  local mp; mp="$(panes_path)"
  mkdir -p "$(dirname "$mp")"
  local tmp; tmp="$(mktemp)"
  {
    printf '{\n  "team": %s,\n  "workspace_id": %s,\n  "roles": {\n' \
      "$(jq -Rn --arg v "$TEAM" '$v')" "$(jq -Rn --arg v "$HERDR_WORKSPACE_ID" '$v')"
    local first=1 role pane created
    while IFS='|' read -r role pane created; do
      [ -n "$role" ] || continue
      [ $first -eq 1 ] || printf ',\n'
      first=0
      printf '    %s: { "workspace_id": %s, "pane_id": %s, "cwd": %s, "kind": %s, "created_by_skill": %s }' \
        "$(jq -Rn --arg v "$role" '$v')" \
        "$(jq -Rn --arg v "$HERDR_WORKSPACE_ID" '$v')" \
        "$(jq -Rn --arg v "$pane" '$v')" \
        "$(jq -Rn --arg v "$(cfg_role_field "$role" cwd)" '$v')" \
        "$(jq -Rn --arg v "$(cfg_role_field "$role" kind)" '$v')" \
        "$created"
    done
    printf '\n  }\n}\n'
  } >"$tmp"
  jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "pane 状態の生成に失敗（JSON 不正）"; }
  mv "$tmp" "$mp"
  note "pane 状態を書き出した: $mp"
}

# intent-cli の topology コマンドは `.intent-cli` を持つ cwd（host repo）から実行しないと
# `missing-host-state` で落ちる。このスキルは任意の cwd から呼ばれる（caller pane が
# host repo に居るとは限らない）ので、config の host_repo に移って実行する。
#
# --domain は 0.31.0 で全サブコマンド必須になった。呼び出し側が毎回書くと
# 付け忘れが起きるので、ここで一律に足す。
topology_cmd() {
  local domain; domain="$(cfg_domain)"
  [ -n "$domain" ] || { printf 'domain が team 設定に無い。init をやり直すこと\n'; return 1; }
  ( cd "$(cfg_host_repo)" 2>/dev/null || exit 1
    intent-cli session-layer topology --domain "$domain" "$@" 2>&1 )
}

# 記録が無いときの session-layer の既定は agmsg。agmsg はこの環境から撤去済みなので、
# 明示しないと配送が黙って死ぬ。record_topology の最後で毎回設定する。
set_session_layer_mode() {
  local domain out; domain="$(cfg_domain)"
  out="$( cd "$(cfg_host_repo)" 2>/dev/null || exit 1
          intent-cli session-layer set --domain "$domain" --team "$TEAM" \
            --mode herdr-only --write --format json 2>&1 )" || {
    note "! session-layer を herdr-only に設定できなかった:"
    note "  $(printf '%s' "$out" | head -3)"
    return 1
  }
  note "session-layer を herdr-only に設定した"
}

# 配送トポロジーを記録する。**形式の正本は intent-cli 側**（`session-layer topology`）で、
# このスキルは値を渡すだけ。自分で JSON を組まないので、CLI が形を変えても追随できる。
# intent-cli が無い環境ではスキップする（このスキルは herdr の配備だけで成立する）。
record_topology() {
  if ! command -v intent-cli >/dev/null 2>&1; then
    note "intent-cli が無いので配送トポロジーの記録はスキップ（pane 状態は保存済み）"
    return 0
  fi
  local role resident reader pane cwd kind model effort delivery out rc=0
  local domain; domain="$(cfg_domain)"
  for role in $(cfg_roles); do
    resident="$(cfg_role_field "$role" resident)"; : "${resident:=herdr}"
    model="$(cfg_role_field "$role" model)"
    effort="$(cfg_role_field "$role" effort)"
    local -a extra=()
    [ -n "$model" ]  && extra+=(--model "$model")
    [ -n "$effort" ] && extra+=(--reasoning-effort "$effort")
    if [ "$resident" = external ]; then
      reader="$(cfg_role_field "$role" reader)"
      : "${reader:=.intent-cli/events/${TEAM}.jsonl}"
      out="$(topology_cmd record --team "$TEAM" --role "$role" \
               --resident external --reader "$reader" \
               "${extra[@]}" --write --format json)" || rc=1
    else
      pane="$(mapped_pane "$role")"
      if [ -z "$pane" ] || [ "$pane" = "-" ]; then continue; fi
      cwd="$(cfg_role_field "$role" cwd)"
      kind="$(cfg_role_field "$role" kind)"
      # delivery_method: file-backed だと notify が封筒を
      # .intent-cli/tasks/<domain>/<team>/<task-id>-<nonce>.md に書いてから
      # 1行のポインタだけを pane へ送る。長文が pane 入力で欠ける事故
      # （orca #10416 と同種）を配送層で潰せるので、既定で付ける。
      delivery="$(cfg_role_field "$role" delivery_method)"
      : "${delivery:=file-backed}"
      out="$(topology_cmd record --team "$TEAM" --role "$role" \
               --resident herdr --workspace-id "$HERDR_WORKSPACE_ID" --pane-id "$pane" \
               --cwd "$cwd" --kind "$kind" --delivery-method "$delivery" \
               "${extra[@]}" --write --format json)" || rc=1
    fi
    # CLI は食い違う記録を fail closed で拒否する。勝手に直さず operator に上げる。
    if printf '%s' "$out" | jq -e '.conflict == true' >/dev/null 2>&1; then
      note "  ! ${role}: 既存の記録と食い違うため intent-cli が拒否した"
      note "    intent-cli session-layer topology show --domain ${domain} --team ${TEAM} で現在の記録を確認すること"
      rc=1
    fi
  done
  if [ "$rc" -eq 0 ]; then
    note "配送トポロジーを intent-cli に記録した（正本は CLI 側）"
  else
    note "! 配送トポロジーの記録に問題があった。上の指摘を解消すること"
  fi
  # 失敗は note で上げるだけにして呼び出し側は止めない（pane は既に立っており、
  # 記録の修復は operator の作業になるため）。
  set_session_layer_mode || true
  return 0
}

# ---------- サブコマンド: init -----------------------------------------------

HOST_REPO=""
IMPL_REPO=""
REVIEW_REPO=""
DOMAIN=""
declare -a KIND_OVERRIDES=()
declare -a RATIO_OVERRIDES=()
declare -a MODEL_OVERRIDES=()
declare -a EFFORT_OVERRIDES=()

abspath() { ( cd "$1" 2>/dev/null && pwd ) || die "ディレクトリが存在しない: $1"; }

# domain の正本は host repo の .intent-cli/config.toml の [project] domain。
# ここから読むことで、--domain の打ち間違いで intent-cli 側と食い違うのを防ぐ。
read_domain_from_host() {
  local f="$1/.intent-cli/config.toml"
  [ -f "$f" ] || return 1
  sed -n 's/^[[:space:]]*domain[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1
}

# リポジトリ固有のパスを解決して <config-dir>/<team>.json を生成する。
# 既定のロール構成・kind・比率は config/defaults.json（全リポジトリ共通）から取る。
cmd_init() {
  [ -n "$TEAM" ] || die "--team <name> が必要"
  [ -f "$DEFAULTS_FILE" ] || die "既定値が無い: $DEFAULTS_FILE"

  # host-repo の既定は cwd の git トップレベル
  if [ -z "$HOST_REPO" ]; then
    HOST_REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$HOST_REPO" ] || die "--host-repo を指定すること（cwd が git リポジトリでないため既定値を決められない）"
    note "host-repo を cwd から推定: $HOST_REPO"
  fi
  HOST_REPO="$(abspath "$HOST_REPO")"
  IMPL_REPO="$(abspath "${IMPL_REPO:-$HOST_REPO}")"
  REVIEW_REPO="$(abspath "${REVIEW_REPO:-$IMPL_REPO}")"

  [ "$REVIEW_REPO" != "$IMPL_REPO" ] || \
    note "! review と implementation が同じディレクトリです。ロールの分離が弱くなります（--review-repo で分けられます）"

  if [ -z "$DOMAIN" ]; then
    DOMAIN="$(read_domain_from_host "$HOST_REPO" || true)"
    [ -n "$DOMAIN" ] || die "domain を決められない。--domain <name> で渡すか、host repo で
  intent-cli intent init --domain <name> --target-repo <owner/repo> --write
を先に実行して .intent-cli/config.toml を用意すること: $HOST_REPO"
    note "domain を host repo の .intent-cli/config.toml から読んだ: $DOMAIN"
  fi

  mkdir -p "$CONFIG_DIR"
  local out="$CONFIG_DIR/$TEAM.json"
  local tmp; tmp="$(mktemp)"

  # 既定値の cwd_from を実パスに解決し、kind / ratio の上書きを適用する
  jq \
    --arg team "$TEAM" --arg domain "$DOMAIN" \
    --arg host "$HOST_REPO" --arg impl "$IMPL_REPO" --arg rev "$REVIEW_REPO" \
    --argjson kinds "$(printf '%s\n' "${KIND_OVERRIDES[@]:-}" | jq -Rn '[inputs | select(length>0) | split("=") | {(.[0]): .[1]}] | add // {}')" \
    --argjson ratios "$(printf '%s\n' "${RATIO_OVERRIDES[@]:-}" | jq -Rn '[inputs | select(length>0) | split("=") | {(.[0]): (.[1]|tonumber)}] | add // {}')" \
    --argjson models "$(printf '%s\n' "${MODEL_OVERRIDES[@]:-}" | jq -Rn '[inputs | select(length>0) | split("=") | {(.[0]): .[1]}] | add // {}')" \
    --argjson efforts "$(printf '%s\n' "${EFFORT_OVERRIDES[@]:-}" | jq -Rn '[inputs | select(length>0) | split("=") | {(.[0]): .[1]}] | add // {}')" \
    '{
       team: $team,
       domain: $domain,
       host_repo: $host,
       repos: { host: $host, implementation: $impl, review: $rev },
       roles: [ .roles[] | . as $r |
         {
           role: $r.role,
           kind: ($kinds[$r.role] // $r.kind),
           cwd: ({host:$host, implementation:$impl, review:$rev}[$r.cwd_from // "host"]),
           ratio: ($ratios[$r.role] // $r.ratio)
         }
         + (if $r.caller == true then {caller: true} else {} end)
         + (($models[$r.role] // $r.model)  | if . then {model: .}  else {} end)
         + (($efforts[$r.role] // $r.effort) | if . then {effort: .} else {} end)
         + (if $r.launch_flags then {launch_flags: $r.launch_flags} else {} end)
         # delivery_method: herdr 席の封筒をファイル経由にするか（既定 file-backed）。
         # 省略時の値は record_topology 側が持つ。
         + (if $r.delivery_method then {delivery_method: $r.delivery_method} else {} end)
         # resident: external のロールは pane 宛の送信ではなく events ファイルへの
         # 追記で受け取る。reader はチーム名から決まるのでここで実体化する。
         + (if $r.resident then {resident: $r.resident} else {} end)
         + (if $r.resident == "external"
              then {reader: ($r.reader // (".intent-cli/events/" + $team + ".jsonl"))}
              else {} end)
         # stack_below: このロールを親ロールの真下に縦積みする指定。横方向の ratio
         # 合計には含めない（親と同じ列の幅を共有するため）。
         + (if $r.stack_below then {stack_below: $r.stack_below} else {} end)
         + (if $r.stack_ratio then {stack_ratio: $r.stack_ratio} else {} end)
       ]
     }' "$DEFAULTS_FILE" >"$tmp"

  jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "設定の生成に失敗（JSON 不正）"; }

  local sum; sum="$(jq '[.roles[] | select(.stack_below == null) | .ratio] | add' "$tmp")"
  awk -v s="$sum" 'BEGIN{ if (s < 0.95 || s > 1.05) exit 1 }' \
    || { rm -f "$tmp"; die "ratio の合計が 1.0 から外れている（${sum}、stack_below の子ロールは除く）。--ratio で調整すること"; }

  if [ "$DRY_RUN" = 1 ]; then
    note "(dry-run) 生成される内容:"; cat "$tmp"; rm -f "$tmp"; return 0
  fi
  if [ -f "$out" ]; then
    note "! 既存の設定を上書きします: $out"
  fi
  mv "$tmp" "$out"
  note "設定を書き出した: $out"
  cat "$out"
}

# ---------- サブコマンド: status ---------------------------------------------

cmd_status() {
  load_config
  local mp; mp="$(panes_path)"
  note "team: $TEAM   workspace: $HERDR_WORKSPACE_ID   area: $(area_width)桁"
  note "mapping: $([ -f "$mp" ] && echo "$mp" || echo '(まだ無い)')"
  printf '\n%-16s %-10s %-8s %-9s %-6s %s\n' ROLE PANE KIND STATUS WIDTH CWD
  local role pane kind_cfg kind_live status width cwd_cfg cwd_live flag
  for role in $(cfg_roles); do
    pane="$(mapped_pane "$role")"
    if ! pane_exists "$pane"; then pane=""; fi
    kind_cfg="$(cfg_role_field "$role" kind)"
    cwd_cfg="$(cfg_role_field "$role" cwd)"
    if [ -n "$pane" ]; then
      kind_live="$(pane_field "$pane" agent)"
      status="$(pane_field "$pane" agent_status)"
      cwd_live="$(pane_field "$pane" cwd)"
      width="$(pane_width "$pane")"
      flag=""
      [ "$kind_live" = "$kind_cfg" ] || flag="$flag kind≠config($kind_cfg)"
      [ "$cwd_live" = "$cwd_cfg" ] || flag="$flag cwd≠config"
      printf '%-16s %-10s %-8s %-9s %-6s %s%s\n' \
        "$role" "$pane" "$kind_live" "$status" "${width:--}" "$cwd_live" "$flag"
    else
      printf '%-16s %-10s %-8s %-9s %-6s %s\n' "$role" "--" "$kind_cfg" "--" "--" "$cwd_cfg"
    fi
  done
}

# ---------- サブコマンド: adopt ----------------------------------------------

# 手で組んだ既存レイアウトを mapping に取り込む。
# caller と同じタブの pane を x 昇順に並べ、config の roles の順に対応づける。
# 作成者はこのスキルではないので created_by_skill=false（down で閉じない）。
cmd_adopt() {
  load_config
  local -a panes=() roles=()
  local p r
  while read -r p; do [ -n "$p" ] && panes+=("$p"); done < <(tab_panes_ordered)
  while read -r r; do [ -n "$r" ] && roles+=("$r"); done < <(cfg_roles)

  [ "${#panes[@]}" -eq "${#roles[@]}" ] || die "pane 数(${#panes[@]}) と config の role 数(${#roles[@]}) が一致しない。
  現在の pane: ${panes[*]}
  config の role: ${roles[*]}
  手で揃えてから adopt するか、config を直すこと"

  local caller_role; caller_role="$(cfg_caller_role)"
  local -a lines=()
  local i
  for (( i=0; i<${#roles[@]}; i++ )); do
    assert_same_workspace "${panes[$i]}" "$HERDR_WORKSPACE_ID"
    if [ "${roles[$i]}" = "$caller_role" ] && [ "${panes[$i]}" != "$HERDR_PANE_ID" ]; then
      note "! 警告: caller role '${roles[$i]}' の位置が caller pane($HERDR_PANE_ID) ではなく ${panes[$i]} です"
      note "  config の roles の並び順が画面の左右の並びと一致しているか確認してください"
    fi
    note "adopt: ${roles[$i]} <- ${panes[$i]} ($(pane_width "${panes[$i]}")桁)"
    [ "$DRY_RUN" = 1 ] || herdr pane rename "${panes[$i]}" "${roles[$i]}" >/dev/null 2>&1 || true
    lines+=("${roles[$i]}|${panes[$i]}|false")
  done

  if [ "$DRY_RUN" = 1 ]; then note "(dry-run) pane 状態とトポロジーは書かない"; return 0; fi
  printf '%s\n' "${lines[@]}" | write_panes_state
  record_topology
  note ""
  cmd_status
}

# ---------- サブコマンド: ratio ----------------------------------------------

# 幅の下限。これを割ると承認ダイアログが読めなくなるので、下回る計画は実行しない。
# 優先順: 環境変数 > team config の min_pane_cols > 既定 40。
# team config に持たせられるのは、画面の広さがチームの運用環境ごとに違うため
# （ノート単体で回すチームと外部モニタで回すチームで下限が同じである必要はない）。
min_pane_cols() {
  local v
  if [ -n "${HERDR_TEAM_MIN_PANE_COLS:-}" ]; then
    printf '%s' "$HERDR_TEAM_MIN_PANE_COLS"; return 0
  fi
  v="$(jq -r '.min_pane_cols // empty' "$CFG" 2>/dev/null || true)"
  printf '%s' "${v:-40}"
}

# ロールの目標幅（桁）= 領域幅 × ratio
target_cols() {
  awk -v a="$(area_width)" -v r="$(cfg_role_field "$1" ratio)" 'BEGIN{printf "%d", a*r}'
}

# 連続 split で作った pane は「入れ子の二分木」になる（p1 | (pA | (pB | pC))）。
# ここで実測して分かった resize の性質（2026-08 herdr で確認）:
#   - `resize --pane X --direction D` は X が D 方向に伸びて広くなる（縮まない）
#   - `--amount` は **その分割ノードのローカル container 幅** に対する比率。
#     最外の境界だけは container が領域全体なので全体幅比と一致して見える。
#     内側の境界で全体幅を分母にすると効き量が足りず、反復が発散して
#     pane が 0〜5 桁まで潰れる（実際に踏んだ）。
# よって外側の境界から順に、そのつど残り幅を container として計算する。
cmd_ratio() {
  load_config
  local aw; aw="$(area_width)"
  require_id "area width" "$aw"

  local -a order=() targets=()
  local role pane stack_below
  for role in $(cfg_roles); do
    stack_below="$(cfg_role_field "$role" stack_below)"
    # 縦積みロールは親と同じ列の幅を共有するだけなので、横方向の境界調整には含めない
    [ -z "$stack_below" ] || continue
    pane="$(mapped_pane "$role")"
    pane_exists "$pane" || { note "ratio: $role が未配備なのでスキップ"; continue; }
    order+=("$pane")
    targets+=("$(awk -v a="$aw" -v r="$(cfg_role_field "$role" ratio)" 'BEGIN{printf "%d", a*r}')")
  done
  local n=${#order[@]}
  [ "$n" -ge 2 ] || { note "ratio: 対象 pane が 2 未満なので何もしない"; return 0; }

  # 下限ガード: 目標が下限を割るなら実行しない（潰れた pane を作らない）
  local i minc; minc="$(min_pane_cols)"
  for (( i=0; i<n; i++ )); do
    if [ "${targets[$i]}" -lt "$minc" ]; then
      die "目標幅 ${targets[$i]}桁 (${order[$i]}) が下限 ${minc}桁 を割る。
  この幅では承認ダイアログが読めない。ウィンドウを広げるか、config の ratio を見直すこと
  （下限は team config の min_pane_cols か、環境変数 HERDR_TEAM_MIN_PANE_COLS で変えられる）"
    fi
  done

  local cur tgt delta amount iter container j prev
  for (( i=0; i<n-1; i++ )); do
    # この境界の container = order[i] 以降の実測幅の合計
    container=0
    for (( j=i; j<n; j++ )); do container=$(( container + $(pane_width "${order[$j]}") )); done

    prev=-1
    for (( iter=0; iter<10; iter++ )); do
      cur="$(pane_width "${order[$i]}")"
      tgt="${targets[$i]}"
      delta=$(( tgt - cur ))
      [ "${delta#-}" -le 2 ] && break
      # 発散・停滞したら打ち切る（前回より改善していなければ止める）
      if [ "$prev" -ne -1 ] && [ "${delta#-}" -ge "$prev" ]; then
        note "! ratio: ${order[$i]} が収束しない（残差 ${delta}桁）。この境界は中断する"
        break
      fi
      prev="${delta#-}"
      amount="$(awk -v d="${delta#-}" -v c="$container" 'BEGIN{ if (c<=0) c=1; printf "%.4f", d/c }')"
      if [ "$DRY_RUN" = 1 ]; then
        if [ "$delta" -gt 0 ]; then note "would: resize ${order[$i]} right $amount (container ${container}桁)"
        else note "would: resize ${order[$((i+1))]} left $amount (container ${container}桁)"; fi
        break
      fi
      if [ "$delta" -gt 0 ]; then
        herdr pane resize --pane "${order[$i]}" --direction right --amount "$amount" >/dev/null
      else
        herdr pane resize --pane "${order[$((i+1))]}" --direction left --amount "$amount" >/dev/null
      fi
    done
  done

  note "ratio 適用後:"
  local warn=0
  for (( i=0; i<n; i++ )); do
    cur="$(pane_width "${order[$i]}")"
    note "  ${order[$i]}  ${cur}桁 (目標 ${targets[$i]})"
    [ "$cur" -ge "$(min_pane_cols)" ] || warn=1
  done
  [ "$warn" -eq 0 ] || note "! 下限 $(min_pane_cols)桁 を割った pane がある。ウィンドウ幅か config を見直すこと"
}

# ---------- サブコマンド: up -------------------------------------------------

cmd_up() {
  load_config
  local caller_role; caller_role="$(cfg_caller_role)"
  [ -n "$caller_role" ] || die "config に caller:true のロールが無い（自分の pane を割り当てられない）"

  local -a lines=()
  local prev_pane="$HERDR_PANE_ID" prev_role=""
  local role pane kind cwd created stack_below

  for role in $(cfg_roles); do
    kind="$(cfg_role_field "$role" kind)"
    cwd="$(cfg_role_field "$role" cwd)"
    stack_below="$(cfg_role_field "$role" stack_below)"

    if [ "$role" = "$caller_role" ]; then
      pane="$HERDR_PANE_ID"; created=false
      note "$role: caller pane $pane を割り当て（agent は起動しない）"
      # agent を起動しないロールには logical role 名が付かない。名前が無い agent は
      # notify の宛先解決から漏れる（「logical role が見つからない」で fail closed）ため、
      # rename だけは caller にも当てる。
      if [ "$DRY_RUN" != 1 ]; then
        herdr agent rename "$pane" "$(agent_ident "$role")" >/dev/null 2>&1 \
          || note "  ! caller pane の rename に失敗（notify の宛先解決から漏れる可能性）"
        # pane label（UI 表示用、agent identity とは別物）も非 caller ロールと同様に付ける。
        # これを忘れると label が null のままになり、UI は agent kind（例: "claude"）に
        # フォールバック表示する（実測で踏んだ）。
        herdr pane rename "$pane" "$role" >/dev/null 2>&1 || true
      fi
    else
      pane="$(mapped_pane "$role")"
      if pane_exists "$pane"; then
        created="$(jq -r --arg r "$role" '.roles[$r].created_by_skill // false' "$(panes_path)")"
        note "$role: 既存 pane $pane を再利用"
      elif [ -n "$stack_below" ]; then
        # 縦積み: 親ロール（$stack_below）の pane の真下に split する。
        # 横方向の連結（prev_pane/prev_role）には加わらない — 親と同じ列の幅を
        # 共有するだけで、次のロールは親の pane から続けて右に split させる。
        [ -d "$cwd" ] || die "$role の cwd が存在しない: $cwd"
        local parent_pane stack_ratio
        parent_pane="$(mapped_pane "$stack_below")"
        pane_exists "$parent_pane" || \
          parent_pane="$(printf '%s\n' "${lines[@]:-}" | awk -F'|' -v r="$stack_below" '$1==r{print $2}' | tail -1)"
        stack_ratio="$(cfg_role_field "$role" stack_ratio)"; : "${stack_ratio:=0.5}"
        if [ "$DRY_RUN" = 1 ]; then
          note "would: pane split --pane ${parent_pane:-?} --direction down --ratio $stack_ratio --cwd $cwd   → $role (stack_below=$stack_below)"
          pane="(new:$role)"; created=true
        else
          require_id "$stack_below の pane（$role の縦積み先）" "$parent_pane"
          assert_same_workspace "$parent_pane" "$HERDR_WORKSPACE_ID"
          pane="$(herdr pane split --pane "$parent_pane" --direction down --ratio "$stack_ratio" \
                    --cwd "$cwd" --no-focus | jq -r '.result.pane.pane_id')"
          require_id "$role の新 pane" "$pane"
          herdr pane rename "$pane" "$role" >/dev/null 2>&1 || true
          created=true
          note "$role: pane $pane を作成（cwd=${cwd}, stack_below=${stack_below}, ratio=${stack_ratio}）"
        fi
      else
        [ -d "$cwd" ] || die "$role の cwd が存在しない: $cwd"
        # 分割時に --ratio を渡して一発で正確な幅にする（あとから resize で
        # 追い込む必要がない）。--ratio は「元 pane が保持する比率」で、
        # 分母はその分割ノードのローカル container = 分割元 pane の現在幅。
        # 分割元は直前ロールの pane なので、渡す比率は「直前ロールの目標幅 ÷ 分割元の現在幅」。
        local split_ratio="" prev_target prev_w
        if [ -n "$prev_role" ]; then
          prev_w="$(pane_width "$prev_pane" 2>/dev/null || true)"
          prev_target="$(target_cols "$prev_role")"
          if [ -n "$prev_w" ] && [ "$prev_w" -gt 0 ] 2>/dev/null; then
            split_ratio="$(awk -v t="$prev_target" -v w="$prev_w" 'BEGIN{ r=t/w; if(r<0.05)r=0.05; if(r>0.95)r=0.95; printf "%.4f", r }')"
          fi
        fi
        if [ "$DRY_RUN" = 1 ]; then
          # 実行時は新 pane が次の split 元になるので、その連鎖を表示に反映する
          note "would: pane split --pane $prev_pane --direction right${split_ratio:+ --ratio $split_ratio} --cwd $cwd   → $role"
          pane="(new:$role)"; created=true
        else
          require_id "split 元 pane" "$prev_pane"
          assert_same_workspace "$prev_pane" "$HERDR_WORKSPACE_ID"
          if [ -n "$split_ratio" ]; then
            pane="$(herdr pane split --pane "$prev_pane" --direction right --ratio "$split_ratio" \
                      --cwd "$cwd" --no-focus | jq -r '.result.pane.pane_id')"
          else
            pane="$(herdr pane split --pane "$prev_pane" --direction right \
                      --cwd "$cwd" --no-focus | jq -r '.result.pane.pane_id')"
          fi
          require_id "$role の新 pane" "$pane"
          herdr pane rename "$pane" "$role" >/dev/null 2>&1 || true
          created=true
          note "$role: pane $pane を作成（cwd=${cwd}${split_ratio:+, ratio=${split_ratio}}）"
        fi
      fi
    fi

    if [ -n "$stack_below" ]; then
      # 縦積みロールは横方向の連結を更新せず、次のロールは親 pane から続ける
      lines+=("$role|$pane|$created")
      continue
    fi
    prev_pane="$pane"; prev_role="$role"
    lines+=("$role|$pane|$created")
  done

  if [ "$DRY_RUN" = 1 ]; then
    note "(dry-run) pane 状態・トポロジーの記録と agent 起動はしない"
    return 0
  fi

  printf '%s\n' "${lines[@]}" | write_panes_state
  record_topology
  cmd_ratio

  # agent 起動（caller 以外、かつ agent が居ない pane だけ）
  local live flags
  local -a launched=()
  for role in $(cfg_roles); do
    [ "$role" = "$caller_role" ] && continue
    pane="$(mapped_pane "$role")"
    require_id "$role の pane" "$pane"
    assert_same_workspace "$pane" "$HERDR_WORKSPACE_ID"
    live="$(pane_field "$pane" agent)"
    if [ "$live" != "-" ] && [ -n "$live" ]; then
      note "$role: 既に $live が動いているので起動しない（入れ替えは swap を使う）"
      continue
    fi
    kind="$(cfg_role_field "$role" kind)"
    build_launch_args "$role" "$kind"
    local ident; ident="$(agent_ident "$role")"
    note "$role: herdr agent start $ident --kind $kind --pane $pane${LAUNCH_ARGS[0]+ -- ${LAUNCH_ARGS[*]}}"
    if [ "${#LAUNCH_ARGS[@]}" -gt 0 ]; then
      if herdr agent start "$ident" --kind "$kind" --pane "$pane" -- "${LAUNCH_ARGS[@]}" >/dev/null; then
        launched+=("$role")
      else
        note "  ! 起動に失敗（doctor で確認すること）"
      fi
    else
      if herdr agent start "$ident" --kind "$kind" --pane "$pane" >/dev/null; then
        launched+=("$role")
      else
        note "  ! 起動に失敗（doctor で確認すること）"
      fi
    fi
  done

  # 起動したロールだけ READY 判定を通す。起動報告は生存の証明ではないうえに、
  # 起動直後の agent は「検出はされるが宛先候補になれない」状態を取りうる（下記参照）。
  if [ "${#launched[@]}" -gt 0 ]; then
    note ""
    note "READY 判定（ping/ack）:"
    local r
    for r in "${launched[@]}"; do ready_ping "$r" || true; done
  fi

  note ""
  cmd_doctor
}

# ---------- READY 判定（ping/ack） -------------------------------------------

# 起動直後の agent は「herdr には検出されるが、外部からの配送の宛先候補になれない」
# 状態を取りうる（実測 2026-08: agent start 直後は running=false のままで、1回
# prompt を受けるまで宛先解決から漏れる）。cwd も kind も一致していて生存確認も
# 通るので、ping を送るまでこの状態を見分けられない。
#
# 送るのは短い ping ひとつだけで、作業内容には関与しない。
READY_PING_TEXT="READY 確認: 何も変更せず、稼働していることを1行だけ返してください。"

ready_ping() {
  local role="$1" ident pane
  ident="$(agent_ident "$role")"
  pane="$(mapped_pane "$role")"

  if ! herdr agent prompt "$ident" "$READY_PING_TEXT" >/dev/null 2>&1; then
    note "  [not-ready] ${role} — ping を送出できなかった（agent 名 ${ident} が解決できない）"
    ready_ping_hint "$pane"
    return 1
  fi

  # prompt が実際に届けば working に入る。入らないなら届いていない。
  if ! herdr agent wait "$ident" --until working --timeout 20000 >/dev/null 2>&1; then
    note "  [not-ready] ${role} — ping を送ったが working に遷移しない"
    note "              この状態では外部からの配送が届かない。原因を切り分けること:"
    ready_ping_hint "$pane"
    return 1
  fi

  # 応答して settled に戻るところまで見る（タイムアウトは失敗ではない）
  if herdr agent wait "$ident" --until idle --until "done" --until blocked --timeout 180000 >/dev/null 2>&1; then
    note "  [ready] ${role} — ping/ack を確認"
  else
    note "  [注意] ${role} — ping は届いたが応答が時間内に settled しなかった（応答中の可能性）"
  fi
  return 0
}

# not-ready のときに pane から原因の手がかりを拾う。
# 実測（2026-08）: 利用上限に達した agent は最初の turn が失敗するため READY が
# 確立せず、pane 幅や pane の破損に見えるが実体はアカウントの問題だった。
ready_ping_hint() {
  local pane="${1:-}" disp s
  [ -n "$pane" ] || return 0
  disp=""
  for s in visible detection recent-unwrapped; do
    disp="$(herdr pane read "$pane" --source "$s" --lines 25 2>/dev/null || true)"
    [ -n "$disp" ] && break
  done
  [ -n "$disp" ] || { note "              → pane を読めなかった"; return 0; }

  if printf '%s' "$disp" | grep -qiE 'usage limit|rate limit|try again at|quota|purchase more credits'; then
    note "              → pane に利用上限の表示がある。**agent の故障ではなくアカウントの問題**。"
    note "                 別アカウントに切り替えてから起動し直すこと（pane を作り直すだけでは直らない）"
  elif printf '%s' "$disp" | grep -qiE 'not initialized|startup interrupted'; then
    note "              → 起動時の初期化に失敗した表示がある。pane を読んで内容を確認すること"
  else
    note "              → pane の表示に既知の兆候は無い。手で pane を読むこと:"
    note "                 herdr pane read ${pane} --source visible"
  fi
}

# ---------- サブコマンド: swap -----------------------------------------------

SWAP_ROLE=""
SWAP_KIND=""

cmd_swap() {
  load_config
  [ -n "$SWAP_ROLE" ] || die "--role <name> が必要"
  [ -n "$SWAP_KIND" ] || die "--kind <claude|codex|...> が必要"
  local pane; pane="$(mapped_pane "$SWAP_ROLE")"
  pane_exists "$pane" || die "$SWAP_ROLE の pane が見つからない（先に up を実行）"
  assert_same_workspace "$pane" "$HERDR_WORKSPACE_ID"

  local live status
  live="$(pane_field "$pane" agent)"
  status="$(pane_field "$pane" agent_status)"
  if [ "$live" != "-" ] && [ -n "$live" ]; then
    # working は作業中なので --force でも触らない（進行中の仕事を殺さない）
    if [ "$status" = "working" ]; then
      die "$pane の $live は working（作業中）。--force でも入れ替えない。
  完了を待つか、その pane で対話的に停止させること"
    fi
    if [ "$FORCE" != 1 ]; then
      # 全角文字の直後の $var は変数名に取り込まれる（`$status）` → `status）` で
      # unbound variable。実測で確認）。全角が続く箇所では必ず ${var} で囲む。
      die "${pane} で ${live} が稼働中（status=${status}）。既定では入れ替えない。
  作業が無いことを確認済みなら --force を付けること。
  あるいはその pane で対話的に終了させてから再実行する（graceful drop が先）"
    fi
    # --force: graceful に終了させてから入れ替える
    note "$SWAP_ROLE: $live を終了させる（status=$status, --force 指定）"
    if [ "$DRY_RUN" = 1 ]; then
      note "would: $live に終了を指示し、agent が消えるのを待ってから起動し直す"
    else
      # 段階的に終了させる。Claude Code は `/exit` を打つと**スラッシュコマンドの
      # 補完メニューが開き、最初の Enter が補完確定に消費される**（実測）。
      # そのため Enter の追い送りが必要で、それでも駄目なら ctrl+c を2回送る。
      _agent_gone() {
        local a; a="$(pane_field "$pane" agent)"
        [ "$a" = "-" ] || [ -z "$a" ]
      }
      _wait_gone() { # 秒数
        local n=0
        while [ "$n" -lt "$1" ]; do _agent_gone && return 0; sleep 1; n=$((n+1)); done
        return 1
      }
      herdr agent prompt "$(agent_ident "$SWAP_ROLE")" "/exit" >/dev/null 2>&1 || true
      if ! _wait_gone 6; then
        note "  補完メニューで Enter が消費された可能性があるので Enter を追い送りする"
        herdr pane send-keys "$pane" enter >/dev/null 2>&1 || true
      fi
      if ! _wait_gone 8; then
        note "  まだ生きているので ctrl+c を2回送る"
        herdr pane send-keys "$pane" ctrl+c ctrl+c >/dev/null 2>&1 || true
        _wait_gone 8 || true
      fi
      if ! _agent_gone; then
        die "$pane の $live が終了しなかった。
  その pane を見て手で終了させてから再実行すること（強制的な kill はしない）"
      fi
      note "  終了を確認した"
    fi
  fi

  # kind を変えると model/effort のフラグ形式も変わるので、新しい kind で組み直す
  build_launch_args "$SWAP_ROLE" "$SWAP_KIND"
  local swap_ident; swap_ident="$(agent_ident "$SWAP_ROLE")"
  if [ "$DRY_RUN" = 1 ]; then
    note "would: herdr agent start $swap_ident --kind $SWAP_KIND --pane $pane${LAUNCH_ARGS[0]+ -- ${LAUNCH_ARGS[*]}}"
    return 0
  fi
  if [ "${#LAUNCH_ARGS[@]}" -gt 0 ]; then
    herdr agent start "$swap_ident" --kind "$SWAP_KIND" --pane "$pane" -- "${LAUNCH_ARGS[@]}" >/dev/null
  else
    herdr agent start "$swap_ident" --kind "$SWAP_KIND" --pane "$pane" >/dev/null
  fi
  note "$SWAP_ROLE を $SWAP_KIND で起動した（pane ${pane}）"
  note "config の kind は変更していない。恒久的に変えるなら $CFG を編集すること"
  cmd_doctor
}

# ---------- サブコマンド: doctor ---------------------------------------------

# 起動報告は生存の証明ではない。pane を実際に読んで TUI があるか確認する。
cmd_doctor() {
  load_config
  local caller_role; caller_role="$(cfg_caller_role)"
  local problems=0
  note "doctor: team=$TEAM"
  local role pane kind_cfg kind_live status cwd_cfg cwd_live tail
  for role in $(cfg_roles); do
    pane="$(mapped_pane "$role")"
    if ! pane_exists "$pane"; then
      note "  [未配備] $role — pane が無い（up を実行）"; problems=$((problems+1)); continue
    fi
    kind_cfg="$(cfg_role_field "$role" kind)"
    cwd_cfg="$(cfg_role_field "$role" cwd)"
    kind_live="$(pane_field "$pane" agent)"
    status="$(pane_field "$pane" agent_status)"
    cwd_live="$(pane_field "$pane" cwd)"

    # herdr の agent 名はワークスペース非依存でグローバルに一意なので、
    # このスキルは team 名で名前空間を切った識別子（agent_ident）を herdr 側の名前として使う。
    # intent-cli の宛先解決は --team/--role/--pane-id の topology 記録で行われ、
    # herdr 側のこの名前とは無関係（record_topology 参照）。
    # ここでの比較は「このスキルが割り当てた herdr identity が生きているか」の自己整合性チェック。
    local agent_name want_ident
    want_ident="$(agent_ident "$role")"
    agent_name="$(herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.name // empty' 2>/dev/null || true)"
    if [ "$agent_name" != "$want_ident" ]; then
      note "  [role名なし] $role ($pane) — agent の herdr identity が「${agent_name:-未設定}」（期待値: ${want_ident}）"
      note "               この状態では宛先解決から漏れる。修復: herdr agent rename $pane $want_ident"
      problems=$((problems+1))
    fi

    if [ "$role" = "$caller_role" ]; then
      # caller pane は起動し直さないと cwd を変えられないので、指摘ではなく注意に留める
      if [ "$cwd_live" != "$cwd_cfg" ]; then
        note "  [注意] $role ($pane) — caller pane の cwd が config と違う"
        note "         実機=$cwd_live"
        note "         config=$cwd_cfg"
        note "         次回このロールを起動するときは config 側の cwd で開くこと（今の session は変えられない）"
      else
        note "  [ok] $role ($pane) — caller pane"
      fi
      continue
    fi

    if [ "$cwd_live" != "$cwd_cfg" ]; then
      note "  [cwd不一致] $role ($pane) — 実機=$cwd_live / config=$cwd_cfg"; problems=$((problems+1))
    fi

    if [ "$kind_live" = "-" ] || [ -z "$kind_live" ]; then
      note "  [agent-absent] $role ($pane) — agent が検出されない。落ちている可能性が高い"
      problems=$((problems+1))
    else
      [ "$kind_live" = "$kind_cfg" ] || {
        note "  [kind不一致] $role ($pane) — 実機=$kind_live / config=$kind_cfg"; problems=$((problems+1)); }

      # 「検出はされるが宛先候補になれない」状態を検出する。agent start 直後は
      # interactive_ready が確立しておらず、cwd も kind も一致していて生存確認も
      # 通るのに外部からの配送が届かない（実測 2026-08 で3時間これに費やした）。
      local iready
      iready="$(herdr agent get "$(agent_ident "$role")" 2>/dev/null \
                 | jq -r '.result.agent.interactive_ready // empty' 2>/dev/null || true)"
      if [ "$iready" != true ]; then
        note "  [not-ready] $role ($pane) — interactive_ready が確立していない（実機=${iready:-null}）"
        note "              agent は居るが外部からの配送は届かない。ping を1回通せば確立する:"
        note "              herdr agent prompt $(agent_ident "$role") \"READY 確認\""
        note "              ping を送っても working にならないなら pane を読むこと（利用上限の可能性）"
        problems=$((problems+1))
      fi

      # model / effort の乖離を検出する。
      # up は稼働中の agent を起動し直さないので、config を変えても既存 agent には
      # 反映されない。ここで検出しないと「設定したのに効いていない」に気づけない（実測で踏んだ）。
      # 実機の値は pane の表示から読む（agent が自分の model/effort を表示している）。
      local want_model want_effort disp
      want_model="$(cfg_role_field "$role" model)"
      want_effort="$(cfg_role_field "$role" effort)"
      if [ -n "$want_model$want_effort" ]; then
        disp=""
        local s2
        for s2 in detection visible recent-unwrapped; do
          disp="$(herdr pane read "$pane" --source "$s2" --lines 30 2>/dev/null || true)"
          [ -n "$disp" ] && break
        done
        if [ -n "$disp" ]; then
          # model 名は表記が異なる（config: opus / 表示: "Opus 5"）ので大小無視の部分一致で見る
          if [ -n "$want_model" ] && ! printf '%s' "$disp" | grep -qiF "$want_model"; then
            note "  [model不一致?] $role ($pane) — config=$want_model が pane 表示に見当たらない"
            # 利用上限に達した agent は指定 model が使えず fallback model で起動する。
            # READY ping は通ってしまう（fallback でも応答するため）ので、この不一致が
            # 上限に気づく唯一の手がかりになる（実測 2026-08: codex が
            # gpt-5.6-sol high の指定で gpt-5.6-luna medium で動いていた）。
            if printf '%s' "$disp" | grep -qiE 'usage limit|rate limit|try again at|purchase more credits'; then
              note "                 → pane に**利用上限**の表示がある。指定 model が使えず fallback で"
              note "                    起動している。別アカウントに切り替えてから起動し直すこと"
              note "                    （pane を作り直すだけでは直らない。シェルの環境から変える）"
            else
              note "                 起動後に config を変えた場合は反映されない。swap で入れ替えること:"
              note "                 herdr-team.sh swap --team $TEAM --role $role --kind $kind_cfg --force"
            fi
            problems=$((problems+1))
          fi
          if [ -n "$want_effort" ] && ! printf '%s' "$disp" | grep -qiF "$want_effort"; then
            note "  [effort不一致?] $role ($pane) — config=$want_effort が pane 表示に見当たらない"
            problems=$((problems+1))
          fi
        fi
      fi

      # pane を読んで承認待ちでないかを見る。
      # source の選択が重要: codex など alternate screen で動く agent は
      # recent-unwrapped / host scrollback が**空**になる（実測）。
      # detection（agent 検出に使う bottom-buffer）→ visible → recent-unwrapped の順に試す。
      tail=""
      local src
      for src in detection visible recent-unwrapped; do
        tail="$(herdr pane read "$pane" --source "$src" --lines 20 2>/dev/null || true)"
        [ -n "$tail" ] && break
      done
      if printf '%s' "$tail" | grep -qiE '(y/n|\[y/N\]|approve|permission|do you trust|trust the contents|do you want|allow\?|press enter to continue|^ *›? *1\. )'; then
        note "  [承認待ち?] $role ($pane) status=$status — pane に承認/選択のプロンプトらしき表示がある"
        note "             → 内容を読んでから判断すること。破壊的・認証・権限に関わるものは operator に上げる"
        problems=$((problems+1))
      else
        note "  [ok] $role ($pane) kind=$kind_live status=$status"
      fi
    fi
  done

  # 配送トポロジーの妥当性は判定しない — 形式の正本が intent-cli 側にあるので、
  # CLI の validate に聞く。ここで独自の判定を持つと二重管理に戻る。
  if command -v intent-cli >/dev/null 2>&1; then
    local tv
    tv="$(topology_cmd validate --team "$TEAM" --format json || true)"
    if [ -n "$tv" ] && printf '%s' "$tv" | jq -e 'has("valid")' >/dev/null 2>&1; then
      if printf '%s' "$tv" | jq -e '.valid == true' >/dev/null 2>&1; then
        note "  [ok] 配送トポロジー — intent-cli の validate を通過"
      else
        note "  [topology不正] $(printf '%s' "$tv" | jq -r '.summary // "-"')"
        note "                 intent-cli session-layer topology show --domain $(cfg_domain) --team ${TEAM} で確認し、"
        note "                 up を再実行して記録し直すこと"
        problems=$((problems+1))
      fi
    fi
  fi

  note ""
  if [ "$problems" -eq 0 ]; then
    note "doctor: 問題なし。READY の正式な判定基準（settle delay / ping-ack）は"
    note "        intent-cli guide orchestrator-thread の G556 節を参照すること"
  else
    note "doctor: $problems 件の指摘。自動修復はしない"
  fi
}

# ---------- サブコマンド: nudge ----------------------------------------------

# 外部から pane に送られたプロンプトが、入力欄に貼られたまま submit されずに
# 止まることがある（実測 2026-08: claude kind の pane で再現。codex kind は正常に着火した）。
# pane は idle に見えるので生存確認では気づけない。貼られたままの pane に enter を送る。
#
# これは「止まっている pane を動かす」機械的操作であり、何を送るかには関与しない。
cmd_nudge() {
  load_config
  local role pane status disp hit=0
  note "nudge: team=$TEAM"
  for role in $(cfg_roles); do
    if [ -n "$SWAP_ROLE" ] && [ "$role" != "$SWAP_ROLE" ]; then continue; fi
    pane="$(mapped_pane "$role")"
    if ! pane_exists "$pane"; then
      note "  [skip] $role — pane が無い"; continue
    fi
    assert_same_workspace "$pane" "$HERDR_WORKSPACE_ID"
    status="$(pane_field "$pane" agent_status)"
    disp=""
    local s2
    for s2 in visible detection recent-unwrapped; do
      disp="$(herdr pane read "$pane" --source "$s2" --lines 15 2>/dev/null || true)"
      [ -n "$disp" ] && break
    done
    if printf '%s' "$disp" | grep -q 'Pasted text'; then
      if [ "$DRY_RUN" = 1 ]; then
        note "  would: herdr agent send-keys $(agent_ident "$role") enter   （${pane} に未 submit の貼り付けがある）"
      else
        if herdr agent send-keys "$(agent_ident "$role")" enter >/dev/null 2>&1; then
          note "  [着火] $role (${pane}) — 未 submit の貼り付けに enter を送った"
        else
          note "  ! $role (${pane}) — send-keys に失敗"
        fi
      fi
      hit=$((hit+1))
    else
      note "  [ok] $role (${pane}) — 未 submit の貼り付けは見当たらない（status=${status}）"
    fi
  done
  [ "$hit" -gt 0 ] || note "着火対象なし"
}

# ---------- サブコマンド: down -----------------------------------------------

cmd_down() {
  load_config
  local mp; mp="$(panes_path)"
  [ -f "$mp" ] || die "mapping が無いので、何を作ったか判別できない。手動で確認すること"
  local caller_role; caller_role="$(cfg_caller_role)"
  local role pane created
  for role in $(cfg_roles); do
    [ "$role" = "$caller_role" ] && continue
    pane="$(jq -r --arg r "$role" '.roles[$r].pane_id // empty' "$mp")"
    created="$(jq -r --arg r "$role" '.roles[$r].created_by_skill // false' "$mp")"
    [ -n "$pane" ] || continue
    if [ "$created" != "true" ]; then
      note "$role ($pane): このスキルが作った pane ではないので閉じない"
      continue
    fi
    pane_exists "$pane" || { note "$role ($pane): 既に無い"; continue; }
    assert_same_workspace "$pane" "$HERDR_WORKSPACE_ID"
    if [ "$DRY_RUN" = 1 ]; then note "would: pane close $pane"; continue; fi
    herdr pane close "$pane" >/dev/null && note "$role ($pane) を閉じた"
  done
  note "caller pane は閉じない。mapping は残してある: $mp"
}

# ---------- 引数 -------------------------------------------------------------

USAGE='使い方:
  herdr-team.sh init   --team <name> [--host-repo P] [--impl-repo P] [--review-repo P]
                       [--domain <name>]   # 省略時は host repo の .intent-cli/config.toml から読む
                       [--kind <role>=<kind>]... [--ratio <role>=<0.0-1.0>]...
                       [--model <role>=<model>]... [--effort <role>=<level>]...
  herdr-team.sh adopt  --team <name>          # 手で組んだ既存レイアウトを取り込む
  herdr-team.sh up     --team <name>          # 不足ロールを配備して agent を起動
  herdr-team.sh status --team <name>
  herdr-team.sh swap   --team <name> --role <role> --kind <kind>
  herdr-team.sh ratio  --team <name>
  herdr-team.sh doctor --team <name>
  herdr-team.sh nudge  --team <name> [--role <role>]   # 貼られたまま止まった pane に enter
  herdr-team.sh down   --team <name>
共通: --dry-run   swap のみ: --force（idle な agent を終了させて入れ替える）
設定の場所: ${HERDR_TEAM_CONFIG_DIR:-~/.config/herdr-agent-team}/<team>.json'

[ $# -ge 1 ] || die "$USAGE"
SUB="$1"; shift

while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="${2:-}"; shift 2 ;;
    --role) SWAP_ROLE="${2:-}"; shift 2 ;;
    --host-repo) HOST_REPO="${2:-}"; shift 2 ;;
    --impl-repo) IMPL_REPO="${2:-}"; shift 2 ;;
    --review-repo) REVIEW_REPO="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --ratio) RATIO_OVERRIDES+=("${2:-}"); shift 2 ;;
    --model) MODEL_OVERRIDES+=("${2:-}"); shift 2 ;;
    --effort) EFFORT_OVERRIDES+=("${2:-}"); shift 2 ;;
    # init では role=kind 形式（繰り返し可）、swap では kind 単体
    --kind)
      case "${2:-}" in
        *=*) KIND_OVERRIDES+=("${2}") ;;
        *)   SWAP_KIND="${2:-}" ;;
      esac
      shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) die "$USAGE" ;;
    *) die "不明な引数: $1" ;;
  esac
done

require_env

case "$SUB" in
  init)   cmd_init ;;
  up)     cmd_up ;;
  adopt)  cmd_adopt ;;
  status) cmd_status ;;
  swap)   cmd_swap ;;
  ratio)  cmd_ratio ;;
  doctor) cmd_doctor ;;
  nudge)  cmd_nudge ;;
  down)   cmd_down ;;
  *) die "不明なサブコマンド: $SUB" ;;
esac
