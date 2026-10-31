# Dictator

On-device dictation for macOS in **English and Hinglish**. Hold a key, speak, and clean text is typed into whatever
app you're using. Speech recognition and AI cleanup run entirely on your Mac — no account, no cloud, nothing you say
leaves the machine.

## Features
- **Two speech models, chosen automatically**: Whisper large-v3-turbo fine-tuned for Hinglish (writes Hindi in Roman
  script), and OpenAI's Whisper large-v3-turbo for pure English (about half the errors on English).
- **Streaming**: phrases are transcribed while you're still talking, so text appears about a second after you let go,
  however long you spoke.
- **AI cleanup** with a local LLM (Qwen3 via llama.cpp): removes fillers, applies self-corrections ("5 baje, no wait,
  6 baje"), punctuates. Every prompt and example is editable in Settings, with a playground.
- **Learns from your corrections**: fix a misheard word after it's typed and Dictator remembers it.
- **Transforms**: select text anywhere and press ⌃⌥1–8 to rewrite it with your own prompts (Polish, Prompt Engineer, …).
- **Insights**: words, words per minute, fixes, streaks, activity.
- Hold-to-talk or double-tap for hands-free · a floating bar you can drag anywhere · custom dictionary · history.

## Requirements
Apple Silicon Mac (M1 or newer), macOS 14 or later, ~2.5 GB free disk space.

## Install
Download the latest `Dictator-x.y.z.dmg` from **Releases**, drag Dictator to Applications, and open it.
The Setup screen downloads the models (about 2.3 GB, once) and asks for Microphone and Accessibility access.
See [`Resources/INSTALL.txt`](Resources/INSTALL.txt) for the one-time "Open Anyway" step on unsigned builds.

## Build from source
Requires the Xcode command-line tools (Swift 6).

```sh
./scripts/build-app.sh      # builds dist/Dictator.app and installs it to ~/Applications
./scripts/package-dmg.sh    # also produces dist/Dictator-<version>.dmg
```

Set `SIGN_IDENTITY="Developer ID Application: …"` to sign for notarized distribution.

Developer test modes (the binary inside the app bundle):
`--bench`, `--engine`, `--pipeline`, `--stream` (WER and latency benchmarks), `--refine`, `--transform`,
`--learn-test`, `--snapshot <folder>` (renders every screen to PNG).

## Project layout
| Path | What |
|---|---|
| `Sources/Dictator/SpeechEngine.swift`, `Transcriber.swift` | Dual-model speech recognition (WhisperKit / CoreML) |
| `Sources/Dictator/DictationPipeline.swift`, `Voice.swift` | Streaming segmentation, VAD, audio pre-processing |
| `Sources/Dictator/Refiner.swift`, `Models.swift` | Rule + LLM cleanup, prompts, transforms |
| `Sources/Dictator/Learner.swift` | Learning from user corrections |
| `Sources/Dictator/Overlay.swift`, `UI/` | Floating bar, recording pill, main window |
| `docs/` | Launch plan, privacy policy and terms drafts |

## Licences
Dictator's own code: all rights reserved. Third-party components and models keep their own licences (MIT /
Apache-2.0) — see [`Resources/THIRD_PARTY_NOTICES.md`](Resources/THIRD_PARTY_NOTICES.md).
