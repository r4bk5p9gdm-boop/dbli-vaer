import SwiftUI
import BackgroundTasks
import UserNotifications

@MainActor
enum StartupWeatherBootstrap {
    static func run(
        selectCurrentLocation: @escaping @MainActor () async -> Void,
        refreshInitialForecast: @escaping @MainActor () async -> Void,
        scheduleBackgroundRefresh: @escaping @MainActor () -> Void,
        requestNotificationsPermission: @escaping @MainActor () async -> Void,
        refreshSelectedForecastIfNeeded: @escaping @MainActor () async -> Void
    ) async {
        async let locationSelection = selectCurrentLocation()
        scheduleBackgroundRefresh()
        await refreshInitialForecast()
        await locationSelection
        await requestNotificationsPermission()
        await refreshSelectedForecastIfNeeded()
    }
}

final class AppNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let placeID = response.notification.request.content.userInfo[NotificationRoute.placeIDKey] as? String else { return }
        NotificationRoute.request(placeID: placeID)
    }
}

@main
struct VarselApp: App {
    @UIApplicationDelegateAdaptor(AppNotificationDelegate.self) private var notificationDelegate
    @StateObject private var store = Store.shared
    @Environment(\.scenePhase) private var scenePhase

    init() { BackgroundRefresh.register() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { @MainActor in
                        store.notificationsAuthorized = await NotificationScheduler.authorizationStatus()
                        _ = await store.refreshSelectedForecastIfNeeded()
                    }
                }
                .task {
                    let shouldAskForPermissions = !CommandLine.arguments.contains("-skipPermissionPrompts")
                    await StartupWeatherBootstrap.run(
                        selectCurrentLocation: { await store.selectCurrentLocationIfPossible() },
                        refreshInitialForecast: { _ = await store.refreshAll() },
                        scheduleBackgroundRefresh: { BackgroundRefresh.schedule() },
                        requestNotificationsPermission: {
                            if shouldAskForPermissions {
                                store.notificationsAuthorized = await NotificationScheduler.requestPermission()
                            }
                        },
                        refreshSelectedForecastIfNeeded: { _ = await store.refreshSelectedForecastIfNeeded() }
                    )
                }
        }
    }
}
