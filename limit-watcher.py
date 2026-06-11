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
    plain resume keystroke continues the same conversation (no --continue).

Control (via the `auto-resume` CLI, which just writes these files):
  - master switch : presence of OFF_FILE  -> whole watcher paused (opt-in: ships present)
  - enrolled set  : ENROLL_FILE, one session name per line
State: STATE_FILE (json) tracks per-session reset_ts + resume attempts across ticks.

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
OFF_FILE = os.path.join(DIR, "limit-watcher.off")       # present => master disabled
ENROLL_FILE = os.path.join(DIR, "auto-resume.enrolled")  # one session name per line
STATE_FILE = os.path.join(DIR, "limit-watcher.state.json")

BUFFER_SEC = 90        # wait this long past the parsed reset before resuming
STAGGER = 1            # max sessions to resume per tick (shared bucket)
MAX_ATTEMPTS = 8       # give up resuming a session after this many tries
FALLBACK_WAIT = 5 * 3600  # if the reset time can't be parsed, assume +5h (window len)
RESUME_PROMPT = (
    "Usage limit has reset — continue your in-progress work. If context was lost, "
    "reconcile from the kanban board (git pull the KB, resume your in-progress cards)."
)

# Limit-screen signature. Claude Code shows e.g.
#   "Claude usage limit reached. Your limit will reset at 3pm"
#   "5-hour limit reached - resets 9:00pm"
LIMIT_RE = re.compile(r"(usage limit reached|limit will reset|\b\d+-hour limit\b)", re.I)
# Reset time, e.g. "reset at 3pm", "resets 9:00pm", "will reset at 1pm", "reset at 15:00"
TIME_RE = re.compile(
    r"reset(?:s|\s+will\s+reset)?(?:\s+at)?\s+(\d{1,2})(?::(\d{2}))?\s*([ap]m)?", re.I
)


def log(msg: str) -> None:
    print(f"{datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)


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
    r = subprocess.run(["tmux", "capture-pane", "-t", sess, "-p"],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def parse_reset_ts(text: str, now: float | None = None) -> float | None:
    """Next wall-clock occurrence of the reset time in the limit message (local tz).

    Returns an epoch timestamp, or None if no time could be parsed. Any explicit
    timezone token in the message is ignored — Claude Code renders local time.
    """
    now = time.time() if now is None else now
    m = TIME_RE.search(text)
    if not m:
        return None
    hh = int(m.group(1))
    mm = int(m.group(2) or 0)
    ap = (m.group(3) or "").lower()
    if ap == "pm" and hh != 12:
        hh += 12
    elif ap == "am" and hh == 12:
        hh = 0
    if not (0 <= hh <= 23 and 0 <= mm <= 59):
        return None
    base = datetime.fromtimestamp(now)
    target = base.replace(hour=hh, minute=mm, second=0, microsecond=0)
    if target.timestamp() <= now:
        target += timedelta(days=1)
    return target.timestamp()


def resume(sess: str) -> None:
    """Inject the resume prompt into a session's live prompt (clear input first)."""
    subprocess.run(["tmux", "send-keys", "-t", sess, "C-u"])  # clear any pending input
    subprocess.run(["tmux", "send-keys", "-t", sess, "-l", "--", RESUME_PROMPT])
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
        if not tmux_alive(sess):
            state.pop(sess, None)
            continue
        screen = capture(sess)
        if LIMIT_RE.search(screen):
            if sess not in state:
                rt = parse_reset_ts(screen, now)
                if rt is None:
                    rt = now + FALLBACK_WAIT
                    log(f"{sess}: limit detected, reset time UNPARSED — falling back to +5h")
                else:
                    log(f"{sess}: limit detected, reset ~{datetime.fromtimestamp(rt).isoformat(timespec='minutes')}")
                state[sess] = {"reset_ts": rt, "attempts": 0, "detected": now}
            else:
                st = state[sess]
                if now >= st["reset_ts"] + BUFFER_SEC and st["attempts"] < MAX_ATTEMPTS:
                    candidates.append(sess)
        else:
            if sess in state:             # limit screen gone => resumed (or cleared)
                log(f"{sess}: limit screen cleared — resumed")
                state.pop(sess, None)

    for sess in candidates[:STAGGER]:     # stagger: shared account bucket
        state[sess]["attempts"] += 1
        n = state[sess]["attempts"]
        resume(sess)
        log(f"{sess}: resume injected (attempt {n}/{MAX_ATTEMPTS})")
        if n >= MAX_ATTEMPTS:
            log(f"{sess}: gave up after {MAX_ATTEMPTS} attempts — clearing state")
            state.pop(sess, None)

    save_state(state)


def selftest() -> None:
    cases = [
        "Claude usage limit reached. Your limit will reset at 3pm",
        "5-hour limit reached - resets 9:00pm",
        "Your limit will reset at 1pm (America/New_York)",
        "limit will reset at 15:00",
        "usage limit reached",          # no time -> None (fallback path)
    ]
    now = time.time()
    for c in cases:
        detected = bool(LIMIT_RE.search(c))
        rt = parse_reset_ts(c, now)
        when = datetime.fromtimestamp(rt).isoformat(timespec="minutes") if rt else "UNPARSED(+5h fallback)"
        print(f"detected={detected!s:5}  reset={when:30}  <- {c!r}")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        main()
