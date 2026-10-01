import {
  DEFAULT_LECTURE_OS_DB,
  inspectDatabase,
  listLectures,
  openLectureOsDatabase,
} from "../../db/src/index.ts";
import { importAltLecture } from "./index.ts";

const [command, noteId] = process.argv.slice(2);
const databasePath = process.env.LECTURE_OS_DB || DEFAULT_LECTURE_OS_DB;

if (command === "import") {
  if (!noteId) throw new Error("Usage: npm run phase1:import -- <ALT_NOTE_ID>");
  console.log(JSON.stringify(importAltLecture(noteId, { lectureOsDatabasePath: databasePath }), null, 2));
} else if (command === "inspect") {
  const database = openLectureOsDatabase(databasePath);
  try {
    console.log(JSON.stringify({ databasePath, ...inspectDatabase(database), lectures: listLectures(database) }, null, 2));
  } finally {
    database.close();
  }
} else {
  throw new Error("Usage: cli.ts <import|inspect> [ALT_NOTE_ID]");
}
