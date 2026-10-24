#!/bin/bash
# Downloads the tools pinned in Scripts/tools.lock into a folder, refusing any
# file whose SHA-256 differs from the pin. Downloads are cached, and a cached
# file is checked again before use.
#
#   ./Scripts/fetch-tools.sh <destination-folder> [cache-folder]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${PROSLIDE_TOOLS_LOCK:-$ROOT/Scripts/tools.lock}"  # the override is for testing this script
DEST="${1:?usage: fetch-tools.sh <destination-folder> [cache-folder]}"
CACHE="${2:-$ROOT/build/tools-cache}"

die() { echo "error: $*" >&2; exit 1; }

sha256() {
    if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1
    else sha256sum "$1" | cut -d' ' -f1
    fi
}

[ -f "$LOCK" ] || die "$LOCK not found"
mkdir -p "$DEST" "$CACHE"

while read -r name version kind expected url <&3; do
    case "${name:-}" in ''|'#'*) continue ;; esac
    [ -n "${url:-}" ] || die "malformed line in tools.lock for '$name'"

    cached="$CACHE/$name-$version"
    if [ -f "$cached" ] && [ "$(sha256 "$cached")" = "$expected" ]; then
        echo "Using cached $name $version"
    else
        echo "Downloading $name $version"
        rm -f "$cached" "$cached.part"
        curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 -o "$cached.part" "$url"
        actual="$(sha256 "$cached.part")"
        if [ "$actual" != "$expected" ]; then
            rm -f "$cached.part"
            die "checksum mismatch for $name $version
  expected $expected
  got      $actual
  from     $url"
        fi
        mv "$cached.part" "$cached"
    fi

    case "$kind" in
        file) cp "$cached" "$DEST/$name" ;;
        zip)  unzip -o -q -j "$cached" "$name" -d "$DEST" ;;
        *)    die "unknown kind '$kind' for $name in tools.lock" ;;
    esac
    chmod 755 "$DEST/$name"
done 3< "$LOCK"
