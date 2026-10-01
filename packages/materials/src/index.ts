import { createHash, randomUUID } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { basename } from "node:path";
import { execFileSync } from "node:child_process";
import type { DatabaseSync } from "node:sqlite";

export interface DriveCatalogInput {
  externalId: string;
  externalUrl: string;
  fileName: string;
  mimeType: string;
  modifiedAt?: string;
  courseName?: string;
}

export function catalogDriveFile(database: DatabaseSync, input: DriveCatalogInput): object {
  const courseId = input.courseName ? findCourseId(database, input.courseName) : null;
  const existing = database.prepare(`
    SELECT id, version FROM course_materials
    WHERE provider = 'google_drive' AND external_id = ? AND source_modified_at IS ?
    ORDER BY version DESC LIMIT 1
  `).get(input.externalId, input.modifiedAt ?? null) as { id: string; version: number } | undefined;
  if (existing) return { materialId: existing.id, version: existing.version, created: false, status: "cataloged" };
  const version = nextVersion(database, "google_drive", input.externalId);
  const id = randomUUID();
  database.prepare(`
    INSERT INTO course_materials
      (id, course_id, provider, external_id, external_url, file_name, mime_type,
       source_modified_at, version, status, ingested_at)
    VALUES (?, ?, 'google_drive', ?, ?, ?, ?, ?, ?, 'cataloged', ?)
  `).run(
    id, courseId, input.externalId, input.externalUrl, input.fileName, input.mimeType,
    input.modifiedAt ?? null, version, new Date().toISOString(),
  );
  return { materialId: id, version, created: true, status: "cataloged" };
}

export function ingestLocalPdf(
  database: DatabaseSync,
  input: { path: string; courseName: string; externalId?: string },
): object {
  const bytes = readFileSync(input.path);
  const contentHash = createHash("sha256").update(bytes).digest("hex");
  const externalId = input.externalId ?? input.path;
  const existing = database.prepare(`
    SELECT id, version, page_count AS pageCount, has_text_layer AS hasTextLayer
    FROM course_materials
    WHERE provider = 'local_goodnotes_export' AND external_id = ? AND content_hash = ?
    ORDER BY version DESC LIMIT 1
  `).get(externalId, contentHash) as { id: string; version: number; pageCount: number; hasTextLayer: number } | undefined;
  if (existing) {
    return {
      materialId: existing.id, version: existing.version, created: false,
      pageCount: existing.pageCount, hasTextLayer: Boolean(existing.hasTextLayer),
    };
  }

  const pageCount = pdfPageCount(input.path);
  const pages = Array.from({ length: pageCount }, (_, index) => {
    const pageNumber = index + 1;
    const text = execFileSync("pdftotext", ["-f", String(pageNumber), "-l", String(pageNumber), input.path, "-"], {
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
    }).replace(/\f/g, "").trim();
    return { pageNumber, text, textHash: createHash("sha256").update(text).digest("hex") };
  });
  const hasTextLayer = pages.some((page) => page.text.length > 0);
  const id = randomUUID();
  const version = nextVersion(database, "local_goodnotes_export", externalId);
  const courseId = findCourseId(database, input.courseName);
  database.exec("BEGIN IMMEDIATE");
  try {
    database.prepare(`
      INSERT INTO course_materials
        (id, course_id, provider, external_id, file_name, mime_type, local_path,
         content_hash, source_modified_at, version, page_count, has_text_layer, status, ingested_at)
      VALUES (?, ?, 'local_goodnotes_export', ?, ?, 'application/pdf', ?, ?, ?, ?, ?, ?, 'ingested', ?)
    `).run(
      id, courseId, externalId, basename(input.path), input.path, contentHash,
      statSync(input.path).mtime.toISOString(), version, pageCount, hasTextLayer ? 1 : 0,
      new Date().toISOString(),
    );
    const insertPage = database.prepare(`
      INSERT INTO material_pages (id, material_id, page_number, text, text_hash)
      VALUES (?, ?, ?, ?, ?)
    `);
    for (const page of pages) insertPage.run(randomUUID(), id, page.pageNumber, page.text, page.textHash);
    database.exec("COMMIT");
  } catch (error) {
    database.exec("ROLLBACK");
    throw error;
  }
  return { materialId: id, version, created: true, pageCount, hasTextLayer, contentHash };
}

function pdfPageCount(path: string): number {
  const output = execFileSync("pdfinfo", [path], { encoding: "utf8" });
  const match = /^Pages:\s+(\d+)$/m.exec(output);
  if (!match) throw new Error(`Could not determine PDF page count: ${path}`);
  return Number(match[1]);
}

function findCourseId(database: DatabaseSync, courseName: string): string {
  const row = database.prepare("SELECT id FROM courses WHERE name = ? ORDER BY rowid LIMIT 1")
    .get(courseName) as { id: string } | undefined;
  if (!row) throw new Error(`Course not found: ${courseName}`);
  return row.id;
}

function nextVersion(database: DatabaseSync, provider: string, externalId: string): number {
  const row = database.prepare(
    "SELECT COALESCE(MAX(version), 0) + 1 AS version FROM course_materials WHERE provider = ? AND external_id = ?",
  ).get(provider, externalId) as { version: number };
  return row.version;
}
