#!/usr/bin/env python3
"""Paired, local 0.3/0.4 pipeline evaluation; keeps transcript text off stdout."""
import argparse
import json
import os
from pathlib import Path
import time
import hashlib

from evaluate_local_stt import edit_distance, normalized_characters, normalized_words
from ravil_asr_longform import PCMSource, transcribe, vad_boundaries, review_ranges
from transcribe_mlx_qwen_aligned import (
    ASR_MODELS, ALIGNER_SHA256, group_words, verify_model,
)


def score(reference, prediction):
    expected, actual = normalized_characters(reference), normalized_characters(prediction)
    words = normalized_words(reference)
    return {"characterErrors": edit_distance(expected, actual), "referenceCharacters": len(expected),
            "wordErrors": edit_distance(words, normalized_words(prediction)), "referenceWords": len(words)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--short-count", type=int, default=20)
    parser.add_argument("--vad-engine", type=Path)
    parser.add_argument("--vad-model", type=Path)
    parser.add_argument("--case", help="run a single case ID when diagnosing a failed sample")
    args = parser.parse_args()
    if bool(args.vad_engine) != bool(args.vad_model):
        parser.error("vad-engine and vad-model must be supplied together")
    if args.vad_model and hashlib.sha256(args.vad_model.read_bytes()).hexdigest() != "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987":
        parser.error("VAD hash differs from pinned Silero model")
    if not 0 <= args.short_count <= 100:
        parser.error("short-count must be between 0 and 100")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.umask(0o077)
    args.output.mkdir(parents=True, exist_ok=False)
    import mlx.core as mx
    from mlx_audio.stt import load

    asr_path = args.models / "qwen3-asr-1.7b-6bit"
    aligner_path = args.models / "qwen3-aligner-0.6b-4bit"
    verify_model(asr_path, ASR_MODELS["6bit"][2], "ASR")
    verify_model(aligner_path, ALIGNER_SHA256, "aligner")
    asr = load(asr_path, strict=True)
    aligner = load(aligner_path, strict=True)
    cases = json.loads((args.data / "longform.json").read_text())
    for language in ("korean", "english"):
        short = [json.loads(line) for line in (args.data / (language + ".jsonl")).read_text().splitlines()]
        cases.extend(short[:args.short_count])
    if args.case:
        cases = [row for row in cases if row["id"] == args.case]
        if not cases:
            parser.error("case ID not found")
    report = {"items": [], "asrSHA256": ASR_MODELS["6bit"][2],
              "alignerSHA256": ALIGNER_SHA256,
              "inputManifestSHA256": hashlib.sha256((args.data / "longform.json").read_bytes()).hexdigest(),
              "candidateLanguageMode": "auto", "maxTokensPerWindow": 512,
              "chunkSeconds": 30, "contextSeconds": 1,
              "vadSplitHints": bool(args.vad_engine),
              "implementationSHA256": {
                  "evaluator": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  "longform": hashlib.sha256(Path(__file__).with_name("ravil_asr_longform.py").read_bytes()).hexdigest()},
              "note": "Long cases are constructed FLEURS concatenations, not natural lectures. "
                      "Baseline fixes Korean for mixed audio; candidate detects language per window. "
                      "CER removes spaces/punctuation and case; English WER uses normalized words."}
    items = report["items"]
    for row in cases:
        source = PCMSource(Path(row["audio_path"]))
        item = {"id": row["id"], "language": row["language"], "audioSeconds": source.duration}
        for version in ("0.3", "0.4"):
            mx.reset_peak_memory()
            started = time.perf_counter()
            try:
                if version == "0.3":
                    # 0.3 requires one language for the full file; use Korean for mixed.
                    language = "English" if row["language"] == "en" else "Korean"
                    generated = asr.generate(str(source.path), language=language, max_tokens=512)
                    words = aligner.generate(audio=str(source.path), text=generated.text, language=language)
                    phrases = group_words(words, source.duration)
                    metrics = {"generationTokens": generated.generation_tokens,
                               "reachedTokenLimit": generated.generation_tokens >= 512}
                else:
                    boundaries = (vad_boundaries(args.vad_engine, args.vad_model, source)
                                  if args.vad_engine and source.duration > 30 else [])
                    words, metrics = transcribe(source, asr, aligner, language="auto",
                                                clear_cache=mx.clear_cache, boundaries=boundaries)
                    metrics["reviewRequiredRanges"] = review_ranges(metrics)
                    phrases = group_words(words, source.duration) if words else []
                predicted = " ".join(p["text"] for p in phrases)
                metrics.update(score(row["reference"], predicted))
                metrics.update(elapsedSeconds=round(time.perf_counter() - started, 3),
                               peakActiveMemoryBytes=mx.get_peak_memory())
                item[version] = metrics
                payload = {"transcription": phrases,
                           "provenance": {"pipeline": "Ravil-ASMR-" + version + "-experimental",
                                          "evaluationOnly": True, "asrSHA256": ASR_MODELS["6bit"][2],
                                          "alignerSHA256": ALIGNER_SHA256}}
                (args.output / (row["id"] + "-" + version + ".json")).write_text(
                    json.dumps(payload, ensure_ascii=False, indent=2))
            except Exception as error:
                item[version] = {"error": type(error).__name__ + ": " + str(error)}
            mx.clear_cache()
        items.append(item)
        (args.output / "report.json").write_text(json.dumps(report, indent=2))
        print(json.dumps({"id": row["id"], **{v: {k: val for k, val in item[v].items()
              if k in ("characterErrors", "referenceCharacters", "wordErrors", "referenceWords",
                       "elapsedSeconds", "reachedTokenLimit", "error")} for v in ("0.3", "0.4")}}), flush=True)
    if any("error" in row[v] for row in items for v in ("0.3", "0.4")):
        raise SystemExit("Evaluation contains failed cases; see report.json")


if __name__ == "__main__":
    main()
