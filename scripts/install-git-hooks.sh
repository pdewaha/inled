#!/usr/bin/env bash
# Point this repo at .githooks/ (pre-commit normalizes *.sh to LF).
#
# Usage (once per clone, from repo root):
#   bash scripts/install-git-hooks.sh

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit 2>/dev/null || true
chmod +x scripts/*.sh 2>/dev/null || true

echo "Git hooks installed: core.hooksPath=.githooks"
echo "Pre-commit will auto-fix CRLF in staged *.sh files before each commit."
