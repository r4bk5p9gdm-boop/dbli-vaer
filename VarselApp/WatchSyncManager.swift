import Foundation
import WatchConnectivity

@MainActor
final class WatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchSyncManager()
    private static let snapshotKey = "weatherSnapshot"
    private var pendingTransferData: Data?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(place: Place, forecast: [ForecastHour], updatedAt: Date) {
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: forecast, updatedAt: updatedAt)
        enqueue(WatchWeatherTransfer(snapshot: snapshot, sentAt: Date()))
    }

    func clear() {
        enqueue(WatchWeatherTransfer(snapshot: nil, sentAt: Date()))
    }

    private func enqueue(_ transfer: WatchWeatherTransfer) {
        guard WCSession.isSupported(), let data = try? JSONEncoder().encode(transfer) else { return }
        pendingTransferData = data
        flushIfActivated()
    }

    private func flushIfActivated() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              let data = pendingTransferData else { return }
        do {
            try WCSession.default.updateApplicationContext([Self.snapshotKey: data])
            pendingTransferData = nil
        } catch {
            // Keep the newest transfer and retry on the next activation or send.
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            if activationState == .activated { self.flushIfActivated() }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
