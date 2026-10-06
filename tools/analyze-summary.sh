#!/usr/bin/env bash
# Runs tools/analyze.sh and prints each distinct problem once, sorted by file.
# Usage: tools/analyze-summary.sh [paths...]
# Filter to the files you touched, e.g.:
#   tools/analyze-summary.sh | grep SightingService
set -uo pipefail
cd "$(dirname "$0")/.."
bash tools/analyze.sh "$@" 2>&1 \
  | grep -E '^([a-zA-Z]:|/)' \
  | tr '\\' '/' \
  | sed -E 's|^.*/src/|src/|; s| \[game[^]]*\]||' \
  | sort -u
