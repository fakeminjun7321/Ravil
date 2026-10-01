#!/usr/bin/env python3
"""Offline decoder LoRA pilot: source-separated public references plus explicit pseudo-labels."""
import argparse
import json
import math
import os
from pathlib import Path
import random
import shutil
import time

from asr_training_data import read_rows, assert_disjoint, mask_assistant_labels
from prepare_asr_training_pilot import digest
from evaluate_local_stt import normalized_characters, normalized_words, edit_distance

BASE = "Qwen/Qwen3-ASR-0.6B-hf"
REVISION = "7f1569a48a89f3e3f4dc3a5c9d28bddd903bc76c"
WEIGHT_SHA = "d3f212dd20abecd315d830bc54ae3865e56ebfc3276484e57b771288ba27fd35"
SEED = 261001


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", type=Path, required=True)
    p.add_argument("--pseudo", type=Path, required=True)
    p.add_argument("--hf-home", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--epochs", type=int, default=2)
    p.add_argument("--allow-pseudo-labels", action="store_true")
    args = p.parse_args()
    if args.output.exists() or not 1 <= args.epochs <= 3:
        p.error("new output directory and 1–3 epochs required")
    os.umask(0o077)
    os.environ["HF_HOME"] = str(args.hf_home.resolve())
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    import torch
    from huggingface_hub import hf_hub_download
    from transformers import AutoProcessor, AutoModelForMultimodalLM, logging
    from peft import LoraConfig, get_peft_model, PeftModel

    train_paths = [args.data / "public-train.jsonl", args.pseudo / "private-train.jsonl"]
    val_paths = [args.data / "public-validation.jsonl", args.pseudo / "private-validation.jsonl"]
    test_paths = [args.data / "public-test.jsonl"]
    train = read_rows(train_paths, "train", args.allow_pseudo_labels)
    val = read_rows(val_paths, "validation", args.allow_pseudo_labels)
    test = read_rows(test_paths, "test")
    assert_disjoint(train, val, test)
    if not train or not val or not test:
        raise ValueError("all public splits must be present")
    for row in train + val + test:
        if digest(Path(row["audio_path"])) != row["audio_sha256"]:
            raise ValueError("audio content differs from its frozen manifest")
    args.output.mkdir(parents=True)
    torch.manual_seed(SEED)
    random.seed(SEED)
    logging.set_verbosity_error()
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    dtype = torch.float16 if device == "mps" else torch.float32
    weight_path = Path(hf_hub_download(BASE, "model.safetensors", revision=REVISION, local_files_only=True))
    if digest(weight_path) != WEIGHT_SHA:
        raise ValueError("base model checksum mismatch")
    processor = AutoProcessor.from_pretrained(BASE, revision=REVISION, local_files_only=True)
    base = AutoModelForMultimodalLM.from_pretrained(BASE, revision=REVISION, local_files_only=True,
                                                   dtype=dtype).to(device)
    targets = [name for name, _ in base.named_modules()
               if name.endswith(("q_proj", "v_proj")) and "audio" not in name]
    if not targets or any("language_model" not in name for name in targets):
        raise ValueError("unexpected decoder LoRA target layout")
    model = get_peft_model(base, LoraConfig(r=8, lora_alpha=16, lora_dropout=.05,
                                           target_modules=targets, bias="none"))
    initial = {name: value.detach().cpu().clone() for name, value in model.named_parameters() if value.requires_grad}
    marker = processor.tokenizer.encode("<|im_start|>assistant\n", add_special_tokens=False)

    def training_input(row):
        language = {"ko": "Korean", "en": "English"}[row["language"]]
        messages = [[{"role": "user", "content": [{"type": "audio", "path": row["audio_path"]}]},
                     {"role": "assistant", "content": [{"type": "text", "text": f"language {language}<asr_text>{row['reference']}"}]}]]
        inputs = processor.apply_chat_template(messages, tokenize=True, return_dict=True,
                                              processor_kwargs={"output_labels": True})
        inputs["labels"] = mask_assistant_labels(inputs["input_ids"], inputs["labels"], marker)
        return inputs

    # CPU feature cache: keep training activations off the device between steps.
    features = {r["id"]: training_input(r) for r in train + val}

    def validation_loss():
        model.eval()
        losses = {"public_reference": [], "dual_asr_agreement": []}
        with torch.no_grad():
            for row in val:
                inputs = {k:v.to(device=device, dtype=dtype if v.is_floating_point() else v.dtype)
                          for k,v in features[row["id"]].items()}
                value = float(model(**inputs, use_cache=False).loss.item())
                if not math.isfinite(value):
                    raise ValueError("non-finite validation loss")
                losses[row["label_source"]].append(value)
        return {key: sum(values) / len(values) for key, values in losses.items() if values}

    def evaluate(rows, label):
        model.eval()
        items = []
        for index, row in enumerate(rows):
            inputs = processor.apply_transcription_request(audio=row["audio_path"],
                language={"ko": "Korean", "en": "English"}[row["language"]]).to(device, dtype)
            with torch.inference_mode():
                out = model.generate(**inputs, max_new_tokens=256)
            tokens = out[:, inputs['input_ids'].shape[1]:]
            if tokens.shape[1] >= 256:
                raise ValueError("evaluation reached output token limit")
            prediction = processor.decode(tokens, return_format="transcription_only")[0]
            chars = normalized_characters(row["reference"])
            words = normalized_words(row["reference"])
            items.append({"id": row["id"], "language": row["language"], "labelSource": row["label_source"],
                "characterErrors": edit_distance(chars, normalized_characters(prediction)), "referenceCharacters": len(chars),
                "wordErrors": edit_distance(words, normalized_words(prediction)), "referenceWords": len(words),
                "prediction": prediction})
            if (index + 1) % 10 == 0 or index + 1 == len(rows):
                print(json.dumps({"stage": label, "processed": index + 1, "total": len(rows)}), flush=True)
        summary = {}
        for language in ("ko", "en"):
            subset = [x for x in items if x["language"] == language]
            if subset:
                summary[language] = {"samples": len(subset),
                    "CER": sum(x['characterErrors'] for x in subset) / sum(x['referenceCharacters'] for x in subset),
                    "WER": sum(x['wordErrors'] for x in subset) / sum(x['referenceWords'] for x in subset)}
        return {"summary": summary, "items": items}

    print(json.dumps({"stage": "prepared", "device": device, "train": len(train), "validation": len(val),
        "publicTest": len(test), "trainableParameters": sum(v.numel() for v in initial.values()),
        "privatePseudoTrain": sum(r['label_source'] == 'dual_asr_agreement' for r in train)}), flush=True)
    baseline_val = validation_loss()
    baseline = evaluate(test, "baseline-public-test")
    private_val = [r for r in val if r["label_source"] == "dual_asr_agreement"]
    baseline_private = evaluate(private_val, "baseline-private-proxy") if private_val else None
    (args.output / "baseline.json").write_text(json.dumps({"public": baseline, "privateProxy": baseline_private}, ensure_ascii=False, indent=2))
    optimizer = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=2e-5, weight_decay=.01)
    epochs = []
    optimizer_steps = 0
    started = time.perf_counter()
    for epoch in range(1, args.epochs + 1):
        model.train()
        base.model.audio_tower.eval()
        order = list(train)
        random.Random(SEED + epoch).shuffle(order)
        losses = []
        for start in range(0, len(order), 4):
            batch = order[start:start + 4]
            optimizer.zero_grad(set_to_none=True)
            for row in batch:
                inputs = {k:v.to(device=device, dtype=dtype if v.is_floating_point() else v.dtype)
                          for k,v in features[row["id"]].items()}
                loss = model(**inputs, use_cache=False).loss
                value = float(loss.detach().item())
                if not math.isfinite(value):
                    raise ValueError("non-finite training loss")
                losses.append(value)
                (loss / len(batch)).backward()
            norm = torch.nn.utils.clip_grad_norm_([p for p in model.parameters() if p.requires_grad], 1.0)
            if not torch.isfinite(norm).item():
                raise ValueError("non-finite gradient norm")
            optimizer.step()
            optimizer_steps += 1
            if optimizer_steps % 5 == 0 or start + 4 >= len(order):
                print(json.dumps({"stage": "training", "epoch": epoch, "samples": min(start + 4, len(order)),
                                  "optimizerSteps": optimizer_steps, "loss": round(value, 4)}), flush=True)
        validation = validation_loss()
        checkpoint = args.output / f"epoch-{epoch}"
        model.save_pretrained(checkpoint, safe_serialization=True)
        epochs.append({"epoch": epoch, "validationLoss": validation, "trainingLoss": sum(losses) / len(losses),
                       "checkpoint": str(checkpoint.resolve())})
        print(json.dumps({"stage": "epoch-saved", **epochs[-1]}), flush=True)
    training_seconds = time.perf_counter() - started
    changed = sum(not torch.equal(initial[n], p.detach().cpu()) for n,p in model.named_parameters() if n in initial)
    if not changed:
        raise ValueError("no adapter weights changed")
    # Select with validation loss only. Public test scores are not used for epoch selection.
    selected = min(epochs, key=lambda row: row["validationLoss"]["public_reference"])
    selected_dir = args.output / "adapter"
    shutil.copytree(selected["checkpoint"], selected_dir)
    del optimizer, features, initial
    model = model.unload()
    model = PeftModel.from_pretrained(model, selected_dir, is_trainable=False).to(device)
    adapted = evaluate(test, "reloaded-adapter-public-test")
    adapted_private = evaluate(private_val, "reloaded-adapter-private-proxy") if private_val else None
    report = {"name": "Ravil-ASMR-0.6-adapter-pilot", "base": BASE, "revision": REVISION, "baseSHA256": WEIGHT_SHA,
        "seed": SEED, "device": device, "rank": 8, "alpha": 16, "learningRate": 2e-5,
        "trainingSamples": len(train), "publicTrain": sum(r['label_source']=='public_reference' for r in train),
        "pseudoTrain": sum(r['label_source']=='dual_asr_agreement' for r in train),
        "manifestSHA256": {str(path): digest(path) for path in train_paths + val_paths + test_paths},
        "baselineValidationLoss": baseline_val, "epochs": epochs, "selectedEpoch": selected['epoch'],
        "optimizerSteps": optimizer_steps, "changedAdapterTensors": changed, "trainingSeconds": training_seconds,
        "adapterSHA256": digest(selected_dir / 'adapter_model.safetensors'),
        "baseline": baseline['summary'], "adapted": adapted['summary'],
        "baselinePrivateTeacherAgreement": baseline_private['summary'] if baseline_private else None,
        "adaptedPrivateTeacherAgreement": adapted_private['summary'] if adapted_private else None,
        "humanClassroomAccuracyVerified": False, "promotionEligible": False,
        "publicNonRegressionGate": (adapted['summary']['ko']['CER'] <= baseline['summary']['ko']['CER']
                                    and adapted['summary']['en']['WER'] <= baseline['summary']['en']['WER']),
        "status": "trained and reloaded locally; not approved for publication or replacing the app model"}
    (args.output / "adapted.json").write_text(json.dumps({"public": adapted, "privateProxy": adapted_private}, ensure_ascii=False, indent=2))
    (args.output / "experiment.json").write_text(json.dumps(report, indent=2))
    (selected_dir / "RAVIL_MODEL_CARD.md").write_text(
        "# Ravil-ASMR-0.6-adapter-pilot\n\n"
        f"LoRA adapter trained by Ravil from [{BASE}](https://huggingface.co/{BASE}), "
        f"revision `{REVISION}`, Apache-2.0. The adapter requires the base weights.\n\n"
        "Ravil changes: decoder q/v rank-8 LoRA, alpha 16, dropout 0.05, learning rate 2e-5. "
        f"{len(train)} training pairs, {optimizer_steps} optimizer updates, selected epoch {selected['epoch']}. "
        "Audio encoder and original base weights were frozen.\n\n"
        "Public data: Google FLEURS ko_kr and en_us dev, revision "
        "`70bb2e84b976b7e960aa89f1c648e09c59f894dd`, CC BY 4.0. "
        "Attribution: Conneau et al., FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech (2022), "
        "https://huggingface.co/datasets/google/fleurs . Audio/reference pairs were subsetted and source-group split.\n\n"
        "Private data: user-authorized Alt recordings, local use only. Labels are filtered agreement between "
        "Qwen3-ASR 1.7B 6-bit (Apache-2.0) and Whisper large-v3-turbo q5_0 (MIT), not human ground truth. "
        "The original recordings were not altered or uploaded. See frozen manifests and selection.json for provenance.\n\n"
        f"Reloaded public evaluation: baseline {baseline['summary']}; adapter {adapted['summary']}. "
        "Private validation measures teacher agreement only. No human-verified classroom accuracy or app integration.\n\n"
        f"Adapter SHA-256: `{report['adapterSHA256']}`. "
        "Experimental and private; not approved for public redistribution. Retain all base, teacher, runtime and data notices "
        "and resolve release rights before publishing. This is an adapted open model, not a foundation model trained from scratch.\n",
        encoding="utf-8")
    print(json.dumps({"stage": "complete", **report}), flush=True)


if __name__ == "__main__":
    main()
