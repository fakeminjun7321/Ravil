import sys
from pathlib import Path
from types import SimpleNamespace as Object
import unittest
import tempfile
import subprocess
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "script"))
from asr_candidates import candidate_spec, require_language
from ravil_asr_native import native_words


class NativeTests(unittest.TestCase):
    def test_long_english_requires_split_hints_before_model_loading(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "input.wav"
            with wave.open(str(audio), "wb") as target:
                target.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                target.writeframes(bytes(31 * 16000 * 2))
            script = Path(__file__).resolve().parents[1] / "script/transcribe_mlx_parakeet.py"
            result = subprocess.run([sys.executable, str(script), "--audio", str(audio),
                "--models", str(root), "--language", "en", "--output", str(root / "out.json"),
                "--metrics", str(root / "metrics.json")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("require --vad-engine", result.stderr)
            self.assertFalse((root / "out.json").exists())

    def test_english_engine_refuses_korean_and_auto(self):
        for name in ("parakeet-v3-bf16", "parakeet-v3-bf16-compact", "parakeet-redux"):
            for language in ("ko", "auto"):
                with self.assertRaises(ValueError):
                    require_language(candidate_spec(name), language)

    def test_subwords_and_spoken_repetition_are_preserved(self):
        tokens = [Object(text=t, start=i*.1, end=(i+1)*.1) for i,t in enumerate([" I", " don", "'t", " know", " know", "."])]
        result = Object(text="I don't know know.", sentences=[Object(tokens=tokens)])
        self.assertEqual([w.text for w in native_words(result, 1)], ["I", "don't", "know", "know."])

    def test_timestamp_and_text_corruption_fail(self):
        for token, text in [(Object(text="test", start=-1, end=0), "test"),
                            (Object(text="test", start=0, end=float('nan')), "test"),
                            (Object(text="test", start=0, end=.2), "other")]:
            with self.assertRaises(ValueError):
                native_words(Object(text=text, sentences=[Object(tokens=[token])]), 1)


if __name__ == "__main__":
    unittest.main()
