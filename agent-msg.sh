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
# submits it. Reply by running agent-msg back to the sender. Delivery semantics:
#   idle target        -> lands on the prompt and submits immediately
#   generating target  -> lands in Claude Code's own input queue and is delivered
#                         at the next prompt boundary (send anyway, don't wait)
#   answer-consuming dialog open (permission dialog, AskUserQuestion, plan approval,
#   feedback prompt)   -> REFUSED, exit 2, no keys sent: injected text/Enter could
#                         answer the dialog and submit a phantom choice. The user must
#                         resolve the dialog in the target session; then retry.
#   session not running-> REFUSED, exit 1 (live-only; never claims delivery)
# The pane-state check lives in pane-state.sh — shared with the dispatcher, one home.
# Sender defaults to the calling tmux session; override with AGENT_MSG_SENDER.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: agent-msg <target-session-or-scope> <message...>" >&2; exit 1; }

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"   # resolve symlink (~/.local/bin) to the real agent-infra dir
CONF="$DIR/sessions.conf"
target="$1"; shift
msg="$(printf '%s' "$*" | tr '\n' ' ')"   # one line — a newline would submit early

sess="$target"
[ -f "$CONF" ] && sess="$(awk -v k="$target" '!/^#/ && $1==k {print $2; f=1; exit} END{if(!f) print k}' "$CONF")"
sender="${AGENT_MSG_SENDER:-$(tmux display-message -p '#S' 2>/dev/null || echo "${USER:-unknown}")}"

# Pre-send guard — the shared pane-state check (pane-state.sh, one home for
# agent-msg + dispatcher). Blocks ONLY on positively detected answer-consuming
# UI or an absent session; idle and generating targets both get the message.
state="$("$DIR/pane-state.sh" "$sess")"
case "$state" in
  absent)
    echo "'$sess' is not running — message NOT delivered. agent-msg is live-only; retry when the session is up (tracked work belongs on the board, not in a message)." >&2
    exit 1;;
  dialog)
    echo "'$sess' is stalled at an answer-consuming dialog (permission / AskUserQuestion / plan approval / feedback prompt) — message NOT delivered, no keys sent: typing into it could answer the dialog and submit a phantom choice. The user must resolve the dialog in '$sess'; then retry agent-msg." >&2
    exit 2;;
esac

tmux send-keys -t "$sess" -l -- "[agent-msg from $sender] $msg"
tmux send-keys -t "$sess" Enter
echo "delivered to '$sess' prompt (from $sender)"
