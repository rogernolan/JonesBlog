import OSLog
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
