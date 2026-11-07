import Foundation

/// Runs tasks on dedicated threads, so blocking `read`/`write`/`fsync` calls never starve the
/// shared cooperative pool (which has only one thread per core).
///
/// Use with `withTaskExecutorPreference(BlockingIOExecutor.shared) { … }`. Child tasks
/// inherit the preference.
public final class BlockingIOExecutor: TaskExecutor, @unchecked Sendable {
    /// Enough threads for every file in flight writing to several destinations at once.
    public static let shared = BlockingIOExecutor(threads: 24)

    // `@unchecked Sendable`: `jobs` is only touched while holding `condition`.
    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []

    public init(threads: Int) {
        for i in 0..<threads {
            let thread = Thread { [self] in run() }
            thread.name = "photoferry.io.\(i)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}
