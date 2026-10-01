#!/usr/bin/env python3
"""Compare a saved Ravil LoRA adapter with its pinned base on held-out Korean audio."""

import argparse
import json
from pathlib import Path

import torch
from peft import PeftModel
from transformers import WhisperForConditionalGeneration, WhisperProcessor, logging

from train_whisper_ko_adapter import BASE_MODEL, BASE_REVISION, evaluate, load_rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--eval", type=Path, required=True)
    parser.add_argument("--adapter", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    logging.set_verbosity_error()
    rows = load_rows(args.eval, "eval")
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    processor = WhisperProcessor.from_pretrained(BASE_MODEL, revision=BASE_REVISION,
                                                 language="ko", task="transcribe")
    base = WhisperForConditionalGeneration.from_pretrained(BASE_MODEL, revision=BASE_REVISION).to(device)
    baseline = evaluate(base, processor, rows, device)
    adapted = PeftModel.from_pretrained(base, args.adapter).to(device)
    result = evaluate(adapted, processor, rows, device)
    report = {"baseModel": BASE_MODEL, "baseRevision": BASE_REVISION,
              "evalSamples": len(rows), "device": device,
              "baseline": baseline, "adapted": result,
              "adapter": str(args.adapter.resolve()),
              "note": "General read speech only; not a lecture or Alt comparison."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
