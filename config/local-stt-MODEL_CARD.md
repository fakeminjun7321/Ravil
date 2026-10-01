# Ravil local STT baseline

Status: upstream baseline. Ravil has not trained or fine-tuned these weights. Do not describe this file as a Ravil-created model or as an improvement over Alt.

## Attribution and provenance

- Base model: OpenAI Whisper large-v3-turbo, by OpenAI. Source: https://github.com/openai/whisper
- Base model code and weights: MIT License, copyright 2022 OpenAI. The license text is included as `Models/LICENSE`.
- GGML conversion and q5_0 quantization: published by the whisper.cpp maintainer at https://huggingface.co/ggerganov/whisper.cpp (MIT). The conversion workflow is documented at https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md.
- Exact downloaded artifact: `ggml-large-v3-turbo-q5_0.bin` from repository revision `5359861c739e955e79d9a303bcbc70fb988958b1`.
- SHA-256: `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`.
- Ravil modifications to model weights: none. Ravil packages this unmodified quantized artifact and provides app integration around it.

## Limits

This baseline does not include speaker diarization, Ravil-trained subject vocabulary, or a model for summary and quiz generation. Its accuracy on actual Korean classes, resource use on other Macs, and advantage over Alt have not been established. The matching SHA-256 shows that the previously Alt-sourced file had identical bytes; changing the download source alone cannot improve recognition quality.

Before publishing a Ravil-derived model, create a new model card that lists every base weight, transform, training dataset and its permitted uses, evaluation corpus, model version, and artifact hash. Keep source audio and school/Goodnotes material out of training unless rights and consent are documented. Publish only the model whose exact hash and notices have been reviewed.
