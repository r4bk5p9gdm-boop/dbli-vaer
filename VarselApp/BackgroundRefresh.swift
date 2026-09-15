import BackgroundTasks

enum BackgroundRefresh {
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
        let req = BGAppRefreshTaskRequest(identifier: id)
        req.earliestBeginDate = earliestBeginDate()
        try? BGTaskScheduler.shared.submit(req)
    }

    static func earliestBeginDate(now: Date = Date()) -> Date {
        now.addingTimeInterval(minimumInterval)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task {
            let store = await Store.shared
            let success = await store.refreshAll(backgroundOnly: true)
            task.setTaskCompleted(success: success && !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }
}
