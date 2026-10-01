import { randomUUID } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";

const PIPELINE_VERSION = "intelligence-rules-v1";
const STOPWORDS = new Set(`basically sort something able course point need guy sense mean means time kind same small moving change plus first start line makes make move case happens other every again doing really actually just thing things okay yeah right maybe what this that with from have has will would there these which when then about into your they them their could should because where using used also more some only want were been does did here going very let now over don way why much idea than always project and the for are not but can was one like how out use our all you its get got see look know think say said give take well even`.split(/\s+/));

export function generateLectureIntelligence(database: DatabaseSync, lectureId: string): any {
  const lecture = database.prepare("SELECT id, title, course_id AS courseId FROM lectures WHERE id = ?")
    .get(lectureId) as { id: string; title: string; courseId: string | null } | undefined;
  if (!lecture) throw new Error(`Lecture not found: ${lectureId}`);
  const segments = database.prepare(`SELECT id, start_ms AS startMs, end_ms AS endMs, text FROM transcript_segments WHERE lecture_id = ? ORDER BY ordinal`)
    .all(lectureId) as Array<{ id: string; startMs: number; endMs: number; text: string }>;
  const evidenceRows = database.prepare(`SELECT kind, quote, start_ms AS startMs, end_ms AS endMs, transcript_segment_id AS transcriptSegmentId FROM evidence WHERE lecture_id = ? AND pipeline_version = 'rules-v1' ORDER BY start_ms`)
    .all(lectureId) as Array<{ kind: string; quote: string; startMs: number; endMs: number; transcriptSegmentId: string }>;
  const sourceArtifact = database.prepare(`SELECT payload_json AS payload FROM ai_artifacts WHERE lecture_id = ? AND artifact_type = 'alt_summary_and_candidates' ORDER BY created_at DESC LIMIT 1`)
    .get(lectureId) as { payload: string } | undefined;
  const summaryText = sourceArtifact ? JSON.parse(sourceArtifact.payload)?.altSummary?.text ?? "" : "";
  const concepts = extractConcepts(segments, evidenceRows);
  const materialSignals = lecture.courseId ? extractStudentEmphasis(database, lecture.courseId) : [];
  const priorities = concepts.map((concept: any) => {
    const lower = concept.name.toLocaleLowerCase();
    let score = Math.min(concept.mentionCount, 20);
    if (evidenceRows.some((row) => row.kind === "professor_emphasis" && row.quote.toLocaleLowerCase().includes(lower))) score += 25;
    if (evidenceRows.some((row) => row.kind === "exam_mention" && row.quote.toLocaleLowerCase().includes(lower))) score += 40;
    if (evidenceRows.some((row) => row.kind === "assignment" && row.quote.toLocaleLowerCase().includes(lower))) score += 10;
    if (materialSignals.some((signal: any) => signal.text.toLocaleLowerCase().includes(lower))) score += 15;
    return { concept: concept.name, score, level: score >= 40 ? "HIGH" : score >= 20 ? "MEDIUM" : "LOW", reasons: [`mentions:${concept.mentionCount}`] };
  }).sort((a: any, b: any) => b.score - a.score);
  const toCandidate = (kind: string) => evidenceRows.filter((row) => row.kind === kind).map((row) => ({ status: "candidate", text: row.quote, evidence: transcriptEvidence(row) }));
  const artifact = {
    schemaVersion: 1,
    pipelineVersion: PIPELINE_VERSION,
    lecture: { id: lecture.id, title: lecture.title },
    summary: { status: summaryText ? "provider_generated_unverified" : "missing", text: summaryText, source: summaryText ? { provider: "alt", type: "meeting_notes" } : null },
    keyConcepts: concepts,
    professorEmphasis: toCandidate("professor_emphasis"),
    examMentions: toCandidate("exam_mention"),
    assignments: toCandidate("assignment"),
    studentEmphasis: materialSignals,
    studyPriorities: priorities,
    verification: { evidenceReferencesValid: validateEvidence(database, lectureId, evidenceRows), semanticAccuracy: "not_verified", summaryCoverage: "not_verified" },
  };
  if (!artifact.verification.evidenceReferencesValid) throw new Error("Evidence validation failed");
  database.prepare(`INSERT INTO ai_artifacts (id, lecture_id, artifact_type, pipeline_version, payload_json, created_at) VALUES (?, ?, 'lecture_intelligence', ?, ?, ?) ON CONFLICT(lecture_id, artifact_type, pipeline_version) DO UPDATE SET payload_json = excluded.payload_json, created_at = excluded.created_at`)
    .run(randomUUID(), lectureId, PIPELINE_VERSION, JSON.stringify(artifact), new Date().toISOString());
  return artifact;
}

export function generateAllLectureIntelligence(database: DatabaseSync): any[] {
  return (database.prepare("SELECT id FROM lectures ORDER BY lecture_date, created_at").all() as Array<{ id: string }>).map((lecture) => generateLectureIntelligence(database, lecture.id));
}

export function getLectureIntelligence(database: DatabaseSync, lectureId: string): object | null {
  const row = database.prepare(`SELECT payload_json AS payload FROM ai_artifacts WHERE lecture_id = ? AND artifact_type = 'lecture_intelligence' AND pipeline_version = ?`)
    .get(lectureId, PIPELINE_VERSION) as { payload: string } | undefined;
  return row ? JSON.parse(row.payload) : null;
}

function extractConcepts(segments: Array<{ id: string; startMs: number; endMs: number; text: string }>, evidenceRows: Array<{ quote: string }>): any[] {
  const counts = new Map<string, { count: number; segments: typeof segments }>();
  for (const segment of segments) {
    const unique = new Set((segment.text.toLocaleLowerCase().match(/[\p{L}][\p{L}\p{N}-]{2,}/gu) ?? []).filter((token) => !STOPWORDS.has(token)));
    for (const token of unique) {
      const current = counts.get(token) ?? { count: 0, segments: [] };
      current.count += 1;
      if (current.segments.length < 3) current.segments.push(segment);
      counts.set(token, current);
    }
  }
  return [...counts.entries()].filter(([, value]) => value.count >= 4).sort((a, b) => b[1].count - a[1].count).slice(0, 10).map(([name, value]) => ({
    name, mentionCount: value.count,
    evidence: value.segments.map((segment) => ({ sourceType: "transcript", transcriptSegmentId: segment.id, startMs: segment.startMs, endMs: segment.endMs, quote: segment.text })),
    emphasisSignalCount: evidenceRows.filter((row) => row.quote.toLocaleLowerCase().includes(name)).length,
  }));
}

function extractStudentEmphasis(database: DatabaseSync, courseId: string): any[] {
  const pages = database.prepare(`SELECT p.material_id AS materialId, p.page_number AS pageNumber, p.text FROM material_pages p JOIN course_materials m ON m.id = p.material_id WHERE m.course_id = ?`)
    .all(courseId) as Array<{ materialId: string; pageNumber: number; text: string }>;
  const pattern = /(?:★+|시험|중요|외우|헷갈|주의)/u;
  return pages.filter((page) => pattern.test(page.text)).map((page) => ({ status: "candidate", kind: "text_marker", text: page.text.match(pattern)?.[0] ?? "", evidence: { sourceType: "material_page", materialId: page.materialId, pageNumber: page.pageNumber } }));
}

function transcriptEvidence(row: { transcriptSegmentId: string; startMs: number; endMs: number; quote: string }): object {
  return { sourceType: "transcript", transcriptSegmentId: row.transcriptSegmentId, startMs: row.startMs, endMs: row.endMs, quote: row.quote };
}

function validateEvidence(database: DatabaseSync, lectureId: string, rows: Array<{ transcriptSegmentId: string }>): boolean {
  const valid = new Set((database.prepare("SELECT id FROM transcript_segments WHERE lecture_id = ?").all(lectureId) as Array<{ id: string }>).map((row) => row.id));
  return rows.every((row) => valid.has(row.transcriptSegmentId));
}
