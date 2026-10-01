import { createHash, randomUUID } from "node:crypto";

import { listTranscribedLectures, loadNormalizedLecture } from "../../../src/alt-adapter.mjs";
import {
  DEFAULT_LECTURE_OS_DB,
  getExternalSourceContentHash,
  openLectureOsDatabase,
  setExternalSourceContentHash,
} from "../../db/src/index.ts";
import { importNormalizedAltLecture } from "../../import-alt/src/index.ts";
import type { ImportResult, NormalizedLectureInput } from "../../types/src/index.ts";

export interface SyncSummary {
  syncRunId: string;
  discovered: number;
  imported: number;
  skipped: number;
  failed: number;
  failures: Array<{ externalId: string; error: string }>;
}

export async function syncAltOnce(options: {
  altDatabasePath?: string;
  lectureOsDatabasePath?: string;
  retryCount?: number;
  retryDelayMs?: number;
  importer?: (lecture: NormalizedLectureInput, databasePath?: string) => ImportResult | Promise<ImportResult>;
} = {}): Promise<SyncSummary> {
  const lectureOsDatabasePath = options.lectureOsDatabasePath || DEFAULT_LECTURE_OS_DB;
  const retryCount = options.retryCount ?? 2;
  const retryDelayMs = options.retryDelayMs ?? 250;
  const importer = options.importer || importNormalizedAltLecture;
  const rows = listTranscribedLectures(options.altDatabasePath);
  const syncRunId = randomUUID();
  const startedAt = new Date().toISOString();
  const runDatabase = openLectureOsDatabase(lectureOsDatabasePath);
  runDatabase.prepare(`
    INSERT INTO sync_runs (id, provider, status, discovered_count, started_at)
    VALUES (?, 'alt', 'running', ?, ?)
  `).run(syncRunId, rows.length, startedAt);
  runDatabase.close();

  const summary: SyncSummary = {
    syncRunId,
    discovered: rows.length,
    imported: 0,
    skipped: 0,
    failed: 0,
    failures: [],
  };

  for (const row of rows) {
    try {
      const normalized = loadNormalizedLecture(row.id, options.altDatabasePath) as NormalizedLectureInput;
      const contentHash = normalizedLectureHash(normalized);
      const checkDatabase = openLectureOsDatabase(lectureOsDatabasePath);
      let existingHash: string | null;
      try {
        existingHash = getExternalSourceContentHash(
          checkDatabase,
          normalized.source.provider,
          normalized.source.externalId,
        );
      } finally {
        checkDatabase.close();
      }
      if (existingHash === contentHash) {
        summary.skipped += 1;
        continue;
      }

      await withRetries(
        () => importer(normalized, lectureOsDatabasePath),
        retryCount,
        retryDelayMs,
      );
      const updateDatabase = openLectureOsDatabase(lectureOsDatabasePath);
      setExternalSourceContentHash(
        updateDatabase,
        normalized.source.provider,
        normalized.source.externalId,
        contentHash,
      );
      updateDatabase.close();
      summary.imported += 1;
    } catch (error) {
      summary.failed += 1;
      summary.failures.push({
        externalId: row.id,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  const status = summary.failed === 0 ? "completed" : summary.imported > 0 || summary.skipped > 0 ? "partial" : "failed";
  const finalDatabase = openLectureOsDatabase(lectureOsDatabasePath);
  finalDatabase.prepare(`
    UPDATE sync_runs SET status = ?, imported_count = ?, skipped_count = ?, failed_count = ?,
      error_json = ?, finished_at = ? WHERE id = ?
  `).run(
    status, summary.imported, summary.skipped, summary.failed,
    summary.failures.length ? JSON.stringify(summary.failures) : null,
    new Date().toISOString(), syncRunId,
  );
  finalDatabase.close();
  return summary;
}

export function normalizedLectureHash(input: NormalizedLectureInput): string {
  const stable = {
    schemaVersion: input.schemaVersion,
    source: { provider: input.source.provider, externalId: input.source.externalId },
    lecture: input.lecture,
    audio: input.audio,
    transcript: input.transcript,
    altSummary: input.altSummary,
  };
  return createHash("sha256").update(JSON.stringify(stable)).digest("hex");
}

export async function withRetries<T>(
  operation: () => T | Promise<T>,
  retryCount: number,
  retryDelayMs: number,
): Promise<T> {
  let lastError: unknown;
  for (let attempt = 0; attempt <= retryCount; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      if (attempt < retryCount && retryDelayMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, retryDelayMs * (attempt + 1)));
      }
    }
  }
  throw lastError;
}
