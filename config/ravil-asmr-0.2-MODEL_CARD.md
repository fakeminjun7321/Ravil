# Ravil-ASMR-0.2-experimental

Status: local pipeline experiment. **Not a released Ravil model.** Ravil has not trained the Qwen weights in this version; its contribution is local quantized inference, forced alignment, timestamp validation, and conversion to Ravil's transcript JSON contract.

## Base models and attribution

| Component | Source and role | License | Pinned revision | SHA-256 of `model.safetensors` |
|---|---|---|---|---|
| ASR | [MLX Community Qwen3-ASR 1.7B 4-bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit), converted from [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) | Apache-2.0 | `78a389c776a5483b2d0d4ea5494e11012e0d6159` | `9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45` |
| Alignment | [MLX Community Qwen3-ForcedAligner 0.6B 4-bit](https://huggingface.co/mlx-community/Qwen3-ForcedAligner-0.6B-4bit), converted from Qwen ForcedAligner | Apache-2.0 | `2f652af86ae0c73fe189b9429225c908ce4bf020` | `630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c` |

Runtime: [mlx-audio](https://github.com/Blaizzy/mlx-audio), MIT, pinned commit `94c7716212b2228f178d2f9c7619a591fd1b0b78`. The source repos and model cards must accompany any later distributable package with the applicable license notices. This prototype distributes neither weights nor user recordings.

## Ravil changes and limits

`script/transcribe_mlx_qwen_aligned.py` runs both models locally, groups aligned words into timestamped phrases, rejects malformed/empty text and invalid timestamps, and emits JSON compatible with Ravil's `RecognizedPhrase` decoder. Inputs must be mono 16 kHz PCM WAV, at most five minutes. This prototype has no speaker labels, automatic long-lecture chunking, or installed-app UI path.

FLEURS Korean test 100 read-speech sentences (4,667 normalized characters): 173 character errors, CER **3.71%**. The same test gave 148 errors / 3.17% with full Qwen3-ASR 1.7B and 191 errors / 4.09% with Ravil's current Whisper Turbo. This is not a classroom accuracy result. Model weights total 2.57 GB; measured active MLX memory after loading both models was 2.59 GB. A 120-second real lecture excerpt reached 4.26 GB peak and took 10.87 seconds for ASR plus 2.00 seconds for alignment after model load. Human-verified transcript and timestamp accuracy are pending.

The provisional `Ravil-ASMR` name requires trademark clearance before public release. User-authorized local recordings and worksheets were used only for local evaluation of this pipeline, not to train these Qwen weights. Permission to publish a model derived from third-party lecture audio or worksheets has not been established.
