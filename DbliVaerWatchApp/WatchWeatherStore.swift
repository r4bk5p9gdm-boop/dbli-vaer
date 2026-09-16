import Foundation
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchWeatherStore: ObservableObject {
    @Published private(set) var snapshot: WidgetWeatherSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?

    private let receiver = WatchSnapshotReceiver()
    private let lastTransferKey = "watch.lastWeatherTransferAt"
    private var lastTransferAt: Date
    private var snapshotRevision = UUID()

    init() {
        snapshot = SharedWidgetData.load()
        lastTransferAt = UserDefaults.standard.object(forKey: lastTransferKey) as? Date ?? .distantPast
        receiver.onTransfer = { [weak self] transfer in
            Task { @MainActor in
                self?.accept(transfer)
            }
        }
        receiver.activate()
    }

    func refresh() async {
        guard !isRefreshing, let startingSnapshot = snapshot else { return }
        let revision = snapshotRevision
        let place = startingSnapshot.place
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let forecast = try await YrService.fetch(lat: place.lat, lon: place.lon)
            try Task.checkCancellation()
            guard let updated = startingSnapshot.refreshed(
                with: forecast, at: Date(), requestRevision: revision, currentRevision: snapshotRevision
            ) else { return }
            accept(updated)
        } catch {
            guard !Task.isCancelled, revision == snapshotRevision else { return }
            message = "Kunne ikke oppdatere. Viser sist hentede vær."
        }
    }

    private func accept(_ snapshot: WidgetWeatherSnapshot) {
        guard !snapshot.forecast.isEmpty else { return }
        // Snapshot carries the current Place with the stable UUID, so a
        // position rename is reflected immediately on Watch.
        snapshotRevision = UUID()
        message = nil
        self.snapshot = snapshot
        SharedWidgetData.save(place: snapshot.place, forecast: snapshot.forecast, updatedAt: snapshot.updatedAt, languageStyle: snapshot.languageStyle, textSeparator: snapshot.textSeparator)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func accept(_ transfer: WatchWeatherTransfer) {
        guard WatchTransferPolicy.accepts(transfer.sentAt, after: lastTransferAt) else { return }
        lastTransferAt = transfer.sentAt
        UserDefaults.standard.set(transfer.sentAt, forKey: lastTransferKey)
        guard let snapshot = transfer.snapshot else {
            snapshotRevision = UUID()
            message = nil
            self.snapshot = nil
            SharedWidgetData.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        accept(snapshot)
    }
}

private final class WatchSnapshotReceiver: NSObject, WCSessionDelegate {
    var onTransfer: ((WatchWeatherTransfer) -> Void)?
    private static let snapshotKey = "weatherSnapshot"

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        decode(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        decode(applicationContext)
    }

    private func decode(_ context: [String: Any]) {
        guard let data = context[Self.snapshotKey] as? Data else { return }
        let decoder = JSONDecoder()
        if let transfer = try? decoder.decode(WatchWeatherTransfer.self, from: data) {
            onTransfer?(transfer)
            return
        }
        // Accept contexts sent by builds from before WatchWeatherTransfer.
        if let snapshot = try? decoder.decode(WidgetWeatherSnapshot.self, from: data) {
            onTransfer?(WatchWeatherTransfer(snapshot: snapshot, sentAt: snapshot.updatedAt))
        }
    }
}
