#!/usr/bin/env python3
"""Copy short local Ravil audio clips only when audio/transcript timelines align."""

import argparse
import hashlib
import json
import os
import sqlite3
import subprocess
import unicodedata
from pathlib import Path


def duration_seconds(path: Path) -> float:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)],
        capture_output=True, text=True, check=True)
    return float(json.loads(result.stdout)["format"]["duration"])


def eligible_candidates(database: sqlite3.Connection, subject: str, clip_seconds: int) -> tuple[list, list]:
    candidates = []
    rejected = []
    rows = database.execute("""
        SELECT a.lecture_id, l.title, a.local_path, COUNT(t.id), MAX(t.end_ms)
        FROM audio_assets a JOIN lectures l ON l.id = a.lecture_id
        LEFT JOIN transcript_segments t ON t.lecture_id = l.id
        GROUP BY a.id
    """).fetchall()
    for lecture_id, title, audio_path, count, transcript_end_ms in rows:
        if subject not in unicodedata.normalize("NFKC", title):
            continue
        if not audio_path or not Path(audio_path).is_file() or count < 20:
            rejected.append({"lectureID": lecture_id, "reason": "missing audio or transcript"})
            continue
        duration = duration_seconds(Path(audio_path))
        transcript_end = (transcript_end_ms or 0) / 1000
        if duration < clip_seconds or abs(duration - transcript_end) > max(10, duration * 0.05):
            rejected.append({"lectureID": lecture_id, "reason": "audio/transcript duration mismatch",
                             "audioSeconds": round(duration, 2),
                             "transcriptEndSeconds": round(transcript_end, 2)})
            continue
        candidates.append((abs(duration - transcript_end) / duration, count,
                           lecture_id, Path(audio_path), duration))
    return candidates, rejected


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--subjects", nargs="+", required=True)
    parser.add_argument("--clip-seconds", type=int, default=20)
    args = parser.parse_args()
    if not 5 <= args.clip_seconds <= 60:
        parser.error("clip length must be 5–60 seconds")
    os.umask(0o077)
    args.output.mkdir(parents=True, exist_ok=True)
    database = sqlite3.connect(f"file:{args.database.resolve()}?mode=ro", uri=True)
    samples = []
    rejected = []
    for subject in args.subjects:
        candidates, skipped = eligible_candidates(database, subject, args.clip_seconds)
        rejected.extend(skipped)
        if not candidates:
            continue
        _, _, lecture_id, source, duration = min(candidates, key=lambda item: (item[0], -item[1]))
        segments = database.execute(
            "SELECT start_ms, text FROM transcript_segments WHERE lecture_id=? ORDER BY start_ms",
            (lecture_id,)).fetchall()
        quarter_start = segments[len(segments) // 4][0]
        start_ms = min(quarter_start, int((duration - args.clip_seconds) * 1000))
        clip = args.output / f"{subject}-{lecture_id}.wav"
        subprocess.run([
            "ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", str(start_ms / 1000),
            "-i", str(source), "-t", str(args.clip_seconds), "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le", str(clip)], check=True)
        clip_duration = duration_seconds(clip)
        if abs(clip_duration - args.clip_seconds) > 0.1:
            raise RuntimeError(f"clip duration mismatch for {subject}")
        weak = " ".join(text for offset, text in segments
                        if start_ms <= offset < start_ms + args.clip_seconds * 1000)
        language = "en" if subject == "영어" else "ko"
        sample = {"subject": subject, "lecture_id": lecture_id,
                  "audio_path": str(clip.resolve()), "start_ms": start_ms,
                  "duration_ms": args.clip_seconds * 1000, "language": language,
                  "clip_sha256": hashlib.sha256(clip.read_bytes()).hexdigest(),
                  "reference_status": "unreviewed machine transcript",
                  "rights_status": "user authorized local evaluation and training"}
        if language == "en" and sum("가" <= char <= "힣" for char in weak) > sum(
                char.isascii() and char.isalpha() for char in weak):
            sample["reference_status"] = "Alt transcript language differs; no usable reference"
        else:
            sample["weak_alt_reference"] = weak
        samples.append(sample)
    manifest = args.output / "manifest.json"
    manifest.write_text(json.dumps(samples, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    manifest.chmod(0o600)
    print(json.dumps({"clips": len(samples), "subjects": [s["subject"] for s in samples],
                      "excluded": rejected}, ensure_ascii=False))


if __name__ == "__main__":
    main()
