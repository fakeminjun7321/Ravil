# Ravil 0.1 macOS preview

## What this build does

- Opens an independent Ravil library under `~/Library/Application Support/Ravil`.
- On first launch, copies the existing local Lecture OS SQLite data into that library using a
  checked SQLite backup. It does not bundle the user's DB in the DMG.
- Reads Alt's local lecture database to import new and changed timestamped transcripts.
- Lists lectures, courses, materials, and personal knowledge notes in one native Mac app.
- Presents each lecture with editable `노트/요약` content above a persistent transcript and audio
  player, following the installed Alt app's observed note workflow.
- Groups lecture entries by date and offers course folders in the sidebar.
- Offers Alt-inspired home quick actions, recent lectures, and a fixed recording entry bar. The
  home PDF action imports without a hidden course choice; the materials screen uses its visible
  course picker.
- Copies selected local PDFs into Ravil's private library and indexes their pages.
- Searches lecture titles, transcript text, material titles, and personal notes.
- Search results navigate to their target and leave the search overlay. Transcript hits request a
  timestamp jump; changing lectures stops audio from the previous lecture.
- Plays a lecture's original audio from a selected transcript timestamp when the source file exists.
- Records microphone audio to a local WAV and transcribes it with the Alt-downloaded local
  Whisper large-v3-turbo model and `whisper-cli` copied into the Ravil bundle.
- Stores unsaved personal-note drafts for recovery and shows WAV files that need registration.
- Saves a separate personal memo for each lecture and keeps a recovery draft if a DB write fails.

## Verified in this build

- Swift release build and ad-hoc app-bundle signature passed.
- The headless smoke test passed: database reopen, personal note persistence, recording
  registration, transcript timestamps, search, Alt import, safe source updates, lecture memo, and
  idempotent PDF import.
- The bundled executable transcribed a real 32-second lecture excerpt with the copied Alt model
  and returned nine timestamped phrases. The same check passed from the read-only mounted DMG.
- The headless self-check reported `modelSource=bundled`, `engineSource=bundled`, and
  `localModelReady=true`. All bundled Whisper binaries linked only to in-bundle or system libraries.
- First-run library initialization copied the existing Lecture OS data. The current private DB
  contains two lectures, 19 courses, and two materials; its integrity check returned `ok`.
- The DMG passed `hdiutil verify`, read-only mounting, bundle inspection, and signature checks.
- The 16 Node tests passed.
- The UX navigation fixes compiled in the release build, but were not exercised in a foreground
  window.

## Not yet verified or included

- The installed Alt window was directly inspected. The revised Ravil window, microphone permission
  prompt, and a full live-class recording have not yet been visually exercised. An offscreen
  SwiftUI renderer did not reproduce the real system split-view window.
- Long-session chunking, crash recovery during active recording, and background recording remain
  future native-recorder work.
- The bundle includes the Alt-downloaded GGML Whisper model and a local engine. It does not include
  Alt's Core ML accelerator, summary LLM, user notes, or recordings. The model's public
  redistribution terms have not been reviewed; this is a personal development build.
- Alt-imported audio still points to Alt's original audio file. Moving or deleting that file
  breaks Ravil playback for that lecture.
- iPhone, iPad, Apple Watch, and cross-device synchronization are not in this Mac DMG.
- The app is ad-hoc signed and not notarized for public distribution.

## Artifact

`dist/Ravil-0.1.0-arm64.dmg` contains `Ravil.app` and an Applications shortcut. The app includes
a copy of the local Whisper model and engine. It contains no personal SQLite DB, transcript, or
audio file.

The Alt reference decisions are recorded in `docs/alt-reference-design.md`.
