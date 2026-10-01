import { readFileSync } from "node:fs";

import { DEFAULT_LECTURE_OS_DB, openLectureOsDatabase } from "../../db/src/index.ts";
import { catalogDriveFile, ingestLocalPdf } from "./index.ts";

const [command, first, second] = process.argv.slice(2);
const database = openLectureOsDatabase(process.env.LECTURE_OS_DB || DEFAULT_LECTURE_OS_DB);
try {
  if (command === "ingest-local") {
    if (!first || !second) throw new Error("Usage: cli.ts ingest-local <pdf-path> <course-name>");
    console.log(JSON.stringify(ingestLocalPdf(database, { path: first, courseName: second }), null, 2));
  } else if (command === "catalog-drive") {
    if (!first) throw new Error("Usage: cli.ts catalog-drive <manifest.json>");
    const items = JSON.parse(readFileSync(first, "utf8"));
    console.log(JSON.stringify(items.map((item: unknown) => catalogDriveFile(database, item as never)), null, 2));
  } else {
    throw new Error("Usage: cli.ts <ingest-local|catalog-drive> ...");
  }
} finally {
  database.close();
}
