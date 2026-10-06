#!/usr/bin/env bash
# Preview "screenshots" of every screen without Roblox Studio.
# Runs the client in the smoke harness at a PC and a phone size, dumps the
# GUI tree at each checkpoint (tools/smoke --snapshots), then draws each dump
# in Chromium with the real fonts (tools/preview/render.js). Icons are
# placeholders and the 3D world is a night backdrop: judge layout, colours,
# fonts and wording here, and the final look in Studio.
# Usage: tools/preview/shoot.sh [outdir] [WxH ...]   (default: tools/preview/out, 1920x1080 749x368)
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-tools/preview/out}"
shift || true
SIZES=("$@")
if [ "${#SIZES[@]}" -eq 0 ]; then SIZES=(1920x1080 749x368); fi
mkdir -p "$OUT"
for vp in "${SIZES[@]}"; do
	bash tools/smoke/run.sh --snapshots "$OUT/dumps-$vp" --viewport "$vp" | tail -1
	node tools/preview/render.js "$OUT/dumps-$vp" "$OUT" | grep -E '^(ok|error)' | sed -E 's/ -> .*//'
done
echo "PNGs in $OUT"
