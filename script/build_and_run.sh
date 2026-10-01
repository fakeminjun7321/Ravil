#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${RAVIL_APP_BUNDLE:-$PROJECT_ROOT/dist/Ravil.app}"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_RESOURCES="$APP_BUNDLE/Contents/Resources"
source "$PROJECT_ROOT/config/local-stt-model.env"
MODEL_SOURCE="${RAVIL_MODEL_SOURCE:-${RAVIL_MODEL_CACHE:-$HOME/Library/Caches/Ravil/Models}/$RAVIL_MODEL_FILENAME}"
MODEL_DEST="$APP_RESOURCES/Models/$RAVIL_MODEL_FILENAME"
WHISPER_BIN="$APP_RESOURCES/Whisper/bin"
WHISPER_LIB="$APP_RESOURCES/Whisper/lib"
WHISPER_BACKENDS="$APP_RESOURCES/Whisper/backends"
WHISPER_LICENSES="$APP_RESOURCES/Whisper/licenses"
RUNTIME_SOURCE="${RAVIL_WHISPER_RUNTIME_DIR:-}"

if [[ ! -f "$MODEL_SOURCE" ]]; then
  printf 'Ravil local Whisper model not found: %s\nRun script/fetch_local_model.sh first.\n' "$MODEL_SOURCE" >&2
  exit 1
fi
model_hash="$(/usr/bin/shasum -a 256 "$MODEL_SOURCE" | /usr/bin/awk '{print $1}')"
if [[ "$model_hash" != "$RAVIL_MODEL_SHA256" ]]; then
  printf 'Ravil local Whisper model does not match the pinned SHA-256: %s\n' "$MODEL_SOURCE" >&2
  exit 1
fi
if [[ -n "$RUNTIME_SOURCE" ]]; then
  for required in .ravil-runtime-package whisper-cli libwhisper.1.dylib libggml.0.dylib \
                  libggml-base.0.dylib libggml-metal.so libggml-blas.so libggml-cpu.so \
                  ggml-silero-v6.2.0.bin whisper-cpp-LICENSE silero-vad-LICENSE vad-source.env; do
    if [[ ! -f "$RUNTIME_SOURCE/$required" ]]; then
      printf 'Independent Whisper runtime is incomplete: %s\n' "$required" >&2
      exit 1
    fi
  done
elif [[ ! -x /opt/homebrew/bin/whisper-cli ]]; then
  printf 'Required local whisper-cli not found: /opt/homebrew/bin/whisper-cli\n' >&2
  exit 1
fi

cd "$PROJECT_ROOT"
SWIFT_BUILD_ARGS=(-c release)
if [[ -n "${RAVIL_SWIFT_SDK:-}" ]]; then
  SWIFT_BUILD_ARGS+=(--sdk "$RAVIL_SWIFT_SDK")
fi
swift build "${SWIFT_BUILD_ARGS[@]}"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
/usr/bin/ditto "$PROJECT_ROOT/.build/release/Ravil" "$APP_MACOS/Ravil"
/usr/bin/ditto "$PROJECT_ROOT/apps/macos/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
chmod 755 "$APP_MACOS/Ravil"

# A desktop OAuth client ID is public app configuration, never a user token.
if [[ -n "${RAVIL_GOOGLE_CLIENT_ID:-}" ]]; then
  if [[ ! "$RAVIL_GOOGLE_CLIENT_ID" =~ ^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$ ]]; then
    printf 'RAVIL_GOOGLE_CLIENT_ID is not a valid desktop OAuth client ID\n' >&2
    exit 1
  fi
  /usr/bin/plutil -replace RavilGoogleClientID -string "$RAVIL_GOOGLE_CLIENT_ID" "$APP_BUNDLE/Contents/Info.plist"
fi

# Optional private Desktop OAuth JSON is supplied at packaging time. Never print
# its contents or commit it. Only installed-app (not web-server) credentials qualify.
GOOGLE_CLIENT_JSON="${RAVIL_GOOGLE_CLIENT_JSON:-$HOME/Library/Application Support/Ravil/GoogleOAuth/desktop-client.json}"
if [[ "${RAVIL_SKIP_GOOGLE_OAUTH:-0}" != 1 && -n "${RAVIL_GOOGLE_CLIENT_JSON:-}" && ! -f "$GOOGLE_CLIENT_JSON" ]]; then
  printf 'Desktop OAuth configuration file does not exist\n' >&2
  exit 1
fi
if [[ "${RAVIL_SKIP_GOOGLE_OAUTH:-0}" != 1 && -f "$GOOGLE_CLIENT_JSON" ]]; then
  python3 - "$GOOGLE_CLIENT_JSON" "$APP_BUNDLE/Contents/Info.plist" <<'PY_OAUTH'
import json, pathlib, plistlib, re, sys
try:
    client = json.loads(pathlib.Path(sys.argv[1]).read_text()).get('installed', {})
    target = pathlib.Path(sys.argv[2])
    info = plistlib.loads(target.read_bytes())
    identifier = client.get('client_id', '')
    secret = client.get('client_secret', '')
    if not isinstance(identifier, str) or not re.fullmatch(r'[A-Za-z0-9_-]+\.apps\.googleusercontent\.com', identifier):
        raise ValueError()
    if identifier != info.get('RavilGoogleClientID') or not isinstance(secret, str) or not secret.strip():
        raise ValueError()
    info['RavilGoogleClientSecret'] = secret
    target.write_bytes(plistlib.dumps(info, sort_keys=False))
except Exception:
    raise SystemExit('Desktop OAuth JSON is invalid or does not match the configured client ID')
print('Desktop OAuth configuration packaged; values withheld')
PY_OAUTH
fi

# Package the independently sourced, digest-verified model. No notes or audio enter the bundle.
mkdir -p "$(dirname "$MODEL_DEST")"
/usr/bin/ditto "$MODEL_SOURCE" "$MODEL_DEST"
dest_hash="$(/usr/bin/shasum -a 256 "$MODEL_DEST" | /usr/bin/awk '{print $1}')"
if [[ "$dest_hash" != "$RAVIL_MODEL_SHA256" ]]; then
  printf 'Bundled Whisper model does not match the pinned SHA-256\n' >&2
  exit 1
fi
/usr/bin/ditto "$PROJECT_ROOT/config/local-stt-model.env" "$APP_RESOURCES/Models/source.env"
/usr/bin/ditto "$PROJECT_ROOT/config/whisper-model-LICENSE" "$APP_RESOURCES/Models/LICENSE"
/usr/bin/ditto "$PROJECT_ROOT/config/local-stt-MODEL_CARD.md" "$APP_RESOURCES/Models/MODEL_CARD.md"

# The source-built runtime keeps all dynamic backends beside the executable and
# has no compiled-in Homebrew backend search path.
if [[ -n "$RUNTIME_SOURCE" ]]; then
  if [[ -d "$APP_RESOURCES/Whisper" ]]; then /bin/rm -R "$APP_RESOURCES/Whisper"; fi
  /usr/bin/ditto "$RUNTIME_SOURCE" "$WHISPER_BIN"
  source "$PROJECT_ROOT/config/local-vad-model.env"
  vad_hash="$(/usr/bin/shasum -a 256 "$WHISPER_BIN/$RAVIL_VAD_FILENAME" | /usr/bin/awk '{print $1}')"
  if [[ "$vad_hash" != "$RAVIL_VAD_SHA256" ]]; then
    printf 'Bundled VAD model does not match the pinned SHA-256\n' >&2
    exit 1
  fi
  for binary in "$WHISPER_BIN/whisper-cli" "$WHISPER_BIN"/*.dylib "$WHISPER_BIN"/*.so; do
    /usr/bin/codesign --verify "$binary"
    if /usr/bin/otool -L "$binary" | /usr/bin/tail -n +2 | rg -q '/opt/homebrew/|/tmp/'; then
      printf 'Independent runtime still links outside its bundle: %s\n' "$binary" >&2
      exit 1
    fi
  done
  printf 'Bundled pinned source-built Whisper runtime and Silero VAD\n'
else
mkdir -p "$WHISPER_BIN" "$WHISPER_LIB" "$WHISPER_BACKENDS" "$WHISPER_LICENSES"
# Keep the local engine inside the bundle so transcription does not depend on Homebrew at runtime.
/bin/cp -L /opt/homebrew/bin/whisper-cli "$WHISPER_BIN/whisper-cli"
/bin/cp -L /opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib "$WHISPER_LIB/libwhisper.1.dylib"
/bin/cp -L /opt/homebrew/opt/ggml/lib/libggml.0.dylib "$WHISPER_LIB/libggml.0.dylib"
/bin/cp -L /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib "$WHISPER_LIB/libggml-base.0.dylib"
/bin/cp -L /opt/homebrew/opt/libomp/lib/libomp.dylib "$WHISPER_LIB/libomp.dylib"
for backend in blas cpu-apple_m1 cpu-apple_m2_m3 cpu-apple_m4 metal; do
  backend_source="/opt/homebrew/opt/ggml/libexec/libggml-${backend}.so"
  if [[ ! -f "$backend_source" ]]; then
    printf 'Required ggml backend not found: %s\n' "$backend_source" >&2
    exit 1
  fi
  /bin/cp -L "$backend_source" "$WHISPER_BACKENDS/libggml-${backend}.so"
done
/bin/cp -L /opt/homebrew/opt/whisper-cpp/LICENSE "$WHISPER_LICENSES/whisper-cpp-LICENSE"
/bin/cp -L /opt/homebrew/opt/ggml/LICENSE "$WHISPER_LICENSES/ggml-LICENSE"
/bin/cp -L /opt/homebrew/opt/libomp/LICENSE.TXT "$WHISPER_LICENSES/libomp-LICENSE.TXT"
chmod 755 "$WHISPER_BIN/whisper-cli" "$WHISPER_LIB"/*.dylib "$WHISPER_BACKENDS"/*.so

/usr/bin/install_name_tool -change /opt/homebrew/opt/ggml/lib/libggml.0.dylib @rpath/libggml.0.dylib \
  -change /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib @rpath/libggml-base.0.dylib \
  "$WHISPER_BIN/whisper-cli"
/usr/bin/install_name_tool -id @rpath/libwhisper.1.dylib \
  -change /opt/homebrew/opt/ggml/lib/libggml.0.dylib @rpath/libggml.0.dylib \
  -change /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib @rpath/libggml-base.0.dylib \
  "$WHISPER_LIB/libwhisper.1.dylib"
/usr/bin/install_name_tool -id @rpath/libggml.0.dylib "$WHISPER_LIB/libggml.0.dylib"
/usr/bin/install_name_tool -id @rpath/libggml-base.0.dylib \
  -change /opt/homebrew/opt/libomp/lib/libomp.dylib @rpath/libomp.dylib \
  "$WHISPER_LIB/libggml-base.0.dylib"
/usr/bin/install_name_tool -id @rpath/libomp.dylib "$WHISPER_LIB/libomp.dylib"

for backend in "$WHISPER_BACKENDS"/*.so; do
  if /usr/bin/otool -L "$backend" | rg -q '/opt/homebrew/opt/libomp/lib/libomp.dylib'; then
    /usr/bin/install_name_tool -change /opt/homebrew/opt/libomp/lib/libomp.dylib @rpath/libomp.dylib "$backend"
  fi
done

for binary in "$WHISPER_BIN/whisper-cli" "$WHISPER_LIB"/*.dylib "$WHISPER_BACKENDS"/*.so; do
  if /usr/bin/otool -L "$binary" | rg -q '/opt/homebrew/'; then
    printf 'Whisper binary still links to Homebrew: %s\n' "$binary" >&2
    exit 1
  fi
  /usr/bin/codesign --force --sign - "$binary"
done
fi
printf 'Bundled Ravil Whisper model SHA-256: %s\n' "$dest_hash"

ICONSET="$(dirname "$APP_BUNDLE")/Ravil.iconset"
mkdir -p "$ICONSET"
swift "$PROJECT_ROOT/script/make_icon.swift" "$ICONSET/icon_512x512@2x.png"
for SIZE in 16 32 128 256 512; do
  /usr/bin/sips -z "$SIZE" "$SIZE" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  /usr/bin/sips -z "$DOUBLE" "$DOUBLE" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP_RESOURCES/Ravil.icns"
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"

case "$MODE" in
  --build|build)
    printf 'Built %s\n' "$APP_BUNDLE"
    ;;
  --verify|verify)
    "$APP_MACOS/Ravil" --smoke-test
    ;;
  run)
    if pgrep -x Ravil >/dev/null; then
      printf 'Ravil is already running. Close it before using the Run action.\n' >&2
      exit 1
    fi
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_MACOS/Ravil"
    ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "Ravil"'
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.minjun.ravil"'
    ;;
  *)
    printf 'usage: %s [run|--build|--verify|--debug|--logs|--telemetry]\n' "$0" >&2
    exit 2
    ;;
esac
