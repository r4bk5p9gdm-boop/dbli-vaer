import Foundation
import BackgroundTasks
import OSLog

final class BackgroundRefreshCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasCompleted = false

    func finish(success: Bool, complete: (Bool) -> Void) {
        lock.lock()
        guard !hasCompleted else {
            lock.unlock()
            return
        }
        hasCompleted = true
        lock.unlock()
        complete(success)
    }

    func expire(cancelWork: () -> Void, complete: (Bool) -> Void) {
        lock.lock()
        guard !hasCompleted else {
            lock.unlock()
            return
        }
        hasCompleted = true
        lock.unlock()

        // Claim failure before cancellation can cause the work to finish.
        cancelWork()
        complete(false)
    }
}

final class BackgroundRefreshCoordinator: @unchecked Sendable {
    private let completionGate = BackgroundRefreshCompletionGate()
    private let complete: (Bool) -> Void

    init(complete: @escaping (Bool) -> Void) {
        self.complete = complete
    }

    func finish(success: Bool) {
        completionGate.finish(success: success, complete: complete)
    }

    func expire(cancelWork: () -> Void) {
        completionGate.expire(cancelWork: cancelWork, complete: complete)
    }
}

enum BackgroundRefresh {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "no.mathias.VarselApp", category: "BackgroundRefresh")
    static let minimumInterval: TimeInterval = 30 * 60

    static var id: String {
        (Bundle.main.bundleIdentifier ?? "no.mathias.VarselApp") + ".refresh"
    }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    static func schedule() {
        schedule(submit: { try BGTaskScheduler.shared.submit($0) }) { error in
            logger.error("Could not schedule background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func scheduleWhenActive(isActive: Bool, schedule: () -> Void) {
        guard isActive else { return }
        schedule()
    }

    static func schedule(
        now: Date = Date(),
        submit: (BGAppRefreshTaskRequest) throws -> Void,
        onFailure: (Error) -> Void
    ) {
        let req = BGAppRefreshTaskRequest(identifier: id)
        req.earliestBeginDate = earliestBeginDate(now: now)
        do {
            try submit(req)
        } catch {
            onFailure(error)
        }
    }

    static func earliestBeginDate(now: Date = Date()) -> Date {
        now.addingTimeInterval(minimumInterval)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let coordinator = BackgroundRefreshCoordinator { task.setTaskCompleted(success: $0) }
        let work = Task {
            let store = await Store.shared
            let success = await store.refreshAll(backgroundOnly: true)
            coordinator.finish(success: success && !Task.isCancelled)
        }
        task.expirationHandler = {
            coordinator.expire { work.cancel() }
        }
    }
}
