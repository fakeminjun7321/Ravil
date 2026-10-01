#!/usr/bin/env python3
"""Paired Korean/English candidate comparison on the same local PCM files.

ASR-only timing, excluding model load, includes native timestamps if provided.
No forced aligner is added here. Reports distinguish that from app latency.
"""
import argparse
import json
import os
from pathlib import Path
import time
import wave

from asr_candidates import load_candidate, recognize, candidate_spec, require_language, digest
from evaluate_local_stt import normalized_characters, normalized_words, edit_distance


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--candidate", required=True)
    p.add_argument("--models", type=Path, required=True)
    p.add_argument("--manifest", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--limit", type=int, default=100)
    args = p.parse_args()
    if args.output.exists() or args.limit < 1:
        p.error("output must be new and limit must be positive")
    os.umask(0o077)
    rows = [json.loads(line) for line in args.manifest.read_text().splitlines() if line][:args.limit]
    if not rows or len({r["id"] for r in rows}) != len(rows):
        p.error("empty or duplicate evaluation rows")
    spec = candidate_spec(args.candidate)
    for row in rows:
        require_language(spec, row["language"])
        if row["split"] != "eval" or not normalized_characters(row["reference"]):
            p.error("expected non-empty evaluation references")
    import mlx.core as mx
    started = time.perf_counter()
    model, spec = load_candidate(args.candidate, args.models)
    load_seconds = time.perf_counter() - started
    # Disclosed warm-up: first sample, unscored; every model gets the same rule.
    recognize(model, spec, rows[0]["audio_path"], rows[0]["language"])
    mx.clear_cache()
    mx.reset_peak_memory()
    items = []
    for index, row in enumerate(rows):
        with wave.open(row["audio_path"], "rb") as audio:
            duration = audio.getnframes() / audio.getframerate()
        started = time.perf_counter()
        generated = recognize(model, spec, row["audio_path"], row["language"])
        elapsed = time.perf_counter() - started
        text = generated.text
        if not isinstance(text, str) or "\ufffd" in text or "\x00" in text:
            raise ValueError("invalid candidate transcript")
        reference = normalized_characters(row["reference"])
        words = normalized_words(row["reference"])
        items.append({"id": row["id"], "language": row["language"], "audioSeconds": duration,
                      "elapsedSeconds": elapsed, "characterErrors": edit_distance(reference, normalized_characters(text)),
                      "referenceCharacters": len(reference),
                      "wordErrors": edit_distance(words, normalized_words(text)), "referenceWords": len(words),
                      "prediction": text})
        if (index + 1) % 20 == 0 or index + 1 == len(rows):
            print(json.dumps({"candidate": args.candidate, "processed": index + 1, "total": len(rows)}), flush=True)
        mx.clear_cache()
    report = {"candidate": args.candidate, "spec": spec, "manifestSHA256": digest(args.manifest),
              "warmup": "one unscored first-sample decode", "samples": len(rows),
              "modelLoadAndHashSeconds": round(load_seconds, 3),
              "activeMemoryBytes": mx.get_active_memory(), "peakActiveMemoryBytes": mx.get_peak_memory(),
              "asrSeconds": round(sum(x["elapsedSeconds"] for x in items), 3),
              "audioSeconds": round(sum(x["audioSeconds"] for x in items), 3),
              "characterErrorRate": sum(x["characterErrors"] for x in items) / sum(x["referenceCharacters"] for x in items),
              "wordErrorRate": sum(x["wordErrors"] for x in items) / sum(x["referenceWords"] for x in items),
              "items": items,
              "note": "Public read-speech diagnosis; not classroom, mixed-language or full app performance."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as target:
        json.dump(report, target, ensure_ascii=False, indent=2)
    print(json.dumps({k:v for k,v in report.items() if k not in ("items", "spec")}), flush=True)


if __name__ == "__main__":
    main()
