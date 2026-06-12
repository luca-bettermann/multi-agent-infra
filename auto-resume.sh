#!/usr/bin/env bash
# auto-resume — control the limit-watcher (auto-resume agents after the 5h limit).
# Thin control surface over the files limit-watcher.py reads. See limit-watcher.py
# and [[Agent Setup]] -> auto-resume.
#
#   auto-resume on                 # master switch ON  (remove the kill-switch file)
#   auto-resume off                # master switch OFF (pause the whole watcher)
#   auto-resume enable  <session>  # enroll a session  (it may be auto-resumed)
#   auto-resume disable <session>  # unenroll a session
#   auto-resume status             # master state + enrolled set + cron + recent log
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"   # resolve symlink (~/.local/bin) to the real agent-infra dir
OFF="$DIR/limit-watcher.off"
ENROLL="$DIR/auto-resume.enrolled"
LOG="$DIR/limit-watcher.log"

cmd="${1:-status}"
case "$cmd" in
  on)   rm -f "$OFF";   echo "auto-resume master: ON" ;;
  off)  : > "$OFF";     echo "auto-resume master: OFF (watcher paused)" ;;
  enable)
    s="${2:?usage: auto-resume enable <session>}"
    touch "$ENROLL"
    grep -qxF "$s" "$ENROLL" || echo "$s" >> "$ENROLL"
    echo "enrolled: $s"
    ;;
  disable)
    s="${2:?usage: auto-resume disable <session>}"
    if [ -f "$ENROLL" ]; then
      grep -vxF "$s" "$ENROLL" > "$ENROLL.tmp" 2>/dev/null || true
      mv "$ENROLL.tmp" "$ENROLL"
    fi
    echo "unenrolled: $s"
    ;;
  status)
    if [ -f "$OFF" ]; then echo "master:   OFF (paused)"; else echo "master:   ON"; fi
    enrolled="$( ( [ -f "$ENROLL" ] && tr '\n' ' ' < "$ENROLL" ) || true)"
    echo "enrolled: ${enrolled:-<none>}"
    if crontab -l 2>/dev/null | grep -q "limit-watcher.py"; then
      echo "cron:     installed"
    else
      echo "cron:     NOT installed (watcher will not run — see Agent Setup)"
    fi
    echo "--- recent log ---"
    tail -n 8 "$LOG" 2>/dev/null || echo "(no log yet)"
    ;;
  *)
    echo "usage: auto-resume {on|off|status|enable <session>|disable <session>}" >&2
    exit 1
    ;;
esac
