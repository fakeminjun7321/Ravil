#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [--replace]\n' "$0" >&2
  printf 'Package the existing signed dist/Ravil.app; --replace replaces an existing DMG.\n' >&2
}

replace=false
case "${1:-}" in
  '') ;;
  --replace) replace=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="${RAVIL_APP_BUNDLE:-$project_root/dist/Ravil.app}"
app_executable="$app_bundle/Contents/MacOS/Ravil"
app_plist="$app_bundle/Contents/Info.plist"

if [[ ! -d "$app_bundle" || ! -f "$app_plist" || ! -x "$app_executable" ]]; then
  printf 'Missing or incomplete app bundle: %s\n' "$app_bundle" >&2
  exit 1
fi

# An old bundle can still be installed locally, but cannot be repackaged without
# the exact model notices and digest that belong to this source revision.
source "$project_root/config/local-stt-model.env"
model_dir="$app_bundle/Contents/Resources/Models"
for notice in MODEL_CARD.md LICENSE source.env; do
  if [[ ! -f "$model_dir/$notice" ]]; then
    printf 'Missing model attribution in app bundle: %s\n' "$notice" >&2
    exit 1
  fi
done
if ! /usr/bin/cmp -s "$project_root/config/local-stt-MODEL_CARD.md" "$model_dir/MODEL_CARD.md" \
    || ! /usr/bin/cmp -s "$project_root/config/whisper-model-LICENSE" "$model_dir/LICENSE" \
    || ! /usr/bin/cmp -s "$project_root/config/local-stt-model.env" "$model_dir/source.env"; then
  printf 'Bundled model attribution differs from this source revision\n' >&2
  exit 1
fi
model_file="$model_dir/$RAVIL_MODEL_FILENAME"
if [[ ! -f "$model_file" || "$(/usr/bin/shasum -a 256 "$model_file" | /usr/bin/awk '{print $1}')" != "$RAVIL_MODEL_SHA256" ]]; then
  printf 'Bundled model is missing or differs from the published digest\n' >&2
  exit 1
fi

runtime_dir="$app_bundle/Contents/Resources/Whisper/bin"
if [[ -f "$runtime_dir/ggml-silero-v6.2.0.bin" ]]; then
  source "$project_root/config/local-vad-model.env"
  for notice in vad-source.env silero-vad-LICENSE whisper-cpp-LICENSE whisper-cpp-revision.txt; do
    if [[ ! -f "$runtime_dir/$notice" ]]; then
      printf 'Missing source-built runtime attribution: %s\n' "$notice" >&2
      exit 1
    fi
  done
  if ! /usr/bin/cmp -s "$project_root/config/local-vad-model.env" "$runtime_dir/vad-source.env" \
      || ! /usr/bin/cmp -s "$project_root/config/silero-vad-LICENSE" "$runtime_dir/silero-vad-LICENSE" \
      || [[ "$(cat "$runtime_dir/whisper-cpp-revision.txt")" != '6e4ab854f67f743900934a703d5603419384c961' ]] \
      || [[ "$(/usr/bin/shasum -a 256 "$runtime_dir/$RAVIL_VAD_FILENAME" | /usr/bin/awk '{print $1}')" != "$RAVIL_VAD_SHA256" ]]; then
    printf 'Bundled source runtime attribution or VAD digest does not match\n' >&2
    exit 1
  fi
  for binary in "$runtime_dir/whisper-cli" "$runtime_dir"/*.dylib "$runtime_dir"/*.so; do
    if /usr/bin/otool -L "$binary" | /usr/bin/tail -n +2 | rg -q '/opt/homebrew/|/tmp/'; then
      printf 'Bundled source runtime links outside its app: %s\n' "$binary" >&2
      exit 1
    fi
  done
fi

bundle_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app_plist")"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_plist")"
bundle_arch="$(/usr/bin/lipo -archs "$app_executable")"
if [[ "$bundle_name" != 'Ravil' || ! "$bundle_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "$bundle_arch" != 'arm64' ]]; then
  printf 'Unexpected bundle metadata: name=%s version=%s architecture=%s\n' \
    "$bundle_name" "$bundle_version" "$bundle_arch" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict "$app_bundle"

image_name="Ravil-${bundle_version}-${bundle_arch}.dmg"
output_image="$project_root/dist/$image_name"
if [[ -e "$output_image" && "$replace" != true ]]; then
  printf 'DMG already exists: %s (pass --replace to replace it)\n' "$output_image" >&2
  exit 1
fi

umask 077
stage_root="$(/usr/bin/mktemp -d -t ravil-dmg.XXXXXX)"
cleanup() {
  if [[ -n "${stage_root:-}" && -d "$stage_root" ]]; then
    /bin/rm -R "$stage_root"
  fi
}
trap cleanup EXIT

stage_content="$stage_root/content"
/bin/mkdir "$stage_content"
/usr/bin/ditto "$app_bundle" "$stage_content/Ravil.app"
/bin/ln -s /Applications "$stage_content/Applications"
/usr/bin/codesign --verify --deep --strict "$stage_content/Ravil.app"

staged_image="$stage_root/$image_name"
/usr/bin/hdiutil create -quiet -volname Ravil -srcfolder "$stage_content" \
  -fs HFS+ -format UDZO "$staged_image"
/usr/bin/hdiutil verify -quiet "$staged_image"

if [[ "$replace" == true ]]; then
  /bin/mv -f "$staged_image" "$output_image"
else
  /bin/mv -n "$staged_image" "$output_image"
fi
if [[ ! -f "$output_image" ]]; then
  printf 'DMG was not placed at %s\n' "$output_image" >&2
  exit 1
fi
/bin/chmod 0644 "$output_image"
/usr/bin/hdiutil verify -quiet "$output_image"
/usr/bin/shasum -a 256 "$output_image"
