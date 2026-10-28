# Lecture OS Phase 5 — evidence-backed lecture intelligence

## Implemented

- Versioned `intelligence-rules-v1` pipeline.
- Provider-summary preservation without promoting it to a verified summary.
- Transcript-frequency concept candidates with filler-word filtering.
- Professor-emphasis, exam-mention, and assignment candidates.
- Course-material text-marker candidates for student emphasis.
- Explainable HIGH/MEDIUM/LOW study-priority scoring.
- Evidence validation before artifact persistence.
- Idempotent versioned intelligence artifacts.
- API endpoint: `GET /lectures/:lectureId/intelligence`.

## Actual-data result

`과학 시뮬레이션과 컴퓨터 활용`:

- summary: Alt provider summary present, unverified
- key concepts: 10
- professor-emphasis candidates: 6
- exam-mention candidates: 1
- assignments: 0
- student-emphasis candidates: 0
- evidence references valid: true

`수치해석과 시뮬레이션 프로젝트`:

- summary: missing
- key concepts: 10
- professor-emphasis candidates: 13
- exam-mention candidates: 1
- assignment candidates: 1
- student-emphasis candidates: 0
- evidence references valid: true

The exam and assignment results remain candidates. The known `exams`/`examples` STT ambiguity is
not presented as a confirmed exam announcement.

Student emphasis is empty because the two July Alt lectures are not linked to the current-semester
courses or the `프실` PDF. Unrelated PDF pages were not combined with those lectures.

## Verification levels

- Implemented: structured artifact, concepts, signal candidates, priorities, validation, API.
- Unit-verified: 16 focused tests pass, including idempotent intelligence persistence.
- Local-data-verified: artifacts generated for both real Alt lectures.
- API-verified: the first real lecture returned its persisted artifact and valid evidence state.
- Not verified: semantic quality of the concepts, whole-lecture summary coverage, confirmed exam or
  assignment meaning, handwriting-derived student emphasis, or LLM-based contextual verification.

## Pipeline boundary

The previously unstable full-transcript local-LLM path is not part of the completion path. The
rules pipeline is deterministic and evidence-safe, but it is a candidate generator rather than a
final semantic judge.

## Remaining roadmap

- Phase 6: study view and source jumps.
- Phase 7: cross-lecture Course Memory, search, Q&A, and exam-preparation mode.

