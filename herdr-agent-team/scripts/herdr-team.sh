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
CONFIG_DIR="$SCRIPT_DIR/../config"

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

load_config() {
  [ -n "$TEAM" ] || die "--team <name> が必要"
  CFG="$CONFIG_DIR/$TEAM.json"
  [ -f "$CFG" ] || die "config が無い: $CFG"
  jq -e . "$CFG" >/dev/null 2>&1 || die "config が JSON として不正: $CFG"

  local sum
  sum="$(jq '[.roles[].ratio] | add' "$CFG")"
  # 合計が 1.0 から大きく外れていたら誤設定
  awk -v s="$sum" 'BEGIN{ if (s < 0.95 || s > 1.05) exit 1 }' \
    || die "ratio の合計が 1.0 から外れている（現在 $sum）"
}

cfg_host_repo() { jq -r '.host_repo' "$CFG"; }
cfg_roles()     { jq -r '.roles[].role' "$CFG"; }
cfg_role_field() { jq -r --arg r "$1" --arg f "$2" '.roles[] | select(.role==$r) | .[$f] // empty' "$CFG"; }
cfg_caller_role() { jq -r '.roles[] | select(.caller==true) | .role' "$CFG"; }
cfg_launch_flags() { jq -r --arg r "$1" '.roles[] | select(.role==$r) | (.launch_flags // []) | join(" ")' "$CFG"; }

mapping_path() { printf '%s/.intent-cli/role-pane-mapping.json' "$(cfg_host_repo)"; }

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
    local first=1 line role pane created
    while IFS='|' read -r role pane created; do
      [ -n "$role" ] || continue
      [ $first -eq 1 ] || printf ',\n'
      first=0
      printf '    %s: { "resident": "herdr", "workspace_id": %s, "pane_id": %s, "cwd": %s, "kind": %s, "created_by_skill": %s }' \
        "$(jq -Rn --arg v "$role" '$v')" \
        "$(jq -Rn --arg v "$HERDR_WORKSPACE_ID" '$v')" \
        "$(jq -Rn --arg v "$pane" '$v')" \
        "$(jq -Rn --arg v "$(cfg_role_field "$role" cwd)" '$v')" \
        "$(jq -Rn --arg v "$(cfg_role_field "$role" kind)" '$v')" \
        "$created"
    done
    printf '\n  }\n}\n'
  } >"$tmp"
  jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "mapping の生成に失敗（JSON 不正）"; }
  mv "$tmp" "$mp"
  note "mapping を書き出した: $mp"
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

# pane resize --direction は「指定 pane がその方向に伸びて広くなる」。
# 隣接2 pane の境界1本しか動かないので、左から順に詰めて収束させる。
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

  local i cur tgt delta amount iter
  for (( i=0; i<n-1; i++ )); do
    for (( iter=0; iter<12; iter++ )); do
      cur="$(pane_width "${order[$i]}")"
      tgt="${targets[$i]}"
      delta=$(( tgt - cur ))
      # 2桁以内なら十分
      if [ "${delta#-}" -le 2 ]; then break; fi
      amount="$(awk -v d="${delta#-}" -v a="$aw" 'BEGIN{printf "%.4f", d/a}')"
      if [ "$delta" -gt 0 ]; then
        [ "$DRY_RUN" = 1 ] && { note "would: resize ${order[$i]} right $amount"; break; }
        herdr pane resize --pane "${order[$i]}" --direction right --amount "$amount" >/dev/null
      else
        [ "$DRY_RUN" = 1 ] && { note "would: resize ${order[$((i+1))]} left $amount"; break; }
        herdr pane resize --pane "${order[$((i+1))]}" --direction left --amount "$amount" >/dev/null
      fi
    done
  done
  note "ratio 適用後:"
  for (( i=0; i<n; i++ )); do
    note "  ${order[$i]}  $(pane_width "${order[$i]}")桁 (目標 ${targets[$i]})"
  done
}

# ---------- サブコマンド: up -------------------------------------------------

cmd_up() {
  load_config
  local caller_role; caller_role="$(cfg_caller_role)"
  [ -n "$caller_role" ] || die "config に caller:true のロールが無い（自分の pane を割り当てられない）"

  local -a lines=()
  local prev_pane="$HERDR_PANE_ID"
  local role pane kind cwd created

  for role in $(cfg_roles); do
    kind="$(cfg_role_field "$role" kind)"
    cwd="$(cfg_role_field "$role" cwd)"

    if [ "$role" = "$caller_role" ]; then
      pane="$HERDR_PANE_ID"; created=false
      note "$role: caller pane $pane を割り当て（agent は起動しない）"
    else
      pane="$(mapped_pane "$role")"
      if pane_exists "$pane"; then
        created="$(jq -r --arg r "$role" '.roles[$r].created_by_skill // false' "$(mapping_path)")"
        note "$role: 既存 pane $pane を再利用"
      else
        [ -d "$cwd" ] || die "$role の cwd が存在しない: $cwd"
        if [ "$DRY_RUN" = 1 ]; then
          note "would: pane split --pane $prev_pane --direction right --cwd $cwd"
          pane="(new)"; created=true
        else
          require_id "split 元 pane" "$prev_pane"
          assert_same_workspace "$prev_pane" "$HERDR_WORKSPACE_ID"
          pane="$(herdr pane split --pane "$prev_pane" --direction right --cwd "$cwd" --no-focus \
                  | jq -r '.result.pane.pane_id')"
          require_id "$role の新 pane" "$pane"
          herdr pane rename "$pane" "$role" >/dev/null 2>&1 || true
          created=true
          note "$role: pane $pane を作成（cwd=$cwd）"
        fi
      fi
    fi
    [ "$pane" = "(new)" ] || prev_pane="$pane"
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
    flags="$(cfg_launch_flags "$role")"
    note "$role: herdr agent start $role --kind $kind --pane $pane ${flags:+-- $flags}"
    # shellcheck disable=SC2086
    if [ -n "$flags" ]; then
      herdr agent start "$role" --kind "$kind" --pane "$pane" -- $flags >/dev/null \
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

  local live; live="$(pane_field "$pane" agent)"
  if [ "$live" != "-" ] && [ -n "$live" ]; then
    die "$pane で $live が稼働中。作業を殺さないため自動では入れ替えない。
  その pane で対話的に終了させてから再実行すること（graceful drop が先）。
  現在の状態: $(pane_field "$pane" agent_status)"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    note "would: herdr agent start $SWAP_ROLE --kind $SWAP_KIND --pane $pane"
    return 0
  fi
  local flags; flags="$(cfg_launch_flags "$SWAP_ROLE")"
  # shellcheck disable=SC2086
  if [ -n "$flags" ]; then
    herdr agent start "$SWAP_ROLE" --kind "$SWAP_KIND" --pane "$pane" -- $flags >/dev/null
  else
    herdr agent start "$SWAP_ROLE" --kind "$SWAP_KIND" --pane "$pane" >/dev/null
  fi
  note "$SWAP_ROLE を $SWAP_KIND で起動した（pane $pane）"
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

    if [ "$cwd_live" != "$cwd_cfg" ]; then
      note "  [cwd不一致] $role ($pane) — 実機=$cwd_live / config=$cwd_cfg"; problems=$((problems+1))
    fi

    if [ "$role" = "$caller_role" ]; then
      note "  [ok] $role ($pane) — caller pane"
      continue
    fi

    if [ "$kind_live" = "-" ] || [ -z "$kind_live" ]; then
      note "  [agent-absent] $role ($pane) — agent が検出されない。落ちている可能性が高い"
      problems=$((problems+1))
    else
      [ "$kind_live" = "$kind_cfg" ] || {
        note "  [kind不一致] $role ($pane) — 実機=$kind_live / config=$kind_cfg"; problems=$((problems+1)); }
      # pane を読んで、シェルプロンプトに戻っていないか / 承認待ちでないかを見る
      tail="$(herdr pane read "$pane" --source recent-unwrapped --lines 12 2>/dev/null | tail -4 || true)"
      if printf '%s' "$tail" | grep -qiE '(y/n|\[y/N\]|approve|permission|trust|do you want|allow\?)'; then
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

[ $# -ge 1 ] || die "使い方: herdr-team.sh <up|adopt|status|swap|ratio|doctor|down> --team <name> [--role R --kind K] [--dry-run]"
SUB="$1"; shift

while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="${2:-}"; shift 2 ;;
    --role) SWAP_ROLE="${2:-}"; shift 2 ;;
    --kind) SWAP_KIND="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) die "使い方: herdr-team.sh <up|status|swap|ratio|doctor|down> --team <name>" ;;
    *) die "不明な引数: $1" ;;
  esac
done

require_env

case "$SUB" in
  up)     cmd_up ;;
  adopt)  cmd_adopt ;;
  status) cmd_status ;;
  swap)   cmd_swap ;;
  ratio)  cmd_ratio ;;
  doctor) cmd_doctor ;;
  down)   cmd_down ;;
  *) die "不明なサブコマンド: $SUB" ;;
esac
