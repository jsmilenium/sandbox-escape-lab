#!/usr/bin/env bash
# Battery 02 - kit signatures: `sbx kit verify` on the official kits and a test of kit.requireSignature.
# ALWAYS restores the original value of the setting (trap). MIT License.
# Usage: LAB_CONFIRM=yes bash scripts/02-kit-signatures.sh
# The kits tested are the ones sbx itself returns (listing). To pin the list: LAB_KITS="<name1> <name2>".
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
confirm
require_sbx

# Kit list: the agents sbx lists in `sbx create --help` ("Available agents: ...").
# To pin the list, use LAB_KITS.
if [ -n "${LAB_KITS:-}" ]; then
  KITS="$LAB_KITS"
else
  KITS=$(sbx create --help 2>&1 | sed -n 's/.*Available agents:[[:space:]]*//p' | tr ',' ' ' | tr -s ' ')
fi
[ -n "$(echo "$KITS" | tr -d ' ')" ] || { echo "could not list the sbx kits; provide LAB_KITS=\"<name1> <name2>\"" >&2; exit 2; }
WS="$LAB_DIR/signatures/repo"
mkdir -p "$WS"

# original value (factory default: false)
ORIG=$(sbx settings ls 2>/dev/null | awk '$1=="kit.requireSignature"{print $2}')
case "$ORIG" in true|false) ;; *) ORIG=false ;; esac
log "original kit.requireSignature: $ORIG"

restore() {
  sbx settings set kit.requireSignature "$ORIG" >>"$LOG" 2>&1
  log "[kit.requireSignature restored to $ORIG]"
  for k in $KITS; do sbx rm -f "lab-sig-$k" >>"$LOG" 2>&1; done
}
trap restore EXIT

log "== S1 sbx kit verify on the official kits (default signer)"
for k in $KITS; do
  log "--- verify docker.io/sbx/$k:latest"
  sbx kit verify "docker.io/sbx/$k:latest" >"$OUTPUTS/verify-$k.txt" 2>&1; rc=$?
  cat "$OUTPUTS/verify-$k.txt" >>"$LOG"; log "[rc=$rc]"
  if [ $rc -eq 0 ]; then log "RESULT $k: valid signature"; else log "RESULT $k: NO verifiable signature (rc=$rc)"; fi
done

log "== S2 kit.requireSignature=true and create a sandbox with each kit"
run sbx settings set kit.requireSignature true
for k in $KITS; do
  sbx create --name "lab-sig-$k" --skills=off "$k" "$WS" >"$OUTPUTS/create-$k.txt" 2>&1; rc=$?
  cat "$OUTPUTS/create-$k.txt" >>"$LOG"
  if [ $rc -ne 0 ] && grep -qi "not signed\|signature" "$OUTPUTS/create-$k.txt"; then
    log "RESULT $k: REFUSED by the signature requirement (the lock works)"
  elif [ $rc -eq 0 ]; then
    log "RESULT $k: CREATED with requireSignature=true (kit signed by a trusted signer)"
  else
    log "RESULT $k: failed for another reason (rc=$rc), read $OUTPUTS/create-$k.txt"
  fi
done
log "Note: in the 2026-11-21 pilot (sbx 0.54.0) no official kit had a signature; the lock refused even the official ones."
