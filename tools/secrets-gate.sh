#!/usr/bin/env bash
# Secrets gate. MIT License.
# Scans the repository (git ls-files + untracked, if it is a git repo; otherwise all files)
# and exits 1 if it finds a credential or a private IP address. Never prints the matched value.
# To release a documented example line, write the marker gate-ok on the same line.
#
# Personal deny-list (optional, NEVER committed): one case-insensitive extended regex per line,
# read from $GATE_DENYLIST (default: ~/.config/sandbox-escape-lab/denylist).
# Put there whatever must never be published: your user name, host names, home paths,
# public IP prefix, company or product names. Lines starting with # are ignored.
#
# Usage: bash tools/secrets-gate.sh [folder]   (default: repository root)
set -u
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 2
DENYLIST="${GATE_DENYLIST:-$HOME/.config/sandbox-escape-lab/denylist}"

PATTERNS=(
  'API key (sk- prefix)|(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}'
  'AWS access key|AKIA[0-9A-Z]{16}'
  'GitHub token|gh[pousr]_[A-Za-z0-9]{20,}'
  'private key block|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'Slack token|xox[baprs]-[A-Za-z0-9-]{10,}'
  'private IP 192.168.x.x|(^|[^0-9.])192\.168\.[0-9]{1,3}\.[0-9]{1,3}'
  'private IP 10.x.x.x|(^|[^0-9.])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
  'private IP 172.16-31.x.x|(^|[^0-9.])172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}'
)

DENY=()
if [ -f "$DENYLIST" ]; then
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"
    case "$l" in ''|'#'*) continue ;; esac
    DENY+=("$l")
  done < "$DENYLIST"
  echo "secrets-gate: personal deny-list loaded (${#DENY[@]} entries)"
else
  echo "secrets-gate: no personal deny-list at $DENYLIST (only generic patterns)"
fi

# Root check by --show-prefix (empty at the top level). Comparing --show-toplevel with pwd
# fails on Windows Git Bash (D:/x vs /d/x) and silently scanned ignored files too.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -z "$(git rev-parse --show-prefix 2>/dev/null)" ]; then
  FILES=$(git ls-files -co --exclude-standard)
  echo "secrets-gate: file list = git (tracked + untracked, ignored files skipped)"
else
  FILES=$(find . -type f -not -path './.git/*' | sed 's|^\./||')
  echo "secrets-gate: file list = all files (not at a git repository root)"
fi

FINDINGS=0
N=0
report() { # $1 label, $2 file, $3 regex, $4 extra grep flag
  while IFS=: read -r num _rest; do
    [ -n "$num" ] || continue
    line=$(sed -n "${num}p" "$2")
    case "$line" in *gate-ok*) continue ;; esac
    echo "FINDING [$1] $2:$num"
    FINDINGS=$((FINDINGS+1))
  done < <(grep -In$4E -e "$3" -- "$2" 2>/dev/null)
}
while IFS= read -r file; do
  [ -f "$file" ] || continue
  N=$((N+1))
  for p in "${PATTERNS[@]}"; do report "${p%%|*}" "$file" "${p#*|}" ""; done
  i=0
  for d in "${DENY[@]}"; do i=$((i+1)); report "personal deny-list entry #$i" "$file" "$d" "i"; done
done <<EOF
$FILES
EOF

echo "secrets-gate: $N files scanned, $FINDINGS finding(s)"
[ "$FINDINGS" -eq 0 ]
