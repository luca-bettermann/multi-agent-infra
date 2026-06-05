# agent-infra — Phase 1 of the multi-agent kanban workflow

Three pieces. See the KB notes `Agent Setup.md` (folder template/sessions) and
`CLAUDE.md` (routing/handoff/review rules); tracked by the task
`Roll out multi-agent kanban workflow`.

## 1. `kanban-dispatch.py` — board → session dispatcher
Polls the Obsidian CLAUDE Kanban (via `git fetch` on a KB clone) and fires four events:
- card enters **`open`** -> ping the owning session (routed by first scope tag, `sessions.conf`)
- card moves **`review` -> `in progress`** -> ping the owning session (design sign-off / build approval; routed like `open`)
- card enters **`review`** -> ping the user (`notify-send` + `~/.claude-inbox/_user.md`)
- card enters **`complete`** + `#from/<session>` -> ping that session (handoff callback)

A ping = a durable line in `~/.claude-inbox/<session>.md` **plus** a `tmux send-keys` nudge
(the inbox is the durable half; the keystroke is best-effort). Routing override: `#to/<session>`.

**Safe by default — `DRY_RUN=1`.**
```
python3 kanban-dispatch.py --preview     # show routing for current open cards (read-only)
python3 kanban-dispatch.py               # dry run (first run just records a baseline)
DRY_RUN=0 python3 kanban-dispatch.py     # GO LIVE
```
Enable via cron (every 1 min). **Status: LIVE since 2026-06-01.** Polling (not a
push webhook) is deliberate: the remote is GitHub (no server-side hooks), Obsidian
Git uses isomorphic-git (bypasses local hooks), and the box is behind NAT (a webhook
would need a maintained tunnel). 1 min is cron's floor; sub-minute would mean a
systemd timer/daemon and `git fetch` churn for no real gain — latency is dominated
by Obsidian's commit-and-sync, not the poll. Cron's default `PATH` (`/usr/bin:/bin`)
omits `/usr/local/bin` where `python3` lives here, so set `PATH` explicitly and use
absolute paths:
```
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * flock -n /tmp/kdispatch.lock env DRY_RUN=0 python3 /home/luca/projects/agent-infra/kanban-dispatch.py >> /home/luca/projects/agent-infra/dispatch.log 2>&1
```
`flock` execs its argument directly, so the env var is set via `env` (not a shell
`VAR=val` prefix). SSH `git fetch` works non-interactively (BatchMode-verified).
Config (env or top of file): `KB_DIR`, `SESSIONS_CONF`, `KDISPATCH_STATE`, `DRY_RUN`.
The user `review` ping is `notify-send` only — plug ntfy/Pushover into `notify_user()` for a phone push.

## 2. `block-context-repos.sh` — read-only context-repos/ guard
Claude Code PreToolUse hook: blocks Edit/Write under any `context-repos/` and tells the agent
to file a handoff card. Convention-level guard (the kernel guarantee is the bind mount). Enable in
`~/.claude/settings.json`:
```json
"hooks": { "PreToolUse": [ { "matcher": "Edit|Write|MultiEdit",
  "hooks": [ { "type": "command", "command": "/home/luca/projects/agent-infra/block-context-repos.sh" } ] } ] }
```

## 3. `mount-context-repo.sh` — read-only bind mount
```
./mount-context-repo.sh <owner-repo-path> <agent-root>
```
Mounts a repo read-only into `<agent-root>/context-repos/` (sudo; prints the `/etc/fstab` line to persist).

## 4. `context-mounts.conf` + `mount-all-context.sh` — persistent, manifest-driven mounts
`context-mounts.conf` is the **source of truth** for all cross-agent context bind mounts
(one `<source-repo> <agent-root>` per line). `mount-all-context.sh` mounts them all
read-only, idempotently (skips already-mounted, warns on a missing source) and re-execs
itself via `sudo` when run as non-root; `--dry-run` previews without mounting.

Persistence is the **systemd oneshot** `context-mounts.service` (runs the script at boot,
as root) — **not** `/etc/fstab`. To persist or change the mount topology, edit the
manifest, not fstab. `mount-context-repo.sh` (§3) is fine for a quick ad-hoc one-off, but
anything that should survive a reboot belongs in the manifest.

Install the boot unit (one-time):
```
sudo cp ~/projects/agent-infra/context-mounts.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now context-mounts.service
```
Add context for an agent: add a line to `context-mounts.conf`, then run `./mount-all-context.sh`.
