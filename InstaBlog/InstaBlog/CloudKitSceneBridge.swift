import CloudKit
import UIKit

@MainActor
enum RemoteNotificationSyncHandler {
    static func run(
        synchronizeCloudState: () async -> Void,
        loadActiveBlogID: () async throws -> Blog.ID?,
        synchronizeMedia: (Blog.ID) async throws -> Void,
        logFailure: (String) -> Void = { _ in }
    ) async -> UIBackgroundFetchResult {
        await synchronizeCloudState()

        let activeBlogID: Blog.ID?
        do {
            activeBlogID = try await loadActiveBlogID()
        } catch {
            AppTelemetry.log(
                "Failed to load the active blog during background sync",
                category: "cloud.background-sync",
                level: .error,
                error: error
            )
            logFailure("Failed to load the active blog during background sync: \(error)")
            return .failed
        }

        guard let activeBlogID else {
            return .noData
        }

        do {
            try await synchronizeMedia(activeBlogID)
            return .newData
        } catch {
            AppTelemetry.log(
                "Failed to synchronize media during background sync",
                category: "cloud.background-sync",
                level: .error,
                error: error,
                data: ["blog_id": activeBlogID.uuidString]
            )
            logFailure("Failed to synchronize media during background sync: \(error)")
            return .failed
        }
    }
}

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
