# Lecture OS Phase 2 — automatic Alt synchronization

## Implemented

- Discover every Alt note that currently has a transcript.
- Compute a stable SHA-256 fingerprint excluding volatile import timestamps.
- Import new or changed notes only.
- Skip byte-equivalent normalized lecture content.
- Preserve Phase 1 internal Lecture IDs during updates.
- Retry a failed note with a fixed bound and increasing delay.
- Continue to the next note after a bounded failure.
- Record aggregate sync runs as `completed`, `partial`, or `failed`.
- Polling watcher with a configurable interval; it runs sequentially and does not overlap cycles.

## Actual-data verification

First real sync:

```text
discovered: 2
imported:   2
skipped:    0
failed:     0
```

Immediate second sync against unchanged Alt data:

```text
discovered: 2
imported:   0
skipped:    2
failed:     0
```

Persisted Lecture OS state:

- lectures: 2
- external sources: 2
- transcript segments: 3,203
- evidence candidates: 22
- versioned artifacts: 2
- failed imports: 0
- orphan evidence rows: 0

A separate temporary database exercised the polling watcher. Its first cycle imported both notes;
subsequent cycles skipped both unchanged notes. The watcher was then manually interrupted and was
not left running.

## Focused tests

- unchanged content is skipped;
- changed transcript content is imported;
- changed content updates the existing Lecture instead of creating another one;
- stale segments are removed when source length changes;
- retry count is bounded;
- a terminal note failure is stored as a failed sync run, not left as `running`;
- evidence foreign keys remain valid.

Ten focused tests pass.

## Commands

One synchronization pass:

```bash
npm run phase2:sync
```

Polling watcher, default 30 seconds:

```bash
npm run phase2:watch
```

Custom interval:

```bash
ALT_SYNC_INTERVAL_MS=60000 npm run phase2:watch
```

## Verification levels

- Implemented: discovery, hashing, new/changed-only import, bounded retry, run history, polling.
- Unit-verified: ten focused tests pass.
- Local-data-verified: two real Alt notes synchronized; the second pass skipped both.
- Watch-loop-verified: repeated polling worked against a temporary destination DB.
- Not verified: long-running unattended stability, behavior while Alt is actively writing a
  transcript, macOS launch-at-login scheduling, notification delivery, or multi-process locking.

## Safety boundary

The watcher reads Alt's database and writes only Lecture OS's private database. It does not modify
Alt, start cloud transcription, or upload files. No watcher process was left running after this
verification.

Timetable-based course assignment continues in
[`phase-3-course-classification.md`](./phase-3-course-classification.md).
