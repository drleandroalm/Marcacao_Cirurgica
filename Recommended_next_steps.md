# Recommended Next Steps

- Stress the refined highlight pipeline with UI snapshot tests (e.g., `swift-snapshot-testing`) covering light/dark schemes and long snippets.
- Add an automated simulator smoke test that launches the app, taps “Refinar” on a seeded preview, and verifies highlight updates via accessibility identifiers.
- Profile the new extraction context cache—ensure background `Task` churn does not leak when toggling recording rapidly.
- Extract a dedicated `AbbreviationExpander` helper and pre-compile regexes to reduce per-call overhead in `EntityExtractor`.
- Consolidate redacted logging through a `RedactedLogger` facade and scrub residual PHI from legacy debug prints.
- Expand DocC coverage: produce an end-to-end article (capture → transcription → extraction → decisions) and annotate new types (`ExtractionSessionContext`, `RefinementQueue`, `HighlightedTranscriptView`).
- Externalize surgeon/procedure datasets into signed JSON bundles with diff tooling for hospital updates.
- Introduce configuration structs (e.g., `RecordingConfig`, `ExtractionConfig`) injected into `Recorder` and `EntityExtractor` to expose toggles like `shouldWriteToDisk`, confidence thresholds, and model timeouts for future modes and testing.
- Evaluate adoption of Instruments (Time Profiler + os_signpost) for the entire stop-recording pipeline to quantify post-stop latency after recent optimizations.
