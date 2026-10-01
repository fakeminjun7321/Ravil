import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";

import { inspectDatabase, listLectures, openLectureOsDatabase } from "../packages/db/src/index.ts";
import { importAltLecture } from "../packages/import-alt/src/index.ts";
import { syncAltOnce, withRetries } from "../packages/sync-alt/src/index.ts";

function createAltFixture() {
  const directory = mkdtempSync(join(tmpdir(), "lecture-os-phase1-"));
  const altDatabasePath = join(directory, "alt.db");
  const lectureOsDatabasePath = join(directory, "lecture-os.db");
  const audioPath = join(directory, "lecture.mp3");
  writeFileSync(audioPath, "private audio fixture");
  const database = new DatabaseSync(altDatabasePath);
  database.exec(`
    CREATE TABLE lecture_notes (
      id TEXT PRIMARY KEY, title TEXT, lecture_date DATE NOT NULL, status TEXT,
      updated_at DATETIME, deleted_at TEXT
    );
    CREATE TABLE note_components (
      id TEXT PRIMARY KEY, note_id TEXT NOT NULL, component_type TEXT NOT NULL,
      content_text TEXT, file_inode BIGINT, file_ref_id TEXT, deleted_at TEXT
    );
    CREATE TABLE file_metadata (inode BIGINT PRIMARY KEY, file_path TEXT);
    CREATE TABLE file_refs (id TEXT PRIMARY KEY, mime_type TEXT, original_name TEXT);
  `);
  database.prepare("INSERT INTO lecture_notes VALUES (?, ?, ?, ?, ?, NULL)")
    .run("alt-note-1", "자료구조", "2026-09-21", "completed", "2026-09-21T00:00:00Z");
  database.prepare("INSERT INTO file_metadata VALUES (?, ?)").run(1, audioPath);
  database.prepare("INSERT INTO file_refs VALUES (?, ?, ?)")
    .run("file-1", "audio/mpeg", "lecture.mp3");
  database.prepare("INSERT INTO note_components VALUES (?, ?, ?, ?, ?, ?, NULL)").run(
    "transcript-1", "alt-note-1", "transcript",
    JSON.stringify([{ segments: [
      { start: 0, end: 1000, text: "AVL Tree를 설명합니다.", speaker: "교수" },
      { start: 1000, end: 2000, text: "이 부분은 시험에 중요합니다.", speaker: "교수" },
    ] }]), null, null,
  );
  database.prepare("INSERT INTO note_components VALUES (?, ?, ?, ?, ?, ?, NULL)")
    .run("recording-1", "alt-note-1", "recording", null, 1, "file-1");
  database.prepare("INSERT INTO note_components VALUES (?, ?, ?, ?, ?, ?, NULL)").run(
    "notes-1", "alt-note-1", "meeting_notes",
    JSON.stringify([{ children: [{ text: "AVL Tree 요약" }] }]), null, null,
  );
  database.close();
  return { altDatabasePath, lectureOsDatabasePath };
}

test("imports an Alt lecture idempotently and syncs only changed content", async () => {
  const paths = createAltFixture();
  const first = importAltLecture("alt-note-1", paths);
  const second = importAltLecture("alt-note-1", paths);
  assert.equal(first.created, true);
  assert.equal(second.created, false);
  assert.equal(second.lectureId, first.lectureId);
  assert.equal(second.externalSourceId, first.externalSourceId);

  const reopened = openLectureOsDatabase(paths.lectureOsDatabasePath);
  try {
    assert.deepEqual(inspectDatabase(reopened), {
      lectures: 1,
      externalSources: 1,
      transcriptSegments: 2,
      evidence: 2,
      aiArtifacts: 1,
      completedImports: 2,
      failedImports: 0,
      orphanEvidence: 0,
    });
    const lectures = listLectures(reopened);
    assert.equal(lectures.length, 1);
    assert.equal(lectures[0].segmentCount, 2);
    assert.equal(lectures[0].evidenceCount, 2);
  } finally {
    reopened.close();
  }

  const firstSync = await syncAltOnce({ ...paths, retryDelayMs: 0 });
  assert.equal(firstSync.imported, 1);
  assert.equal(firstSync.skipped, 0);
  const unchangedSync = await syncAltOnce({ ...paths, retryDelayMs: 0 });
  assert.equal(unchangedSync.imported, 0);
  assert.equal(unchangedSync.skipped, 1);

  const altDatabase = new DatabaseSync(paths.altDatabasePath);
  const transcriptRow = altDatabase.prepare(
    "SELECT content_text AS contentText FROM note_components WHERE id = 'transcript-1'",
  ).get();
  const transcript = JSON.parse(transcriptRow.contentText);
  transcript[0].segments.push({
    start: 2000,
    end: 3000,
    text: "다음 개념으로 넘어갑니다.",
    speaker: "교수",
  });
  altDatabase.prepare("UPDATE note_components SET content_text = ? WHERE id = 'transcript-1'")
    .run(JSON.stringify(transcript));
  altDatabase.close();

  const changedSync = await syncAltOnce({ ...paths, retryDelayMs: 0 });
  assert.equal(changedSync.imported, 1);
  assert.equal(changedSync.skipped, 0);
  const finalDatabase = openLectureOsDatabase(paths.lectureOsDatabasePath);
  try {
    const state = inspectDatabase(finalDatabase);
    assert.equal(state.lectures, 1);
    assert.equal(state.transcriptSegments, 3);
    assert.equal(state.orphanEvidence, 0);
    const syncRuns = finalDatabase.prepare(
      "SELECT status, imported_count AS imported, skipped_count AS skipped FROM sync_runs ORDER BY started_at, rowid",
    ).all().map((row) => ({ ...row }));
    assert.deepEqual(syncRuns, [
      { status: "completed", imported: 1, skipped: 0 },
      { status: "completed", imported: 0, skipped: 1 },
      { status: "completed", imported: 1, skipped: 0 },
    ]);
  } finally {
    finalDatabase.close();
  }
});

test("retries a transient operation with a fixed bound", async () => {
  let attempts = 0;
  const result = await withRetries(() => {
    attempts += 1;
    if (attempts < 3) throw new Error("transient");
    return "ok";
  }, 2, 0);
  assert.equal(result, "ok");
  assert.equal(attempts, 3);
});

test("records a bounded sync failure instead of leaving the run active", async () => {
  const paths = createAltFixture();
  let attempts = 0;
  const result = await syncAltOnce({
    ...paths,
    retryCount: 1,
    retryDelayMs: 0,
    importer: () => {
      attempts += 1;
      throw new Error("provider unavailable");
    },
  });
  assert.equal(attempts, 2);
  assert.equal(result.failed, 1);
  assert.equal(result.failures[0].error, "provider unavailable");
  const database = openLectureOsDatabase(paths.lectureOsDatabasePath);
  try {
    const run = database.prepare(
      "SELECT status, failed_count AS failed FROM sync_runs WHERE id = ?",
    ).get(result.syncRunId);
    assert.deepEqual({ ...run }, { status: "failed", failed: 1 });
  } finally {
    database.close();
  }
});
