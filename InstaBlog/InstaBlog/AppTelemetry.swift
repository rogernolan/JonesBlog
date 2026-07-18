import Sentry

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
        data: [String: Any] = [:]
    ) {
        log(message, category: category, level: level, data: data)
        guard SentrySDK.isEnabled else { return }

        let breadcrumb = Breadcrumb(level: sentryLevel(for: level), category: category)
        breadcrumb.type = "app"
        breadcrumb.message = message
        breadcrumb.data = data
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    nonisolated static func log(
        _ message: String,
        category: String,
        level: Level = .info,
        data: [String: Any] = [:]
    ) {
        guard SentrySDK.isEnabled else { return }

        var attributes = data
        attributes["category"] = category

        switch level {
        case .info:
            SentrySDK.logger.info(message, attributes: attributes)
        case .warning:
            SentrySDK.logger.warn(message, attributes: attributes)
        case .error:
            SentrySDK.logger.error(message, attributes: attributes)
        }
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
