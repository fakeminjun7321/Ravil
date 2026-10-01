#!/usr/bin/env python3
"""Ravil-ASMR 0.5 English-only fast candidate. Never select by course name."""
import argparse
import json
import os
from pathlib import Path
import time

from asr_candidates import candidate_spec, load_candidate, require_language, digest
from ravil_asr_longform import PCMSource, review_ranges, vad_boundaries
from ravil_asr_native import transcribe_native


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--audio", type=Path, required=True)
    p.add_argument("--models", type=Path, required=True)
    p.add_argument("--candidate", choices=("parakeet-v3-bf16", "parakeet-v3-bf16-compact", "parakeet-redux"), default="parakeet-v3-bf16-compact")
    p.add_argument("--language", required=True, choices=("en",), help="must explicitly declare English-only speech")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--metrics", type=Path, required=True)
    p.add_argument("--vad-engine", type=Path)
    p.add_argument("--vad-model", type=Path)
    args = p.parse_args()
    if bool(args.vad_engine) != bool(args.vad_model):
        p.error("vad-engine and vad-model must be supplied together")
    targets = {args.output.resolve(), args.metrics.resolve()}
    if len(targets) != 2 or args.audio.resolve() in targets or any(x.exists() for x in targets):
        p.error("outputs must be distinct new files, separate from audio")
    require_language(candidate_spec(args.candidate), args.language)
    source = PCMSource(args.audio)
    if source.duration > 30 and not args.vad_engine:
        p.error("English inputs above 30 seconds require --vad-engine and --vad-model for speech-gap splitting")
    boundaries = []
    vad = None
    if args.vad_engine:
        vad_hash = digest(args.vad_model)
        if vad_hash != "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987":
            p.error("VAD model SHA-256 mismatch")
        if source.duration > 30:
            boundaries = vad_boundaries(args.vad_engine, args.vad_model, source)
        vad = {"modelSHA256": vad_hash, "engineSHA256": digest(args.vad_engine),
               "strategy": "speech-gap boundaries without dropping samples"}
    os.umask(0o077)
    os.environ["HF_HUB_OFFLINE"] = "1"
    import mlx.core as mx
    from transcribe_mlx_qwen_aligned import group_words, MLX_AUDIO_COMMIT

    code_hashes = {name: digest(Path(__file__).with_name(name)) for name in
                   ("transcribe_mlx_parakeet.py", "ravil_asr_native.py", "ravil_asr_longform.py", "asr_candidates.py")}
    started = time.perf_counter()
    model, spec = load_candidate(args.candidate, args.models)
    load_seconds = time.perf_counter() - started
    mx.reset_peak_memory()
    words, metrics = transcribe_native(source,
        lambda audio: model.generate(mx.array(audio), verbose=False), clear_cache=mx.clear_cache, boundaries=boundaries,
        progress=lambda item: print(json.dumps(item), flush=True))
    phrases = group_words(words, source.duration) if words else []
    gaps = review_ranges(metrics)
    metrics.update(modelLoadAndHashSeconds=round(load_seconds, 3), phrases=len(phrases),
                   reviewRequiredWindows=len(gaps), peakActiveMemoryBytes=mx.get_peak_memory(),
                   activeMemoryBytes=mx.get_active_memory())
    result = {"transcription": phrases, "reviewRequiredRanges": gaps,
              "status": "needs_review" if gaps else "transcribed" if phrases else "digital_silence",
              "provenance": {"pipeline": "Ravil-ASMR-0.5-english-experimental", "candidate": args.candidate,
                  "model": spec, "mlxAudioCommit": MLX_AUDIO_COMMIT, "languageMode": "explicit English-only",
                  "audioSHA256": digest(args.audio), "implementationSHA256": code_hashes,
                  "timestamps": "native model timestamps; human accuracy not verified", "vad": vad}}
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
    print(json.dumps({k:v for k,v in metrics.items() if k != "windows"}), flush=True)
    if gaps:
        raise SystemExit(3)


if __name__ == "__main__":
    main()
