import SwiftUI
import BackgroundTasks
import UserNotifications

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

    init() { BackgroundRefresh.register() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task {
                    if !CommandLine.arguments.contains("-skipPermissionPrompts") {
                        store.notificationsAuthorized = await NotificationScheduler.requestPermission()
                    }
                    _ = await store.refreshAll()
                    BackgroundRefresh.schedule()
                }
        }
    }
}
