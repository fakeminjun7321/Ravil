# Ravil 0.6.1 검증 기록 (2026-09-25)

## 실제 자료 반영

- Google Drive `-Midterm Exam-` 폴더를 읽기 전용으로 대조했다. 같은 이름의 `Astronomy` 폴더가 두 개이며, 전체 PDF는 26개였다. 기존 Ravil DB에는 Drive 파일 ID 25개가 기록돼 있었다.
- 새 파일 `Astronomy/이영훈_01_천체의운동1.pdf`(61쪽, 25,113,867바이트)를 수입 전에 DB 사본에서 미리 확인했다. `천문`으로 분류됐고 자료 종류는 확인 대상으로 남았다.
- 수입 전 DB 백업: `/Users/minjun/Library/Application Support/Ravil/Backups/ravil-before-new-astronomy-20260925.sqlite` (`integrity_check=ok`, 문서 25개, 판본 27개).
- 원본 Drive PDF는 바꾸지 않았다. 수입 후 DB는 문서 26개, PDF 판본 28개, 분류 확인 3개, `integrity_check=ok`였다. 동일 파일 재수입 미리보기에서 새 판본 0개를 확인했다.
- 기기 내 OCR 첫 쪽만 추가로 처리했다. OCR 전 DB 백업: `/Users/minjun/Library/Application Support/Ravil/Backups/ravil-before-new-astronomy-ocr-20260925.sqlite`. 첫 쪽에서 1,118자, 평균 신뢰도 0.57을 얻었고 `좌표계` 검색 가능한 데이터가 저장됐다. 나머지 60쪽은 아직 처리하지 않았다.

## 이번 코드 보완

- 자료 상세 화면에서 선택한 최신 Goodnotes PDF에 한해 OCR 시작·중단·진행 상태를 제공한다. 5쪽씩 백그라운드 처리하며 화면을 떠나면 취소한다.
- OCR 검색 결과에 쪽 번호를 보존하고 해당 PDF 쪽으로 이동하도록 연결했다.
- 자료 분류 확인 화면에서 과목·자료 종류·교사/작성자를 수정할 수 있다. 수동 분류는 새 백업이 들어와도 자동 분류에 덮어써지지 않는다.
- 동명 Drive 폴더에서 동일 상대 경로가 생기면 자료를 조용히 합치지 않고 수입을 중단하는 테스트를 추가했다.

## 검증 범위

- `swift build -c debug`, Goodnotes 가져오기·자동 동기화·시험 범위·Google OAuth 로컬 콜백·Drive HTTP 모의 응답·기본 검사와 Node 테스트 16개 통과.
- `dist/Ravil-0.6.1-arm64.dmg`를 읽기 전용 마운트하여 내부 앱 버전 0.6.1, `codesign --verify --deep --strict`, Goodnotes 검사와 기본 실행 파일 검사를 통과했다. SHA-256: `d6408dda4597ad0b254d5278c3900a513360bd5cda486ea2c1d8579d559edf0f`.
- 실제 Ravil 0.6.1 앱의 화면 조작은 **미검증**이다. 화면 도구가 다시 `failedToCreateImageDestination (-10005)`를 반환해 우회 조작을 하지 않았다. 실행 중인 별도 `dist/Ravil.app`는 0.3.0이며 종료·교체하지 않았다.
- Ravil 전용 Google OAuth Desktop 클라이언트와 `drive.readonly` 권한 선택이 없어 앱 자체의 실계정 자동 갱신은 **미검증**이다. 이번 Drive 대조와 새 파일 수입은 연결된 Drive 도구를 이용한 수동 작업이며 앱 자동 갱신의 성공 증거가 아니다.
- DMG는 로컬 검사용 ad-hoc 서명이다. `codesign`은 통과했지만 `spctl --assess`는 `rejected`였다. Apple Developer ID 공증 배포·일반 사용자 설치 검증은 별개로 남아 있다.
