"""Bounded-memory Korean/English ASR windows; no model or network imports.

Core intervals cover the audio once. Context on each side is decoded again, but
an aligned word belongs to the core containing its midpoint. Actual repeated
words are never removed merely because their text matches a previous phrase.
"""

from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
import math
import time
import wave
import re
import subprocess

import numpy as np

from evaluate_local_stt import edit_distance, normalized_characters


SAMPLE_RATE = 16000
LANGUAGES = {"ko": "Korean", "en": "English", "auto": None}


def vad_boundaries(engine, model, source):
    """Use speech gaps as cut hints only; preserve every source sample."""
    result = subprocess.run(
        [str(engine), "-f", str(source.path), "-vm", str(model), "-vsd", "500", "-vp", "0", "-np"],
        capture_output=True, text=True, check=True, timeout=max(60, source.duration))
    count = re.search(r"Detected (\d+) speech segments:", result.stdout)
    matches = re.findall(r"Speech segment \d+: start = ([\d.]+), end = ([\d.]+)", result.stdout)
    if count is None or int(count[1]) != len(matches):
        raise ValueError("unexpected VAD output format")
    # whisper-vad-speech-segments explicitly outputs centiseconds, not seconds.
    segments = [(float(a) / 100, float(b) / 100) for a, b in matches]
    previous_end = 0
    for start, end in segments:
        if not 0 <= previous_end <= start <= end <= source.duration + .1:
            raise ValueError("invalid VAD timestamps")
        previous_end = end
    return [round((a[1] + b[0]) / 2 * SAMPLE_RATE)
            for a, b in zip(segments, segments[1:]) if b[0] - a[1] >= .5]


@dataclass(frozen=True)
class Window:
    start: int
    end: int
    read_start: int
    read_end: int


class PCMSource:
    def __init__(self, path: Path):
        self.path = path
        with wave.open(str(path), "rb") as source:
            if (source.getnchannels(), source.getframerate(), source.getsampwidth(),
                    source.getcomptype()) != (1, SAMPLE_RATE, 2, "NONE"):
                raise ValueError("input must be mono 16 kHz 16-bit PCM WAV")
            self.frames = source.getnframes()
        if self.frames <= 0:
            raise ValueError("input must contain audio frames")

    @property
    def duration(self):
        return self.frames / SAMPLE_RATE

    def read(self, start: int, end: int):
        with wave.open(str(self.path), "rb") as source:
            source.setpos(start)
            raw = source.readframes(end - start)
        if len(raw) != (end - start) * 2:
            raise ValueError("truncated WAV payload")
        return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0

    def window(self, start, end, context_seconds):
        context = round(context_seconds * SAMPLE_RATE)
        return Window(start, end, max(0, start - context), min(self.frames, end + context))

    def windows(self, chunk_seconds=30.0, context_seconds=1.0, boundaries=()):
        if not math.isfinite(chunk_seconds) or not 10 <= chunk_seconds <= 60:
            raise ValueError("chunk_seconds must be between 10 and 60")
        if not math.isfinite(context_seconds) or not 0 <= context_seconds <= 2:
            raise ValueError("context_seconds must be between 0 and 2")
        start = 0
        maximum = round(chunk_seconds * SAMPLE_RATE)
        if list(boundaries) != sorted(set(boundaries)) or any(not 0 < b < self.frames for b in boundaries):
            raise ValueError("split boundaries must be ordered distinct frame positions")
        while start < self.frames:
            end = min(start + maximum, self.frames)
            hints = [b for b in boundaries if start + 4 * SAMPLE_RATE <= b < end]
            if hints:
                end = hints[0]
            elif end < self.frames:
                # Without a speech-gap hint, seek a low-energy boundary near the
                # length limit. This changes the split, never the retained audio.
                search_start = end - maximum // 5
                samples = self.read(search_start, end)
                block = SAMPLE_RATE // 10
                blocks = samples[:len(samples) // block * block].reshape(-1, block)
                energies = np.mean(blocks * blocks, axis=1)
                candidates = np.flatnonzero(energies <= float(energies.min()) * 1.05 + 1e-12)
                end = search_start + int(candidates[-1]) * block + block // 2
            yield self.window(start, end, context_seconds)
            start = end


def alignment_language(result, text, requested):
    detected = result.language
    if isinstance(detected, str):
        detected = [detected]
    detected = [str(value).lower() for value in (detected or [])]
    if requested == "auto" and any(value not in ("korean", "english", "ko", "en")
                                    for value in detected):
        raise ValueError("ASR detected a language outside Korean/English; review required")
    # Korean tokenizer retains Latin words, so mixed phrases keep the original text.
    if any("가" <= char <= "힣" for char in text):
        return "Korean"
    return "English"


def checked_words(words, text, duration):
    checked = []
    previous_end = 0.0
    for word in words:
        start, end = float(word.start_time), float(word.end_time)
        value = str(word.text).strip()
        if (not value or not all(map(math.isfinite, (start, end))) or start < 0
                or end < start or end > duration + 0.5 or start + 0.5 < previous_end):
            raise ValueError(f"invalid alignment timestamps: start={start}, end={end}, "
                             f"previousEnd={previous_end}, audioSeconds={duration}")
        checked.append(SimpleNamespace(start_time=min(start, duration),
                                       end_time=min(end, duration), text=value))
        previous_end = end
    original = normalized_characters(text)
    aligned = normalized_characters(" ".join(word.text for word in checked))
    if not original or edit_distance(original, aligned) / len(original) > 0.2:
        raise ValueError("aligned words differ materially from ASR text")
    return checked


def transcribe(source, asr, aligner, *, language="auto", chunk_seconds=30.0,
               context_seconds=1.0, max_tokens=512, progress=None, clear_cache=None,
               boundaries=()):
    if language not in LANGUAGES or not 32 <= max_tokens <= 2048:
        raise ValueError("invalid language or per-window token budget")
    metrics = {"audioSeconds": round(source.duration, 3), "asrSeconds": 0.0,
               "alignmentSeconds": 0.0, "tokenLimitRetries": 0,
               "alignmentRetries": 0,
               "languageContextRetries": 0,
               "silentWindows": 0, "windows": [], "inferenceCalls": 0}
    all_words = []

    def retry_split(window, depth, reason):
        if depth >= 3 or window.end - window.start < 8 * SAMPLE_RATE:
            raise ValueError(f"{reason}; bounded splitting exhausted at "
                             f"{window.start / SAMPLE_RATE:.2f}-{window.end / SAMPLE_RATE:.2f}s")
        middle = (window.start + window.end) // 2
        hints = [b for b in boundaries if window.start + 2 * SAMPLE_RATE < b < window.end - 2 * SAMPLE_RATE]
        if hints:
            middle = min(hints, key=lambda b: abs(b - middle))
        if clear_cache:
            clear_cache()
        process(source.window(window.start, middle, context_seconds), depth + 1)
        process(source.window(middle, window.end, context_seconds), depth + 1)

    def process(window, depth=0):
        audio = source.read(window.read_start, window.read_end)
        core_start = window.start - window.read_start
        core_end = window.end - window.read_start
        entry = {"startSeconds": window.start / SAMPLE_RATE,
                 "endSeconds": window.end / SAMPLE_RATE}
        # Skip only exact digital silence, never threshold away quiet speech.
        if not np.any(audio[core_start:core_end]):
            metrics["silentWindows"] += 1
            entry["status"] = "digital_silence"
            metrics["windows"].append(entry)
            return
        for attempt in range(2):
            started = time.perf_counter()
            generated = asr.generate(audio, language=LANGUAGES[language],
                                     max_tokens=max_tokens, verbose=False)
            metrics["asrSeconds"] += time.perf_counter() - started
            metrics["inferenceCalls"] += 1
            try:
                alignment_language(generated, generated.text, language)
                break
            except ValueError:
                if attempt:
                    raise ValueError("language remains outside Korean/English after context retry "
                                     f"at {window.start / SAMPLE_RATE:.2f}-{window.end / SAMPLE_RATE:.2f}s")
                # A short ambiguous utterance may be misidentified. Re-listen to
                # adjacent audio once, without forcing or translating its text.
                metrics["languageContextRetries"] += 1
                window = source.window(window.start, window.end, 4.0)
                audio = source.read(window.read_start, window.read_end)
                entry["contextRetrySeconds"] = 4.0
        tokens = int(generated.generation_tokens)
        if tokens >= max_tokens:
            # Never save a token-limited prefix as a successful full transcript.
            metrics["tokenLimitRetries"] += 1
            retry_split(window, depth, "ASR reached its token limit")
            return
        text = generated.text.strip()
        if not text or "\ufffd" in text or "\x00" in text:
            raise ValueError("empty or invalid ASR text in non-silent audio; review required")
        align_language = alignment_language(generated, text, language)
        started = time.perf_counter()
        words = aligner.generate(audio=audio, text=text, language=align_language)
        metrics["alignmentSeconds"] += time.perf_counter() - started
        try:
            words = checked_words(words, text, len(audio) / SAMPLE_RATE)
        except ValueError as error:
            metrics["alignmentRetries"] += 1
            retry_split(window, depth, str(error))
            return
        retained = 0
        for word in words:
            start = word.start_time + window.read_start / SAMPLE_RATE
            end = word.end_time + window.read_start / SAMPLE_RATE
            midpoint = (start + end) / 2 * SAMPLE_RATE
            if window.start <= midpoint < window.end:
                # Clip context spill at the ownership boundary, preserving order.
                all_words.append(SimpleNamespace(
                    start_time=max(start, window.start / SAMPLE_RATE),
                    end_time=min(end, window.end / SAMPLE_RATE), text=word.text))
                retained += 1
        entry.update(status="transcribed", language=align_language,
                     generationTokens=tokens, words=retained)
        metrics["windows"].append(entry)
        if progress:
            progress({"processedSeconds": round(window.end / SAMPLE_RATE, 2),
                      "audioSeconds": round(source.duration, 2)})
        if clear_cache:
            clear_cache()

    for window in source.windows(chunk_seconds, context_seconds, boundaries):
        process(window)
    metrics["words"] = len(all_words)
    metrics["asrSeconds"] = round(metrics["asrSeconds"], 3)
    metrics["alignmentSeconds"] = round(metrics["alignmentSeconds"], 3)
    return all_words, metrics


def review_ranges(metrics):
    """Expose unresolved non-silent intervals; absence of words is not proof of silence."""
    return [{"from": round(w["startSeconds"] * 1000), "to": round(w["endSeconds"] * 1000),
             "reason": "no_aligned_words_in_non_silent_core"}
            for w in metrics["windows"] if w["status"] != "digital_silence" and w.get("words", 0) == 0]
