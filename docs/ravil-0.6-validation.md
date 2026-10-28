# Ravil 0.6.0 검증 기록 (2026-09-25)

## 이번에 구현한 범위

- Goodnotes PDF 과목·자료 종류·교사 태그 자동 분류. 확신이 부족한 자료는 `분류 확인 필요`로 남기며 임의의 `기타 과목`으로 합치지 않는다.
- Drive 중간고사 폴더의 하위 폴더를 재귀 탐색하고, 이미 관찰한 수정판은 다시 내려받지 않으며, 새 PDF는 기존 판본을 지우지 않고 수입하는 동기화 엔진. 원본 Drive 파일은 수정하지 않는다.
- 설정 화면의 Google Desktop OAuth 연결(PKCE S256, 127.0.0.1 콜백, 새로고침 토큰은 macOS 키체인)과 앱이 켜져 있는 동안 15분 간격의 자동 확인. 실계정 연결은 아래와 같이 아직 미검증이다.
- PDF 쪽과 OCR 인식문을 함께 보고 보정문을 별도로 저장하는 검토 화면. 원본 OCR과 PDF는 보존한다.
- PDF 쪽 범위를 출처로 저장하는 시험 범위·퀴즈 화면. 첫 순회는 미학습 카드를 우선하고 1분/4분 재알림을 사용하지 않는다. PDF 새 판본이 오면 구판 카드는 평가 대상에서 제외하고, 새 범위는 사용자 확인 후 재지정한다.
- Ravil 안의 Codex 패널. 기존 Codex App Server/ChatGPT 계정으로 연결하며 API 키는 만들거나 읽지 않는다. 모델 목록에서 사용 가능한 모델을 선택한다. 대화는 이 패널에서 세션 한정이며 PDF는 자동 첨부하지 않는다.

## 통과한 검사

- `swift build -c debug`
- `.build/debug/Ravil --goodnotes-import-check`: 동일 파일·개정판·이름 변경·원본 보존·자동 분류·OCR 승인 및 검색
- `.build/debug/Ravil --goodnotes-sync-check`: 모의 Drive 소스로 하위 폴더 탐색·변경 없는 파일 건너뛰기·v2 보존·이름 변경·잘못된 경로 거부
- `.build/debug/Ravil --google-oauth-loopback-check`: 127.0.0.1 전용 OAuth 콜백과 잘못된 `state` 거부
- `.build/debug/Ravil --google-drive-http-check`: 모의 HTTP 응답으로 폴더 검증·Bearer 헤더·페이지네이션·PDF 다운로드
- `.build/debug/Ravil --study-check`: 시험 범위·출처 쪽·첫 순회·오답 우선·구판 배제·새 판본 범위 재지정
- `.build/debug/Ravil --smoke-test`: DB·녹음·전사·Alt 동기화·PDF
- `npm test`: 16개 테스트 통과
- 살아 있는 DB의 사본에서 25개 Goodnotes PDF 재수입 미리보기: 새 판본 0개, 동일 25개, 분류 검토 2개. 살아 있는 DB에 시험 범위 테이블을 강제로 만들지는 않았다.
- Codex App Server 초기화·계정 조회·모델 목록 조회·한 번의 짧은 실제 응답 수신.
- `dist/Ravil-0.6.0-arm64.dmg`를 읽기 전용으로 마운트한 뒤 내부 `Ravil.app`의 0.6.0 버전, `codesign --verify --deep --strict`, Google OAuth·Drive HTTP 계약 검사, 헤드리스 기본 검사를 통과했다. 이후 연결 해제 중 동기화 취소 처리만 보완해 동일 검사를 다시 빌드·DMG 검증 단계에서 반복했다. 최종 DMG SHA-256: `8f8e8005b295cfb8916279c0c2657a054974dd0d22a957b3980e265bbe94b4d7`.

## 발생한 오류와 처리

- Codex 연결의 첫 실제 응답 시험은 로컬 기본값 `gpt-6-luna`가 ChatGPT 계정용 App Server에서 지원되지 않아 HTTP 400으로 실패했다. App Server의 `model/list`에 나온 사용 가능한 모델을 명시적으로 전달하도록 수정한 뒤 짧은 응답 시험을 통과했다.
- Goodnotes 가져오기 테스트에서 손상된 PDF를 의도적으로 거부할 때 CoreGraphics가 PDF 오류 한 줄을 출력했다. 테스트는 예상된 실패 후 DB 롤백과 기존 판본 보존을 확인했다.

## 미검증 / 차단됨

- **화면 사용 경로 미검증:** Ravil 0.5.0의 설치 앱에서 과목 → PDF → v1/v2 → 변경 쪽 → OCR 검색을 끝까지 조작하지 못했다. 화면 도구가 `failedToCreateImageDestination (-10005)`로 반복 실패했고 우회 조작은 하지 않았다. 0.6.0 화면 역시 아직 시각·실사용 검증되지 않았다.
- **Google 실계정 자동 갱신 차단됨:** 이 Mac에 Google Drive 데스크톱 동기화 폴더가 없고, Ravil 전용 Google Cloud OAuth Desktop 클라이언트가 없다. 앱의 연결·주기 확인 코드는 존재하지만 OAuth 승인부터 실제 Drive 변경 탐지까지는 한 번도 실행하지 않았다. 새 파일까지 자동 발견하기 위해 앱은 Google의 제한 범위인 `drive.readonly`를 요청하도록 구현했으며, 설정 화면에 전체 Drive 읽기 권한과 선택 폴더만 탐색한다는 차이를 명시했다. 사용자 권한 선택과 OAuth 클라이언트 설정이 필요하다. Codex의 연결된 Drive 세션 자격 증명을 Ravil에 복사하지 않는다.
- **Codex 화면 미검증:** App Server 왕복은 실제 계정으로 통과했으나 패널의 렌더링·키보드 사용·장시간 스트리밍은 설치 앱에서 검증하지 못했다.
- **공식 배포 신뢰 미검증:** DMG를 마운트해 번들 서명과 헤드리스 실행을 검사했지만 서명은 ad-hoc이며, `spctl --assess`는 예상대로 `rejected`였다. Apple Developer ID 서명·공증·일반 사용자 설치는 검증되지 않았다.

## 다음에 필요한 사용자 경로 확인

1. 설치한 0.6.0 앱에서 과목 → PDF → 판본 전환 → 변경 쪽 → OCR 검색·승인을 확인한다.
2. 시험 범위를 만들고, 출처 쪽에서 퀴즈 카드를 저장·평가한다. 새 PDF가 들어온 경우 범위를 다시 지정하고 구판 카드가 출제되지 않는지 확인한다.
3. Google 앱 연결용 OAuth 클라이언트를 정한 뒤 실계정의 `-Midterm Exam-` 폴더로 첫 동기화·두 번째 무변경 동기화·변경 판본 동기화를 확인한다.
