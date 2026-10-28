# Ravil 0.2.3 — Alt subject folders

## Subject display

The sidebar now shows these folders in the order requested:

1. 켈큘 — 수 I, 수 II, 수 III
2. 천문 — 일지 I
3. 미방 — 미방
4. 일물 — 일물
5. 현물 — 현물
6. 국어 — 독서
7. 영어 — 영 I, 영 II
8. 물실 — 물실
9. 프실 — 프실
10. 기타 과목 — remaining timetable courses under their original names

The subject list is a derived view grouping. It does not rename or delete source course IDs or
timetable records. Selecting a parent folder shows lectures from all of its original courses;
selecting a child shows that single course. `전체 강의` still includes every course, including
`기타 과목`. Alt note titles stay as saved, so teacher labels in those titles remain visible.

## Build

- Swift release build completed.
- `dist/Ravil-0.2.3-arm64.dmg` was created as a separate version; 0.2.0, 0.2.1, and 0.2.2 artifacts
  remain in `dist/`.
- The package script completed its app-signature and DMG-integrity checks.
- Subject-folder clicks and lecture filtering were not exercised in the foreground app.

SHA-256: `885bc70d8597b1a653aabeec8605c23271097274797ef1b946f9bd52c51cf1b8`.

Alt's local database contains only two imported July notes without a course assignment. The teacher-
labelled workspace notes visible in Alt are not all present in that local database, so this grouping
preserves teacher names in titles when present but does not import those remote notes.
