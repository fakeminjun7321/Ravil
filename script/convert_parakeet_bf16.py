#!/usr/bin/env python3
"""Persist the measured Parakeet BF16 inference weights, preserving source attribution."""
import argparse
import json
from pathlib import Path
import shutil

from asr_candidates import load_candidate, digest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--models", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    if args.output.exists():
        p.error("output directory must be new")
    import mlx.core as mx
    from mlx.utils import tree_flatten
    model, spec = load_candidate("parakeet-v3-bf16", args.models)
    args.output.mkdir(parents=True)
    original = args.models / spec["directory"]
    for filename in ("config.json", "tokenizer.model", "tokenizer.vocab", "vocab.txt"):
        shutil.copyfile(original / filename, args.output / filename)
    weights = args.output / "model.safetensors"
    mx.save_safetensors(str(weights), dict(tree_flatten(model.parameters())))
    provenance = {"source": spec, "conversion": "FP32 source to BF16; no training, same dtype used in measured inference",
                  "sha256": digest(weights), "bytes": weights.stat().st_size,
                  "runtimeCommit": "94c7716212b2228f178d2f9c7619a591fd1b0b78"}
    (args.output / "conversion.json").write_text(json.dumps(provenance, indent=2) + "\n")
    (args.output / "README.md").write_text(
        "# Ravil-ASMR-0.5 English BF16 experiment\n\n"
        "Derived from NVIDIA parakeet-tdt-0.6b-v3 and its MLX Community conversion.\n"
        "Sources: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 and "
        "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3\n\n"
        "License: Creative Commons Attribution 4.0 (https://creativecommons.org/licenses/by/4.0/). "
        "Retain attribution to NVIDIA and MLX Community and identify Ravil's FP32-to-BF16 conversion. "
        "No additional training was performed; Korean and mixed Korean/English are unsupported. "
        "Not a released product. See conversion.json for pinned revision and checksums.\n")
    print(json.dumps(provenance), flush=True)


if __name__ == "__main__":
    main()
