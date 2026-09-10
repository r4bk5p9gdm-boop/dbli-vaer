import Foundation
import WatchConnectivity

final class WatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchSyncManager()
    private static let snapshotKey = "weatherSnapshot"

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(place: Place, forecast: [ForecastHour], updatedAt: Date) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: forecast, updatedAt: updatedAt)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? WCSession.default.updateApplicationContext([Self.snapshotKey: data])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}

