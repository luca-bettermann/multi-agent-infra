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
#
# Pre-send guard: because we type text + Enter into the target's live TTY, sending while
# the target is at an interactive prompt (AskUserQuestion, permission dialog, plan
# approval) or actively generating makes that Enter collide with the prompt and can
# submit a PHANTOM choice (e.g. auto-confirm the highlighted option). So we first
# passively snapshot the target screen (`capture-pane` sends NOTHING to the target) and
# refuse (exit 2) if it looks non-idle, telling the sender to have the user resolve it
# and retry. Heuristic — INTERACTIVE_RE below is the tunable part; extend as new prompt
# signatures appear.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: agent-msg <target-session-or-scope> <message...>" >&2; exit 1; }

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"   # resolve symlink (~/.local/bin) to the real agent-infra dir
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

# Pre-send guard — passively snapshot the target and bail if it isn't idle.
# capture-pane only READS the screen; it injects nothing. Three measures, each killing
# a real false-positive class:
#  1. Scope to the bottom UI region (last ~12 lines: input box + status line) so marker
#     WORDS in ordinary conversation output above don't match (that refused master —
#     this very discussion contains "esc to interrupt", "to confirm", …).
#  2. Capture WITH escapes (-e), strip Claude Code's faint "ghost text" (a dim SGR-2m
#     history suggestion on an empty idle prompt), and normalise NBSP (U+00A0) sitting
#     between the prompt glyph and the ghost.
#  3. Markers are UI-chrome ONLY (generation, permission dialog, numbered option) — not
#     generic English like "to select"/"to confirm" which match normal prose.
INTERACTIVE_RE='esc to interrupt|Do you want to proceed|❯ +[0-9][.)]'
# strip escapes/ghost/NBSP, then take the last 12 lines up to the last non-blank one
# (trailing blanks stripped so the status line can't be pushed out of the window).
screen="$(tmux capture-pane -t "$sess" -e -p 2>/dev/null \
  | perl -pe 's/\e\[(?:[0-9;]*;)?2m[^\e]*//g; s/\e\[[0-9;]*m//g; s/\xc2\xa0/ /g' \
  | awk 'NF{last=NR} {b[NR]=$0} END{s=last-11; if(s<1)s=1; for(i=s;i<=last;i++)print b[i]}')"
if printf '%s\n' "$screen" | grep -Eq "$INTERACTIVE_RE"; then
  echo "'$sess' looks busy or is at an interactive prompt — message NOT delivered. Typing into it now could collide with its prompt and submit a phantom choice. Ask the user to resolve '$sess' to an idle prompt, then retry agent-msg." >&2
  exit 2
fi

tmux send-keys -t "$sess" -l -- "[agent-msg from $sender] $msg"
tmux send-keys -t "$sess" Enter
echo "delivered to '$sess' prompt (from $sender)"
