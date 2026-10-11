# Models on your iPhone

The optional iPhone app answers inside the app with a local model. It has a separate
conversation from Messages, where the running Mac provides replies.

## Install the app

Open `Apps/AssistantPhone/AssistantPhone.xcodeproj` in Xcode 26 or later. Select the
AssistantPhone target, choose your team under Signing & Capabilities, select your physical
iPhone, and run. Keep signing profiles and account settings out of commits.

## Choose a model

Open **Phone conversation** and choose a **Phone model**. Apple Intelligence is the default
on a supported iPhone with Apple Intelligence ready; this app downloads no extra Apple weights.

| Choice | Setup |
| --- | --- |
| Apple on-device | Enable Apple Intelligence on a supported iPhone |
| Qwen3 0.6B, 4-bit | Allow about 1 GB free during installation |
| Qwen3 1.7B, 4-bit | Allow about 2 GB free; 8 GB RAM recommended |
| My imported MLX model | Select a compatible small model folder from Files |

For a Qwen preset, tap **Download model to this iPhone**, wait for it to finish, then use
**Ask on this iPhone**. Choosing a model alone does not start a download. The first reply
loads it into memory; later replies reuse it while the conversation remains active.
Open models require a physical iPhone.

Installed models run from local files. **Remove selected model** removes the installed copy;
iOS may retain the download cache. Removing the app removes its models and application data.
**New phone conversation** clears the conversation and unloads its model. Chat history lasts
only while the app process remains alive.

## Import a model

Transfer a compatible MLX model folder to Files, then tap **Import my MLX model folder**.
The app copies the model into its own storage.

The folder needs `config.json`, `tokenizer.json`, `tokenizer_config.json`, and `.safetensors`
weights. Use a small quantized text model, usually 0.6–3B. Supported families include
Qwen2/Qwen3, Llama, Gemma text, Phi3, and SmolLM3; the installed runtime must support the
specific model. Import or loading errors appear in the app.

Weights can total at most 1.6 GB; the copied folder can total at most 1.7 GB. GGUF files
and Ollama manifests cannot be imported here. Shorten a conversation if the app reports
that it exceeds the input budget.

## Connect phone sources

Grant Calendar or Contacts in the app. Use an exact contact name for lookups. Sleep,
activity, and coarse location have separate sharing controls. Missing Health readings
remain unknown. Calendar reads cover the upcoming seven days.

[Pair with the Mac](local-models.md#pair-the-iphone-app) to upload sleep, activity, and coarse
location summaries. Calendar and Contacts stay in the phone conversation. Raw Health
samples stay on the phone. Location is a foreground snapshot rounded to about 1 km.

## Model licenses

The presets download [Qwen3 0.6B](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit) and
[Qwen3 1.7B](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit), both with Apache 2.0
model licenses. Downloads pin revisions `73e3e38d981303bc594367cd910ea6eb48349da8` and
`3b1b1768f8f8cf8351c712464f906e86c2b8269e`. Check the license of any model you import.
Runtime licenses are listed in [Third-party notices](../ThirdPartyNotices.md).

[Setup](install.md) · [Everyday use](use.md)
