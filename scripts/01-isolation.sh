#!/usr/bin/env bash
# Battery 01 - isolation: 10 sbx boundary tests with synthetic canaries.
# Adapted from the escape test of 2026-11-21. MIT License.
# Usage: LAB_CONFIRM=yes [LAN_TARGETS="<host>[:port] ..."] bash scripts/01-isolation.sh
# Everything is synthetic: random canaries, no real key, nothing outside $LAB_DIR.
# T9 (credential through the proxy) only runs if you provide the service and the API host of ONE provider of yours:
#   SERVICE=<sbx secret service> T9_HOST=<API host of that service> bash scripts/01-isolation.sh
# Without that, T9 is skipped.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"
confirm
require_sbx

B="$LAB_DIR"
CAN_FILE="canary-file-$(rand 12)"
CAN_ENV="canary-env-$(rand 12)"
CAN_DOTENV="canary-dotenv-$(rand 12)"
SERVICE="${SERVICE:-}"; T9_HOST="${T9_HOST:-}"
CAN_SECRET="canary-secret-$(rand 16)"
export CANARY_HOST_ENV="$CAN_ENV"

cleanup() {
  log "== F4 cleanup"
  sbx rm -f lab-clone >>"$LOG" 2>&1
  sbx rm -f lab-rw >>"$LOG" 2>&1
  [ -n "$SERVICE" ] && sbx secret rm "$SERVICE" --force >>"$LOG" 2>&1
  policy_reset "$LAB_POLICY_FINAL"
  log "END $(date '+%d/%m %H:%M')"
}
if [ -n "$SERVICE" ] && secret_exists "$SERVICE" && [ "${LAB_OVERWRITE_SECRET:-}" != "yes" ]; then
  echo "a secret '$SERVICE' already exists in sbx; T9 would overwrite it and delete it at the end. Set LAB_OVERWRITE_SECRET=yes to accept." >&2
  exit 2
fi
trap cleanup EXIT

log "== F0 versions and diagnostics"
run sbx version
run sbx diagnose
run sbx settings set telemetry.disabled true

log "== F1 lab setup"
rm -rf "$B/repo" "$B/repo-rw" "$B/outside"
mkdir -p "$B/repo" "$B/repo-rw" "$B/outside"
echo "$CAN_FILE" > "$B/outside/canary.txt"
( cd "$B/repo" && git init -q && echo "TOKEN=$CAN_DOTENV" > .env && echo "hello" > app.txt && git add app.txt && git -c user.email=lab@example.invalid -c user.name=lab commit -qm base )
ln -s "$B/outside/canary.txt" "$B/repo/symlink.txt"
ln "$B/outside/canary.txt" "$B/repo/hardlink.txt" 2>/dev/null || log "hard link not created in repo"
cp -a "$B/repo/." "$B/repo-rw/"
# cp -a turns the hard link into a NEW FILE (another inode). Recreate the real link in repo-rw.
rm -f "$B/repo-rw/hardlink.txt"
ln "$B/outside/canary.txt" "$B/repo-rw/hardlink.txt" 2>/dev/null || log "hard link not created in repo-rw"
I1=$(stat -c %i "$B/outside/canary.txt" 2>/dev/null); I2=$(stat -c %i "$B/repo-rw/hardlink.txt" 2>/dev/null)
if [ -n "$I1" ] && [ "$I1" = "$I2" ]; then log "hard link confirmed: same inode ($I1)"; else log "WARNING: hard link does NOT share an inode ($I1 x $I2); T3 is invalid on this file system"; fi
hash_repo() { ( cd "$B/repo" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum ); }
HASH_BEFORE=$(hash_repo)
log "repo hash (host) before: $HASH_BEFORE"

log "== F2 network policy denied by default"
policy_reset deny-all
run sbx policy ls

log "== F3 sandboxes: lab-clone (--clone) and lab-rw (folder mounted with write access)"
sbx rm -f lab-clone >>"$LOG" 2>&1; sbx rm -f lab-rw >>"$LOG" 2>&1
run sbx create --name lab-clone --skills=off --clone shell "$B/repo"
run sbx create --name lab-rw --skills=off shell "$B/repo-rw"
run sbx ls

log "== T1 canary outside the workspace, by absolute path (expected: not found)"
in_sandbox lab-clone T1-clone "cat $B/outside/canary.txt"
in_sandbox lab-rw T1-rw "cat $B/outside/canary.txt"
log "== T2 symlink pointing outside (docs: not followed)"
in_sandbox lab-rw T2 "cat symlink.txt; ls -la symlink.txt"
log "== T3 hard link to a file outside (docs admit it passes in direct mode)"
in_sandbox lab-rw T3 "cat hardlink.txt"
log "== T4 .env in --clone (docs: still readable at the source)"
in_sandbox lab-clone T4 "cat /run/sandbox/source/.env; pwd; ls -la; cat .env 2>/dev/null"
log "== T5 write to the source through --clone (expected: host does not change)"
in_sandbox lab-clone T5 "echo changed-by-agent > app.txt; git add -A; git -c user.email=a@example.invalid -c user.name=a commit -qm agent; echo written >> /run/sandbox/source/app.txt"
HASH_AFTER=$(hash_repo)
log "repo hash (host) after: $HASH_AFTER"
if [ "$HASH_BEFORE" = "$HASH_AFTER" ]; then log "T5 RESULT: source intact (as expected)"; else log "T5 RESULT: SOURCE CHANGED (DIVERGES from docs)"; DIVERGENCES=$((DIVERGENCES+1)); fi
log "== T5b write in read/write mode (documented: shows up on the host immediately)"
in_sandbox lab-rw T5b "echo written-by-agent > new-file.txt"
if [ -f "$B/repo-rw/new-file.txt" ]; then log "T5b RESULT: agent file showed up on the host (as documented)"; else log "T5b RESULT: file did NOT show up (DIVERGES from docs)"; DIVERGENCES=$((DIVERGENCES+1)); fi

log "== T6 network with deny-all"
in_sandbox lab-rw T6a "curl -s -m 8 -o /dev/null -w '%{http_code}' https://example.com; echo"
if [ -n "$LAN_TARGETS" ]; then
  for a in $LAN_TARGETS; do
    in_sandbox lab-rw "T6-lan-$(echo "$a" | tr -c 'A-Za-z0-9\n' '_')" "curl -s -m 5 -o /dev/null -w '%{http_code}' http://$a; echo"
  done
else
  log "LAN_TARGETS empty: LAN test skipped (provide hosts on YOUR network to measure)"
fi
in_sandbox lab-rw T6c "getent hosts example.com; nslookup example.com 8.8.8.8 2>&1 | tail -2; ping -c1 -W2 8.8.8.8 2>&1 | tail -1"

log "== T7 inner Docker does not see the host"
HOST_NAMES=""
if command -v docker >/dev/null 2>&1; then
  HOST_NAMES=$(docker ps --format '{{.Names}}' 2>/dev/null)
  log "containers on the host: $(echo "$HOST_NAMES" | grep -c .)"
else log "(host has no docker)"; fi
in_sandbox lab-rw T7 "docker ps --format '{{.Names}}' 2>&1 | head"

log "== T8 host environment variable (expected: absent)"
in_sandbox lab-rw T8-rw "env | grep canary-env- || true"
in_sandbox lab-clone T8-clone "env | grep canary-env- || true"

log "== T9 credential: fake secret through the proxy (expected: value never enters the VM)"
T9_RAN=0
if [ -n "$SERVICE" ] && [ -n "$T9_HOST" ]; then
  T9_RAN=1
  printf '%s' "$CAN_SECRET" | sbx secret set "$SERVICE" >>"$LOG" 2>&1; log "[secret set rc=$?]"
  policy_allow "$T9_HOST"
  in_sandbox lab-rw T9a "env | grep -o 'canary-secret-[0-9a-f]*' || true; grep -rhao 'canary-secret-[0-9a-f]*' /etc /home /root /run 2>/dev/null | head -3; echo end-of-search"
  in_sandbox lab-rw T9b "curl -s -m 10 https://$T9_HOST/ -o /tmp/r.txt -w '%{http_code}\n'; head -c 300 /tmp/r.txt; echo"
  policy_remove "$T9_HOST"
else
  log "T9 skipped (set SERVICE and T9_HOST)"
fi

log "== CANARY SUMMARY (only the sandbox output counts; the host log does not)"
S="$OUTPUTS"
check "T1 canary-file (clone)" "$CAN_FILE" no-leak "$S/T1-clone.txt"
check "T1 canary-file (rw)" "$CAN_FILE" no-leak "$S/T1-rw.txt"
check "T2 symlink -> canary-file" "$CAN_FILE" no-leak "$S/T2.txt"
check "T3 hard link -> canary-file" "$CAN_FILE" leaks "$S/T3.txt"
check "T4 canary-dotenv in --clone" "$CAN_DOTENV" leaks "$S/T4.txt"
check "T8 canary-env (rw)" "$CAN_ENV" no-leak "$S/T8-rw.txt"
check "T8 canary-env (clone)" "$CAN_ENV" no-leak "$S/T8-clone.txt"
[ $T9_RAN = 1 ] && check "T9 fake secret" "$CAN_SECRET" no-leak "$S/T9a.txt" "$S/T9b.txt"
LEAK_DOCKER=0
if [ -n "$HOST_NAMES" ]; then
  while IFS= read -r nm; do [ -n "$nm" ] && grep -qxF -- "$nm" "$S/T7.txt" && LEAK_DOCKER=1; done <<EOF
$HOST_NAMES
EOF
  if [ $LEAK_DOCKER = 1 ]; then log "T7 host containers visible inside the sandbox: LEAKED (DIVERGES from docs)"; DIVERGENCES=$((DIVERGENCES+1)); else log "T7 host containers: OK (did not appear) - as expected"; fi
fi
[ $T9_RAN = 1 ] && log "T9b HTTP code of the call without the real key (a 401 suggests the proxy injected the fake key): $(grep -oE '^[0-9]{3}' "$S/T9b.txt" | head -n1)"
log "DIVERGENCES from the documented behavior: $DIVERGENCES"
log "Full result in: $LOG"
[ "$DIVERGENCES" -eq 0 ]
