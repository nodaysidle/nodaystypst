# nodaystypst

## Product Vision
A lightweight macOS desktop utility that predicts the next words while you type in verified apps, shows a ghost completion inline, and inserts it only when you press Tab — like editor autocomplete, but system-wide. Predictions come from OpenRouter (cloud); no local LLM weights.

## Problem Statement
macOS has no first-class cloud ghost completion across the user's selected writing surfaces. Editor autocomplete stays trapped in one app. Local models burn RAM and complicate install. Users need a thin, privacy-aware assistant that feels like keystroke assist across supported writing apps: capture → predict → ghost → Tab accept / keep typing to reject.

## Goals (Phase A)
- Capture focused text-field context via Accessibility
- Debounce (~80–150ms), cancel in-flight work on keystroke, keep one in-flight prediction request
- Call OpenRouter for short next-token / phrase predictions
- Show a non-activating ghost overlay aligned to the caret when geometry is trustworthy
- One Tab accepts the entire shown 2–4-word completion via adapter-based insert; further typing rejects it.
- First-class quality in Orion, Antinote, Bear, ChatGPT, Ghostty, TextEdit, Notes, Safari, and Obsidian; remain inactive in unverified apps and unsafe controls
- Hide the ghost rather than misdraw; Chrome is explicitly content-blind because live AX exposes no trustworthy caret rectangle
- Block secure / password fields; store API key in Keychain; send short context snippets only
- Fail silently in-field (no error toasts on the caret path)
- Idle RAM well under ~100MB (no model weights on disk or in memory)
- Learn repeated vocabulary, short phrasing, punctuation, capitalization, and sentence-length tendencies within ordinary daily use
- Keep learned data as encrypted, bounded statistics; never retain raw documents or chronological typing history
- Suppress prediction when the last non-whitespace character before the caret is `?`, preventing conversational answers instead of same-author completion
- Let the user clear all encrypted learned-writing statistics directly from Settings

## Non-Goals (Phase A)
- Local LLM / on-device model weights of any kind
- Inline typo-fix as a productized feature
- Prompt-assist productization for ChatGPT, Claude, or coding agents
- IMK / input-method takeover as the primary injection path
- Global key-tap logging as the sole capture strategy
- Accounts, sync, telemetry dashboards, or multi-device profiles
- iOS / iPadOS / non-macOS platforms
- Whole-line or uncontrolled paragraph insertion; suggestions remain bounded to 2–4 words

## Target Users
- Users who write across native apps, browsers, Electron editors, ChatGPT, and Ghostty
- Anyone who wants editor-style ghost complete outside a single IDE
- Privacy-conscious users who will not run local model weights for this job

## Core User Story (Phase A)
1. User grants Accessibility and pastes an OpenRouter API key into Settings (Keychain).
2. User types in a supported text field.
3. After a short debounce, a ghost continuation appears at the caret (when alignment is trusted).
4. One Tab inserts the entire shown 2–4-word completion. Continuing to type dismisses it and may trigger a new prediction.
5. In secure fields, or when caret geometry is unknown/misaligned, nothing is shown.

## Core Features (Phase A)
- **AccessibilityObserver:** Focused element, value/selected text, caret bounds when available
- **FieldAdapters:** Evidence-selected insert + geometry strategies (native AppKit/AX, terminal where supported, and app-specific paths only when actual target evidence requires them)
- **GhostOverlay:** Non-activating, click-through overlay that never steals focus
- **PredictClient:** OpenRouter client with latency-oriented routing, cancel, timeout, single in-flight request
- **AcceptInsert:** Tab handler that inserts via the active adapter
- **WritingStyleStore:** encrypted global + per-app aggregate statistics that gently shape OpenRouter prompts
- **SecureFieldGate:** Blocks password / secure-text roles and known secure AX traits
- **Desktop Settings:** Pause/resume, clear all learned writing, API key (Keychain), basic status, onboarding for Accessibility; prediction keeps running when the window closes

## Phase Roadmap
| Phase | Scope |
| --- | --- |
| **A** | Capture → debounce → predict → ghost → Tab accept / keep-typing reject across the verified compatibility matrix |
| **B** | **Approved and implemented:** encrypted local style / vocabulary statistics shape prompts (still OpenRouter inference; no local LLM) |
| **C** (teaser) | Optional richer surfaces only if Phase A/B quality bar holds — not typo-fix or agent prompt-assist by default |

## Must-Pass Surfaces (Phase A ship gate)
| App | Bar |
| --- | --- |
| Orion Browser (`com.kagi.kagimacOS`) | Ghost aligns or safely hides; physical Tab inserts the shown completion once; secure fields block |
| Antinote (`com.chabomakers.Antinote`) | Same bar; continued typing rejects; no focus steal |
| Bear (`net.shinyfrog.bear`) | Native AX fields; Tab accept enabled; secure-field gating |
| ChatGPT (`com.openai.codex`) | Field-anchored banner via `CodexAdapter`; Tab accept enabled |
| Ghostty (`com.mitchellh.ghostty`) | Ghost shown on the trailing line; **Tab not intercepted** so shell completion keeps working |
| TextEdit (`com.apple.TextEdit`) | Native AX field; aligned ghost or safe hide; Tab accept enabled |
| Notes (`com.apple.Notes`) | Native AX note editor; aligned ghost or safe hide; Tab accept enabled |
| Safari (`com.apple.Safari`) | Web-content editable fields only; address/search bar rejected before content capture |
| Google Chrome (`com.google.Chrome`) | Safe-rejected before content capture because live AX provides no trustworthy caret geometry |
| Obsidian (`md.obsidian`) | Electron editor via `ChromeElectronAdapter`; Tab accept enabled only with trusted geometry |

All enabled and display-only apps are **ship blockers**. Chrome's explicit content-blind safe rejection is the verified result, not a compatibility claim. Every other bundle remains content-blind and inactive until separately verified. Misaligned ghost = fail; hide instead.

## Design Requirements
- Normal operation uses a visible desktop Settings window and Dock icon; closing Settings keeps the completion service running
- Ghost text visually secondary to the host field (muted / translucent), matching host font metrics when obtainable
- Overlay must not activate the app or steal keyboard focus
- Settings: API key entry, pause toggle, clear all encrypted learned-writing statistics, Accessibility status, compatibility matrix, and optional non-sensitive QA diagnostics
- The protected API-key field must never be the initial Settings focus, so merely opening the app does not engage macOS Secure Input or block AeroSpace shortcuts
- Onboarding: clear Accessibility + Keychain key steps; no dark patterns

## Non-Functional Requirements
- Stack: Native Swift 6 desktop app with a thin SwiftUI shell and lightweight AppKit Settings/AX surfaces
- Inference: OpenRouter only in Phase A/B (no local model)
- Debounce ~80–150ms; cancel on keystroke; drop late responses after timeout; one in-flight request
- Idle RAM target well under ~100MB
- Privacy: secure fields blocked; Keychain for secrets; short context snippets only; no field-content logging by default
- Silent failures on the typing path

## Success Metrics
- Feels like keystroke assist: ghost appears after debounce without perceptible UI fighting
- Idle memory well under ~100MB
- Zero secure-field leaks (no predict / no ghost in password fields)
- Must-pass apps: ghost either correctly aligned or hidden; Tab accepts the shown completion without focus loss where the adapter allows it
- Personalization: repeated signals begin influencing prompts during the first day of normal writing; one-off terms do not
- Named targets: no shipping build that shows a misaligned ghost or bypasses secure-field gating
- Prediction path: cancel + timeout behave correctly under fast typing

## Assumptions
- User grants Accessibility; product is non-functional without it
- User supplies their own OpenRouter API key
- macOS 15+ is acceptable for Phase A unless later docs revise
- Caret geometry varies across target apps — hide-over-misdraw is the contract
- Tab is free enough in must-pass contexts, or adapters detect when Tab would be harmful and refuse to show/accept

## Open Questions
- Default OpenRouter model is locked to `google/gemma-4-26b-a4b-it`, routed for latency with reasoning disabled
- Personalization is on-device, encrypted, bounded, aged, resettable, and stores no raw snippets
- Whether a secondary accept key (e.g. Right Arrow) is needed later — not Phase A
