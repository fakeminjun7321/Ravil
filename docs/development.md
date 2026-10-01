# Ravil 개발 환경

## 소스 검사

- Node.js 24 이상: 내장 TypeScript 및 SQLite 기능을 사용하는 로컬 실험 코드.
- macOS와 Swift/Command Line Tools: `Package.swift`의 `Ravil` 실행 대상.

```sh
npm test
swift build
```

macOS 27 SDK에서 `SwiftUIMacros.StateMacro` 문제가 발생한 개발 환경은 설치된 macOS 26.5 SDK로 우회했습니다. 해당 SDK가 실제로 있는 환경에서만 사용하세요.

```sh
swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
```

SwiftPM test target 대신 앱의 임시 DB 기반 `--smoke-test`와 여러 전용 검사 모드를 사용합니다. 빌드 성공은 GUI·마이크·외부 계정 동작의 성공을 증명하지 않습니다.

## 개발용 앱 번들

Apple Silicon 개발 환경에서 Homebrew `whisper-cpp`와 관련 GGML 런타임이 필요합니다. 정확한 검사 목록은 `script/build_and_run.sh`를 확인하세요. 기본 모델은 공개 원본의 고정 리비전에서 별도로 받습니다.

```sh
bash script/fetch_local_model.sh
RAVIL_SKIP_GOOGLE_OAUTH=1 bash script/build_and_run.sh --build
```

생성 위치는 `dist/Ravil.app`입니다. 기본 빌드는 로컬 개발용 ad-hoc 서명이며 Developer ID 공증 설치판이 아닙니다. 기존 실행 앱 교체·실행은 별도 작업입니다.

독립 소스 빌드 런타임을 사용하는 실험 경로는 `script/build_whisper_runtime.sh`와 `RAVIL_WHISPER_RUNTIME_DIR`로 제공합니다. 모델 파일과 원본 런타임은 저장소에 넣지 않습니다.

## Google Drive

OAuth 사용자 토큰은 Keychain에서 관리합니다. `Info.plist`의 Desktop OAuth client ID는 공개 앱 식별자이며 사용자 토큰이 아닙니다. 빌드 시 `RAVIL_GOOGLE_CLIENT_ID`로 자신의 구성을 지정할 수 있습니다. 필요한 Desktop OAuth JSON은 `RAVIL_GOOGLE_CLIENT_JSON`으로 로컬 파일 경로를 전달합니다. 비밀값·사용자 토큰·실제 계정 JSON을 Git에 추가하지 마세요. Drive 실계정 검증 여부는 상태 문서와 구분합니다.

## ASR 연구 코드

macOS Apple Silicon용 MLX 실험 의존성은 `config/model-opt-requirements.txt`, PyTorch 추가 학습 의존성은 `config/model-dev-requirements.txt`에 있습니다. 별도의 Python 3.12 가상환경에 설치합니다. 모델 가중치·데이터는 모델 카드의 리비전과 해시를 확인해 별도로 준비해야 하며 자동 검사만 실행하는 데 모두 필요하지는 않습니다.

비공개 수업 데이터로 수행한 실험은 이 저장소만으로 재현되지 않습니다. 코드와 공개 가능한 집계 결과만 포함하고, 원본 음성·전사·학습 가중치는 로컬에 보관합니다.
