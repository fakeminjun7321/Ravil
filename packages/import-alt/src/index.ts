import { loadNormalizedLecture } from "../../../src/alt-adapter.mjs";
import { analyzeEvidenceCandidates } from "../../../src/phase-0-analysis.mjs";
import {
  openLectureOsDatabase,
  persistNormalizedLecture,
} from "../../db/src/index.ts";
import type { ImportResult, NormalizedLectureInput } from "../../types/src/index.ts";

export function importAltLecture(
  noteId: string,
  options: { altDatabasePath?: string; lectureOsDatabasePath?: string } = {},
): ImportResult {
  const normalized = loadNormalizedLecture(
    noteId,
    options.altDatabasePath,
  ) as NormalizedLectureInput;
  return importNormalizedAltLecture(normalized, options.lectureOsDatabasePath);
}

export function importNormalizedAltLecture(
  normalized: NormalizedLectureInput,
  lectureOsDatabasePath?: string,
): ImportResult {
  const analysis = analyzeEvidenceCandidates(normalized);
  const candidates = analysis.candidates.map((candidate) => ({
    ...candidate,
    evidence: {
      ...candidate.evidence,
      segmentId: normalized.transcript.segments.find(
        (segment) =>
          segment.startMs === candidate.evidence.startMs &&
          segment.endMs === candidate.evidence.endMs,
      )?.id,
    },
  }));
  const database = openLectureOsDatabase(lectureOsDatabasePath);
  try {
    return persistNormalizedLecture(database, normalized, candidates);
  } finally {
    database.close();
  }
}
