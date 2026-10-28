# Lecture OS Phase 0 error log

This log separates confirmed implementation mistakes, local-tool failures, and source-data
limitations. Failed runs did not modify Alt's database. No failed local-LLM run produced a final
pilot report.

## E-001 — `exam` matched `example`

- Category: implementation defect
- Observed: the first rule-based pass produced 19 exam candidates, mostly sentences containing
  `example`.
- Confirmed cause: the regular expression matched the substring `exam` without word boundaries.
- Impact: false exam-related evidence.
- Recovery: changed English patterns to word-bounded `exam`, `exams`, `midterm`, and `quiz` forms.
- Verification: the same real lecture dropped from 19 candidates to one; a regression test proves
  that `This is only an example.` is not classified as an exam mention.
- Prevention: include negative lexical fixtures for every short English keyword that may be a
  prefix of a common word.
- Status: resolved and unit-verified.

## E-002 — SQLite segment count was multiplied

- Category: diagnostic-query defect
- Observed: an exploratory SQL query reported 13,363 transcript segments, while the normalized
  adapter reported 1,721.
- Confirmed cause: the query expanded every segment with `json_each` and then summed the parent
  chunk's full segment count once for each expanded segment.
- Impact: the first diagnostic count was incorrect. No stored data was changed.
- Recovery: the adapter parses each chunk once and counts the resulting segment objects directly.
- Verification: the real lecture consistently reports 1,721 normalized segments.
- Prevention: when a JSON array is expanded to one row per item, use `COUNT(*)` or count in the
  normalizer; do not sum the parent array length over expanded rows.
- Status: resolved in the production-facing inspection path.

## E-003 — Module import assumed `process.argv[1]`

- Category: implementation defect
- Observed: importing `alt-adapter.mjs` from `node --input-type=module -e` threw
  `ERR_INVALID_ARG_TYPE` in `pathToFileURL`.
- Confirmed cause: the CLI-entry guard assumed every Node invocation has a script path in
  `process.argv[1]`.
- Impact: programmatic imports from eval/stdin mode failed; the normal CLI and Alt data were not
  affected.
- Recovery: guard `process.argv[1]` before converting it to a file URL.
- Verification: the import-based timestamp query succeeded and all seven tests still pass.
- Prevention: test modules as both direct CLIs and imported libraries.
- Status: resolved and re-verified.

## E-004 — Whole-transcript Ollama request exceeded runtime context

- Category: local-tool configuration failure
- Observed: Ollama rejected a 118,809-token request because the active runtime context was 4,096
  tokens.
- Confirmed cause: the model metadata advertised a larger possible context, but the active runner
  was created with the default 4,096-token context.
- Impact: no local-model analysis result was created.
- Recovery attempted: split the transcript into sequential chunks and explicitly set `num_ctx`.
- Prevention: inspect the active runner context with `ollama ps`; size requests for the active
  context rather than the model-card maximum.
- Status: initial cause resolved, but the replacement pipeline remained unstable (E-005/E-006).

## E-005 — Local-model JSON was truncated

- Category: local-tool output failure
- Observed: a chunk response ended inside a Korean string and failed `JSON.parse` with
  `Unterminated string`.
- Confirmed cause: `num_predict: 1000` stopped generation before the structured response closed.
- Impact: the partial response was discarded and no report file was written.
- Recovery attempted: reduced array sizes, added string-length limits, and increased the output
  allowance.
- Prevention: use checkpointed per-chunk output, validate each JSON object before aggregation, and
  retry only the failed chunk with a bounded output contract.
- Status: not present in the final deterministic report, but the local-LLM pipeline is not ready.

## E-006 — Ollama response hit the client header timeout

- Category: local-tool runtime failure
- Observed: a later chunk failed with `UND_ERR_HEADERS_TIMEOUT` after the first chunk had completed.
- Confirmed fact: Node's fetch client did not receive response headers within its timeout.
- Cause: the immediate mechanism is confirmed; whether model generation time or runner scheduling
  was dominant was not separately measured.
- Impact: in-memory partial analysis was lost; no final file had been written.
- Recovery: stopped repeated attempts after recurring failures and completed the pilot with
  deterministic extraction plus reviewed transcript/audio evidence.
- Prevention: stream or checkpoint each completed chunk, set an explicit request deadline, record
  timing per chunk, and make resume idempotent before using this path again.
- Status: unresolved for the experimental full-transcript local-LLM path.

## E-007 — `light`/`life` scientific-term transcription error

- Category: source/provider limitation
- Observed: around 23:35, parts of the constant-speed-of-light explanation were transcribed as
  `life has a constant speed`.
- Confirmed by: the Alt transcript and an independent local Whisper large-v3-turbo transcription
  of a decoded 32-second source excerpt.
- Impact: an evidence link can point to the correct audio position while its text remains
  semantically wrong.
- Recovery: the reviewed pilot report uses the surrounding audio context to identify the intended
  concept and explicitly records the ambiguity.
- Prevention: inject course vocabulary, cross-check important terms against slides/notes, and
  require audio review for high-priority claims when sources disagree.
- Status: reproducible provider limitation; mitigation identified, not eliminated.

## E-008 — Alt provider summary covered only the introduction

- Category: output-quality limitation
- Observed: the stored Alt summary was 221 characters and described the opening discussion, while
  the transcript later covered relativity examples, differential equations, initial conditions,
  and Euler's method.
- Impact: treating the provider summary as a complete lecture summary would omit most of the
  lecture.
- Recovery: the pilot report was rebuilt from timestamped topic evidence across the recording.
- Prevention: compare summary coverage against temporal transcript windows before accepting it as
  whole-lecture output.
- Status: mitigated in the reviewed pilot; automatic coverage validation is not implemented.

## Recurrence policy

Before the next Alt/local-analysis implementation:

1. Run the seven focused tests.
2. Verify the active model context instead of relying on advertised maximum context.
3. Persist validated chunk results incrementally with an idempotent resume key.
4. Keep generated claims in candidate state until evidence IDs resolve.
5. Sample at least one important scientific term against original audio or a document source.
6. Report provider output, reviewed output, and destination-side persistence as separate states.

Phase 1 implementation and verification notes continue in
[`phase-1-foundation.md`](./phase-1-foundation.md).

## E-009 — WAL database failed with system `sqlite3 -readonly`

- Category: verification-tool incompatibility
- Observed: the final Phase 1 inspection could not open the closed WAL-mode database using the
  system CLI's `-readonly` option.
- Impact: the first read-only verification command produced no integrity result; no write was
  attempted.
- Recovery: opened the closed snapshot with SQLite URI `immutable=1`, then verified integrity,
  foreign keys, counts, raw payload, audio size, and evidence matches.
- Prevention: use application connections that understand WAL for live databases; use immutable
  mode only for a confirmed closed snapshot.
- Status: verification completed; the future concurrent-worker read strategy remains open.

## E-010 — SQLite row prototypes caused a false test failure

- Category: test assertion defect
- Observed: expected and actual sync-run values printed identically, but `deepStrictEqual` failed.
- Confirmed cause: `node:sqlite` rows use a null prototype while the expected fixtures were normal
  object literals.
- Impact: one test failed despite correct synchronization state.
- Recovery: normalize database rows with object spread before structural comparison.
- Prevention: normalize driver-specific row objects at test boundaries.
- Status: resolved; the suite passes 10/10.

## E-011 — Polling watcher ended through the npm Ctrl-C path

- Category: verification-boundary observation
- Observed: the temporary watcher performed repeated successful cycles and then the npm wrapper
  returned exit code 1 after an interactive Ctrl-C.
- Confirmed fact: no watcher process remained, and all observed sync cycles completed successfully.
- Unconfirmed cause: the exit code may come from npm's signal handling rather than the child
  watcher's stop flag; this was not isolated further.
- Impact: watcher synchronization was verified, but graceful zero-code shutdown through npm is not.
- Prevention: add a direct child-process signal test before packaging the watcher as a managed
  background service.
- Status: shutdown semantics not verified; no background process left running.

## E-012 — Live timetable verification used the wrong UTC value

- Category: verification-input defect
- Observed: a test intended to represent Monday 08:35 KST used `2026-09-21T04:35:00Z`, which is
  Monday 13:35 KST. The title indicated `미방`, while the supplied time fell inside `현물`, so the
  classifier correctly refused automatic assignment.
- Confirmed cause: manual UTC conversion error in the verification fixture.
- Impact: the first live-config check did not verify the intended Monday first-period path. The
  real Lecture OS database was not changed because the check used a temporary database.
- Recovery: reran with `2026-09-20T23:35:00Z`, corresponding to Monday 08:35 KST; title and
  timetable both matched `미방` and produced confidence 1.0.
- Prevention: express verification fixtures with explicit local-time comments or generate UTC
  values programmatically from the named timezone instead of mental conversion.
- Status: corrected and re-verified.

## E-013 — Permission command included unresolved WAL globs

- Category: verification-command defect
- Observed: a combined `chmod` included `data/lecture-os.db*`; absent WAL/SHM matches caused the
  command to fail before the timetable file changed, leaving `data/timetable.json` at `0644`.
- Impact: the private timetable briefly retained default owner/group/world-readable mode inside the
  local user directory. It remained Git-ignored and was not uploaded.
- Recovery: targeted the two existing files explicitly and verified both as `0600` with `stat`.
- Prevention: resolve existing targets first and do not combine sensitive permission changes with
  optional unmatched globs.
- Status: resolved and filesystem-verified.

## E-014 — Unicode-normalized filename pattern returned an empty path

- Category: verification-command defect
- Observed: a `find -name '*객체지향*게임*개발.pdf'` lookup returned no result, after which
  `stat`, `shasum`, and `pdfinfo` received an empty path.
- Confirmed cause: the stored filename uses decomposed Korean Unicode while the shell pattern used
  precomposed characters.
- Impact: the first read-only inspection failed; no file was modified.
- Recovery: listed PDFs by extension inside the exact `LEC3` directory and selected the sole PDF by
  directory scope rather than normalized text matching.
- Prevention: avoid literal Korean filename matching when normalization is unknown; enumerate a
  bounded directory and verify the selected path and size before passing it downstream.
- Status: resolved; the selected PDF was hashed, indexed, rendered, and visually verified.

## E-015 — Permission readback raced the permission update

- Category: verification-order defect
- Observed: `drive-manifest.json` appeared as `0644` while its `chmod` command was running in a
  parallel tool branch.
- Confirmed cause: the permission update and `stat` readback were launched concurrently, so the
  readback could observe the pre-update mode.
- Impact: the first readback did not prove the final permission state.
- Recovery: ran permission update and `stat` sequentially against the exact file; final mode is
  `0600`.
- Prevention: never parallelize a state mutation with the readback intended to verify it.
- Status: resolved and sequentially verified.

## E-016 — macOS `chmod` rejected GNU-style `--`

- Category: command portability defect
- Observed: `/bin/chmod 600 -- path` failed with `chmod: --: No such file or directory`.
- Confirmed cause: the macOS system `chmod` used here does not accept that GNU-style separator.
- Impact: that retry did not change permissions.
- Recovery: reran `/bin/chmod 600 <absolute-path>` and verified `0600` immediately.
- Prevention: use commands supported by the host utility version and avoid unnecessary option
  separators for already validated absolute paths.
- Status: resolved.

## E-017 — Temporary PNG cleanup command was rejected

- Category: safety-policy rejection
- Observed: a combined command containing `rm -f` was rejected before execution.
- Impact: the permission update and tests bundled in that same command also did not run; rendered
  PNG intermediates remain organized under `tmp/pdfs/phase4/`.
- Recovery: reran permission and test commands without deletion. No destructive workaround was
  attempted.
- Prevention: keep cleanup separate from verification and use the environment's approved
  recoverable cleanup mechanism.
- Status: verification completed; temporary renders intentionally retained.

## E-018 — Phase 5 multi-file patch had an invalid file boundary

- Category: patch-format defect
- Observed: the first combined Phase 5 patch was rejected because an `Add File` marker appeared
  inside an unfinished update hunk.
- Impact: the patch was rejected before changing any file.
- Recovery: split the change into smaller, file-bounded patches and applied them successfully.
- Prevention: close every update hunk before beginning another file and prefer smaller patches for
  multi-package additions.
- Status: resolved; tests and actual-data generation pass.

## E-009 recurrence — WAL read-only CLI path

- Observation: a Phase 5 concept-quality read again failed with system `sqlite3 -readonly` against
  the WAL database.
- Prevention applied: did not retry the same path; used the previously documented closed-snapshot
  `immutable=1` read.
- Result: the artifact was read successfully without modifying the database.
- Status: recurrence confirmed for that CLI mode; application DB reads remain operational.

## E-019 — Roadmap renumbering omitted Recorder and STT

- Category: requirements-tracking defect
- Observed: after adding the user-requested Alt preliminary phase, the assistant continued using a
  0–7 roadmap and treated Alt automation as a formal replacement phase. The original Recorder and
  STT phases disappeared from later summaries.
- Confirmed cause: the roadmap was rewritten instead of prepending the new phase and shifting the
  original document's phases by one.
- Impact: later work was labelled one phase earlier than its canonical position, and the project
  appeared closer to completion than it is.
- Recovery: established `canonical-roadmap.md` with phases 0–8 and mapped every existing artifact
  to complete, partial, or not implemented status.
- Prevention: preserve source acceptance criteria and maintain an explicit old-to-new phase mapping
  whenever a user inserts a phase.
- Status: superseded by the user's later sequencing clarification; see E-020 and
  `canonical-roadmap.md`.

## E-020 — Roadmap correction placed native replacement too early

- Category: requirements-interpretation defect
- Observed: after restoring the original Recorder/STT phases, the assistant said the next work
  should return to authentication and native Recorder before continuing the learning experience.
- User clarification: the final product must be independent of Alt and Daglo, but the intended
  development order is to finish the complete product loop using Alt first and build the native
  replacement afterward.
- Impact: the previous correction preserved the source document's order but did not preserve the
  user's intended delivery strategy.
- Recovery: replaced the single numbered roadmap with Wave A (Alt-backed full product) and Wave B
  (native Recorder/STT/cutover). Recorder and STT remain mandatory, not deleted.
- Prevention: separate final capability requirements from implementation sequence when a temporary
  provider is explicitly being used to validate the product first.
- Status: corrected in `canonical-roadmap.md`.

## E-021 — Closed Alt WAL database failed on a normal read-only connection

- Category: local integration behavior
- Observed: the packaged Ravil app's Alt refresh failed during SQL preparation with SQLite
  `CANTOPEN (14)`, even though the Alt database existed and passed an immutable snapshot read.
- Confirmed cause: the current closed Alt database remained in WAL journal mode while its
  `-wal`/`-shm` sidecar files were absent. Normal read-only SQLite access could not recreate the
  journal state.
- Recovery: Ravil first tries normal read-only access. Only when it receives `CANTOPEN` and both
  sidecars are absent does it retry a read-only immutable snapshot. If sidecars exist, it reports
  that Alt must finish its current work instead of ignoring uncheckpointed writes.
- Verification: a closed WAL fixture and the current real Alt database both synchronized with no
  new imported lectures and no source-data mutation.
- Status: resolved for the observed closed-database case; active Alt writes remain a separate
  user-path verification.

## E-022 — Offscreen SwiftUI capture did not render the native split view

- Category: visual-verification limitation
- Observed: `ImageRenderer` returned a 1180×760 PNG containing a system placeholder graphic
  rather than the Ravil window content.
- Impact: that PNG cannot support a claim of visual UI quality or layout correctness.
- Recovery: removed the diagnostic command from the app and retained build, background launch,
  process, DB, and packaged-artifact checks as separate evidence.
- Prevention: use a permitted native-window visual check when the user provides foreground-control
  time, or use a proper supported macOS UI test environment.
- Status: visual UI review remains unverified.

## E-023 — Alt visual reference was claimed without opening the app

- Category: verification and communication error
- Observed: Ravil's Alt-inspired UI was built from Alt's public site and local database, and the
  assistant described it as an Alt reference. The user then clarified that they had asked for the
  installed Alt application itself to be opened and inspected.
- Attempted recovery: checked that no other Codex task was controlling the desktop, then called
  Computer Use to select Alt. Initialization failed with `failed to write kernel assets: No such
  file or directory`. A reset and second same-tool attempt failed identically. A read-only process
  check showed Alt had not launched.
- Impact: the installed Alt screen, navigation, recording UI, and note detail remain unobserved.
  The current Ravil layout has not been visually compared against the actual Alt app.
- Prevention: state the source of each design observation explicitly. Before claiming an app UI was
  referenced, inspect that app through the supported Computer Use route and record the exact screen
  and interaction observed. If that route is unavailable, leave visual comparison unverified.
- Status: corrected. A fresh Computer Use session later opened the installed Alt app and inspected
  its home and an existing note's detail. Ravil changes based on those observations are recorded in
  `docs/alt-reference-design.md`. The earlier failed initialization remains a real tool incident.

## E-024 — Blank image crashed a PDFKit smoke fixture

- Category: test-fixture defect
- Observed: `PDFPage(image: NSImage(size:))` raised `NSInvalidArgumentException` because the empty
  image had no backing pixels.
- Impact: the first headless PDF smoke run aborted before testing PDF ingestion; no user file was
  modified.
- Recovery: generated a valid one-page PDF with Core Graphics, verified its page count with
  PDFKit, then exercised local PDF import and duplicate detection successfully.
- Prevention: use a valid PDF fixture with actual page backing, and classify a fixture failure
  separately from an importer failure.
- Status: resolved in the headless smoke path.

## E-025 — Bundled model path failed Swift compilation on first attempt

- Category: implementation error
- Observed: the first compile after adding in-app model and engine lookup failed in
  `AppPaths.swift` because optional chaining made `.flatMap` a call on `URL`, which has no such
  method.
- Impact: the UI agent could compile its `ContentView.swift` work but could not complete the
  full app build at that point; no user data or Alt files changed.
- Recovery: replaced the expression with an explicit `guard let` for the bundle resource URL and
  a file-existence check. The final release build, app signature, bundled-model transcription,
  and mounted-DMG transcription all passed.
- Prevention: compile the changed path-resolution code before packaging and validate the path from
  the packaged executable, not only from the SwiftPM development binary.
- Status: resolved.

## E-026 — Self-check mislabelled bundled paths as external

- Category: diagnostic and communication error
- Observed: a read-only mounted DMG contained the copied model and engine and passed a real
  transcription, but `--self-check` reported `modelSource=external` and `engineSource=external`.
  The assistant initially told the user that old saved preferences might be overriding the
  bundle, without evidence for that cause.
- Confirmed scope: the two default preference keys did not exist, and the app-bundle check after
  comparing filesystem paths reported both sources as `bundled`. The incorrect values came from
  comparing `URL` objects rather than their `.path` values in the self-check report; the real
  transcription check already used the bundled resources.
- Impact: verification output and the interim explanation were misleading. The model copy and
  Alt originals were not changed by this error.
- Recovery: compare paths in the diagnostic, rebuild and re-run the packaged-app self-check.
- Prevention: validate a diagnostic's source classification against the resolved path and the
  actual operation before attributing it to user settings.
- Status: resolved. The final rebuilt DMG reported both sources as `bundled` and passed the
  mounted-app transcription check.

## E-027 — UI code review found misleading or incomplete navigation paths

- Category: UX implementation defects
- Observed: search results kept the search overlay visible after selecting a hit; switching from
  a playing lecture to one without audio could leave the prior audio playing; a first transcript
  jump could be missed before its dock mounted. A home PDF import could silently use the materials
  screen's previous course picker, and a summary called same-course PDFs “linked” to one lecture.
  A note-search target could also be replaced on entry by an unsaved recovery draft.
- Impact: the interface could appear unresponsive, play audio for the wrong selection, or imply
  evidence of a lecture-to-material link that the data does not contain.
- Recovery: clear search when opening a result, stop old playback on lecture changes, scroll after
  the transcript dock mounts, pass an explicit course selection to PDF import, label same-course
  materials accurately, and prioritize an explicit note-search target while leaving the recovery
  action visible.
- Verification: the release Swift build passes. These specific interactions were not exercised in
  the foreground app and remain visually/user-path unverified.
- Status: code corrected; interactive verification remains open.

## E-028 — Alt settings navigation returned to a different home state

- Category: desktop inspection anomaly
- Observed: during read-only inspection of Alt 0.12.0, clicking the visible sidebar settings control
  dismissed the plugin marketplace and showed the home with a different, older-dated note list.
- Impact: settings internals were not inspected. No note, recording, or setting value was edited,
  and the unexpected state was not reversed.
- Cause: unknown. The visible result could be an app navigation/state refresh; there is not enough
  evidence to identify why that click changed the displayed library.
- Recovery: stopped further Alt UI interaction and continued with read-only bundle and Ravil-code
  inspection.
- Prevention: after a native-app action, inspect the fresh accessibility state; if the app changes
  to an unexpected library or destination, stop and do not try to restore the previous screen.
- Status: contained; the cause and settings UI remain unverified.

## E-029 — Audio import rejected the UTType initializer as a function reference

- Category: implementation/compile error
- Observed: while adding an audio-file picker, the first version used
  `compactMap(UTType.init(filenameExtension:))`; Swift could not resolve that initializer as a
  function value at the call site.
- Impact: the interim release build failed before producing the updated app. No audio file or Alt
  data was changed.
- Recovery: use the explicit closure `compactMap { UTType(filenameExtension: $0) }`. The subsequent
  full release build completed and produced the 0.2.0 app bundle.
- Prevention: prefer an explicit closure when a Swift initializer has optional or overloaded
  parameters, then compile the affected target before packaging.
- Status: resolved in the 0.2.0 source and build.

## E-030 — Course grouping result type was ambiguous in Swift

- Category: implementation/compile error
- Observed: after adding the user's corrected subject-group list and an `기타 과목` remainder group,
  the release build could not infer `compactMap`'s result type in `SubjectCourseGroup.make`.
- Impact: the first build for the corrected course mapping stopped before packaging; no database rows
  or source course IDs were changed.
- Recovery: annotate the compact-map closure/result as `[SubjectCourseGroup]` and flatten course ID
  sets with an explicit closure. The next release build completed and the separate 0.2.3 DMG was made.
- Prevention: give optional-producing `compactMap` closures an explicit result type when their `nil`
  branch and inferred collection type are not enough for Swift.
- Status: resolved in 0.2.3.

## E-031 — Alt 계정 폴더를 잘못된 DB와 계층으로 해석

- 분류: 요구 해석·데이터 소스·UI 결함.
- 관찰: Ravil 화면에 모든 과목 폴더 수가 0으로 보였고 `수 I`·`독서` 같은 시간표 과목이 자식 폴더처럼 나타났다. `기타 과목`도 사용자가 원하지 않았는데 만들었다.
- 확인된 원인: 첫 수입은 Alt의 개인 기본 `lecture_notes.db`(7월 노트 2건)만 읽었다. 실제 DSHS 워크스페이스의 폴더 7개와 노트 18건은 `powersync-store.account-*.db`에 있었으며, 그 폴더들은 모두 최상위다. 시간표 과목 ID는 Alt 폴더 계층이 아니다.
- 영향: 사용자가 요청한 Alt 유사성과 실제 저장 내용이 반영되지 않았다. 원본 Alt 파일은 변경하지 않았다.
- 수정: DSHS 계정 DB에서 폴더·노트 메타데이터를 읽기 전용으로 확인하고 Ravil 자체 DB에 수입한다. 폴더 UI는 사용자가 정한 9개 상위 항목만 보여 주고, `기타 과목`과 시간표 기반 자식 폴더를 제거한다. Alt에 없는 물실·프실에는 원본 수를 꾸며 표시하지 않는다.
- 검증: 계정 DB의 폴더 7개/노트 18개와 Ravil 수입 18건을 임시 DB 검사로 대조했다. 실제 Ravil 창에서 폴더 수, 현물 4건, 미방 2건, 빈 일물 화면을 확인했다. 모든 Alt 기능의 동등성까지 검증한 것은 아니다.
- 상태: 이 폴더/수입 결함은 수정·위 범위에서 검증. 나머지 Alt 기능 격차는 별도 추적.

## E-032 — 슬라이드 노트가 녹음 강의처럼 보임

- 분류: 실제 화면에서 발견한 UX·데이터 수입 결함.
- 관찰: Alt의 미방 슬라이드 노트를 Ravil에서 열면 PDF 내용 대신 `전사 · 0개 구간`과 `전사 결과가 아직 없습니다`가 나타났다.
- 확인된 범위: Alt 계정 DB의 해당 노트는 `type=slide`, `note_components.component_type=slides`이고 원본 PDF 파일 경로와 추출 텍스트가 있다. 이 둘을 기존 수입 경로가 활용하지 않았다.
- 영향: 슬라이드 노트의 본문을 Ravil에서 볼 수 없고 빈 전사로 잘못 이해하기 쉽다.
- 수정: Alt 슬라이드 컴포넌트의 PDF 경로·추출 텍스트를 Ravil 자체 DB로 가져오고, 슬라이드 상세에서는 읽기 전용 PDF 미리보기(파일이 없으면 텍스트)를 보여 주도록 했다. 전사 도크는 숨긴다.
- 검증: 전체 Swift 릴리스 빌드, 합성 DB의 최초·반복·수정·삭제 수입 테스트, 실제 Alt 계정 DB의 임시 수입(18건 중 슬라이드 1건), 새 실행 파일 smoke test가 통과했다. PDF 파일 존재와 비어 있지 않은 추출 텍스트를 확인했다. 최종 앱의 **실제 화면은 CUA 오류로 미검증**이다.
- 상태: 코드/데이터 경로 수정·단위 검증; 0.3.0 사용자 화면 검증은 열려 있다.

## E-033 — 이번 진단 명령의 범위 착오

- 분류: 읽기 전용 진단 명령 오류; 제품 데이터 손상 없음.
- 관찰: 백업 SQLite 파일을 일반 `-readonly`로 검사하자 WAL 관련 접근 오류가 나왔으나, 백업을 변경하지 않는 `immutable=1` URI로 다시 검사해 `PRAGMA integrity_check = ok`를 확인했다. Alt 슬라이드 조회 첫 쿼리에서는 실제 열 이름 `type` 대신 `note_type`, 다음 쿼리에서는 없는 `size_bytes` 열을 사용해 SQL 준비 오류가 났다. CUA의 첫 빈 폴더 클릭도 숫자 대신 객체를 전달해 인자 오류가 났다.
- 복구: `PRAGMA table_info`와 최신 접근성 상태를 다시 읽은 뒤 올바른 열/요소 인자로 재조회했다. 클릭 실패 시에는 화면 변화가 없음을 확인한 후 한 번만 재시도했다.
- 영향: 해당 실패들은 조회·검증 단계에 한정된다. Alt 원본, Ravil 노트, 사용자 입력은 변경되지 않았다.
- 상태: 재조회 성공. 백업 무결성 `ok`, Alt 슬라이드의 PDF 경로/추출 텍스트 확인, 빈 일물 폴더 화면 확인.

## E-034 — 최종 슬라이드 UI 검증 중 화면 도구 캡처 실패

- 분류: 검증 도구 장애.
- 관찰: 이전 Ravil 앱에서 슬라이드 노트를 선택한 뒤 최종 코드 빌드를 준비하려고 화면을 다시 읽었으나 Computer Use가 `failedToCreateImageDestination`(-10005)를 반환했다. 읽기 전용 전체 상태에서는 Ravil이 실행 중임을 확인했지만, 같은 화면 조회가 다시 같은 오류로 끝났다.
- 대응: 직접 화면 조작을 중단했고 AppleScript·전역 키 입력·다른 UI 제어 도구로 우회하지 않았다. 실행 중인 `dist/Ravil.app`을 덮어쓰지 않고 별도 `dist/Ravil-0.3.0.app`을 빌드해 DMG를 만들었다.
- 영향: 소스 빌드, 임시 DB 검사, 번들 서명, DMG 무결성은 확인했지만 새 앱의 슬라이드 상세 표시와 DMG 설치 후 사용자 경로는 **미검증**이다.
- 상태: 화면 도구 복구 또는 사용자 주도 설치/실행 시 후속 검증 필요. 원인 미확인.

2026-09-25 후속 관찰: Ravil 0.5.0의 실제 화면 검증에서도 `cua.getApp("Ravil")`가 동일한
`failedToCreateImageDestination`(-10005)를 반환했다. 읽기 전용 앱 목록에서 Ravil 실행 상태만
확인하고 다시 화면 조작을 중단했다. 코드·DB·DMG의 헤드리스 검사를 실제 화면 검증으로
대체해 보고하지 않는다.

## E-035 — 병렬 검사 중 Alt 메타데이터 SQLite 잠금

- 분류: 간헐적 로컬 DB 읽기 실패.
- 관찰: 새 번들에서 Alt 폴더 검사와 `--self-check` 등을 병렬 실행했을 때 `--self-check` 한 번이 `Alt 폴더 메타데이터를 읽을 수 없습니다: database is locked`로 종료됐다.
- 범위: Alt 원본 DB는 읽기 전용으로 열었으며 수정하지 않았다. 직후 원본 `PRAGMA quick_check`는 `ok`, 순차 `--self-check`도 DSHS 폴더 7개/노트 18개와 번들 모델·엔진을 정상 보고했다. 정확한 잠금 보유 프로세스는 확인되지 않았다.
- 수정: Alt 메타데이터·노트 읽기 연결에 최대 1.5초 SQLite busy timeout을 설정했다. 무한 재시도나 원본 DB 복구/변경은 하지 않았다.
- 검증: 수정 후 Swift 빌드, Alt 폴더 검사, 읽기 전용 마운트 DMG의 순차 `--self-check` 통과. 동시 잠금 상황의 재발 방지 효과는 미검증.
