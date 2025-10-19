import Foundation

actor RefinementQueue {
    static let shared = RefinementQueue()

    private struct PendingRequest {
        var entity: ExtractedEntity
        var continuations: [CheckedContinuation<ExtractedEntity?, Never>]
    }

    private var pending: [String: PendingRequest] = [:]
    private var isFlushing = false
    private let debounceInterval: UInt64 = 120_000_000 // 120ms

    init() {}

    func submit(entity: ExtractedEntity) async -> ExtractedEntity? {
        return await withCheckedContinuation { continuation in
            enqueue(entity: entity, continuation: continuation)
        }
    }

    private func enqueue(entity: ExtractedEntity, continuation: CheckedContinuation<ExtractedEntity?, Never>) {
        let key = entity.fieldId
        if var existing = pending[key] {
            existing.entity = entity
            existing.continuations.append(continuation)
            pending[key] = existing
        } else {
            pending[key] = PendingRequest(entity: entity, continuations: [continuation])
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !isFlushing else { return }
        isFlushing = true
        Task {
            try? await Task.sleep(nanoseconds: debounceInterval)
            await flush()
        }
    }

    private func flush() async {
        let requests = pending
        pending.removeAll()
        isFlushing = false
        guard !requests.isEmpty else { return }

        let entities = requests.values.map { $0.entity }
        let extractor = await MainActor.run { EntityExtractor.shared }
        let refined = await extractor.refineEntities(entities)

        for (fieldId, request) in requests {
            let result = refined[fieldId]
            for continuation in request.continuations {
                continuation.resume(returning: result)
            }
        }
    }
}
