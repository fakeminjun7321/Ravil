# Ravil-ASMR-0.5-experimental

Local efficiency profiles for Korean and English. **Development artifact, not an installed-app release.** This iteration adds model selection, a persistent BF16 conversion, and native-timestamp inference; it does not train new ASR weights. The Qwen 1.7B quality path remains available.

## Profiles and provenance

| Profile | Model and source | License | Intended scope |
|---|---|---|---|
| Quality | [Qwen3-ASR 1.7B 6-bit, MLX Community](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-6bit), from [Qwen](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) | Apache-2.0 | Korean/English, including experimental mixed-language handling |
| Fast bilingual | [Qwen3-ASR 0.6B 8-bit, MLX Community](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit), from [Qwen](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) | Apache-2.0 | Korean/English; reduced accuracy measured versus the quality path |
| Fast English | [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [MLX conversion](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3), Ravil BF16 storage conversion | CC BY 4.0 | Explicitly English-only speech; not Korean or mixed classes |
| Minimum-memory English experiment | [Moondream Parakeet Redux](https://huggingface.co/moondream/parakeet-redux), based on NVIDIA Parakeet | CC BY 4.0 | English-only; slower and less accurate than BF16 Parakeet in this MLX test |

Runtime: [mlx-audio](https://github.com/Blaizzy/mlx-audio), MIT, commit `94c7716212b2228f178d2f9c7619a591fd1b0b78`. Qwen profiles retain the separately attributed [ForcedAligner](https://huggingface.co/mlx-community/Qwen3-ForcedAligner-0.6B-4bit), Apache-2.0, from the 0.4 card. Parakeet profiles use their native timing outputs and do not load that aligner. The optional external Silero VAD and whisper.cpp retain the pinned sources and MIT notices in the [0.4 card](ravil-asmr-0.4-MODEL_CARD.md).

Exact repositories, revisions, weight hashes, runtime dtype and local conversion metadata are in [the candidate registry](asr-candidates-20261001.json). New hashes:

- Qwen 0.6B 8-bit revision `89e96d92ba34aca20b3e29fb10cc284097d1219f`, weight SHA-256 `b5bfe4abc1b4c6e58b633096682ec2b6297298add1527119936107d211adf0e8`.
- Parakeet MLX source revision `ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15`, SHA-256 `05e01c7f396c298cf7d23f61da7b504adeab698f0aaeafd9c82d198625464592`.
- Ravil persistent BF16 conversion SHA-256 `bbd966b18b7b05b0f6147b2ecf4711a32f7e66e7d2e34b7bb7b066b988f2333b`, 1,254,184,497 bytes. The change is FP32-to-BF16 storage using the same inference dtype already measured. Source weights remain intact. Twenty selected utterances produced identical text after reload; this is not exhaustive equivalence proof.
- Redux revision `2bf128600aac4b16946f7ed8372e56117fe5e23b`, SHA-256 `78ec25733ee0d0c1586d1346fc86db9d0c2e436e3a8ab1d32a82d1bb8f848d21`. The MLX runtime repacks ternary codes; it does not use Photon or its native VAD. Photon benchmark claims are not attributed to Ravil's MLX runtime.

NVIDIA, MLX Community and Moondream attribution must accompany applicable distributions. Preserve the [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) license link and identify Ravil's conversion and inference changes. Apache and MIT license notices remain necessary for their components. These local experiments do not publicly redistribute model weights or user recordings.

## Evidence and limitations

[Development results](../docs/ravil-asmr-0.5-development.md) report matched FLEURS Korean/English samples, ASR-only timings, MLX active memory, longer constructed audio and local private-recording checks. FLEURS remains attributed to Google and Conneau et al., CC BY 4.0, fixed revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`; see the 0.4 card for dataset preparation changes and checksums.

This is a quality/efficiency tradeoff. The small Korean model and fast English model did not beat the quality model's short-clip error rates. Native word timing is structurally checked, not human-time-aligned ground truth. Native long English output improved with speech-gap hints, but the candidate is not validated for mixed speech or all recording conditions. An English course name is not authorization to treat its audio as English-only.

The native English CLI requires the pinned external VAD engine/model for inputs longer than 30 seconds after unsegmented long-file regressions were observed. It uses boundaries only, preserving all samples. Short inputs do not require VAD.

CLI outputs declare model sources and `reviewRequiredRanges`. Exit code 3 means review-required artifacts exist; consumers must not interpret mere JSON decoding as successful full transcription. GUI recording, DB persistence, native app packaging, thermal/energy results, independent natural-classroom accuracy, speaker identification, and release readiness remain unverified. No claim of superiority over Alt on identical natural recordings is made.
