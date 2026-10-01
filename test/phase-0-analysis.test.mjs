import assert from "node:assert/strict";
import test from "node:test";

import { analyzeEvidenceCandidates, inspectAnalysis } from "../src/phase-0-analysis.mjs";

const lecture = {
  lecture: { externalId: "lecture-1", title: "자료구조" },
  altSummary: { externalId: "summary-1", text: "AVL Tree 요약" },
  transcript: {
    segments: [
      {
        id: "segment-1",
        startMs: 1000,
        endMs: 2500,
        text: "이 부분은 시험에 중요합니다.",
        provenance: { externalSourceId: "transcript-1" },
      },
      {
        id: "segment-2",
        startMs: 3000,
        endMs: 4500,
        text: "과제는 다음 주까지 제출하세요.",
        provenance: { externalSourceId: "transcript-1" },
      },
      {
        id: "segment-3",
        startMs: 5000,
        endMs: 6000,
        text: "This is only an example.",
        provenance: { externalSourceId: "transcript-1" },
      },
    ],
  },
};

test("extracts evidence-backed candidates without promoting them to facts", () => {
  const analysis = analyzeEvidenceCandidates(lecture);
  assert.equal(analysis.candidates.length, 3);
  assert.ok(analysis.candidates.every((candidate) => candidate.status === "candidate"));
  assert.deepEqual(analysis.candidates[0].evidence, {
    sourceType: "transcript",
    sourceId: "transcript-1",
    startMs: 1000,
    endMs: 2500,
    quote: "이 부분은 시험에 중요합니다.",
    provider: "alt",
  });
});

test("does not confuse example with exam", () => {
  const analysis = analyzeEvidenceCandidates(lecture);
  assert.equal(
    analysis.candidates.some((candidate) => candidate.text === "This is only an example."),
    false,
  );
});

test("reports candidate counts and provider-summary verification state", () => {
  const inspection = inspectAnalysis(analyzeEvidenceCandidates(lecture));
  assert.deepEqual(inspection.candidateCounts, {
    exam_mention: 1,
    professor_emphasis: 1,
    assignment: 1,
  });
  assert.equal(inspection.summaryStatus, "provider_generated_unverified");
  assert.equal(inspection.evidenceComplete, true);
});
