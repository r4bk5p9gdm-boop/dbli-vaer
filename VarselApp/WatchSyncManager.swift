import Foundation
import WatchConnectivity

@MainActor
protocol WatchApplicationContextClient: AnyObject {
    var isSupported: Bool { get }
    var isActivated: Bool { get }
    func updateApplicationContext(_ context: [String: Data]) throws
}

@MainActor
private final class SystemWatchApplicationContextClient: WatchApplicationContextClient {
    var isSupported: Bool { WCSession.isSupported() }
    var isActivated: Bool { WCSession.default.activationState == .activated }
    func updateApplicationContext(_ context: [String: Data]) throws {
        try WCSession.default.updateApplicationContext(context)
    }
}

@MainActor
final class WatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchSyncManager(client: SystemWatchApplicationContextClient(), activateSession: true)
    private static let snapshotKey = "weatherSnapshot"
    private let client: any WatchApplicationContextClient
    private var pendingTransferData: Data?

    init(client: any WatchApplicationContextClient, activateSession: Bool = false) {
        self.client = client
        super.init()
        guard activateSession, client.isSupported else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(place: Place, forecast: [ForecastHour], updatedAt: Date, languageStyle: AlertLanguageStyle? = nil, textSeparator: WeatherTextSeparator? = .current) {
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: forecast, updatedAt: updatedAt, languageStyle: languageStyle, textSeparator: textSeparator)
        enqueue(WatchWeatherTransfer(snapshot: snapshot, sentAt: Date()))
    }

    func clear() {
        enqueue(WatchWeatherTransfer(snapshot: nil, sentAt: Date()))
    }

    private func enqueue(_ transfer: WatchWeatherTransfer) {
        guard client.isSupported, let data = try? JSONEncoder().encode(transfer) else { return }
        pendingTransferData = data
        flushIfActivated()
    }

    private func flushIfActivated() {
        guard client.isSupported,
              client.isActivated,
              let data = pendingTransferData else { return }
        do {
            try client.updateApplicationContext([Self.snapshotKey: data])
            pendingTransferData = nil
        } catch {
            // Keep the newest transfer and retry on the next activation or send.
        }
    }

    func retryPendingTransfer() { flushIfActivated() }

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
