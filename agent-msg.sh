#!/usr/bin/env bash
# agent-msg — send a direct message to another agent's inbox and nudge its session.
# For EPHEMERAL coordination only: a question, an FYI, "pushed X, pull it".
# Work that must be tracked or remembered is a kanban card, NOT a message.
# (See CLAUDE.md -> Task Tracking: track work, message coordination.)
#
#   agent-msg <target> <message...>
#     <target> : session name (e.g. pfab-mock) OR a scope tag (e.g. pred-fab -> pfab),
#                resolved through sessions.conf; passes through if unmapped.
#
# Messages land in ~/.claude-inbox/<session>.md (a durable, greppable log) and, if the
# target session is live, as a tmux nudge. Replies are just agent-msg back to the sender.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: agent-msg <target-session-or-scope> <message...>" >&2; exit 1; }

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$DIR/sessions.conf"
INBOX="$HOME/.claude-inbox"
target="$1"; shift; msg="$*"

# resolve a scope tag to its session (pass through if already a session or unmapped)
sess="$target"
[ -f "$CONF" ] && sess="$(awk -v k="$target" '!/^#/ && $1==k {print $2; f=1; exit} END{if(!f) print k}' "$CONF")"

sender="$(tmux display-message -p '#S' 2>/dev/null || echo "${USER:-unknown}")"
ts="$(date +%H:%M)"

mkdir -p "$INBOX"
printf '%s  msg from %s: %s\n' "$ts" "$sender" "$msg" >> "$INBOX/$sess.md"

if tmux has-session -t "$sess" 2>/dev/null; then
  tmux send-keys -t "$sess" "agent-msg from $sender — read ~/.claude-inbox/$sess.md and respond/act"
  tmux send-keys -t "$sess" Enter
  echo "sent to '$sess' (live) + logged to inbox"
else
  echo "'$sess' not running — queued in ~/.claude-inbox/$sess.md"
fi
