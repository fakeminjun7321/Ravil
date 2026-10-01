"""Boundary, truncation and language regressions, with deterministic fake models."""
import sys
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
import wave
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "script"))
from ravil_asr_longform import PCMSource, SAMPLE_RATE, checked_words, transcribe, vad_boundaries, review_ranges


class ASR:
    def __init__(self, saturate_over=None, language="English"):
        self.calls = []
        self.saturate_over = saturate_over
        self.language = language

    def generate(self, audio, **kwargs):
        self.calls.append(kwargs)
        saturated = self.saturate_over and len(audio) / SAMPLE_RATE > self.saturate_over
        return SimpleNamespace(text="go go", language=[self.language],
                               generation_tokens=kwargs["max_tokens"] if saturated else 3)


class Aligner:
    def generate(self, audio, text, language):
        duration = len(audio) / SAMPLE_RATE
        return [SimpleNamespace(text="go", start_time=duration * .3, end_time=duration * .4),
                SimpleNamespace(text="go", start_time=duration * .6, end_time=duration * .7)]


class LongFormTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def source(self, seconds, silent=False):
        path = Path(self.temp.name) / "input.wav"
        with wave.open(str(path), "wb") as target:
            target.setparams((1, 2, SAMPLE_RATE, 0, "NONE", "not compressed"))
            target.writeframes(np.full(round(seconds * SAMPLE_RATE), 0 if silent else 500,
                                       dtype="<i2").tobytes())
        return PCMSource(path)

    def test_windows_cover_long_file_without_gaps_or_overlapping_ownership(self):
        source = self.source(367.321)
        windows = list(source.windows())
        self.assertEqual(windows[0].start, 0)
        self.assertEqual(windows[-1].end, source.frames)
        self.assertTrue(all(a.end == b.start for a, b in zip(windows, windows[1:])))
        self.assertTrue(all(w.end > w.start and w.read_end - w.read_start <= 32 * SAMPLE_RATE
                            for w in windows))

    def test_language_detection_and_token_budget_restart_for_each_window(self):
        model = ASR()
        words, metrics = transcribe(self.source(91), model, Aligner())
        self.assertGreater(len(model.calls), 3)
        self.assertTrue(all(c["language"] is None and c["max_tokens"] == 512 for c in model.calls))
        self.assertEqual(metrics["windows"][-1]["endSeconds"], 91)
        self.assertGreater(words[-1].end_time, 89)

    def test_repeated_spoken_words_are_preserved(self):
        words, _ = transcribe(self.source(4), ASR(), Aligner())
        self.assertEqual([w.text for w in words], ["go", "go"])

    def test_vad_hints_split_utterances_including_last_window_without_dropping_audio(self):
        source = self.source(45)
        pattern = np.concatenate([np.full(8 * SAMPLE_RATE, 500, dtype="<i2"),
                                  np.zeros(SAMPLE_RATE, dtype="<i2")])
        with wave.open(str(source.path), "wb") as target:
            target.setparams((1, 2, SAMPLE_RATE, 0, "NONE", "not compressed"))
            target.writeframes(np.tile(pattern, 5).tobytes())
        windows = list(source.windows(boundaries=[round(x * SAMPLE_RATE) for x in (8.5, 17.5, 26.5, 35.5)]))
        self.assertGreaterEqual(len(windows), 5)
        self.assertTrue(all(w.end - w.start < 12 * SAMPLE_RATE for w in windows))
        self.assertEqual(windows[-1].end, source.frames)

    def test_token_limit_retries_cover_entire_interval(self):
        words, metrics = transcribe(self.source(20), ASR(saturate_over=12), Aligner())
        self.assertEqual(metrics["tokenLimitRetries"], 1)
        self.assertEqual([(w["startSeconds"], w["endSeconds"]) for w in metrics["windows"]],
                         [(0, 10), (10, 20)])
        self.assertGreater(words[-1].end_time, 16)

    def test_persistent_token_limit_is_an_error(self):
        with self.assertRaisesRegex(ValueError, "token limit"):
            transcribe(self.source(20), ASR(saturate_over=.01), Aligner())

    def test_exact_silence_never_calls_model(self):
        model = ASR()
        words, metrics = transcribe(self.source(65, silent=True), model, Aligner())
        self.assertFalse(model.calls)
        self.assertFalse(words)
        self.assertGreater(metrics["silentWindows"], 1)

    def test_unexpected_language_does_not_silently_get_translated(self):
        with self.assertRaisesRegex(ValueError, "outside Korean/English"):
            transcribe(self.source(3), ASR(language="Chinese"), Aligner())

    def test_short_ambiguous_language_gets_one_context_retry(self):
        class ContextSensitive(ASR):
            def generate(self, audio, **kwargs):
                self.language = "Portuguese" if not self.calls else "English"
                return super().generate(audio, **kwargs)
        model = ContextSensitive()
        words, metrics = transcribe(self.source(10), model, Aligner())
        self.assertEqual(metrics["languageContextRetries"], 1)
        self.assertEqual(len(model.calls), 2)
        self.assertEqual(len(words), 2)

    def test_invalid_alignment_is_rejected(self):
        word = SimpleNamespace(text="go", start_time=1, end_time=float("nan"))
        with self.assertRaises(ValueError):
            checked_words([word], "go", 3)

    def test_bad_alignment_retries_smaller_windows_without_saving_bad_times(self):
        class SometimesInvalid(Aligner):
            def generate(self, audio, text, language):
                if len(audio) > 12 * SAMPLE_RATE:
                    return [SimpleNamespace(text="go go", start_time=0, end_time=999)]
                return super().generate(audio, text, language)
        words, metrics = transcribe(self.source(20), ASR(), SometimesInvalid())
        self.assertEqual(metrics["alignmentRetries"], 1)
        self.assertTrue(all(0 <= w.start_time <= w.end_time <= 20 for w in words))
        self.assertEqual(metrics["windows"][-1]["endSeconds"], 20)

    def test_vad_centiseconds_are_converted_and_missing_segments_fail(self):
        source = self.source(10)
        output = "Detected 2 speech segments:\nSpeech segment 0: start = 100.00, end = 200.00\nSpeech segment 1: start = 400.00, end = 700.00\n"
        with patch("ravil_asr_longform.subprocess.run", return_value=SimpleNamespace(stdout=output)):
            self.assertEqual(vad_boundaries(Path("engine"), Path("model"), source), [3 * SAMPLE_RATE])
        with patch("ravil_asr_longform.subprocess.run", return_value=SimpleNamespace(stdout=output.replace("Detected 2", "Detected 3"))):
            with self.assertRaises(ValueError):
                vad_boundaries(Path("engine"), Path("model"), source)

    def test_context_words_have_one_owner(self):
        class BoundaryAligner:
            def generate(self, audio, text, language):
                duration = len(audio) / SAMPLE_RATE
                return [SimpleNamespace(text="go", start_time=.1, end_time=.2),
                        SimpleNamespace(text="go", start_time=duration - .2,
                                        end_time=duration - .1)]
        words, _ = transcribe(self.source(40), ASR(), BoundaryAligner())
        self.assertEqual(len(words), 2)
        self.assertLess(words[0].end_time, 1)
        self.assertGreater(words[-1].start_time, 39)

    def test_non_silent_empty_core_is_flagged_for_review(self):
        metrics = {"windows": [
            {"startSeconds": 0, "endSeconds": 2, "status": "digital_silence"},
            {"startSeconds": 2, "endSeconds": 4, "status": "transcribed", "words": 0},
            {"startSeconds": 4, "endSeconds": 6, "status": "transcribed", "words": 2}]}
        self.assertEqual(review_ranges(metrics), [{"from": 2000, "to": 4000,
                         "reason": "no_aligned_words_in_non_silent_core"}])

    def test_truncated_audio_fails_before_inference(self):
        source = self.source(3)
        source.path.write_bytes(source.path.read_bytes()[:-500])
        with self.assertRaisesRegex(ValueError, "truncated WAV"):
            transcribe(source, ASR(), Aligner())


if __name__ == "__main__":
    unittest.main()
