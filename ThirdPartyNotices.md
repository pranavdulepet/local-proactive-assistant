# Dependencies and model licenses

Local Assistant's original source is [Apache 2.0](LICENSE). This source release does not
include third-party binaries, downloaded packages or model weights. Downloads and compiled
applications retain their own dependency terms; the project license does not relicense them.

| Component | How used | Upstream license |
| --- | --- | --- |
| [imsg](https://github.com/openclaw/imsg) | Installed through Homebrew; copied into locally built Mac app | [MIT](ThirdPartyLicenses/imsg.txt) |
| [Ollama](https://github.com/ollama/ollama) | Separate local runtime, installed during selected setup | [MIT and upstream notices](https://github.com/ollama/ollama/blob/main/LICENSE) |
| [MLX Swift LM 2.29.2](https://github.com/ml-explore/mlx-swift-lm/tree/2.29.2) | Phone Xcode package | [MIT](https://github.com/ml-explore/mlx-swift-lm/blob/2.29.2/LICENSE) |
| [MLX Swift 0.29.1](https://github.com/ml-explore/mlx-swift/tree/0.29.1) | Phone Xcode package | [MIT](https://github.com/ml-explore/mlx-swift/blob/0.29.1/LICENSE) |
| [Swift Transformers](https://github.com/huggingface/swift-transformers) | Phone tokenizer/Hub package, compatible 1.1.x | [Apache 2.0](https://github.com/huggingface/swift-transformers/blob/1.1.0/LICENSE) |
| SQLite | Linked from the operating system | [Public domain](https://www.sqlite.org/copyright.html) |
| Apple frameworks | System-provided APIs and on-device model | Apple's platform and SDK terms |

The Mac installer includes this file, the project license and imsg's MIT notice in
`Contents/Resources`. Phone builds also resolve transitive packages through Xcode; preserve
their licenses when distributing a compiled phone app. This table describes direct runtime
dependencies, not a complete binary software bill of materials.

Model weights are separate downloads. Read the exact model card and license for your selected
tag or revision before redistributing weights or using them. Phone presets and pinned
revisions are documented in [phone-models.md](docs/phone-models.md). No weights are included
in this release, and no single model license covers arbitrary user-selected models.
