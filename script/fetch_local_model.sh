#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# This file is maintained in this repository, not loaded from a download.
source "$project_root/config/local-stt-model.env"
model_dir="${RAVIL_MODEL_CACHE:-$HOME/Library/Caches/Ravil/Models}"
model_path="$model_dir/$RAVIL_MODEL_FILENAME"

verify_model() {
  local actual
  actual="$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')"
  [[ "$actual" == "$RAVIL_MODEL_SHA256" ]]
}

if [[ -f "$model_path" ]] && verify_model "$model_path"; then
  printf 'Verified Ravil model: %s\n' "$model_path"
  exit 0
fi

mkdir -p "$model_dir"
partial="$model_path.download"
trap 'rm -f "$partial"' EXIT
rm -f "$partial"
/usr/bin/curl --fail --location --max-redirs 5 --retry 2 --connect-timeout 15 \
  --output "$partial" "$RAVIL_MODEL_URL"
if ! verify_model "$partial"; then
  printf 'Downloaded model SHA-256 does not match the pinned digest; refusing to install it.\n' >&2
  exit 1
fi
/bin/chmod 0644 "$partial"
/bin/mv -f "$partial" "$model_path"
printf 'Verified Ravil model: %s\n' "$model_path"
