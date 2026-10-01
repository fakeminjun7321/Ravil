import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { openLectureOsDatabase } from "../packages/db/src/index.ts";
import { generateLectureIntelligence } from "../packages/intelligence/src/index.ts";

test("persists evidence-valid intelligence idempotently", () => {
  const database = openLectureOsDatabase(join(mkdtempSync(join(tmpdir(), "lecture-os-intelligence-")), "db.sqlite"));
  try {
    database.prepare("INSERT INTO lectures (id,title,lecture_date,source_status,created_at,updated_at) VALUES ('l1','자료구조','2026-09-21','ready','x','x')").run();
    const insert = database.prepare("INSERT INTO transcript_segments (id,lecture_id,external_source_id,provider_segment_id,ordinal,start_ms,end_ms,text,speaker_id) VALUES (?,?,?,?,?,?,?,?,?)");
    database.prepare("INSERT INTO external_sources (id,lecture_id,provider,external_id,raw_payload_json,imported_at) VALUES ('s1','l1','alt','a1','{}','x')").run();
    for (let i=0;i<5;i++) insert.run(`t${i}`,'l1','s1',`p${i}`,i,i*1000,(i+1)*1000,`going going AVL tree rotation function ${i}`,null);
    database.prepare("INSERT INTO evidence (id,lecture_id,transcript_segment_id,kind,quote,start_ms,end_ms,pipeline_version) VALUES ('e1','l1','t0','professor_emphasis','AVL tree rotation is important',0,1000,'rules-v1')").run();
    database.prepare("INSERT INTO ai_artifacts (id,lecture_id,artifact_type,pipeline_version,payload_json,created_at) VALUES ('a1','l1','alt_summary_and_candidates','rules-v1',?, 'x')")
      .run(JSON.stringify({ altSummary: { text: "AVL 요약" } }));
    const first = generateLectureIntelligence(database,'l1');
    const second = generateLectureIntelligence(database,'l1');
    assert.equal(first.verification.evidenceReferencesValid,true);
    assert.equal(second.keyConcepts.some((concept) => concept.name === 'going'),false);
    assert.equal(database.prepare("SELECT COUNT(*) AS count FROM ai_artifacts WHERE artifact_type='lecture_intelligence'").get().count,1);
  } finally { database.close(); }
});
