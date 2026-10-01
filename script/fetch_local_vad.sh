#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/config/local-vad-model.env"
model_dir="${RAVIL_VAD_CACHE:-$HOME/Library/Caches/Ravil/Models}"
model_path="$model_dir/$RAVIL_VAD_FILENAME"
if [[ -f "$model_path" && "$(/usr/bin/shasum -a 256 "$model_path" | /usr/bin/awk '{print $1}')" == "$RAVIL_VAD_SHA256" ]]; then
  printf 'Verified Ravil VAD model: %s\n' "$model_path"
  exit 0
fi
mkdir -p "$model_dir"
partial="$model_path.download"
trap 'rm -f "$partial"' EXIT
/usr/bin/curl --fail --location --max-redirs 5 --retry 2 --connect-timeout 15 \
  --output "$partial" "$RAVIL_VAD_URL"
if [[ "$(/usr/bin/shasum -a 256 "$partial" | /usr/bin/awk '{print $1}')" != "$RAVIL_VAD_SHA256" ]]; then
  printf 'Downloaded VAD model SHA-256 mismatch\n' >&2
  exit 1
fi
/bin/chmod 0644 "$partial"
/bin/mv -f "$partial" "$model_path"
printf 'Verified Ravil VAD model: %s\n' "$model_path"
