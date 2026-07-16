#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: launch_cc_workspace.sh <repo-or-path> [--name <workspace-name>]

Open a repository/path in a new cmux workspace, start Claude Code there,
and print the detected workspace/session information.
USAGE
}

log() {
  printf '[cc-launch-workspace] %s\n' "$*" >&2
}

fail() {
  printf '[cc-launch-workspace] ERROR: %s\n' "$*" >&2
  exit "${2:-1}"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

expand_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

canonical_dir() {
  local path
  path="$(expand_path "$1")"
  [ -d "$path" ] || return 1
  (cd "$path" && pwd -P)
}

resolve_target() {
  local input="$1"
  local expanded
  expanded="$(expand_path "$input")"

  if [ "${expanded#/}" != "$expanded" ]; then
    canonical_dir "$expanded" || fail "path does not exist or is not a directory: $expanded" 2
    return
  fi

  if [ -d "$expanded" ]; then
    canonical_dir "$expanded" || fail "path does not exist or is not a directory: $expanded" 2
    return
  fi

  local root="$HOME/workspace/github.com"
  [ -d "$root" ] || fail "workspace search root does not exist: $root" 2

  local matches=()
  while IFS= read -r match; do
    matches+=("$match")
  done < <(find "$root" -mindepth 2 -maxdepth 2 -type d -name "$input" -print 2>/dev/null | sort)

  case "${#matches[@]}" in
    0)
      fail "no repo named '$input' found under $root" 2
      ;;
    1)
      canonical_dir "${matches[0]}"
      ;;
    *)
      printf '[cc-launch-workspace] ERROR: multiple repos named %s found:\n' "$input" >&2
      printf '  %s\n' "${matches[@]}" >&2
      printf '[cc-launch-workspace] Pass an absolute path to choose one.\n' >&2
      exit 3
      ;;
  esac
}

workspace_ids_for_dir() {
  local dir="$1"
  [ -f "$SESSION_JSON" ] || return 0
  jq -r --arg dir "$dir" '
    .windows[0].tabManager.workspaces[]?
    | select(.currentDirectory == $dir)
    | .workspaceId
  ' "$SESSION_JSON" 2>/dev/null || true
}

detect_workspace() {
  local dir="$1"
  local before_ids="$2"
  [ -f "$SESSION_JSON" ] || return 1

  jq -r --arg dir "$dir" --arg before "$before_ids" '
    def in_before($id): (($before | split("\n")) | index($id)) != null;
    (.windows[0].tabManager.workspaces // [])
    | to_entries
    | map(select(.value.currentDirectory == $dir)) as $matches
    | ($matches | map(select((in_before(.value.workspaceId) | not))) | last)
    | if . == null then empty else
        [
          .value.workspaceId,
          (.value.panels[0].ttyName // ""),
          (.value.panels[0].terminal.agent.kind // ""),
          (.value.panels[0].terminal.agent.sessionId // "")
        ] | @tsv
      end
  ' "$SESSION_JSON" 2>/dev/null || true
}

workspace_agent_info() {
  local workspace_id="$1"
  [ -f "$SESSION_JSON" ] || return 1

  jq -r --arg wid "$workspace_id" '
    .windows[0].tabManager.workspaces[]?
    | select(.workspaceId == $wid)
    | [
        (.panels[]? | select(.terminal.agent.kind == "claude") | .ttyName) // (.panels[0].ttyName // ""),
        (.panels[]? | select(.terminal.agent.kind == "claude") | .terminal.agent.sessionId) // (.panels[0].terminal.agent.sessionId // ""),
        (.panels[]? | select(.terminal.agent.kind == "claude") | .terminal.agent.kind) // (.panels[0].terminal.agent.kind // "")
      ] | @tsv
  ' "$SESSION_JSON" 2>/dev/null | head -n 1 || true
}

session_from_ps() {
  local tty="$1"
  [ -n "$tty" ] || return 1
  ps -t "$tty" -o command= 2>/dev/null \
    | awk '
        /(^|\/)claude([[:space:]]|$)/ {
          for (i = 1; i <= NF; i++) {
            if ($i == "--session-id" && (i + 1) <= NF) {
              print $(i + 1)
              exit
            }
          }
          print "unknown"
          exit
        }
      '
}

claude_running_on_tty() {
  local tty="$1"
  [ -n "$tty" ] || return 1
  ps -t "$tty" -o command= 2>/dev/null | grep -E '(^|/)claude([[:space:]]|$)' >/dev/null
}

wait_for_workspace() {
  local dir="$1"
  local before_ids="$2"
  local info=""
  local i
  for i in $(seq 1 60); do
    info="$(detect_workspace "$dir" "$before_ids")"
    if [ -n "$info" ]; then
      printf '%s\n' "$info"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

wait_for_claude() {
  local workspace_id="$1"
  local fallback_tty="$2"
  local info tty session_id kind ps_session
  local i

  for i in $(seq 1 30); do
    info="$(workspace_agent_info "$workspace_id")"
    IFS="$(printf '\t')" read -r tty session_id kind <<EOF
$info
EOF
    tty="${tty:-$fallback_tty}"

    if [ "$kind" = "claude" ]; then
      printf '%s\t%s\t%s\n' "$tty" "$session_id" "$kind"
      return 0
    fi

    if claude_running_on_tty "$tty"; then
      ps_session="$(session_from_ps "$tty")"
      printf '%s\t%s\t%s\n' "$tty" "${ps_session:-unknown}" "claude"
      return 0
    fi

    sleep 0.5
  done

  return 1
}

TARGET_INPUT=""
WORKSPACE_NAME=""
RESUME_SESSION_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --name)
      [ "$#" -ge 2 ] || fail "--name requires a value" 2
      WORKSPACE_NAME="$2"
      shift 2
      ;;
    --resume)
      [ "$#" -ge 2 ] || fail "--resume requires a session-id value" 2
      RESUME_SESSION_ID="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      fail "unknown option: $1" 2
      ;;
    *)
      if [ -n "$TARGET_INPUT" ]; then
        fail "unexpected extra argument: $1" 2
      fi
      TARGET_INPUT="$1"
      shift
      ;;
  esac
done

[ -n "$TARGET_INPUT" ] || {
  usage >&2
  exit 2
}

need_cmd cmux
need_cmd claude
need_cmd jq

SESSION_JSON="${CMUX_SESSION_JSON:-$HOME/Library/Application Support/cmux/session-com.cmuxterm.app.json}"
TARGET_DIR="$(resolve_target "$TARGET_INPUT")"

log "target: $TARGET_DIR"

BEFORE_IDS="$(workspace_ids_for_dir "$TARGET_DIR")"

log "creating cmux workspace"
CREATE_ARGS=(new-workspace --cwd "$TARGET_DIR" --focus true)
if [ -n "$WORKSPACE_NAME" ]; then
  CREATE_ARGS+=(--name "$WORKSPACE_NAME")
fi

if CMUX_QUIET=1 cmux "${CREATE_ARGS[@]}" >/tmp/cc-launch-workspace-create.out 2>/tmp/cc-launch-workspace-create.err; then
  log "cmux new-workspace command accepted"
else
  log "cmux new-workspace returned an error; checking session JSON anyway: $(tr '\n' ' ' </tmp/cc-launch-workspace-create.err | sed 's/[[:space:]]*$//')"
fi

WORKSPACE_INFO="$(wait_for_workspace "$TARGET_DIR" "$BEFORE_IDS" || true)"

if [ -z "$WORKSPACE_INFO" ]; then
  log "falling back to cmux path opener"
  cmux "$TARGET_DIR" >/dev/null
  WORKSPACE_INFO="$(wait_for_workspace "$TARGET_DIR" "$BEFORE_IDS" || true)"
fi

[ -n "$WORKSPACE_INFO" ] \
  || fail "new cmux workspace was not found in session JSON after opening; cmux may have focused an existing workspace instead: $SESSION_JSON"

IFS="$(printf '\t')" read -r WORKSPACE_ID TTY AGENT_KIND SESSION_ID <<EOF
$WORKSPACE_INFO
EOF

[ -n "$WORKSPACE_ID" ] || fail "detected workspace has no workspace id"
log "workspace: $WORKSPACE_ID tty: ${TTY:-unknown}"

if [ -n "$WORKSPACE_NAME" ]; then
  if cmux rename-workspace --workspace "$WORKSPACE_ID" "$WORKSPACE_NAME" >/dev/null 2>&1; then
    log "renamed workspace: $WORKSPACE_NAME"
  else
    log "workspace rename skipped: cmux RPC unavailable or rename failed"
  fi
fi

if [ "$AGENT_KIND" != "claude" ] && ! claude_running_on_tty "$TTY"; then
  log "launching Claude in the workspace terminal via 'cmux send' (deterministic RPC)"
  # Send `claude` + Enter into the workspace's default terminal surface. This runs
  # the claude CLI inside the interactive login shell, so it yields an OPERABLE
  # terminal Claude that also inherits the shell environment (direnv/devshell, PATH,
  # etc.). This is preferred over `cmux new-surface --type agent-session --provider
  # claude`, which creates a cmux-managed React agent surface that is NOT a normal
  # interactive terminal (hard to operate, different model). Unlike AppleScript
  # keystrokes, `cmux send` goes through the cmux socket and does not depend on OS
  # window focus, so it does not silently miss the terminal.
  if [ -n "$RESUME_SESSION_ID" ]; then
    CLAUDE_CMD="claude -r $RESUME_SESSION_ID"
  else
    CLAUDE_CMD="claude"
  fi
  if cmux send --workspace "$WORKSPACE_ID" "${CLAUDE_CMD}\n" \
      >/tmp/cc-launch-workspace-send.out 2>/tmp/cc-launch-workspace-send.err; then
    log "cmux send accepted"
  else
    log "cmux send failed: $(tr '\n' ' ' </tmp/cc-launch-workspace-send.err | sed 's/[[:space:]]*$//')"
  fi
fi

if ! FINAL_INFO="$(wait_for_claude "$WORKSPACE_ID" "$TTY")"; then
  # Last-resort fallback only. AppleScript synthetic keystrokes are focus-dependent
  # and can silently miss the embedded terminal; prefer `cmux send` above.
  if command -v osascript >/dev/null 2>&1; then
    log "cmux send did not yield Claude; trying AppleScript keystroke fallback"
    osascript \
      -e 'tell application "cmux" to activate' \
      -e 'delay 0.5' \
      -e 'tell application "System Events" to keystroke "claude"' \
      -e 'tell application "System Events" to key code 36' || true

    FINAL_INFO="$(wait_for_claude "$WORKSPACE_ID" "$TTY")" \
      || fail "Claude Code did not appear to start in workspace $WORKSPACE_ID; inspect tty ${TTY:-unknown}"
  else
    fail "Claude Code did not start in workspace $WORKSPACE_ID and osascript is unavailable for fallback; inspect tty ${TTY:-unknown}"
  fi
fi

IFS="$(printf '\t')" read -r FINAL_TTY FINAL_SESSION_ID FINAL_KIND <<EOF
$FINAL_INFO
EOF

cat <<EOF
TARGET_DIR=$TARGET_DIR
WORKSPACE_ID=$WORKSPACE_ID
TTY=${FINAL_TTY:-$TTY}
CLAUDE_SESSION_ID=${FINAL_SESSION_ID:-unknown}
AGENT_KIND=${FINAL_KIND:-claude}
EOF
