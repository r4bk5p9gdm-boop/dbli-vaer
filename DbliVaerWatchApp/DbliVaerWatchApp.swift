import SwiftUI

@main
struct DbliVaerWatchApp: App {
    @StateObject private var store = WatchWeatherStore()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(store)
                .task { await store.refresh() }
        }
    }
}

