import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { randomUUID } from "node:crypto";
import { DatabaseSync } from "node:sqlite";

import type { ImportResult, NormalizedLectureInput } from "../../types/src/index.ts";

export const DEFAULT_LECTURE_OS_DB = new URL("../../../data/lecture-os.db", import.meta.url).pathname;

export function openLectureOsDatabase(databasePath = DEFAULT_LECTURE_OS_DB): DatabaseSync {
  mkdirSync(dirname(databasePath), { recursive: true });
  const database = new DatabaseSync(databasePath);
  database.exec("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;");
  migrate(database);
  return database;
}

export function migrate(database: DatabaseSync): void {
  database.exec(`
    CREATE TABLE IF NOT EXISTS lectures (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      lecture_date TEXT NOT NULL,
      source_status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS external_sources (
      id TEXT PRIMARY KEY,
      lecture_id TEXT NOT NULL REFERENCES lectures(id) ON DELETE CASCADE,
      provider TEXT NOT NULL,
      external_id TEXT NOT NULL,
      raw_payload_json TEXT NOT NULL,
      imported_at TEXT NOT NULL,
      UNIQUE(provider, external_id)
    );

    CREATE TABLE IF NOT EXISTS audio_assets (
      id TEXT PRIMARY KEY,
      lecture_id TEXT NOT NULL REFERENCES lectures(id) ON DELETE CASCADE,
      external_source_id TEXT NOT NULL REFERENCES external_sources(id) ON DELETE CASCADE,
      provider_external_id TEXT,
      local_path TEXT,
      mime_type TEXT,
      size_bytes INTEGER,
      UNIQUE(external_source_id)
    );

    CREATE TABLE IF NOT EXISTS transcript_segments (
      id TEXT PRIMARY KEY,
      lecture_id TEXT NOT NULL REFERENCES lectures(id) ON DELETE CASCADE,
      external_source_id TEXT NOT NULL REFERENCES external_sources(id) ON DELETE CASCADE,
      provider_segment_id TEXT NOT NULL,
      ordinal INTEGER NOT NULL,
      start_ms INTEGER NOT NULL CHECK(start_ms >= 0),
      end_ms INTEGER NOT NULL CHECK(end_ms >= start_ms),
      text TEXT NOT NULL,
      speaker_id TEXT,
      UNIQUE(external_source_id, ordinal),
      UNIQUE(external_source_id, provider_segment_id)
    );

    CREATE TABLE IF NOT EXISTS evidence (
      id TEXT PRIMARY KEY,
      lecture_id TEXT NOT NULL REFERENCES lectures(id) ON DELETE CASCADE,
      transcript_segment_id TEXT NOT NULL REFERENCES transcript_segments(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      quote TEXT NOT NULL,
      start_ms INTEGER NOT NULL,
      end_ms INTEGER NOT NULL,
      pipeline_version TEXT NOT NULL,
      UNIQUE(lecture_id, transcript_segment_id, kind, pipeline_version)
    );

    CREATE TABLE IF NOT EXISTS ai_artifacts (
      id TEXT PRIMARY KEY,
      lecture_id TEXT NOT NULL REFERENCES lectures(id) ON DELETE CASCADE,
      artifact_type TEXT NOT NULL,
      pipeline_version TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      UNIQUE(lecture_id, artifact_type, pipeline_version)
    );

    CREATE TABLE IF NOT EXISTS import_runs (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      external_id TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('running', 'completed', 'failed')),
      error TEXT,
      started_at TEXT NOT NULL,
      finished_at TEXT
    );

    CREATE TABLE IF NOT EXISTS sync_runs (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('running', 'completed', 'partial', 'failed')),
      discovered_count INTEGER NOT NULL DEFAULT 0,
      imported_count INTEGER NOT NULL DEFAULT 0,
      skipped_count INTEGER NOT NULL DEFAULT 0,
      failed_count INTEGER NOT NULL DEFAULT 0,
      error_json TEXT,
      started_at TEXT NOT NULL,
      finished_at TEXT
    );

    CREATE TABLE IF NOT EXISTS semesters (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      starts_at TEXT NOT NULL,
      ends_at TEXT NOT NULL,
      UNIQUE(name, starts_at, ends_at)
    );

    CREATE TABLE IF NOT EXISTS courses (
      id TEXT PRIMARY KEY,
      semester_id TEXT NOT NULL REFERENCES semesters(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      professor_name TEXT,
      color TEXT,
      UNIQUE(semester_id, name)
    );

    CREATE TABLE IF NOT EXISTS course_schedules (
      id TEXT PRIMARY KEY,
      course_id TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      iso_weekday INTEGER NOT NULL CHECK(iso_weekday BETWEEN 1 AND 7),
      start_minute INTEGER NOT NULL CHECK(start_minute BETWEEN 0 AND 1439),
      end_minute INTEGER NOT NULL CHECK(end_minute BETWEEN 1 AND 1440),
      timezone TEXT NOT NULL,
      location TEXT,
      source TEXT NOT NULL,
      CHECK(end_minute > start_minute),
      UNIQUE(course_id, iso_weekday, start_minute, end_minute)
    );

    CREATE TABLE IF NOT EXISTS lecture_classification_candidates (
      id TEXT PRIMARY KEY,
      lecture_id TEXT NOT NULL REFERENCES lectures(id) ON DELETE CASCADE,
      course_id TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
      score REAL NOT NULL,
      reasons_json TEXT NOT NULL,
      classifier_version TEXT NOT NULL,
      created_at TEXT NOT NULL,
      UNIQUE(lecture_id, course_id, classifier_version)
    );

    CREATE TABLE IF NOT EXISTS course_materials (
      id TEXT PRIMARY KEY,
      course_id TEXT REFERENCES courses(id) ON DELETE SET NULL,
      lecture_id TEXT REFERENCES lectures(id) ON DELETE SET NULL,
      provider TEXT NOT NULL,
      external_id TEXT NOT NULL,
      external_url TEXT,
      file_name TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      local_path TEXT,
      content_hash TEXT,
      source_modified_at TEXT,
      version INTEGER NOT NULL,
      page_count INTEGER,
      has_text_layer INTEGER,
      status TEXT NOT NULL CHECK(status IN ('cataloged', 'ingested', 'failed')),
      ingested_at TEXT NOT NULL,
      UNIQUE(provider, external_id, version)
    );

    CREATE TABLE IF NOT EXISTS material_pages (
      id TEXT PRIMARY KEY,
      material_id TEXT NOT NULL REFERENCES course_materials(id) ON DELETE CASCADE,
      page_number INTEGER NOT NULL CHECK(page_number > 0),
      text TEXT NOT NULL,
      text_hash TEXT NOT NULL,
      UNIQUE(material_id, page_number)
    );
  `);
  const externalSourceColumns = database.prepare("PRAGMA table_info(external_sources)").all() as Array<{ name: string }>;
  if (!externalSourceColumns.some((column) => column.name === "content_hash")) {
    database.exec("ALTER TABLE external_sources ADD COLUMN content_hash TEXT");
  }
  const lectureColumns = database.prepare("PRAGMA table_info(lectures)").all() as Array<{ name: string }>;
  for (const [name, definition] of [
    ["started_at", "TEXT"],
    ["course_id", "TEXT REFERENCES courses(id) ON DELETE SET NULL"],
    ["classification_confidence", "REAL"],
    ["classification_method", "TEXT"],
  ] as const) {
    if (!lectureColumns.some((column) => column.name === name)) {
      database.exec(`ALTER TABLE lectures ADD COLUMN ${name} ${definition}`);
    }
  }
}

export function persistNormalizedLecture(
  database: DatabaseSync,
  input: NormalizedLectureInput,
  candidates: Array<{ type: string; evidence: { segmentId?: string; sourceId: string; startMs: number; endMs: number; quote: string } }>,
): ImportResult {
  const now = new Date().toISOString();
  const importRunId = randomUUID();
  database.prepare(
    "INSERT INTO import_runs (id, provider, external_id, status, started_at) VALUES (?, ?, ?, 'running', ?)",
  ).run(importRunId, input.source.provider, input.source.externalId, now);

  database.exec("BEGIN IMMEDIATE");
  try {
    const existing = database.prepare(
      "SELECT id, lecture_id AS lectureId FROM external_sources WHERE provider = ? AND external_id = ?",
    ).get(input.source.provider, input.source.externalId) as { id: string; lectureId: string } | undefined;
    const created = !existing;
    const lectureId = existing?.lectureId ?? randomUUID();
    const externalSourceId = existing?.id ?? randomUUID();

    if (created) {
      database.prepare(
        "INSERT INTO lectures (id, title, lecture_date, source_status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
      ).run(lectureId, input.lecture.title, input.lecture.lectureDate, input.lecture.sourceStatus, now, now);
      database.prepare(
        "INSERT INTO external_sources (id, lecture_id, provider, external_id, raw_payload_json, imported_at) VALUES (?, ?, ?, ?, ?, ?)",
      ).run(externalSourceId, lectureId, input.source.provider, input.source.externalId, JSON.stringify(input), now);
    } else {
      database.prepare(
        "UPDATE lectures SET title = ?, lecture_date = ?, source_status = ?, updated_at = ? WHERE id = ?",
      ).run(input.lecture.title, input.lecture.lectureDate, input.lecture.sourceStatus, now, lectureId);
      database.prepare(
        "UPDATE external_sources SET raw_payload_json = ?, imported_at = ? WHERE id = ?",
      ).run(JSON.stringify(input), now, externalSourceId);
    }

    if (input.audio) {
      database.prepare(`
        INSERT INTO audio_assets
          (id, lecture_id, external_source_id, provider_external_id, local_path, mime_type, size_bytes)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(external_source_id) DO UPDATE SET
          provider_external_id = excluded.provider_external_id,
          local_path = excluded.local_path,
          mime_type = excluded.mime_type,
          size_bytes = excluded.size_bytes
      `).run(
        randomUUID(), lectureId, externalSourceId, input.audio.externalId, input.audio.path,
        input.audio.mimeType, input.audio.bytes,
      );
    }

    const segmentIdByProviderId = new Map<string, string>();
    const upsertSegment = database.prepare(`
      INSERT INTO transcript_segments
        (id, lecture_id, external_source_id, provider_segment_id, ordinal, start_ms, end_ms, text, speaker_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(external_source_id, ordinal) DO UPDATE SET
        provider_segment_id = excluded.provider_segment_id,
        start_ms = excluded.start_ms,
        end_ms = excluded.end_ms,
        text = excluded.text,
        speaker_id = excluded.speaker_id
      RETURNING id
    `);
    for (const [ordinal, segment] of input.transcript.segments.entries()) {
      const row = upsertSegment.get(
        randomUUID(), lectureId, externalSourceId, segment.id, ordinal, segment.startMs,
        segment.endMs, segment.text, segment.speakerId,
      ) as { id: string };
      segmentIdByProviderId.set(segment.id, row.id);
    }
    database.prepare(
      "DELETE FROM transcript_segments WHERE external_source_id = ? AND ordinal >= ?",
    ).run(externalSourceId, input.transcript.segments.length);

    const pipelineVersion = "rules-v1";
    database.prepare("DELETE FROM evidence WHERE lecture_id = ? AND pipeline_version = ?")
      .run(lectureId, pipelineVersion);
    const insertEvidence = database.prepare(`
      INSERT INTO evidence
        (id, lecture_id, transcript_segment_id, kind, quote, start_ms, end_ms, pipeline_version)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);
    let evidenceCount = 0;
    for (const candidate of candidates) {
      const providerSegmentId = candidate.evidence.segmentId;
      if (!providerSegmentId) continue;
      const transcriptSegmentId = segmentIdByProviderId.get(providerSegmentId);
      if (!transcriptSegmentId) continue;
      insertEvidence.run(
        randomUUID(), lectureId, transcriptSegmentId, candidate.type, candidate.evidence.quote,
        candidate.evidence.startMs, candidate.evidence.endMs, pipelineVersion,
      );
      evidenceCount += 1;
    }

    database.prepare(`
      INSERT INTO ai_artifacts
        (id, lecture_id, artifact_type, pipeline_version, payload_json, created_at)
      VALUES (?, ?, 'alt_summary_and_candidates', ?, ?, ?)
      ON CONFLICT(lecture_id, artifact_type, pipeline_version) DO UPDATE SET
        payload_json = excluded.payload_json,
        created_at = excluded.created_at
    `).run(
      randomUUID(), lectureId, pipelineVersion,
      JSON.stringify({ altSummary: input.altSummary, candidates }), now,
    );

    database.prepare(
      "UPDATE import_runs SET status = 'completed', finished_at = ? WHERE id = ?",
    ).run(new Date().toISOString(), importRunId);
    database.exec("COMMIT");
    return {
      lectureId, externalSourceId, created, segmentCount: input.transcript.segments.length,
      evidenceCount, importRunId,
    };
  } catch (error) {
    database.exec("ROLLBACK");
    database.prepare(
      "UPDATE import_runs SET status = 'failed', error = ?, finished_at = ? WHERE id = ?",
    ).run(error instanceof Error ? error.message : String(error), new Date().toISOString(), importRunId);
    throw error;
  }
}

export function inspectDatabase(database: DatabaseSync): object {
  const counts = database.prepare(`
    SELECT
      (SELECT COUNT(*) FROM lectures) AS lectures,
      (SELECT COUNT(*) FROM external_sources) AS externalSources,
      (SELECT COUNT(*) FROM transcript_segments) AS transcriptSegments,
      (SELECT COUNT(*) FROM evidence) AS evidence,
      (SELECT COUNT(*) FROM ai_artifacts) AS aiArtifacts,
      (SELECT COUNT(*) FROM import_runs WHERE status = 'completed') AS completedImports,
      (SELECT COUNT(*) FROM import_runs WHERE status = 'failed') AS failedImports
  `).get();
  const orphanEvidence = database.prepare(`
    SELECT COUNT(*) AS count
    FROM evidence e
    LEFT JOIN transcript_segments s ON s.id = e.transcript_segment_id
    WHERE s.id IS NULL
  `).get() as { count: number };
  return { ...counts, orphanEvidence: orphanEvidence.count };
}

export function listLectures(database: DatabaseSync): unknown[] {
  return database.prepare(`
    SELECT l.id, l.title, l.lecture_date AS lectureDate, l.source_status AS sourceStatus,
      COUNT(DISTINCT s.id) AS segmentCount, COUNT(DISTINCT e.id) AS evidenceCount
    FROM lectures l
    LEFT JOIN transcript_segments s ON s.lecture_id = l.id
    LEFT JOIN evidence e ON e.lecture_id = l.id
    GROUP BY l.id
    ORDER BY l.lecture_date DESC, l.created_at DESC
  `).all();
}

export function listMaterials(database: DatabaseSync): unknown[] {
  return database.prepare(`
    SELECT m.id, m.provider, m.file_name AS fileName, m.version, m.page_count AS pageCount,
      m.has_text_layer AS hasTextLayer, m.status, c.name AS courseName
    FROM course_materials m LEFT JOIN courses c ON c.id = m.course_id
    ORDER BY m.ingested_at DESC, m.id
  `).all();
}

export function getMaterialPage(database: DatabaseSync, materialId: string, pageNumber: number): unknown {
  return database.prepare(`
    SELECT material_id AS materialId, page_number AS pageNumber, text, text_hash AS textHash
    FROM material_pages WHERE material_id = ? AND page_number = ?
  `).get(materialId, pageNumber) ?? null;
}

export function getExternalSourceContentHash(
  database: DatabaseSync,
  provider: string,
  externalId: string,
): string | null {
  const row = database.prepare(
    "SELECT content_hash AS contentHash FROM external_sources WHERE provider = ? AND external_id = ?",
  ).get(provider, externalId) as { contentHash: string | null } | undefined;
  return row?.contentHash ?? null;
}

export function setExternalSourceContentHash(
  database: DatabaseSync,
  provider: string,
  externalId: string,
  contentHash: string,
): void {
  database.prepare(
    "UPDATE external_sources SET content_hash = ? WHERE provider = ? AND external_id = ?",
  ).run(contentHash, provider, externalId);
}
