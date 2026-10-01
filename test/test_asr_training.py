import sys
from pathlib import Path
import unittest
import importlib.util

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "script"))
from asr_training_data import assert_disjoint, mask_assistant_labels


class TrainingTests(unittest.TestCase):
    def test_same_recording_is_rejected_even_with_different_clip_ids(self):
        a = {"id": "clip-a", "source_group": "same-lecture", "audio_sha256": "a"}
        b = {"id": "clip-b", "source_group": "same-lecture", "audio_sha256": "b"}
        with self.assertRaisesRegex(ValueError, "source_group"):
            assert_disjoint([a], [b])

    def test_duplicate_audio_is_rejected_even_with_different_groups(self):
        with self.assertRaisesRegex(ValueError, "audio_sha256"):
            assert_disjoint([{"id": "a", "source_group": "x", "audio_sha256": "same"}],
                            [{"id": "b", "source_group": "y", "audio_sha256": "same"}])

    @unittest.skipUnless(importlib.util.find_spec("torch"), "run label-mask test in the training environment")
    def test_only_assistant_target_is_supervised(self):
        import torch
        ids = torch.tensor([[1, 2, 3, 90, 91, 4, 5]])
        labels = mask_assistant_labels(ids, ids, [90, 91])
        self.assertEqual(labels.tolist(), [[-100, -100, -100, -100, -100, 4, 5]])
        with self.assertRaises(ValueError):
            mask_assistant_labels(ids, ids, [99])


if __name__ == "__main__":
    unittest.main()
