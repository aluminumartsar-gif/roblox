#!/usr/bin/env bash
# Prints "<StudioPath> len=<n> sum=<n> weighted=<n>" for every script in src/.
# Run the matching Luau snippet in Studio (tools/checksum.luau) and diff the
# two outputs: identical output means the repo and Studio are byte-identical.
set -euo pipefail
cd "$(dirname "$0")/.."

studio_path() {
  local f="$1" rel
  case "$f" in
    src/shared/*) rel="ReplicatedStorage.Shared.${f#src/shared/}" ;;
    src/server/*) rel="ServerScriptService.Server.${f#src/server/}" ;;
    src/client/*) rel="StarterPlayer.StarterPlayerScripts.Client.${f#src/client/}" ;;
  esac
  rel="${rel%.luau}"; rel="${rel%.server}"; rel="${rel%.client}"
  echo "${rel//\//.}"
}

find src -name '*.luau' | sort | while read -r f; do
  p="$(studio_path "$f")"
  od -An -v -tu1 "$f" | awk -v p="$p" '{for(i=1;i<=NF;i++){n++; s+=$i; w=(w+n*$i)%4294967296}} END{printf "%s len=%d sum=%d weighted=%d\n", p, n, s, w}'
done
