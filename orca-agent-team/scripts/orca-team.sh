#!/usr/bin/env bash
# orca-agent-team — 役割ごとの席を orca のタブに立て、orchestrator が worker として仕事を渡す。
#
#   design（このセッション）   : init / up / tell / status / doctor / down
#   orchestrator（up が立てる）: run / seat / delegate / wait / ack / settle / tell / status / doctor
#
# 持つのは orca の端末と orchestration の機械的な操作だけ。何を委譲するか・どう判断するかは持たない
# （references/boundaries.md）。

set -euo pipefail

CONFIG_DIR="${ORCA_TEAM_CONFIG_DIR:-$HOME/.config/orca-agent-team}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM=""
CFG=""

die()  { printf 'ERROR %s\n' "$*" >&2; exit 1; }
warn() { printf '! %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*" >&2; }

require_orca() {
  command -v orca >/dev/null 2>&1 || die "orca が PATH にない"
  command -v jq   >/dev/null 2>&1 || die "jq が PATH にない"
}
require_in_orca() {
  [ -n "${ORCA_TERMINAL_HANDLE:-}" ] || die "ORCA_TERMINAL_HANDLE が空。orca の端末の中から実行すること"
  [ -n "${ORCA_WORKTREE_ID:-}" ]     || die "ORCA_WORKTREE_ID が空。orca の端末の中から実行すること"
}

cfg_file()   { printf '%s/%s.json' "$CONFIG_DIR" "$TEAM"; }
state_file() { printf '%s/%s.state.json' "$CONFIG_DIR" "$TEAM"; }
team_dir()   { printf '%s/%s' "$CONFIG_DIR" "$TEAM"; }

load_config() {
  [ -n "$TEAM" ] || die "--team が要る"
  [ -f "$(cfg_file)" ] || die "team 設定が無い: $(cfg_file)（先に init を実行する）"
  CFG="$(cat "$(cfg_file)")"
  [ -f "$(state_file)" ] || printf '{"run_id":null,"seats":{}}\n' > "$(state_file)"
}
role_field() { jq -r --arg r "$1" --arg f "$2" '.roles[] | select(.role == $r) | .[$f] // empty' <<<"$CFG"; }
has_role()   { jq -e --arg r "$1" '.roles[] | select(.role == $r)' <<<"$CFG" >/dev/null; }
title_of()   { local t; t="$(role_field "$1" title)"; printf '%s' "${t:-$1}"; }

state_set() {  # state_set <jq filter> [--arg k v ...]
  local f tmp; f="$(state_file)"; tmp="$(mktemp)"
  jq "${@:2}" "$1" "$f" > "$tmp" && mv "$tmp" "$f"
}

# ------------------------------------------------------------------ terminals

# 端末が使えるか。閉じた handle も show は ok を返すので writable と exitCause まで見る。
handle_alive() {
  [ -n "${1:-}" ] || return 1
  orca terminal show --terminal "$1" --json 2>/dev/null \
    | jq -e '.ok == true and .result.terminal.writable == true and (.result.terminal.exitCause == null)' >/dev/null 2>&1
}
pane_key_of() {
  orca terminal show --terminal "$1" --json 2>/dev/null | jq -r '.result.terminal | "\(.tabId):\(.leafId)"'
}
# 席の handle を引く。orca を再起動すると handle は変わるが、タブの位置（paneKey）は保たれる
# （2026-09-28 実測）ので、記録した paneKey から引き直す。
seat_handle() {
  local role="$1" h pk
  h="$(jq -r --arg r "$role" '.seats[$r].handle // empty' "$(state_file)")"
  if handle_alive "$h"; then printf '%s' "$h"; return 0; fi
  pk="$(jq -r --arg r "$role" '.seats[$r].pane_key // empty' "$(state_file)")"
  [ -n "$pk" ] || return 1
  h="$(orca terminal list --json 2>/dev/null | jq -r --arg pk "$pk" \
        '.result.terminals[]? | select("\(.tabId):\(.leafId)" == $pk and .writable == true) | .handle' | head -1)"
  [ -n "$h" ] || return 1
  state_set '.seats[$r].handle = $h' --arg r "$role" --arg h "$h"
  printf '%s' "$h"
}
remember_seat() {  # role handle created_by_skill
  local pk; pk="$(pane_key_of "$2")"
  state_set '.seats[$r] = {handle: $h, pane_key: $pk, created_by_skill: ($c == "true")}' \
    --arg r "$1" --arg h "$2" --arg pk "$pk" --arg c "$3"
}

# kind-flags.json を引いて起動コマンドを組む。値は @sh で quoting する。
launch_command() {
  local role="$1" kind model effort account tier tmpl out
  kind="$(role_field "$role" kind)"; model="$(role_field "$role" model)"
  effort="$(role_field "$role" effort)"; account="$(role_field "$role" account)"; tier="$(role_field "$role" tier)"
  [ -n "$kind" ] || die "$role: kind が無い"
  tmpl="$SKILL_DIR/config/kind-flags.json"
  out="$kind"
  if jq -e --arg k "$kind" '.kinds[$k]' "$tmpl" >/dev/null; then
    local key val
    for key in account model effort tier; do
      val="$(eval "printf '%s' \"\$$key\"")"
      [ -n "$val" ] || continue
      # account_before: アカウントをフラグでなく、agent の前に走らせるコマンドで切り替える kind（codex の cx）。
      if [ "$key" = account ] && jq -e --arg k "$kind" '.kinds[$k].account_before' "$tmpl" >/dev/null; then
        out="$(jq -r --arg k "$kind" --arg v "$val" \
          '.kinds[$k].account_before | map(gsub("\\{account\\}"; $v) | @sh) | join(" ")' "$tmpl") && $out"
      elif jq -e --arg k "$kind" --arg f "$key" '.kinds[$k][$f]' "$tmpl" >/dev/null; then
        out+=" $(jq -r --arg k "$kind" --arg f "$key" --arg v "$val" \
          '.kinds[$k][$f] | map(gsub("\\{" + $f + "\\}"; $v) | @sh) | join(" ")' "$tmpl")"
      else
        warn "$role: kind '$kind' は $key を受けない（無視する）"
      fi
    done
  elif [ -n "$model$effort$account$tier" ]; then
    warn "$role: kind '$kind' は kind-flags.json に無い: model/effort/account/tier を無視する"
  fi
  printf '%s' "$out"
}

# 席のタブを作って agent を起動する。既に生きていれば再利用する。
ensure_seat() {
  local role="$1" h cmd out
  if h="$(seat_handle "$role")"; then printf '%s' "$h"; return 0; fi
  cmd="$(launch_command "$role")"
  info "$role: タブ '$(title_of "$role")' を作る: $cmd"
  out="$(orca terminal create --worktree "id:$ORCA_WORKTREE_ID" --title "$(title_of "$role")" --command "$cmd" --json)"
  h="$(jq -r '.result.terminal.handle // empty' <<<"$out")"
  [ -n "$h" ] || die "$role: タブを作れなかった: $(jq -c '.error // .' <<<"$out")"
  remember_seat "$role" "$h" true
  # 入力待ちになるまで待つ。起動直後に送った入力は取りこぼしうる。
  orca terminal wait --terminal "$h" --for tui-idle --timeout-ms 90000 --json >/dev/null 2>&1 \
    || warn "$role: 入力待ちを確認できなかった（画面を確かめること）"
  printf '%s' "$h"
}

# 端末に1行だけ送る（長文は切れることがあるので、長い指示は必ずファイルにしてパスを送る）。
send_line() {
  local h="$1" line="$2" out code
  out="$(orca terminal send --terminal "$h" --text "$line" --enter --wait-submit 15 --json 2>/dev/null || true)"
  if [ "$(jq -r '.ok // false' <<<"$out")" = "true" ]; then return 0; fi
  code="$(jq -r '.error.code // "unknown"' <<<"$out")"
  if [ "$code" = "agent_prompt_blocked" ]; then
    die "送れない: 相手の端末でダイアログが出ている（orca が止めた）。端末を見て先に答えること"
  fi
  die "送信に失敗した: $code"
}
envelope_line() { printf 'Read and execute the task envelope at %s' "$1"; }

# ----------------------------------------------------------------- commands

cmd_init() {
  local repo="" sets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --set)  sets+=("$2"); shift 2 ;;
      *) die "init: 不明な引数 $1" ;;
    esac
  done
  [ -n "$TEAM" ] || die "--team が要る"
  [ -n "$repo" ] || repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -d "$repo" ] || die "--repo が要る（git の作業ツリー）"
  repo="$(cd "$repo" && pwd)"
  mkdir -p "$CONFIG_DIR" "$(team_dir)/envelopes"
  local c; c="$(jq --arg t "$TEAM" --arg r "$repo" '{team: $t, repo: $r, roles: .roles}' "$SKILL_DIR/config/defaults.json")"
  local s role key val
  for s in "${sets[@]+"${sets[@]}"}"; do   # --set implementation.account=labteam
    role="${s%%.*}"; key="${s#*.}"; val="${key#*=}"; key="${key%%=*}"
    jq -e --arg r "$role" '.roles[] | select(.role == $r)' <<<"$c" >/dev/null || die "未知の役割: $role"
    c="$(jq --arg r "$role" --arg k "$key" --arg v "$val" '(.roles[] | select(.role == $r))[$k] = $v' <<<"$c")"
  done
  if [ -f "$(cfg_file)" ]; then warn "既存の設定を上書きする: $(cfg_file)"; fi
  printf '%s\n' "$c" > "$(cfg_file)"
  [ -f "$(state_file)" ] || printf '{"run_id":null,"seats":{}}\n' > "$(state_file)"
  jq -r '.roles[] | "  \(.role)\t\(.title // .role)\t\(if .caller then "caller" else "\(.kind) \(.model // "-") \(.effort // "-") \(.account // "-")" end)"' <<<"$c"
  info "設定: $(cfg_file)"
  info "指示書の置き場: $(team_dir)/envelopes/"
}

cmd_up() {
  load_config; require_in_orca
  local caller h
  caller="$(jq -r '.roles[] | select(.caller == true) | .role' <<<"$CFG" | head -1)"
  if [ -n "$caller" ]; then
    remember_seat "$caller" "$ORCA_TERMINAL_HANDLE" false
    orca terminal rename --terminal "$ORCA_TERMINAL_HANDLE" --title "$(title_of "$caller")" --json >/dev/null 2>&1 || true
  fi
  has_role orchestrator || die "設定に orchestrator が無い"
  local fresh=1
  if h="$(seat_handle orchestrator)"; then
    fresh=0
    info "orchestrator: 既存のタブを使う (${h})"
  else
    h="$(ensure_seat orchestrator)"
  fi
  # 起動の指示を送ったかを記録する。途中で失敗した up をやり直したときに、送り直せるように。
  if [ "$fresh" = 0 ] && [ "$(jq -r '.seats.orchestrator.briefed // false' "$(state_file)")" = "true" ]; then
    return 0
  fi
  send_line "$h" "あなたはチーム '${TEAM}' の orchestrator です。最初に ${SKILL_DIR}/references/orchestrator.md を読み、その手順どおりに動いてください（スクリプトは bash ${SKILL_DIR}/scripts/orca-team.sh、--team ${TEAM}）。"
  state_set '.seats.orchestrator.briefed = true'
  info "orchestrator: 起動の指示を送った (${h})。仕事は tell --role orchestrator --envelope <file> で渡す"
}

cmd_run() {
  load_config; require_in_orca
  local rid out
  rid="$(jq -r '.run_id // empty' "$(state_file)")"
  if [ -n "$rid" ] && [ "$(jq -r '.run_coordinator // empty' "$(state_file)")" = "$ORCA_TERMINAL_HANDLE" ]; then
    orca orchestration run-use --id "$rid" --json >/dev/null 2>&1 && { info "Run を使う: $rid"; printf '%s\n' "$rid"; return 0; }
  fi
  out="$(orca orchestration run-create --objective "orca-agent-team $TEAM" --json)"
  rid="$(jq -r '.result.run.id // empty' <<<"$out")"
  [ -n "$rid" ] || die "Run を作れなかった: $(jq -c '.error // .' <<<"$out")"
  state_set '.run_id = $r | .run_coordinator = $h' --arg r "$rid" --arg h "$ORCA_TERMINAL_HANDLE"
  info "Run を作った: ${rid}（coordinator はこの端末）"
  printf '%s\n' "$rid"
}

cmd_seat() {
  local role=""
  while [ $# -gt 0 ]; do case "$1" in --role) role="$2"; shift 2 ;; *) die "seat: 不明な引数 $1" ;; esac; done
  load_config; require_in_orca
  [ -n "$role" ] && has_role "$role" || die "--role が要る（設定にある役割）"
  ensure_seat "$role"; printf '\n'
}

cmd_delegate() {
  local role="" env="" title=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) role="$2"; shift 2 ;; --envelope) env="$2"; shift 2 ;; --title) title="$2"; shift 2 ;;
      *) die "delegate: 不明な引数 $1" ;;
    esac
  done
  load_config; require_in_orca
  [ -n "$role" ] && has_role "$role" || die "--role が要る"
  [ -f "$env" ] || die "--envelope のファイルが無い: $env"
  env="$(cd "$(dirname "$env")" && pwd)/$(basename "$env")"
  local h out
  h="$(ensure_seat "$role")"
  out="$(orca orchestration worker-start --terminal "$h" --worktree current \
          --task-title "${title:-$role: $(basename "$env")}" \
          --spec "$(envelope_line "$env")" --timeout-ms 120000 --json 2>/dev/null || true)"
  jq -c '{ok, dispatchId: (.result.dispatchId // .result.worker.dispatchId // null), taskId: (.result.taskId // null),
          state: (.result.state // null), failedStage: (.result.failedStage // null), error: (.error.code // null),
          recovery: (.result.recovery // null)}' <<<"$out"
  [ "$(jq -r '.result.state // empty' <<<"$out")" = "ready" ] || exit 2
}

# 次の意味のあるメッセージ（worker_done / question / escalation）が来るまで待つ。
# --types で絞っても heartbeat は届く（2026-09-27 実測）ので、それだけの配達は ack して待ち直す。
# 意味のある配達は ack せずに返す。処理してから ack すること。
# check --json は整形された複数行の JSON を返すので、行ではなく JSON の値の単位で読む。
cmd_wait() {
  local total=900000
  while [ $# -gt 0 ]; do case "$1" in --timeout-ms) total="$2"; shift 2 ;; *) die "wait: 不明な引数 $1" ;; esac; done
  load_config; require_in_orca
  local deadline now left out dl types
  deadline=$(( $(date +%s) + total / 1000 ))
  while :; do
    now=$(date +%s); left=$(( (deadline - now) * 1000 ))
    [ "$left" -gt 0 ] || { printf '{"timedOut":true}\n'; exit 3; }
    [ "$left" -le 120000 ] || left=120000
    out="$(orca orchestration check --wait --types "worker_done,escalation,question" --timeout-ms "$left" --json 2>/dev/null \
            | jq -c 'select(._keepalive | not)' 2>/dev/null | tail -1)"
    [ -n "$out" ] || continue
    dl="$(jq -r '.result.deliveryId // empty' <<<"$out")"
    [ -n "$dl" ] || continue
    types="$(jq -r '[.result.messages[]?.type] | unique | join(",")' <<<"$out")"
    if [ -z "$types" ] || [ "$types" = "heartbeat" ]; then
      orca orchestration check --ack "$dl" --json >/dev/null 2>&1 || true
      continue
    fi
    jq -c '{deliveryId: .result.deliveryId, messages: [.result.messages[] | {id, type, subject, body, from: .from_handle, payload: (.payload | fromjson? // .)}]}' <<<"$out"
    return 0
  done
}

cmd_ack() {
  local d=""; while [ $# -gt 0 ]; do case "$1" in --delivery) d="$2"; shift 2 ;; *) die "ack: 不明な引数 $1" ;; esac; done
  load_config; require_in_orca; [ -n "$d" ] || die "--delivery が要る"
  orca orchestration check --ack "$d" --json | jq -c '{acknowledged: .result.acknowledged}'
}

# 完了した仕事を片付ける。席の端末はこの skill が作ったものなので閉じられず、次の仕事に使える。
cmd_settle() {
  local d=""; while [ $# -gt 0 ]; do case "$1" in --dispatch) d="$2"; shift 2 ;; *) die "settle: 不明な引数 $1" ;; esac; done
  load_config; require_in_orca; [ -n "$d" ] || die "--dispatch が要る"
  orca orchestration worker-release --dispatch "$d" --json | jq -c '{state: .result.state, processAction: .result.processAction, error: .error.code}'
}

cmd_tell() {
  local role="" env="" text=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) role="$2"; shift 2 ;; --envelope) env="$2"; shift 2 ;; --text) text="$2"; shift 2 ;;
      *) die "tell: 不明な引数 $1" ;;
    esac
  done
  load_config
  [ -n "$role" ] || die "--role が要る"
  local h; h="$(seat_handle "$role")" || die "$role の席が見つからない"
  if [ -n "$env" ]; then
    [ -f "$env" ] || die "--envelope のファイルが無い: $env"
    env="$(cd "$(dirname "$env")" && pwd)/$(basename "$env")"
    send_line "$h" "$(envelope_line "$env")"
  else
    [ -n "$text" ] || die "--envelope か --text が要る"
    case "$text" in *$'\n'*) die "--text は1行だけ。長い指示は --envelope にする" ;; esac
    send_line "$h" "$text"
  fi
  info "$role に送った"
}

cmd_status() {
  load_config
  printf 'team %s  repo %s  run %s\n' "$TEAM" "$(jq -r .repo <<<"$CFG")" "$(jq -r '.run_id // "-"' "$(state_file)")"
  local role h show
  for role in $(jq -r '.roles[].role' <<<"$CFG"); do
    h="$(seat_handle "$role" 2>/dev/null || true)"
    if [ -z "$h" ]; then printf '  %-15s %-15s -\n' "$role" "$(title_of "$role")"; continue; fi
    show="$(orca terminal show --terminal "$h" --json 2>/dev/null)"
    printf '  %-15s %-15s %s  agent=%s  wait=%s\n' "$role" "$(title_of "$role")" "$h" \
      "$(jq -r '.result.terminal.agentIdentity // "-"' <<<"$show")" \
      "$(jq -r '.result.terminal.agentWait.reason // .result.terminal.agentWait.source // "-"' <<<"$show")"
  done
}

# 承認待ち・利用上限を画面から拾う。自動では何も答えない。
cmd_doctor() {
  load_config
  local role h tail rc=0
  local approval='(y/n|\[y/N\]|approve|permission|do you trust|trust this folder|do you want|allow\?|press enter to confirm|enter to confirm|esc to cancel)'
  local limit='(usage limit|rate limit|quota|limit reached|try again (later|in))'
  for role in $(jq -r '.roles[] | select(.caller != true) | .role' <<<"$CFG"); do
    h="$(seat_handle "$role" 2>/dev/null || true)"
    [ -n "$h" ] || { printf '  %-15s 席なし\n' "$role"; continue; }
    tail="$(orca terminal read --terminal "$h" --screen --limit 40 --json 2>/dev/null | jq -r '.result.terminal.tail[]?' || true)"
    if grep -qiE "$approval" <<<"$tail"; then printf '  %-15s 承認待ちの可能性（%s を見ること）\n' "$role" "$h"; rc=1
    elif grep -qiE "$limit" <<<"$tail"; then printf '  %-15s 利用上限の可能性（アカウントを確かめること）\n' "$role"; rc=1
    else printf '  %-15s ok\n' "$role"; fi
  done
  return $rc
}

cmd_down() {
  load_config
  local role h
  for role in $(jq -r '.roles[] | select(.caller != true) | .role' <<<"$CFG"); do
    [ "$(jq -r --arg r "$role" '.seats[$r].created_by_skill // false' "$(state_file)")" = "true" ] || continue
    h="$(seat_handle "$role" 2>/dev/null || true)"
    [ -n "$h" ] || continue
    orca terminal close --terminal "$h" --tab --json >/dev/null 2>&1 && info "$role: タブを閉じた" || warn "$role: 閉じられなかった ($h)"
    state_set 'del(.seats[$r])' --arg r "$role"
  done
}

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

  init     --team T [--repo PATH] [--set role.key=value ...]
  up       --team T                                  design: orchestrator のタブを立てる
  run      --team T                                  orchestrator: 自分の Run を作る / 使う
  seat     --team T --role R                         席のタブを立てる（delegate が自動で呼ぶ）
  delegate --team T --role R --envelope F [--title]  席に1件の仕事を worker として渡す
  wait     --team T [--timeout-ms N]                 次の worker_done / question / escalation まで待つ
  ack      --team T --delivery D                     処理した配達を ack する
  settle   --team T --dispatch D                     終わった仕事を片付ける（席は残る）
  tell     --team T --role R (--envelope F|--text S) 席に1行送る（design ↔ orchestrator の連絡）
  status   --team T
  doctor   --team T                                  承認待ち・利用上限を画面から拾う
  down     --team T                                  この skill が作ったタブを閉じる
EOF
}

main() {
  local sub="${1:-}"; shift || true
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in --team) TEAM="$2"; shift 2 ;; *) args+=("$1"); shift ;; esac
  done
  require_orca
  case "$sub" in
    init|up|run|seat|delegate|wait|ack|settle|tell|status|doctor|down) "cmd_$sub" "${args[@]+"${args[@]}"}" ;;
    ""|-h|--help|help) usage ;;
    *) die "不明なサブコマンド: $sub" ;;
  esac
}
main "$@"
