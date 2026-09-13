#!/usr/bin/env bash
# orca-agent-team — intent-cli の四ロール席を orca 上に配備する。
#
#   orca-team.sh init|up|status|down|doctor --team <name> [--dry-run]
#
# このスクリプトが持つのは orca の端末配置と agent 起動、および intent-cli への
# トポロジー「値の受け渡し」だけ。委譲・レビュー・publish の作法は intent-cli guide
# が正本で、ここには書かない（references/boundaries.md を参照）。

set -euo pipefail

CONFIG_DIR="${ORCA_TEAM_CONFIG_DIR:-$HOME/.config/orca-agent-team}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
TOPOLOGY_ONLY=0
CALLER_IN_HOST=0
TEAM=""
CFG=""
RUN_ID=""
HOST_REPO=""
IMPL_REPO=""
DOMAIN=""

die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*"; }
step() { printf '\033[36m==>\033[0m %s\n' "$*"; }

run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '\033[90m    [dry-run] %s\033[0m\n' "$*"
    return 0
  fi
  "$@" >/dev/null
}

require_env() {
  command -v orca >/dev/null 2>&1 || die "orca が PATH にない"
  command -v jq   >/dev/null 2>&1 || die "jq が PATH にない"
  command -v intent-cli >/dev/null 2>&1 || warn "intent-cli が PATH にない: topology の記録を skip する"
  [ -n "${ORCA_TERMINAL_HANDLE:-}" ] || die "ORCA_TERMINAL_HANDLE が空。orca の端末から実行すること"
}

team_config() { printf '%s/%s.json' "$CONFIG_DIR" "$TEAM"; }
term_state()  { printf '%s/%s.terminals.json' "$CONFIG_DIR" "$TEAM"; }

load_config() {
  local f; f="$(team_config)"
  [ -f "$f" ] || die "team 設定が無い: ${f}（先に \`init\` を実行する）"
  CFG="$(cat "$f")"
  HOST_REPO="$(jq -r '.repos.host' <<<"$CFG")"
  IMPL_REPO="$(jq -r '.repos.impl' <<<"$CFG")"
  DOMAIN="$(jq -r '.domain' <<<"$CFG")"
  [ -d "$HOST_REPO" ] || die "host repo が存在しない: $HOST_REPO"
  [ -d "$IMPL_REPO" ] || die "impl repo が存在しない: $IMPL_REPO"
  [ -d "$HOST_REPO/.intent-cli" ] || warn "$HOST_REPO に .intent-cli が無い（intent-cli は G299 で失敗する）"
}

save_config() { printf '%s\n' "$CFG" > "$(team_config)"; }

role_field() {
  jq -r --arg r "$1" --arg f "$2" '.roles[] | select(.role == $r) | .[$f] // empty' <<<"$CFG"
}
roles()      { jq -r '.roles[].role' <<<"$CFG"; }
caller_role(){ jq -r '.roles[] | select(.caller == true) | .role' <<<"$CFG" | head -1; }

# --------------------------------------------------------------- terminals

known_handle() {
  local f; f="$(term_state)"
  [ -f "$f" ] || { printf ''; return 0; }
  jq -r --arg r "$1" '.roles[$r].handle // empty' "$f" 2>/dev/null || printf ''
}
known_created_by_skill() {
  local f; f="$(term_state)"
  [ -f "$f" ] || { printf 'false'; return 0; }
  jq -r --arg r "$1" '.roles[$r].created_by_skill // false' "$f" 2>/dev/null || printf 'false'
}
handle_alive() {
  [ -n "${1:-}" ] || return 1
  orca terminal show --terminal "$1" --json 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1
}
remember_handle() {
  local role="$1" handle="$2" created="$3" launched="${4:-false}" f; f="$(term_state)"
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$CONFIG_DIR"
  [ -f "$f" ] || printf '{"team":"%s","roles":{}}\n' "$TEAM" > "$f"
  local tmp; tmp="$(mktemp)"
  jq --arg r "$role" --arg h "$handle" --argjson c "$created" --argjson l "$launched" \
     '.roles[$r] = {handle: $h, created_by_skill: $c, agent_launched: $l}' "$f" > "$tmp" && mv "$tmp" "$f"
}

# kind-flags.json を引いて起動コマンド文字列を組む。値は @sh で quoting する。
launch_command() {
  local kind="$1" model="$2" effort="$3" tmpl flags=""
  tmpl="$SKILL_DIR/config/kind-flags.json"
  if jq -e --arg k "$kind" '.kinds[$k]' "$tmpl" >/dev/null 2>&1; then
    [ -z "$model" ]  || flags+=" $(jq -r --arg k "$kind" --arg v "$model" \
        '.kinds[$k].model  | map(gsub("\\{model\\}";  $v) | @sh) | join(" ")' "$tmpl")"
    [ -z "$effort" ] || flags+=" $(jq -r --arg k "$kind" --arg v "$effort" \
        '.kinds[$k].effort | map(gsub("\\{effort\\}"; $v) | @sh) | join(" ")' "$tmpl")"
  elif [ -n "$model$effort" ]; then
    warn "kind '$kind' は kind-flags.json に無い: model/effort を無視する"
  fi
  printf '%s%s' "$kind" "$flags"
}

extract_handle() { jq -r '.result.terminal.handle // .result.split.handle // .result.handle // empty'; }

# agent は `terminal create --command` では起動しない。TUI agent を --command に渡すと
# orca が "Timed out waiting for terminal handle after creation" で失敗し、端末も
# 残らない（2026-09-14 実測。素の claude でも再現、echo なら成功）。
# 端末を先に作り、対話シェルにコマンドを打ち込んで起動する。herdr 版が codex について
# 同じ結論に達していた（シェル経由でないと wrapper が適用されない）。
launch_agent() {
  local role="$1" handle="$2" cmd="$3"
  if [ "$DRY_RUN" = 1 ]; then
    printf '\033[90m    [dry-run] orca terminal send --terminal %s --text %q --enter --wait-submit 15\033[0m\n' "$handle" "$cmd"
    return 0
  fi
  local out warn
  out="$(orca terminal send --terminal "$handle" --text "$cmd" --enter --wait-submit 15 --json 2>/dev/null)" || true
  if [ "$(jq -r '.ok // false' <<<"$out")" != "true" ]; then
    warn "$role: 起動コマンドの送信に失敗した（端末を見て手で起動すること）"
    return 0
  fi
  warn="$(jq -r '.result.warnings[]? // empty' <<<"$out" | head -1)"
  [ -z "$warn" ] || info "$role: $warn"
}

# ------------------------------------------------------------------- run

ensure_run() {
  local rid; rid="$(jq -r '.run_id // empty' <<<"$CFG")"
  if [ -n "$rid" ] && orca orchestration run-use --id "$rid" --json >/dev/null 2>&1; then
    RUN_ID="$rid"; info "Run を bind: $RUN_ID"; return 0
  fi
  [ -z "$rid" ] || warn "記録された Run '$rid' に bind できない: 作り直す（wake_command を全席更新する）"
  if [ "$DRY_RUN" = 1 ]; then
    RUN_ID="<new-run-id>"
    printf '\033[90m    [dry-run] orca orchestration run-create --objective "intent-cli team %s"\033[0m\n' "$TEAM"
    return 0
  fi
  RUN_ID="$(orca orchestration run-create --objective "intent-cli team $TEAM" --json 2>/dev/null \
    | jq -r '.result.run.id // .result.runId // .result.id // empty')"
  [ -n "$RUN_ID" ] || die "Run の作成に失敗した"
  info "Run を作成: $RUN_ID"
  CFG="$(jq --arg r "$RUN_ID" '.run_id = $r' <<<"$CFG")"; save_config
}

# --------------------------------------------------------------- topology

has_intent_cli() { command -v intent-cli >/dev/null 2>&1; }

# 全席 external の topology を作る。1席を herdr で記録して workspace_id を確立し、
# その席を external に変換する。直接 external で4席記録すると workspace_id を
# 導出できず validate が落ちる（2026-09-14 実測）。
record_topology() {
  has_intent_cli || { warn "intent-cli が無い: topology の記録を skip"; return 0; }
  local anchor ws frontend reader r
  anchor="$(jq -r '.host_state_role' <<<"$CFG")"
  ws="$(jq -r '.workspace_id_placeholder' <<<"$CFG")"
  frontend="$(jq -r '.frontend' <<<"$CFG")"
  reader=".intent-cli/events/$TEAM.jsonl"

  step "topology を記録する（anchor=$anchor → 全席 external）"
  ( cd "$HOST_REPO" && run intent-cli session-layer topology record \
      --domain "$DOMAIN" --team "$TEAM" --role "$anchor" --resident herdr \
      --workspace-id "$ws" --pane-id "$ws:p1" --cwd "$HOST_REPO" \
      --kind "$(role_field "$anchor" kind)" --write --format json )

  while read -r r; do
    [ "$r" = "$anchor" ] && continue
    ( cd "$HOST_REPO" && run intent-cli session-layer topology record \
        --domain "$DOMAIN" --team "$TEAM" --role "$r" --resident external \
        --reader "$reader" --frontend "$frontend" --write --format json )
  done < <(roles)

  ( cd "$HOST_REPO" && run intent-cli session-layer topology update-residence \
      --domain "$DOMAIN" --team "$TEAM" --role "$anchor" \
      --current-resident herdr --new-resident external \
      --reader "$reader" --frontend "$frontend" \
      --confirm-update-residence --write --format json )
}

# wake_command は run_id を焼き込むので、Run を作り直したら再実行が要る。
# --from は固定ラベル。送信者は委譲するたびに変わるが、テンプレートは受信ロール単位で
# 記録されるため送信者を知りようがない。宛先は subject に入れて区別できるようにする。
record_wake_commands() {
  has_intent_cli || return 0
  step "wake_command を設定する（run=${RUN_ID}）"
  local r cur new
  while read -r r; do
    new="orca orchestration send --run $RUN_ID --to run:$RUN_ID --from intent-cli --subject {task_id} --body {summary}"
    cur="$( cd "$HOST_REPO" && intent-cli session-layer topology show --domain "$DOMAIN" --team "$TEAM" \
      --format json 2>/dev/null | jq -r --arg r "$r" '.roles[]? | select(.role == $r) | .wake_command // empty' | head -1 || true )"
    [ -n "$cur" ] || cur="absent"
    [ "$cur" = "$new" ] && { info "$r: 変更なし"; continue; }
    ( cd "$HOST_REPO" && run intent-cli session-layer topology update-field \
        --domain "$DOMAIN" --team "$TEAM" --role "$r" --field wake_command \
        --current "$cur" --new "$new" --confirm-update-field --write --format json )
  done < <(roles)
}

record_host_state() {
  has_intent_cli || return 0
  local role env
  role="$(jq -r '.host_state_role' <<<"$CFG")"
  env="$(jq -r '.host_state_envelope' <<<"$CFG")"
  step "host-state ロールを宣言する（$role / envelope=${env}）"
  ( cd "$HOST_REPO" && run intent-cli session-layer topology record-host-state \
      --domain "$DOMAIN" --team "$TEAM" --role "$role" --envelope "$env" \
      --write --format json )
}

# 記録が無いと既定の agmsg に落ちる（実測）。必ず明示する。
set_session_layer() {
  has_intent_cli || return 0
  step "session-layer を herdr-only に設定する"
  ( cd "$HOST_REPO" && run intent-cli session-layer set --domain "$DOMAIN" --team "$TEAM" \
      --mode herdr-only --write --format json )
}

# 旧 role-pane-mapping.json が残っていると domain 内の全チームが invalid になる
# （0.31.0 で互換読み取りが削除された）。退役は新形式の記録が先に要る。
check_legacy_topology() {
  local f="$HOST_REPO/.intent-cli/role-pane-mapping.json"
  [ -f "$f" ] || return 0
  warn "旧形式の topology が残っている: $f"
  warn "  この domain の全チームが invalid になる。新形式を記録した今なら退役できる:"
  warn "  cd $HOST_REPO && intent-cli session-layer topology retire-legacy \\"
  warn "    --domain $DOMAIN --team $TEAM --evidence <理由> --confirm-retire-legacy --write"
}

validate_topology() {
  has_intent_cli || return 0
  local out
  out="$( cd "$HOST_REPO" && intent-cli session-layer topology validate \
    --domain "$DOMAIN" --team "$TEAM" --format json 2>/dev/null )" || true
  [ -n "$out" ] || { warn "validate の出力が空"; return 0; }
  if [ "$(jq -r '.valid' <<<"$out")" = "true" ]; then
    info "topology validate: valid"
  else
    warn "topology validate: INVALID"
    jq -r '.findings[]? | "    - \(.role)/\(.field): \(.message)"' <<<"$out" >&2
  fi
}

# ------------------------------------------------------------------ init

cmd_init() {
  local domain="$1" host_repo="$2" impl_repo="$3"; shift 3
  [ -n "$domain" ]    || die "--domain が必要"
  [ -n "$host_repo" ] || die "--host-repo が必要"
  [ -n "$impl_repo" ] || die "--impl-repo が必要"
  host_repo="$(cd "$host_repo" && pwd)" || die "host repo を解決できない"
  impl_repo="$(cd "$impl_repo" && pwd)" || die "impl repo を解決できない"
  [ "$host_repo" != "$impl_repo" ] || die "host と impl が同一ディレクトリ（git は同一 repo の2ブランチを1 worktree に置けない）"

  local base; base="$(cat "$SKILL_DIR/config/defaults.json")"
  local out
  out="$(jq --arg t "$TEAM" --arg d "$domain" --arg h "$host_repo" --arg i "$impl_repo" \
    '{team: $t, domain: $d, repos: {host: $h, impl: $i}}
     + {roles, host_state_role, host_state_envelope, workspace_id_placeholder, frontend}' <<<"$base")"

  # --kind/--model/--effort の上書きを適用する。
  local ov key role val
  for ov in "$@"; do
    [ -n "$ov" ] || continue
    key="${ov%%:*}"; val="${ov#*:}"; role="${val%%=*}"; val="${val#*=}"
    out="$(jq --arg r "$role" --arg k "$key" --arg v "$val" \
      '.roles |= map(if .role == $r then .[$k] = $v else . end)' <<<"$out")"
  done

  local f; f="$(team_config)"
  [ -f "$f" ] && warn "既存の設定を上書きする: $f"
  if [ "$DRY_RUN" = 1 ]; then
    printf '\033[90m[dry-run] %s に書き出す内容:\033[0m\n' "$f"; jq '.' <<<"$out"; return 0
  fi
  mkdir -p "$CONFIG_DIR"; printf '%s\n' "$out" > "$f"
  step "team 設定を書き出した: $f"
  jq -r '.roles[] | "  \(.role): kind=\(.kind) worktree=\(.worktree) model=\(.model // "-") effort=\(.effort // "-")"' <<<"$out"
}

# -------------------------------------------------------------------- up

cmd_up() {
  step "orca-agent-team up: $TEAM (domain=$DOMAIN)"
  info "host: $HOST_REPO"
  info "impl: $IMPL_REPO"
  ensure_run

  local caller r kind model effort wt cwd handle cmd
  caller="$(caller_role)"

  # このセッションが host worktree にいるかを判定する。
  local here
  here="$(orca terminal show --terminal "$ORCA_TERMINAL_HANDLE" --json 2>/dev/null \
    | jq -r '.result.terminal.worktreePath // empty')"
  if [ "$here" = "$HOST_REPO" ]; then
    CALLER_IN_HOST=1
  else
    CALLER_IN_HOST=0
    warn "このセッションは host worktree にいない（現在: ${here:-不明}）"
    warn "  '$caller' も新しい端末として作る。既にどこかで動いている席があれば down してから実行すること"
  fi

  # 移行用: 端末も agent も触らず、intent-cli 側の記録だけを作る。
  # 旧 role-pane-mapping.json からの移行は「新形式を記録してから retire-legacy」
  # の順序が必要で、そのために agent を起動せず記録だけ作りたい場面がある。
  if [ "$TOPOLOGY_ONLY" = 1 ]; then
    info "--topology-only: 端末の作成と agent の起動を skip する"
    record_topology
    record_wake_commands
    record_host_state
    set_session_layer
    check_legacy_topology
    validate_topology
    return 0
  fi

  while read -r r; do
    kind="$(role_field "$r" kind)"
    model="$(role_field "$r" model)"
    effort="$(role_field "$r" effort)"
    wt="$(role_field "$r" worktree)"
    [ "$wt" = "impl" ] && cwd="$IMPL_REPO" || cwd="$HOST_REPO"

    # caller 席は「このセッション自身」に割り当てる。ただしそれが成立するのは
    # このセッションが host worktree にいるときだけ。別の worktree から実行された
    # 場合に流用すると、席が誤った cwd に置かれる（端末の worktree は変えられない）。
    # その場合は caller 扱いをやめ、通常の席として新しい端末を作る。
    if [ "$r" = "$caller" ] && [ "$CALLER_IN_HOST" = 1 ]; then
      handle="$ORCA_TERMINAL_HANDLE"
      info "$r: caller 席（このセッション自身）$handle"
      run orca terminal rename --terminal "$handle" --title "$r" --json >/dev/null 2>&1 || true
      remember_handle "$r" "$handle" false
      continue
    fi

    handle="$(known_handle "$r")"
    if handle_alive "$handle"; then
      info "$r: 既存の端末を再利用 $handle"
      continue
    fi

    cmd="$(launch_command "$kind" "$model" "$effort")"
    # 1席1タブ。ペイン分割はしない。
    # 3席を1タブに split すると各ペインが 250px 程度になり、単語が分断されて
    # 実用にならない（2026-09-14 に実機で確認）。herdr 版も「worker pane を
    # 細くしすぎない、実用下限およそ48桁」を規定していた。画面幅は
    # 4席 × 48桁 = 192桁を要求するが、読めるフォントサイズでは成立しない。
    # 席同士の視覚的同居は agent には不要で（委譲は notify 経由、他席の画面は
    # terminal read で読める）、人間が見る必要のある承認待ちは doctor が拾う。
    info "$r: $wt worktree にタブを作成 ($cmd)"
    if [ "$DRY_RUN" = 1 ]; then
      printf '\033[90m    [dry-run] orca terminal create --worktree path:%s --title %s\033[0m\n' "$cwd" "$r"
      handle="<new-$r>"
    else
      handle="$(orca terminal create --worktree "path:$cwd" --title "$r" \
        --json 2>/dev/null | extract_handle)"
      [ -n "$handle" ] || die "$r: terminal create に失敗した"
    fi
    launch_agent "$r" "$handle" "$cmd"
    run orca terminal rename --terminal "$handle" --title "$r" --json >/dev/null 2>&1 || true
    remember_handle "$r" "$handle" true
  done < <(roles)

  record_topology
  record_wake_commands
  record_host_state
  set_session_layer
  validate_topology

  step "完了。各席は自分で notify collect のループを回すこと（intent-cli guide が正本）"
}

# ---------------------------------------------------------------- status

# ---------------------------------------------------------------- layout

# 1タブの中に入れ子 split で4席分のペインを作る。
#
#   design │ review │ orchestrator
#                    ├─────────────
#                    │ implementation
#
# herdr-agent-team と同じ配置（右列を上下に分ける）。
# 向きは実測に従う: vertical が左右、horizontal が上下（orca-cli skill の説明とは逆）。
#
# タブ「領域」自体の分割は CLI から作れないが、入れ子 split なら同じ見た目になる。
# UI 側の Split Terminal Right は computer click が ok を返しても作動しない
# （Electron の web content では AXPress が効かない。2026-09-14 実測）。
#
# implementation のペインは host worktree に属することになるので、agent の起動前に
# impl チェックアウトへ cd する。external 席の topology は cwd を記録しないため
# （reader / frontend / wake_command のみ）、worktree の帰属がずれても配送に影響しない。
cmd_layout() {
  local base
  base="$(known_handle "$(caller_role)")"
  handle_alive "$base" || die "起点となる席が無い。先に \`up\` で1席目を作るか \`adopt\` で取り込む"

  step "1タブ内に4ペインを組む（起点: $(caller_role) ${base}）"
  local h2 h3 h4
  h2="$(split_from "$base" vertical   "review")"
  h3="$(split_from "$h2"   vertical   "orchestrator")"
  h4="$(split_from "$h3"   horizontal "implementation")"

  remember_handle review         "$h2" true
  remember_handle orchestrator   "$h3" true
  remember_handle implementation "$h4" true

  local r cmd cwd
  for r in review orchestrator implementation; do
    cmd="$(launch_command "$(role_field "$r" kind)" "$(role_field "$r" model)" "$(role_field "$r" effort)")"
    [ "$(role_field "$r" worktree)" = "impl" ] && cmd="cd $(printf '%q' "$IMPL_REPO") && $cmd"
    launch_agent "$r" "$(known_handle "$r")" "$cmd"
  done
  info "完了。topology の記録は \`up\` が行う"
}

split_from() {
  local from="$1" dir="$2" label="$3" h
  if [ "$DRY_RUN" = 1 ]; then
    printf '\033[90m    [dry-run] orca terminal split --terminal %s --direction %s  (%s)\033[0m\n' "$from" "$dir" "$label" >&2
    printf '<new-%s>' "$label"; return 0
  fi
  h="$(orca terminal split --terminal "$from" --direction "$dir" --json 2>/dev/null | extract_handle)"
  [ -n "$h" ] || die "$label: split に失敗した"
  orca terminal rename --terminal "$h" --title "$label" --json >/dev/null 2>&1 || true
  printf '  %s: %s に %s 分割 → %s\n' "$label" "$from" "$dir" "$h" >&2
  printf '%s' "$h"
}

# ----------------------------------------------------------------- adopt

# 人間が UI で並べた端末を席として取り込む。
# orca の CLI はタブ「領域」の分割を持たない（terminal split はタブ内のペイン分割、
# tab コマンドはブラウザ用）。複数のタブ領域を横に並べるのは UI 操作でしかできず、
# visualLayouts も読み取り専用で null が返る。したがってレイアウトは人間が作り、
# skill はその結果を role に対応づける。herdr 版が adopt を持っていたのと同じ理由。
#
# 取り込んだ席は created_by_skill=false として記録するので、down は閉じない。
cmd_adopt() {
  local pairs=("$@")
  [ "${#pairs[@]}" -gt 0 ] || die "--map <role>=<handle> を1つ以上指定する（handle は \`orca terminal list\` で確認）"
  step "orca-agent-team adopt: $TEAM"
  local p role handle
  for p in "${pairs[@]}"; do
    [ -n "$p" ] || continue
    role="${p%%=*}"; handle="${p#*=}"
    [ "$role" != "$p" ] || die "--map の形式は <role>=<handle>: $p"
    roles | grep -qx "$role" || die "設定に無いロール: $role"
    handle_alive "$handle" || die "$role: 端末が見つからない ($handle)"
    info "$role: $handle を取り込む"
    run orca terminal rename --terminal "$handle" --title "$role" --json >/dev/null 2>&1 || true
    remember_handle "$role" "$handle" false
  done
  info "取り込み完了。agent の起動と topology の記録は \`up\` が行う"
}

cmd_status() {
  step "orca-agent-team status: $TEAM"
  printf '  %-16s %-10s %-8s %-38s %s\n' ROLE KIND WORKTREE HANDLE STATE
  local r handle state
  while read -r r; do
    handle="$(known_handle "$r")"
    if [ -z "$handle" ]; then state="未配備"
    elif handle_alive "$handle"; then state="alive"
    else state="\033[31mdead\033[0m"; fi
    printf "  %-16s %-10s %-8s %-38s $state\n" \
      "$r" "$(role_field "$r" kind)" "$(role_field "$r" worktree)" "${handle:--}"
  done < <(roles)
  printf '\n'
  info "Run: $(jq -r '.run_id // "(未作成)"' <<<"$CFG")"
  validate_topology
}

# ------------------------------------------------------------------ down

cmd_down() {
  step "orca-agent-team down: ${TEAM}（この skill が作った端末のみ閉じる）"
  local r handle
  while read -r r; do
    handle="$(known_handle "$r")"
    [ -n "$handle" ] || continue
    if [ "$(known_created_by_skill "$r")" != "true" ]; then
      info "$r: caller 席なので閉じない"
      continue
    fi
    handle_alive "$handle" || { info "$r: 既に停止している"; continue; }
    info "$r: 閉じる $handle"
    run orca terminal close --terminal "$handle" --json >/dev/null 2>&1 || warn "$r: close に失敗"
  done < <(roles)
  info "topology と Run は残してある（再配備は up）"
}

# ---------------------------------------------------------------- doctor

APPROVAL_RE='(y/n|\[y/N\]|approve|permission|do you trust|trust the contents|do you want|allow\?|press enter to continue|^ *›? *1\. )'
LIMIT_RE='usage limit|rate limit|try again at|quota|purchase more credits'

cmd_doctor() {
  step "orca-agent-team doctor: $TEAM"
  local r handle screen issues=0
  while read -r r; do
    handle="$(known_handle "$r")"
    if [ -z "$handle" ]; then warn "$r: 未配備"; issues=$((issues+1)); continue; fi
    if ! handle_alive "$handle"; then warn "$r: 端末が落ちている ($handle)"; issues=$((issues+1)); continue; fi
    screen="$(orca terminal read --terminal "$handle" --screen --json 2>/dev/null \
      | jq -r '.result.terminal.tail[]? // empty' | tail -40)"
    if grep -qiE "$LIMIT_RE" <<<"$screen"; then
      warn "$r: 利用上限らしき表示（別アカウントに切り替えて起動し直す）"; issues=$((issues+1))
    elif grep -qiE "$APPROVAL_RE" <<<"$screen"; then
      warn "$r: 承認待ちらしき表示（このタブを見て応答する）"; issues=$((issues+1))
    else
      info "$r: 異常なし"
    fi
  done < <(roles)
  validate_topology
  [ "$issues" = 0 ] && step "問題なし" || step "$issues 件の指摘（自動修復はしない）"
}

# ------------------------------------------------------------------ main

usage() {
  cat <<'EOF'
orca-agent-team — intent-cli の四ロール席を orca に配備する

  orca-team.sh init --team <name> --domain <d> --host-repo <path> --impl-repo <path>
                    [--kind <role>=<v>] [--model <role>=<v>] [--effort <role>=<v>]
  orca-team.sh up     --team <name> [--dry-run]
  orca-team.sh status --team <name>
  orca-team.sh down   --team <name> [--dry-run]
  orca-team.sh doctor --team <name>

配置: host worktree に design / orchestrator / review（1タブ3ペイン）、
      impl worktree に implementation（別タブ、サンドボックス境界のため）。
配送: 全席 external + herdr-only モード。herdr も agmsg も使わない。

委譲・レビュー・publish の作法は `intent-cli guide ...` が正本。この skill は扱わない。
EOF
}

main() {
  local sub="${1:-}"; shift || true
  local domain="" host_repo="" impl_repo=""
  local overrides=() maps=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --team)      TEAM="$2"; shift 2 ;;
      --domain)    domain="$2"; shift 2 ;;
      --host-repo) host_repo="$2"; shift 2 ;;
      --impl-repo) impl_repo="$2"; shift 2 ;;
      --kind|--model|--effort) overrides+=("${1#--}:$2"); shift 2 ;;
      --map)       maps+=("$2"); shift 2 ;;
      --dry-run)   DRY_RUN=1; shift ;;
      --topology-only) TOPOLOGY_ONLY=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      *) die "不明なオプション: $1" ;;
    esac
  done
  [ -n "$sub" ] || { usage; exit 1; }
  [ -n "$TEAM" ] || die "--team が必要"

  case "$sub" in
    init)   cmd_init "$domain" "$host_repo" "$impl_repo" ${overrides+"${overrides[@]}"} ;;
    adopt)  require_env; load_config; cmd_adopt ${maps+"${maps[@]}"} ;;
    layout) require_env; load_config; cmd_layout ;;
    up)     require_env; load_config; cmd_up ;;
    status) require_env; load_config; cmd_status ;;
    down)   require_env; load_config; cmd_down ;;
    doctor) require_env; load_config; cmd_doctor ;;
    *) die "不明なサブコマンド: $sub" ;;
  esac
}

main "$@"
