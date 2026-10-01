#!/usr/bin/env python3
"""Evaluate the pinned Qwen3-ASR 0.6B model entirely on this Mac."""

import argparse
import hashlib
import json
import time
from pathlib import Path

import torch
from huggingface_hub import hf_hub_download
from transformers import AutoModelForMultimodalLM, AutoProcessor, logging

from evaluate_local_stt import edit_distance, normalized_characters


MODELS = {
    "0.6b": ("Qwen/Qwen3-ASR-0.6B-hf", "7f1569a48a89f3e3f4dc3a5c9d28bddd903bc76c",
             "d3f212dd20abecd315d830bc54ae3865e56ebfc3276484e57b771288ba27fd35"),
    "1.7b": ("Qwen/Qwen3-ASR-1.7B-hf", "bcd2b5b7f32b480ab5790554cfa8347f246a14f3",
             "2db53c7d81bd9b8cbc6a074e89be2c968a0d373fb4ee68bb1b1e14f7042dfee1"),
}


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--variant", choices=MODELS, default="0.6b")
    parser.add_argument("--include-text", action="store_true",
                        help="save predictions to the local report; never send it to a service")
    args = parser.parse_args()
    raw_manifest = args.manifest.read_text(encoding="utf-8")
    rows = (json.loads(raw_manifest) if raw_manifest.lstrip().startswith("[") else
            [json.loads(line) for line in raw_manifest.splitlines() if line.strip()])
    if not rows or any(not Path(row.get("audio_path", "")).is_file() for row in rows):
        parser.error("manifest is empty or includes missing audio")
    logging.set_verbosity_error()
    model_id, revision, expected_model_sha256 = MODELS[args.variant]
    model_file = Path(hf_hub_download(model_id, "model.safetensors", revision=revision,
                                      local_files_only=True))
    digest = sha256(model_file)
    if digest != expected_model_sha256:
        parser.error("cached Qwen model SHA-256 differs from the pinned official file")
    processor = AutoProcessor.from_pretrained(model_id, revision=revision, local_files_only=True)
    model = AutoModelForMultimodalLM.from_pretrained(
        model_id, revision=revision, local_files_only=True, device_map="auto")
    model.eval()

    items = []
    for number, row in enumerate(rows, start=1):
        started = time.monotonic()
        language = {"ko": "Korean", "en": "English"}.get(row.get("language", "ko"))
        if language is None:
            parser.error(f"unsupported language for sample {number}")
        inputs = processor.apply_transcription_request(
            audio=row["audio_path"], language=language).to(model.device, model.dtype)
        with torch.inference_mode():
            output_ids = model.generate(**inputs, max_new_tokens=256)
        generated = output_ids[:, inputs["input_ids"].shape[1]:]
        prediction = processor.decode(generated, return_format="transcription_only")[0]
        item = {"id": row["id"] if "id" in row else row.get("lecture_id", str(number)),
                "elapsedSeconds": round(time.monotonic() - started, 3),
                "language": row.get("language", "ko")}
        if "reference" in row:
            expected = normalized_characters(row["reference"])
            item["characterErrors"] = edit_distance(expected, normalized_characters(prediction))
            item["referenceCharacters"] = len(expected)
        if "weak_alt_reference" in row:
            weak = normalized_characters(row["weak_alt_reference"])
            item["weakAltDistance"] = edit_distance(weak, normalized_characters(prediction))
            item["weakAltCharacters"] = len(weak)
            item["referenceStatus"] = "unreviewed Alt output; distance is not accuracy"
        if args.include_text:
            item["prediction"] = prediction
        items.append(item)
        if number % 10 == 0 or number == len(rows):
            print(json.dumps({"processed": number, "total": len(rows)}), flush=True)

    report = {"model": model_id, "revision": revision, "modelSHA256": digest,
              "license": "Apache-2.0", "device": str(model.device), "samples": len(items),
              "items": items, "note": "Inputs stayed local; weak Alt references are not ground truth."}
    if all("referenceCharacters" in item for item in items):
        report["characterErrorRate"] = round(
            sum(item["characterErrors"] for item in items)
            / sum(item["referenceCharacters"] for item in items), 4)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.output.chmod(0o600)
    print(json.dumps({"samples": len(items), "characterErrorRate": report.get("characterErrorRate"),
                      "modelSHA256": digest}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
