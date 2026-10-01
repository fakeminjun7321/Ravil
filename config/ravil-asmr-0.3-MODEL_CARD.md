# Ravil-ASMR-0.3-experimental

Status: balanced local pipeline candidate. **Not a released Ravil model and not the app default.** Ravil has not trained these Qwen weights. It combines attributed 6-bit ASR, attributed 4-bit forced alignment, and Ravil's timestamp validation and transcript grouping.

## Base models and licenses

| Component | Source | License | Pinned revision | SHA-256 |
|---|---|---|---|---|
| ASR | [MLX Community Qwen3-ASR 1.7B 6-bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-6bit), converted from [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) | Apache-2.0 | `edd077a475c4da058e25b6e6ec1199115ca1be2b` | `cacb094fef227ec2a5908d0136b3ad3384d95e0e2a8a915984ce577e4b12b2ba` |
| Forced alignment | [MLX Community Qwen3-ForcedAligner 0.6B 4-bit](https://huggingface.co/mlx-community/Qwen3-ForcedAligner-0.6B-4bit) | Apache-2.0 | `2f652af86ae0c73fe189b9429225c908ce4bf020` | `630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c` |

Runtime: [mlx-audio](https://github.com/Blaizzy/mlx-audio), MIT, pinned commit `94c7716212b2228f178d2f9c7619a591fd1b0b78`. The model weights and runtime notices must be included and reviewed before any distributable release. This experiment does not redistribute the weights or private lecture audio.

## Evaluation

FLEURS Korean test, 100 unseen read-speech sentences and 4,667 normalized characters: 154 character errors, CER **3.30%**. The corresponding 4-bit ASR had 173 errors / 3.71%; full PyTorch Qwen3-ASR 1.7B had 148 / 3.17%; current Ravil Whisper Turbo had 191 / 4.09%. The 6-bit weights are 2.03 GB, versus 1.60 GB for 4-bit and 4.08 GB for full precision. In the same 100-sentence local MLX evaluation, 6-bit inference time summed to 79.5 seconds versus 75.8 seconds for 4-bit. This is read speech, not a verified classroom result.

With the 4-bit aligner, combined weights are about 3.00 GB. On this Mac M5, a 120-second user-authorized lecture excerpt produced 196 aligned words and 16 Ravil-compatible phrases; model load took 1.13 seconds, ASR 9.72 seconds, alignment 1.51 seconds, with peak active MLX memory about 4.69 GB. The transcript JSON passed Ravil's decoder contract check. Human-verified text and timestamp accuracy, long lecture chunking, diarization, app UI and distributable runtime are not verified. `Ravil-ASMR` is a provisional name pending trademark clearance.
