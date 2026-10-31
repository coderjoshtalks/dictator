# Dictator — launch plan

Status as of v0.3.0. Phase 1 (app quality) is done; Phases 2–3 need accounts only the owner can create.

## Product

On-device dictation for macOS (Apple Silicon, macOS 14+) in English and Hinglish. Hold a key, speak, and clean text
is typed into any app. Audio and text never leave the Mac.

| Area | Status |
|---|---|
| Speech: Hinglish model + English model, routed by Hindi-word detection | ✅ |
| Streaming: phrases transcribed while speaking; wait after release ≈ 1 s at any length | ✅ |
| Audio chain: 80 Hz high-pass, speech-level AGC, noise-floor-relative VAD, high-quality resampling | ✅ |
| AI cleanup (local Qwen3), skipped when a phrase is already clean | ✅ |
| Learns from the user's corrections (heard → corrected) | ✅ |
| Transforms (Polish, Prompt Engineer, up to 8 custom; ⌃⌥1–8) | ✅ |
| Insights, history, dock bar, recording pill, original sounds | ✅ |
| Benchmarks: `--bench`, `--engine`, `--pipeline`, `--stream`, `--learn-test` | ✅ |

## Phase 2 — distribution (needs an Apple Developer account, $99/yr)

1. **Developer ID signing + notarization.** Build with `SIGN_IDENTITY="Developer ID Application: …"`; add hardened-runtime
   entitlements (`com.apple.security.device.audio-input`); notarize with `xcrun notarytool` and staple. Without this,
   every customer sees an "unverified developer" warning.
2. **Single installer.** A signed `.pkg` containing the app and all models (~2.35 GB). Models install to
   `/Library/Application Support/Dictator/Models` (shared, read-only) so app updates never re-download them.
   Host on Cloudflare R2/S3 behind the website (GitHub's 2 GB per-file release limit doesn't apply).
3. **Updates.** Sparkle 2 with an EdDSA-signed appcast; app-only updates (~35 MB).
4. **First launch.** macOS compiles each model for the Neural Engine once (~3 min per model); this cannot be
   pre-built. Show it as a polished "Getting Dictator ready" step.
5. **Crash reporting** (opt-in, no content): e.g. Sentry with PII scrubbing.

## Phase 3 — business

### Licensing and subscription
- Payment + subscriptions via a merchant of record (Lemon Squeezy or Paddle): cards, UPI, international tax, invoices.
- Server issues an **Ed25519-signed licence token** (customer id, plan, device id, expiry = 30 days). The app verifies
  the signature offline with an embedded public key and refreshes it when online; 7-day grace period when offline.
- Device limit per subscription (e.g. 2 Macs); deactivate from the website.
- Honest limit: any client-side check can be patched out. Defences that hold: server-gated model upgrades and new
  features, frequent updates, and a price that makes paying easier than cracking.

### Backend and admin dashboard
- Supabase (Postgres + auth + edge functions): `users`, `devices`, `licences`, `subscriptions`, `daily_usage`.
- The app sends **daily aggregates only**: words, dictations, active minutes, app version, OS, model. Never audio,
  text, or app names unless the user opts in.
- Payment-provider webhooks update `subscriptions`.
- Admin dashboard (Next.js on Vercel, or Retool/Metabase to start): total words, active users (DAU/WAU/MAU),
  each user's plan and payment status, churn, usage over time.

### Website
Landing page, pricing, download, account (licence keys, devices, billing portal), privacy policy, terms, refund policy,
support contact, changelog.

## Legal checklist (have a lawyer review before charging money)
- [ ] **Employment/IP**: confirm in writing that the owner (not their employer) owns Dictator.
- [ ] **Trademark**: search "Dictator" (India IP office, USPTO, EUIPO) and existing app names; consider registering.
- [ ] **Open-source notices** ship in the app (`THIRD_PARTY_NOTICES.md`, `licenses/`): WhisperKit (MIT), llama.cpp (MIT),
      OpenAI Whisper (MIT), Oriserve Hindi2Hinglish-Apex (Apache-2.0), CoreML conversion (Apache-2.0), Qwen3 (Apache-2.0),
      NVIDIA Parakeet if adopted (CC-BY-4.0, needs attribution).
- [ ] **Privacy**: DPDP Act 2023 (India) and GDPR (EU customers): privacy policy, consent for analytics, data export/deletion.
- [ ] **Tax**: GST registration once over the threshold; the merchant of record handles foreign VAT/sales tax.
- [ ] **Marketing**: no competitor names/logos implying affiliation; comparative claims must be true and provable.
- [ ] Terms of use, EULA, refund policy.

## Quality gates before public launch
- [ ] Test on an 8 GB M1 (memory: two speech models + LLM ≈ 3 GB) and on macOS 14, 15, 26.
- [ ] Real-voice benchmark: 10+ speakers, English/Hinglish/mixed, built-in mic and AirPods, quiet and noisy rooms.
- [ ] Dictation into: Chrome/Safari text areas, Slack, WhatsApp, Notion, Gmail, VS Code/Cursor, Terminal, Claude/ChatGPT.
- [ ] Accessibility revoked / mic revoked / no models / offline / disk full / sleep-wake mid-dictation.
- [ ] Fresh-Mac install from the installer, upgrade from the previous version, uninstall.

## Known next steps
- Benchmark NVIDIA Parakeet (FluidAudio) as the English model: expected faster and more accurate on short English.
- Optional Apple voice-processing input (system noise suppression) as a setting; needs real-mic testing.
- Snippets and per-app styles (were deprioritised by the owner).
