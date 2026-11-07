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
# チームの worktree の置き場所。席は単位ごとに <WORKSPACES>/<repo>/<unit> で起動し直す。
WORKSPACES="${HERDR_TEAM_WORKSPACES:-$HOME/herdr/workspaces}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/herdr-team.sh"
TEAM=""
CFG=""

die()  { printf 'ERROR %s\n' "$*" >&2; exit 1; }
warn() { printf '! %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*" >&2; }

cfg_file() { printf '%s/%s.json' "$CONFIG_DIR" "$TEAM"; }
team_dir() { printf '%s/%s' "$CONFIG_DIR" "$TEAM"; }
unit_dir() { printf '%s/%s/%s' "$WORKSPACES" "$(basename "$(jq -r '.repo' <<<"$CFG")")" "$1"; }
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
  for key in account model effort tier sandbox; do
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
  local tab="" out i
  # 起動した直後の端末は keep を断られることがある（tab の無い応答で失敗する）。少し待ってやり直す
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ -n "$2" ]; then
      herdr-app do pane.focus --terminal "$2" >/dev/null 2>&1 || true
      out="$(herdr-app do terminal.keep --terminal "$addr" --place "$3" 2>&1 || true)"
    else
      out="$(herdr-app do terminal.keep --terminal "$addr" 2>&1 || true)"
    fi
    tab="$(jq -r '.tab // empty' <<<"$out" 2>/dev/null || true)"
    [ -z "$tab" ] || break
    sleep 1
  done
  [ -n "$tab" ] || { warn "$1 をペインに出せない: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; return 1; }
  # keep は pending を返し、ペインは後からできる。次の分割はこのペインを起点にするので、できるまで待つ。
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(pane_of "$addr")" ] && break; sleep 0.5; done
  [ -n "$(pane_of "$addr")" ] || { warn "$1 のペインができない"; return 1; }
  printf '%s' "$tab"
}

# Herdr app が core に保存しているタブの分割の木（root）。herdr-app ls には木が出ない。
tab_tree() {
  # hc connect は stdin が閉じると応答を待たずに終わるので、送った後しばらく開けておく
  { printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"hello","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"doc.get","params":{"name":"herdr-app"}}'; sleep 2; } \
    | hc connect 2>/dev/null | jq -c --arg t "$1" 'select(.id == 2) | [.. | objects | select(.id? == $t and has("root")) | .root][0] // empty'
}

# design のタブの幅を design 45%・orchestrator 20%・右の列 35% にする。並びが違えば何もしない。
size_columns() {
  local me="$1" orch="$2" tab ids
  tab="$(herdr-app ls | jq -r --arg t "$me" '[.spaces[].tabs[] | select(any(.terminals[]; .terminal == $t)) | .id][0] // empty')"
  ids="$(tab_tree "$tab" | jq -r --arg d "$me" --arg o "$orch" '
    select(.type == "row" and (.children | length) == 3)
    | select(.children[0].content.terminal == $d and .children[1].content.terminal == $o and .children[2].type == "column")
    | .children | map(.id + ":" + ((.size.weight // 1) * 100 | round | tostring)) | @tsv')"
  [ -n "$ids" ] || { warn "design のタブが design | orchestrator | 右の列 の並びでない（幅は変えていない）"; return 0; }
  # 幅がもう目標どおりなら書かない。置いた直後のペインと同じタブの文書を続けて書くと、ペインの記録が消えることがある
  [ "$(printf '%s' "$ids" | tr '\t' '\n' | cut -d: -f2 | tr '\n' ' ')" != "45 20 35 " ] || return 0
  ids="$(printf '%s' "$ids" | tr '\t' '\n' | cut -d: -f1 | tr '\n' ' ')"
  set -- $ids
  herdr-app do layout.resize --id "$1" --weight 0.45 >/dev/null
  herdr-app do layout.resize --id "$2" --weight 0.20 >/dev/null
  herdr-app do layout.resize --id "$3" --weight 0.35 >/dev/null
}

# レーンの 2 席（上 $1・下 $2）のうちペインの無いほうを出す。上が無く下があるときは、下の下に出して上下を入れ替える。
# $3: 上を新しく出すときの基準（orchestrator の端末、空なら新しいタブ）。
show_lane() {
  local top="$1" bottom="$2" anchor="$3" t b tab=""
  t="$(hc get "$top" --json | jq -r .address)"
  b="$( [ -n "$bottom" ] && hc get "$bottom" --json | jq -r .address || true)"
  if [ -z "$(pane_of "$t")" ] && [ -n "$b" ] && [ -n "$(pane_of "$b")" ]; then
    show "$top" "$b" down >/dev/null || true
    herdr-app do pane.focus --terminal "$t" >/dev/null
    herdr-app do pane.swap --direction up >/dev/null
  elif [ -n "$anchor" ]; then
    show "$top" "$anchor" right >/dev/null || true
  else
    tab="$(show "$top" "" "" || true)"
  fi
  [ -z "$b" ] || show "$bottom" "$t" down >/dev/null || true
  printf '%s' "$tab"
}

# 席を並べる: design のタブに「design | orchestrator | レーン 1 の implementation / review（上下）」、
# レーン 2 以降は 1 レーン 1 タブ（上下）。ペインのある席は動かさず、無い席だけを正しい位置に足すので、
# 1 席だけ起動し直した後に呼んでも並びは崩れない。
arrange() {
  local me="$1" orch role l tab
  command -v herdr-app >/dev/null 2>&1 || { warn "herdr-app が無い（席はペインに出していない）"; return 0; }
  [ -n "$(pane_of "$me")" ] || { warn "Herdr app に design のペインが見えない（席はペインに出していない）"; return 0; }
  orch="$(hc get "$(seat orchestrator)" --json | jq -r .address)"
  show "$(seat orchestrator)" "$me" right >/dev/null || true
  declare -A top=() bottom=()
  for role in $(seat_roles); do
    [ "$role" = orchestrator ] && continue
    l="$(lane "$role")"
    if [ -z "${top[$l]:-}" ]; then top[$l]="$(seat "$role")"; else bottom[$l]="$(seat "$role")"; fi
  done
  for l in $(printf '%s\n' "${!top[@]}" | sort -n); do
    if [ "$l" = 1 ]; then show_lane "${top[$l]}" "${bottom[$l]:-}" "$orch" >/dev/null
    else
      tab="$(show_lane "${top[$l]}" "${bottom[$l]:-}" "")"
      [ -z "$tab" ] || herdr-app do tab.rename --id "$tab" --name "$TEAM-$l" >/dev/null || true
    fi
  done
  size_columns "$me" "$orch"
  herdr-app do pane.focus --terminal "$me" >/dev/null || true
}

# 席の端末を起こす（ペインは arrange が出す）。端末は user のふだんの login zsh で、agent はそこに打って起動し、
# agent が終わっても端末は zsh で残る。素の bash（--norc）にしないのは、nix-darwin の環境・agent-switch の shim・
# direnv の hook が通らず、agent のコマンドの zsh が PATH を初期化し直して devshell が消えたため（2026-11-07）。
# 端末を作り直して起動し直すと、古いペインが閉じる処理と新しいペインを置く処理が Herdr app の中で競合し、
# 新しいペインが後から消える（2026-11-06 に数回再現）。同じ端末の中で agent だけを起こし直せば、ペインに触らずに済む。
seat_is_zsh() { jq -e '.argv == ["zsh", "-il"]' >/dev/null; }
start_seat() {
  local role="$1" repo; repo="$(jq -r '.repo' <<<"$CFG")"
  hc run --bg --json --name "$(seat "$role")" --cwd "$repo" --parent "$(seat orchestrator)" --label "herdr-team.role=$role" \
    -- zsh -il >/dev/null
  launch_agent "$role" "$repo"
}

# 席の zsh に agent を打って起動し、入力を待つ状態（idle）になるまで待つ。信頼の確認は状態を報告しないので画面で見る。
# 確認に答えるのは skill が作った worktree（$WORKSPACES の下）だけ。それ以外のフォルダは design が判断する。
launch_agent() {
  local role="$1" cwd="$2" name trust prompt st i k
  name="$(seat "$role")"
  build_argv "$role"
  info "$role: ${ARGV[*]}（${cwd}）"
  # 送り手の端末 ID があると hc send は本文を <hc from> で囲み、shell がコマンドとして読めない
  env -u HC_TERMINAL_ID hc send "$name" "cd $(printf '%q' "$cwd") && $(printf '%q ' "${ARGV[@]}")" >/dev/null
  trust="$(jq -c --arg k "$(role_field "$role" kind)" '.kinds[$k].trust // empty' "$SKILL_DIR/config/kind-flags.json")"
  prompt="$(jq -r '.prompt // empty' <<<"${trust:-{\}}")"
  for i in $(seq 1 60); do
    sleep 1
    st="$(hc get "$name" --json | jq -r '.status.state // empty')"
    [ "$st" != idle ] && [ "$st" != done ] || break
    if [ -n "$prompt" ] && hc read "$name" --lines 30 | grep -qF "$prompt"; then
      if own_worktree "$cwd"; then
        for k in $(jq -r '.keys[]' <<<"$trust"); do hc keys "$name" "$k" >/dev/null; sleep 0.3; done
        info "$role: skill の worktree の信頼の確認に答えた（${cwd}）"
      else
        warn "$role に信頼の確認が出ている（${cwd}）。hc read $name で読み、design が答える"; break
      fi
    fi
  done
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
    start_seat "$role"
  done
  arrange "$me"
  cmd_status
}

# 席の agent を同じ端末の中で起動し直す（端末・ペイン・名前・親は変わらない）。$cwd を渡すとそこで起動する。
# orchestrator は対象外（design との約束を持つ。立て直すなら down と up）。
cmd_restart() {
  load_config
  local role="" cwd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) role="$2"; shift 2 ;;
      --cwd)  cwd="$2"; shift 2 ;;
      *) die "restart: 不明な引数 $1" ;;
    esac
  done
  [ -n "$role" ] || die "--role が要る"
  [ "$role" != orchestrator ] || die "orchestrator は restart しない（down と up で立て直す）"
  jq -e --arg r "$role" '.roles[] | select(.role == $r and .caller != true)' <<<"$CFG" >/dev/null || die "役割 $role が設定に無い"
  [ -n "$cwd" ] || cwd="$(jq -r '.repo' <<<"$CFG")"
  [ -d "$cwd" ] || die "ディレクトリが無い: $cwd"
  local name j pid i kids; name="$(seat "$role")"
  j="$(live "$name")" || die "$name が動いていない（up で起こす）"
  seat_is_zsh <<<"$j" || die "$name は login zsh の端末ではない（この版より前の up）。down と up で起こし直す"
  [ "$(jq -r '.status.state // empty' <<<"$j")" != working ] || die "$role は作業中。終わりを待ってから起動し直す"
  pid="$(jq -r '.pid' <<<"$j")"
  kids="$(pgrep -P "$pid" || true)"
  if [ -n "$kids" ]; then
    kill -TERM $kids 2>/dev/null || true
    for i in $(seq 1 20); do [ -z "$(pgrep -P "$pid" || true)" ] && break; sleep 0.5; done
    [ -z "$(pgrep -P "$pid" || true)" ] || die "$role の agent が終わらない（pid $(pgrep -P "$pid" | tr '\n' ' ')）"
  fi
  launch_agent "$role" "$cwd"
  cmd_status
}

# $1 が skill の作った worktree か: 実際のパスが $WORKSPACES/<repo>/ の直下にあり、repo に worktree として登録されている。
# 文字列の前方一致だけでは ../ やシンボリックリンクで外の場所を通してしまう。
own_worktree() {
  local real ws repo
  real="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  ws="$(cd "$WORKSPACES" 2>/dev/null && pwd -P)" || return 1
  repo="$(jq -r '.repo' <<<"$CFG")"
  [ "$(dirname "$real")" = "$ws/$(basename "$repo")" ] || return 1
  git -C "$repo" worktree list --porcelain | grep -qxF "worktree $real"
}

# 単位の worktree を作る・消す。置き場所は <WORKSPACES>/<repo>/<unit>。
cmd_worktree() {
  load_config
  local sub="${1:-}"; [ $# -gt 0 ] && shift
  local unit="" branch="" from="" repo dir b i
  while [ $# -gt 0 ]; do
    case "$1" in
      --unit)   unit="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --from)   from="$2"; shift 2 ;;
      *) die "worktree: 不明な引数 $1" ;;
    esac
  done
  [ -n "$unit" ] || die "--unit が要る（指示書の <unit> と同じ名前）"
  [[ "$unit" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$unit" != *..* ]] || die "--unit に使えない文字がある: ${unit}（英数字と . _ - だけ）"
  repo="$(jq -r '.repo' <<<"$CFG")"; dir="$(unit_dir "$unit")"
  case "$sub" in
    add)
      [ -n "$branch" ] || die "--branch が要る"
      [ ! -e "$dir" ] || die "既にある: $dir"
      mkdir -p "$(dirname "$dir")"
      git -C "$repo" worktree add -b "$branch" "$dir" ${from:+"$from"} >&2
      # 席は起動時の .envrc で devshell を読む（agent-switch の shim）。許可が無いと devshell が載らない。
      # 許可するのは repo の本体で使っている .envrc と中身が同じときだけ。違えば中身を design が読んで決める
      if [ -f "$dir/.envrc" ]; then
        if [ -f "$repo/.envrc" ] && cmp -s "$dir/.envrc" "$repo/.envrc"; then direnv allow "$dir"
        else warn "$dir/.envrc が repo の本体の .envrc と違う。中身を読んでから direnv allow $dir を実行する"; fi
      fi
      printf '%s\n' "$dir" ;;
    rm)
      [ -d "$dir" ] || die "無い: $dir"
      b="$(git -C "$dir" branch --show-current)"
      [ -z "$(git -C "$dir" status --porcelain)" ] || die "$dir に commit していない変更がある"
      [ -n "$b" ] && git -C "$repo" merge-base --is-ancestor "$b" "$(git -C "$repo" branch --show-current)" \
        || die "$b は $(git -C "$repo" branch --show-current) に入っていない"
      for i in $(seat_roles); do
        case "$(live "$(seat "$i")" | jq -r '.foreground.cwd // empty')/" in
          "$dir"/*) die "$i がこの worktree で動いている。次の単位を渡すか restart --role $i で移してから消す" ;;
        esac
      done
      git -C "$repo" worktree remove "$dir"
      git -C "$repo" branch -d "$b" >/dev/null
      info "消した: ${dir}（${b}）" ;;
    *) die "worktree add|rm" ;;
  esac
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
      # 単位の worktree があれば、席をそこで起動し直す（新しいセッションにもなる）。無ければ同じ場所でセッションだけ新しくする
      # shortcut: この版より前の up で起動した席（ararat、2026-11-06 時点）は restart できないので、セッションだけ新しくする。
      # その席は worktree に書けないことがある（Codex の sandbox）。チームを down と up で起こし直したら、この分岐を消す
      if [ -d "$(unit_dir "$unit")" ] && live "$target" | seat_is_zsh; then
        cmd_restart --role "$role" --cwd "$(unit_dir "$unit")" >/dev/null
      else
        [ ! -d "$(unit_dir "$unit")" ] || warn "$role は古い up で起動されていて worktree で起動し直せない。セッションだけ新しくする（down と up で直る）"
        new_session "$role"
      fi
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
  restart --team T --role <role> [--cwd <dir>]   席の agent を同じ端末（同じペイン）の中で起動し直す
  worktree add --team T --unit <unit> --branch <b> [--from <rev>]   <WORKSPACES>/<repo>/<unit> に作る
  worktree rm  --team T --unit <unit>    main に入っていて変更が無ければ worktree とブランチを消す
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
    init|up|restart|worktree|tell|wait|status|down) "cmd_$cmd" "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "不明なコマンド: $cmd" ;;
  esac
}

main "$@"
