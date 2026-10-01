import { statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";

export const DEFAULT_ALT_DB = join(
  homedir(),
  "Library",
  "Application Support",
  "alt",
  "data",
  "database",
  "lecture_notes.db",
);

export function openAltDatabase(databasePath = DEFAULT_ALT_DB) {
  return new DatabaseSync(databasePath, { readOnly: true });
}

export function listTranscribedLectures(databasePath = DEFAULT_ALT_DB) {
  const database = openAltDatabase(databasePath);
  try {
    const rows = database
      .prepare(`
        SELECT
          n.id,
          n.title,
          n.lecture_date AS lectureDate,
          n.status,
          length(t.content_text) AS transcriptChars,
          fm.file_path AS audioPath,
          fr.mime_type AS audioMimeType
        FROM lecture_notes n
        JOIN note_components t
          ON t.note_id = n.id
          AND t.component_type = 'transcript'
          AND t.deleted_at IS NULL
        LEFT JOIN note_components r
          ON r.note_id = n.id
          AND r.component_type = 'recording'
          AND r.deleted_at IS NULL
        LEFT JOIN file_metadata fm ON fm.inode = r.file_inode
        LEFT JOIN file_refs fr ON fr.id = r.file_ref_id
        WHERE n.deleted_at IS NULL
        ORDER BY n.updated_at DESC
      `)
      .all();

    return rows.map((row) => ({
      ...row,
      hasAudio: Boolean(row.audioPath),
      audioBytes: safeFileSize(row.audioPath),
    }));
  } finally {
    database.close();
  }
}

export function loadNormalizedLecture(noteId, databasePath = DEFAULT_ALT_DB) {
  if (!noteId) throw new Error("noteId is required");

  const database = openAltDatabase(databasePath);
  try {
    const row = database
      .prepare(`
        SELECT
          n.id,
          n.title,
          n.lecture_date AS lectureDate,
          n.status,
          t.id AS transcriptComponentId,
          t.content_text AS transcriptJson,
          m.id AS meetingNotesComponentId,
          m.content_text AS meetingNotesJson,
          r.id AS recordingComponentId,
          fm.file_path AS audioPath,
          fr.id AS audioFileRefId,
          fr.mime_type AS audioMimeType,
          fr.original_name AS audioOriginalName
        FROM lecture_notes n
        JOIN note_components t
          ON t.note_id = n.id
          AND t.component_type = 'transcript'
          AND t.deleted_at IS NULL
        LEFT JOIN note_components r
          ON r.note_id = n.id
          AND r.component_type = 'recording'
          AND r.deleted_at IS NULL
        LEFT JOIN note_components m
          ON m.note_id = n.id
          AND m.component_type = 'meeting_notes'
          AND m.deleted_at IS NULL
        LEFT JOIN file_metadata fm ON fm.inode = r.file_inode
        LEFT JOIN file_refs fr ON fr.id = r.file_ref_id
        WHERE n.id = ? AND n.deleted_at IS NULL
        LIMIT 1
      `)
      .get(noteId);

    if (!row) throw new Error(`No transcribed Alt lecture found for note ${noteId}`);

    let chunks;
    try {
      chunks = JSON.parse(row.transcriptJson);
    } catch (error) {
      throw new Error(`Alt transcript is not valid JSON: ${error.message}`);
    }
    if (!Array.isArray(chunks)) {
      throw new Error("Alt transcript root must be an array");
    }

    const segments = [];
    for (const [chunkIndex, chunk] of chunks.entries()) {
      if (!Array.isArray(chunk?.segments)) continue;
      for (const [segmentIndex, segment] of chunk.segments.entries()) {
        const startMs = Number(segment?.start);
        const endMs = Number(segment?.end);
        if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs < startMs) {
          throw new Error(
            `Invalid timestamp at chunk ${chunkIndex}, segment ${segmentIndex}`,
          );
        }
        segments.push({
          id: `${row.transcriptComponentId}:${chunkIndex}:${segmentIndex}`,
          startMs,
          endMs,
          text: typeof segment.text === "string" ? segment.text : "",
          speakerId: segment.speaker || null,
          provenance: {
            provider: "alt",
            externalSourceId: row.transcriptComponentId,
            chunkIndex,
            segmentIndex,
          },
        });
      }
    }

    return {
      schemaVersion: 1,
      source: {
        provider: "alt",
        externalId: row.id,
        importedAt: new Date().toISOString(),
      },
      lecture: {
        externalId: row.id,
        title: row.title,
        lectureDate: row.lectureDate,
        sourceStatus: row.status,
      },
      audio: row.recordingComponentId
        ? {
            externalId: row.recordingComponentId,
            fileRefId: row.audioFileRefId,
            path: row.audioPath,
            originalName: row.audioOriginalName,
            mimeType: row.audioMimeType,
            bytes: safeFileSize(row.audioPath),
          }
        : null,
      transcript: {
        externalId: row.transcriptComponentId,
        segments,
      },
      altSummary: {
        externalId: row.meetingNotesComponentId,
        text: extractPlateText(row.meetingNotesJson),
      },
    };
  } finally {
    database.close();
  }
}

export function extractPlateText(value) {
  if (!value) return "";
  let root;
  try {
    root = typeof value === "string" ? JSON.parse(value) : value;
  } catch {
    return "";
  }
  const text = [];
  const visit = (node) => {
    if (Array.isArray(node)) {
      for (const child of node) visit(child);
      return;
    }
    if (!node || typeof node !== "object") return;
    if (typeof node.text === "string") text.push(node.text);
    if (Array.isArray(node.children)) visit(node.children);
  };
  visit(root);
  return text.join(" ").replace(/\s+/g, " ").trim();
}

export function inspectNormalizedLecture(lecture) {
  const segments = lecture.transcript.segments;
  return {
    provider: lecture.source.provider,
    externalId: lecture.source.externalId,
    title: lecture.lecture.title,
    segmentCount: segments.length,
    durationMs: segments.reduce((maximum, segment) => Math.max(maximum, segment.endMs), 0),
    hasTimestamps: segments.length > 0 && segments.every(
      (segment) => Number.isFinite(segment.startMs) && Number.isFinite(segment.endMs),
    ),
    hasAudio: Boolean(lecture.audio?.path),
    audioBytes: lecture.audio?.bytes ?? null,
  };
}

function safeFileSize(path) {
  if (!path) return null;
  try {
    return statSync(path).size;
  } catch {
    return null;
  }
}

function parseArguments(argv) {
  const [command = "list", noteId, ...rest] = argv;
  const databaseFlagIndex = rest.indexOf("--db");
  const databasePath = databaseFlagIndex >= 0 ? rest[databaseFlagIndex + 1] : DEFAULT_ALT_DB;
  return { command, noteId, databasePath };
}

function runCli() {
  const { command, noteId, databasePath } = parseArguments(process.argv.slice(2));
  if (command === "list") {
    console.log(JSON.stringify(listTranscribedLectures(databasePath), null, 2));
    return;
  }
  if (command === "inspect") {
    console.log(
      JSON.stringify(inspectNormalizedLecture(loadNormalizedLecture(noteId, databasePath)), null, 2),
    );
    return;
  }
  if (command === "export") {
    console.log(JSON.stringify(loadNormalizedLecture(noteId, databasePath), null, 2));
    return;
  }
  throw new Error("Usage: node src/alt-adapter.mjs <list|inspect|export> [note-id] [--db path]");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    runCli();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
