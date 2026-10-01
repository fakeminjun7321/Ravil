"""English-only native timestamp adapter for pinned Parakeet models."""
from types import SimpleNamespace
import math
import time

import numpy as np

from evaluate_local_stt import normalized_characters
from ravil_asr_longform import SAMPLE_RATE


def native_words(result, duration):
    words = []
    current = []

    def emit():
        if current:
            text = "".join(t.text for t in current).strip()
            if text:
                words.append(SimpleNamespace(text=text, start_time=current[0].start,
                                             end_time=max(t.end for t in current)))
            current.clear()

    previous_start = 0.0
    for sentence in result.sentences:
        for token in sentence.tokens:
            start, end = float(token.start), float(token.end)
            if (not all(map(math.isfinite, (start, end))) or start < 0 or end < start
                    or end > duration + .5 or start < previous_start):
                raise ValueError("native model returned invalid timestamps")
            previous_start = start
            if token.text[:1].isspace():
                emit()
            current.append(SimpleNamespace(text=token.text, start=min(start, duration), end=min(end, duration)))
        emit()
    if normalized_characters(" ".join(w.text for w in words)) != normalized_characters(result.text):
        raise ValueError("native timestamp tokens differ from transcription")
    return words


def transcribe_native(source, decode, clear_cache=None, progress=None, boundaries=()):
    words = []
    metrics = {"audioSeconds": source.duration, "asrSeconds": 0.0, "windows": [],
               "alignmentSeconds": 0.0, "alignment": "model-native; no separate aligner"}
    for window in source.windows(boundaries=boundaries):
        audio = source.read(window.read_start, window.read_end)
        entry = {"startSeconds": window.start / SAMPLE_RATE, "endSeconds": window.end / SAMPLE_RATE}
        if not np.any(audio[window.start - window.read_start:window.end - window.read_start]):
            entry.update(status="digital_silence", words=0)
        else:
            started = time.perf_counter()
            result = decode(audio)
            metrics["asrSeconds"] += time.perf_counter() - started
            local = native_words(result, len(audio) / SAMPLE_RATE)
            count = 0
            for w in local:
                start = w.start_time + window.read_start / SAMPLE_RATE
                end = w.end_time + window.read_start / SAMPLE_RATE
                if window.start <= (start + end) / 2 * SAMPLE_RATE < window.end:
                    words.append(SimpleNamespace(text=w.text,
                        start_time=max(start, window.start / SAMPLE_RATE),
                        end_time=min(end, window.end / SAMPLE_RATE)))
                    count += 1
            entry.update(status="transcribed", words=count)
        metrics["windows"].append(entry)
        if progress:
            progress({"processedSeconds": entry["endSeconds"], "audioSeconds": source.duration})
        if clear_cache:
            clear_cache()
    metrics.update(asrSeconds=round(metrics["asrSeconds"], 3), words=len(words))
    return words, metrics
