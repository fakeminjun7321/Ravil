import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { openLectureOsDatabase } from "../packages/db/src/index.ts";
import { configureTimetable } from "../packages/classification/src/index.ts";
import { catalogDriveFile } from "../packages/materials/src/index.ts";

test("catalogs Drive metadata idempotently and versions a changed source", () => {
  const directory = mkdtempSync(join(tmpdir(), "lecture-os-materials-"));
  const database = openLectureOsDatabase(join(directory, "lecture-os.db"));
  try {
    configureTimetable(database, {
      semester: { name: "2026-2", startsAt: "2026-09-01", endsAt: "2026-12-31" },
      courses: [{ name: "프실" }],
    });
    const source = {
      externalId: "drive-file-1",
      externalUrl: "https://drive.google.com/file/d/drive-file-1/view",
      fileName: "LEC3.pdf",
      mimeType: "application/pdf",
      modifiedAt: "2026-09-08T00:00:00Z",
      courseName: "프실",
    };
    const first = catalogDriveFile(database, source);
    const duplicate = catalogDriveFile(database, source);
    const changed = catalogDriveFile(database, { ...source, modifiedAt: "2026-09-09T00:00:00Z" });
    assert.equal(first.created, true);
    assert.equal(duplicate.created, false);
    assert.equal(duplicate.materialId, first.materialId);
    assert.equal(changed.version, 2);
    assert.equal(database.prepare("SELECT COUNT(*) AS count FROM course_materials").get().count, 2);
  } finally {
    database.close();
  }
});
