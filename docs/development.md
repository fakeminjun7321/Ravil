# Ravil 개발 환경

제품 목표는 [개인용 세컨드 브레인](product-goal.md), 구현 순서는 [공식 로드맵](canonical-roadmap.md)을 따른다. 과목·시험 예시는 기존 학습 기능의 검사 자료로 유지한다.

## 개인 작업 공간 검사

```sh
npm test
npm --prefix apps/cloud test
npm --prefix apps/cloud run check
cd apps/website
./node_modules/.bin/tsx --test test/*.test.ts
npm run check
npm run build
```

AI 계약은 `apps/website/src/workspace/second-brain.ts`에서 공유한다. `POST /api/ai/analyze`는 `recordID`, 선택 `question`(최대 2,000자), `mode`(`organize` 또는 `question`)를 받는다. 결과에는 요약·주제·제안, 관련 기록, 질문 답변과 근거 ID, 제공한 출처 목록·원문 입력 해시가 포함된다. 주제·프로젝트로 연결되거나 질문과 일치한 관련 기록만 제한된 문맥으로 전달한다.

웹은 `store.saveAnalysis(record, result)`로 `payload.aiAnalysis`에 결과를 저장하고 수동 태그를 유지한다. 원문·연결이 바뀌면 기존 결과는 `stale: true`로 보관한다. 서버도 동기화 시 같은 무효화 기준을 적용한다. `getRecordAnalysis(payload)`는 현재 유효한 결과만 반환한다. 검색은 원문·수동 태그·주제·프로젝트·현재 AI 요약과 태그를 사용한다.

웹과 AI 서버는 이 응답 계약을 함께 사용하는 버전으로 배포해야 한다. 이전 서버의 입력 해시 없는 응답은 원문 변경과 혼동하지 않고 업데이트가 필요한 연결로 안내한다. 배포 전 두 구성요소의 실제 연결과 구버전 클라이언트 사용 범위를 확인한다.

실제 로컬 D1·R2·인증을 사용하는 검사는 격리된 Wrangler `--local` 설정에서 실행한다. 모델 호출을 검사하지 않는 로컬 설정에는 AI 바인딩을 넣지 않는다.

```sh
node apps/cloud/test/api-flow.ts http://127.0.0.1:8896
node apps/cloud/test/local-second-brain-flow.ts http://127.0.0.1:8896
```

가입 제한을 피하려고 운영 제한을 바꾸지 않는다. 여러 검사를 합칠 때는 두 번째 명령의 세 번째 인자로 합성 계정 fixture JSON(`base`, `email`, `otherEmail`, `password`) 경로를 전달해 기존 로컬 계정으로 로그인한다. fixture는 Git 밖에 권한 0600으로 보관한다. 429가 나오면 해당 실행을 중단하고 원인을 확인한다.

AI 계약 검사는 테스트 대체 모델을 사용한다. 실제 모델 품질, Codex·로컬 모델 연결과 물리 기기 사용은 별도 검증 대상이다.

Mac 계획 파서는 `script/check_workspace_plan.swift`로 앱 UI 없이 검사할 수 있다. `WorkspaceModels.swift`와 함께 임시 위치에 컴파일해 실행한다. 일상·프로젝트 행동, Markdown 제목·체크박스의 본문 추출, 날짜·반복 횟수와 기존 할 일 ID를 확인하며 앱의 전체 사용자 경로 검증을 대신하지 않는다.

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
