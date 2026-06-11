#!/usr/bin/env python3
"""limit-watcher — auto-resume Claude Code agents after the 5-hour usage limit.

Polls each ENROLLED tmux session (cron, every 1 min). When a session shows the
usage-limit screen, parses the reset time; once that time has passed (+buffer),
injects a resume prompt so the agent continues without a human re-prompting.

Why this shape (see [[Agent Setup]] -> auto-resume):
  - Detection is passive `tmux capture-pane` (reads the screen, injects nothing)
    of the already-displayed limit message — Claude Code exposes no limit hook.
  - The 5-hour limit is PER-ACCOUNT, shared across all sessions. So resuming the
    whole fleet at once just re-saturates the one bucket; we resume at most
    STAGGER session(s) per tick, in enrolled order, and only the enrolled set.
  - The `claude` process stays alive and keeps context through the limit, so a
    plain resume keystroke continues the same conversation (no --continue). The
    tmux send-keys pattern mirrors kanban-dispatch (proven to work from cron).

Robustness (overnight, unattended, first-shot):
  - Captured text is whitespace-normalised before matching, so a limit message
    that line-WRAPS in a narrow pane is still detected.
  - The reset time is RE-PARSED every tick; if a later reset appears (e.g. we
    resumed slightly too early and the session re-limited), reset_ts is bumped
    forward instead of hammering. Resume attempts are spaced by RETRY_BACKOFF
    and capped at MAX_ATTEMPTS, spanning ~1h — robust to clock skew.
  - Capture is VISIBLE-pane only (no scrollback) so a *stale* limit message from
    earlier in the night can't trigger a spurious resume after the screen scrolls.

Control (via the `auto-resume` CLI, which just writes these files):
  - master switch : presence of OFF_FILE  -> whole watcher paused (opt-in: ships present)
  - enrolled set  : ENROLL_FILE, one session name per line
State: STATE_FILE (json) tracks per-session reset_ts + attempts across ticks.

Run `limit-watcher.py --selftest` to exercise the reset-time parser offline.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta

DIR = os.path.dirname(os.path.abspath(__file__))
SESSIONS_CONF = os.environ.get("SESSIONS_CONF", os.path.join(DIR, "sessions.conf"))
OFF_FILE = os.path.join(DIR, "limit-watcher.off")        # present => master disabled
ENROLL_FILE = os.path.join(DIR, "auto-resume.enrolled")  # one session name per line
STATE_FILE = os.path.join(DIR, "limit-watcher.state.json")

BUFFER_SEC = 120          # wait this long past the parsed reset before resuming (clock-skew margin)
RETRY_BACKOFF = 300       # min seconds between resume attempts on the same session
STAGGER = 1               # max sessions to resume per tick (shared account bucket)
MAX_ATTEMPTS = 12         # give up resuming a session after this many tries (~1h with backoff)
FALLBACK_WAIT = 5 * 3600  # if the reset time can't be parsed, assume +5h (window length)
RESUME_PROMPT = (
    "Usage limit has reset — resume autonomously. Continue your in-progress work; "
    "if context was lost, reconcile from the kanban board (git pull the KB, pick up "
    "your in-progress cards). Keep working your queue; only stop for a genuine blocker "
    "or a decision that truly needs the user."
)

# Limit-screen signature. Claude Code shows e.g.
#   "Claude usage limit reached. Your limit will reset at 3pm"
#   "5-hour limit reached - resets 9:00pm"
LIMIT_RE = re.compile(r"(usage limit reached|limit will reset|\b\d+-hour limit\b)", re.I)
# Absolute reset time: "reset at 3pm", "resets 9:00pm", "will reset at 1pm", "reset at 15:00"
TIME_RE = re.compile(
    r"reset(?:s|\s+will\s+reset)?(?:\s+at)?\s+(\d{1,2})(?::(\d{2}))?\s*([ap]m)?", re.I
)
# Relative reset: "resets in 2h 30m", "reset in 45 minutes", "resets in 3 hours"
REL_RE = re.compile(
    r"reset\w*\s+in\s+(?:(\d+)\s*h(?:ours?)?)?\s*(?:(\d+)\s*m(?:in(?:utes?)?)?)?", re.I
)


def log(msg: str) -> None:
    print(f"{datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)


def normalize(text: str) -> str:
    """Collapse all whitespace (incl. newlines) to single spaces, so a limit
    message that wraps across pane lines still matches as one string."""
    return re.sub(r"\s+", " ", text)


def enrolled_sessions() -> list[str]:
    """Enrolled sessions, ordered by their appearance in sessions.conf (priority)."""
    if not os.path.exists(ENROLL_FILE):
        return []
    wanted = {l.strip() for l in open(ENROLL_FILE) if l.strip() and not l.startswith("#")}
    order: list[str] = []
    if os.path.exists(SESSIONS_CONF):
        for line in open(SESSIONS_CONF):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2 and parts[1] in wanted and parts[1] not in order:
                order.append(parts[1])
    for s in sorted(wanted):           # any enrolled session not in sessions.conf
        if s not in order:
            order.append(s)
    return order


def tmux_alive(sess: str) -> bool:
    return subprocess.run(["tmux", "has-session", "-t", sess],
                          capture_output=True).returncode == 0


def capture(sess: str) -> str:
    """Visible pane only — deliberately NOT scrollback, so a stale earlier limit
    message can't re-trigger a resume once the screen has scrolled past it."""
    r = subprocess.run(["tmux", "capture-pane", "-t", sess, "-p"],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def parse_reset_ts(text: str, now: float | None = None) -> float | None:
    """Epoch of the reset time in the limit message, or None if unparseable.

    `text` should already be whitespace-normalised. Absolute times are taken as
    the next wall-clock occurrence in LOCAL time (any tz token is ignored —
    Claude Code renders local time). Relative ("in 2h") is now + delta.
    """
    now = time.time() if now is None else now
    m = TIME_RE.search(text)
    if m:
        hh = int(m.group(1))
        mm = int(m.group(2) or 0)
        ap = (m.group(3) or "").lower()
        if ap == "pm" and hh != 12:
            hh += 12
        elif ap == "am" and hh == 12:
            hh = 0
        if 0 <= hh <= 23 and 0 <= mm <= 59:
            base = datetime.fromtimestamp(now)
            target = base.replace(hour=hh, minute=mm, second=0, microsecond=0)
            if target.timestamp() <= now:
                target += timedelta(days=1)
            return target.timestamp()
    r = REL_RE.search(text)
    if r and (r.group(1) or r.group(2)):
        return now + int(r.group(1) or 0) * 3600 + int(r.group(2) or 0) * 60
    return None


def resume(sess: str) -> None:
    """Inject the resume prompt into a session's live prompt.

    Mirrors kanban-dispatch / agent-msg exactly (literal text, then Enter as a
    separate key — send-keys drops a trailing newline). No clearing keystroke:
    the limit screen's input is empty, and agent-msg proves literal+Enter lands.
    """
    subprocess.run(["tmux", "send-keys", "-t", sess, "-l", "--", RESUME_PROMPT])
    time.sleep(0.4)                                       # let the TUI ingest the text first
    subprocess.run(["tmux", "send-keys", "-t", sess, "Enter"])


def load_state() -> dict:
    try:
        return json.load(open(STATE_FILE))
    except (OSError, ValueError):
        return {}


def save_state(state: dict) -> None:
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_FILE)


def main() -> None:
    if os.path.exists(OFF_FILE):          # master switch off
        return
    enrolled = enrolled_sessions()
    if not enrolled:
        return

    state = load_state()
    now = time.time()
    candidates: list[str] = []

    for sess in enrolled:
      try:
        if not tmux_alive(sess):
            state.pop(sess, None)
            continue
        screen = normalize(capture(sess))
        if LIMIT_RE.search(screen):
            rt_parsed = parse_reset_ts(screen, now)
            st = state.get(sess)
            if st is None:
                rt = rt_parsed if rt_parsed is not None else now + FALLBACK_WAIT
                state[sess] = {"reset_ts": rt, "attempts": 0, "last_attempt": 0.0,
                               "detected": now, "parsed": rt_parsed is not None}
                when = datetime.fromtimestamp(rt).isoformat(timespec="minutes")
                how = "" if rt_parsed is not None else " (UNPARSED — +5h fallback)"
                log(f"{sess}: limit detected, reset ~{when}{how}")
            else:
                # Re-parse each tick: if a LATER reset shows (we resumed too early
                # and it re-limited), push reset_ts forward instead of hammering.
                if rt_parsed is not None and rt_parsed > st["reset_ts"] + 60:
                    st["reset_ts"] = rt_parsed
                    log(f"{sess}: reset time moved to ~{datetime.fromtimestamp(rt_parsed).isoformat(timespec='minutes')}")
                ready = now >= st["reset_ts"] + BUFFER_SEC
                rested = now - st["last_attempt"] >= RETRY_BACKOFF
                if ready and rested and st["attempts"] < MAX_ATTEMPTS:
                    candidates.append(sess)
        else:
            if sess in state:             # limit screen gone => resumed (or cleared)
                log(f"{sess}: limit screen cleared — resumed")
                state.pop(sess, None)
      except Exception as e:              # one bad session must not wedge the tick
        log(f"{sess}: error while checking — {e!r} (will retry next tick)")

    for sess in candidates[:STAGGER]:     # stagger: shared account bucket
        st = state[sess]
        st["attempts"] += 1
        st["last_attempt"] = now
        resume(sess)
        log(f"{sess}: resume injected (attempt {st['attempts']}/{MAX_ATTEMPTS})")
        if st["attempts"] >= MAX_ATTEMPTS:
            log(f"{sess}: reached {MAX_ATTEMPTS} attempts — clearing state, giving up")
            state.pop(sess, None)

    save_state(state)


def selftest() -> None:
    cases = [
        "Claude usage limit reached. Your limit will reset at 3pm",
        "5-hour limit reached - resets 9:00pm",
        "Your limit will reset at 1pm (America/New_York)",
        "limit will reset at 15:00",
        "Claude usage limit\nreached. Your limit will\nreset at 7:30am",   # wrapped
        "usage limit reached, resets in 2h 30m",
        "5-hour limit reached - reset in 45 minutes",
        "usage limit reached",          # no time -> None (fallback path)
    ]
    now = time.time()
    for c in cases:
        norm = normalize(c)
        detected = bool(LIMIT_RE.search(norm))
        rt = parse_reset_ts(norm, now)
        when = datetime.fromtimestamp(rt).isoformat(timespec="minutes") if rt else "UNPARSED(+5h)"
        print(f"detected={detected!s:5}  reset={when:20}  <- {c!r}")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        main()
