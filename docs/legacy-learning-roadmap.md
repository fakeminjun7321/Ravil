# 과거 학습 앱 로드맵 보관본

2026-10-19 개인용 세컨드 브레인 목표로 전환하기 전의 계획·검증 기록이다.
현재 제품 목표와 순서는 [개발 목표](product-goal.md), [공식 로드맵](canonical-roadmap.md)을 따른다.
아래의 다음 단계·완료 기준은 당시 학습 기능 작업의 범위로 읽는다.

# Ravil canonical roadmap (formerly Lecture OS)

## Product goal

Ravil is developed as a private learning product first, with commercial distribution planned
after the user enters university. Its introduction website is a separate presentation surface,
not the app's synchronization database.

Ravil ends as an independent study application. Recording, transcription, diarization,
lecture intelligence, materials, study views, and Course Memory must run through Ravil-owned
interfaces and data. Alt and Daglo are temporary bootstrap providers, not permanent product
dependencies.

The independent AI runtime, distributable model provenance, and **measured improvement over Alt on
real lectures** are separate requirements. Own-trained weights are a means, not an automatic
requirement; B2's local STT alone does not satisfy the product-quality target. See
[Ravil independent AI architecture](ravil-independent-ai-architecture.md). This document is design-only,
not proof that the current Alt-sourced model bundle is commercially distributable.

## Delivery strategy

Development has two waves:

1. Complete and validate the entire learning product using Alt as the temporary recorder/STT source.
2. Replace Alt/Daglo capabilities with Ravil-native recording and STT, then cut over without
   losing the already accumulated Course Memory.

This intentionally changes the implementation order from the original handoff. Recorder and STT
remain required final capabilities, but are deferred until after the Alt-backed learning loop works.

## Wave A — Alt-backed product validation

| Phase | Scope | Current status |
|---|---|---|
| A0 | Real Alt pilot: audio, transcript, evidence, source jump | Exercised |
| A1 | Foundation: DB, internal IDs, sources, retries, local API | Partial; authentication remains |
| A2 | Alt ingestion and automatic synchronization | Same-Mac DSHS account DB read-only ingestion of 7 folders/18 notes implemented and checked on launch/refresh; continuous background sync and remote/cloud sync remain unverified |
| A3 | Timetable and course classification | Partial; real start-time path remains |
| A4 | Drive / Goodnotes materials | Partial; selected `-Midterm Exam-` 최신 25문서/1,254쪽과 총 27개 판본을 로컬 Ravil DB에 보존. 같은 파일 2개의 실제 v1→v2와 변경 페이지 그림 비교, OCR 148쪽(미검토) 확인. 앱 내 Google 로그인/자동 감시, 전체 필기 정확도, 최종 화면 사용자 경로는 미검증 또는 미구현 |
| A5 | Lecture Intelligence | Partial; deterministic candidates work, semantic validation remains |
| A6 | Study View with source jumps | Partial in Ravil 0.3 Alt-style shell; folder/lecture window navigation observed on Mac, final 0.3 slide PDF UI and source-jump end-to-end path not verified |
| A7 | Course Memory, cross-lecture search, Q&A, exam-preparation mode | Not implemented |

Wave A exit criterion:

> A student can use Alt for capture/transcription, while Lecture OS automatically organizes a real
> semester and provides evidence-backed review and exam preparation without manual filing.

## Wave B — independent application replacement

| Phase | Scope | Current status |
|---|---|---|
| B1 | Native Recorder: one tap, chunks, background, screen lock, crash/network recovery | Local WAV capture plus imported audio implemented; long-session, system-audio, and device paths unverified |
| B2 | Native STT layer: replaceable provider interface, timestamps, speakers, retry, benchmark | Alt Whisper model/engine bundled with language, translation, and prompt options; provider layer, diarization, and reliability remain |
| B3 | Migration and cutover: native capture→STT→Course Memory, legacy Alt import, dependency removal | Not implemented |

Wave B exit criterion:

> A real class is recorded and processed end to end using Lecture OS alone. Alt and Daglo are not
> required for new lectures, while historical Alt data remains available.

## Total roadmap

- Wave A: 8 phases, A0–A7.
- Wave B: 3 phases, B1–B3.
- Total: 11 phases.

These 11 phases are the **historical app roadmap**, not the whole commercial-product scope.
The independent AI model work in the linked design, Mac/iPhone/iPad/Watch sync, and the introduction
website are additional workstreams. B2's local STT path is not a substitute for a source-grounded
local summary/quiz model, independently documented model rights, or matched Alt/Ravil evaluation.

The next implementation work is to exercise and finish A6 Study View, then build A7 Course
Memory. The basic native recording and local STT paths in Ravil 0.1 do not yet satisfy the
reliability and independence criteria of B1–B3.

The user's wider target also includes synchronization across Mac, iPhone, iPad, and Apple Watch.
That multi-device architecture and its platform clients remain a separate future track and are not
included in the 11 implementation phases above or in the first Mac DMG. Its exact sequence should
be fixed before calling the final personal app complete.

## 2026-09-25 권장 작업 순서 (기존 단계의 세부 순서, 완료 선언 아님)

사용자가 고른 Codex 연결은 **Ravil 안에서 VS Code 확장처럼 쓰는 경험**이다. 향후 Ravil이
Codex App Server의 클라이언트가 되어 로그인·대화·스트리밍·승인과 선택한 학습자료 문맥을
제공한다. 사용자가 Codex에 Ravil 검색 도구를 붙이는 방식은 기본안이 아니다. 사용자는
Codex 구현을 관련 기능과 함께 나중에 한 번에 진행하도록 명시했다. 현재 연결이나 로그인이
구현됐다는 뜻이 아니다.

| 순서 | 권장 작업 | 완료 판단 기준 |
|---|---|---|
| 0 | Ravil 0.4.0 실제 사용 경로 검증 | 설치한 DMG에서 자료 화면·과목 표기·스캔 PDF·텍스트 PDF·슬라이드 노트를 연다. 빌드와 DB 검사만으로 화면 동작이 증명되지는 않는다. |
| 1 | Goodnotes 중간고사 폴더 증분 수집 | 새 Drive 판본/교체 ID를 감지하고 이전 PDF를 보존한다. 새 페이지·변경 판본을 보여 주고 경로 중복은 검토 대상으로 남긴다. 현재 23개 수입은 1회 스냅샷이다. |
| 2 | 기기 내 OCR과 검색 색인 | 이미지형 국어·물리 PDF의 대표 페이지로 인식률을 측정하고 원본 이미지·인식 신뢰도를 보존한다. 현재 5개 PDF는 추출 텍스트가 거의 없으며 그중 2개는 빈 템플릿이다. 필기 인식 품질은 별도 검증한다. |
| 3 | 출처가 연결된 시험 범위·퀴즈 | 시험 범위를 명시하고 과목·선생님·단원으로 좁힌다. 몇 분 뒤 재출제보다 범위 첫 순회를 우선하며 답마다 현재 PDF 판본·페이지나 전사 시점을 연결한다. 퀴즈 저장 구조는 아직 없다. |
| 4 | 기기 간 동기화와 복구 | 자료 ID와 학습 상태가 안정된 뒤 Mac/iPhone/iPad/Watch의 데이터 범위를 정한다. 큰 PDF보다 메모·카드·진도를 먼저 동기화하고 오프라인·충돌·복구를 검증한다. CloudKit/iCloud Documents는 후보이지 확정 인프라가 아니다. |
| 이후 | Codex App Server 연결을 하나의 기능으로 구현 | 로그인, 선택 자료 문맥, 대화 스트리밍, 승인, 한도·오류 처리, 개인정보 검증을 함께 진행한다. 그전에는 Codex 호출이나 결제를 추가하지 않는다. |

기술 참고: [Codex App Server](https://learn.chatgpt.com/docs/app-server),
[Apple Vision 문자 인식](https://developer.apple.com/documentation/vision/recognizing-text-in-images),
[Apple CloudKit](https://developer.apple.com/documentation/cloudkit),
[Apple iCloud 데이터 선택](https://developer.apple.com/documentation/cloudkit/deciding-whether-cloudkit-is-right-for-your-app).

## Compatibility note

Existing filenames and npm commands such as `phase1:*` through `phase5:*` are historical internal
labels. New planning and completion reports use the Wave A / Wave B identifiers above.
