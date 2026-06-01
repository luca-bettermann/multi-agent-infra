#!/usr/bin/env bash
# Bind-mount a repo READ-ONLY into an agent's context-repos/.
# Usage: ./mount-context-repo.sh <owner-repo-path> <agent-root>
#   e.g. ./mount-context-repo.sh ~/projects/general/robolab-data-stack ~/projects/advei
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <owner-repo-path> <agent-root>"; exit 1; }
src=$(realpath "$1"); agent_root=$(realpath "$2")
name=$(basename "$src")
dst="$agent_root/context-repos/$name"
mkdir -p "$agent_root/context-repos"
if mountpoint -q "$dst" 2>/dev/null; then echo "$dst already mounted"; exit 0; fi
mkdir -p "$dst"
sudo mount --bind "$src" "$dst"
sudo mount -o remount,ro,bind "$src" "$dst"
echo "mounted read-only: $dst -> $src"
echo "to persist across reboots, add to /etc/fstab:"
echo "  $src  $dst  none  bind,ro  0 0"
