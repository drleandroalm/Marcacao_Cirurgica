# Roadmap

This roadmap outlines near‑term and long‑term development priorities. Dates are targets and may shift based on validation and feedback.

## Recently Shipped (v1.2.0)
- Highlighted transcript pipeline with reusable `HighlightedTranscriptView`
- Context precomputation cache and deterministic stage gating for `EntityExtractor`
- Batch refinement queue with debounced UI entry points in Form Preview
- Evidence spans persisted on `SurgicalRequestForm` for downstream review surfaces
- Additional fixtures + tests for deterministic stage snapshots and highlight rendering
- Accessibility pass for highlights (VoiceOver label for snippet + confidence)

## Recently Shipped (v1.1.1)
- Robust fallback extraction (KB‑assisted n‑gram scan for surgeons/procedures)
- Abbreviation expansion in fallback (RTU/RTUP/UTL/etc.)
- Phone parsing hardened (non‑digit separators; accepts 8–9 digits sans DDD for pre‑fill)
- Duration disambiguation when a clock time is already present

## Recently Shipped (v1.1.0)
- History tab with persistent sessions (search, filters, delete)
- Bulk export of history (CSV/JSON) with anonymization toggle
- PHI‑safe logs (redacted summaries only)
- Unified export via `SurgicalRequestForm.generateFilledTemplate()`
- pt‑BR parsing improvements: complex date phrases, weekday phrases ("próxima segunda"), durations ("uma hora e meia")
- Expanded test coverage for time/duration parsing; fixed breaking tests

## v1.2.x (Q4 2025)
- PDF export with form layout and branding
- Enhanced weekday phrases (e.g., "na próxima sexta à tarde") and relative dates beyond 2 days
- Session tagging and notes for later retrieval
- History export presets (filters remembered per export)
- Optional encryption for CSV/JSON exports

## v2.0 (Q2 2026)
- Multi‑template support (e.g., Admission, Consent, Lab Request) with per‑template models and validators
- iCloud (Private Database) sync for sessions and knowledge base updates (opt‑in)
- Voice commands for navigation and field confirmation in both modes
- Template‑aware PDF export with watermarks and signing placeholders

## Design & UX
- Continue refining the dark theme with accessible contrast ratios and dynamic type sizes
- Add haptics tied to extraction confidence and popup decisions
- Explore a heads‑up “recording strip” for background recording with quick stop/confirm actions

## v3.0 (Q4 2026)
- HL7/FHIR integrations to hospital systems (export pipeline adapters)
- Multi‑user support with roles and local user profiles
- Analytics dashboard (local, aggregated, and privacy‑preserving)
- Offline model improvements (domain‑tuned on‑device post‑processors)

## Technical Debt & Quality
- Snapshot/UI testing for highlight cards and refinement states (XCUITest or swift-snapshot-testing)
- Centralize redaction utilities; compile‑time protections for logging
- Expand unit tests for regex fallbacks and edge‑case date/time (including locale misspellings)
- Stress test Recorder/Transcriber lifecycle (rapid toggling, backgrounding)
- Performance profiling and os_signpost marks across pipeline

## Security & Privacy
- PHI scrubber in export pipeline (best‑effort heuristics) as a secondary anonymization option
- Optional export encryption (AES‑GCM) with local keychain storage
- Privacy review checklist for new templates

## Knowledge Base
- Tools to curate and validate JSON resources (surgeons, procedures, abbreviations)
- CSV→JSON pipeline with diff reporting and unit tests for KB migrations
- Capture user feedback loop from refinement queue to score KB coverage

---

Contributions are welcome. Please file issues with a minimal reproduction, expected behavior, and proposed solution outline. See CONTRIBUTING.md for guidelines.
