# Lecture OS Phase 3 — timetable and course classification

## Implemented

- Semester, Course, and recurring CourseSchedule persistence.
- ISO weekday plus local start/end minutes.
- Per-schedule IANA timezone handling with `Intl.DateTimeFormat`.
- Deterministic scoring with explicit reasons:
  - exact normalized title match: +70
  - partial title-token overlap: up to +30
  - timetable window match: +60
- 15-minute tolerance before and after a scheduled class.
- Candidate persistence with classifier version.
- Automatic assignment only when:
  - top score is at least 0.60; and
  - the top candidate leads the runner-up by at least 0.15.
- Ambiguous and low-signal lectures remain unassigned.
- JSON timetable configuration and classify-all CLI commands.

## User timetable configured

The supplied timetable images were transcribed into the private, Git-ignored
`data/timetable.json`:

- courses and scheduled activities: 19
- weekly schedule blocks: 25
- timezone: `Asia/Seoul`
- consecutive periods of the same course were merged into one lecture block
- cells explicitly labelled `공강` were excluded
- grey unavailable cells were excluded
- the overlapping `1차자습 16:30–18:00` reference was kept outside the lecture schedule

The semester range is currently assumed to be `2026-09-01` through `2026-12-31`; those dates were
not printed in the images and remain user-confirmation data.

An isolated live-config check using the transcribed timetable verified:

- Monday `미방`, 08:35 KST: exact title plus schedule match, confidence 1.0
- Thursday `영 I`, 15:22 KST: exact title plus schedule match, confidence 1.0

Single-character and Roman-numeral tokens such as `I` are excluded from partial-title scoring, so
`영 I`, `영 II`, `수 I`, and `일지 I` do not become weak candidates merely because they share `I`.

## Current real-Lecture result

The two current Alt notes have no `calendar_event_id`, `calendar_event_start`, or
`calendar_event_end`, and their July dates fall outside the configured September–December semester.

Running classification against the real Lecture OS database therefore produced:

```text
Lecture 1: unclassified / no_candidate_signal
Lecture 2: unclassified / no_candidate_signal
```

This is the expected safe result. The real timetable is stored, but unrelated July lectures were
not forced into current-semester courses.

## Unit verification

- `2026-09-21T04:32:00Z` is interpreted as Monday 13:32 in `Asia/Seoul` and matches a
  Monday 13:30–14:45 schedule.
- A single timetable match scores 0.60 and is assigned.
- Two courses with the same schedule tie at 0.60 and are not assigned.
- An exact course-title match can assign at 0.70 when start time is unavailable.
- Invalid weekdays and clock ranges are rejected by configuration validation and database checks.

The full project test suite passes 14/14.

## Commands

Copy and edit the example before using it:

```bash
cp config/timetable.example.json data/timetable.json
```

Then configure and classify:

```bash
npm run phase3:configure -- data/timetable.json
npm run phase3:classify
```

`config/timetable.example.json` contains illustrative names and times only.

## Verification levels

- Implemented: timetable storage, timezone-aware deterministic scoring, candidates, confidence,
  ambiguity protection, and CLI.
- Unit-verified: schedule match, ambiguity, and no-time title fallback pass.
- Actual-data-verified: missing calendar/schedule inputs leave both real lectures unclassified.
- Not verified: the user's real timetable, Google Calendar OAuth/events, location matching,
  notification delivery, or an actual automatically assigned class.

## Next input needed for live verification

One real timetable JSON is sufficient. At least one corresponding lecture must also have a trusted
recording start time. The current Alt `created_at` value is note creation time and is not assumed to
be the lecture start time.

Drive/PDF material ingestion continues in
[`phase-4-drive-goodnotes.md`](./phase-4-drive-goodnotes.md).
