#!/usr/bin/env bash
# Claude Code PreToolUse hook: block writes to read-only context-repos/.
# Wire in ~/.claude/settings.json (matcher: Edit|Write|MultiEdit). Exit 2 = block.
input=$(cat)
path=$(printf '%s' "$input" | python3 -c \
  'import json,sys;print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null)
case "$path" in
  */context-repos/*)
    echo "Blocked: '$path' is inside a read-only context-repos/ (reference only). \
To change that repo, file a handoff card for its owner (its scope tag + #from:<you>), per CLAUDE.md." >&2
    exit 2
    ;;
esac
exit 0
