# Technical Requirements Document — nodaystypst

## System Context
nodaystypst is a macOS 15+ menu-bar app (Swift 6, SwiftUI + AppKit) that implements cloud ghost completion in Orion Browser and Antinote only: Accessibility capture → debounce → OpenRouter predict → non-activating ghost → word-by-word Tab acceptance / keep-typing reject. Unsupported bundles remain content-blind and inactive. Injection is Approach 1 (Accessibility + overlay + adapter insert). Encrypted local aggregate statistics personalize prompts; there is no local LLM.

## Stack Rules
| Rule | Contract |
| --- | --- |
| Language | Swift 6 strict concurrency |
| UI | SwiftUI for menu bar / settings; AppKit for overlay + AX interop |
| Inference | OpenRouter only; no on-device model weights |
| Secrets | OpenRouter API key in Keychain only |
| Process | LSUIElement menu-bar app |
| Network | Outbound HTTPS to OpenRouter for predictions |

## Permissions
| Permission | Required | Behavior if denied |
| --- | --- | --- |
| Accessibility (`AXIsProcessTrusted`) | Yes | Onboarding / Settings prompt; no capture, no ghost, no Tab accept |
| Network client | Yes | Predict fails silently in-field; Settings may show last error |
| Keychain access | Yes | Cannot save/load API key; Settings surfaces failure |

## Distribution
- **Direct-distribution build is intentionally non-sandboxed.** App Sandbox is removed because cross-app AX reads/observers/writes are incompatible with sandboxing. Accessibility consent is still required.
- `Scripts/package_app.sh` performs deterministic bundle-entitlement verification at packaging time: fails if App Sandbox is present, fails if `network.client` is not `true`.
- No App Store distribution or notarization in Phase A.

## Context Window Limits
- Send **short context snippets only** (bounded text before and after the caret).
- Recommended Phase A budgets (tunable constants, not magic literals scattered):
  - Max combined context: **800 characters**; suffix reservation **≤ 160**; hard cap **≤ 1000**
  - Max completion tokens / characters requested: small phrase (e.g. **≤ 40–80** tokens or equivalent char budget)
- Never send full document bodies, attachments, or multi-field dumps.
- Strip or refuse content from secure fields before any network call.

## Debounce / Cancel / Timeout
| Parameter | Contract |
| --- | --- |
| Debounce | **~80–150ms** after last relevant edit before starting predict |
| In-flight | **Exactly one** prediction request; new cycle cancels the previous |
| Cancel | On keystroke / value change that invalidates the generation, cancel URLSession task and bump generation id |
| Timeout | Bound wait of **4 seconds** for the locked Gemma 4 model; on timeout drop response |
| Late response | If generation id ≠ current, discard; do not update ghost |
| Reject | Any typing while ghost visible clears ghost and restarts debounce |

## OpenRouter Request Shape
- **Endpoint:** OpenRouter chat/completions (HTTPS), latency-oriented model routing.
- **Auth:** `Authorization: Bearer <key from Keychain>`.
- **Body (conceptual):**
  - System: short instruction — continue the user’s text naturally; return only the continuation; no quotes/markdown fences.
  - User: labeled bounded text before the caret, `<CURSOR>`, and optional bounded text after it.
  - Output: exactly **2–4 insertable words**; deterministic gates reject shorter, repeated, or suffix-duplicating text.
  - Prefer low-latency models / OpenRouter routing that minimizes TTFT for short completions.
- **Response:** Trim to continuation only; reject empty / identical-to-prefix.
- **Errors:** Map to silent in-field no-op; optional Settings “last failure” string (no raw key, no full prompt dump).

The default model id is `google/gemma-4-26b-a4b-it`. The request sorts providers by latency, denies data-collection providers, allows same-model provider fallback, uses temperature `0.2`, and disables reasoning. The previous built-in Ministral default migrates automatically; an explicit custom model value remains intact.

## Overlay Behavior
| Rule | Contract |
| --- | --- |
| Activation | Non-activating; must not become key or steal focus |
| Hit testing | Click-through (`ignoresMouseEvents` or equivalent) |
| Content | Ghost string only; fixed mid-grey with contrast on light and dark host fields |
| Ordering | Status-window level and inactive-app-safe front ordering; key/main window must remain unchanged |
| Show | Only when adapter returns trusted caret screen rect **and** generation is current |
| Hide | Secure field, pause, untrusted geometry, cancel, timeout, reject, accept, focus loss |
| Misdraw | **Forbidden** — if alignment uncertain, hide |

## Field Adapter Contract

```text
protocol FieldAdapter {
  func canHandle(app: RunningApp, element: AXUIElement) -> Bool
  func isSecure(...) -> Bool
  func readContext(...) throws -> FieldContext   // short snippet + caret meta
  func caretScreenRect(...) -> CGRect?           // nil => untrusted
  func geometryTrusted(...) -> Bool
  func insertAcceptedText(_ text: String) throws
  func shouldOfferTabAccept() -> Bool
}
```

### NativeAdapter
- Selected for Orion (`com.kagi.kagimacOS`) and Antinote (`com.chabomakers.Antinote`).

### Unsupported adapters

- Legacy Codex, Chromium/Electron, and terminal adapters may remain in source for future work.
- The supported-app gate runs before reading field values. Unsupported bundles receive no prediction request, overlay, learning update, or Tab interception.

### ChromeElectronAdapter (existing compatibility, not a Phase A ship gate)
- Existing Chromium compatibility code may remain, but Chrome, Cursor, and VS Code evidence cannot satisfy Phase A acceptance.
- Do not implement further Chromium-specific repairs unless the user explicitly re-scopes the product.

### Adapter selection
- Match by bundle identifier first, then AX role heuristics.
- Supported-app gate first; unsupported bundle → content-blind safe hide.

## Tab Accept Default
- When ghost is visible and `shouldOfferTabAccept()` is true: **Tab accepts the next shown word**.
- Leading boundary whitespace and punctuation attached to that word are accepted with it.
- The unaccepted remainder is re-anchored at the new caret and remains available for repeated Tab presses without another request.
- Keep typing rejects the visible remainder.

## Secure Field Rules
Block predict + ghost + Tab accept when any of:
- AX role / subrole indicates secure text / password
- Attribute traits mark secure input
- Known bundle+element patterns for password managers’ secure entry (best effort)

On block: silent no-op.

## Error Matrix
| Condition | In-field UX | Settings / logs |
| --- | --- | --- |
| Accessibility denied | No ghost | Persistent CTA to grant |
| Missing API key | No ghost | Prompt to add key |
| Network / OpenRouter 4xx/5xx | No ghost | Optional last-error summary |
| Timeout / cancel / stale | No ghost / clear stale | Debug log only |
| Untrusted caret | No ghost | Debug log only |
| Secure field | No ghost | No content logged |
| Insert failure after Tab | Clear ghost; do not retry loudly | Error log without field dump |

**Default logging:** no field content. Debug builds may gate verbose AX behind an explicit developer flag.

## Privacy Contracts
- Keychain for API key
- Short snippets only on the wire
- No telemetry product in Phase A
- Silent failures on the caret path

## Performance Contracts
- Idle RAM well under **~100MB** (no weights)
- One in-flight HTTP request
- Debounce **80–150ms**
- Overlay show/hide must not activate the app

## QA Acceptance Tests (Must-Pass)

### Shared
1. Grant Accessibility; save OpenRouter key to Keychain; confirm idle memory well under ~100MB.
2. Type in a normal field → after debounce, ghost appears only if aligned → Tab inserts the next word and repeated Tab walks the remainder.
3. Type while ghost visible → ghost clears; no late response reappears for old generation.
4. Focus a password field → no request / no ghost (verify via network/debug flag, not by logging secrets).
5. Pause from menu bar → no ghosts anywhere.

### Actual target matrix

For each target below, record the real bundle identifier, selected adapter, AX value/selection notification behavior, caret geometry, and insertion behavior before changing fallback code.

| Target | Bundle ID | Initial adapter |
| --- | --- | --- |
| Orion Browser | `com.kagi.kagimacOS` | NativeAdapter |
| Antinote | `com.chabomakers.Antinote` | NativeAdapter |

Both targets must prove: 2–4-word contextual ghost; correct boundary spacing; aligned ghost or safe hide; physical Tab inserts the next visible word exactly once; repeated Tab walks the remainder; continued typing rejects it; no focus steal; and secure/password fields produce no request and no ghost. Unsupported apps must remain content-blind and inactive.

An event fallback is allowed only after the same target reproduces a missing-notification defect. It may only trigger a fresh AX snapshot, must not record characters, must not replace AX as the content source, and must not bypass SecureFieldGate.

Live Antinote QA reproduced readable AX text/caret state without a prediction wake-up after typing, so Antinote shares Orion's content-blind key-event refresh. The event payload is never inspected or retained.

## Personalization Contract
- Learning is enabled for this user and can be disabled globally or per target app in Settings.
- One global profile and one profile per bundle contain bounded word, repeated two-word phrase, punctuation, capitalization, and sentence-length counters.
- A first observation establishes a baseline. Only small appended AX changes are learned; large pastes and replacements establish a new baseline without collection.
- Secure fields never contribute. AI-inserted words advance the field baseline without incrementing counters.
- One-off terms never enter the OpenRouter style summary; a signal must repeat at least twice.
- Counters are capped, aged daily, duplicate-suppressed, and resettable per app or globally.
- The profile is AES-GCM encrypted in Application Support; its random 256-bit key is stored in Keychain.
- No raw document, message, prompt, chronological typing history, or reconstructed key content is persisted.
- OpenRouter receives only the bounded prefix plus a compact derived summary (maximum 420 characters).
- Encrypted profile updates run asynchronously and never delay a prediction request; a request may use the most recently committed profile while current typing catches up.

## Out of Scope (enforce in tests / review)
- Inline typo-fix productization
- Prompt-assist for ChatGPT / Claude / agents
- Local model download or embedding server

## Open Questions
- Whether provider routing keeps live Gemma 4 latency comfortably below the 4-second gate on the user's OpenRouter account
- Whether Antinote needs a narrower adapter after live AX characterization
