#!/usr/bin/env bash
# agent-msg — send a quick LIVE message straight into another agent's prompt.
# Real-time, ephemeral coordination only: a question, an FYI, "pushed X, pull it".
# NOT persisted by design — durable/async/queued communication is a kanban task,
# not a message (see CLAUDE.md -> Task Tracking: track work, message coordination).
#
#   agent-msg <target> <message...>
#     <target> : session name (e.g. pfab-mock) OR scope tag (e.g. pred-fab -> pfab),
#                resolved through sessions.conf; passes through if unmapped.
#
# Injects "[agent-msg from <sender>] <message>" into the target's live tmux prompt and
# submits it. Reply by running agent-msg back to the sender. If the target session is
# not running the message is NOT delivered (use a task for anything that must survive).
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: agent-msg <target-session-or-scope> <message...>" >&2; exit 1; }

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$DIR/sessions.conf"
target="$1"; shift
msg="$(printf '%s' "$*" | tr '\n' ' ')"   # one line — a newline would submit early

sess="$target"
[ -f "$CONF" ] && sess="$(awk -v k="$target" '!/^#/ && $1==k {print $2; f=1; exit} END{if(!f) print k}' "$CONF")"
sender="$(tmux display-message -p '#S' 2>/dev/null || echo "${USER:-unknown}")"

if ! tmux has-session -t "$sess" 2>/dev/null; then
  echo "'$sess' is not running — message NOT delivered. agent-msg is live-only; for durable/async handoff use a kanban task." >&2
  exit 1
fi

tmux send-keys -t "$sess" -l -- "[agent-msg from $sender] $msg"
tmux send-keys -t "$sess" Enter
echo "delivered to '$sess' prompt (from $sender)"
