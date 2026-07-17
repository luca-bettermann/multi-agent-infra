#!/usr/bin/env bash
# Tests for pane-state.sh classification and agent-msg delivery semantics.
# Classification cases feed canned screens to `pane-state.sh --classify`;
# integration cases use throwaway tmux sessions on the default server
# (unique pstest-$$ names, killed on exit). Run: bash tests/test_pane_state.sh
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PS="$DIR/pane-state.sh"
AM="$DIR/agent-msg.sh"
TMP="$(mktemp -d)"
S1="pstest-clear-$$"; S2="pstest-dialog-$$"; S3="pstest-gen-$$"; S4="pstest-fb-$$"
cleanup() {
  tmux kill-session -t "$S1" 2>/dev/null
  tmux kill-session -t "$S2" 2>/dev/null
  tmux kill-session -t "$S3" 2>/dev/null
  tmux kill-session -t "$S4" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0; fail=0
check() { # <name> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1: want '$2' got '$3'"; fi
}

# ---- classification (offline, canned screens) --------------------------------

# idle prompt with faint ghost text (SGR 2m) + NBSP after the prompt glyph
idle_screen="$(printf '╭──────╮\n│ >\xc2\xa0\x1b[2mtry "fix the tests"\x1b[0m │\n╰──────╯\n  status line\n')"
check "idle prompt -> clear" "clear" "$(printf '%s\n' "$idle_screen" | "$PS" --classify)"

# actively generating: must NOT block any more (input queues at the prompt boundary)
gen_screen="$(printf '✳ Reticulating splines… (esc to interrupt)\n╭──────╮\n│ >  │\n╰──────╯\n')"
check "generating -> clear" "clear" "$(printf '%s\n' "$gen_screen" | "$PS" --classify)"

# permission dialog: question line + highlighted numbered option
perm_screen="$(printf 'Do you want to proceed?\n ❯ 1. Yes\n   2. No\n')"
check "permission dialog -> dialog" "dialog" "$(printf '%s\n' "$perm_screen" | "$PS" --classify)"

# periodic feedback prompt: its own state, auto-dismissable by callers
fb_screen="$(printf 'How is Claude doing this session?\n ❯ 1. Good\n   2. Bad\n   0. Dismiss\n')"
check "feedback prompt -> feedback" "feedback" "$(printf '%s\n' "$fb_screen" | "$PS" --classify)"

# AskUserQuestion-style selector (numbered options only, no question keyword)
ask_screen="$(printf 'Pick an approach:\n ❯ 1) Option A\n   2) Option B\n')"
check "numbered selector -> dialog" "dialog" "$(printf '%s\n' "$ask_screen" | "$PS" --classify)"

# plan approval
plan_screen="$(printf 'Would you like to proceed with this plan?\n ❯ 1. Yes\n')"
check "plan approval -> dialog" "dialog" "$(printf '%s\n' "$plan_screen" | "$PS" --classify)"

# dialog WORDS in conversation output scrolled above the bottom UI region must not match
scroll_screen="$(printf 'earlier output: Do you want to proceed? was the question\n%s╭──────╮\n│ >  │\n╰──────╯\n' "$(printf 'filler line\n%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)")"
check "dialog words above UI region -> clear" "clear" "$(printf '%s\n' "$scroll_screen" | "$PS" --classify)"

# ---- integration (throwaway tmux sessions) ------------------------------------

if ! tmux -V >/dev/null 2>&1; then
  echo "tmux unavailable — skipping integration tests"
  echo "passed $pass, failed $fail"; exit $((fail > 0))
fi

# absent session
check "absent session -> absent" "absent" "$("$PS" "no-such-session-$$")"

# clear pane: cat consumes the tty -> agent-msg must deliver (exit 0), line lands
tmux new-session -d -s "$S1" "cat > '$TMP/clear.out'"
sleep 0.5
check "live cat pane -> clear" "clear" "$("$PS" "$S1")"
AGENT_MSG_SENDER=test "$AM" "$S1" "hello clear pane"
check "agent-msg to clear pane exits 0" "0" "$?"
sleep 0.5
grep -q "\[agent-msg from test\] hello clear pane" "$TMP/clear.out"
check "message landed in clear pane" "0" "$?"

# generating-look pane (esc to interrupt on screen): must also deliver
tmux new-session -d -s "$S3" "printf '✳ Thinking… (esc to interrupt)\n'; cat > '$TMP/gen.out'"
sleep 0.5
check "generating-look pane -> clear" "clear" "$("$PS" "$S3")"
AGENT_MSG_SENDER=test "$AM" "$S3" "hello generating pane"
check "agent-msg to generating pane exits 0" "0" "$?"
sleep 0.5
grep -q "hello generating pane" "$TMP/gen.out"
check "message landed in generating pane" "0" "$?"

# dialog pane: refusal (exit 2) and NO keys injected
tmux new-session -d -s "$S2" "printf 'Do you want to proceed?\n ❯ 1. Yes\n   2. No\n'; cat > '$TMP/dialog.out'"
sleep 0.5
check "dialog pane -> dialog" "dialog" "$("$PS" "$S2")"
AGENT_MSG_SENDER=test "$AM" "$S2" "must not arrive" 2>/dev/null
check "agent-msg to dialog pane exits 2" "2" "$?"
sleep 0.5
[ ! -s "$TMP/dialog.out" ]
check "no keys injected into dialog pane" "0" "$?"

# feedback pane: one keypress dismisses it (read -n1), screen clears, then the
# message must be delivered. The '0' is consumed by the dismiss, not the message.
tmux new-session -d -s "$S4" "bash -c 'printf \"How is Claude doing this session?\\n ❯ 1. Good\\n   0. Dismiss\\n\"; read -n1 k; printf \"\\033[2J\\033[H\"; exec cat > \"$TMP/fb.out\"'"
sleep 0.5
check "feedback pane -> feedback" "feedback" "$("$PS" "$S4")"
AGENT_MSG_SENDER=test "$AM" "$S4" "hello after dismiss"
check "agent-msg auto-dismisses feedback and exits 0" "0" "$?"
sleep 0.5
grep -q "hello after dismiss" "$TMP/fb.out"
check "message landed after feedback dismiss" "0" "$?"
grep -q "0" "$TMP/fb.out" && fbleak=1 || fbleak=0
check "dismiss keypress not leaked into delivered text" "0" "$fbleak"

# absent target through agent-msg: explicit failure (exit 1)
AGENT_MSG_SENDER=test "$AM" "no-such-session-$$" "into the void" 2>/dev/null
check "agent-msg to absent session exits 1" "1" "$?"

echo "passed $pass, failed $fail"
exit $((fail > 0))
