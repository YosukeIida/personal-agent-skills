---
name: install-skill
description: "Install a Claude Code .skill file into dotfiles. Usage: /install-skill <path-to-file.skill>"
allowed-tools: Bash(mkdir:*), Bash(unzip:*), Read, Write
---

Install a `.skill` file into the dotfiles-managed skills directory so it becomes available globally in Claude Code.

## Target directories

- **private**: `~/workspace/github.com/YosukeIida/dotfiles-private/agents/skills/` — for personal/sensitive skills
- **public**: `~/workspace/github.com/YosukeIida/dotfiles/agents/skills/` — for shareable skills

## Steps

1. Determine the skill name from the filename (strip `.skill` extension)
2. **Ask the user whether to install into private or public dotfiles** before proceeding
3. If the file is in `~/Downloads/`, warn the user that macOS may block terminal access and ask them to move it to `~/Desktop/` or `~/workspace/` first
4. Create the destination directory: `<target>/<skill-name>/`
5. Extract using: `unzip -j <file> "*/SKILL.md" -d <dest> 2>/dev/null || unzip -j <file> "SKILL.md" -d <dest>`
   - The `-j` flag discards subdirectory paths, avoiding nested directory issues
6. Verify `SKILL.md` exists in the destination
7. Report the installed path

## Notes

- If the user doesn't provide a path, ask for it
- If `~/Downloads/` access fails with "Operation not permitted", instruct the user to move the file to `~/Desktop/` or `~/workspace/` (macOS privacy restriction)
