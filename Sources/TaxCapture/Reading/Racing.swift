import Foundation
import Synchronization

/// Races `work` against `timeout`. Whichever of {`work` finishes, the timeout fires, the
/// caller is cancelled} gets there first wins; the loser is cancelled and the result is
/// nil for anything but a clean finish.
///
/// A `TaskGroup` would wait for its losing child, so this races with a continuation
/// instead, resumed exactly once. Shared by `ReceiptModelCheck.answer` (M3: the model call
/// and its timer must both die the instant the caller cancels) and `VisionTextReader`
/// (I1: `.accurate` OCR is bounded the same way before falling through to `.fast`).
enum Racing {

    static func firstToFinish<T: Sendable>(
        timeout: Duration,
        work: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let resolution = Resolution<T?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                resolution.attach(continuation)
                let workTask = Task {
                    let result = try? await work()
                    resolution.resolve(with: result)
                }
                let timerTask = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    resolution.resolve(with: nil)
                }
                resolution.attach(workTask: workTask, timerTask: timerTask)
            }
        } onCancel: {
            resolution.resolve(with: nil)
        }
    }
}

/// Resolves a continuation exactly once, from whichever of {work, timer, cancellation}
/// gets there first, and cancels whichever of the two tasks did not win.
private final class Resolution<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Never>?
        var workTask: Task<Void, Never>?
        var timerTask: Task<Void, Never>?
        var done = false
    }
    private let state = Mutex(State())

    func attach(_ continuation: CheckedContinuation<T, Never>) {
        state.withLock { $0.continuation = continuation }
    }

    /// Stored after the tasks are created, so `resolve` — which may already have fired,
    /// synchronously, from inside `work`'s own first suspension point — can still cancel
    /// a task it did not have a reference to yet.
    func attach(workTask: Task<Void, Never>, timerTask: Task<Void, Never>) {
        let alreadyDone = state.withLock { s -> Bool in
            s.workTask = workTask
            s.timerTask = timerTask
            return s.done
        }
        if alreadyDone {
            workTask.cancel()
            timerTask.cancel()
        }
    }

    func resolve(with value: T) {
        let continuation = state.withLock { s -> CheckedContinuation<T, Never>? in
            guard !s.done else { return nil }
            s.done = true
            let c = s.continuation
            s.workTask?.cancel()
            s.timerTask?.cancel()
            return c
        }
        continuation?.resume(returning: value)
    }
}
