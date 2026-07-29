# nodaystypst

## Product Vision
A lightweight macOS menu-bar utility that predicts the next words while you type anywhere, shows a ghost completion inline, and inserts it only when you press Tab — like editor autocomplete, but system-wide. Predictions come from OpenRouter (cloud); no local LLM weights.

## Problem Statement
macOS has no first-class cloud ghost completion across the user's selected writing surfaces. Editor autocomplete stays trapped in one app. Local models burn RAM and complicate install. Users need a thin, privacy-aware assistant that feels like keystroke assist in Orion and Antinote: capture → predict → ghost → Tab accept / keep typing to reject.

## Goals (Phase A)
- Capture focused text-field context via Accessibility
- Debounce (~80–150ms), cancel in-flight work on keystroke, keep one in-flight prediction request
- Call OpenRouter for short next-token / phrase predictions
- Show a non-activating ghost overlay aligned to the caret when geometry is trustworthy
- Tab accepts the next shown word via adapter-based insert; repeated Tab walks the visible remainder and further typing rejects it.
- First-class quality in Orion Browser and Antinote; remain inactive elsewhere
- Hide the ghost rather than misdraw; every named target is a ship blocker, not best-effort
- Block secure / password fields; store API key in Keychain; send short context snippets only
- Fail silently in-field (no error toasts on the caret path)
- Idle RAM well under ~100MB (no model weights on disk or in memory)
- Learn repeated vocabulary, short phrasing, punctuation, capitalization, and sentence-length tendencies within ordinary daily use
- Keep learned data as encrypted, bounded statistics; never retain raw documents or chronological typing history

## Non-Goals (Phase A)
- Local LLM / on-device model weights of any kind
- Inline typo-fix as a productized feature
- Prompt-assist productization for ChatGPT, Claude, or coding agents
- IMK / input-method takeover as the primary injection path
- Global key-tap logging as the sole capture strategy
- Accounts, sync, telemetry dashboards, or multi-device profiles
- iOS / iPadOS / non-macOS platforms
- Whole-line or uncontrolled paragraph insertion; suggestions remain 2–4 words and Tab accepts one word at a time

## Target Users
- Users who write in Orion Browser and Antinote
- Anyone who wants editor-style ghost complete outside a single IDE
- Privacy-conscious users who will not run local model weights for this job

## Core User Story (Phase A)
1. User grants Accessibility and pastes an OpenRouter API key into Settings (Keychain).
2. User types in a supported text field.
3. After a short debounce, a ghost continuation appears at the caret (when alignment is trusted).
4. Tab inserts the next shown word; repeated Tab accepts the remainder word-by-word. Continuing to type dismisses it and may trigger a new prediction.
5. In secure fields, or when caret geometry is unknown/misaligned, nothing is shown.

## Core Features (Phase A)
- **AccessibilityObserver:** Focused element, value/selected text, caret bounds when available
- **FieldAdapters:** Evidence-selected insert + geometry strategies (native AppKit/AX, terminal where supported, and app-specific paths only when actual target evidence requires them)
- **GhostOverlay:** Non-activating, click-through overlay that never steals focus
- **PredictClient:** OpenRouter client with latency-oriented routing, cancel, timeout, single in-flight request
- **AcceptInsert:** Tab handler that inserts via the active adapter
- **WritingStyleStore:** encrypted global + per-app aggregate statistics that gently shape OpenRouter prompts
- **SecureFieldGate:** Blocks password / secure-text roles and known secure AX traits
- **Menu bar + Settings:** Pause/resume, API key (Keychain), basic status, onboarding for Accessibility

## Phase Roadmap
| Phase | Scope |
| --- | --- |
| **A** | Capture → debounce → predict → ghost → Tab accept / keep-typing reject; Orion and Antinote only |
| **B** | **Approved and implemented:** encrypted local style / vocabulary statistics shape prompts (still OpenRouter inference; no local LLM) |
| **C** (teaser) | Optional richer surfaces only if Phase A/B quality bar holds — not typo-fix or agent prompt-assist by default |

## Must-Pass Surfaces (Phase A ship gate)
| App | Bar |
| --- | --- |
| Orion Browser (`com.kagi.kagimacOS`) | Ghost aligns or safely hides; physical Tab inserts the next visible word once; secure fields block |
| Antinote (`com.chabomakers.Antinote`) | Same bar; continued typing rejects; no focus steal |

Both named apps are **ship blockers**. Every other bundle remains content-blind and inactive. Misaligned ghost = fail; hide instead.

## Design Requirements
- Menu-bar-only app (LSUIElement); no Dock icon
- Ghost text visually secondary to the host field (muted / translucent), matching host font metrics when obtainable
- Overlay must not activate the app or steal keyboard focus
- Settings: API key entry, pause toggle, Accessibility status, optional model/routing preference
- Onboarding: clear Accessibility + Keychain key steps; no dark patterns

## Non-Functional Requirements
- Stack: Native Swift 6 + SwiftUI menu-bar app; AppKit/AX where required
- Inference: OpenRouter only in Phase A/B (no local model)
- Debounce ~80–150ms; cancel on keystroke; drop late responses after timeout; one in-flight request
- Idle RAM target well under ~100MB
- Privacy: secure fields blocked; Keychain for secrets; short context snippets only; no field-content logging by default
- Silent failures on the typing path

## Success Metrics
- Feels like keystroke assist: ghost appears after debounce without perceptible UI fighting
- Idle memory well under ~100MB
- Zero secure-field leaks (no predict / no ghost in password fields)
- Must-pass apps: ghost either correctly aligned or hidden; Tab accepts word-by-word without focus loss
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
