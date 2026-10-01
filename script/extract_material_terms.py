#!/usr/bin/env python3
"""Extract local worksheet vocabulary candidates with PDF-page provenance.

The output is a private review list. It is not automatically used as an ASR
prompt or as training data because unreviewed terms can bias transcription.
"""

import argparse
import collections
import json
import os
import re
import sqlite3
import unicodedata
from pathlib import Path


TOKEN = re.compile(r"[가-힣]{2,10}|[A-Za-z][A-Za-z0-9-]{2,20}")
STOP = {"그리고", "그러나", "따라서", "다음", "대한", "때문에", "문제", "정답", "해설",
        "자료", "내용", "경우", "위하여", "있는", "없는", "있다", "없다", "한다", "한다면",
        "것은", "것을", "것이다", "에서", "으로", "이를", "통해", "다음과", "문장을",
        "이다", "풀이", "학년", "학번", "이름", "대비", "저작권은", "허락", "복제를",
        "which", "that", "this", "these", "those", "with", "from", "about", "into",
        "the", "and", "are", "for", "people", "they", "how", "can", "some", "was", "will",
        "were", "have", "has", "had", "your", "their", "them", "what", "when", "where",
        "all", "copyright", "rights", "reserved"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--subject", required=True)
    parser.add_argument("--match", nargs="+", required=True,
                        help="filename substrings that belong to this subject")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.resolve() == args.database.resolve() or args.output.exists():
        parser.error("output must be a new file separate from the Ravil database")
    os.umask(0o077)
    database = sqlite3.connect(f"file:{args.database.resolve()}?mode=ro", uri=True)
    database.row_factory = sqlite3.Row
    rows = database.execute("""
        WITH latest AS (
          SELECT m.* FROM course_materials m
          WHERE m.status = 'ingested' AND (
            m.provider != 'goodnotes_drive_pdf' OR m.version = (
              SELECT MAX(v.version) FROM course_materials v
              WHERE v.provider = m.provider AND v.external_id = m.external_id
            )
          )
        )
        SELECT m.id AS material_id, m.file_name, p.page_number,
               COALESCE(r.corrected_text, p.text) AS page_text
        FROM latest m JOIN material_pages p ON p.material_id = m.id
        LEFT JOIN material_page_ocr_review r ON r.page_id = p.id AND r.approved_at IS NOT NULL
    """).fetchall()
    selectors = [unicodedata.normalize("NFKC", value).casefold() for value in args.match]
    counts = collections.Counter()
    page_counts = collections.Counter()
    provenance = collections.defaultdict(list)
    matched_materials = set()
    matched_pages = 0
    for row in rows:
        name = unicodedata.normalize("NFKC", row["file_name"]).casefold()
        if not any(selector in name for selector in selectors):
            continue
        text = unicodedata.normalize("NFKC", row["page_text"] or "")
        if not text.strip():
            continue
        matched_materials.add(row["material_id"])
        matched_pages += 1
        seen_on_page = set()
        for match in TOKEN.finditer(text):
            term = match.group().casefold()
            if term in STOP or term.isnumeric():
                continue
            counts[term] += 1
            if term not in seen_on_page and len(provenance[term]) < 4:
                provenance[term].append({"materialID": row["material_id"],
                                         "fileName": row["file_name"],
                                         "page": row["page_number"]})
            seen_on_page.add(term)
        page_counts.update(seen_on_page)
    candidates = [{"term": term, "occurrences": count,
                   "pages": page_counts[term], "examples": provenance[term]}
                  for term, count in counts.most_common()
                  if count >= 2 and (matched_pages < 5 or page_counts[term] / matched_pages < 0.7)]
    result = {"subject": args.subject, "status": "unreviewed candidates",
              "materialVersions": len(matched_materials), "textPages": matched_pages,
              "candidates": candidates[:200],
              "note": "Only current material versions, extractable text and approved OCR are used. Review before ASR prompting or training."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.output.chmod(0o600)
    print(json.dumps({"subject": args.subject, "materials": len(matched_materials),
                      "textPages": matched_pages, "candidates": len(result["candidates"])},
                     ensure_ascii=False))


if __name__ == "__main__":
    main()
