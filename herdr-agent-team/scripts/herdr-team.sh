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
CONFIG_DIR="${HERDR_TEAM_CONFIG_DIR:-$HOME/.config/herdr-agent-team}"

# ---------- 基本ガード -------------------------------------------------------

die() { printf 'herdr-team: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

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
  sum="$(jq '[.roles[].ratio] | add' "$CFG")"
  # 合計が 1.0 から大きく外れていたら誤設定
  awk -v s="$sum" 'BEGIN{ if (s < 0.95 || s > 1.05) exit 1 }' \
    || die "ratio の合計が 1.0 から外れている（現在 ${sum}）"
}

cfg_host_repo() { jq -r '.host_repo' "$CFG"; }
cfg_roles()     { jq -r '.roles[].role' "$CFG"; }
cfg_role_field() { jq -r --arg r "$1" --arg f "$2" '.roles[] | select(.role==$r) | .[$f] // empty' "$CFG"; }
cfg_caller_role() { jq -r '.roles[] | select(.caller==true) | .role' "$CFG"; }
cfg_launch_flags() { jq -r --arg r "$1" '.roles[] | select(.role==$r) | (.launch_flags // []) | join(" ")' "$CFG"; }

mapping_path() { printf '%s/.intent-cli/role-pane-mapping.json' "$(cfg_host_repo)"; }

# role の model / effort / launch_flags を、その kind の実フラグに変換して
# LAUNCH_ARGS 配列に入れる（`herdr agent start ... -- <ここ>` に渡す）。
#
# 実測で確認したフラグ（2026-08）:
#   claude: --model <m> / --effort <level>
#   codex : --model <m> / -c model_reasoning_effort=<level>
#           （引用符なしで codex --strict-config が受理するので、シェル経由でも安全）
# 権限モードは launch_flags に書く。起動後に修飾キーで切り替えるのは信頼できない。
build_launch_args() {
  local role="$1" kind="$2"
  local model effort flags
  model="$(cfg_role_field "$role" model)"
  effort="$(cfg_role_field "$role" effort)"
  flags="$(cfg_launch_flags "$role")"

  LAUNCH_ARGS=()
  case "$kind" in
    claude)
      [ -n "$model" ]  && LAUNCH_ARGS+=(--model "$model")
      [ -n "$effort" ] && LAUNCH_ARGS+=(--effort "$effort")
      ;;
    codex)
      [ -n "$model" ]  && LAUNCH_ARGS+=(--model "$model")
      [ -n "$effort" ] && LAUNCH_ARGS+=(-c "model_reasoning_effort=$effort")
      ;;
    *)
      if [ -n "$model$effort" ]; then
        note "! $role: kind '$kind' の model/effort フラグ対応を持っていないので無視した。"
        note "  必要なら launch_flags にその agent のフラグを直接書くこと"
      fi
      ;;
  esac
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

# caller と同じタブに属する pane を x 昇順で返す
tab_panes_ordered() {
  layout_json | jq -r '.result.layout.panes | sort_by(.rect.x) | .[].pane_id'
}

pane_width() { layout_json | jq -r --arg p "$1" '.result.layout.panes[] | select(.pane_id==$p) | .rect.width'; }

# ---------- mapping ----------------------------------------------------------

# 既存 mapping からロールの pane を引く（無ければ空）
mapped_pane() {
  local mp; mp="$(mapping_path)"
  [ -f "$mp" ] || return 0
  jq -r --arg r "$1" '.roles[$r].pane_id // empty' "$mp" 2>/dev/null || true
}

# mapping に記録された pane が実機にまだ存在するか
pane_exists() {
  [ -n "${1:-}" ] || return 1
  pane_json | jq -e --arg p "$1" 'any(.result.panes[]; .pane_id==$p)' >/dev/null 2>&1
}

write_mapping() { # assoc: role=pane_id;created の行を stdin で受ける
  local mp; mp="$(mapping_path)"
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
      local resident reader
      resident="$(cfg_role_field "$role" resident)"; : "${resident:=herdr}"
      if [ "$resident" = external ]; then
        # herdr の外で受け取るロール。pane への送信ではなく events ファイルへの
        # 追記で届くので、routing-root 相対の reader を記録する。pane_id 以降は
        # このスキル自身が pane を管理するために残す（読み手は resident を見る）。
        reader="$(cfg_role_field "$role" reader)"
        : "${reader:=.intent-cli/events/${TEAM}.jsonl}"
        printf '    %s: { "resident": "external", "reader": %s, "workspace_id": %s, "pane_id": %s, "cwd": %s, "kind": %s, "created_by_skill": %s }' \
          "$(jq -Rn --arg v "$role" '$v')" \
          "$(jq -Rn --arg v "$reader" '$v')" \
          "$(jq -Rn --arg v "$HERDR_WORKSPACE_ID" '$v')" \
          "$(jq -Rn --arg v "$pane" '$v')" \
          "$(jq -Rn --arg v "$(cfg_role_field "$role" cwd)" '$v')" \
          "$(jq -Rn --arg v "$(cfg_role_field "$role" kind)" '$v')" \
          "$created"
      else
        printf '    %s: { "resident": "herdr", "workspace_id": %s, "pane_id": %s, "cwd": %s, "kind": %s, "created_by_skill": %s }' \
          "$(jq -Rn --arg v "$role" '$v')" \
          "$(jq -Rn --arg v "$HERDR_WORKSPACE_ID" '$v')" \
          "$(jq -Rn --arg v "$pane" '$v')" \
          "$(jq -Rn --arg v "$(cfg_role_field "$role" cwd)" '$v')" \
          "$(jq -Rn --arg v "$(cfg_role_field "$role" kind)" '$v')" \
          "$created"
      fi
    done
    printf '\n  }\n}\n'
  } >"$tmp"
  jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "mapping の生成に失敗（JSON 不正）"; }
  mv "$tmp" "$mp"
  note "mapping を書き出した: $mp"
}

# ---------- サブコマンド: init -----------------------------------------------

HOST_REPO=""
IMPL_REPO=""
REVIEW_REPO=""
declare -a KIND_OVERRIDES=()
declare -a RATIO_OVERRIDES=()
declare -a MODEL_OVERRIDES=()
declare -a EFFORT_OVERRIDES=()

abspath() { ( cd "$1" 2>/dev/null && pwd ) || die "ディレクトリが存在しない: $1"; }

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

  mkdir -p "$CONFIG_DIR"
  local out="$CONFIG_DIR/$TEAM.json"
  local tmp; tmp="$(mktemp)"

  # 既定値の cwd_from を実パスに解決し、kind / ratio の上書きを適用する
  jq \
    --arg team "$TEAM" --arg host "$HOST_REPO" --arg impl "$IMPL_REPO" --arg rev "$REVIEW_REPO" \
    --argjson kinds "$(printf '%s\n' "${KIND_OVERRIDES[@]:-}" | jq -Rn '[inputs | select(length>0) | split("=") | {(.[0]): .[1]}] | add // {}')" \
    --argjson ratios "$(printf '%s\n' "${RATIO_OVERRIDES[@]:-}" | jq -Rn '[inputs | select(length>0) | split("=") | {(.[0]): (.[1]|tonumber)}] | add // {}')" \
    --argjson models "$(printf '%s\n' "${MODEL_OVERRIDES[@]:-}" | jq -Rn '[inputs | select(length>0) | split("=") | {(.[0]): .[1]}] | add // {}')" \
    --argjson efforts "$(printf '%s\n' "${EFFORT_OVERRIDES[@]:-}" | jq -Rn '[inputs | select(length>0) | split("=") | {(.[0]): .[1]}] | add // {}')" \
    '{
       team: $team,
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
         # resident: external のロールは pane 宛の送信ではなく events ファイルへの
         # 追記で受け取る。reader はチーム名から決まるのでここで実体化する。
         + (if $r.resident then {resident: $r.resident} else {} end)
         + (if $r.resident == "external"
              then {reader: ($r.reader // (".intent-cli/events/" + $team + ".jsonl"))}
              else {} end)
       ]
     }' "$DEFAULTS_FILE" >"$tmp"

  jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "設定の生成に失敗（JSON 不正）"; }

  local sum; sum="$(jq '[.roles[].ratio] | add' "$tmp")"
  awk -v s="$sum" 'BEGIN{ if (s < 0.95 || s > 1.05) exit 1 }' \
    || { rm -f "$tmp"; die "ratio の合計が 1.0 から外れている（${sum}）。--ratio で調整すること"; }

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
  local mp; mp="$(mapping_path)"
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

  if [ "$DRY_RUN" = 1 ]; then note "(dry-run) mapping は書かない"; return 0; fi
  printf '%s\n' "${lines[@]}" | write_mapping
  note ""
  cmd_status
}

# ---------- サブコマンド: ratio ----------------------------------------------

# 幅の下限。これを割ると承認ダイアログが読めなくなるので、下回る計画は実行しない。
MIN_PANE_COLS="${HERDR_TEAM_MIN_PANE_COLS:-40}"

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
  local role pane
  for role in $(cfg_roles); do
    pane="$(mapped_pane "$role")"
    pane_exists "$pane" || { note "ratio: $role が未配備なのでスキップ"; continue; }
    order+=("$pane")
    targets+=("$(awk -v a="$aw" -v r="$(cfg_role_field "$role" ratio)" 'BEGIN{printf "%d", a*r}')")
  done
  local n=${#order[@]}
  [ "$n" -ge 2 ] || { note "ratio: 対象 pane が 2 未満なので何もしない"; return 0; }

  # 下限ガード: 目標が下限を割るなら実行しない（潰れた pane を作らない）
  local i
  for (( i=0; i<n; i++ )); do
    if [ "${targets[$i]}" -lt "$MIN_PANE_COLS" ]; then
      die "目標幅 ${targets[$i]}桁 (${order[$i]}) が下限 ${MIN_PANE_COLS}桁 を割る。
  この幅では承認ダイアログが読めない。ウィンドウを広げるか、config の ratio を見直すこと
  （下限は HERDR_TEAM_MIN_PANE_COLS で変えられる）"
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
    [ "$cur" -ge "$MIN_PANE_COLS" ] || warn=1
  done
  [ "$warn" -eq 0 ] || note "! 下限 ${MIN_PANE_COLS}桁 を割った pane がある。ウィンドウ幅か config を見直すこと"
}

# ---------- サブコマンド: up -------------------------------------------------

cmd_up() {
  load_config
  local caller_role; caller_role="$(cfg_caller_role)"
  [ -n "$caller_role" ] || die "config に caller:true のロールが無い（自分の pane を割り当てられない）"

  local -a lines=()
  local prev_pane="$HERDR_PANE_ID" prev_role=""
  local role pane kind cwd created

  for role in $(cfg_roles); do
    kind="$(cfg_role_field "$role" kind)"
    cwd="$(cfg_role_field "$role" cwd)"

    if [ "$role" = "$caller_role" ]; then
      pane="$HERDR_PANE_ID"; created=false
      note "$role: caller pane $pane を割り当て（agent は起動しない）"
      # agent を起動しないロールには logical role 名が付かない。名前が無い agent は
      # notify の宛先解決から漏れる（「logical role が見つからない」で fail closed）ため、
      # rename だけは caller にも当てる。
      if [ "$DRY_RUN" != 1 ]; then
        herdr agent rename "$pane" "$role" >/dev/null 2>&1 \
          || note "  ! caller pane の rename に失敗（notify の宛先解決から漏れる可能性）"
      fi
    else
      pane="$(mapped_pane "$role")"
      if pane_exists "$pane"; then
        created="$(jq -r --arg r "$role" '.roles[$r].created_by_skill // false' "$(mapping_path)")"
        note "$role: 既存 pane $pane を再利用"
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
    prev_pane="$pane"; prev_role="$role"
    lines+=("$role|$pane|$created")
  done

  if [ "$DRY_RUN" = 1 ]; then
    note "(dry-run) mapping の書き出しと agent 起動はしない"
    return 0
  fi

  printf '%s\n' "${lines[@]}" | write_mapping
  cmd_ratio

  # agent 起動（caller 以外、かつ agent が居ない pane だけ）
  local live flags
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
    note "$role: herdr agent start $role --kind $kind --pane $pane${LAUNCH_ARGS[0]+ -- ${LAUNCH_ARGS[*]}}"
    if [ "${#LAUNCH_ARGS[@]}" -gt 0 ]; then
      herdr agent start "$role" --kind "$kind" --pane "$pane" -- "${LAUNCH_ARGS[@]}" >/dev/null \
        || note "  ! 起動に失敗（doctor で確認すること）"
    else
      herdr agent start "$role" --kind "$kind" --pane "$pane" >/dev/null \
        || note "  ! 起動に失敗（doctor で確認すること）"
    fi
  done

  note ""
  cmd_doctor
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
      herdr agent prompt "$SWAP_ROLE" "/exit" >/dev/null 2>&1 || true
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
  if [ "$DRY_RUN" = 1 ]; then
    note "would: herdr agent start $SWAP_ROLE --kind $SWAP_KIND --pane $pane${LAUNCH_ARGS[0]+ -- ${LAUNCH_ARGS[*]}}"
    return 0
  fi
  if [ "${#LAUNCH_ARGS[@]}" -gt 0 ]; then
    herdr agent start "$SWAP_ROLE" --kind "$SWAP_KIND" --pane "$pane" -- "${LAUNCH_ARGS[@]}" >/dev/null
  else
    herdr agent start "$SWAP_ROLE" --kind "$SWAP_KIND" --pane "$pane" >/dev/null
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

    # 宛先解決は agent の logical role 名で行われる。名前が付いていない agent は
    # pane が生きていても宛先候補から漏れ、fail closed で配送されない（実測で踏んだ）。
    # 名前を付けるのは `herdr agent start <role>` なので、pane で直接 `claude` /
    # `codex` と打って起動した agent には付いていない。
    local agent_name
    agent_name="$(herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.name // empty' 2>/dev/null || true)"
    if [ "$agent_name" != "$role" ]; then
      note "  [role名なし] $role ($pane) — agent の logical role 名が「${agent_name:-未設定}」"
      note "               この状態では宛先解決から漏れる。修復: herdr agent rename $pane $role"
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
            note "                 起動後に config を変えた場合は反映されない。swap で入れ替えること:"
            note "                 herdr-team.sh swap --team $TEAM --role $role --kind $kind_cfg --force"
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
        note "  would: herdr agent send-keys $role enter   （${pane} に未 submit の貼り付けがある）"
      else
        if herdr agent send-keys "$role" enter >/dev/null 2>&1; then
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
  local mp; mp="$(mapping_path)"
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
