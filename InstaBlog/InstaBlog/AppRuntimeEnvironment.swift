import Foundation

nonisolated enum AppCloudKitEnvironment: String, Equatable, Sendable {
    case development = "Development"
    case production = "Production"
    case unknown
}

nonisolated enum AppBuildVariant: String, Equatable, Sendable {
    case debug = "Debug"
    case liveDebug = "Live Debug"
    case migrationExport = "Migration Export"
    case release = ""

    static var current: Self {
#if MIGRATION_EXPORT
        .migrationExport
#elseif LIVE_PRODUCTION
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

    var displayText: String {
        let versionAndBuild = "Version \(version) (\(build))"
        guard !variant.rawValue.isEmpty else { return versionAndBuild }
        return "\(versionAndBuild) · \(variant.rawValue)"
    }

    static var current: Self {
        Self(
            version: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "Unknown",
            build: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "Unknown",
            variant: .current
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
