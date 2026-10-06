#!/usr/bin/env bash
# Headless smoke test of the client code (see tools/smoke/README.md).
#
#   bash tools/smoke/run.sh                 # both device profiles, full report
#   bash tools/smoke/run.sh --list          # ...plus the PlayerGui tree
#   bash tools/smoke/run.sh --fixture validation
#   bash tools/smoke/run.sh --help
#
# First run downloads Lune (https://github.com/lune-org/lune, latest release)
# and Roblox's API dump into tools/.lune/ (git-ignored). Delete that folder
# to update both. Pin a Lune version with LUNE_VERSION=0.10.5.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE="$ROOT/tools/.lune"
LUNE="$CACHE/lune"
API_DUMP="$CACHE/API-Dump.json"
API_DUMP_URL="https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/API-Dump.json"
FALLBACK_LUNE_VERSION="0.10.5"

mkdir -p "$CACHE"

platform() {
	local os arch
	case "$(uname -s)" in
		Linux) os=linux ;;
		Darwin) os=macos ;;
		*) echo "smoke: unsupported OS $(uname -s)" >&2; exit 2 ;;
	esac
	case "$(uname -m)" in
		x86_64 | amd64) arch=x86_64 ;;
		arm64 | aarch64) arch=aarch64 ;;
		*) echo "smoke: unsupported CPU $(uname -m)" >&2; exit 2 ;;
	esac
	echo "$os-$arch"
}

unpack() { # zip, dest dir
	if command -v unzip >/dev/null 2>&1; then
		unzip -q -o "$1" -d "$2"
	else
		python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"
	fi
}

install_lune() {
	local plat versions version url tmp
	plat="$(platform)"
	if [ -n "${LUNE_VERSION:-}" ]; then
		versions="$LUNE_VERSION"
	else
		# Newest release tags first (git works where the GitHub API may not).
		versions="$(git ls-remote --tags --refs https://github.com/lune-org/lune 2>/dev/null \
			| sed -n 's#.*refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' \
			| sort -t. -k1,1nr -k2,2nr -k3,3nr | head -n 3)"
		versions="${versions:-$FALLBACK_LUNE_VERSION}"
	fi
	tmp="$(mktemp -d)"
	for version in $versions; do
		url="https://github.com/lune-org/lune/releases/download/v$version/lune-$version-$plat.zip"
		echo "smoke: downloading Lune $version ($plat)..." >&2
		if curl -fsSL --retry 2 -o "$tmp/lune.zip" "$url"; then
			mkdir -p "$tmp/x"
			unpack "$tmp/lune.zip" "$tmp/x"
			mv "$tmp/x/lune" "$LUNE"
			chmod +x "$LUNE"
			echo "$version" > "$CACHE/lune-version.txt"
			rm -rf "$tmp"
			return 0
		fi
	done
	rm -rf "$tmp"
	echo "smoke: could not download Lune (tried: $versions). Put a lune binary at $LUNE." >&2
	exit 2
}

if [ ! -x "$LUNE" ]; then
	install_lune
fi

if [ ! -s "$API_DUMP" ]; then
	echo "smoke: downloading Roblox's API dump..." >&2
	if ! curl -fsSL --retry 2 -o "$API_DUMP.tmp" "$API_DUMP_URL"; then
		rm -f "$API_DUMP.tmp"
		echo "smoke: could not download $API_DUMP_URL (put a copy at $API_DUMP)" >&2
		exit 2
	fi
	mv "$API_DUMP.tmp" "$API_DUMP"
fi

export SMOKE_CWD="$PWD"
cd "$ROOT"
export SMOKE_ROOT="$ROOT/" SMOKE_API="$API_DUMP" SMOKE_LUNE="$LUNE"
exec "$LUNE" run "$ROOT/tools/smoke/main.luau" "$@"
