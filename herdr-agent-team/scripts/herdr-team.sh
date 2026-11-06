#!/usr/bin/env bash
# herdr-agent-team — 役割ごとの席を herdr-core（hc）の端末として design のタブに分割して並べ、
# orchestrator が hc send / hc wait で仕事を渡して結果を受け取る。
#
#   design（Herdr app の端末の中のセッション）: init / up / tell / status / down
#   orchestrator（up が起動する）              : tell / wait / status
#
# 持つのは hc と herdr-app の機械的な操作だけ。何を委譲するか・どう判断するかは持たない
# （references/boundaries.md）。

set -euo pipefail

CONFIG_DIR="${HERDR_TEAM_CONFIG_DIR:-$HOME/.config/herdr-agent-team}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/herdr-team.sh"
TEAM=""
CFG=""

die()  { printf 'ERROR %s\n' "$*" >&2; exit 1; }
warn() { printf '! %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*" >&2; }

cfg_file() { printf '%s/%s.json' "$CONFIG_DIR" "$TEAM"; }
team_dir() { printf '%s/%s' "$CONFIG_DIR" "$TEAM"; }
seat()     { printf '%s-%s' "$TEAM" "$1"; }

load_config() {
  [ -n "$TEAM" ] || die "--team が要る"
  [ -f "$(cfg_file)" ] || die "team 設定が無い: $(cfg_file)（先に init を実行する）"
  CFG="$(cat "$(cfg_file)")"
}
role_field() { jq -r --arg r "$1" --arg f "$2" '.roles[] | select(.role == $r) | .[$f] // empty' <<<"$CFG"; }
seat_roles() { jq -r '.roles[] | select(.caller != true) | .role' <<<"$CFG"; }

# 生きている端末の JSON。無ければ失敗する（hc get は名前が無いと exit 3）。
live() { local j; j="$(hc get "$1" --json 2>/dev/null)" && [ "$(jq -r '.state' <<<"$j")" = live ] && printf '%s' "$j"; }

# design の端末 = 最後に up を実行した端末（up が設定に書く）。
# orchestrator を design の子にしないのは、Herdr app の Agents 一覧で design の行の下にチーム全体が木として重なるため。
design_terminal() { jq -r '.design // empty' <<<"$CFG"; }

# kind-flags.json から起動の argv を ARGV に組む。task が空なら最初の入力を付けない。
build_argv() {
  local role="$1" task="${2:-}" kind tmpl key val envs=() flags=() k
  kind="$(role_field "$role" kind)"; [ -n "$kind" ] || die "$role: kind が無い"
  tmpl="$SKILL_DIR/config/kind-flags.json"
  jq -e --arg k "$kind" '.kinds[$k]' "$tmpl" >/dev/null || die "$role: kind '$kind' は kind-flags.json に無い"
  expand() {  # expand <jq path> <key> <value> → 置換したトークンを 1 行ずつ
    jq -r --arg k "$kind" --arg f "$1" --arg key "$2" --arg v "$3" --arg home "$HOME" \
      '.kinds[$k][$f] // [] | .[] | gsub("\\{" + $key + "\\}"; $v) | gsub("\\{home\\}"; $home)' "$tmpl"
  }
  while IFS= read -r k; do flags+=("$k"); done < <(jq -r --arg k "$kind" '.kinds[$k].args // [] | .[]' "$tmpl")
  for key in account model effort tier; do
    val="$(role_field "$role" "$key")"; [ -n "$val" ] || continue
    if jq -e --arg k "$kind" --arg f "${key}_env" '.kinds[$k][$f]' "$tmpl" >/dev/null; then
      while IFS= read -r k; do envs+=("$k"); done < <(expand "${key}_env" "$key" "$val")
    elif jq -e --arg k "$kind" --arg f "$key" '.kinds[$k][$f]' "$tmpl" >/dev/null; then
      while IFS= read -r k; do flags+=("$k"); done < <(expand "$key" "$key" "$val")
    else
      warn "$role: kind '$kind' は $key を受けない（無視する）"
    fi
  done
  if [ -n "$task" ]; then
    while IFS= read -r k; do flags+=("$k"); done < <(expand task task "$task")
  fi
  ARGV=()
  [ ${#envs[@]} -eq 0 ] || ARGV=(env "${envs[@]}")
  ARGV+=("$kind" "${flags[@]+"${flags[@]}"}")
}

# 席のセッションを新しくする（config/kind-flags.json の new_session）。
# hc send は送り手の端末 ID があると本文を <hc from=…> で囲み、スラッシュコマンドが効かないので、ID を外して送る。
new_session() {
  local role="$1" name kind ns text k i
  name="$(seat "$role")"; kind="$(role_field "$role" kind)"
  ns="$(jq -c --arg k "$kind" '.kinds[$k].new_session // empty' "$SKILL_DIR/config/kind-flags.json")"
  [ -n "$ns" ] || die "$role: kind '$kind' の new_session が kind-flags.json に無い"
  text="$(jq -r '.send // empty' <<<"$ns")"
  [ -z "$text" ] || env -u HC_TERMINAL_ID hc send "$name" "$text" >/dev/null
  for k in $(jq -r '.keys // [] | .[]' <<<"$ns"); do hc keys "$name" "$k" >/dev/null; sleep 0.3; done
  text="$(jq -r '.confirm // empty' <<<"$ns")"
  if [ -n "$text" ]; then
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if hc read "$name" --lines 20 | grep -qF "$text"; then hc keys "$name" enter >/dev/null; break; fi
      sleep 0.5  # ダイアログは非同期に出る。hc wait --output は wait の後の出力しか見ないので使えない
    done
  fi
  sleep 1  # 新しいセッションの入力欄が出るのを待つ。状態の報告は変わらない（idle のまま）ので hc wait では待てない
  info "$role: セッションを新しくした"
}

# 指示書の単位 = ファイル名 <unit>-<role>-<n>.md の <unit>。
envelope_unit() {
  local b; b="$(basename "$1" .md)"; b="${b%-*}"
  [ "${b%-"$2"}" != "$b" ] || die "指示書の名前が <unit>-$2-<n>.md でない: $(basename "$1")。席ごとの指示書を $(team_dir)/envelopes/<unit>-$2-<n>.md に書いて送る（元の指示書はその中でパスで指す）"
  printf '%s' "${b%-"$2"}"
}

orchestrator_task() {
  printf 'You are the orchestrator seat of herdr-agent-team team "%s". Read %s/references/orchestrator.md and follow it. Script: bash %s --team %s. Your seats are your children; reach design with `tell --role design`.' \
    "$TEAM" "$SKILL_DIR" "$SCRIPT" "$TEAM"
}

# 席のレーン: implementation と review の組。role の末尾の -N が番号で、無ければ 1。
lane() { [[ "$1" =~ -([0-9]+)$ ]] && printf '%s' "${BASH_REMATCH[1]}" || printf 1; }

# 端末の Herdr app のペイン。ペインが無ければ空。
pane_of() { herdr-app ls 2>/dev/null | jq -r --arg t "$1" '[.spaces[].tabs[].terminals[] | select(.terminal == $t) | .pane][0] // empty'; }

# ペインの無い端末 $1 を、端末 $2 のペインの $3（right / down）に出す。$2 が空なら新しいタブに出し、タブの id を返す。
show() {
  local addr; addr="$(hc get "$1" --json | jq -r .address)"
  [ -z "$(pane_of "$addr")" ] || return 0
  local tab i
  if [ -n "$2" ]; then
    herdr-app do pane.focus --terminal "$2" >/dev/null
    tab="$(herdr-app do terminal.keep --terminal "$addr" --place "$3" | jq -r .tab)"
  else
    tab="$(herdr-app do terminal.keep --terminal "$addr" | jq -r .tab)"
  fi
  # keep は pending を返し、ペインは後からできる。次の分割はこのペインを起点にするので、できるまで待つ。
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(pane_of "$addr")" ] && break; sleep 0.5; done
  [ -n "$(pane_of "$addr")" ] || { warn "$1 のペインができない"; return 1; }
  printf '%s' "$tab"
}

# 席を並べる: design のタブに「design | orchestrator | レーン 1 の implementation / review（上下）」、
# レーン 2 以降は 1 レーン 1 タブ（上下）。
arrange() {
  local me="$1" orch role top fresh="" tab
  command -v herdr-app >/dev/null 2>&1 || { warn "herdr-app が無い（席はペインに出していない）"; return 0; }
  [ -n "$(pane_of "$me")" ] || { warn "Herdr app に design のペインが見えない（席はペインに出していない）"; return 0; }
  orch="$(hc get "$(seat orchestrator)" --json | jq -r .address)"
  [ -n "$(pane_of "$orch")" ] || fresh=1
  show "$(seat orchestrator)" "$me" right >/dev/null
  declare -A tops=()
  for role in $(seat_roles); do
    [ "$role" = orchestrator ] && continue
    local l; l="$(lane "$role")"
    if [ -z "${tops[$l]:-}" ]; then
      tops[$l]="$(hc get "$(seat "$role")" --json | jq -r .address)"
      if [ "$l" = 1 ]; then show "$(seat "$role")" "$orch" right >/dev/null
      else tab="$(show "$(seat "$role")" "" "")"; [ -z "$tab" ] || herdr-app do tab.rename --id "$tab" --name "$TEAM-$l" >/dev/null || true
      fi
    else
      show "$(seat "$role")" "${tops[$l]}" down >/dev/null
    fi
  done
  # 幅は design 45%・orchestrator 20%・右の列 35%。右の列の重みは、orchestrator を半分に割った 0.25 のまま残る。
  # shortcut: 割る前の design の重みが 1（タブに design だけ）のときしか比が合わない。design のタブに他のペインがあるなら doc.get の木から列の id を引いて直す。
  if [ -n "$fresh" ]; then
    herdr-app do layout.resize --id "$(pane_of "$me")" --weight 0.321 >/dev/null || warn "design の幅を変えられなかった"
    herdr-app do layout.resize --id "$(pane_of "$orch")" --weight 0.143 >/dev/null || warn "orchestrator の幅を変えられなかった"
  fi
  herdr-app do pane.focus --terminal "$me" >/dev/null || true
}

# ----------------------------------------------------------------- commands

cmd_init() {
  local repo="" sets=() s role key val c
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
  c="$(jq --arg t "$TEAM" --arg r "$repo" '{team: $t, repo: $r, roles: .roles}' "$SKILL_DIR/config/defaults.json")"
  for s in "${sets[@]+"${sets[@]}"}"; do   # --set implementation.account=labteam / --set implementation-2.kind=opencode
    role="${s%%.*}"; key="${s#*.}"; val="${key#*=}"; key="${key%%=*}"
    if ! jq -e --arg r "$role" '.roles[] | select(.role == $r)' <<<"$c" >/dev/null; then
      info "役割を足す: $role"
      c="$(jq --arg r "$role" '.roles += [{role: $r}]' <<<"$c")"
    fi
    c="$(jq --arg r "$role" --arg k "$key" --arg v "$val" '(.roles[] | select(.role == $r))[$k] = $v' <<<"$c")"
  done
  # hc の名前は 1〜32 文字の a-z 0-9 - _ で、生きている端末の中で一意。
  for role in $(jq -r '.roles[] | select(.caller != true) | .role' <<<"$c"); do
    [[ "$TEAM-$role" =~ ^[a-z0-9_-]{1,32}$ ]] || die "端末の名前 '$TEAM-$role' が hc の規則（a-z 0-9 - _、32 文字まで）に合わない"
  done
  mkdir -p "$(team_dir)/envelopes"
  [ ! -f "$(cfg_file)" ] || warn "既存の設定を上書きする: $(cfg_file)"
  printf '%s\n' "$c" > "$(cfg_file)"
  jq -r '.roles[] | "  \(.role)\t\(if .caller then "caller" else "\(.kind) \(.model // "-") \(.effort // "-") \(.account // "-")" end)"' <<<"$c"
  info "設定: $(cfg_file)"
  info "指示書の置き場: $(team_dir)/envelopes/"
}

cmd_up() {
  load_config
  [ -n "${HC_TERMINAL_ID:-}" ] || die "HC_TERMINAL_ID が空。Herdr app の端末の中から実行すること"
  local me repo role name l
  me="$HC_TERMINAL_ID"
  repo="$(jq -r '.repo' <<<"$CFG")"
  declare -A per=()
  for role in $(seat_roles); do
    [ "$role" = orchestrator ] && continue
    l="$(lane "$role")"; per[$l]=$(( ${per[$l]:-0} + 1 ))
    [ "${per[$l]}" -le 2 ] || die "レーン $l に席が 3 つ以上ある（1 レーンは implementation と review の 2 席まで）"
  done
  CFG="$(jq --arg d "$me" '.design = $d' <<<"$CFG")"
  printf '%s\n' "$CFG" > "$(cfg_file)"

  if live "$(seat orchestrator)" >/dev/null; then
    info "orchestrator: 既に動いている（$(seat orchestrator)）"
  else
    build_argv orchestrator "$(orchestrator_task)"
    info "orchestrator: ${ARGV[*]:0:6} …"
    hc run --bg --json --name "$(seat orchestrator)" --cwd "$repo" --no-parent --label herdr-team.role=orchestrator -- "${ARGV[@]}" >/dev/null
  fi
  for role in $(seat_roles); do
    [ "$role" = orchestrator ] && continue
    name="$(seat "$role")"
    if live "$name" >/dev/null; then info "$role: 既に動いている（${name}）"; continue; fi
    build_argv "$role"
    info "$role: ${ARGV[*]}"
    hc run --bg --json --name "$name" --cwd "$repo" --parent "$(seat orchestrator)" --label "herdr-team.role=$role" -- "${ARGV[@]}" >/dev/null
  done
  arrange "$me"
  cmd_status
}

cmd_tell() {
  load_config
  local role="" text="" envelope="" target
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) role="$2"; shift 2 ;;
      --text) text="$2"; shift 2 ;;
      --envelope) envelope="$2"; shift 2 ;;
      *) die "tell: 不明な引数 $1" ;;
    esac
  done
  [ -n "$role" ] || die "--role が要る"
  if [ -n "$envelope" ]; then
    [ -f "$envelope" ] || die "指示書が無い: $envelope"
    text="Read and execute the task envelope at $(cd "$(dirname "$envelope")" && pwd)/$(basename "$envelope")"
  fi
  [ -n "$text" ] || die "--text か --envelope が要る"
  # 長い文は端末に送らない。指示はファイルに書いてパスを送る。
  [ "${#text}" -le 400 ] || die "1 行が長すぎる（${#text} 文字）。ファイルに書いて --envelope で送る"
  if [ "$role" = design ]; then target="$(design_terminal)"; else target="$(seat "$role")"; fi
  [ -n "$target" ] || die "$role の端末が分からない"
  # 席は単位ごとに新しいセッションで始め、単位の中は続ける。記録の無い席（up の直後）も新しくする。
  local unit="" seats_file last
  seats_file="$(team_dir)/seats.json"
  if [ -n "$envelope" ] && [ "$role" != design ] && [ "$role" != orchestrator ]; then
    unit="$(envelope_unit "$envelope" "$role")"
    last="$(jq -r --arg r "$role" '.[$r] // empty' "$seats_file" 2>/dev/null || true)"
    if [ "$unit" != "$last" ]; then
      [ "$(live "$target" | jq -r '.status.state // empty')" != working ] || die "$role は作業中。単位を変える前に終わりを待つ"
      new_session "$role"
    fi
  fi
  # blocked の相手には送れない（hc が断る）。断られたら画面を読んで判断する。
  hc send "$target" "$text"
  if [ -n "$unit" ]; then
    jq --arg r "$role" --arg u "$unit" '.[$r] = $u' "$seats_file" 2>/dev/null > "$seats_file.tmp" || jq -n --arg r "$role" --arg u "$unit" '{($r): $u}' > "$seats_file.tmp"
    mv "$seats_file.tmp" "$seats_file"
  fi
}

cmd_wait() {
  # 子の知らせ（turn の終わり・blocked・error・終了）か、自分宛ての send が来るまで待つ。
  exec hc wait --children any "$@"
}

cmd_status() {
  load_config
  local role name j
  printf '%-16s %-26s %-6s %-9s %s\n' role terminal id state msg
  for role in $(seat_roles); do
    name="$(seat "$role")"
    if j="$(live "$name")"; then
      jq -r --arg r "$role" --arg n "$name" '"\($r)\t\($n)\t\(.address)\t\(.status.state // "-")\t\(.status.msg // "" | .[0:60])"' <<<"$j" \
        | awk -F'\t' '{printf "%-16s %-26s %-6s %-9s %s\n", $1, $2, $3, $4, $5}'
    else
      printf '%-16s %-26s %-6s %-9s\n' "$role" "$name" - down
    fi
  done
}

cmd_down() {
  load_config
  local role name
  # 席は orchestrator の子なので、orchestrator を終えると一緒に終わる。念のため名前で全部閉じる。
  for role in $(seat_roles | sort -r); do
    name="$(seat "$role")"
    live "$name" >/dev/null || continue
    hc kill "$name" >/dev/null 2>&1 || warn "$name を終えられなかった"
  done
  for role in $(seat_roles); do hc rm "$(seat "$role")" >/dev/null 2>&1 || true; done
  rm -f "$(team_dir)/seats.json"
  info "チーム $TEAM の端末を閉じた"
}

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

usage: herdr-team.sh <command> --team <T> [options]
  init   --team T [--repo R] [--set role.key=value ...]
  up     --team T
  tell   --team T --role <role|design> (--envelope <file> | --text <1行>)
  wait   --team T [--timeout <s>]
  status --team T
  down   --team T
EOF
}

main() {
  command -v hc >/dev/null 2>&1 || die "hc が PATH にない"
  command -v jq >/dev/null 2>&1 || die "jq が PATH にない"
  local cmd="${1:-}"; [ $# -gt 0 ] && shift
  local rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --team) TEAM="$2"; shift 2 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  set -- "${rest[@]+"${rest[@]}"}"
  case "$cmd" in
    init|up|tell|wait|status|down) "cmd_$cmd" "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "不明なコマンド: $cmd" ;;
  esac
}

main "$@"
