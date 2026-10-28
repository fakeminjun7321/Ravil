# RAVIL AI workspace design brief — 2026-10-13

## Target and outcome
Redesign RAVIL's web introduction, authentication and personal workspace using the user's local Quilo UI and mature AI workspace patterns.
The primary concept frame is a signed-in desktop workspace at 1440 × 1024. It should let a user capture free-form records, resume subject/project work, edit notes and use AI with the relevant record in view.

## Confirmed constraints
- Quilo remains its own product. Preserve RAVIL as a record-first personal workspace.
- Keep subject/project associations and one canonical record reused in multiple contexts.
- Maintain the existing cloud login, persistence, rich note input, original photo/PDF attachment, PDF/Word export and exam archive/backup behavior.
- Primary recording types must remain easy to distinguish.
- Prefer short slash commands and icon actions to explanatory form text; avoid childlike badges, gamification and long feature descriptions.
- Preserve the existing graphite/forest/lime RAVIL identity where useful; use depth sparingly around navigation and active work surfaces.
- Personal understanding stays within RAVIL activity. Do not imply external device monitoring or perfect personality profiling.
- Use synthetic example data derived from the user's study-plan example.
- Date anchor: Tuesday 2026-10-13, Asia/Seoul. 10.14 is Wednesday and 10.15 is Thursday.
- The three generated concepts are design previews. No application code or production deployment is changed before visual selection.

## Inspected references
- Local source: /Users/minjun/Quilo, HEAD 63ec14d; source files are read-only for this task.
- public/index.html, public/chat/view.js, public/ui/chat.css: input-first home, short action chips, compact conversation after input.
- public/ui/tool-shell.js and tool-shell.css: navigation / active work / result rail; restrained surfaces and stable columns.
- references/quilo-home-light.png, references/quilo-home-dark.png, references/quilo-tool-workspace.png: actual public frontend rendered locally with capability/auth fixtures. These do not verify Quilo production AI or login.
- /Users/minjun/Ravil/output/domain-launch-2026-10-06/live-workspace-persisted.png: inspected existing RAVIL screenshot from the domain launch, used for brand and current controls.
- https://www.notion.com/product/ai : official record, finding and contextual AI patterns.
- https://support.anthropic.com/en/articles/9487310-what-are-artifacts-and-how-do-i-use-them : official separate conversation/result surface, iterative document and export patterns.

## Proposed independent directions
- Start desk: input-first signed-in home with a quiet project/subject rail and a short recent-work list.
- Document studio: the document is primary; related material and a contextual AI pane sit beside it.
- Project desk: the selected exam project brings notes and a small planning preview together; AI acts within that project rather than across unrelated records.

Do not put numeric option labels in generation prompts. Resolve user option numbers from the generated-image display order.

## Capture boundary and verification
Quilo's .env and one school-template sidecar have dangling links. No secrets were read or relinked.
Capture uses real frontend files with local API fixtures; write/generation requests are disabled.
The in-app browser's screenshot/layout capture was unavailable/mis-scaled, so a separate background Chrome tab captured the local references. Only task tabs were used.
Quilo verify:quick passed 6 harness tests and git diff --check. This is not backend or production verification.
Quilo public URL was queried once and returned 503 through the research fetcher. RAVIL production has received 0 direct application probes in this design task.
