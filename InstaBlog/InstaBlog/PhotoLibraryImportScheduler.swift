import Foundation

nonisolated struct PhotoLibraryImportSuccess<Value: Sendable>: Sendable {
    let index: Int
    let value: Value
}

nonisolated struct PhotoLibraryImportFailure: Sendable {
    let index: Int
    let description: String
}

nonisolated struct PhotoLibraryImportBatch<Value: Sendable>: Sendable {
    let successes: [PhotoLibraryImportSuccess<Value>]
    let failures: [PhotoLibraryImportFailure]
    let wasCancelled: Bool
}

nonisolated enum PhotoLibraryImportScheduler {
    /// Runs only a small number of import operations at a time and returns every
    /// successful result in the order the person selected it.
    nonisolated static func process<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maximumConcurrentOperations: Int = 3,
        progress: (@Sendable (_ completedCount: Int, _ totalCount: Int) async -> Void)? = nil,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async -> PhotoLibraryImportBatch<Output> {
        precondition(maximumConcurrentOperations > 0)

        var nextIndex = 0
        var successes: [PhotoLibraryImportSuccess<Output>] = []
        var failures: [PhotoLibraryImportFailure] = []
        var wasCancelled = Task.isCancelled
        var completedCount = 0

        await withTaskGroup(of: ImportResult<Output>.self) { group in
            func addNextOperation() {
                guard nextIndex < inputs.count, !Task.isCancelled else { return }
                let index = nextIndex
                let input = inputs[index]
                nextIndex += 1
                group.addTask {
                    do {
                        return .success(index, try await operation(input))
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .failure(index, String(describing: error))
                    }
                }
            }

            for _ in 0..<min(maximumConcurrentOperations, inputs.count) {
                addNextOperation()
            }

            while let result = await group.next() {
                completedCount += 1
                if Task.isCancelled {
                    wasCancelled = true
                    group.cancelAll()
                }

                switch result {
                case let .success(index, value):
                    successes.append(PhotoLibraryImportSuccess(index: index, value: value))
                case let .failure(index, description):
                    failures.append(PhotoLibraryImportFailure(index: index, description: description))
                case .cancelled:
                    wasCancelled = true
                }

                await progress?(completedCount, inputs.count)

                addNextOperation()
            }
        }

        return PhotoLibraryImportBatch(
            successes: successes.sorted { $0.index < $1.index },
            failures: failures.sorted { $0.index < $1.index },
            wasCancelled: wasCancelled || Task.isCancelled
        )
    }

    private enum ImportResult<Value: Sendable>: Sendable {
        case success(Int, Value)
        case failure(Int, String)
        case cancelled
    }
}
