#!/usr/bin/env python3
"""Train a small local Whisper LoRA experiment on pinned, attributed FLEURS Korean audio."""

import argparse
import hashlib
import json
import random
import time
from pathlib import Path

import soundfile as sf
import torch
from peft import LoraConfig, get_peft_model
from transformers import WhisperForConditionalGeneration, WhisperProcessor, logging

from evaluate_local_stt import edit_distance, normalized_characters


BASE_MODEL = "openai/whisper-tiny"
BASE_REVISION = "169d4a4341b33bc18d8881c4b69c2e104e1cc0af"
DATASET_REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
SEED = 240930


def load_rows(path: Path, split: str) -> list[dict]:
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not rows:
        raise ValueError(f"empty {split} manifest")
    for row in rows:
        if (row.get("split") != split or row.get("license") != "CC-BY-4.0"
                or row.get("source_split") != ("dev" if split == "train" else "test")
                or not row.get("rights_reference", "").endswith(DATASET_REVISION)
                or not Path(row.get("audio_path", "")).is_file()
                or not row.get("reference")):
            raise ValueError(f"{split} manifest has missing or unexpected provenance")
    return rows


def features_and_labels(processor, row: dict):
    audio, sample_rate = sf.read(row["audio_path"], dtype="float32")
    if sample_rate != 16000 or audio.ndim != 1:
        raise ValueError(f"unexpected FLEURS audio format for {row['id']}")
    features = processor.feature_extractor(
        audio, sampling_rate=sample_rate, return_tensors="pt").input_features
    labels = torch.tensor([processor.tokenizer(row["reference"]).input_ids])
    return features, labels


def evaluate(model, processor, rows: list[dict], device: str) -> dict:
    model.eval()
    errors = 0
    characters = 0
    timings = []
    for row in rows:
        features, _ = features_and_labels(processor, row)
        started = time.monotonic()
        with torch.no_grad():
            tokens = model.generate(input_features=features.to(device), language="ko",
                                    task="transcribe", max_new_tokens=128)
        prediction = processor.batch_decode(tokens, skip_special_tokens=True,
                                            clean_up_tokenization_spaces=False)[0]
        reference_chars = normalized_characters(row["reference"])
        errors += edit_distance(reference_chars, normalized_characters(prediction))
        characters += len(reference_chars)
        timings.append(time.monotonic() - started)
    return {"samples": len(rows), "characterErrors": errors,
            "referenceCharacters": characters, "characterErrorRate": round(errors / characters, 4),
            "inferenceSeconds": round(sum(timings), 3)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--train", type=Path, required=True)
    parser.add_argument("--eval", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-train-samples", type=int, default=64)
    parser.add_argument("--epochs", type=int, default=1)
    args = parser.parse_args()
    if args.max_train_samples < 1 or not 1 <= args.epochs <= 10:
        parser.error("sample count must be positive and epochs must be 1–10")
    train_rows = load_rows(args.train, "train")[:args.max_train_samples]
    eval_rows = load_rows(args.eval, "eval")
    if {row["id"] for row in train_rows} & {row["id"] for row in eval_rows}:
        parser.error("training and evaluation ids overlap")

    random.seed(SEED)
    torch.manual_seed(SEED)
    logging.set_verbosity_error()
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    processor = WhisperProcessor.from_pretrained(BASE_MODEL, revision=BASE_REVISION,
                                                 language="ko", task="transcribe")
    base = WhisperForConditionalGeneration.from_pretrained(BASE_MODEL, revision=BASE_REVISION)
    model = get_peft_model(base, LoraConfig(r=4, lora_alpha=8, lora_dropout=0.05,
                                           target_modules=["q_proj", "v_proj"], bias="none"))
    model.to(device)
    print(json.dumps({"stage": "baseline", "device": device,
                      "trainableParameters": sum(p.numel() for p in model.parameters() if p.requires_grad)}),
          flush=True)
    baseline = evaluate(model, processor, eval_rows, device)
    print(json.dumps({"stage": "baseline-evaluated", **baseline}), flush=True)

    model.train()
    optimizer = torch.optim.AdamW((p for p in model.parameters() if p.requires_grad), lr=1e-4)
    losses = []
    started = time.monotonic()
    optimizer.zero_grad(set_to_none=True)
    for epoch in range(1, args.epochs + 1):
        order = list(range(len(train_rows)))
        random.Random(SEED + epoch).shuffle(order)
        for number, index in enumerate(order, start=1):
            features, labels = features_and_labels(processor, train_rows[index])
            loss = model(input_features=features.to(device), labels=labels.to(device)).loss
            (loss / 4).backward()
            losses.append(float(loss.detach().cpu()))
            if number % 4 == 0 or number == len(order):
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                optimizer.step()
                optimizer.zero_grad(set_to_none=True)
            if number % 32 == 0 or number == len(order):
                print(json.dumps({"stage": "training", "epoch": epoch,
                                  "samplesSeen": number, "latestLoss": round(losses[-1], 4)}),
                      flush=True)

    training_seconds = time.monotonic() - started
    adapted = evaluate(model, processor, eval_rows, device)
    args.output.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(args.output, safe_serialization=True)
    adapter_path = args.output / "adapter_model.safetensors"
    adapter_hash = hashlib.sha256(adapter_path.read_bytes()).hexdigest()
    report = {"baseModel": BASE_MODEL, "baseRevision": BASE_REVISION,
              "dataset": "google/fleurs ko_kr", "datasetRevision": DATASET_REVISION,
              "datasetLicense": "CC-BY-4.0", "trainSourceSplit": "dev",
              "evalSourceSplit": "test", "trainSamples": len(train_rows),
              "evalSamples": len(eval_rows), "seed": SEED, "device": device,
              "epochs": args.epochs,
              "baseline": baseline, "adapted": adapted,
              "meanTrainingLoss": round(sum(losses) / len(losses), 4),
              "trainingSeconds": round(training_seconds, 3),
              "adapterSHA256": adapter_hash,
              "status": "experimental; not approved for app integration or publication"}
    (args.output / "experiment.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.output / "MODEL_CARD.md").write_text(
        f"# Ravil-ASMR-0.1-experimental (Korean STT LoRA)\n\n"
        f"Status: experimental. Not approved for Ravil app integration or publication.\n\n"
        f"- Base weights: [{BASE_MODEL}](https://huggingface.co/{BASE_MODEL}), revision `{BASE_REVISION}`. "
        f"The original [OpenAI Whisper repository](https://github.com/openai/whisper) states MIT; "
        f"the Hugging Face checkpoint page labels this conversion Apache-2.0. Resolve and retain both notices before any release.\n"
        f"- Training data: [Google FLEURS Korean](https://huggingface.co/datasets/google/fleurs), "
        f"revision `{DATASET_REVISION}`, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). "
        f"Source split: dev, {len(train_rows)} samples. The audio was used to train a LoRA adapter; "
        f"the dataset archive itself is not redistributed. "
        f"Attribution: Conneau et al., *FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech* (2022).\n"
        f"- Held-out evaluation: FLEURS Korean test, {len(eval_rows)} samples. "
        f"Baseline CER {baseline['characterErrorRate']}; adapter CER {adapted['characterErrorRate']}. "
        f"This is read speech, not real classroom audio.\n"
        f"- Ravil changes: rank-4 LoRA on Whisper attention q_proj and v_proj; "
        f"{len(train_rows)} samples, {args.epochs} passes, seed {SEED}, learning rate 1e-4.\n"
        f"- Adapter SHA-256: `{adapter_hash}`. The adapter requires the named base model.\n\n"
        f"No school recordings, Goodnotes documents, or Alt outputs were used for training.\n",
        encoding="utf-8")
    print(json.dumps({"stage": "complete", **report}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
