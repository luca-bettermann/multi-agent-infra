#!/usr/bin/env bash
# pane-state — classify a tmux pane's input state. The SINGLE home for the
# pane-state check shared by agent-msg.sh and kanban-dispatch.py, so the two
# cannot drift.
#
#   pane-state.sh <session>      -> prints: absent | feedback | dialog | clear
#   pane-state.sh --classify     -> reads a captured screen from stdin,
#                                   prints: feedback | dialog | clear
#
# States:
#   absent    the tmux session does not exist
#   feedback  the periodic "How is Claude doing this session?" prompt is open.
#             It consumes one keypress and holds no content decision; callers
#             may auto-dismiss it (send '0') and re-check.
#   dialog    an ANSWER-CONSUMING content dialog is open (permission dialog,
#             AskUserQuestion, plan approval, folder-trust): injected text/Enter
#             could answer it and submit a phantom choice -> callers must refuse
#   clear     anything else: idle prompt OR actively generating / running tools.
#             Sending is safe — Claude Code queues input typed while it is
#             generating and delivers it at the next prompt boundary.
#
# Detection is POSITIVE-ONLY: block for detected dialog chrome, never for mere
# busyness. Markers are UI chrome, not generic English ("to select",
# "to confirm" match ordinary prose). DIALOG_RE is the tunable part — extend it
# as new dialog signatures appear.
set -euo pipefail

# Answer-consuming dialog chrome:
#   '❯ 1.' / '❯ 1)'                     highlighted numbered option (permission
#                                       dialog, AskUserQuestion, plan approval,
#                                       selector menus)
#   'Do you want'                       permission-dialog question line
#   'Would you like to proceed'         plan-approval question line
#   'Do you trust the files'            folder-trust dialog
DIALOG_RE='❯ +[0-9][.)]|Do you want|Would you like to proceed|Do you trust the files'
# The feedback prompt also renders numbered options, so it must be recognised
# BEFORE the generic dialog chrome.
FEEDBACK_RE='How is Claude doing this session'

classify() {
  # stdin: raw screen capture (with escapes). Three measures, each killing a
  # real false-positive class:
  #  1. Scope to the bottom UI region (last ~12 lines up to the last non-blank
  #     one: input box + status line) so marker WORDS in conversation output
  #     above don't match.
  #  2. Strip Claude Code's faint "ghost text" (a dim SGR-2m history suggestion
  #     shown on an empty idle prompt) before stripping SGR, and normalise NBSP.
  #  3. Positive dialog chrome only (DIALOG_RE).
  local screen
  screen="$(perl -pe 's/\e\[(?:[0-9;]*;)?2m[^\e]*//g; s/\e\[[0-9;]*m//g; s/\xc2\xa0/ /g' \
    | awk 'NF{last=NR} {b[NR]=$0} END{s=last-11; if(s<1)s=1; for(i=s;i<=last;i++)print b[i]}')"
  if printf '%s\n' "$screen" | grep -Eq "$FEEDBACK_RE"; then
    echo feedback
  elif printf '%s\n' "$screen" | grep -Eq "$DIALOG_RE"; then
    echo dialog
  else
    echo clear
  fi
}

if [ "${1:-}" = "--classify" ]; then
  classify
  exit 0
fi

[ $# -eq 1 ] || { echo "usage: pane-state.sh <tmux-session> | pane-state.sh --classify < screen.txt" >&2; exit 64; }
sess="$1"

if ! tmux has-session -t "$sess" 2>/dev/null; then
  echo absent
  exit 0
fi
# capture-pane only READS the screen; it injects nothing into the target.
# A capture failure here means the session vanished between the two calls.
if ! screen_raw="$(tmux capture-pane -t "$sess" -e -p 2>/dev/null)"; then
  echo absent
  exit 0
fi
printf '%s\n' "$screen_raw" | classify
