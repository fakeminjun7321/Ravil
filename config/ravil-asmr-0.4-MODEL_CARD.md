# Ravil-ASMR-0.4-experimental

Status: Korean/English local inference pipeline candidate. **Not a public release or the installed app default.** No new Qwen weights were trained in this iteration. Ravil adds long-form windowing, per-window language detection and token budgets, validated word timestamps, bounded retries, and source attribution.

## Sources and licenses

| Component | Source | Pinned revision | License |
|---|---|---|---|
| ASR, 1.7B 6-bit | [MLX Community conversion](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-6bit) of [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) | `edd077a475c4da058e25b6e6ec1199115ca1be2b` | Apache-2.0 |
| Aligner, 0.6B 4-bit | [MLX Community conversion](https://huggingface.co/mlx-community/Qwen3-ForcedAligner-0.6B-4bit) | `2f652af86ae0c73fe189b9429225c908ce4bf020` | Apache-2.0 |
| MLX inference | [mlx-audio](https://github.com/Blaizzy/mlx-audio) | `94c7716212b2228f178d2f9c7619a591fd1b0b78` | MIT |
| Optional VAD | [Silero v6.2.0 GGML](https://huggingface.co/ggml-org/whisper-vad) | `9ffd54a1e1ee413ddf265af9913beaf518d1639b` | MIT |
| Optional VAD runner | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | `6e4ab854f67f743900934a703d5603419384c961` | MIT |
| Public evaluation data | [Google FLEURS](https://huggingface.co/datasets/google/fleurs), Korean and US English | `70bb2e84b976b7e960aa89f1c648e09c59f894dd` | CC BY 4.0 |

Weight SHA-256 values: ASR `cacb094fef227ec2a5908d0136b3ad3384d95e0e2a8a915984ce577e4b12b2ba`; aligner `630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c`; optional VAD `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987`. The CLI verifies these before loading. Each output records model revisions, hashes, runtime commit, input audio hash, language mode, and chunk settings; optional VAD also records the executable hash.

FLEURS attribution: Conneau et al., *FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech*, [paper](https://arxiv.org/abs/2205.12446). Ravil converts selected float WAV recordings to PCM16 and constructs concatenated diagnostic cases; it does not claim those concatenations are original natural lectures. English archive SHA-256: `d9c2e37b41aacd41bc283554a0a82b5476b36887049774ecb2819dcaaa55a356`; English test TSV: `74c046239374deeb60fa63f258f907388093a32bcaa3140965f70ef05c79f7ca`. Dataset license and source must accompany any later redistributed derived material. Model and runtime notices must accompany their distribution.

## Operation

- Input: mono, 16 kHz, 16-bit PCM WAV. The previous five-minute CLI restriction is removed; normal model input windows stay at most 32 seconds with default context. A language-identification retry may use up to 38 seconds.
- `--language ko`, `en`, or `auto`; auto detects each window independently. Korean speech and English words remain in their spoken language. An unexpected detected language gets one re-decode with four seconds of adjacent context on each side, then an explicit review error if unresolved. It does not force the unexpected language into Korean or English.
- Default maximum core: 30 seconds, plus up to one second of context per side. Core intervals cover all source samples once. Word midpoint selects its owning core; matching text is not deduplicated, preserving intentional repetition.
- 512 output tokens per window. Saturated generation and invalid alignment trigger bounded subdivision, up to three levels. Unresolved failures stop the run without publishing a partial transcript.
- Optional Silero speech gaps guide boundaries. They **do not remove audio**. Short inputs up to 30 seconds bypass these hints. This differs from cropping low-confidence speech out of the input.
- Only exact digital silence is skipped. Non-silent audio with empty ASR text requires review. Transcript and metrics are local, private files and never overwrite an existing output.
- A non-silent core with no aligned words is listed in `reviewRequiredRanges`. Its artifact has `status: needs_review` and the CLI exits with code 3. A consumer must inspect this status; merely decoding the JSON is not full-transcript acceptance.

## Evaluation and limits

Detailed results and exact local artifacts are in [the 0.4 development record](../docs/ravil-asmr-0.4-development.md). Improvements compare against Ravil 0.3's 512-token whole-file decoding configuration, not a retrained or stronger base model. Concatenated diagnostics were used during development and are not an unbiased estimate of classroom accuracy.

Remaining gaps: human-checked natural classroom references, continuous within-sentence code switching, speaker labels, robust handling of all noisy/silent input, energy consumption, native Swift packaging, and the installed app's recording-to-save flow. The Python environment and optional VAD CLI remain development dependencies. Current evidence does not establish superiority over Alt on the same natural recordings.

The user authorizes all Alt recordings and available worksheets for model training and evaluation. This iteration uses selected recordings only for local inference checks; no private audio or transcript is distributed, and no private recording is used to update these weights. The provisional public name and complete distribution rights review remain release work.
