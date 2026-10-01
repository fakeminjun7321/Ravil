#!/usr/bin/env python3
"""Download a source-attributed candidate at its pinned revision, then verify weights."""
import argparse
from pathlib import Path

from asr_candidates import candidate_spec, digest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("candidate")
    p.add_argument("--models", type=Path, required=True)
    args = p.parse_args()
    spec = candidate_spec(args.candidate)
    if spec.get("localConversion"):
        p.error("this candidate is built locally by convert_parakeet_bf16.py")
    from huggingface_hub import snapshot_download
    directory = args.models / spec["directory"]
    snapshot_download(spec["repo"], revision=spec["revision"], local_dir=directory,
        allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model", "*.vocab", "README.md", "LICENSE*"],
        max_workers=2)
    if digest(directory / "model.safetensors") != spec["sha256"]:
        raise SystemExit("model SHA-256 mismatch; candidate was not accepted")
    print(f"Verified {spec['repo']} at {spec['revision']} ({spec['license']})")


if __name__ == "__main__":
    main()
