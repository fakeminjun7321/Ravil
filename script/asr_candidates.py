"""Pinned offline candidate loading; no remote code or unpinned downloads."""
import hashlib
import json
import os
from pathlib import Path


REGISTRY = Path(__file__).resolve().parents[1] / "config/asr-candidates-20261001.json"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for data in iter(lambda: source.read(1024 * 1024), b""):
            value.update(data)
    return value.hexdigest()


def candidate_spec(name):
    return json.loads(REGISTRY.read_text())["candidates"][name]


def require_language(spec, language):
    if language not in spec["scope"]:
        raise ValueError(f"{spec['family']} candidate does not support requested scope: {language}")


def load_candidate(name, models):
    os.environ["HF_HUB_OFFLINE"] = "1"
    import mlx.core as mx
    from mlx.utils import tree_map
    from mlx_audio.stt import load
    spec = candidate_spec(name)
    directory = models / spec["directory"]
    if digest(directory / "model.safetensors") != spec["sha256"]:
        raise ValueError("candidate weight SHA-256 mismatch")
    model = load(directory, strict=True, model_type=spec["family"])
    if spec.get("inferenceDtype") == "bfloat16":
        model.update(tree_map(lambda w: w.astype(mx.bfloat16) if mx.issubdtype(w.dtype, mx.floating) else w,
                              model.parameters()))
        mx.eval(model.parameters())
        mx.clear_cache()
    return model, spec


def recognize(model, spec, audio, language):
    require_language(spec, language)
    if spec["family"] == "parakeet":
        return model.generate(audio, verbose=False)
    result = model.generate(audio, language={"ko": "Korean", "en": "English", "auto": None}[language],
                            max_tokens=512, verbose=False)
    if result.generation_tokens >= 512:
        raise ValueError("candidate hit output token limit")
    return result
