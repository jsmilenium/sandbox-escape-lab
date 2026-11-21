#!/usr/bin/env bash
# Shared functions for the sandbox-escape-lab scripts. Do not run directly: it is loaded with `source`.
# MIT License.
#
# Environment variables (all optional):
#   LAB_DIR           lab working directory (default /var/tmp/sbx-escape-lab)
#   LAN_TARGETS       space-separated list of hosts on YOUR network to test (e.g. "<ip>:<port> <ip>"). Empty by default.
#   LAB_CONFIRM       "yes" to skip the interactive confirmation prompt
#   LAB_POLICY_FINAL  network policy to leave in place at the end (default deny-all)

LAB_DIR="${LAB_DIR:-/var/tmp/sbx-escape-lab}"
LAN_TARGETS="${LAN_TARGETS:-}"
LAB_POLICY_FINAL="${LAB_POLICY_FINAL:-deny-all}"
SBX_MIN="0.54.0"
export SBX_NO_TELEMETRY=1

# Refuse a dangerous working directory (root, home, relative).
case "$LAB_DIR" in
  /|""|"$HOME"|"$HOME"/) echo "dangerous LAB_DIR: $LAB_DIR" >&2; exit 2 ;;
  /*) ;;
  *) echo "LAB_DIR must be an absolute path: $LAB_DIR" >&2; exit 2 ;;
esac

OUTPUTS="$LAB_DIR/outputs/$(basename "$0" .sh)"
rm -rf "$OUTPUTS"; mkdir -p "$OUTPUTS"
LOG="$LAB_DIR/result-$(basename "$0" .sh).txt"
: > "$LOG"

log() { echo "$*" | tee -a "$LOG"; }

# run: executes a host command and records its output and exit code.
run() { log "\$ $*"; ( "$@" ) >>"$LOG" 2>&1; local rc=$?; log "[rc=$rc]"; return $rc; }

# rand N: N random bytes in hexadecimal.
rand() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

confirm() {
  cat <<'WARNING'
============================================================
WARNING: this lab tests the boundary of a sandbox.
Use ONLY on a machine that is YOURS and DISPOSABLE. It may reset the
global sbx network policy, create and remove sandboxes and use CPU/memory.
============================================================
WARNING
  if [ "${LAB_CONFIRM:-}" = "yes" ]; then return 0; fi
  if [ ! -t 0 ]; then echo "no terminal: set LAB_CONFIRM=yes to continue" >&2; exit 2; fi
  printf 'Type "yes" to continue: '; read -r r
  [ "$r" = "yes" ] || { echo "cancelled"; exit 2; }
}

version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

require_sbx() {
  command -v sbx >/dev/null 2>&1 || { echo "sbx not found in PATH" >&2; exit 2; }
  local v; v=$(sbx version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  if [ -z "$v" ]; then log "WARNING: could not read the sbx version";
  elif ! version_ge "$v" "$SBX_MIN"; then echo "sbx $v < $SBX_MIN" >&2; exit 2; fi
  log "sbx version: ${v:-unknown}"
  if [ "$(uname -s)" = "Linux" ] && { [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; }; then
    echo "/dev/kvm is not readable and writable by this user" >&2; exit 2
  fi
}

# Network policy: resets and applies a preset (allow-all | balanced | deny-all).
policy_reset() {
  sbx --no-input policy reset --force >>"$LOG" 2>&1 && sbx policy init "$1" >>"$LOG" 2>&1
  log "[network policy -> $1, rc=$?]"
}
policy_allow() { run sbx policy allow network "$1"; }
# Removes a network rule from the host: finds the id in the listing (best effort). The final reset handles the rest.
policy_remove() {
  local id
  id=$(sbx policy ls 2>/dev/null | grep -F -- "$1" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n1)
  if [ -n "$id" ]; then run sbx policy rm network --id "$id" --force; else log "(rule for $1 has no visible id; the final reset removes it)"; fi
}

# secret_exists <service>: 0 if a secret is already registered.
secret_exists() { sbx secret ls 2>/dev/null | grep -qiw -- "$1"; }

# in_sandbox <sandbox> <test> <command...>: runs inside the sandbox. The output goes to
# outputs/<script>/<test>.txt (ONLY what the sandbox printed) and also to the log.
in_sandbox() {
  local n=$1 t=$2; shift 2
  local f="$OUTPUTS/$t.txt"
  log "--- [$t/$n] $*"
  sbx exec "$n" -- sh -c "$*" >>"$f" 2>&1
  local rc=$?
  cat "$f" >>"$LOG"; log "[rc=$rc]"
}

# appears <output-file> <value>: 0 if the literal value is in the file.
appears() { [ -f "$1" ] && grep -qF -- "$2" "$1"; }

DIVERGENCES=0
# check <label> <value> <expected: leaks|no-leak> <output-files...>
check() {
  local label=$1 val=$2 exp=$3; shift 3
  local found=0 f
  for f in "$@"; do appears "$f" "$val" && found=1; done
  local state; [ $found = 1 ] && state="LEAKED" || state="OK (did not appear)"
  local conf="as expected"
  if { [ $found = 1 ] && [ "$exp" = "no-leak" ]; } || { [ $found = 0 ] && [ "$exp" = "leaks" ]; }; then
    conf="DIVERGES from docs ($exp)"; DIVERGENCES=$((DIVERGENCES+1))
  fi
  log "$label: $state - $conf"
}

# ---- real agent (used by 03 and 04) ----
# Each person tests the agent they prefer. Nothing here assumes a specific agent or provider.
#   AGENT            name of the sbx kit (see the ones listed by `sbx create --help`). No default.
#   AGENT_CMD        command of your agent in non-interactive mode; {PROMPT} is replaced by the task text.
#                    Generic example: AGENT_CMD='<your agent command in non-interactive mode> {PROMPT}'
#   SERVICE          name of the `sbx secret` service (the one for your agent's key)
#   LAB_KEY_VAR      NAME of the environment variable that holds the key (name only; no default)
#   LAB_ALLOW_HOSTS  extra hosts to allow on the network (if the agent kit does not allow what it needs)
AGENT="${AGENT:-}"
AGENT_CMD="${AGENT_CMD:-}"
SERVICE="${SERVICE:-}"
LAB_KEY_VAR="${LAB_KEY_VAR:-}"
LAB_ALLOW_HOSTS="${LAB_ALLOW_HOSTS:-}"
AG_NAME="${AG_NAME:-lab-agent}"

# safe single quotes for sh
quote() { local sq="'" bs='\'; local q=${1//$sq/$sq$bs$sq$sq}; printf "'%s'" "$q"; }

# agent_exec <output-file> <prompt>: runs the agent in the sandbox and writes the output.
agent_exec() {
  local out=$1 prompt=$2 q cmd
  q=$(quote "$prompt")
  cmd="${AGENT_CMD//\{PROMPT\}/$q}"
  sbx exec "$AG_NAME" -- sh -c "$cmd" </dev/null >"$out" 2>&1
  log "[agent rc=$?]"
}

agent_cleanup() {
  log "== agent cleanup"
  sbx rm -f "$AG_NAME" >>"$LOG" 2>&1
  [ -n "$SERVICE" ] && sbx secret rm "$SERVICE" --force >>"$LOG" 2>&1
  policy_reset "$LAB_POLICY_FINAL"
}

# agent_prepare <workspace-folder>: creates the sandbox with the chosen kit and registers the key through stdin.
# The key NEVER goes to a file or to the screen.
agent_prepare() {
  local ws=$1
  if [ -z "$AGENT" ]; then
    echo "Set AGENT=<sbx kit name>. See the available ones with: sbx create --help" >&2; exit 2
  fi
  [ -n "$AGENT_CMD" ] || { echo "Set AGENT_CMD (your agent command in non-interactive mode, with {PROMPT} in place of the task)" >&2; exit 2; }
  case "$AGENT_CMD" in *"{PROMPT}"*) ;; *) echo "AGENT_CMD must contain {PROMPT}" >&2; exit 2;; esac
  [ -n "$SERVICE" ] || { echo "Set SERVICE=<name of the sbx secret service for your agent's key>" >&2; exit 2; }
  [ -n "$LAB_KEY_VAR" ] || { echo "Set LAB_KEY_VAR=<NAME of the environment variable holding the key>" >&2; exit 2; }
  if [ "${LAB_CONFIRM_COST:-}" != "yes" ]; then
    echo "This script calls an AI model and may CHARGE your provider account. Set LAB_CONFIRM_COST=yes." >&2; exit 2
  fi
  [ -n "${!LAB_KEY_VAR:-}" ] || { echo "the variable $LAB_KEY_VAR is empty (the key is passed only through stdin)" >&2; exit 2; }
  if secret_exists "$SERVICE" && [ "${LAB_OVERWRITE_SECRET:-}" != "yes" ]; then
    echo "a secret '$SERVICE' already exists in sbx; this lab overwrites it and deletes it at the end. Set LAB_OVERWRITE_SECRET=yes if you accept." >&2; exit 2
  fi
  trap agent_cleanup EXIT
  policy_reset deny-all
  for h in $LAB_ALLOW_HOSTS; do policy_allow "$h"; done
  printf '%s' "${!LAB_KEY_VAR}" | sbx secret set "$SERVICE" >>"$LOG" 2>&1
  log "[secret set rc=$?]"
  sbx rm -f "$AG_NAME" >>"$LOG" 2>&1
  run sbx create --name "$AG_NAME" --skills=off "$AGENT" "$ws"
}
