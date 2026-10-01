# Ravil

강의 기록과 학습자료를 과목별로 모으고, 출처를 따라 찾아보며 복습하는 macOS 학습 앱입니다.

현재는 **개발·검증 중인 제품의 소스 저장소**입니다. 소스 업로드가 일반 사용자용 설치판 출시를 뜻하지는 않습니다.

현재 우선순위는 **Mac에서의 성능과 안정성**입니다. AI 자동 복습과 iPad·iPhone 앱 공개는 후순위이며, 기기 확장은 PWA부터 검토합니다. [Mac 우선 개발 범위](docs/mac-first-roadmap.md)를 참고하세요.

## 구성

- **Mac 앱:** PDF·판본 관리, 기기 내 OCR, 강의 기록, 녹음·로컬 전사, 검색과 시험 범위.
- **공통 패키지:** 로컬 DB, 기존 Alt 기록 가져오기, 동기화·분류·학습자료 처리.
- **Ravil-ASMR 실험:** 공개 모델을 기반으로 한 한국어·영어 전사 최적화와 추가 학습 실험. 앱 기본 전사 경로와 별도로 검증합니다.

```
apps/macos/    SwiftUI macOS 앱
apps/api/      로컬 API 실험
packages/      DB·가져오기·동기화·분류·자료 처리
src/           초기 가져오기·분석 도구
script/        빌드·포장·모델 다운로드·평가·학습 도구
config/        공개 설정 예제와 모델 출처·라이선스 기록
test/          Node 및 Python 검사
docs/          개발 환경·검증 상태·모델 실험 기록
```

## 개발과 검사

Node.js 24 이상과 macOS용 Swift 도구가 필요합니다.

```sh
npm test
swift build
```

앱 번들, 로컬 전사 모델, Google OAuth 설정과 SDK 문제는 [개발 환경 안내](docs/development.md)를 참고하세요. 녹음·PDF·전사·DB·모델 가중치·OAuth 비밀값은 저장소에 포함하지 않습니다.

## 현재 상태

[첫 소스 업로드의 검증 범위](docs/repository-status.md)를 확인하세요. 빌드·자동 검사와 실제 녹음→전사→저장→재열기 검증을 구분합니다. 설치 앱의 모든 기능, 다중 기기 동기화, 공증 배포와 일반 사용자 설치는 완료된 것으로 표시하지 않습니다.

ASR 상세 기록:

- [0.4 긴 녹음 처리](docs/ravil-asmr-0.4-development.md)
- [0.5 효율 비교](docs/ravil-asmr-0.5-development.md)
- [0.6 추가 학습 파일럿](docs/ravil-asmr-0.6-training-pilot.md)
- [모델·연구 및 실행 환경 조사](docs/asr-research-2026-10-01.md)

## 라이선스와 출처

Ravil 자체 코드의 외부 이용·배포 라이선스는 아직 결정하지 않았습니다. 이 저장소를 오픈소스 이용 허락으로 해석하지 마세요. 외부 모델·라이브러리의 라이선스는 각각 적용됩니다. [제삼자 구성요소 안내](THIRD_PARTY_NOTICES.md)와 `config/`의 모델 카드를 확인하세요.

Ravil-ASMR은 공개 기반 모델을 활용하는 프로젝트입니다. 기반 모델까지 처음부터 직접 학습했다고 주장하지 않으며, 추가 학습·변환·실행 최적화의 범위를 구분해 기록합니다.
