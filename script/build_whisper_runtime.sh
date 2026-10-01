#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
revision=6e4ab854f67f743900934a703d5603419384c961
source_dir="${RAVIL_WHISPER_SOURCE_DIR:-$project_root/tmp/whisper-runtime/source}"
build_dir="${RAVIL_WHISPER_BUILD_DIR:-$project_root/tmp/whisper-runtime/build}"
output_dir="${RAVIL_WHISPER_RUNTIME_DIR:-$project_root/tmp/whisper-runtime/package}"
source "$project_root/config/local-vad-model.env"
vad_source="${RAVIL_VAD_SOURCE:-${RAVIL_VAD_CACHE:-$HOME/Library/Caches/Ravil/Models}/$RAVIL_VAD_FILENAME}"

if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$(dirname "$source_dir")"
  /usr/bin/git clone --filter=blob:none --no-checkout https://github.com/ggml-org/whisper.cpp.git "$source_dir"
  /usr/bin/git -C "$source_dir" fetch --depth 1 origin "$revision"
  /usr/bin/git -C "$source_dir" checkout --detach FETCH_HEAD
fi
if [[ "$(/usr/bin/git -C "$source_dir" rev-parse HEAD)" != "$revision" ]]; then
  printf 'whisper.cpp source is not the pinned revision: %s\n' "$source_dir" >&2
  exit 1
fi

cmake_bin="${RAVIL_CMAKE:-}"
if [[ -z "$cmake_bin" ]]; then
  cmake_bin="$(command -v cmake || true)"
fi
if [[ -z "$cmake_bin" && -x "$project_root/tmp/model-opt/venv/bin/cmake" ]]; then
  cmake_bin="$project_root/tmp/model-opt/venv/bin/cmake"
fi
if [[ -z "$cmake_bin" || ! -x "$cmake_bin" ]]; then
  printf 'CMake is required to build the pinned whisper.cpp runtime.\n' >&2
  exit 1
fi
if [[ ! -f "$vad_source" || "$(/usr/bin/shasum -a 256 "$vad_source" | /usr/bin/awk '{print $1}')" != "$RAVIL_VAD_SHA256" ]]; then
  printf 'Verified Ravil VAD model missing. Run script/fetch_local_vad.sh first.\n' >&2
  exit 1
fi

"$cmake_bin" -S "$source_dir" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_BACKEND_DIR= \
  -DGGML_METAL=ON -DGGML_BLAS=ON -DGGML_NATIVE=OFF -DWHISPER_COREML=OFF
"$cmake_bin" --build "$build_dir" --target whisper-cli ggml-metal ggml-blas ggml-cpu -j 4

if [[ -d "$output_dir" ]]; then
  if [[ ! -f "$output_dir/.ravil-runtime-package" ]]; then
    printf 'Refusing to replace an unknown runtime directory: %s\n' "$output_dir" >&2
    exit 1
  fi
  /bin/rm -R "$output_dir"
fi
mkdir -p "$output_dir"
touch "$output_dir/.ravil-runtime-package"
for name in whisper-cli libwhisper.1.dylib libggml.0.dylib libggml-base.0.dylib \
            libggml-metal.so libggml-blas.so libggml-cpu.so; do
  /bin/cp -L "$build_dir/bin/$name" "$output_dir/$name"
done
/bin/cp "$vad_source" "$output_dir/$RAVIL_VAD_FILENAME"
/bin/cp "$project_root/config/local-vad-model.env" "$output_dir/vad-source.env"
/bin/cp "$project_root/config/silero-vad-LICENSE" "$output_dir/silero-vad-LICENSE"
/bin/cp "$source_dir/LICENSE" "$output_dir/whisper-cpp-LICENSE"

for binary in "$output_dir/whisper-cli" "$output_dir"/*.dylib "$output_dir"/*.so; do
  if /usr/bin/otool -l "$binary" | /usr/bin/grep -Fq "path $build_dir/bin"; then
    /usr/bin/install_name_tool -rpath "$build_dir/bin" @loader_path "$binary"
  fi
  if /usr/bin/otool -L "$binary" | /usr/bin/tail -n +2 | rg -q '/opt/homebrew/|/tmp/model-opt/|/tmp/whisper-runtime/'; then
    printf 'Runtime still links outside its bundle: %s\n' "$binary" >&2
    exit 1
  fi
  /usr/bin/codesign --force --sign - "$binary"
done
printf '%s\n' "$revision" > "$output_dir/whisper-cpp-revision.txt"
printf 'Packaged independent whisper.cpp runtime: %s\n' "$output_dir"
