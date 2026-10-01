#!/usr/bin/env python3
"""Transcribe local clips with the bundled whisper.cpp engine for private comparison."""

import argparse
import json
from pathlib import Path

from evaluate_local_stt import edit_distance, normalized_characters, transcribe


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--include-text", action="store_true")
    args = parser.parse_args()
    raw = args.manifest.read_text(encoding="utf-8")
    rows = json.loads(raw) if raw.lstrip().startswith("[") else [
        json.loads(line) for line in raw.splitlines() if line.strip()]
    resources = args.app / "Contents/Resources"
    engine = resources / "Whisper/bin/whisper-cli"
    model = resources / "Models/ggml-large-v3-turbo-q5_0.bin"
    backends = resources / "Whisper/backends"
    if not rows or not engine.is_file() or not model.is_file() or not backends.is_dir():
        parser.error("manifest or Ravil app bundle is incomplete")

    items = []
    for index, row in enumerate(rows, start=1):
        if not Path(row.get("audio_path", "")).is_file():
            parser.error(f"missing audio for sample {index}")
        prediction, seconds, valid_utf8 = transcribe(
            engine, model, backends, {**row, "language": row.get("language", "ko")})
        item = {"id": row.get("id", row.get("lecture_id", str(index))),
                "elapsedSeconds": round(seconds, 3), "validUTF8": valid_utf8}
        if "weak_alt_reference" in row:
            weak = normalized_characters(row["weak_alt_reference"])
            item["weakAltDistance"] = edit_distance(weak, normalized_characters(prediction))
            item["weakAltCharacters"] = len(weak)
            item["referenceStatus"] = "unreviewed Alt output; distance is not accuracy"
        if args.include_text:
            item["prediction"] = prediction
        items.append(item)
    report = {"model": "OpenAI Whisper large-v3-turbo q5_0", "samples": len(items),
              "items": items, "note": "Inputs stayed local; weak Alt references are not ground truth."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.output.chmod(0o600)
    print(json.dumps({"samples": len(items), "invalidUTF8Samples": sum(
        not item["validUTF8"] for item in items)}), flush=True)


if __name__ == "__main__":
    main()
