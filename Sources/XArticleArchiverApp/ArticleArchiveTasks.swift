import Foundation

/// Owns every archive task until completion, including tasks awaited for the
/// concurrency limit. Stopping drains this owner before the library is idle.
@MainActor
final class ArticleArchiveTasks {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generation = UUID()
    var count: Int { tasks.count }

    func schedule(_ operation: @escaping @MainActor () async -> Void) async {
        let currentGeneration = generation
        while tasks.count >= 2, let first = tasks.values.first {
            await first.value
            guard currentGeneration == generation, !Task.isCancelled else { return }
        }
        guard currentGeneration == generation, !Task.isCancelled else { return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await operation()
            self?.tasks.removeValue(forKey: id)
        }
    }

    func wait() async {
        while let first = tasks.values.first { await first.value }
    }

    func cancelAndWait() async {
        generation = UUID()
        let pending = Array(tasks.values)
        for task in pending { task.cancel() }
        for task in pending { await task.value }
    }
}
