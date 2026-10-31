# Dictator — open-source components

Dictator is built on these open-source projects and models. Full license texts are in the `licenses` folder inside Dictator.app (Contents/Resources/licenses).

| Component | Use in Dictator | License |
|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax | Runs the speech model on Apple's Neural Engine | MIT |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) (build b11669) | Runs the AI cleanup model on the GPU (bundled `llama-server`) | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | WhisperKit dependency | Apache-2.0 |

## Models (downloaded on first run, not bundled)

| Model | Source | License |
|---|---|---|
| Whisper Hindi2Hinglish Apex (fine-tune of OpenAI Whisper large-v3-turbo) | [Oriserve/Whisper-Hindi2Hinglish-Apex](https://huggingface.co/Oriserve/Whisper-Hindi2Hinglish-Apex) | Apache-2.0 |
| CoreML 6-bit conversion of the above | [raghuramr14/whisperkit-hinglish-w6](https://huggingface.co/raghuramr14/whisperkit-hinglish-w6) | Apache-2.0 |
| OpenAI Whisper large-v3-turbo (base model) | [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) | MIT |
| Qwen3 1.7B / Qwen3 4B Instruct 2507 (GGUF quantizations by Unsloth) | [Qwen](https://huggingface.co/Qwen) · [unsloth](https://huggingface.co/unsloth) | Apache-2.0 |

Dictator is an independent project and is not affiliated with or endorsed by any of the above, or by any other dictation product.
