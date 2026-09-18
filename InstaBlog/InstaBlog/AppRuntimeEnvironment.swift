import Foundation

nonisolated enum AppCloudKitEnvironment: String, Equatable, Sendable {
    case development = "Development"
    case production = "Production"
    case unknown
}

nonisolated enum AppBuildVariant: String, Equatable, Sendable {
    case debug = "Debug"
    case liveDebug = "Live Debug"
    case release = ""

    static var current: Self {
#if LIVE_PRODUCTION
        .liveDebug
#elseif DEBUG
        .debug
#else
        .release
#endif
    }
}

nonisolated struct AppBuildInformation: Equatable, Sendable {
    let version: String
    let build: String
    let variant: AppBuildVariant
    let commitHash: String?

    var displayText: String {
        var text = "Version \(version) (\(build))"
        if !variant.rawValue.isEmpty {
            text += " · \(variant.rawValue)"
        }
        // Written into the app bundle by the "Stamp git commit hash" build
        // phase for non-Release configurations.
        if variant != .release, let commitHash, !commitHash.isEmpty {
            text += " · \(commitHash)"
        }
        return text
    }

    static var current: Self {
        let commitHash = Bundle.main.url(forResource: "git-commit-hash", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Self(
            version: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "Unknown",
            build: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "Unknown",
            variant: .current,
            commitHash: commitHash
        )
    }
}

nonisolated struct AppRuntimeEnvironment: Equatable, Sendable {
    let cloudKitEnvironment: AppCloudKitEnvironment
    let isDebugBuild: Bool

    var requiresProductionDataWarning: Bool {
        isDebugBuild && cloudKitEnvironment == .production
    }

    static var current: Self {
        Self(
            cloudKitEnvironment: Bundle.main.object(
                forInfoDictionaryKey: "AppCloudKitEnvironment"
            )
            .flatMap { $0 as? String }
            .flatMap(AppCloudKitEnvironment.init(rawValue:))
            ?? .unknown,
            isDebugBuild: Self.isDebugBuild
        )
    }

    private static var isDebugBuild: Bool {
#if DEBUG
        true
#else
        false
#endif
    }
}
