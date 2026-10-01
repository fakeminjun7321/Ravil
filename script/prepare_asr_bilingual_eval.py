#!/usr/bin/env python3
"""Prepare attributed FLEURS English clips and constructed KO/EN long-form tests.

These concatenations test length and language switching, not natural classroom
accuracy or within-sentence code switching. Never use these test rows to train.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tarfile
import wave
import subprocess

from prepare_fleurs_ko import DATASET_REVISION, selected_rows


EN_HASHES = {"test.tsv": "74c046239374deeb60fa63f258f907388093a32bcaa3140965f70ef05c79f7ca",
             "test.tar.gz": "d9c2e37b41aacd41bc283554a0a82b5476b36887049774ecb2819dcaaa55a356"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--english-source", type=Path, required=True)
    parser.add_argument("--korean-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    args.output.mkdir(parents=True, exist_ok=False)
    for filename, expected in EN_HASHES.items():
        path = args.english_source / filename
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"English source checksum mismatch: {filename}")
    chosen = selected_rows(args.english_source / "test.tsv", 100, seed=930240)
    wanted = {"test/" + row[1]: row for row in chosen}
    english = []
    audio_dir = args.output / "english"
    audio_dir.mkdir()
    with tarfile.open(args.english_source / "test.tar.gz", "r:gz") as archive:
        for member in archive:
            if member.name not in wanted:
                continue
            row = wanted.pop(member.name)
            if not member.isfile():
                raise ValueError("non-file FLEURS member")
            path = audio_dir / row[1]
            with archive.extractfile(member) as stream:
                path.write_bytes(stream.read())
            english.append({"id": "fleurs-en-test-" + row[0], "audio_path": str(path.resolve()),
                            "reference": row[2], "language": "en", "split": "eval",
                            "subject": "general-read-speech", "license": "CC-BY-4.0",
                            "rights_reference": "https://huggingface.co/datasets/google/fleurs/tree/" + DATASET_REVISION})
    if wanted:
        raise ValueError("missing English audio")
    korean = [json.loads(line) for line in args.korean_manifest.read_text().splitlines() if line]
    # FLEURS stores float WAVs. Both inference paths receive identical PCM16
    # copies, matching Ravil's recorder format without changing the originals.
    for name, rows in (("korean", korean), ("english", english)):
        directory = args.output / (name + "-pcm")
        directory.mkdir()
        for row in rows:
            path = directory / (row["id"] + ".wav")
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-n", "-i",
                            row["audio_path"], "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                            str(path)], check=True)
            row["audio_path"] = str(path.resolve())
        (args.output / (name + ".jsonl")).write_text("".join(json.dumps(r) + "\n" for r in rows))
    manifest = build_long_cases(korean, english, args.output)
    print(json.dumps({"englishSamples": len(english),
                      "cases": [{"id": r["id"], "seconds": r["audioSeconds"]} for r in manifest]}))


def build_long_cases(korean, english, output):
    # Source order is stable and not selected according to model outputs.
    cases = [("ko-long", korean, "ko"), ("en-long", english, "en"),
             ("mixed-long", [r for pair in zip(korean, english) for r in pair], "auto")]
    manifest = []
    for case_id, rows, language in cases:
        path = output / (case_id + ".wav")
        if path.exists():
            raise ValueError("refusing to overwrite a constructed evaluation file")
        total = 0
        used = []
        with wave.open(str(path), "wb") as target:
            target.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            for row in rows:
                with wave.open(row["audio_path"], "rb") as source:
                    if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):
                        raise ValueError("unexpected source audio format")
                    frames = source.getnframes()
                    if total + frames > 240 * 16000:
                        break
                    target.writeframes(source.readframes(frames))
                used.append({"id": row["id"], "language": row["language"],
                             "startSeconds": total / 16000, "endSeconds": (total + frames) / 16000,
                             "reference": row["reference"]})
                target.writeframes(bytes(16000))  # half a second of digital silence
                total += frames + 8000
        manifest.append({"id": case_id, "audio_path": str(path.resolve()), "language": language,
                         "reference": " ".join(r["reference"] for r in used), "components": used,
                         "audioSeconds": total / 16000, "split": "eval", "license": "CC-BY-4.0",
                         "datasetRevision": DATASET_REVISION,
                         "note": "Constructed concatenation; not a natural bilingual lecture"})
    (output / "longform.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    return manifest


if __name__ == "__main__":
    main()
