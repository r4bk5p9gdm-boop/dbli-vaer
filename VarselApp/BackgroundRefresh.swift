import BackgroundTasks

enum BackgroundRefresh {
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
        req.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task {
            let store = await Store()
            let success = await store.refreshAll()
            task.setTaskCompleted(success: success && !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }
}
