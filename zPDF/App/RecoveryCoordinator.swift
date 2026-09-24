import Foundation

/// The caller captures immutable native save inputs on the main actor after
/// field editing commits. Only the latest waiting snapshot per tab is kept.
@MainActor
@Observable
final class RecoveryCoordinator {
    let store: RecoveryStore
    private(set) var items: [RecoveryCheckpoint] = []
    private(set) var isLoading = false
    private(set) var isWriting = false
    var errorMessage: String?
    var showingRecovery = false
    @ObservationIgnored private var pending: [UUID: RecoverySnapshot] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var checkpointErrors: [UUID: String] = [:]
    @ObservationIgnored private var displayedCheckpointError: String?

    init(store: RecoveryStore) { self.store = store }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await store.list()
            showingRecovery = !items.isEmpty
        } catch { errorMessage = error.localizedDescription }
    }

    func enqueue(_ snapshot: RecoverySnapshot) {
        pending[snapshot.id] = snapshot
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            isWriting = true
            defer { isWriting = false; worker = nil }
            while let snapshot = pending.values.first {
                pending.removeValue(forKey: snapshot.id)
                do {
                    // Current-session checkpoints do not appear in the startup
                    // recovery sheet until a later launch discovers them.
                    if try await store.write(snapshot) != nil {
                        checkpointErrors.removeValue(forKey: snapshot.id)
                        updateCheckpointError()
                    }
                } catch {
                    checkpointErrors[snapshot.id] = "\(snapshot.displayName): \(error.localizedDescription)"
                    updateCheckpointError()
                }
            }
        }
    }

    func waitUntilIdle() async { await worker?.value }

    /// Call after successful Save or explicit Discard, before releasing an
    /// immutable source lease. Never remove a checkpoint merely on app launch.
    @discardableResult
    func discard(id: UUID) async -> Bool {
        pending.removeValue(forKey: id)
        do {
            try await store.discard(id: id)
            checkpointErrors.removeValue(forKey: id)
            updateCheckpointError()
            items.removeAll { $0.id == id }
            if items.isEmpty { showingRecovery = false }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func validatedURL(for checkpoint: RecoveryCheckpoint) async -> URL? {
        do { return try await store.validate(checkpoint) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    /// Keep the checkpoint until the recovered document is saved or explicitly
    /// discarded. Opening it must be a Save-As-only recovered copy.
    func didRestore(_ checkpoint: RecoveryCheckpoint) {
        items.removeAll { $0.id == checkpoint.id }
        if items.isEmpty { showingRecovery = false }
    }

    private func updateCheckpointError() {
        // A successful retry clears only that document's write failure. Keep
        // other documents' failures and unrelated restore/storage diagnostics.
        guard errorMessage == nil || errorMessage == displayedCheckpointError else { return }
        let next = checkpointErrors.sorted { $0.key.uuidString < $1.key.uuidString }.first?.value
        errorMessage = next
        displayedCheckpointError = next
    }
}
