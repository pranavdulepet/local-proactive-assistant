# Models on your iPhone

The phone companion can answer inside the app with an on-device model. Apple Intelligence is the default and needs no extra weights. You can instead choose a small open model, or import your own compatible MLX model folder. Choosing a model never starts a download.

The Mac and phone selections are separate. Changing the phone model does not change the Mac model that answers in Messages. iOS does not let this companion read iMessage or independently answer in your self-chat; the running Mac still provides that conversation.

## Choose an open model

1. Build and install `Apps/AssistantPhone/AssistantPhone.xcodeproj` on your physical iPhone using Xcode. Set your signing team as described in the main README.
2. Open Local Assistant and choose a **Phone model**.
3. Tap **Download model to this iPhone**. This explicitly downloads public weights/config/tokenizer files from Hugging Face. Your questions and phone context are not sent to a model service.
4. Wait for the files to be saved, then use **Ask on this iPhone**. The first reply loads the model into memory; later replies reuse it while this conversation remains active.

| Choice | Runtime | Extra weights | Use |
| --- | --- | --- | --- |
| Apple on-device | Foundation Models | None downloaded by this app | Default on a supported iPhone with Apple Intelligence ready |
| Qwen3 0.6B, 4-bit | MLX | One explicit download; allow about 1 GB of free storage during installation | Smallest preset; lighter conversation |
| Qwen3 1.7B, 4-bit | MLX | One explicit download; allow about 2 GB of free storage during installation | Larger preset; 8 GB RAM recommended |
| My imported MLX model | MLX | Copied from the folder you select | Bring a compatible small quantized text model |

These are small-footprint choices, not a claim that one model is best for every iPhone. Runtime quality, speed, memory pressure and battery use need testing on your particular device. Open-model inference is disabled in the simulator; simulator CI tests the setup controls and compiles the app, not a physical phone's model speed.

Once installed, inference loads the model's local directory. It makes no Hub/model-server request. Installed files live in this app's Application Support directory and are excluded from backup. Removing the app removes its installed models. A download cache may also retain the original downloaded files until iOS clears that cache; **Remove selected model** removes the installed copy.

## Bring your own model

Transfer a compatible MLX model folder to the iPhone's Files app, then tap **Import my MLX model folder** and select that folder. The app copies the files into its own storage, so later answers do not depend on the selected folder remaining available or its Files provider staying online.

The folder must contain `config.json`, `tokenizer.json`, `tokenizer_config.json` and one or more `.safetensors` weight files. The app copies bounded JSON and safetensors files only. Qwen2/Qwen3, Llama, Gemma text, Phi3 and SmolLM3 configurations are admitted; the pinned MLX runtime must support the particular architecture/configuration. A matching family name alone does not guarantee the model will load. Import errors and first-load errors remain visible in the app.

Weights are limited to 1.6 GB and the complete copied bundle to 1.7 GB. Use a small quantized text model, typically in the 0.6–3B range. This provider does not load GGUF or Ollama manifests. The Mac can use Ollama/GGUF separately.

The phone provider bounds prepared input to 4,096 tokens and output to 384 tokens, with a 16 MB MLX buffer cache. It reports an over-budget conversation instead of silently truncating the owner's current message. **New phone conversation** clears the in-memory history and unloads that conversation's model. History currently lasts only while the app process remains alive.

## Phone context

Grant Calendar or Contacts explicitly in the app. Contacts lookups require the exact selected name. Sleep, activity and coarse location have separate opt-in controls. Enabled phone context is available to the local phone conversation. Pairing uploads derived sleep, activity and coarse location summaries to the Mac. Calendar and Contacts currently stay in the phone conversation; the Mac reads its own synced Calendar and Contacts. Raw Health samples are not uploaded. Coarse location is one recent foreground snapshot rounded to about 1 km, not continuous tracking.

Unavailable Health readings remain unknown. Denied reads and absent samples must not be interpreted as zero activity or zero sleep. Calendar coverage is bounded to the upcoming seven days and at most the supplied records. Model citations identify supplied records; they do not prove that every generated claim is correct.

## Runtime and weights

The iPhone Xcode project pins [MLX Swift LM 2.29.2](https://github.com/ml-explore/mlx-swift-lm/tree/2.29.2), with its [MIT license](https://github.com/ml-explore/mlx-swift-lm/blob/2.29.2/LICENSE). Its MLX Swift dependency is also [MIT licensed](https://github.com/ml-explore/mlx-swift/blob/0.29.1/LICENSE). The tokenizer dependency, Swift Transformers, uses [Apache 2.0](https://github.com/huggingface/swift-transformers/blob/1.1.0/LICENSE). The project contains original adapter code using those public APIs; it does not copy third-party agent implementations.

Preset weights are the MLX conversions of [Qwen3 0.6B](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit) and [Qwen3 1.7B](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit), with Apache 2.0 model licenses. Downloads pin repository revisions `73e3e38d981303bc594367cd910ea6eb48349da8` and `3b1b1768f8f8cf8351c712464f906e86c2b8269e`. Runtime and weights have separate licenses.

[llama.cpp's MIT runtime](https://github.com/ggml-org/llama.cpp/blob/master/LICENSE) also has an [iOS XCFramework](https://github.com/ggml-org/llama.cpp/blob/master/docs/xcframework.md). This app currently embeds MLX's Swift model/tokenizer API; a llama.cpp phone provider is not implemented.
