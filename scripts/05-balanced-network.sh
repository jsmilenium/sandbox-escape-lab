#!/usr/bin/env bash
# Battery 05 - network: host ports through gateway.docker.internal (deny-all) and the `balanced` profile.
# Measures what the balanced profile lets through (GitHub, npm, PyPI stay open = a data exfiltration channel).
# MIT License.   Usage: LAB_CONFIRM=yes [LAN_TARGETS="..."] bash scripts/05-balanced-network.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib.sh"
confirm
require_sbx

WS="$LAB_DIR/network/repo"; mkdir -p "$WS"
cleanup() { sbx rm -f lab-network >>"$LOG" 2>&1; policy_reset "$LAB_POLICY_FINAL"; }
trap cleanup EXIT
policy_reset deny-all
run sbx create --name lab-network --skills=off shell "$WS"

log "== C1 HOST ports through gateway.docker.internal with deny-all (expected: 000; only the 3128 proxy answers)"
in_sandbox lab-network C1 'for p in 22 80 443 3128 5432 8080; do printf "port $p: "; curl -s -m 4 -o /dev/null -w "%{http_code}" http://gateway.docker.internal:$p/; echo; done'

log "== C2 balanced profile"
policy_reset balanced
run sbx policy ls
in_sandbox lab-network C2 'for u in https://github.com https://api.github.com https://raw.githubusercontent.com https://registry.npmjs.org https://pypi.org https://hub.docker.com https://pastebin.com https://webhook.site https://transfer.sh https://example.com; do printf "$u "; curl -s -m 6 -o /dev/null -w "%{http_code}" $u; echo; done'
if [ -n "$LAN_TARGETS" ]; then
  for a in $LAN_TARGETS; do
    in_sandbox lab-network "C2-lan-$(echo "$a" | tr -c 'A-Za-z0-9\n' '_')" "printf 'lan $a: '; curl -s -m 5 -o /dev/null -w '%{http_code}' http://$a; echo"
  done
else
  log "LAN_TARGETS empty: LAN test skipped"
fi
in_sandbox lab-network C2gist 'curl -s -m 8 -o /tmp/g.json -w "%{http_code}\n" -X POST https://api.github.com/gists -H "Content-Type: application/json" -d "{}"; head -c 200 /tmp/g.json; echo'
log "Interpretation: a 403 with a rate-limit message coming from GitHub itself = the request REACHED GitHub (outbound channel open)."
log "The sbx proxy 403 is something else (policy block): compare the response body."
