import { pathToFileURL } from "node:url";

import { loadNormalizedLecture } from "./alt-adapter.mjs";

const RULES = [
  {
    type: "exam_mention",
    pattern: /(?:시험|중간고사|기말고사|퀴즈|\bexams?\b|\bmidterms?\b|\bfinal\s+exams?\b|\bquizzes?\b)/iu,
  },
  {
    type: "professor_emphasis",
    pattern: /(?:중요|핵심|꼭\s*알아|기억|주의|다시\s*설명|important|key\s+point|remember|pay\s+attention)/iu,
  },
  {
    type: "assignment",
    pattern: /(?:과제|숙제|제출|다음\s*주까지|읽어\s*오|assignment|homework|due\s+(?:by|on)|by\s+next\s+(?:class|week)|read\s+.+\s+for\s+next)/iu,
  },
];

export function analyzeEvidenceCandidates(lecture) {
  const candidates = [];
  for (const segment of lecture.transcript.segments) {
    for (const rule of RULES) {
      if (!rule.pattern.test(segment.text)) continue;
      candidates.push({
        id: `${rule.type}:${segment.id}`,
        type: rule.type,
        status: "candidate",
        text: segment.text,
        evidence: {
          sourceType: "transcript",
          sourceId: segment.provenance.externalSourceId,
          startMs: segment.startMs,
          endMs: segment.endMs,
          quote: segment.text,
          provider: "alt",
        },
      });
    }
  }

  return {
    schemaVersion: 1,
    lecture: {
      externalId: lecture.lecture.externalId,
      title: lecture.lecture.title,
    },
    summary: lecture.altSummary.text
      ? {
          status: "provider_generated_unverified",
          text: lecture.altSummary.text,
          source: {
            provider: "alt",
            externalSourceId: lecture.altSummary.externalId,
          },
        }
      : {
          status: "missing",
          text: "",
          source: null,
        },
    candidates,
  };
}

export function inspectAnalysis(analysis) {
  const counts = Object.fromEntries(RULES.map((rule) => [rule.type, 0]));
  for (const candidate of analysis.candidates) counts[candidate.type] += 1;
  return {
    title: analysis.lecture.title,
    summaryStatus: analysis.summary.status,
    summaryChars: analysis.summary.text.length,
    candidateCounts: counts,
    evidenceComplete: analysis.candidates.every(
      (candidate) =>
        Number.isFinite(candidate.evidence.startMs) &&
        Number.isFinite(candidate.evidence.endMs) &&
        candidate.evidence.sourceId,
    ),
  };
}

function runCli() {
  const [command, noteId] = process.argv.slice(2);
  if (!noteId || !["inspect", "analyze"].includes(command)) {
    throw new Error("Usage: node src/phase-0-analysis.mjs <inspect|analyze> <ALT_NOTE_ID>");
  }
  const analysis = analyzeEvidenceCandidates(loadNormalizedLecture(noteId));
  console.log(
    JSON.stringify(command === "inspect" ? inspectAnalysis(analysis) : analysis, null, 2),
  );
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    runCli();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
