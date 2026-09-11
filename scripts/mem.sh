#!/bin/bash
# Report what damir.ytmusic costs in memory right now (PSS incl. swap, MiB).
#
# The omarchy-shell line is the whole shell process; compare it with the
# plugin disabled to get the panel's share.
set -euo pipefail

pss_kb() {
  awk '/^Pss:/ { p = $2 } /^SwapPss:/ { s = $2 } END { print p + s }' "/proc/$1/smaps_rollup" 2>/dev/null || echo 0
}

row() {
  printf '%-30s %6d MiB\n' "$1" $(( $2 / 1024 ))
}

shell_kb=0
for pid in $(pgrep -f 'quickshell .*omarchy/shell' || true); do
  shell_kb=$(( shell_kb + $(pss_kb "$pid") ))
done

mpv_kb=0
cgroup=$(systemctl --user show -p ControlGroup --value omarchy-ytmusic-mpv 2>/dev/null || true)
if [[ -n $cgroup && -r /sys/fs/cgroup$cgroup/cgroup.procs ]]; then
  for pid in $(cat "/sys/fs/cgroup$cgroup/cgroup.procs"); do
    mpv_kb=$(( mpv_kb + $(pss_kb "$pid") ))
  done
fi

worker_kb=0
for pid in $(pgrep -f 'backend/ytm\.py serve' || true); do
  worker_kb=$(( worker_kb + $(pss_kb "$pid") ))
done

row "omarchy-shell (whole process)" "$shell_kb"
row "mpv player" "$mpv_kb"
row "ytmusicapi worker" "$worker_kb"
row "plugin processes (mpv+worker)" $(( mpv_kb + worker_kb ))
