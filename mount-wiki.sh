#!/usr/bin/env bash
# Bind-mount the RoboLab wiki READ-ONLY into every agent's knowledge-base/robolab,
# so all KB checkouts see the wiki. The canonical clone is master's (writable, master
# maintains it); all other agents get a read-only view of it. Editing the wiki is done
# deliberately in a SEPARATE clone (branch + push), never through these read-only mounts.
#
# Idempotent: skips already-mounted targets. Run manually (re-execs via sudo) or at boot.
#   ./mount-wiki.sh [--dry-run] [--fstab]
set -uo pipefail

CANON="/home/luca/projects/master/knowledge-base/robolab"

DRY=0; SHOW_FSTAB=0
for a in "$@"; do case "$a" in --dry-run) DRY=1;; --fstab) SHOW_FSTAB=1;; esac; done
[ "$DRY" = 1 ] || [ "$SHOW_FSTAB" = 1 ] || [ "$(id -u)" = 0 ] || exec sudo "$0" "$@"

[ -d "$CANON/.git" ] || { echo "canonical wiki clone missing: $CANON" >&2; exit 1; }

ok=0; skip=0
for kb in /home/luca/projects/*/knowledge-base; do
  [ "$kb" = "/home/luca/projects/master/knowledge-base" ] && continue   # master owns the canonical
  [ -d "$kb" ] || continue
  dst="$kb/robolab"
  if [ "$SHOW_FSTAB" = 1 ]; then echo "$CANON  $dst  none  bind,ro,nofail  0 0"; continue; fi
  if mountpoint -q "$dst" 2>/dev/null; then echo "skip (mounted): $dst"; skip=$((skip+1)); continue; fi
  if [ "$DRY" = 1 ]; then echo "[dry] mount ro: $dst <- $CANON"; ok=$((ok+1)); continue; fi
  mkdir -p "$dst"
  if mount --bind "$CANON" "$dst" && mount -o remount,ro,bind "$CANON" "$dst"; then
    echo "mounted ro: $dst <- $CANON"; ok=$((ok+1))
  else
    echo "FAILED: $dst <- $CANON" >&2
  fi
done
[ "$SHOW_FSTAB" = 1 ] && exit 0
echo "done: $ok mounted, $skip already-mounted"
echo "persist across reboots: ./mount-wiki.sh --fstab | sudo tee -a /etc/fstab"
