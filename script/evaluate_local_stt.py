#!/usr/bin/env python3
"""Evaluate a bundled/local Whisper model against human reference transcripts.

Input is JSONL with id, audio_path, reference, language, subject, split="eval",
and rights_reference. Audio and transcript text are never printed or copied into
the report. The rights_reference is a record for review, not legal verification.
"""

import argparse
import hashlib
import json
import subprocess
import tempfile
import time
import unicodedata
from pathlib import Path


def normalized_characters(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).casefold()
    return "".join(char for char in value if unicodedata.category(char)[0] in "LN")


def normalized_words(value: str) -> list[str]:
    value = unicodedata.normalize("NFKC", value).casefold()
    return [
        "".join(char for char in word if unicodedata.category(char)[0] in "LN")
        for word in value.split()
        if any(unicodedata.category(char)[0] in "LN" for char in word)
    ]


def edit_distance(reference, hypothesis) -> int:
    previous = list(range(len(hypothesis) + 1))
    for index, expected in enumerate(reference, start=1):
        current = [index]
        for column, actual in enumerate(hypothesis, start=1):
            current.append(
                min(previous[column] + 1, current[column - 1] + 1,
                    previous[column - 1] + (expected != actual))
            )
        previous = current
    return previous[-1]


def load_manifest(path: Path) -> list[dict]:
    items = []
    identifiers = set()
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        item = json.loads(line)
        required = ("id", "audio_path", "reference", "language", "subject", "split", "rights_reference")
        if any(not isinstance(item.get(key), str) or not item[key].strip() for key in required):
            raise ValueError(f"manifest line {line_number}: missing required metadata")
        if item["split"] != "eval" or item["language"] not in ("ko", "en", "ja", "zh"):
            raise ValueError(f"manifest line {line_number}: invalid split or language")
        if item["id"] in identifiers:
            raise ValueError(f"manifest line {line_number}: duplicate id")
        audio_path = Path(item["audio_path"])
        if not audio_path.is_absolute() or not audio_path.is_file():
            raise ValueError(f"manifest line {line_number}: audio_path must be an existing absolute file")
        identifiers.add(item["id"])
        items.append(item)
    if not items:
        raise ValueError("evaluation manifest is empty")
    return items


def transcribe(engine: Path, model: Path, backends: Path, item: dict,
               vad_model: Path | None = None) -> tuple[str, float, bool]:
    with tempfile.TemporaryDirectory(prefix="ravil-stt-eval-") as directory:
        output_base = Path(directory) / "prediction"
        started = time.monotonic()
        arguments = [str(engine), "-m", str(model), "-f", item["audio_path"],
                     "-l", item["language"], "-oj", "-of", str(output_base), "-np"]
        if vad_model is not None:
            arguments += ["--vad", "--vad-model", str(vad_model)]
        result = subprocess.run(
            arguments,
            cwd=backends, capture_output=True, check=False,
        )
        elapsed = time.monotonic() - started
        if result.returncode:
            raise RuntimeError(f"transcription failed for {item['id']} (exit {result.returncode})")
        raw = output_base.with_suffix(".json").read_bytes()
        try:
            decoded = raw.decode("utf-8")
            valid_utf8 = True
        except UnicodeDecodeError:
            decoded = raw.decode("utf-8", errors="replace")
            valid_utf8 = False
        data = json.loads(decoded)
        segments = data.get("transcription", [])
        return " ".join(segment.get("text", "") for segment in segments), elapsed, valid_utf8


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--app", type=Path, required=True, help="Ravil.app to evaluate")
    parser.add_argument("--model", type=Path, help="optional GGML candidate model; defaults to the app bundle")
    parser.add_argument("--vad-model", type=Path, help="optional pinned GGML VAD model")
    args = parser.parse_args()
    resources = args.app / "Contents" / "Resources"
    engine = resources / "Whisper" / "bin" / "whisper-cli"
    backends = resources / "Whisper" / "backends"
    if not (backends / "libggml-metal.so").is_file():
        backends = resources / "Whisper" / "bin"
    model = args.model or resources / "Models" / "ggml-large-v3-turbo-q5_0.bin"
    if not engine.is_file() or not backends.is_dir() or not model.is_file():
        parser.error("app lacks its bundled Whisper engine, backends, or model")
    if args.vad_model is not None and not args.vad_model.is_file():
        parser.error("VAD model file does not exist")
    digest = hashlib.sha256()
    with model.open("rb") as model_file:
        for chunk in iter(lambda: model_file.read(1024 * 1024), b""):
            digest.update(chunk)

    try:
        items = load_manifest(args.manifest)
    except (ValueError, KeyError, json.JSONDecodeError) as error:
        parser.error(str(error))

    results = []
    for item in items:
        hypothesis, seconds, valid_utf8 = transcribe(
            engine, model, backends, item, vad_model=args.vad_model)
        reference_chars = normalized_characters(item["reference"])
        hypothesis_chars = normalized_characters(hypothesis)
        if not reference_chars:
            raise ValueError(f"empty normalized reference for {item['id']}")
        char_errors = edit_distance(reference_chars, hypothesis_chars)
        result = {"id": item["id"], "subject": item["subject"],
                  "language": item["language"], "characterErrors": char_errors,
                  "referenceCharacters": len(reference_chars), "elapsedSeconds": round(seconds, 3),
                  "validUTF8": valid_utf8}
        if item["language"] == "en":
            reference_words = normalized_words(item["reference"])
            result["wordErrors"] = edit_distance(reference_words, normalized_words(hypothesis))
            result["referenceWords"] = len(reference_words)
        results.append(result)

    char_errors = sum(item["characterErrors"] for item in results)
    char_count = sum(item["referenceCharacters"] for item in results)
    report = {"samples": len(results), "modelSHA256": digest.hexdigest(),
              "vadModelSHA256": hashlib.sha256(args.vad_model.read_bytes()).hexdigest()
                  if args.vad_model is not None else None,
              "characterErrorRate": round(char_errors / char_count, 4),
              "invalidUTF8Samples": sum(not item["validUTF8"] for item in results),
              "elapsedSeconds": round(sum(item["elapsedSeconds"] for item in results), 3),
              "items": results, "note": "Rights references are recorded but not legally verified."}
    english = [item for item in results if item["language"] == "en"]
    if english:
        report["englishWordErrorRate"] = round(
            sum(item["wordErrors"] for item in english) / sum(item["referenceWords"] for item in english), 4)
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
