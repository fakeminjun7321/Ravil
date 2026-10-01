#!/usr/bin/env bash
set -euo pipefail

# Google FLEURS Korean is CC BY 4.0. Retain attribution and source revision.
# These archives contain public read speech for an experiment, not Ravil user data.
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${RAVIL_FLEURS_DIR:-$project_root/tmp/model-dev/fleurs-ko}"
revision=70bb2e84b976b7e960aa89f1c648e09c59f894dd
root="https://huggingface.co/datasets/google/fleurs/resolve/$revision/data/ko_kr"
mkdir -p "$output_dir"

fetch() {
  local name="$1" expected="$2" url="$3" target="$output_dir/$1" partial
  partial="$target.download"
  if [[ -f "$target" && "$(/usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{print $1}')" == "$expected" ]]; then
    printf 'Verified %s\n' "$name"
    return
  fi
  rm -f "$partial"
  /usr/bin/curl --fail --location --max-redirs 5 --retry 2 --connect-timeout 15 \
    --output "$partial" "$url"
  if [[ "$(/usr/bin/shasum -a 256 "$partial" | /usr/bin/awk '{print $1}')" != "$expected" ]]; then
    rm -f "$partial"
    printf 'FLEURS SHA-256 mismatch: %s\n' "$name" >&2
    exit 1
  fi
  /bin/mv -f "$partial" "$target"
  printf 'Verified %s\n' "$name"
}

fetch dev.tar.gz 496edcb5323e75b4a2830f5b5623684a0baf86d3728101853fd4fe503372157c "$root/audio/dev.tar.gz"
fetch dev.tsv 6b236de107c6a1672233f6d710d26adfdb55570a3e6e35aca9dc4ff2be01cea4 "$root/dev.tsv"
fetch test.tar.gz 3489e529f2aad18d3357b746c5f955941d258b79dc60d8a102d5bced2a223184 "$root/audio/test.tar.gz"
fetch test.tsv cf2f7c8765f6203e3c46ef620d5e936d3f331b6e8865455557777dd1347517f5 "$root/test.tsv"
