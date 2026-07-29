# Cotypist-style Cloud Autocomplete Design

## Product contract

nodaystypst remains a native Swift 6 menu-bar app whose predictions come only
from OpenRouter. The default model is `google/gemma-4-26b-a4b-it`; no local model
weights are added. Suggestions contain at most four words. A physical Tab accepts
only the next visible word, preserves the unaccepted remainder as the ghost, and
supports repeated Tab presses. Continuing to type rejects the visible remainder
and starts a new prediction cycle. Boundary whitespace belongs to the first
accepted word, while punctuation attached to a word remains attached.

The Phase A target applications are Orion, Bear, Antinote, Ghostty, and ChatGPT
for macOS. When an application does not emit Accessibility value or selection
notifications, a bundle-scoped content-blind event wake-up may request a fresh AX
snapshot after a key event. It never reads, stores, reconstructs, or logs key
characters. Accessibility remains the only source of field content, and secure
field metadata is checked before any value is read.

## Personalization architecture

Personalization uses one global profile plus one profile per supported bundle.
The app learns only from user-authored append operations observed through AX in
non-secure fields. Text already present when a field is first observed becomes a
baseline and is not learned. AI-inserted completions advance the baseline without
incrementing statistics, preventing a feedback loop.

Completed words, repeated two-word phrases, punctuation preferences,
capitalization ratio, and approximate sentence length are aggregated into bounded
counters. Raw field snapshots, documents, messages, and chronological typing
history are never persisted. One-off terms are not included in prompts; a term or
phrase must repeat before it can influence a suggestion. Counters are bounded and
aged so old habits gradually lose weight.

The compact profile is encrypted with AES-GCM in Application Support. Its random
encryption key is stored in Keychain. Settings provide a learning toggle, a clear
all action, and per-app enable/reset controls. Prediction requests receive only a
short derived style summary merged from the global and active-app profiles.

## Reliability and verification

Gemma 4 requests use a 4-second timeout, generation checks,
single-in-flight rule, short prefix cap, and silent failure behavior. The model
default migration replaces only the prior built-in Ministral value; future user
choices remain intact. The request is deterministic and low-latency oriented,
with a small output budget and no reasoning requirement.

Automated coverage must prove model migration, four-word output capping,
word-by-word splitting (including Unicode, whitespace, and punctuation), secure
field exclusion, encrypted profile persistence, bounded/aged counters, minimum
repeat thresholds, per-app merging, and exclusion of accepted AI text. The full
Swift test suite and release packaging/signature checks must pass.

Live completion remains gated on Orion, Bear, Antinote, Ghostty, and ChatGPT.
Each target must prove aligned ghost-or-safe-hide behavior, next-word Tab insertion
without duplication, continued-typing rejection, focus retention, and secure-field
blocking when a relevant secure field exists. A missing notification may justify
only the content-blind AX refresh described above.
