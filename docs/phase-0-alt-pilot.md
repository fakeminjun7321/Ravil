# Lecture OS Phase 0 — Alt pilot

## Scope

Phase 0 reuses the installed Alt app for recording and transcription. Lecture OS owns the
normalized import format, evidence links, lecture intelligence, and study output. Building a
new recorder or STT provider is intentionally outside this phase.

## Verified local capability snapshot

Checked read-only on 2026-09-21:

- Alt is installed as `com.electron.alt`, version `0.11.2`.
- Alt stores lecture notes in a local SQLite database.
- A transcript component is a JSON array of chunks containing timestamped segments.
- Each observed segment has millisecond `start` and `end` values plus text and an optional
  speaker label.
- Recording components can be resolved to local audio files.
- Two existing notes currently have both transcript data and linked local recordings.

This snapshot does not prove that Alt has a stable public API or that its private database
schema will remain compatible with later Alt versions.

## Safety boundary

The adapter opens the Alt database in read-only mode. It does not:

- write to Alt's database;
- start, cancel, or retry cloud transcription;
- copy transcript text into this repository;
- upload audio or transcript data;
- treat an in-progress job as a completed transcript.

## Phase 0 data flow

```text
Alt recording + transcript
          ↓
read-only Alt adapter
          ↓
NormalizedLectureInput
  ├─ internal import schema version
  ├─ Alt external source IDs
  ├─ local audio reference
  └─ timestamped transcript segments with provenance
          ↓
Lecture intelligence prototype
          ↓
evidence-backed study output
```

## Commands

List importable notes without printing transcript text:

```bash
npm run alt:list
```

Inspect one note's structural readiness without printing transcript text:

```bash
node src/alt-adapter.mjs inspect <ALT_NOTE_ID>
```

Export normalized JSON to standard output only when explicitly needed:

```bash
node src/alt-adapter.mjs export <ALT_NOTE_ID>
```

Because export includes the full transcript, redirect it only to an ignored private location
such as `pilot-data/`.

## Exit criteria

Phase 0 is complete only when one real lecture has been exercised through all of the following:

1. Alt recording and completed transcription are present.
2. The adapter imports the transcript and audio reference without modifying Alt.
3. Summary, key concepts, professor emphasis, exam mentions, and assignments are generated.
4. Every important result links to a supporting transcript timestamp or document page.
5. At least one source jump is manually checked against the original audio.
6. Missing or inaccurate results are recorded instead of being silently accepted.

The adapter and its tests establish only the import foundation. They do not yet satisfy items
3–6, so the full Phase 0 user path remains unverified.

## Current implementation checkpoint

- Implemented: read-only Alt lecture discovery and normalization.
- Unit-verified: adapter, Plate-text extraction, and rule-based evidence candidate extraction.
- Local-data-verified: one existing Alt note was structurally inspected with timestamped
  transcript segments and a linked audio file.
- Not verified: candidate accuracy, summary accuracy, source-jump playback, document-page
  evidence, and the full study output.

The keyword extractor intentionally labels matches as `candidate`. A keyword match alone is not
proof that the professor actually assigned work or announced an exam requirement; contextual
verification is still required.
