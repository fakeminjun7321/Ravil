import { DEFAULT_LECTURE_OS_DB, openLectureOsDatabase } from "../../db/src/index.ts";
import { generateAllLectureIntelligence, generateLectureIntelligence } from "./index.ts";

const [command, lectureId] = process.argv.slice(2);
const database = openLectureOsDatabase(process.env.LECTURE_OS_DB || DEFAULT_LECTURE_OS_DB);
try {
  const results = command === "lecture" ? [generateLectureIntelligence(database, lectureId)] : generateAllLectureIntelligence(database);
  console.log(JSON.stringify(results.map((result: any) => ({
    lectureId: result.lecture.id, summaryStatus: result.summary.status,
    keyConcepts: result.keyConcepts.length, professorEmphasis: result.professorEmphasis.length,
    examMentions: result.examMentions.length, assignments: result.assignments.length,
    studentEmphasis: result.studentEmphasis.length,
    evidenceReferencesValid: result.verification.evidenceReferencesValid,
  })), null, 2));
} finally { database.close(); }
