# RAVIL project desk — 2026-10-17

final result: passed

This result covers the selected design and the local user paths listed below. It is not a production deployment, live AI/Google Calendar verification, or an iPhone/iPad PWA acceptance result.

## Scope and reference

The selected option is **03-project-desk.png**: forest/graphite surfaces, a narrow icon rail, project/subject tree, document with a note list, a separate date plan, and a project command field. The introduction and authentication screens use the same palette. Native Mac app code was not changed in this redesign.

- [Selected reference](/Users/minjun/Ravil/apps/website/design/ai-workspace-2026-10-13/03-project-desk.png)
- [Reference and final implementation, side by side](/Users/minjun/Ravil/output/project-desk-2026-10-17/comparison.png)
- [Actual desktop](/Users/minjun/Ravil/output/project-desk-2026-10-17/workspace-desktop.png)
- [Actual introduction](/Users/minjun/Ravil/output/project-desk-2026-10-17/home-desktop.png)
- [Actual authentication](/Users/minjun/Ravil/output/project-desk-2026-10-17/login-desktop.png)
- [Mobile introduction, login, editor and plan panel](/Users/minjun/Ravil/output/project-desk-2026-10-17/mobile-flow.png)

The same reference state was rendered with synthetic local data: exam project, physics, optics note, the 10.14 heading and its three tasks. The source image is 1487 × 1058. Chrome's existing 80% page zoom was preserved; task viewport compensation produced a measured 1487.5 × 1058.75 CSS-pixel surface. Captures were cropped to 1487 × 1058 without resizing page content. The capture tool's extra white canvas is excluded. Mobile checks used a 390 × 844 viewport; desktop Chrome's scrollbar consumes part of that width. Temporary viewport/CDP overrides were reset afterward.

## Visual review

Reference and implementation were inspected together after the last toolbar change. Header, project tree, document boundary, title/body hierarchy, date panel and bottom command placement match the selected composition. The final command field begins at y=933.76, compared with approximately y=934 in the reference. The document starts at x=501 with its text inset to x=529. There is no desktop overflow in the reference state; measured document width and scroll width are both 1487 CSS pixels.

No unresolved P0, P1 or P2 visual issues were found in the inspected states. Standard Tabler icons replace drawn preview icons; the existing R artwork is reused. Intentional product additions are the actual record type selector, new-note action, global subject access, account/profile actions and time-preview link. The existing table and math functions remain available alongside list/checklist controls. Mobile note tabs scroll horizontally, while project and plan panes open as separate sheets.

| Finding | Correction and observed result |
| --- | --- |
| Tiptap task items put the native checkbox above the text | Style the actual `li[data-checked]` DOM; final desktop/mobile rows align horizontally. |
| Toolbar/title/body positions and command height differed from the reference | Adjust note rail, typography and spacing; recaptured in the side-by-side comparison. |
| Command textarea had an unnecessary scrollbar | Match input height to font metrics; final capture is clear. |
| Reload discarded the current project when the saved owner matched the session | Restore context on first authenticated initialization; reload and re-login retained the project/subject. |
| Context editing only offered one project | Allow multiple checked subjects/projects; applying an unchanged two-project note preserved both links. |
| Mobile sheets exposed the editor behind them | Mark the background inert, focus the sheet, contain Tab navigation and close with Escape; actual AX state exposes the open sheet only. |
| Calendar download contained literal backslash line endings, and time allocation reordered edited tasks | Generate physical CRLF, fold UTF-8 content lines, and retain authored order. Downloaded a fresh file and inspected its three events. |

Calendar serialization follows [RFC 5545 section 3.1](https://www.rfc-editor.org/rfc/rfc5545#section-3.1). This format check does not prove an import into an external calendar.

## Verification levels

**Implemented**

- Introduction capture, dark login, project/subject desk and responsive sheets.
- `/노트`, `/찾기`, `/계획`, `/정리`, `/자료`, `/내보내기` dispatch into the existing record, search, planner, AI, file and export paths.
- One canonical record can be linked to several projects/subjects. Ordinary editing preserves all existing links.
- Project-scoped tasks and calendar requests; explicit empty task selections cannot schedule the whole account.
- Authenticated context restoration, original photo/PDF attachments, PDF/DOCX output, and calendar serialization corrections.

**Unit-verified**

- Website: 13/13 passed with `node --import tsx --test test/*.test.ts`.
- Cloud: 18/18 passed with `npm test`.
- Total: 31 focused tests, including authored order, dates/repetitions, calendar line format, owner-scoped selection, rich-note roundtrip, sync/conflict behavior, workspace gating and export delivery.
- Website `npm run check`: 46 files, 0 errors, 0 warnings, 0 hints. Cloud `npm run check` passed.
- Final Astro build passed. The existing warning for some chunks larger than 500 kB remains; no performance claim is made.

**Simulator-verified**

No iOS/iPadOS Simulator path was exercised. The backend was run using local Wrangler/Miniflare D1 and R2, with real application handlers and database writes, rather than mocked frontend responses.

**Physical-device-verified**

On this Mac in a dedicated background Chrome tab, using a synthetic local account and `http://127.0.0.1:4918`:

1. Entered text on the introduction screen while logged out, signed in, accepted the pending-record dialog and independently checked the persisted original body.
2. Switched projects/subjects, searched with `/찾기`, and confirmed unrelated records did not appear in the selected scope.
3. Ran `/계획` on the formatted optics note; local D1 stored three ordered tasks with 10.14 unchanged and repetitions 1/2/1. Completed the reading task once and twice; the UI and persisted data recorded 1/2 and 2/2. The fixture was reset to incomplete afterward.
4. Applied the two-project connection dialog without losing either link. Created a note through the command field, moved that same record to the personal project, and checked its persisted ID, body and context.
5. Uploaded an image and a two-page PDF through the actual file chooser. Downloaded their stored originals through authenticated file endpoints; both were byte-identical to the inputs. Reloading preserved the source and preview references.
6. Generated and downloaded PDF and Word via the real export endpoints. The PDF has four pages and preserves both source PDF pages and the Korean note. The DOCX contains three embedded PNGs and embedded fonts; a separate headless LibreOffice render shows the image, both source PDF pages and Korean text. Word itself was not opened.
7. Captured a 10.18 plan with repetitions 2/1, observed three nonoverlapping 30-minute blocks with five-minute breaks, downloaded `.ics`, and checked physical CRLF, event count, original order and UTC date/times. Old 10.14 tasks stayed unplaced and were not moved forward.
8. Exercised mobile project/plan open/close and Escape, and checked the accessibility state and horizontal overflow. This was desktop Chrome responsive testing, not an iPhone/iPad hardware test.
9. Signed out, reloaded the protected workspace and observed login. Signed in again and restored the account/project context.
10. Missing local AI binding returns a visible 503 configuration message and leaves the source intact. Unconnected Google Calendar returns the actual connection-required message; no external Google request was sent.

- [Persisted data/output proof](/Users/minjun/Ravil/output/project-desk-2026-10-17/verification-results.json)
- [Original attachment hashes](/Users/minjun/Ravil/output/project-desk-2026-10-17/attachment-proof.json)
- [Task/D1 proof](/Users/minjun/Ravil/output/project-desk-2026-10-17/persisted-plan-proof.json)
- [Downloaded calendar proof](/Users/minjun/Ravil/output/project-desk-2026-10-17/calendar-file-proof.json)
- [Word render](/Users/minjun/Ravil/output/project-desk-2026-10-17/word-render/all-pages.png)

## Not verified / 미검증

- Production deployment and production authentication/service bindings. Intentional requests to RAVIL production during this redesign: **0**.
- Live model responses and Google Calendar destination-side event creation/update with real credentials.
- iPhone/iPad PWA installation, touch keyboard, device storage and cross-device synchronization.
- Mac native app/cloud synchronization, OCR extraction and the full exam backup/archive lifecycle were not exercised in this redesign.
- Third-party calendar import and Microsoft Word opening were not exercised.

The localhost backend is isolated from production D1/R2. Its configuration contains a local-only secret and must not be deployed. The stable preview assets avoid rebuilding inside Wrangler's watched asset directory. The task Chrome tab remains logged into the synthetic account for review; temporary credential material is removed after checks. Existing unrelated Mac changes were preserved. No production DNS, deployment, billing or plan settings were changed.

Configured future deployment targets are Pages `ravil-website` and Worker `ravil-workspace-preview`, serving `ravil.app`/`www.ravil.app`. Updating those targets changes the public introduction/login/workspace assets and shared planning/calendar handling. This report does not authorize that update.

## Deployment follow-up

After this local QA, the user explicitly approved production deployment. The actual versions, public-site checks, request count and remaining live-service verification are recorded in [the 2026-10-17 deployment report](/Users/minjun/Ravil/docs/deploy-2026-10-17.md). The verification levels above remain scoped to the original local QA.
