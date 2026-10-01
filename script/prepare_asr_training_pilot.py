#!/usr/bin/env python3
"""Prepare a private, source-group-separated bilingual adaptation pilot."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import tarfile


FLEURS_REV = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"


def write_rows(path, rows):
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1048576), b""):
            value.update(block)
    return value.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--inventory", type=Path, required=True)
    p.add_argument("--korean-dev", type=Path, required=True)
    p.add_argument("--english-dev", type=Path, required=True)
    p.add_argument("--public-test", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    os.umask(0o077)
    args.output.mkdir(parents=True, exist_ok=False)
    expected = {"dev.tar.gz": "2658fda72f199e12676ecac9415094667a4e14e149b146e568ea00b2a2f0954c",
                "dev.tsv": "9d57ee7e91e9d4c92edb39f6bbea668ef8dc2a3ff96eb510d5580b2ad05d17ec"}
    for name, sha in expected.items():
        if digest(args.english_dev / name) != sha:
            raise ValueError("FLEURS English dev checksum mismatch")
    ko = {r["id"].split("-")[-1]: r for r in map(json.loads, args.korean_dev.read_text().splitlines())}
    en = {}
    with (args.english_dev / "dev.tsv").open() as source:
        for row in csv.reader(source, delimiter="\t"):
            en.setdefault(row[0], row)
    shared = sorted(set(ko) & set(en))
    random.Random(261001).shuffle(shared)
    if len(shared) < 60:
        raise ValueError("not enough shared dev sentence groups")
    train_ids, validation_ids = set(shared[:48]), set(shared[48:60])
    selected = train_ids | validation_ids
    public = []
    destination = args.output / "public"
    destination.mkdir()
    wanted = {"dev/" + en[key][1]: key for key in selected}
    with tarfile.open(args.english_dev / "dev.tar.gz", "r:gz") as archive:
        for member in archive:
            key = wanted.get(member.name)
            if key is None:
                continue
            if not member.isfile():
                raise ValueError("unexpected archive member")
            path = destination / ("en-" + en[key][1])
            with archive.extractfile(member) as source:
                path.write_bytes(source.read())
            row = {"id": "fleurs-en-dev-" + key, "audio_path": str(path.resolve()),
                   "reference": en[key][2], "language": "en", "source_split": "dev",
                   "license": "CC-BY-4.0", "rights_reference": "https://huggingface.co/datasets/google/fleurs/tree/" + FLEURS_REV}
            public.extend([row, dict(ko[key])])
    if len(public) != 120:
        raise ValueError("missing selected public audio")
    for row in public:
        key = row["id"].split("-")[-1]
        row.update(split="train" if key in train_ids else "validation", source_group="fleurs-sentence-" + key,
                   label_source="public_reference", audio_sha256=digest(Path(row["audio_path"])))
    for split in ("train", "validation"):
        write_rows(args.output / ("public-" + split + ".jsonl"), [r for r in public if r["split"] == split])
    test = []
    for lang in ("korean", "english"):
        for row in list(map(json.loads, (args.public_test / (lang + ".jsonl")).read_text().splitlines()))[:20]:
            row.update(split="test", source_group="fleurs-sentence-" + row["id"].split("-")[-1],
                       label_source="public_reference", audio_sha256=digest(Path(row["audio_path"])))
            test.append(row)
    write_rows(args.output / "public-test.jsonl", test)

    inventory = json.loads(args.inventory.read_text())
    unique = {r["sha256"]: r for r in inventory}
    groups = sorted(unique)
    random.Random(261002).shuffle(groups)
    validation_groups = set(groups[:max(1, len(groups) // 4)])
    clips = []
    private = args.output / "private"
    private.mkdir()
    for group in groups:
        row = unique[group]
        split = "validation" if group in validation_groups else "train"
        for index, fraction in enumerate((.2, .5, .8)):
            seconds = min(16.0, row["duration"])
            start = max(0, min(row["duration"] * fraction, row["duration"] - seconds))
            identifier = f"class-{group[:12]}-{index}"
            target = private / (identifier + ".wav")
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-n", "-ss", str(start),
                "-i", row["path"], "-t", str(seconds), "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(target)], check=True)
            clips.append({"id": identifier, "audio_path": str(target.resolve()), "split": split,
                "source_group": "recording-" + group, "lecture_id": row["lecture_id"],
                "source_offset_seconds": start, "duration_seconds": seconds,
                "audio_sha256": digest(target), "label_source": "unlabeled", "human_verified": False,
                "rights_reference": "User explicitly authorizes all Alt recordings for local model training/evaluation in this conversation",
                "public_distribution": False})
    write_rows(args.output / "private-unlabeled.jsonl", clips)
    summary = {"publicTrain": 96, "publicValidation": 24, "publicTest": len(test),
               "privateClips": len(clips), "privateTrainGroups": len(groups) - len(validation_groups),
               "privateValidationGroups": len(validation_groups),
               "privateLabelStatus": "unlabeled; machine labels must remain explicitly identified"}
    (args.output / "preparation.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
