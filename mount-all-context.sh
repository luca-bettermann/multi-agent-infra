#!/usr/bin/env bash
# Mount all cross-agent context-repos read-only, per context-mounts.conf.
# Idempotent: skips already-mounted targets; warns (never fails the run) on a missing source.
# Run manually (re-execs itself via sudo) or at boot (context-mounts.service, already root).
#   ./mount-all-context.sh [--dry-run] [manifest-path]
set -uo pipefail

DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || exec sudo "$0" "$@"

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${1:-$DIR/context-mounts.conf}"
[ -f "$CONF" ] || { echo "manifest not found: $CONF" >&2; exit 1; }

ok=0; skip=0; miss=0
while read -r src agent _; do
  case "${src:-}" in ''|'#'*) continue;; esac
  [ -n "${agent:-}" ] || { echo "bad line (no agent root): $src" >&2; continue; }
  dst="$agent/context-repos/$(basename "$src")"
  if mountpoint -q "$dst" 2>/dev/null; then echo "skip (mounted): $dst"; skip=$((skip+1)); continue; fi
  if [ ! -d "$src" ]; then echo "MISS (no source): $src" >&2; miss=$((miss+1)); continue; fi
  if [ "$DRY" = 1 ]; then echo "[dry] mount ro: $dst <- $src"; ok=$((ok+1)); continue; fi
  mkdir -p "$dst"
  if mount --bind "$src" "$dst" && mount -o remount,ro,bind "$src" "$dst"; then
    echo "mounted ro: $dst <- $src"; ok=$((ok+1))
  else
    echo "FAILED: $dst <- $src" >&2
  fi
done < "$CONF"
echo "done: $ok mounted/ok, $skip already-mounted, $miss missing-source"
