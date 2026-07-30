<p align="center">
  <img src="Resources/AppIcon.png" width="148" alt="nodaystypst icon">
</p>

<h1 align="center">nodaystypst</h1>

<p align="center">
  Cloud-powered predictive typing for macOS—quiet at the caret, light on your Mac.
</p>

<p align="center">
  <strong>Native Swift 6</strong> · <strong>Gemma 4 via OpenRouter</strong> · <strong>No local model</strong>
</p>

## What it does

nodaystypst watches the text field you are actively writing in, sends a short bounded context window to OpenRouter, and displays a subtle 2–4-word completion beside the caret. Press **Tab** once to accept the entire shown completion. Keep typing to dismiss it. A question mark at the end of the current text suppresses prediction so the model never tries to answer the question as if it were a conversation.

The current supported surfaces are:

- **Orion Browser** (`com.kagi.kagimacOS`)
- **Antinote** (`com.chabomakers.Antinote`)
- **Bear** (`net.shinyfrog.bear`)
- **ChatGPT** (`com.openai.codex`)
- **Ghostty** (`com.mitchellh.ghostty`) — shows predictions but keeps Tab for shell completion
- **TextEdit** (`com.apple.TextEdit`)
- **Notes** (`com.apple.Notes`)
- **Safari** (`com.apple.Safari`) — web-content fields only
- **Obsidian** (`md.obsidian`)

Google Chrome (`com.google.Chrome`) is explicitly safe-rejected on the current build: live AX exposes editable content but no trustworthy caret rectangle. Chrome therefore stays content-blind rather than showing a potentially misplaced ghost. Unknown apps, non-editable controls, browser address/search bars, and code-editor surfaces are likewise inactive: no field-value read, prediction request, learning update, overlay, or Tab interception.

## Why it feels lightweight

- Inference runs in the cloud through OpenRouter—no GGUF, MLX, llama.cpp, or model weights.
- The default model is locked to `google/gemma-4-26b-a4b-it` and routed for latency with reasoning disabled.
- An 80 ms debounce, one in-flight request, cancellation, generation checks, and a six-second timeout prevent stale completions.
- The native app keeps prediction running after its Settings window closes and targets an idle footprint well below 100 MB.

## Learns your writing—without keeping your writing

nodaystypst gradually adapts to repeated vocabulary, short phrases, punctuation, capitalization, and sentence-length tendencies.

It does **not** store documents, messages, chronological typing history, secure-field contents, or AI-inserted completions. The local profile contains bounded aggregate counters, is encrypted with AES-GCM, and uses a random key stored in Keychain. Learning can be disabled or reset globally or per supported app. **Clear All Learned Data** in Settings immediately removes the encrypted aggregate profile.

## Privacy and safety

| Contract | Behavior |
| --- | --- |
| API credential | Stored in macOS Keychain only |
| Network | OpenRouter prediction requests only |
| Context | Short bounded text around the caret |
| Secure fields | Blocked before content capture or prediction |
| Unsupported apps | Content-blind and inactive |
| Overlay | Non-activating and click-through |
| Untrusted geometry | Hide instead of guessing |
| Logging | Field contents are not logged by default |

## Requirements

- macOS 15 or newer
- Apple silicon or Intel Mac supported by Swift 6
- An [OpenRouter](https://openrouter.ai/) API key
- Accessibility permission for cross-app reading and accepted-text insertion

No paid Apple Developer account is required to build the app locally. Local builds are ad-hoc signed and are not notarized for public binary distribution.

## Build from source

```bash
git clone https://github.com/nodaysidle/nodaystypst.git
cd nodaystypst
swift test
Scripts/package_app.sh release
open Nodaystypst.app
```

The packaged app is created at `Nodaystypst.app` in the repository root. To install it locally:

```bash
ditto Nodaystypst.app /Applications/Nodaystypst.app
```

Because the app uses a local ad-hoc signature, replace its entry in **System Settings → Privacy & Security → Accessibility** after rebuilding the executable.

## First run

1. Launch `Nodaystypst.app`.
2. In the Settings window, save your OpenRouter key in the secure field and choose whether predictions and learning are enabled.
3. Grant Accessibility access to the exact installed app path.
4. Use **Clear All Learned Data** whenever you want to remove the encrypted aggregate writing profile.
5. Close Settings if you want; prediction continues in the background and the Dock icon reopens it.
6. Write in any compatible content field, pause briefly, and press Tab when the grey completion appears. Ghostty can show a completion but keeps Tab for shell completion.

Settings never focuses the secure API-key field automatically, so opening the app does not disable AeroSpace shortcuts. macOS Secure Input is active only while you intentionally click and edit that protected field; saving the key moves focus back to a normal control.

For additional non-sensitive diagnostics, launch the installed app explicitly with:

```bash
open -na /Applications/Nodaystypst.app --args --qa-settings
```

Normal launches show the same desktop Settings window without the QA-only diagnostics section. Closing the window leaves the lightweight completion service running; click the Dock icon to reopen it.

## Architecture

```text
AccessibilityObserver ──► SecureFieldGate ──► CompletionCoordinator
        │                                             │
        │                                     PredictClient
        │                                      (OpenRouter)
        ▼                                             │
   FieldAdapter ◄──────── AcceptInsert ◄────── GhostOverlay
        │
        └── WritingStyleStore (encrypted aggregate profile)
```

The implementation is a native SwiftPM desktop app with a lightweight AppKit Settings window and AppKit/ApplicationServices for Accessibility, overlay placement, and insertion. A thin SwiftUI scene shell supplies the macOS application lifecycle and commands.

## Verification

The automated suite covers secure-field blocking, bounded context, UTF-16-safe insertion, adapter trust, cancellation/generation policy, 2–4-word output, encrypted personalization, supported-app isolation, and icon-aware packaging.

Run everything with:

```bash
swift test
```

Live release checks cover the ten-app compatibility matrix. A field must either show a correctly aligned ghost or safely show nothing—misaligned output is never accepted as a fallback.

## Project status

This is an early macOS release focused on a verified compatibility matrix rather than claiming universal app support. The product direction is simple: expand only with AX evidence, learn repeated writing tendencies over normal use, and stay out of the way everywhere else.

---

Built by [NODAYSIDLE](https://github.com/nodaysidle).
