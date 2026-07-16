---
name: cc-launch-workspace
description: Launch Claude Code in a new cmux terminal workspace for a specified repository or path. Use when the user asks to open a repo in cmux and start a Claude session, such as "cmux で repo の Claude session を起動して", "新しい workspace で Claude Code を開いて", or "s-code の Claude session を cmux terminal で起動して".
allowed-tools: Bash(scripts/launch_cc_workspace.sh:*), Bash(cmux:*), Bash(command:*)
---

# cc-launch-workspace

## Overview

Open a target repository/path as a new cmux workspace, start Claude Code there, and verify the session. This skill is Claude Code only; do not generalize it to Codex or opencode unless the user explicitly asks for a different skill.

## Workflow

1. Resolve the target from the user's request.
   - If the user gives an absolute path, use that path.
   - If the user gives a repo name, search `~/workspace/github.com/*/<repo>`.
   - If there are zero or multiple matches, stop and ask the user to choose.

2. Confirm the tools exist:

   ```bash
   command -v cmux
   command -v claude
   ```

3. Run the helper script from this skill directory:

   ```bash
   scripts/launch_cc_workspace.sh <repo-or-path>
   scripts/launch_cc_workspace.sh <repo-or-path> --name "<workspace name>"
   ```

4. Report the result concisely: target path, cmux workspace id, TTY, and Claude session id if available.

## Helper Behavior

The helper script performs the fragile sequence:

- Create a workspace with `cmux new-workspace --cwd <path> --focus true`, then confirm it in the cmux session JSON. If cmux RPC returns an error, still inspect the session JSON because workspace creation can succeed before the socket write fails.
- Fall back to `cmux <path>` only if `new-workspace` did not create a new workspace.
- Identify the matching workspace and terminal TTY from the cmux session JSON.
- Launch Claude by sending `claude\n` into the workspace's terminal: `cmux send --workspace <id> "claude\n"`. This runs the claude CLI in the interactive login shell, yielding an **operable terminal Claude** that inherits the shell environment (direnv/devshell, PATH). It goes through the cmux socket, so unlike AppleScript it does NOT depend on OS window focus.
- Do NOT use `cmux new-surface --type agent-session --provider claude`. That creates a cmux-managed React **agent surface** (shows as "Claude Code · React"), which is not a normal operable terminal and does not give you the shell's environment.
- Only if `cmux send` does not yield a running Claude, fall back to AppleScript (activate cmux → keystroke `claude` → key code 36). AppleScript is focus-dependent and can silently miss the embedded terminal, so it is a last resort.
- Verify startup through the cmux session JSON (`terminal.agent.kind == "claude"`, label shows "Claude Code" not "Claude Code · React") and `ps -t <tty>`.

## Manual Fallback

If the helper script fails after creating the workspace, use this sequence:

```bash
# 1) Create the workspace
cmux new-workspace --cwd <absolute-target-path> --focus true
# 2) Find the new workspace id + terminal tty
jq -r '.windows[0].tabManager.workspaces[] | [.workspaceId,.currentDirectory,.panels[0].ttyName] | @tsv' \
  "$HOME/Library/Application Support/cmux/session-com.cmuxterm.app.json"
# 3) Launch Claude deterministically by sending it into the workspace terminal
cmux send --workspace <workspace-id> "claude\n"
# 4) Verify
ps -t <tty> -o pid,ppid,stat,command

# Last resort only (focus-dependent, may silently miss the terminal):
# osascript -e 'tell application "cmux" to activate' \
#   -e 'delay 0.5' \
#   -e 'tell application "System Events" to keystroke "claude"' \
#   -e 'tell application "System Events" to key code 36'
```

Treat the launch as successful when `ps` shows `/opt/homebrew/bin/claude` or cmux session JSON shows `terminal.agent.kind == "claude"` for the workspace (label "Claude Code", not "Claude Code · React").

## Notes

- The `--name` option is best effort; if cmux RPC is unavailable, the workspace is left with cmux's default title.
- Prefer `cmux send --workspace <id> "claude\n"` (terminal launch) over `--type agent-session`. The agent-session surface is a cmux-managed React panel, not an operable interactive terminal; the terminal-launched Claude is operable AND inherits the workspace shell's environment — verified that the repo's nix devshell `node`/`npx` (via direnv) are available to the launched Claude, which matters for MCP servers it spawns.
- `cmux send` escape sequences: `\n` / `\r` send Enter, `\t` sends Tab. `cmux send-key <key>` sends a discrete key (e.g. `enter`, `ctrl+c`).
- Do not use `tmux` fallback for this skill. The point is to launch inside cmux terminal workspace.
- The helper script has side effects: it opens a cmux workspace and may start a Claude session.
