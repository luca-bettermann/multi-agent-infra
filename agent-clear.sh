#!/usr/bin/env bash
# agent-clear — clear another agent session's conversation context remotely.
# Types Claude Code's own '/clear' slash command into the target's live tmux
# prompt, then verifies the session actually restarted its context.
#
#   agent-clear <target>
#     <target> : session name (e.g. pfab-mock) OR scope tag (e.g. pred-fab -> pfab),
#                resolved through sessions.conf exactly like agent-msg.
#
# Why raw keystrokes and not agent-msg: agent-msg prefixes every message with
# "[agent-msg from <sender>] ", so the target reads '/clear' as chat text and
# answers it instead of executing it. A slash command must arrive as the literal
# first characters on the prompt, so agent-clear sends the keys itself and sends
# NOTHING else — no prefix, no sender, no second target.
#
# Pane state decides (pane-state.sh, the shared classifier):
#   clear    -> keys are sent; the pane consumes '/clear' as a command
#   busy     -> REFUSED, exit 3: a generating pane QUEUES typed input for the
#               next prompt boundary, where '/clear' would land as chat text,
#               not as a command. Wait for the target to go idle and retry.
#   dialog   -> REFUSED, exit 2, no keys sent: text + Enter could answer the
#               dialog and submit a phantom choice.
#   feedback -> auto-dismissed with '0' and re-checked, like agent-msg.
#   absent   -> REFUSED, exit 1.
#
# Verification: a real clear reprints Claude Code's startup banner (a line
# carrying "Claude Code v") and echoes the submitted '❯ /clear' beneath it. The
# pane is polled for that pair for up to CLEAR_TIMEOUT seconds, and the banner
# must be a NEW one (banner count strictly higher than before the keys were
# sent), so an older clear further up the scrollback cannot be mistaken for
# this one. No confirmation -> non-zero exit; the command never claims a clear
# it did not observe.
#
# Clearing DESTROYS the target's conversation context. It is deliberate,
# one-session-at-a-time, and never batched.
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"   # resolve symlink (~/.local/bin) to the real agent-infra dir
CONF="$DIR/sessions.conf"
CLEAR_TIMEOUT="${CLEAR_TIMEOUT:-15}"   # seconds to wait for the fresh banner
CAPTURE_LINES="${CAPTURE_LINES:-500}"  # scrollback depth compared before/after

BANNER_RE='Claude Code v'
# The submitted command echoed back on its own transcript line, right under the
# fresh banner. Anchored: '❯ [agent-msg from x] /clear' must NOT match.
ECHO_RE='^[[:space:]]*❯[[:space:]]+/clear[[:space:]]*$'

# Strip Claude Code's faint ghost text, then SGR escapes, then normalise NBSP —
# the same normalisation pane-state.sh applies before matching.
strip_screen() {
  perl -pe 's/\e\[(?:[0-9;]*;)?2m[^\e]*//g; s/\e\[[0-9;]*m//g; s/\xc2\xa0/ /g'
}

# --verify: reads a captured screen on stdin, exits 0 when it shows a fresh
# Claude Code banner with the echoed '/clear' beneath it. Offline-testable.
verify_cleared() {
  strip_screen | awk -v banner="$BANNER_RE" -v echo_re="$ECHO_RE" '
    $0 ~ banner { seen = 1; ok = 0; next }
    seen && $0 ~ echo_re { ok = 1 }
    END { exit(ok ? 0 : 1) }'
}

count_banners() { strip_screen | grep -c "$BANNER_RE" || true; }

if [ "${1:-}" = "--verify" ]; then
  verify_cleared
  exit $?
fi

[ $# -eq 1 ] || { echo "usage: agent-clear <target-session-or-scope>" >&2; exit 64; }
target="$1"

sess="$target"
[ -f "$CONF" ] && sess="$(awk -v k="$target" '!/^#/ && $1==k {print $2; f=1; exit} END{if(!f) print k}' "$CONF")"

state="$("$DIR/pane-state.sh" "$sess")"
if [ "$state" = feedback ]; then
  # Same treatment as agent-msg: the feedback prompt holds no content decision,
  # '0' dismisses it without rating. Dismiss, give the UI a beat, re-check.
  tmux send-keys -t "$sess" -l '0'
  sleep 1
  state="$("$DIR/pane-state.sh" "$sess")"
fi
case "$state" in
  absent)
    echo "'$sess' is not running — nothing cleared." >&2
    exit 1;;
  feedback)
    echo "'$sess' still shows the feedback prompt after auto-dismiss ('0') — NOT cleared, no '/clear' sent. Check the session; its UI may have changed shape." >&2
    exit 2;;
  dialog)
    echo "'$sess' is stalled at an answer-consuming dialog (permission / AskUserQuestion / plan approval) — NOT cleared, no keys sent: typing into it could answer the dialog and submit a phantom choice. The user must resolve the dialog in '$sess'; then retry." >&2
    exit 2;;
  busy)
    echo "'$sess' is generating — NOT cleared, no keys sent: input typed now is queued and would arrive as chat text, not as the /clear command. Retry once '$sess' is idle." >&2
    exit 3;;
esac

before="$(tmux capture-pane -t "$sess" -e -p -S "-$CAPTURE_LINES" 2>/dev/null | count_banners)"

tmux send-keys -t "$sess" -l '/clear'
tmux send-keys -t "$sess" Enter

deadline=$((SECONDS + CLEAR_TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  sleep 1
  screen="$(tmux capture-pane -t "$sess" -e -p -S "-$CAPTURE_LINES" 2>/dev/null || true)"
  [ -n "$screen" ] || continue
  after="$(printf '%s\n' "$screen" | count_banners)"
  if [ "$after" -gt "$before" ] && printf '%s\n' "$screen" | verify_cleared; then
    echo "cleared '$sess'"
    exit 0
  fi
done

echo "'$sess': sent '/clear' but no fresh Claude Code banner appeared within ${CLEAR_TIMEOUT}s — clear NOT confirmed. Check the session before assuming its context is gone." >&2
exit 4
