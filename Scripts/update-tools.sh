#!/bin/bash
# Prints tools.lock lines for the newest stable releases of the download tools.
# It changes no file: compare the lines with each project's release page, then
# update tools.lock in a pull request. The checksums come from the same hosts as
# the downloads, so a second look at the release pages is the point of review.
set -euo pipefail

fetch() { curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$@"; }
json() { python3 -I -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }

yt_tag="$(fetch https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest | json tag_name)"
yt_sha="$(fetch "https://github.com/yt-dlp/yt-dlp/releases/download/$yt_tag/SHA2-256SUMS" | awk '$2 == "yt-dlp_macos.zip" { print $1 }')"

deno_tag="$(fetch https://api.github.com/repos/denoland/deno/releases/latest | json tag_name)"
deno_asset="deno-aarch64-apple-darwin.zip"
deno_url="https://github.com/denoland/deno/releases/download/$deno_tag/$deno_asset"
deno_sha="$(fetch "$deno_url.sha256sum" | awk '{ print $1 }')"

# Not `fetch`: this one must stop at the redirect and read where it points.
ff_url="$(curl --silent --show-error --proto '=https' --tlsv1.2 --output /dev/null --write-out '%{redirect_url}' \
    https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip)"
[ -n "$ff_url" ] || { echo "error: could not resolve the latest ffmpeg release" >&2; exit 1; }
ff_version="$(basename "$(dirname "$ff_url")")"; ff_version="${ff_version#*_}"
ff_sha="$(fetch "$ff_url.sha256" | awk '{ print $1 }')"

for value in "$yt_tag" "$yt_sha" "$deno_tag" "$deno_sha" "$ff_version" "$ff_sha"; do
    [ -n "$value" ] || { echo "error: a lookup came back empty; nothing printed" >&2; exit 1; }
done

printf '%-9s %-11s %-5s %s  %s\n' \
    yt-dlp "$yt_tag" dir "$yt_sha" "https://github.com/yt-dlp/yt-dlp/releases/download/$yt_tag/yt-dlp_macos.zip" \
    ffmpeg "$ff_version" zip "$ff_sha" "$ff_url" \
    deno "${deno_tag#v}" zip "$deno_sha" "$deno_url"
