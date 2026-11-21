#!/usr/bin/env bash
# Battery 06 - resources: by default the sandbox gets the whole machine (CPU and memory).
# WARNING: this script EXHAUSTS CPU for ~20 s and allocates memory on the host. It may freeze a weak machine.
# Use only on a disposable machine with no work open.   MIT License.
# Variables: LAB_MEM_GB (memory to allocate in the VM, default 4), LAB_CPU_SECS (default 20), LAB_CONFIRM_RESOURCES=yes
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
confirm
require_sbx
MEM="${LAB_MEM_GB:-4}"; SECS="${LAB_CPU_SECS:-20}"
case "$MEM$SECS" in *[!0-9]*) echo "LAB_MEM_GB and LAB_CPU_SECS must be integers" >&2; exit 2;; esac
[ "${LAB_CONFIRM_RESOURCES:-}" = "yes" ] || { echo "Set LAB_CONFIRM_RESOURCES=yes: the test saturates the host CPU and memory." >&2; exit 2; }

WS="$LAB_DIR/resources/repo"; mkdir -p "$WS"
cleanup() { sbx rm -f lab-resources >>"$LOG" 2>&1; policy_reset "$LAB_POLICY_FINAL"; }
trap cleanup EXIT
policy_reset deny-all
run sbx create --name lab-resources --skills=off shell "$WS"
run sbx exec lab-resources -- sh -c 'nproc; grep MemTotal /proc/meminfo'

free_mem() { awk '/MemAvailable/{printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null; }
load() { cut -d' ' -f1 /proc/loadavg 2>/dev/null; }
log "BEFORE: load $(load) | free mem $(free_mem)"

log "== CPU: one loop per core for ${SECS}s"
sbx exec lab-resources -- sh -c "n=\$(nproc); i=0; while [ \$i -lt \$n ]; do timeout $SECS sh -c 'while :; do :; done' & i=\$((i+1)); done; wait" >>"$LOG" 2>&1 &
PID_CPU=$!
sleep 12
log "CPU (t=12s): load $(load) | $(top -bn1 2>/dev/null | grep -m1 'Cpu(s)')"
wait "$PID_CPU"

log "== MEMORY: hold ${MEM} GB in the VM for ~10 s (yes | head | grep keeps the whole line in memory)"
sbx exec lab-resources -- sh -c "yes | tr -d '\n' | head -c ${MEM}G | grep -c n" >>"$LOG" 2>&1 &
PID_MEM=$!
sleep 8
log "MEMORY (t=8s): host free mem $(free_mem)"
wait "$PID_MEM"
log "AFTER: load $(load) | free mem $(free_mem)"
log "To limit resources, see the options of 'sbx create --help' and 'sbx settings ls' (syntax not validated here)."
