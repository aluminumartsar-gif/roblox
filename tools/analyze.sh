#!/usr/bin/env bash
# Static type-check every script in src/ with luau-lsp (installed by aftman).
# Usage: tools/analyze.sh [paths...]   (defaults to src/)
#
# Needs tools/.luau/globalTypes.d.luau (Roblox API types). If missing:
#   curl -sSfL -o tools/.luau/globalTypes.d.luau \
#     https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.None.d.luau
#
# Uses the classic type solver (what Studio's Script Analysis uses), so the
# output matches what you'd see in Studio.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tools/.luau
rojo sourcemap default.project.json --include-non-scripts -o tools/.luau/sourcemap.json >/dev/null
if [ "$#" -eq 0 ]; then set -- src; fi
luau-lsp analyze \
  --defs=tools/.luau/globalTypes.d.luau \
  --sourcemap=tools/.luau/sourcemap.json \
  --no-strict-dm-types \
  --flag:LuauSolverV2=false \
  "$@"
