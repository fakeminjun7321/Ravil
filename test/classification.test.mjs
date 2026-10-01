import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { openLectureOsDatabase } from "../packages/db/src/index.ts";
import { classifyLecture, configureTimetable } from "../packages/classification/src/index.ts";

function setup(courses) {
  const directory = mkdtempSync(join(tmpdir(), "lecture-os-classification-"));
  const database = openLectureOsDatabase(join(directory, "lecture-os.db"));
  configureTimetable(database, {
    semester: { name: "2026-2학기", startsAt: "2026-08-01", endsAt: "2026-12-31" },
    courses,
  });
  return database;
}

function insertLecture(database, { id, title, startedAt = null }) {
  database.prepare(`
    INSERT INTO lectures
      (id, title, lecture_date, source_status, created_at, updated_at, started_at)
    VALUES (?, ?, '2026-09-21', 'ready', '2026-09-21T00:00:00Z', '2026-09-21T00:00:00Z', ?)
  `).run(id, title, startedAt);
}

test("assigns a clear timetable match using Asia/Seoul local time", () => {
  const database = setup([
    {
      name: "자료구조",
      schedules: [{ isoWeekday: 1, startsAt: "13:30", endsAt: "14:45", timezone: "Asia/Seoul" }],
    },
  ]);
  try {
    insertLecture(database, { id: "lecture-1", title: "5주차", startedAt: "2026-09-21T04:32:00Z" });
    const result = classifyLecture(database, "lecture-1");
    assert.ok(result.assignedCourseId);
    assert.equal(result.confidence, 0.6);
    assert.deepEqual(result.candidates[0].reasons, ["schedule_window_match:+60"]);
  } finally {
    database.close();
  }
});

test("does not auto-assign equal timetable candidates", () => {
  const sharedSchedule = [{ isoWeekday: 1, startsAt: "13:30", endsAt: "14:45", timezone: "Asia/Seoul" }];
  const database = setup([
    { name: "자료구조", schedules: sharedSchedule },
    { name: "운영체제", schedules: sharedSchedule },
  ]);
  try {
    insertLecture(database, { id: "lecture-2", title: "5주차", startedAt: "2026-09-21T04:32:00Z" });
    const result = classifyLecture(database, "lecture-2");
    assert.equal(result.assignedCourseId, null);
    assert.equal(result.reason, "ambiguous_or_low_score");
    assert.equal(result.candidates.length, 2);
  } finally {
    database.close();
  }
});

test("can classify an exact course title when a recording start time is unavailable", () => {
  const database = setup([{ name: "자료구조" }, { name: "운영체제" }]);
  try {
    insertLecture(database, { id: "lecture-3", title: "자료구조" });
    const result = classifyLecture(database, "lecture-3");
    assert.ok(result.assignedCourseId);
    assert.equal(result.confidence, 0.7);
    assert.deepEqual(result.candidates[0].reasons, ["exact_title_match:+70"]);
  } finally {
    database.close();
  }
});

test("does not treat shared one-character or Roman-numeral tokens as title evidence", () => {
  const database = setup([{ name: "영 I" }, { name: "영 II" }, { name: "수 I" }]);
  try {
    insertLecture(database, { id: "lecture-4", title: "영 I" });
    const result = classifyLecture(database, "lecture-4");
    assert.equal(result.assignedCourseId, result.candidates[0].courseId);
    assert.equal(result.candidates.length, 1);
    assert.equal(result.candidates[0].courseName, "영 I");
  } finally {
    database.close();
  }
});
