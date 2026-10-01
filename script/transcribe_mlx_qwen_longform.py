#!/usr/bin/env python3
"""Ravil-ASMR offline CLI: 0.4 quality profiles and the 0.5 small8bit experiment."""

import argparse
import json
import os
from pathlib import Path
import time

from ravil_asr_longform import PCMSource, transcribe, vad_boundaries, review_ranges
from transcribe_mlx_qwen_aligned import (
    ASR_MODELS, ALIGNER_ID, ALIGNER_REVISION, ALIGNER_SHA256, MLX_AUDIO_COMMIT,
    group_words, sha256, verify_model,
)
from asr_candidates import candidate_spec

SMALL = candidate_spec("qwen-0.6b-8bit")
VARIANTS = {**ASR_MODELS, "small8bit": (SMALL["repo"], SMALL["revision"], SMALL["sha256"])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--asr-model", type=Path, required=True)
    parser.add_argument("--asr-variant", choices=VARIANTS, default="6bit")
    parser.add_argument("--aligner-model", type=Path, required=True)
    parser.add_argument("--language", choices=("ko", "en", "auto"), default="auto")
    parser.add_argument("--chunk-seconds", type=float, default=30)
    parser.add_argument("--context-seconds", type=float, default=1)
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--vad-engine", type=Path, help="optional pinned whisper-vad-speech-segments binary")
    parser.add_argument("--vad-model", type=Path, help="official Silero v6.2.0 GGML model")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metrics", type=Path, required=True)
    args = parser.parse_args()
    if bool(args.vad_engine) != bool(args.vad_model):
        parser.error("vad-engine and vad-model must be supplied together")
    targets = {args.output.resolve(), args.metrics.resolve()}
    if len(targets) != 2 or args.audio.resolve() in targets or any(p.exists() for p in targets):
        parser.error("output and metrics must be distinct new files, separate from audio")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.umask(0o077)
    import mlx.core as mx
    from mlx_audio.stt import load

    model_id, revision, digest = VARIANTS[args.asr_variant]
    verify_model(args.asr_model, digest, "ASR")
    verify_model(args.aligner_model, ALIGNER_SHA256, "aligner")
    source = PCMSource(args.audio)
    vad_metadata = None
    boundaries = []
    if args.vad_engine:
        vad_hash = sha256(args.vad_model)
        if vad_hash != "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987":
            parser.error("VAD model differs from the pinned SHA-256")
        started = time.perf_counter()
        if source.duration > args.chunk_seconds:
            boundaries = vad_boundaries(args.vad_engine, args.vad_model, source)
        vad_metadata = {"modelSHA256": vad_hash, "engineSHA256": sha256(args.vad_engine),
                        "seconds": round(time.perf_counter() - started, 3),
                        "strategy": "speech-gap split hints for long inputs; no audio discarded"}
    # Validate window settings before allocating models.
    next(source.windows(args.chunk_seconds, args.context_seconds))
    started = time.perf_counter()
    asr = load(args.asr_model, strict=True)
    aligner = load(args.aligner_model, strict=True)
    load_seconds = time.perf_counter() - started
    mx.reset_peak_memory()
    words, metrics = transcribe(
        source, asr, aligner, language=args.language, chunk_seconds=args.chunk_seconds,
        context_seconds=args.context_seconds, max_tokens=args.max_tokens,
        boundaries=boundaries,
        clear_cache=mx.clear_cache, progress=lambda item: print(json.dumps(item), flush=True))
    phrases = group_words(words, source.duration) if words else []
    needs_review = review_ranges(metrics)
    metrics["reviewRequiredWindows"] = len(needs_review)
    metrics.update(modelLoadSeconds=round(load_seconds, 3), phrases=len(phrases),
                   activeMemoryBytes=mx.get_active_memory(),
                   peakActiveMemoryBytes=mx.get_peak_memory())
    result = {"transcription": phrases, "reviewRequiredRanges": needs_review,
              "status": "needs_review" if needs_review else "transcribed" if phrases else "digital_silence",
              "provenance": {
        "pipeline": "Ravil-ASMR-0.5-fast-experimental" if args.asr_variant == "small8bit" else "Ravil-ASMR-0.4-experimental", "asr": model_id,
        "asrRevision": revision, "asrSHA256": digest, "aligner": ALIGNER_ID,
        "alignerRevision": ALIGNER_REVISION, "alignerSHA256": ALIGNER_SHA256,
        "license": "Apache-2.0", "runtime": "mlx-audio", "mlxAudioCommit": MLX_AUDIO_COMMIT,
        "audioSHA256": sha256(args.audio), "languageMode": args.language,
        "implementationSHA256": {
            "cli": sha256(Path(__file__)),
            "longform": sha256(Path(__file__).with_name("ravil_asr_longform.py"))},
        "chunkSeconds": args.chunk_seconds, "contextSeconds": args.context_seconds,
        "maxTokensPerWindow": args.max_tokens, "vad": vad_metadata}}
    # Exclusive creation prevents accidental replacement of a concurrent result.
    created = []
    try:
        for path, payload in ((args.output, result), (args.metrics, metrics)):
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("x", encoding="utf-8") as target:
                created.append(path)
                json.dump(payload, target, ensure_ascii=False, indent=2)
                target.write("\n")
    except Exception:
        for path in created:
            path.unlink(missing_ok=True)
        raise
    print(json.dumps({k: v for k, v in metrics.items() if k != "windows"}), flush=True)
    if needs_review:
        raise SystemExit(3)  # Artifacts exist, but must not be called a verified full transcript.


if __name__ == "__main__":
    main()
