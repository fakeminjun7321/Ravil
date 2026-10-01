#!/usr/bin/env python3
"""Generate filtered private pseudo-labels; agreement is never human ground truth."""
import argparse
import json
import os
from pathlib import Path

from asr_candidates import load_candidate
from evaluate_local_stt import normalized_characters, edit_distance, transcribe
from prepare_asr_training_pilot import write_rows, digest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--input", type=Path, required=True)
    p.add_argument("--models", type=Path, required=True)
    p.add_argument("--whisper-app", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    os.umask(0o077)
    args.output.mkdir(parents=True, exist_ok=False)
    import mlx.core as mx
    teacher, spec = load_candidate("qwen-1.7b-6bit", args.models)
    resources = args.whisper_app.resolve() / "Contents/Resources"
    engine = resources / "Whisper/bin/whisper-cli"
    backends = resources / "Whisper/bin"
    weights = resources / "Models/ggml-large-v3-turbo-q5_0.bin"
    expected = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    if digest(weights) != expected:
        raise ValueError("Whisper teacher weights mismatch")
    accepted, rejected = [], []
    rows = list(map(json.loads, args.input.read_text().splitlines()))
    for number, row in enumerate(rows, 1):
        result = teacher.generate(row["audio_path"], language=None, max_tokens=256, verbose=False)
        languages = result.language if isinstance(result.language, list) else [result.language]
        language = {"Korean": "ko", "English": "en"}.get(languages[0] if len(languages) == 1 else None)
        normalized = normalized_characters(result.text)
        reason = None
        if language is None or result.generation_tokens >= 256 or not 10 <= len(normalized) <= row["duration_seconds"] * 25:
            reason = "unsupported language, empty/implausible length, or token limit"
        else:
            comparison = {**row, "language": language}
            whisper, _, valid = transcribe(engine, weights, backends, comparison)
            distance = edit_distance(normalized, normalized_characters(whisper)) / max(1, len(normalized))
            if not valid or distance > .12:
                reason = "teachers disagree or invalid output"
            else:
                accepted.append({**row, "reference": result.text.strip(), "language": language,
                    "label_source": "dual_asr_agreement", "human_verified": False,
                    "teacher": spec, "comparison_model": "Whisper large-v3-turbo q5_0",
                    "comparison_sha256": expected, "normalized_teacher_distance": distance,
                    "reference_warning": "Pseudo-label, not human ground truth; agreement can preserve shared errors"})
        if reason:
            rejected.append({"id": row["id"], "split": row["split"], "reason": reason})
        mx.clear_cache()
        print(json.dumps({"processed": number, "total": len(rows), "accepted": len(accepted)}), flush=True)
    for split in ("train", "validation"):
        write_rows(args.output / ("private-" + split + ".jsonl"), [r for r in accepted if r["split"] == split])
    report = {"accepted": len(accepted), "train": sum(r["split"] == "train" for r in accepted),
              "validation": sum(r["split"] == "validation" for r in accepted), "rejected": rejected,
              "status": "machine pseudo-labels only; no human-verified classroom accuracy"}
    (args.output / "selection.json").write_text(json.dumps(report, indent=2))
    print(json.dumps({k:v for k,v in report.items() if k != "rejected"}), flush=True)


if __name__ == "__main__":
    main()
