import { readFileSync } from "node:fs";

import { DEFAULT_LECTURE_OS_DB, openLectureOsDatabase } from "../../db/src/index.ts";
import { classifyAllLectures, configureTimetable } from "./index.ts";

const [command, configPath] = process.argv.slice(2);
const databasePath = process.env.LECTURE_OS_DB || DEFAULT_LECTURE_OS_DB;
const database = openLectureOsDatabase(databasePath);
try {
  if (command === "configure") {
    if (!configPath) throw new Error("Usage: npm run phase3:configure -- <timetable.json>");
    const config = JSON.parse(readFileSync(configPath, "utf8"));
    console.log(JSON.stringify(configureTimetable(database, config), null, 2));
  } else if (command === "classify") {
    console.log(JSON.stringify(classifyAllLectures(database), null, 2));
  } else {
    throw new Error("Usage: cli.ts <configure|classify> [timetable.json]");
  }
} finally {
  database.close();
}
