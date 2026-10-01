"""Data and label-mask checks for Ravil's first Qwen adapter experiment."""
import json
from pathlib import Path


def read_rows(paths, split, allow_pseudo=False):
    rows = []
    for path in paths:
        rows.extend(json.loads(line) for line in Path(path).read_text().splitlines() if line.strip())
    for row in rows:
        if (row.get("split") != split or row.get("language") not in ("ko", "en")
                or not row.get("source_group") or not row.get("audio_sha256")
                or not row.get("rights_reference") or not row.get("reference", "").strip()
                or not Path(row.get("audio_path", "")).is_file()):
            raise ValueError(f"invalid {split} metadata")
        if any(marker in row["reference"] for marker in ("<|", "<asr_text>")):
            raise ValueError("reference contains model control tokens")
        kind = row.get("label_source")
        if kind == "dual_asr_agreement":
            if not allow_pseudo or row.get("human_verified") is not False:
                raise ValueError("pseudo-labels must be explicitly enabled and not marked human verified")
        elif kind not in ("public_reference", "human_reviewed"):
            raise ValueError("unreviewed automatic transcript is not an accepted label source")
    if len({r["id"] for r in rows}) != len(rows):
        raise ValueError("duplicate sample identifiers")
    return rows


def assert_disjoint(*splits):
    for i, left in enumerate(splits):
        for right in splits[i + 1:]:
            for key in ("id", "source_group", "audio_sha256"):
                if {r[key] for r in left} & {r[key] for r in right}:
                    raise ValueError(f"training/evaluation leakage via {key}")


def mask_assistant_labels(input_ids, labels, assistant_marker):
    """Mask prompt tokens too: HF output_labels only masks audio and padding."""
    tokens = input_ids[0].tolist()
    starts = [i for i in range(len(tokens) - len(assistant_marker) + 1)
              if tokens[i:i + len(assistant_marker)] == assistant_marker]
    if len(starts) != 1:
        raise ValueError("expected exactly one assistant turn")
    start = starts[0] + len(assistant_marker)
    result = labels.clone()
    result[:, :start] = -100
    if not (result != -100).any().item():
        raise ValueError("no supervised assistant tokens")
    return result
