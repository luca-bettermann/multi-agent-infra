#!/usr/bin/env python3
"""
kanban-dispatch — poll the Obsidian CLAUDE Kanban and notify the right tmux
Claude session when a card changes column.

Fires exactly three events:
  * card enters `open`                    -> ping the owning session (routed by first scope tag)
  * card enters `review`                  -> ping the user
  * card enters `complete` + #from/<sess> -> ping that session (handoff callback)
Everything else is silence.

SAFE BY DEFAULT: DRY_RUN=1 logs what it WOULD do and touches nothing.
  python3 kanban-dispatch.py --preview   # show routing for current open cards (read-only)
  python3 kanban-dispatch.py             # dry run (first run just sets the baseline)
  DRY_RUN=0 python3 kanban-dispatch.py   # go live
"""
import os, re, subprocess, sys, time

# ---- config (env-overridable) ------------------------------------------------
KB_DIR    = os.environ.get("KB_DIR", os.path.expanduser("~/projects/advei/knowledge-base"))
BOARD     = "CLAUDE Kanban.md"
CONF      = os.environ.get("SESSIONS_CONF", os.path.expanduser("~/projects/agent-infra/sessions.conf"))
STATE     = os.environ.get("KDISPATCH_STATE", os.path.expanduser("~/projects/agent-infra/.state"))
INBOX_DIR = os.path.expanduser("~/.claude-inbox")
LOGFILE   = os.path.expanduser("~/projects/agent-infra/dispatch.log")
# no catch-all: an unmapped scope is logged and not routed
DRY_RUN   = os.environ.get("DRY_RUN", "1") != "0"   # default: dry
# -----------------------------------------------------------------------------

CARD_RE = re.compile(r'^- \[[ xX]\] \[\[([^\]|]+?)(?:\|[^\]]*)?\]\](.*)$')
HEAD_RE = re.compile(r'^## (.+?)\s*$')

def log(msg):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line)
    try:
        with open(LOGFILE, "a") as f:
            f.write(time.strftime('%Y-%m-%d ') + line + "\n")
    except OSError:
        pass

def sh(*args):
    return subprocess.run(args, capture_output=True, text=True)

def load_routes():
    routes = {}
    if os.path.exists(CONF):
        for ln in open(CONF):
            ln = ln.split("#", 1)[0].strip()
            p = ln.split()
            if len(p) >= 2:
                routes[p[0].lstrip("#")] = p[1]
    return routes

def parse_board(text):
    """{card_title: (column, [tags])}"""
    cards, col = {}, None
    for ln in text.splitlines():
        h = HEAD_RE.match(ln)
        if h:
            col = h.group(1).strip().lower()
            continue
        m = CARD_RE.match(ln.strip())
        if m and col:
            tags = re.findall(r'#([A-Za-z0-9:/_\-]+)', m.group(2))
            cards[m.group(1).strip()] = (col, tags)
    return cards

def board_at(ref):
    r = sh("git", "-C", KB_DIR, "show", f"{ref}:{BOARD}")
    return r.stdout if r.returncode == 0 else ""

def handoff_target(tag, kind):
    # kind is "from" or "to". Accept the Obsidian-valid nested form
    # (kind/<session>) and the legacy colon form (kind:<session>). A colon is
    # NOT a valid Obsidian tag char, so #from:x renders as #from + stray ":x" —
    # prefer the slash form on the board.
    for sep in ("/", ":"):
        if tag.startswith(kind + sep):
            return tag[len(kind) + 1:]
    return None

def route(tags, routes):
    for t in tags:                       # #to/<session> hard override (or legacy #to:)
        tgt = handoff_target(t, "to")
        if tgt:
            return tgt
    for t in tags:                       # first scope tag present in the map
        if t in routes:
            return routes[t]
    return None                          # no catch-all: unmapped scope is not routed

def session_running(s):
    return sh("tmux", "has-session", "-t", s).returncode == 0

def ping_session(sess, kind, card):
    note = f"{time.strftime('%H:%M')}  {kind}: {card}"
    if DRY_RUN:
        log(f"[DRY] -> inbox {sess}.md + send-keys {sess}: {note}")
        return
    os.makedirs(INBOX_DIR, exist_ok=True)
    with open(os.path.join(INBOX_DIR, f"{sess}.md"), "a") as f:
        f.write(note + "\n")
    if session_running(sess):
        sh("tmux", "send-keys", "-t", sess,
           f"kanban: {kind} — read ~/.claude-inbox/{sess}.md, git pull KB, pick it up")
        sh("tmux", "send-keys", "-t", sess, "Enter")   # Enter separately: send-keys drops a trailing newline
    else:
        log(f"session '{sess}' not running — queued in inbox only")

def notify_user(card):
    if DRY_RUN:
        log(f"[DRY] -> notify user (review): {card}")
        return
    os.makedirs(INBOX_DIR, exist_ok=True)
    with open(os.path.join(INBOX_DIR, "_user.md"), "a") as f:
        f.write(f"{time.strftime('%H:%M')}  REVIEW: {card}\n")
    sh("notify-send", "Kanban review", card)
    # TODO: plug ntfy/Pushover here for a real phone push.

def preview():
    routes = load_routes()
    board = parse_board(open(os.path.join(KB_DIR, BOARD)).read())
    print(f"Routing preview ({'DRY' if DRY_RUN else 'LIVE'}) — current board:")
    for title, (col, tags) in board.items():
        if col == "open":
            sess = route(tags, routes) or "UNMAPPED"
            print(f"  open    -> {sess:8}  {title}   [{' '.join('#'+t for t in tags)}]")
        elif col == "review":
            print(f"  review  -> {'USER':8}  {title}")

def main():
    if "--preview" in sys.argv:
        preview(); return
    routes = load_routes()
    sh("git", "-C", KB_DIR, "fetch", "-q", "origin")
    new_ref = sh("git", "-C", KB_DIR, "rev-parse", "origin/main").stdout.strip()
    old_ref = open(STATE).read().strip() if os.path.exists(STATE) else ""
    if not new_ref:
        log("could not resolve origin/main — abort"); return
    if old_ref == new_ref:
        return
    if not old_ref:
        open(STATE, "w").write(new_ref)
        log(f"baseline set to {new_ref[:8]} — no notifications on first run"); return

    old, new = parse_board(board_at(old_ref)), parse_board(board_at(new_ref))
    for title, (col, tags) in new.items():
        prev = old.get(title, (None, []))[0]
        if col == prev:
            continue                       # column unchanged
        if col == "open":
            sess = route(tags, routes)
            if not sess:
                log(f"open: '{title}' — UNMAPPED scope, not routed  [{' '.join('#'+t for t in tags)}]")
                continue
            log(f"open: '{title}' -> {sess}")
            ping_session(sess, "new task", title)
        elif col == "in progress" and prev == "review":
            # user sign-off: review -> in progress hands the card back to the
            # owning agent (build the approved design, or address review feedback)
            sess = route(tags, routes)
            if not sess:
                log(f"resume: '{title}' — UNMAPPED scope, not routed  [{' '.join('#'+t for t in tags)}]")
                continue
            log(f"resume: '{title}' (review->in progress) -> {sess}")
            ping_session(sess, "resume — build/continue per the note", title)
        elif col == "review":
            log(f"review: '{title}' -> user")
            notify_user(title)
        elif col == "complete":
            frm = None
            for t in tags:
                frm = handoff_target(t, "from")
                if frm:
                    break
            if frm:
                log(f"complete: '{title}' -> {frm} (handoff callback)")
                ping_session(frm, "handoff cleared — unblock your dependent card and proceed", title)
    open(STATE, "w").write(new_ref)

if __name__ == "__main__":
    main()
