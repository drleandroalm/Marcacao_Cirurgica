# Changelog

# Changelog

## v1.2.0 — Context Caching & Highlighted Review *(Unreleased)*

- Added `ExtractionSessionContext` builder to precompute deterministic matches, knowledge-base deltas, and prompt targets.
- Introduced shared `HighlightedTranscriptView` with actor-backed `HighlightingContextCache` and VoiceOver-friendly labels.
- Persisted evidence spans on `SurgicalRequestForm` and surfaced them across preview/decision flows.
- Implemented debounced `RefinementQueue` actor powering the “Refinar” buttons without blocking the main actor.
- Hardened `SpokenWordTranscriber` with pre-stop context caching and `@ObservationIgnored` task references to avoid SwiftUI crashes.
- Expanded XCTest coverage with context fixtures, highlight rendering checks, and refined deterministic stage assertions.

## v1.1.1 — Extraction Robustness & Disambiguation

- Fallback extraction now expands medical abbreviations (RTU/RTUP/UTL/etc.) before matching.
- Added knowledge‑base assisted extraction that scans transcript n‑grams to resolve surgeons and procedures without requiring prefixes like “Dr.” or generic keywords.
- Hardened phone parsing to accept non‑digit separators and pre‑fill 8–9 digit numbers (UI guides to add DDD; validator flags until complete).
- Disambiguated duration vs. time phrases: when a clock time is already present, hours‑only matches like “uma hora da tarde” are ignored unless accompanied by duration keywords.
- All unit tests continue to pass.

### UI
- Dark theme adoption across main flow, glass‑morphism cards, and cyan glow accents
- Gradient microphone button with pulsing animation while recording
- Removed “Passo a Passo” (field‑by‑field) mode; app now operates exclusively in “Contínuo” mode

## v1.1.0 — History, Export, and Parser Fixes

- Added a new “Histórico” tab with persistent sessions and browsing features:
  - Chronological sections, search, entity filters, delete.
  - Session detail with copy/share.
  - “Clear All” with confirmation.
- Bulk export for history (CSV/JSON) with anonymization toggle.
- PHI/PII sanitization in logs (redacted summaries only).
- Unified export pipeline — `FormExporter` delegates to `SurgicalRequestForm.generateFilledTemplate()`.
- Parser improvements:
  - Portuguese date phrase handling (e.g., “vinte e sete de setembro de 2024”).
  - Weekday phrases (e.g., “próxima segunda”).
  - Duration phrases (e.g., “uma hora e meia”).
- New unit tests for time/duration edge cases.
- Build/test configuration updated for command‑line runs.
