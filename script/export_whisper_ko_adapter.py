#!/usr/bin/env python3
"""Merge a Ravil Whisper LoRA adapter and convert it to whisper.cpp GGML."""

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

from huggingface_hub import hf_hub_download
from peft import PeftModel
from transformers import WhisperForConditionalGeneration, WhisperProcessor, logging

from train_whisper_ko_adapter import BASE_MODEL, BASE_REVISION


WHISPER_CPP_COMMIT = "6e4ab854f67f743900934a703d5603419384c961"
OPENAI_WHISPER_COMMIT = "86098128c0b4f24f0e2aa2994de830614b474227"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def revision(path: Path) -> str:
    return subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", type=Path, required=True)
    parser.add_argument("--whisper-cpp", type=Path, required=True)
    parser.add_argument("--openai-whisper", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if revision(args.whisper_cpp) != WHISPER_CPP_COMMIT or revision(args.openai_whisper) != OPENAI_WHISPER_COMMIT:
        parser.error("conversion source revisions differ from the pinned commits")
    experiment = json.loads((args.adapter / "experiment.json").read_text(encoding="utf-8"))
    adapter = args.adapter / "adapter_model.safetensors"
    if (experiment.get("baseModel") != BASE_MODEL or experiment.get("baseRevision") != BASE_REVISION
            or experiment.get("adapterSHA256") != sha256(adapter)):
        parser.error("adapter provenance or digest does not match its experiment report")

    logging.set_verbosity_error()
    args.output.mkdir(parents=True, exist_ok=True)
    merged_dir = args.output / "merged-hf"
    merged_dir.mkdir(exist_ok=True)
    base = WhisperForConditionalGeneration.from_pretrained(BASE_MODEL, revision=BASE_REVISION)
    merged = PeftModel.from_pretrained(base, args.adapter).merge_and_unload()
    merged.save_pretrained(merged_dir, safe_serialization=True)
    WhisperProcessor.from_pretrained(BASE_MODEL, revision=BASE_REVISION).save_pretrained(merged_dir)
    # Transformers 5 saves tokenizer.json but the pinned whisper.cpp converter
    # still expects the original vocab and added-token files.
    for name in ("vocab.json", "added_tokens.json"):
        source = hf_hub_download(BASE_MODEL, name, revision=BASE_REVISION)
        shutil.copyfile(source, merged_dir / name)
    required = ("config.json", "vocab.json", "added_tokens.json")
    if any(not (merged_dir / name).is_file() for name in required):
        parser.error("merged Hugging Face model lacks files required by whisper.cpp converter")

    command = [sys.executable, str(args.whisper_cpp / "models/convert-h5-to-ggml.py"),
               str(merged_dir), str(args.openai_whisper), str(args.output)]
    log_path = args.output / "conversion.log"
    with log_path.open("w", encoding="utf-8") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=False)
    if result.returncode:
        raise RuntimeError(f"whisper.cpp conversion failed; inspect {log_path}")
    generated = args.output / "ggml-model.bin"
    if not generated.is_file():
        raise RuntimeError("whisper.cpp converter returned success without a model file")
    ggml = args.output / "ggml-ravil-stt-tiny-ko-lora-v1.bin"
    generated.replace(ggml)
    shutil.copyfile(args.adapter / "MODEL_CARD.md", args.output / "MODEL_CARD.md")
    with (args.output / "MODEL_CARD.md").open("a", encoding="utf-8") as card:
        card.write(
            "\n## Local runtime export\n\n"
            f"Merged adapter converted to GGML f16 by [whisper.cpp](https://github.com/ggml-org/whisper.cpp) "
            f"at commit `{WHISPER_CPP_COMMIT}`, using [OpenAI Whisper assets](https://github.com/openai/whisper) "
            f"at commit `{OPENAI_WHISPER_COMMIT}`. GGML SHA-256: `{sha256(ggml)}`. "
            "Conversion does not change the experimental release status.\n")
    report = {"ggmlPath": str(ggml.resolve()), "ggmlSHA256": sha256(ggml),
              "adapterSHA256": sha256(adapter), "whisperCppCommit": WHISPER_CPP_COMMIT,
              "openaiWhisperCommit": OPENAI_WHISPER_COMMIT,
              "status": "experimental; not approved for app integration or publication"}
    (args.output / "export.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
