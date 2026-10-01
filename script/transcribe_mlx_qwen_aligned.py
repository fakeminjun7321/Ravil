#!/usr/bin/env python3
"""Experimental offline Qwen3-ASR 4-bit + 4-bit aligner output in Ravil's JSON shape.

This prototype accepts mono PCM WAV clips of at most five minutes. It writes
transcript text only to a local 0600 file, never to stdout or a network API.
"""

import argparse
import hashlib
import json
import math
import os
import time
import wave
from pathlib import Path

import mlx.core as mx
from mlx_audio.stt import load

from evaluate_local_stt import edit_distance, normalized_characters


ASR_MODELS = {
    "4bit": ("mlx-community/Qwen3-ASR-1.7B-4bit",
             "78a389c776a5483b2d0d4ea5494e11012e0d6159",
             "9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45"),
    "6bit": ("mlx-community/Qwen3-ASR-1.7B-6bit",
             "edd077a475c4da058e25b6e6ec1199115ca1be2b",
             "cacb094fef227ec2a5908d0136b3ad3384d95e0e2a8a915984ce577e4b12b2ba"),
}
ALIGNER_ID = "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
ALIGNER_REVISION = "2f652af86ae0c73fe189b9429225c908ce4bf020"
ALIGNER_SHA256 = "630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c"
MLX_AUDIO_COMMIT = "94c7716212b2228f178d2f9c7619a591fd1b0b78"


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def verify_model(path: Path, expected: str, label: str) -> None:
    weights = path / "model.safetensors"
    if not weights.is_file() or sha256(weights) != expected:
        raise ValueError(f"{label} weights are missing or differ from the pinned SHA-256")


def wav_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as source:
        if source.getnchannels() != 1 or source.getframerate() != 16000:
            raise ValueError("input must be mono 16 kHz PCM WAV")
        if source.getsampwidth() != 2:
            raise ValueError("input must be 16-bit PCM WAV")
        duration = source.getnframes() / source.getframerate()
    if duration <= 0 or duration > 300:
        raise ValueError("input duration must be above zero and at most five minutes")
    return duration


def group_words(words, duration: float) -> list[dict]:
    phrases = []
    current = []

    def emit() -> None:
        if not current:
            return
        text = " ".join(part[2] for part in current).strip()
        if text:
            phrases.append({"offsets": {"from": round(current[0][0] * 1000),
                                         "to": round(current[-1][1] * 1000)},
                            "text": text})
        current.clear()

    previous_end = 0.0
    for item in words:
        start, end = float(item.start_time), float(item.end_time)
        text = str(item.text).strip()
        if not text or not all(map(math.isfinite, (start, end))) or start < 0 or end < start:
            raise ValueError("aligner returned invalid word or timestamp")
        if end > duration + 0.5 or start + 0.5 < previous_end:
            raise ValueError("aligner returned out-of-range or reversed timestamps")
        if current and (start - current[-1][1] > 0.8 or end - current[0][0] > 8.0):
            emit()
        current.append((start, end, text))
        previous_end = end
        if text.endswith((".", "?", "!", "。", "？", "！")):
            emit()
    emit()
    if not phrases:
        raise ValueError("aligner returned no usable timestamped phrases")
    return phrases


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--asr-model", type=Path, required=True)
    parser.add_argument("--asr-variant", choices=ASR_MODELS, default="4bit")
    parser.add_argument("--aligner-model", type=Path, required=True)
    parser.add_argument("--language", choices=("ko", "en"), default="ko")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metrics", type=Path, required=True)
    args = parser.parse_args()
    targets = {args.output.resolve(), args.metrics.resolve()}
    if len(targets) != 2 or args.audio.resolve() in targets or any(path.exists() for path in targets):
        parser.error("output and metrics must be distinct new files and must not replace audio")
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.umask(0o077)
    asr_id, asr_revision, asr_sha256 = ASR_MODELS[args.asr_variant]
    verify_model(args.asr_model, asr_sha256, "ASR")
    verify_model(args.aligner_model, ALIGNER_SHA256, "aligner")
    duration = wav_duration(args.audio)
    language = {"ko": "Korean", "en": "English"}[args.language]

    started = time.perf_counter()
    asr = load(args.asr_model, strict=True)
    aligner = load(args.aligner_model, strict=True)
    load_seconds = time.perf_counter() - started
    mx.reset_peak_memory()
    started = time.perf_counter()
    generated = asr.generate(str(args.audio), language=language, max_tokens=512)
    asr_seconds = time.perf_counter() - started
    text = generated.text.strip()
    if not text or "\ufffd" in text or "\x00" in text:
        raise ValueError("ASR returned empty or invalid text")
    started = time.perf_counter()
    words = aligner.generate(audio=str(args.audio), text=text, language=language)
    alignment_seconds = time.perf_counter() - started
    phrases = group_words(words, duration)
    aligned_text = normalized_characters(" ".join(phrase["text"] for phrase in phrases))
    source_text = normalized_characters(text)
    if not source_text or edit_distance(source_text, aligned_text) / len(source_text) > 0.2:
        raise ValueError("aligned words differ materially from the ASR text")
    if any(phrase["offsets"]["to"] < phrase["offsets"]["from"] for phrase in phrases):
        raise ValueError("timestamp order is invalid")

    result = {"transcription": phrases,
              "provenance": {"pipeline": "Ravil-ASMR-0.3-experimental"
                                 if args.asr_variant == "6bit" else "Ravil-ASMR-0.2-experimental",
                             "asr": asr_id, "asrRevision": asr_revision,
                             "asrSHA256": asr_sha256,
                             "aligner": ALIGNER_ID, "alignerRevision": ALIGNER_REVISION,
                             "alignerSHA256": ALIGNER_SHA256,
                             "license": "Apache-2.0", "runtime": "mlx-audio",
                             "mlxAudioCommit": MLX_AUDIO_COMMIT}}
    metrics = {"audioSeconds": round(duration, 3), "modelLoadSeconds": round(load_seconds, 3),
               "asrSeconds": round(asr_seconds, 3),
               "alignmentSeconds": round(alignment_seconds, 3),
               "activeMemoryBytes": mx.get_active_memory(),
               "peakActiveMemoryBytes": mx.get_peak_memory(),
               "phrases": len(phrases), "words": len(words)}
    for path, payload in ((args.output, result), (args.metrics, metrics)):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        path.chmod(0o600)
    print(json.dumps(metrics), flush=True)


if __name__ == "__main__":
    main()
