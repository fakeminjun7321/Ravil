# Lecture OS Phase 4 — Drive and PDF materials

## Implemented

- Connected Google Drive discovery through the existing Drive connector.
- Drive-file metadata catalog with provider ID, URL, MIME type, modified time, course link, and
  version tracking.
- Local Goodnotes/PDF-export ingestion with SHA-256 content versioning.
- PDF page count and text-layer detection using Poppler.
- Page-by-page text extraction and page text hashes.
- Duplicate-content skip and changed-source version increment.
- Material and page-read API endpoints:
  - `GET /materials`
  - `GET /materials/:materialId/pages/:pageNumber`

## Actual Drive discovery

The connected Drive contains a `GoodNotes` folder. Relevant current-course folders and files were
found, including `Programing`, `Astronomy`, `Mathematics`, `Physics`, `Korean`, and `English`.

Phase 4 cataloged this real Drive PDF as course `프실`:

- Drive ID: `1fGp2j2wx0DfgyXr0l1S2OISoIZ5bC--_`
- title: `[LEC3] 객체지향 게임 개발.pdf`
- MIME type: `application/pdf`
- Drive-reported size: 261,585 bytes
- status: `cataloged`

The connector returned a streamed file reference, but the Drive bytes were not materialized into
the workspace during this run. Therefore the Drive copy's pages are not claimed as ingested.

## Actual local PDF ingestion

A local PDF with the same title was found under the user's `프실/LEC3` folder. It is not assumed
to be identical to the Drive file because its size is 250,396 bytes.

- provider: `local_goodnotes_export`
- linked course: `프실`
- SHA-256: `7e4b8d43e91975885d76c71fb0b7dd51d9b998b98718f2ead30880ef359f84c1`
- pages: 3
- text layer: present
- page rows stored: 3
- duplicate second import: skipped

All three pages were rendered and visually inspected. They are readable A4 pages with intact
Korean text, code blocks, diagrams, tables, and answer lines; no clipping or broken glyphs were
observed.

The page API returned page 1 with 1,947 extracted characters and a stable page-text hash.

## Verification levels

- Implemented: catalog, PDF ingestion, versioning, page indexing, and page API.
- Unit-verified: 15 focused tests pass, including Drive metadata idempotency and version updates.
- Local-PDF-verified: three pages extracted, rendered, inspected, stored, and retrieved through API.
- Drive-metadata-verified: the real Drive file and GoodNotes folder were read from the connector.
- Not verified: Drive file byte ingestion, automatic Drive polling, Goodnotes handwriting/OCR,
  original-versus-annotated PDF comparison, page-to-Lecture automatic matching, or live Drive
  revision download.

## Privacy and safety

- Drive was read only; no file was moved, shared, renamed, or modified.
- The real Drive manifest and local database live in Git-ignored `data/`.
- The local PDF and Drive PDF remain separate source versions.

Evidence-backed lecture analysis continues in
[`phase-5-lecture-intelligence.md`](./phase-5-lecture-intelligence.md).
