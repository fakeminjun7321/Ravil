# Lecture OS Phase 1 — foundation and persistence

## Implemented

- pnpm workspace and Turborepo layout for `apps/*` and `packages/*`.
- Shared TypeScript contracts for normalized lectures and import results.
- Private SQLite persistence for lectures, external sources, audio references, transcript
  segments, evidence, versioned AI artifacts, and import runs.
- Alt importer that keeps internal UUIDs separate from Alt IDs.
- Idempotent re-import keyed by `(provider, external_id)`.
- Timestamped rule-candidate evidence linked by foreign key to stored transcript segments.
- Localhost-only read API:
  - `GET /health`
  - `GET /lectures`

## Actual-data verification

Real Alt note: `019f34ce-9c4d-755d-9705-d1bd80a5cae5`.

- First import: `created: true`.
- Second import: `created: false`.
- Both imports returned the same internal Lecture ID and ExternalSource ID.
- Persisted state after reopening the database in a separate process:
  - lectures: 1
  - external sources: 1
  - transcript segments: 1,721
  - evidence candidates: 7
  - versioned artifacts: 1
  - completed import runs: 2
  - failed import runs: 0
  - orphan evidence rows: 0
- SQLite integrity check: `ok`.
- Evidence-to-segment quote/timestamp mismatches: 0.
- Raw normalized payload retained: 510,467 characters.
- Audio reference retained: 112,908,860 bytes.
- Database file permissions: owner-only `0600`.

The seven evidence rows are rule-generated candidates, not semantically confirmed claims. One is
the known STT `exams`/`examples` ambiguity and must remain unconfirmed.

## Commands

```bash
npm run phase1:import -- <ALT_NOTE_ID>
npm run phase1:inspect
npm run api
curl http://127.0.0.1:4310/health
curl http://127.0.0.1:4310/lectures
```

The default private database is `data/lecture-os.db`; `data/` is ignored by Git.

## Verification levels

- Implemented: schema, Alt import, idempotency, persistence, evidence foreign keys, and local API.
- Unit-verified: eight focused tests pass.
- Local-data-verified: a real 1,721-segment Alt lecture was imported twice and reopened.
- API-verified: localhost health and lecture-list requests returned the persisted real lecture.
- Not verified: authentication, PostgreSQL/Supabase migration, cloud storage, concurrent workers,
  remote deployment, and any mobile user path.

## Observed issue during verification

The system `sqlite3 -readonly` command could not open the closed WAL-mode database for the final
inspection. No write was retried. The same snapshot opened successfully with SQLite URI
`immutable=1`, after which integrity, foreign keys, counts, and evidence matches were checked.

Before adding concurrent workers, the project must choose and test one supported read strategy:
normal application connections that understand WAL, or explicit immutable snapshots created only
after checkpointing. `immutable=1` must not be used against a database that may still be changing.

## Phase 1 boundary

The API is intentionally bound to `127.0.0.1` and has no authentication. It is a local development
interface, not a production or multi-user service. Phase 1 does not claim deployed or user-ready
status.

Automatic new/changed-only ingestion continues in
[`phase-2-alt-sync.md`](./phase-2-alt-sync.md).
