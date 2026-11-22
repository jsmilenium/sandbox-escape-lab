#!/usr/bin/env bash
# Positive control for the secrets gate. MIT License.
# Plants a fake key, a private IP and a random deny-listed word (with a temporary deny-list),
# requires exit 1; removes the plant and requires exit 0; checks that no value is printed.
# Usage: bash tools/gate-test.sh   (writes the result to tools/GATE-RESULT.txt)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GATE="$HERE/secrets-gate.sh"
PLANT="$ROOT/gate-plant.tmp.txt"
TMPDENY="$(mktemp)"
RES="$HERE/GATE-RESULT.txt"
# Ignored plant: a private IP inside a git-ignored path. It must NOT be reported (only files
# that would be published count). If the gate falls back to scanning every file, ip becomes 2.
IGNDIR="$ROOT/results"
IGNPLANT="$IGNDIR/gate-ignored-plant.tmp.log"
IGNDIR_CREATED=0
[ -d "$IGNDIR" ] || { mkdir -p "$IGNDIR" && IGNDIR_CREATED=1; }
trap 'rm -f "$PLANT" "$IGNPLANT" "$TMPDENY" "$HERE/.out1.tmp" "$HERE/.out2.tmp"; [ "$IGNDIR_CREATED" = 1 ] && rmdir "$IGNDIR" 2>/dev/null' EXIT

RANDVAL=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)
WORD="denyword$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 10)"
IP="192.168.""1.10"   # built in parts so the literal does not exist in this file
printf '%s\n' "$WORD" > "$TMPDENY"
printf 'MY_KEY=sk-test-%s\nserver=%s\ntext with %s inside\n' "$RANDVAL" "$IP" "$(echo "$WORD" | tr a-z A-Z)" > "$PLANT"
printf 'ignored log, server=%s\n' "$IP" > "$IGNPLANT"
IGN_OK=0
git -C "$ROOT" check-ignore -q "$IGNPLANT" 2>/dev/null && IGN_OK=1

GATE_DENYLIST="$TMPDENY" bash "$GATE" "$ROOT" > "$HERE/.out1.tmp" 2>&1; RC1=$?
rm -f "$PLANT"
GATE_DENYLIST="$TMPDENY" bash "$GATE" "$ROOT" > "$HERE/.out2.tmp" 2>&1; RC2=$?

PRINTED=0
grep -qF -- "$RANDVAL" "$HERE/.out1.tmp" && PRINTED=1
grep -qiF -- "$WORD" "$HERE/.out1.tmp" && PRINTED=1
F_KEY=$(grep -c '^FINDING \[API key' "$HERE/.out1.tmp")
F_IP=$(grep -c '^FINDING \[private IP' "$HERE/.out1.tmp")
F_DENY=$(grep -c '^FINDING \[personal deny-list' "$HERE/.out1.tmp")

{
  echo "Secrets gate test"
  echo "1) with plant: exit=$RC1 (expected 1); key=$F_KEY ip=$F_IP deny-list=$F_DENY (expected 1 each)"
  echo "2) without plant: exit=$RC2 (expected 0)"
  echo "3) planted values printed by the gate: $([ "$PRINTED" = 0 ] && echo no || echo YES)"
  echo "4) git-ignored plant skipped: plant ignored by git=$([ "$IGN_OK" = 1 ] && echo yes || echo NO), file list=$(grep -q '^secrets-gate: file list = git' "$HERE/.out1.tmp" && echo git || echo ALL-FILES) (expected yes, git; ip=1 above)"
} > "$RES"
cat "$RES"

LIST_GIT=0
grep -q '^secrets-gate: file list = git' "$HERE/.out1.tmp" && LIST_GIT=1
if [ "$RC1" -eq 1 ] && [ "$F_KEY" -eq 1 ] && [ "$F_IP" -eq 1 ] && [ "$F_DENY" -eq 1 ] && [ "$RC2" -eq 0 ] && [ "$PRINTED" -eq 0 ] && [ "$IGN_OK" -eq 1 ] && [ "$LIST_GIT" -eq 1 ]; then
  echo "GATE-TEST: PASS"; exit 0
fi
echo "GATE-TEST: FAIL"; exit 1
