import Foundation
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchWeatherStore: ObservableObject {
    @Published private(set) var snapshot: WidgetWeatherSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?

    private let receiver = WatchSnapshotReceiver()

    init() {
        snapshot = SharedWidgetData.load()
        receiver.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.accept(snapshot)
            }
        }
        receiver.activate()
    }

    func refresh() async {
        guard !isRefreshing, let place = snapshot?.place else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let forecast = try await YrService.fetch(lat: place.lat, lon: place.lon)
            accept(WidgetWeatherSnapshot(place: place, forecast: forecast, updatedAt: Date()))
            message = nil
        } catch {
            message = "Kunne ikke oppdatere. Viser sist hentede vær."
        }
    }

    private func accept(_ snapshot: WidgetWeatherSnapshot) {
        self.snapshot = snapshot
        SharedWidgetData.save(place: snapshot.place, forecast: snapshot.forecast, updatedAt: snapshot.updatedAt)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

private final class WatchSnapshotReceiver: NSObject, WCSessionDelegate {
    var onSnapshot: ((WidgetWeatherSnapshot) -> Void)?
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
        guard let data = context[Self.snapshotKey] as? Data,
              let snapshot = try? JSONDecoder().decode(WidgetWeatherSnapshot.self, from: data) else { return }
        onSnapshot?(snapshot)
    }
}

