import CloudKit
import UIKit

@MainActor
final class CloudKitSceneBridge: UIResponder, UIWindowSceneDelegate {
    static var shareAcceptanceHandler: ((CKShare.Metadata) -> Void)?

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Self.shareAcceptanceHandler?(cloudKitShareMetadata)
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let metadata = connectionOptions.cloudKitShareMetadata else { return }
        Self.shareAcceptanceHandler?(metadata)
    }
}

final class InstaBlogAppDelegate: NSObject, UIApplicationDelegate {
    nonisolated(unsafe) static var remoteNotificationHandler: (@Sendable () async -> UIBackgroundFetchResult)?

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = CloudKitSceneBridge.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }
        guard let remoteNotificationHandler = Self.remoteNotificationHandler else {
            completionHandler(.noData)
            return
        }
        Task {
            completionHandler(await remoteNotificationHandler())
        }
    }
}
