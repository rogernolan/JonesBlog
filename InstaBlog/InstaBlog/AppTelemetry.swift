import CloudKit
import OSLog
import Sentry
import SQLiteData

enum AppTelemetry {
    private static let syncFailureThrottle = SyncFailureThrottle()

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
        let attributes = AppTelemetryFormatting.attributes(data: data, error: error)
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
            attributes: AppTelemetryFormatting.attributes(data: data, error: error)
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

    nonisolated static func captureSyncFailure(
        _ error: any Error,
        message: String,
        category: String,
        database: (any DatabaseWriter)? = nil,
        data: [String: Any] = [:]
    ) async {
        let failureKind = AppTelemetryFormatting.cloudKitFailureKind(error)
        var attributes = data
        attributes["failure_kind"] = failureKind.rawValue
        let recordNames = AppTelemetryFormatting.cloudKitRecordNames(in: error)
        if !recordNames.isEmpty {
            attributes["record_names"] = recordNames
        }
        let throttleKey = [
            category,
            failureKind.rawValue,
            error.localizedDescription,
            recordNames.joined(separator: ","),
        ].joined(separator: "|")
        if await syncFailureThrottle.shouldCapture(key: throttleKey, now: .now) {
            capture(error, message: message, category: category, data: attributes)
        }

        guard let database,
              failureKind == .schemaValidation
                || failureKind == .recordValidation
        else { return }

        do {
            let requeued = try await CloudSyncRecoveryService.requeue(
                recordNames: recordNames,
                in: database
            )
            guard !requeued.isEmpty else { return }
            record(
                "Requeued records after permanent CloudKit sync failure",
                category: "cloud.sync.recovery",
                level: .warning,
                data: [
                    "failure_kind": failureKind.rawValue,
                    "record_names": requeued,
                ]
            )
        } catch {
            capture(
                error,
                message: "CloudKit sync recovery failed",
                category: "cloud.sync.recovery",
                data: ["failed_record_names": recordNames]
            )
        }
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
        let renderedMessage = AppTelemetryFormatting.renderedMessage(message, attributes: attributes)

        switch level {
        case .info:
            logger.info("\(renderedMessage, privacy: .public)")
        case .warning:
            logger.warning("\(renderedMessage, privacy: .public)")
        case .error:
            logger.error("\(renderedMessage, privacy: .public)")
#if DEBUG
            print("[\(category)] \(renderedMessage)")
#endif
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

enum AppTelemetryFormatting {
    nonisolated static func attributes(
        data: [String: Any],
        error: (any Error)?
    ) -> [String: Any] {
        guard let error else { return data }

        let nsError = error as NSError
        var attributes = data
        attributes["error_domain"] = nsError.domain
        attributes["error_code"] = nsError.code
        attributes["error_description"] = nsError.localizedDescription
        if let details = cloudKitErrorDetails(nsError), !details.isEmpty {
            attributes["error_details"] = details
        }
        return attributes
    }

    nonisolated static func cloudKitErrorDetails(_ error: NSError) -> String? {
        guard error.domain == CKError.errorDomain else { return nil }

        var details: [String] = []
        if let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey]
            as? [AnyHashable: any Error] {
            details.append(contentsOf: partialErrors.map { key, value in
                let partialError = value as NSError
                return "\(key): \(partialError.domain) code \(partialError.code) "
                    + partialError.localizedDescription
            }.sorted())
        }
        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            details.append(
                "underlying: \(underlyingError.domain) code \(underlyingError.code) "
                    + underlyingError.localizedDescription
            )
        }
        return details.isEmpty ? nil : details.joined(separator: "; ")
    }

    enum CloudKitFailureKind: String, Equatable, Sendable {
        case schemaValidation
        case recordValidation
        case transientCloudKit
        case other
    }

    nonisolated static func cloudKitFailureKind(_ error: any Error) -> CloudKitFailureKind {
        failureKind(error as NSError, visited: [])
    }

    nonisolated static func cloudKitRecordNames(in error: any Error) -> [String] {
        recordNames(error as NSError, visited: []).sorted()
    }

    private static func failureKind(
        _ error: NSError,
        visited: Set<ObjectIdentifier>
    ) -> CloudKitFailureKind {
        let identity = ObjectIdentifier(error)
        guard !visited.contains(identity) else { return .other }
        var visited = visited
        visited.insert(identity)

        let description = "\(error.localizedDescription) \(error)".lowercased()
        if description.contains("production schema")
            || description.contains("development schema")
            || description.contains("cannot create or modify field") {
            return .schemaValidation
        }
        if description.contains("cannot serialize")
            || description.contains("serialize")
            || description.contains("invalid record")
            || description.contains("invalid field") {
            return .recordValidation
        }
        if error.domain == CKError.errorDomain {
            switch CKError.Code(rawValue: error.code) {
            case .networkUnavailable, .networkFailure, .serviceUnavailable,
                 .requestRateLimited, .zoneBusy, .limitExceeded:
                return .transientCloudKit
            default:
                break
            }
        }
        for nested in nestedErrors(in: error) {
            let kind = failureKind(nested, visited: visited)
            if kind != .other { return kind }
        }
        return error.domain == CKError.errorDomain ? .transientCloudKit : .other
    }

    private static func recordNames(
        _ error: NSError,
        visited: Set<ObjectIdentifier>
    ) -> Set<String> {
        let identity = ObjectIdentifier(error)
        guard !visited.contains(identity) else { return [] }
        var visited = visited
        visited.insert(identity)
        var names = Set<String>()
        if let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey]
            as? [AnyHashable: any Error] {
            for (key, value) in partialErrors {
                if let recordID = key.base as? CKRecord.ID {
                    names.insert(recordID.recordName)
                } else if let name = key.base as? String,
                          name.contains(":"),
                          name.split(separator: ":").count >= 2 {
                    names.insert(name)
                }
                names.formUnion(recordNames(value as NSError, visited: visited))
            }
        }
        for nested in nestedErrors(in: error) {
            names.formUnion(recordNames(nested, visited: visited))
        }
        return names
    }

    private static func nestedErrors(in error: NSError) -> [NSError] {
        var nested: [NSError] = []
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            nested.append(underlying)
        }
        if let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey]
            as? [AnyHashable: any Error] {
            nested.append(contentsOf: partialErrors.values.map { $0 as NSError })
        }
        return nested
    }

    nonisolated static func renderedMessage(
        _ message: String,
        attributes: [String: Any]
    ) -> String {
        guard let domain = attributes["error_domain"],
              let code = attributes["error_code"],
              let description = attributes["error_description"]
        else { return message }

        let details = attributes["error_details"].map { " Details: \($0)" } ?? ""
        return "\(message) [\(domain) code \(code)] \(description)\(details)"
    }
}

nonisolated enum CloudSyncRecoveryService {
    private static let requeueThrottle = CloudSyncRecoveryThrottle()

    static func requeue(
        recordNames: [String],
        in database: any DatabaseWriter,
        now: Date = .now
    ) async throws -> [String] {
        let references = recordNames.compactMap(RecordReference.init(recordName:))
        guard !references.isEmpty else { return [] }
        var eligibleReferences: [RecordReference] = []
        for reference in references {
            if await requeueThrottle.shouldAttempt(recordName: reference.recordName, now: now) {
                eligibleReferences.append(reference)
            }
        }
        guard !eligibleReferences.isEmpty else { return [] }
        return try await database.write { db in
            var requeued: [String] = []
            for reference in eligibleReferences {
                let column: String?
                switch reference.recordType {
                case "blogs", "bloggers", "blogItems", "photoItems", "mediaAssets",
                     "trips", "mailingLists", "subscribers":
                    column = "updatedAt"
                default:
                    column = nil
                }
                guard let column,
                      let storedID = try UUID.fetchOne(
                        db,
                        sql: "SELECT id FROM \(reference.recordType) WHERE id = ?",
                        arguments: [reference.id.uuidString.lowercased()]
                      )
                else { continue }
                try db.execute(
                    sql: "UPDATE \(reference.recordType) SET \(column) = ? WHERE id = ?",
                    arguments: [now, storedID.uuidString.lowercased()]
                )
                requeued.append(reference.recordName)
            }
            return requeued
        }
    }

    private struct RecordReference {
        let id: UUID
        let recordType: String
        let recordName: String

        init?(recordName: String) {
            let parts = recordName.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let id = UUID(uuidString: parts[0])
            else { return nil }
            self.id = id
            recordType = parts[1]
            self.recordName = recordName
        }
    }
}

private actor SyncFailureThrottle {
    private var lastCaptureByKey: [String: Date] = [:]
    private let cooldown: TimeInterval = 30

    func shouldCapture(key: String, now: Date) -> Bool {
        guard let lastCapture = lastCaptureByKey[key],
              now.timeIntervalSince(lastCapture) < cooldown
        else {
            lastCaptureByKey[key] = now
            return true
        }
        return false
    }
}

private actor CloudSyncRecoveryThrottle {
    private var lastAttemptByRecordName: [String: Date] = [:]
    private let cooldown: TimeInterval = 30

    func shouldAttempt(recordName: String, now: Date) -> Bool {
        guard let lastAttempt = lastAttemptByRecordName[recordName],
              now.timeIntervalSince(lastAttempt) < cooldown
        else {
            lastAttemptByRecordName[recordName] = now
            return true
        }
        return false
    }
}
