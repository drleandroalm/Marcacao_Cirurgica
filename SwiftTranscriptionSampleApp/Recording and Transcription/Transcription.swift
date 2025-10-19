/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Live transcription code
*/

import Foundation
import Speech
import SwiftUI
import FoundationModels
import AVFoundation
import CoreMedia
import Observation
import os

@MainActor
@Observable
/// Manages Speech framework analyzers, converts raw audio into structured transcripts, and pushes normalized values back into the form.
final class SpokenWordTranscriber {
    private var inputSequence: AsyncStream<AnalyzerInput>?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var recognizerTask: Task<(), Error>?
    
    private var currentLocale: Locale?
    private var reservedLocale: Locale?

    static let magenta = Color(red: 0.54, green: 0.02, blue: 0.6).opacity(0.8) // #e81cff
    
    // The format of the audio.
    var analyzerFormat: AVAudioFormat?
    
    nonisolated let converter = BufferConverter()
    var downloadProgress: Progress?
    
    var form: SurgicalRequestForm
    var onFieldComplete: ((String) -> Void)?
    var onContinuousComplete: ((ExtractionResult) -> Void)?
    
    private(set) var configuration: TranscriptionConfiguration
    private let entityExtractor: EntityExtractor
    private static let metricsLog = OSLog(subsystem: "SwiftTranscriptionSampleApp", category: "Transcription")
    
    var volatileTranscript: AttributedString = ""
    var finalizedTranscript: AttributedString = ""
    var continuousTranscript: String = ""
    private var isProcessingTranscription = false
    @ObservationIgnored private var progressiveProcessingTask: Task<Void, Never>?
    @ObservationIgnored private var pendingExtractionContextTask: Task<ExtractionSessionContext, Never>?
    @ObservationIgnored private var pendingExtractionContextSource: String?
    
    private func redactedSummary(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return "<redacted len=\(trimmed.count) words=\(wordCount)>"
    }
    
    private func redactedValue(_ value: String) -> String {
        "<len=\(value.count)>"
    }
    
    static let locale = Locale(identifier: "pt-BR")
    
    init(form: SurgicalRequestForm,
         onFieldComplete: ((String) -> Void)? = nil,
         onContinuousComplete: ((ExtractionResult) -> Void)? = nil,
         configuration: TranscriptionConfiguration = TranscriptionConfiguration(),
         entityExtractor: EntityExtractor = .shared) {
        self.form = form
        self.onFieldComplete = onFieldComplete
        self.onContinuousComplete = onContinuousComplete
        self.configuration = configuration
        self.entityExtractor = entityExtractor
    }
    
    private func resolveSupportedLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let supportedIds = Set(supported.map { $0.identifier(.bcp47) })

        // Respect explicit override when available and supported
        if let override = configuration.localeOverride {
            let overrideId = override.identifier(.bcp47)
            if supportedIds.contains(overrideId) {
                return override
            }
        }

        // Preferred list in order
        let preferredIdentifiers = ["pt-BR", "pt_BR", "pt", "en-US"]
        // Try exact preferred matches by BCP-47 id
        for id in preferredIdentifiers {
            if supportedIds.contains(id) {
                return Locale(identifier: id)
            }
        }
        // Try matching by language code if none of the above
        if let pt = supported.first(where: { $0.language.languageCode?.identifier == "pt" }) {
            return pt
        }
        return nil
    }
    
    func setUpTranscriber() async throws {
        // Resolve a supported locale before initializing the transcriber
        let resolvedLocale = await resolveSupportedLocale()
        guard let resolvedLocale else {
            let supported = await SpeechTranscriber.supportedLocales
            let list = supported.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", ")
            print("❌ No supported locale available for SpeechTranscriber. Supported locales: \(list)")
            throw TranscriptionError.localeNotSupported
        }
        self.currentLocale = resolvedLocale
        let cache = TranscriptionSessionCache.shared
        let shouldReserve = await cache.retain(locale: resolvedLocale)
        var releaseLocaleOnFailure = true
        defer {
            if releaseLocaleOnFailure {
                let localeToRelease = self.reservedLocale ?? resolvedLocale
                self.reservedLocale = nil
                Task {
                    let shouldRelease = await cache.release(locale: localeToRelease)
                    if shouldRelease {
                        await AssetInventory.release(reservedLocale: localeToRelease)
                    }
                }
            }
        }

        // iOS 26 Best Practices for SpeechAnalyzer configuration
        
        // 1. Choose the right preset based on mode
        let preset: SpeechTranscriber.Preset
        // Use non-time-indexed progressive transcription in all modes to avoid strict timestamp requirements
        preset = .progressiveTranscription
        
        // 2. Configure transcriber with enhanced options
        let transcriptionOptions = preset.transcriptionOptions
        var reportingOptions = preset.reportingOptions
        var attributeOptions = preset.attributeOptions
        
        // Add iOS 26 enhanced options - only use available options
        reportingOptions = reportingOptions.union([
            .alternativeTranscriptions  // Get alternative interpretations
        ])
        
        attributeOptions = attributeOptions.union([
            .transcriptionConfidence    // Get confidence scores
        ])
        
        transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: transcriptionOptions,
            reportingOptions: reportingOptions,
            attributeOptions: attributeOptions
        )

        guard let transcriber else {
            throw TranscriptionError.failedToSetupRecognitionStream
        }

        // 3. Configure analyzer with optimal settings for iOS 26
        let analyzerOptions = SpeechAnalyzer.Options(
            priority: .high,                    // High priority for real-time transcription
            modelRetention: .processLifetime   // Keep model in memory for duration
        )
        
        analyzer = SpeechAnalyzer(modules: [transcriber], options: analyzerOptions)
        
        // 4. Asset management with proper error handling
        do {
            self.reservedLocale = resolvedLocale
            if shouldReserve {
                try await AssetInventory.reserve(locale: resolvedLocale)
            }
            
            // Check if assets are installed
            let installedLocales = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
            let isInstalled = installedLocales.contains(resolvedLocale.identifier(.bcp47))
            
            if !isInstalled {
                print("📥 Downloading speech assets for \(resolvedLocale.identifier)")
                if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    // Monitor download progress
                    self.downloadProgress = installationRequest.progress
                    try await installationRequest.downloadAndInstall()
                    print("✅ Speech assets downloaded successfully")
                }
            }
        } catch {
            print("❌ Asset management error: \(error)")
            // Try to continue without full assets
            if let reservedLocale = reservedLocale {
                let shouldRelease = await cache.release(locale: reservedLocale)
                if shouldRelease {
                    await AssetInventory.release(reservedLocale: reservedLocale)
                }
                self.reservedLocale = nil
            }
            releaseLocaleOnFailure = false
        }
        
        // 5. Configure audio format with best available quality (cache result per locale)
        if let cachedFormat = await cache.cachedFormat(for: resolvedLocale) {
            self.analyzerFormat = cachedFormat
        } else if let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
            self.analyzerFormat = bestFormat
            await cache.cache(format: bestFormat, for: resolvedLocale)
        } else {
            self.analyzerFormat = nil
        }
        
        // 6. Prepare analyzer with progress handler for better initialization
        let prepareProgress = Progress()
        try await analyzer?.prepareToAnalyze(
            in: analyzerFormat,
            withProgressReadyHandler: { progress in
                prepareProgress.addChild(progress, withPendingUnitCount: 1)
                print("🎯 Analyzer preparation: \(Int(progress.fractionCompleted * 100))%")
            }
        )
        
        // 7. Reset converter timeline to ensure monotonic timestamps for a fresh session
        converter.reset()

        // 8. Setup input stream with buffering configuration
        let streamConfiguration = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(10)  // Keep only newest buffers
        )
        inputSequence = streamConfiguration.stream
        inputBuilder = streamConfiguration.continuation
        
        guard let inputSequence else { return }
        
        // 9. Start analyzer with error recovery
        do {
            try await analyzer?.start(inputSequence: inputSequence)
            print("🚀 SpeechAnalyzer started successfully")
        } catch {
            print("❌ Failed to start analyzer: \(error)")
            throw error
        }

        // 10. Start results consumer task
        recognizerTask?.cancel()
        recognizerTask = Task {
            guard let transcriber = self.transcriber else { return }
            do {
                for try await result in transcriber.results {
                    await self.processTranscriptionResult(result)
                }
            } catch {
                await self.handleTranscriptionError(error)
            }
        }
        releaseLocaleOnFailure = false
    }
    
    @MainActor
    private func processAnalyzerInput(_ input: AnalyzerInput) async {
        guard let inputBuilder = inputBuilder else { return }
        
        // Yield the input to the stream
        inputBuilder.yield(input)
    }
    
    private func scheduleProgressiveProcessing() {
        cancelScheduledProcessing()
        let delay = max(0, configuration.progressiveDebounceInterval)
        let nanos = UInt64(delay * 1_000_000_000)
        progressiveProcessingTask = Task(priority: .userInitiated) { [weak self] in
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard !Task.isCancelled, let self else { return }
            await self.processContinuousTranscription()
        }
    }

    private func cancelScheduledProcessing() {
        progressiveProcessingTask?.cancel()
        progressiveProcessingTask = nil
    }

    private func prepareExtractionContextCache(for transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearExtractionContextCache()
            return
        }

        let snapshots = form.fields.map { field in
            FieldSnapshot(id: field.id, value: field.value, fieldType: field.fieldType)
        }

        pendingExtractionContextSource = trimmed
        pendingExtractionContextTask?.cancel()
        pendingExtractionContextTask = Task(priority: .utility) {
            await ExtractionSessionContext.build(originalText: trimmed, fieldSnapshots: snapshots)
        }
    }

    private func clearExtractionContextCache() {
        pendingExtractionContextTask?.cancel()
        pendingExtractionContextTask = nil
        pendingExtractionContextSource = nil
        Task { await HighlightingContextCache.shared.clear() }
    }

    private func resolveExtractionContext(for transcript: String) async -> ExtractionSessionContext {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if let task = pendingExtractionContextTask,
           let cachedSource = pendingExtractionContextSource,
           cachedSource == trimmed {
            return await task.value
        }

        let snapshots = form.fields.map { field in
            FieldSnapshot(id: field.id, value: field.value, fieldType: field.fieldType)
        }
        return await ExtractionSessionContext.build(originalText: trimmed, fieldSnapshots: snapshots)
    }

    
    private func processTranscriptionResult(_ result: SpeechTranscriber.Result) async {
        let text = result.text
        
        // Get confidence score from text attributes if available
        var confidence = 1.0
        if let firstRun = text.runs.first,
           let runConfidence = firstRun.transcriptionConfidence {
            confidence = runConfidence
        }
        print("📊 Result confidence: \(Int(confidence * 100))%")
        
        if result.isFinal {
            volatileTranscript = ""
            
            if configuration.isContinuousMode {
                // Extract plain text from AttributedString
                let plainText = String(text.characters)
                
                print("🎤 Continuous Mode - New segment \(redactedSummary(for: plainText))")
                print("  - Confidence: \(Int(confidence * 100))%")
                
                // Only accumulate high-confidence segments
                if confidence > configuration.confidenceThreshold {
                    // Accumulate transcript
                    if continuousTranscript.isEmpty {
                        continuousTranscript = plainText
                        print("📦 Starting new transcript")
                    } else {
                        continuousTranscript = continuousTranscript + " " + plainText
                        print("🔗 Appending to existing transcript")
                    }
                    
                    // Maintain finalizedTranscript for display
                    if !finalizedTranscript.characters.isEmpty {
                        finalizedTranscript.append(AttributedString(" "))
                    }
                    finalizedTranscript.append(text)
                    
                    // Debug logging
                    print("📊 Accumulated transcript stats:")
                    print("  - Total length: \(continuousTranscript.count) characters")
                    print("  - Word count: \(continuousTranscript.split(separator: " ").count) words")
                    
                    if configuration.processAfterRecording {
                        prepareExtractionContextCache(for: continuousTranscript)
                    }

                    // Only auto-process if NOT in "process after recording" mode
                    if !configuration.processAfterRecording &&
                        continuousTranscript.count > configuration.autoProcessCharacterCount &&
                        continuousTranscript.split(separator: " ").count > configuration.autoProcessWordCount {
                        print("🔄 Scheduling auto-processing for accumulated transcript (progressive mode)")
                        scheduleProgressiveProcessing()
                    } else if configuration.processAfterRecording {
                        cancelScheduledProcessing()
                        print("⏳ Accumulating transcript (will process after recording stops)")
                    }
                } else {
                    print("⚠️ Low confidence segment, skipping segment \(redactedSummary(for: plainText))")
                }
            } else {
                finalizedTranscript += text
                updateStoryWithNewText(withFinal: text)
            }
        } else {
            // Process volatile text for display
            var processedText = AttributedString(String(text.characters))
            if !configuration.isContinuousMode, let currentField = form.currentField {
                let processed = TranscriptionProcessor.processText(String(text.characters), fieldType: currentField.fieldType)
                processedText = AttributedString(processed)
            }
            processedText.foregroundColor = .purple.opacity(0.4)
            volatileTranscript = processedText
        }
    }
    
    private func handleTranscriptionError(_ error: Error) async {
        print("🔧 Attempting to recover from transcription error")
        
        // Reset volatile state
        volatileTranscript = ""
        
        // Log error details
        if let transcriptionError = error as? TranscriptionError {
            print("  - Error type: \(transcriptionError)")
        } else {
            print("  - Generic error: \(error.localizedDescription)")
        }
        
        // Attempt to restart if critical
        if !Task.isCancelled {
            print("  - Task not cancelled, continuing...")
        }
    }
    
    func updateStoryWithNewText(withFinal str: AttributedString) {
        let rawText = String(str.characters)
        guard let currentField = form.currentField else {
            form.updateCurrentFieldValue(rawText)
            onFieldComplete?(rawText)
            return
        }
        let fieldType = currentField.fieldType
        Task(priority: .userInitiated) { [weak self] in
            let processed = TranscriptionProcessor.processText(rawText, fieldType: fieldType)
            await MainActor.run {
                guard let self else { return }
                self.form.updateCurrentFieldValue(processed)
                self.onFieldComplete?(processed)
            }
        }
    }
    
    private func processContinuousTranscription() async {
        let signpostID = OSSignpostID(log: Self.metricsLog)
        os_signpost(.begin, log: Self.metricsLog, name: "processContinuousTranscription()", signpostID: signpostID)
        defer { os_signpost(.end, log: Self.metricsLog, name: "processContinuousTranscription()", signpostID: signpostID) }

        cancelScheduledProcessing()
        // Ensure we're not already processing to avoid duplicates
        guard !isProcessingTranscription else {
            print("⚠️ Already processing transcription, skipping duplicate call")
            return
        }
        
        isProcessingTranscription = true
        defer { isProcessingTranscription = false }
        
        print("📤 Processing continuous transcription...")
        print("📝 Transcript summary: \(redactedSummary(for: continuousTranscript))")
        
        let trimmed = continuousTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("⚠️ Transcript is empty - skipping processing")
            return
        }
        
        // Capture the transcript for processing
        let transcriptToProcess = trimmed
        let context = await resolveExtractionContext(for: transcriptToProcess)
        
        // Only clear if in process-after-recording mode (since we won't accumulate more)
        // In progressive mode, keep accumulating
        if configuration.processAfterRecording {
            continuousTranscript = ""  // Reset after final processing
            print("🧹 Cleared continuous transcript after final processing")
            clearExtractionContextCache()
        }
        
        do {
            print("🤖 Calling EntityExtractor with transcript of \(transcriptToProcess.count) chars")
            let result = try await entityExtractor.extractEntities(using: context, form: form)
            
            print("✅ Extraction complete: \(result.entities.count) entities found")
            
            // Log the extraction results first
            print("🎯 Extraction Results:")
            print("  - Total entities extracted: \(result.entities.count)")
            for (index, entity) in result.entities.enumerated() {
                print("  - Entity \(index + 1): \(entity.fieldId) = \(redactedValue(entity.value)) (confidence: \(Int(entity.confidence * 100))%)")
            }
            
            await MainActor.run {
                // Update form fields directly on success (was missing before)
                form.lowConfidenceFieldIds.removeAll()
                form.evidenceSnippets.removeAll()
                form.highlightSpans = result.highlights
                Task {
                    for highlight in result.highlights.values {
                        _ = await HighlightingContextCache.shared.fragments(for: highlight)
                    }
                }
                for entity in result.entities {
                    if let fieldIndex = form.fields.firstIndex(where: { $0.id == entity.fieldId }) {
                        if !entity.value.isEmpty {
                            let field = form.fields[fieldIndex]
                            let processedValue: String
                            switch field.fieldType {
                            case .age, .number, .date, .time, .phone, .duration:
                                processedValue = TranscriptionProcessor.processText(entity.value, fieldType: field.fieldType)
                            default:
                                processedValue = entity.value
                            }
                            form.fields[fieldIndex].value = processedValue.isEmpty ? entity.value : processedValue
                            if let highlight = result.highlights[entity.fieldId] {
                                form.evidenceSnippets[entity.fieldId] = highlight.snippet
                            } else {
                                form.evidenceSnippets[entity.fieldId] = entity.span?.snippet ?? ""
                            }
                            if entity.confidence < 0.75 {
                                form.lowConfidenceFieldIds.insert(entity.fieldId)
                            } else {
                                form.lowConfidenceFieldIds.remove(entity.fieldId)
                            }
                            let appliedValue = form.fields[fieldIndex].value
                            print("✅ Updated: \(field.label) = \(redactedValue(appliedValue))")
                            if let span = entity.span {
                                print("   ↳ span \(span.start)-\(span.end) snippet=\(redactedValue(span.snippet))")
                            }
                        }
                    }
                }
                
                // Mark extraction flags if relevant entities were found
                if let ctiEntity = result.entities.first(where: { $0.fieldId == "procedureName" && $0.value.lowercased().contains("cti") }) {
                    form.ctiMentionedInTranscription = true
                    if let highlight = result.highlights[ctiEntity.fieldId] {
                        form.evidenceSnippets["ctiFlag"] = highlight.snippet
                        form.highlightSpans["ctiFlag"] = HighlightedSpan(
                            fieldId: "ctiFlag",
                            snippet: highlight.snippet,
                            context: highlight.context,
                            start: highlight.start,
                            end: highlight.end,
                            confidence: highlight.confidence
                        )
                    } else if let snippet = ctiEntity.span?.snippet, !snippet.isEmpty {
                        form.evidenceSnippets["ctiFlag"] = snippet
                        form.highlightSpans["ctiFlag"] = HighlightedSpan(
                            fieldId: "ctiFlag",
                            snippet: snippet,
                            context: snippet,
                            start: 0,
                            end: snippet.count,
                            confidence: ctiEntity.confidence
                        )
                    }
                }
                
                // Notify UI
                print("🎯 Calling onContinuousComplete with \(result.entities.count) entities")
                onContinuousComplete?(result)
            }
        } catch {
            print("❌ Failed to extract entities: \(error)")
            print("❌ Error type: \(type(of: error))")
            print("❌ Error details: \(error.localizedDescription)")
            
            // Fallback to basic extraction if AI extraction fails
            if let extractionError = error as? EntityExtractionError {
                print("🔄 Attempting fallback extraction due to: \(extractionError)")
                do {
                    let fallbackResult = try EntityExtractor.fallbackExtraction(from: transcriptToProcess)
                    
                    await MainActor.run {
                        form.lowConfidenceFieldIds.removeAll()
                        form.evidenceSnippets.removeAll()
                        form.highlightSpans = fallbackResult.highlights
                        Task {
                            for highlight in fallbackResult.highlights.values {
                                _ = await HighlightingContextCache.shared.fragments(for: highlight)
                            }
                        }
                        for entity in fallbackResult.entities {
                            if let fieldIndex = form.fields.firstIndex(where: { $0.id == entity.fieldId }) {
                                if !entity.value.isEmpty {
                                    form.fields[fieldIndex].value = entity.value
                                    if let highlight = fallbackResult.highlights[entity.fieldId] {
                                        form.evidenceSnippets[entity.fieldId] = highlight.snippet
                                    } else {
                                        form.evidenceSnippets[entity.fieldId] = entity.span?.snippet ?? ""
                                    }
                                    if entity.confidence < 0.75 {
                                        form.lowConfidenceFieldIds.insert(entity.fieldId)
                                    } else {
                                        form.lowConfidenceFieldIds.remove(entity.fieldId)
                                    }
                                    print("✅ Fallback updated: \(form.fields[fieldIndex].label) = \(redactedValue(entity.value))")
                                }
                            }
                        }
                        
                        onContinuousComplete?(fallbackResult)
                    }
                } catch {
                    print("❌ Fallback extraction also failed: \(error)")
                }
            }
        }
        if !configuration.processAfterRecording {
            prepareExtractionContextCache(for: continuousTranscript)
        }
    }
    
    func finishContinuousTranscription() async {
        print("🏁 Finishing continuous transcription")
        print("📊 Final transcript stats:")
        print("  - Total: \(continuousTranscript.count) chars")
        print("  - Words: \(continuousTranscript.split(separator: " ").count)")
        print("  - Process after recording mode: \(configuration.processAfterRecording)")
        cancelScheduledProcessing()
        
        // Ensure we're not already processing
        guard !isProcessingTranscription else {
            print("⚠️ Already processing transcription, skipping")
            return
        }
        
        // If in "process after recording" mode, we need to process the complete transcript
        if configuration.processAfterRecording && !continuousTranscript.isEmpty {
            print("🔄 Processing complete transcript (process after recording mode)")
            isProcessingTranscription = true
            await processContinuousTranscription()
            isProcessingTranscription = false
        } else if !configuration.processAfterRecording {
            // In progressive mode, just ensure any pending processing is complete
            print("✅ Progressive mode - transcript already processed during recording")
        }
    }
    
    func resetContinuousMode() {
        cancelScheduledProcessing()
        continuousTranscript = ""
        finalizedTranscript = AttributedString("")
        volatileTranscript = AttributedString("")
        clearExtractionContextCache()
    }

    func resetSession() {
        print("🔄 Starting session reset...")
        print("  - Current transcript length: \(continuousTranscript.count)")
        print("  - Finalized transcript length: \(finalizedTranscript.characters.count)")
        
        // Clear all transcript state
        continuousTranscript = ""
        finalizedTranscript = AttributedString("")
        volatileTranscript = AttributedString("")
        clearExtractionContextCache()
        
        // Clear input builder state to ensure clean session
        inputBuilder?.finish()
        inputBuilder = nil
        
        // Re-initialize streams for next session
        Task {
            if analyzer != nil && analyzerFormat != nil {
                (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
            }
        }
        
        // Reset converter timeline to avoid timestamp discontinuities on next start
        converter.reset()

        print("✅ Session reset completed")
    }
    
    nonisolated func streamAudioToTranscriber(_ buffer: AVAudioPCMBuffer) async throws {
        // Get current analyzer format
        let format = await analyzerFormat
        guard let format = format else {
            throw TranscriptionError.invalidAudioDataType
        }
        
        // Convert buffer to analyzer format
        let convertedBuffer = try converter.convertBuffer(buffer, to: format)

        // Guard against zero-length buffers which can cause issues
        if convertedBuffer.frameLength == 0 {
            print("⏭️ Skipping zero-length buffer (no frames)")
            return
        }

        // Create AnalyzerInput without explicit timestamps (progressive mode)
        let input = AnalyzerInput(buffer: convertedBuffer)
        
        // Process through analyzer
        await processAnalyzerInput(input)
    }
    
    public func finishTranscribing() async throws {
        print("🎬 Finishing transcription...")
        print("  - Mode: \(configuration.isContinuousMode ? "Continuous" : "Field-by-field")")
        print("  - Process after recording: \(configuration.processAfterRecording)")
        cancelScheduledProcessing()

        // Finish the input stream
        inputBuilder?.finish()
        
        // Important: Use finalize(through: nil) to ensure all pending audio is processed
        // This follows the pattern from SpeechAnalyzerDemo's finalizePreviousTranscribing
        print("🔄 Finalizing analyzer (processing all pending audio)...")
        try await analyzer?.finalize(through: nil)
        
        // Give time for all final results to be processed through the results stream
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Automatically kick off entity extraction when recording is done
        if configuration.isContinuousMode && configuration.processAfterRecording && !continuousTranscript.isEmpty {
            print("🚀 Auto-processing transcript at finishTranscribing()")
            await processContinuousTranscription()
        }
        
        recognizerTask?.cancel()
        recognizerTask = nil
        print("✅ Transcription finished - all results finalized")
    }
}

extension SpokenWordTranscriber {
    public func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        guard await supported(locale: locale) else {
            throw TranscriptionError.localeNotSupported
        }
        
        if await installed(locale: locale) {
            return
        } else {
            try await downloadIfNeeded(for: transcriber)
        }
    }
    
    func supported(locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    func installed(locale: Locale) async -> Bool {
        let installed = await Set(SpeechTranscriber.installedLocales)
        return installed.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    func downloadIfNeeded(for module: SpeechTranscriber) async throws {
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            self.downloadProgress = downloader.progress
            try await downloader.downloadAndInstall()
        }
    }
    
    func deallocate() async {
        progressiveProcessingTask?.cancel()
        progressiveProcessingTask = nil
        // Release reserved locale assets when done
        if let reserved = self.reservedLocale {
            let shouldRelease = await TranscriptionSessionCache.shared.release(locale: reserved)
            if shouldRelease {
                await AssetInventory.release(reservedLocale: reserved)
            }
            self.reservedLocale = nil
        }
    }
}
