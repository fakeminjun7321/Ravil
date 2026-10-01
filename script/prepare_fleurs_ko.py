#!/usr/bin/env python3
"""Prepare a small, pinned FLEURS Korean LoRA experiment without user recordings."""

import argparse
import csv
import hashlib
import json
import random
import re
import tarfile
from pathlib import Path


DATASET_REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
DATASET_URL = "https://huggingface.co/datasets/google/fleurs"
EXPECTED_SHA256 = {
    "dev.tar.gz": "496edcb5323e75b4a2830f5b5623684a0baf86d3728101853fd4fe503372157c",
    "dev.tsv": "6b236de107c6a1672233f6d710d26adfdb55570a3e6e35aca9dc4ff2be01cea4",
    "test.tar.gz": "3489e529f2aad18d3357b746c5f955941d258b79dc60d8a102d5bced2a223184",
    "test.tsv": "cf2f7c8765f6203e3c46ef620d5e936d3f331b6e8865455557777dd1347517f5",
}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def selected_rows(tsv: Path, count: int, seed: int) -> list[list[str]]:
    with tsv.open(encoding="utf-8", newline="") as source:
        rows = list(csv.reader(source, delimiter="\t"))
    by_sentence: dict[str, list[str]] = {}
    for row in rows:
        if len(row) < 4 or not row[0].strip() or not row[2].strip():
            continue
        if not re.fullmatch(r"[0-9]+\.wav", row[1]):
            raise ValueError("unexpected FLEURS audio filename")
        by_sentence.setdefault(row[0], row)
    if count > len(by_sentence):
        raise ValueError("requested more unique sentences than the source provides")
    identifiers = sorted(by_sentence)
    random.Random(seed).shuffle(identifiers)
    return [by_sentence[key] for key in identifiers[:count]]


def prepare(split: str, count: int, source_dir: Path, output_dir: Path, seed: int) -> list[dict]:
    rows = selected_rows(source_dir / f"{split}.tsv", count, seed)
    destination = output_dir / ("train" if split == "dev" else "eval")
    destination.mkdir(parents=True, exist_ok=True)
    result = []
    wanted = {f"{split}/{row[1]}": row for row in rows}
    found = set()
    with tarfile.open(source_dir / f"{split}.tar.gz", "r:gz") as archive:
        for member in archive:
            row = wanted.get(member.name)
            if row is None:
                continue
            sentence_id, filename, reference = row[:3]
            if not member.isfile():
                raise ValueError("FLEURS audio member is not a file")
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError("FLEURS audio member cannot be read")
            path = destination / filename
            with path.open("wb") as target:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    target.write(chunk)
            found.add(member.name)
            result.append({
                "id": f"fleurs-ko-{split}-{sentence_id}",
                "audio_path": str(path.resolve()), "reference": reference,
                "language": "ko", "subject": "general-read-speech",
                "split": "train" if split == "dev" else "eval",
                "rights_reference": DATASET_URL + "/tree/" + DATASET_REVISION,
                "license": "CC-BY-4.0", "source_split": split,
            })
    if found != set(wanted):
        raise ValueError("FLEURS archive is missing selected audio files")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--train-count", type=int, default=64)
    parser.add_argument("--eval-count", type=int, default=12)
    args = parser.parse_args()
    if not 1 <= args.train_count <= 129 or not 1 <= args.eval_count <= 270:
        parser.error("sample counts must fit the pinned FLEURS Korean splits")
    for name, expected in EXPECTED_SHA256.items():
        path = args.source_dir / name
        if not path.is_file() or digest(path) != expected:
            parser.error(f"FLEURS input missing or SHA-256 mismatch: {name}")

    train = prepare("dev", args.train_count, args.source_dir, args.output_dir, seed=240930)
    evaluation = prepare("test", args.eval_count, args.source_dir, args.output_dir, seed=930240)
    for name, rows in (("train", train), ("eval", evaluation)):
        (args.output_dir / f"{name}.jsonl").write_text(
            "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")
    print(json.dumps({"train": len(train), "eval": len(evaluation),
                      "datasetRevision": DATASET_REVISION, "license": "CC-BY-4.0"}))


if __name__ == "__main__":
    main()
