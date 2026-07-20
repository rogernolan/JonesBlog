import OSLog
import Security
import Sentry

nonisolated enum AppRuntimeEnvironment {
    enum BuildSource: String, Equatable {
        case xcode = "Xcode"
        case testFlight = "TestFlight"
        case production = "Production"
    }

    static var cloudKitEnvironment: String {
        stringEntitlement("com.apple.developer.icloud-container-environment") ?? "Unknown"
    }

    static var isDevelopmentSigned: Bool {
        boolEntitlement("get-task-allow") ?? false
    }

    static var buildSource: BuildSource {
        buildSource(
            isDevelopmentSigned: isDevelopmentSigned,
            receiptName: Bundle.main.appStoreReceiptURL?.lastPathComponent
        )
    }

    static var versionAndBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "—"
        return "\(version) (\(build))"
    }

    static var settingsBuildDescription: String {
        switch buildSource {
        case .xcode, .testFlight:
            "\(buildSource.rawValue) · \(versionAndBuild)"
        case .production:
            versionAndBuild
        }
    }

    static func buildSource(
        isDevelopmentSigned: Bool,
        receiptName: String?
    ) -> BuildSource {
        if isDevelopmentSigned {
            return .xcode
        }
        if receiptName == "sandboxReceipt" {
            return .testFlight
        }
        return .production
    }

    private static func stringEntitlement(_ key: String) -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        else { return nil }
        return value as? String
    }

    private static func boolEntitlement(_ key: String) -> Bool? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        else { return nil }
        return value as? Bool
    }
}

enum AppTelemetry {
    enum Level: Sendable {
        case info
        case warning
        case error
    }

    nonisolated static func record(
        _ message: String,
        category: String,
        level: Level = .info,
        error: (any Error)? = nil,
        data: [String: Any] = [:]
    ) {
        let attributes = attributes(data: data, error: error)
        log(message, category: category, level: level, attributes: attributes)
        guard SentrySDK.isEnabled else { return }

        let breadcrumb = Breadcrumb(level: sentryLevel(for: level), category: category)
        breadcrumb.type = "app"
        breadcrumb.message = message
        breadcrumb.data = attributes
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    nonisolated static func log(
        _ message: String,
        category: String,
        level: Level = .info,
        error: (any Error)? = nil,
        data: [String: Any] = [:]
    ) {
        log(
            message,
            category: category,
            level: level,
            attributes: attributes(data: data, error: error)
        )
    }

    nonisolated static func capture(
        _ error: any Error,
        message: String,
        category: String,
        data: [String: Any] = [:]
    ) {
        log(message, category: category, level: .error, error: error, data: data)
        guard SentrySDK.isEnabled else { return }
        SentrySDK.capture(error: error)
    }

    nonisolated private static func log(
        _ message: String,
        category: String,
        level: Level,
        attributes: [String: Any]
    ) {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "InstaBlog",
            category: category
        )
        let renderedMessage = renderedMessage(message, attributes: attributes)

        switch level {
        case .info:
            logger.info("\(renderedMessage, privacy: .public)")
        case .warning:
            logger.warning("\(renderedMessage, privacy: .public)")
        case .error:
            logger.error("\(renderedMessage, privacy: .public)")
        }

        guard SentrySDK.isEnabled else { return }

        var sentryAttributes = attributes
        sentryAttributes["category"] = category

        switch level {
        case .info:
            SentrySDK.logger.info(message, attributes: sentryAttributes)
        case .warning:
            SentrySDK.logger.warn(message, attributes: sentryAttributes)
        case .error:
            SentrySDK.logger.error(message, attributes: sentryAttributes)
        }
    }

    nonisolated private static func attributes(
        data: [String: Any],
        error: (any Error)?
    ) -> [String: Any] {
        guard let error else { return data }

        let nsError = error as NSError
        var attributes = data
        attributes["error_domain"] = nsError.domain
        attributes["error_code"] = nsError.code
        attributes["error_description"] = nsError.localizedDescription
        return attributes
    }

    nonisolated private static func renderedMessage(
        _ message: String,
        attributes: [String: Any]
    ) -> String {
        guard let domain = attributes["error_domain"],
              let code = attributes["error_code"],
              let description = attributes["error_description"]
        else { return message }

        return "\(message) [\(domain) code \(code)] \(description)"
    }

    nonisolated private static func sentryLevel(for level: Level) -> SentryLevel {
        switch level {
        case .info:
            .info
        case .warning:
            .warning
        case .error:
            .error
        }
    }
}
