#!/usr/bin/env python3
"""Evaluate the pinned MLX Qwen3-ASR 1.7B 4-bit model fully offline."""

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

import mlx.core as mx
from mlx_audio.stt import load

# The shared metric functions use only the Python standard library.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from evaluate_local_stt import edit_distance, normalized_characters  # noqa: E402


MODELS = {
    "4bit": ("mlx-community/Qwen3-ASR-1.7B-4bit",
             "78a389c776a5483b2d0d4ea5494e11012e0d6159",
             "9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45"),
    "6bit": ("mlx-community/Qwen3-ASR-1.7B-6bit",
             "edd077a475c4da058e25b6e6ec1199115ca1be2b",
             "cacb094fef227ec2a5908d0136b3ad3384d95e0e2a8a915984ce577e4b12b2ba"),
}


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def read_rows(path: Path) -> list[dict]:
    contents = path.read_text(encoding="utf-8")
    rows = (json.loads(contents) if contents.lstrip().startswith("[") else
            [json.loads(line) for line in contents.splitlines() if line.strip()])
    if not rows or any(not Path(row.get("audio_path", "")).is_file() for row in rows):
        raise ValueError("manifest is empty or includes missing audio")
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--variant", choices=MODELS, default="4bit")
    parser.add_argument("--include-text", action="store_true")
    args = parser.parse_args()
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    model_id, revision, expected_sha = MODELS[args.variant]
    model_file = args.model_dir / "model.safetensors"
    if not model_file.is_file() or sha256(model_file) != expected_sha:
        parser.error("MLX model missing or SHA-256 differs from pinned conversion")
    rows = read_rows(args.manifest)

    load_started = time.perf_counter()
    model = load(args.model_dir, strict=True)
    load_seconds = time.perf_counter() - load_started
    loaded_memory = mx.get_active_memory()
    mx.reset_peak_memory()
    items = []
    for index, row in enumerate(rows, start=1):
        language = {"ko": "Korean", "en": "English"}.get(row.get("language", "ko"))
        if language is None:
            parser.error(f"unsupported language for sample {index}")
        started = time.perf_counter()
        result = model.generate(row["audio_path"], language=language, max_tokens=256)
        elapsed = time.perf_counter() - started
        text = result.text
        item = {"id": row.get("id", row.get("lecture_id", str(index))),
                "language": row.get("language", "ko"), "elapsedSeconds": round(elapsed, 3)}
        if "reference" in row:
            expected = normalized_characters(row["reference"])
            item["characterErrors"] = edit_distance(expected, normalized_characters(text))
            item["referenceCharacters"] = len(expected)
        if "weak_alt_reference" in row:
            weak = normalized_characters(row["weak_alt_reference"])
            item["weakAltDistance"] = edit_distance(weak, normalized_characters(text))
            item["weakAltCharacters"] = len(weak)
            item["referenceStatus"] = "unreviewed Alt output; distance is not accuracy"
        if args.include_text:
            item["prediction"] = text
        items.append(item)
        if index % 10 == 0 or index == len(rows):
            print(json.dumps({"processed": index, "total": len(rows)}), flush=True)

    report = {"model": model_id, "revision": revision, "modelSHA256": expected_sha,
              "license": "Apache-2.0", "runtime": "mlx-audio",
              "samples": len(rows), "modelLoadSeconds": round(load_seconds, 3),
              "activeMemoryAfterLoadBytes": loaded_memory,
              "peakActiveMemoryBytes": mx.get_peak_memory(),
              "items": items,
              "note": "Offline local inference. Weak Alt text is not verified ground truth."}
    if all("referenceCharacters" in item for item in items):
        report["characterErrorRate"] = round(
            sum(item["characterErrors"] for item in items)
            / sum(item["referenceCharacters"] for item in items), 4)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.output.chmod(0o600)
    print(json.dumps({"samples": len(rows), "characterErrorRate": report.get("characterErrorRate"),
                      "modelLoadSeconds": report["modelLoadSeconds"],
                      "peakActiveMemoryBytes": report["peakActiveMemoryBytes"]}), flush=True)


if __name__ == "__main__":
    main()
