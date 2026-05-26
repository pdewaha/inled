#!/usr/bin/env bash
# Fail if any shell script under scripts/ contains CRLF.
# Usage: bash scripts/check-shell-lf.sh

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bad=0

while IFS= read -r -d '' f; do
  if grep -q $'\r' "$f" 2>/dev/null; then
    echo "CRLF: $f"
    bad=1
  fi
done < <(find "$ROOT/scripts" -name '*.sh' -print0 2>/dev/null)

if [[ "$bad" -ne 0 ]]; then
  echo "Fix with: sed -i 's/\\r$//' scripts/*.sh" >&2
  exit 1
fi

echo "OK: all scripts/*.sh use LF."
