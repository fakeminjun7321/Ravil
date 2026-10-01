import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";

import {
  extractPlateText,
  inspectNormalizedLecture,
  listTranscribedLectures,
  loadNormalizedLecture,
} from "../src/alt-adapter.mjs";

function createFixture() {
  const directory = mkdtempSync(join(tmpdir(), "lecture-os-alt-"));
  const databasePath = join(directory, "lecture_notes.db");
  const audioPath = join(directory, "lecture.mp3");
  writeFileSync(audioPath, "audio fixture");

  const database = new DatabaseSync(databasePath);
  database.exec(`
    CREATE TABLE lecture_notes (
      id TEXT PRIMARY KEY,
      title TEXT,
      lecture_date DATE NOT NULL,
      status TEXT,
      updated_at DATETIME,
      deleted_at TEXT
    );
    CREATE TABLE note_components (
      id TEXT PRIMARY KEY,
      note_id TEXT NOT NULL,
      component_type TEXT NOT NULL,
      content_text TEXT,
      file_inode BIGINT,
      file_ref_id TEXT,
      deleted_at TEXT
    );
    CREATE TABLE file_metadata (inode BIGINT PRIMARY KEY, file_path TEXT);
    CREATE TABLE file_refs (
      id TEXT PRIMARY KEY,
      mime_type TEXT,
      original_name TEXT
    );
  `);
  database.prepare(
    "INSERT INTO lecture_notes VALUES (?, ?, ?, ?, ?, NULL)",
  ).run("note-1", "자료구조", "2026-09-21", "draft", "2026-09-21T01:00:00Z");
  database.prepare("INSERT INTO file_metadata VALUES (?, ?)").run(1, audioPath);
  database.prepare("INSERT INTO file_refs VALUES (?, ?, ?)").run(
    "file-1",
    "audio/mpeg",
    "lecture.mp3",
  );
  database.prepare(
    "INSERT INTO note_components VALUES (?, ?, ?, ?, ?, ?, NULL)",
  ).run(
    "transcript-1",
    "note-1",
    "transcript",
    JSON.stringify([
      {
        relativeStart: 0,
        segments: [
          { start: 0, end: 1500, text: "AVL Tree", speaker: "교수" },
          { start: 1500, end: 3000, text: "시험에 중요합니다.", speaker: "교수" },
        ],
      },
    ]),
    null,
    null,
  );
  database.prepare(
    "INSERT INTO note_components VALUES (?, ?, ?, ?, ?, ?, NULL)",
  ).run("recording-1", "note-1", "recording", null, 1, "file-1");
  database.prepare(
    "INSERT INTO note_components VALUES (?, ?, ?, ?, ?, ?, NULL)",
  ).run(
    "meeting-notes-1",
    "note-1",
    "meeting_notes",
    JSON.stringify([{ type: "p", children: [{ text: "AVL Tree 요약" }] }]),
    null,
    null,
  );
  database.close();
  return { databasePath, audioPath };
}

test("lists transcribed Alt lectures without exposing transcript text", () => {
  const { databasePath } = createFixture();
  const lectures = listTranscribedLectures(databasePath);
  assert.equal(lectures.length, 1);
  assert.equal(lectures[0].title, "자료구조");
  assert.equal(lectures[0].hasAudio, true);
  assert.equal("transcriptJson" in lectures[0], false);
});

test("normalizes timestamped transcript segments with provenance", () => {
  const { databasePath, audioPath } = createFixture();
  const lecture = loadNormalizedLecture("note-1", databasePath);
  assert.equal(lecture.audio.path, audioPath);
  assert.equal(lecture.transcript.segments.length, 2);
  assert.equal(lecture.altSummary.text, "AVL Tree 요약");
  assert.deepEqual(lecture.transcript.segments[1], {
    id: "transcript-1:0:1",
    startMs: 1500,
    endMs: 3000,
    text: "시험에 중요합니다.",
    speakerId: "교수",
    provenance: {
      provider: "alt",
      externalSourceId: "transcript-1",
      chunkIndex: 0,
      segmentIndex: 1,
    },
  });
});

test("extracts plain text from Alt Plate JSON", () => {
  assert.equal(
    extractPlateText('[{"children":[{"text":"첫 문장"},{"text":" 두 번째"}]}]'),
    "첫 문장 두 번째",
  );
});

test("reports the evidence prerequisites needed by phase 0", () => {
  const { databasePath } = createFixture();
  const inspection = inspectNormalizedLecture(loadNormalizedLecture("note-1", databasePath));
  assert.equal(inspection.segmentCount, 2);
  assert.equal(inspection.durationMs, 3000);
  assert.equal(inspection.hasTimestamps, true);
  assert.equal(inspection.hasAudio, true);
});
