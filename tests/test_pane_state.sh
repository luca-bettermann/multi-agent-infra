#!/usr/bin/env bash
# Tests for pane-state.sh classification, agent-msg delivery, and agent-clear
# semantics.
# Classification cases feed canned screens to `pane-state.sh --classify`;
# integration cases use throwaway tmux sessions on the default server
# (unique pstest-$$ names, killed on exit). Run: bash tests/test_pane_state.sh
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PS="$DIR/pane-state.sh"
AM="$DIR/agent-msg.sh"
AC="$DIR/agent-clear.sh"
TMP="$(mktemp -d)"
S1="pstest-clear-$$"; S2="pstest-dialog-$$"; S3="pstest-gen-$$"; S4="pstest-fb-$$"
S5="pstest-acok-$$"; S6="pstest-acbusy-$$"
cleanup() {
  for s in "$S1" "$S2" "$S3" "$S4" "$S5" "$S6"; do tmux kill-session -t "$s" 2>/dev/null; done
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

# actively generating: its own state, but NOT a blocking one for agent-msg
# (input queues at the prompt boundary); agent-clear does refuse on it.
gen_screen="$(printf '✳ Reticulating splines… (esc to interrupt)\n╭──────╮\n│ >  │\n╰──────╯\n')"
check "generating spinner -> busy" "busy" "$(printf '%s\n' "$gen_screen" | "$PS" --classify)"

# the interrupt hint on the status bar rather than a spinner line
statusbar_screen="$(printf '╭──────╮\n│ >  │\n╰──────╯\n  ⏵⏵ bypass permissions on · esc to interrupt\n')"
check "status-bar interrupt hint -> busy" "busy" "$(printf '%s\n' "$statusbar_screen" | "$PS" --classify)"

# a dialog on a busy pane is still a dialog: the stronger refusal wins
busy_dialog_screen="$(printf 'Do you want to proceed?\n ❯ 1. Yes\n   2. No\n  esc to interrupt\n')"
check "dialog beats busy -> dialog" "dialog" "$(printf '%s\n' "$busy_dialog_screen" | "$PS" --classify)"

# busy words scrolled above the bottom UI region must not match either
busy_scroll_screen="$(printf 'earlier output: the hint reads esc to interrupt\n%s╭──────╮\n│ >  │\n╰──────╯\n' "$(printf 'filler line\n%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)")"
check "busy words above UI region -> clear" "clear" "$(printf '%s\n' "$busy_scroll_screen" | "$PS" --classify)"

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
check "generating-look pane -> busy" "busy" "$("$PS" "$S3")"
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

# ---- agent-clear verification (offline, captured screens) --------------------

# Real post-clear screen, captured from a live session (tmux capture-pane -p -S -60):
# the reprinted startup banner followed by the echoed '❯ /clear'.
post_clear_screen="$(printf '  - KB wave-note 885caa5e → pushed\n ▐▛███▜▌   Claude Code v2.1.220\n▝▜█████▛▘  Opus 4.8 with xhigh effort · Claude Max\n  ▘▘ ▝▝    ~/projects/demo\n\n   Tackle your toughest work with Opus 5. Switch anytime with /model.\n\n❯ /clear\n\n')"
printf '%s\n' "$post_clear_screen" | "$AC" --verify
check "post-clear banner + echo -> verified" "0" "$?"

# Same screen with SGR colour escapes around the banner: normalisation must cope.
printf '%s\n' "$(printf '\x1b[1m ▐▛███▜▌\x1b[0m   \x1b[38;5;208mClaude Code v2.1.220\x1b[0m\n\n\x1b[2mghost\x1b[0m❯ /clear\n')" | "$AC" --verify
check "post-clear with SGR escapes -> verified" "0" "$?"

# agent-msg's prefixed text is NOT the echoed command (this is exactly why
# agent-msg cannot clear a session) — and it sits above the banner besides.
prefixed_screen="$(printf '❯ [agent-msg from rtde] /clear\n\n ▐▛███▜▌   Claude Code v2.1.220\n\n❯ [agent-msg from rtde] /clear\n')"
printf '%s\n' "$prefixed_screen" | "$AC" --verify
check "prefixed '/clear' chat text -> not verified" "1" "$?"

# an echoed '/clear' with no fresh banner under it: the command was typed but
# the session never restarted its context
printf '%s\n' "$(printf 'some earlier output\n❯ /clear\n')" | "$AC" --verify
check "echo without banner -> not verified" "1" "$?"

# banner above the echo only (stale ordering): not this clear
printf '%s\n' "$(printf '❯ /clear\n ▐▛███▜▌   Claude Code v2.1.220\n\n')" | "$AC" --verify
check "echo before banner -> not verified" "1" "$?"

# ---- agent-clear delivery (throwaway tmux sessions) --------------------------

# absent target
"$AC" "no-such-session-$$" 2>/dev/null
check "agent-clear on absent session exits 1" "1" "$?"

# dialog pane: refusal, no keys injected (S2 is still parked on its dialog)
: > "$TMP/dialog.out"
"$AC" "$S2" 2>/dev/null
check "agent-clear on dialog pane exits 2" "2" "$?"
sleep 0.5
[ ! -s "$TMP/dialog.out" ]
check "agent-clear injected no keys into dialog pane" "0" "$?"

# busy pane: refusal (exit 3), no keys injected — a queued '/clear' would arrive
# as chat text, so agent-clear waits for idle instead
tmux new-session -d -s "$S6" "printf '✳ Thinking… (esc to interrupt)\n'; cat > '$TMP/busy.out'"
sleep 0.5
check "busy pane -> busy" "busy" "$("$PS" "$S6")"
"$AC" "$S6" 2>/dev/null
check "agent-clear on busy pane exits 3" "3" "$?"
sleep 0.5
[ ! -s "$TMP/busy.out" ]
check "agent-clear injected no keys into busy pane" "0" "$?"

# idle pane that never shows a banner: keys are sent, but the clear is NOT
# claimed — unconfirmed is a loud failure, never a silent success
CLEAR_TIMEOUT=2 "$AC" "$S1" 2>/dev/null
check "agent-clear without banner exits 4" "4" "$?"
sleep 0.5
grep -qx '/clear' "$TMP/clear.out"
check "agent-clear typed a bare '/clear' (no prefix)" "0" "$?"

# idle pane that answers with a fresh banner + echo: confirmed clear
cat > "$TMP/fake-claude.sh" <<'FAKE'
#!/usr/bin/env bash
out="$1"
IFS= read -r line
printf '%s\n' "$line" > "$out"
printf ' ▐▛███▜▌   Claude Code v9.9.9\n▝▜█████▛▘  Test model · Claude Max\n\n'
printf '❯ %s\n\n' "$line"
exec cat >> "$out"
FAKE
tmux new-session -d -s "$S5" "bash '$TMP/fake-claude.sh' '$TMP/ok.out'"
sleep 0.5
out="$(CLEAR_TIMEOUT=10 "$AC" "$S5")"
check "agent-clear on confirming pane exits 0" "0" "$?"
check "agent-clear reports the session" "cleared '$S5'" "$out"
grep -qx '/clear' "$TMP/ok.out"
check "confirming pane received exactly '/clear'" "0" "$?"


echo "passed $pass, failed $fail"
exit $((fail > 0))
